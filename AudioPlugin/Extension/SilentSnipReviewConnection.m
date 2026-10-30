#import "SilentSnipReviewConnection.h"
#include <math.h>

SilentSnipReviewState const SilentSnipReviewStateAnalyzing = @"analyzing";
SilentSnipReviewState const SilentSnipReviewStateCapturing = @"capturing";
SilentSnipReviewState const SilentSnipReviewStateRecalculating = @"recalculating";
SilentSnipReviewState const SilentSnipReviewStateReview = @"review";
SilentSnipReviewState const SilentSnipReviewStateApplying = @"applying";
SilentSnipReviewState const SilentSnipReviewStateVerifying = @"verifying";
SilentSnipReviewState const SilentSnipReviewStateNavigating = @"navigating";
SilentSnipReviewState const SilentSnipReviewStateCancelling = @"cancelling";
SilentSnipReviewState const SilentSnipReviewStateCompleted = @"completed";
SilentSnipReviewState const SilentSnipReviewStateComplete = @"complete";
SilentSnipReviewState const SilentSnipReviewStateFailed = @"failed";
SilentSnipReviewState const SilentSnipReviewStateCancelled = @"cancelled";
SilentSnipReviewState const SilentSnipReviewStateUnavailable = @"unavailable";

BOOL SilentSnipReviewStateIsBusy(SilentSnipReviewState state) {
    return [@[SilentSnipReviewStateAnalyzing, SilentSnipReviewStateCapturing, SilentSnipReviewStateRecalculating,
        SilentSnipReviewStateApplying, SilentSnipReviewStateVerifying, SilentSnipReviewStateNavigating, SilentSnipReviewStateCancelling] containsObject:state];
}
BOOL SilentSnipReviewStateIsTerminal(SilentSnipReviewState state) {
    return [@[SilentSnipReviewStateCompleted, SilentSnipReviewStateComplete, SilentSnipReviewStateFailed,
        SilentSnipReviewStateCancelled, SilentSnipReviewStateUnavailable] containsObject:state];
}
BOOL SilentSnipReviewStateCanRetry(SilentSnipReviewState state) {
    return [@[SilentSnipReviewStateFailed, SilentSnipReviewStateCancelled] containsObject:state];
}
static BOOL booleanValue(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
@implementation SilentSnipReviewConnection
- (NSArray<NSDictionary *> *)commandsToRetry {
    if (self.timedOut) return @[];
    NSMutableArray *commands = [NSMutableArray array];
    if (self.applying && !self.applyAcknowledged && self.pendingApply)
        [commands addObject:self.pendingApply];
    for (id pending in @[self.pendingSelection ?: NSNull.null, self.pendingRetry ?: NSNull.null, self.pendingSettings ?: NSNull.null])
        if (pending != NSNull.null) [commands addObject:pending];
    return commands;
}
- (BOOL)hasTimedOutAt:(NSDate *)now {
    if (self.timedOut) return NO;
    // A completed/failed job needs no heartbeat. Do not erase the actual
    // failure with "helper not responding" when its host view was hidden.
    if (SilentSnipReviewStateIsTerminal(self.state) && !self.awaitingResponse && !self.applying &&
        !self.operationBusy && !self.pendingRetry && !self.pendingSelection && !self.pendingSettings) return NO;
    return self.lastResponse && [now timeIntervalSinceDate:self.lastResponse] > 15;
}
- (NSDictionary *)acceptNotification:(NSNotification *)notification {
    if (notification.userInfo || ![notification.object isKindOfClass:NSString.class]) return nil;
    // This exact payload has already passed validation. Keep the connection
    // alive without decoding/rebuilding its rows. An unacknowledged Apply must
    // still time out if the helper only replays the preceding review.
    if ([notification.object isEqual:self.lastResponseObject]) {
        if ((!self.applying || self.applyAcknowledged) && !self.pendingSettings) self.lastResponse = NSDate.date;
        return nil;
    }
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 262144) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *value = decoded;
    for (NSString *flag in @[@"canUpdateCuts", @"usesAudioSnapshot"])
        if (value[flag] && !booleanValue(value[flag])) return nil;
    if (![value[@"version"] isEqual:@1] || ![value[@"request"] isEqual:self.requestID] ||
        ![value[@"revision"] isKindOfClass:NSNumber.class] || booleanValue(value[@"revision"]) ||
        [value[@"revision"] doubleValue] < 0 || floor([value[@"revision"] doubleValue]) != [value[@"revision"] doubleValue] ||
        ![value[@"message"] isKindOfClass:NSString.class] || ![value[@"state"] isKindOfClass:NSString.class] ||
        ![value[@"cuts"] isKindOfClass:NSArray.class] || [value[@"cuts"] count] > 2000 || !booleanValue(value[@"canApply"])) return nil;
    if (self.revision && [value[@"revision"] compare:self.revision] == NSOrderedAscending) return nil;
    // A timeout consumes this local review. Keep listening for the real final
    // outcome, but no delayed progress/review may restore its capabilities.
    if (self.timedOut && !SilentSnipReviewStateIsTerminal(value[@"state"])) return nil;
    if (self.applying) {
        BOOL terminal = SilentSnipReviewStateIsTerminal(value[@"state"]);
        if ([value[@"revision"] compare:self.applyRevision] != NSOrderedDescending ||
            (!terminal && ![value[@"state"] isEqual:SilentSnipReviewStateApplying])) return nil;
    }
    // A previous settings response cannot replace the newest local edit.
    if (self.pendingSettings && ![value[@"settingsEdit"] isEqual:self.pendingSettings[@"settingsEdit"]]) {
        return nil;
    }

    for (id row in value[@"cuts"]) {
        if (![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] || ![row[@"id"] length] || ![row[@"start"] isKindOfClass:NSString.class] ||
            ![row[@"end"] isKindOfClass:NSString.class] || ![row[@"duration"] isKindOfClass:NSString.class] ||
            !booleanValue(row[@"eligible"]) || !booleanValue(row[@"included"])) return nil;

    }
    // Equal revisions are heartbeats, not acknowledgments of local edits.
    // Preserve the Apply guard above and leave pending selection/settings alone.
    self.lastResponse = NSDate.date;
    if (self.revision && [value[@"revision"] compare:self.revision] == NSOrderedSame) return nil;
    self.awaitingResponse = NO;
    self.lastResponseObject = notification.object;
    self.revision = value[@"revision"];
    self.state = value[@"state"];
    if (self.pendingSettings && [value[@"settingsEdit"] isEqual:self.pendingSettings[@"settingsEdit"]]) self.pendingSettings = nil;
    if (self.pendingRetry && [self.revision compare:self.pendingRetry[@"expectedRevision"]] == NSOrderedDescending) self.pendingRetry = nil;
    if (self.pendingSelection && [self.revision compare:self.selectionRevision] == NSOrderedDescending) {
        NSString *kind = self.pendingSelection[@"command"];
        BOOL matches = YES;
        if ([kind isEqual:@"include"]) {
            matches = NO;
            for (NSDictionary *row in value[@"cuts"]) if ([row[@"id"] isEqual:self.pendingSelection[@"cutID"]])
                matches = [row[@"included"] isEqual:self.pendingSelection[@"included"]];
        } else for (NSDictionary *row in value[@"cuts"]) {
            BOOL wanted = [kind isEqual:@"selectAll"] && [row[@"eligible"] boolValue];
            if ([row[@"included"] boolValue] != wanted) matches = NO;
        }
        if (matches || ![value[@"state"] isEqual:SilentSnipReviewStateReview]) self.pendingSelection = nil;
    }
    return value;
}
@end
