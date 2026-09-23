#import "CutdownReviewConnection.h"
#include <math.h>

CutdownReviewState const CutdownReviewStateAnalyzing = @"analyzing";
CutdownReviewState const CutdownReviewStateCapturing = @"capturing";
CutdownReviewState const CutdownReviewStateRecalculating = @"recalculating";
CutdownReviewState const CutdownReviewStateReview = @"review";
CutdownReviewState const CutdownReviewStateApplying = @"applying";
CutdownReviewState const CutdownReviewStateVerifying = @"verifying";
CutdownReviewState const CutdownReviewStateNavigating = @"navigating";
CutdownReviewState const CutdownReviewStateCancelling = @"cancelling";
CutdownReviewState const CutdownReviewStateCompleted = @"completed";
CutdownReviewState const CutdownReviewStateComplete = @"complete";
CutdownReviewState const CutdownReviewStateFailed = @"failed";
CutdownReviewState const CutdownReviewStateCancelled = @"cancelled";
CutdownReviewState const CutdownReviewStateUnavailable = @"unavailable";

BOOL CutdownReviewStateIsBusy(CutdownReviewState state) {
    return [@[CutdownReviewStateAnalyzing, CutdownReviewStateCapturing, CutdownReviewStateRecalculating,
        CutdownReviewStateApplying, CutdownReviewStateVerifying, CutdownReviewStateNavigating, CutdownReviewStateCancelling] containsObject:state];
}
BOOL CutdownReviewStateIsTerminal(CutdownReviewState state) {
    return [@[CutdownReviewStateCompleted, CutdownReviewStateComplete, CutdownReviewStateFailed,
        CutdownReviewStateCancelled, CutdownReviewStateUnavailable] containsObject:state];
}
BOOL CutdownReviewStateCanRetry(CutdownReviewState state) {
    return [@[CutdownReviewStateFailed, CutdownReviewStateCancelled] containsObject:state];
}
static BOOL booleanValue(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
@implementation CutdownReviewConnection
- (NSArray<NSDictionary *> *)commandsToRetry {
    NSMutableArray *commands = [NSMutableArray array];
    if (self.applying && !self.applyAcknowledged && self.pendingApply)
        [commands addObject:self.pendingApply];
    for (id pending in @[self.pendingSelection ?: NSNull.null, self.pendingRetry ?: NSNull.null, self.pendingPreview ?: NSNull.null])
        if (pending != NSNull.null) [commands addObject:pending];
    return commands;
}
- (BOOL)hasTimedOutAt:(NSDate *)now {
    if (self.timedOut) return NO;
    // A completed/failed job needs no heartbeat. Do not erase the actual
    // failure with "helper not responding" when its host view was hidden.
    if (CutdownReviewStateIsTerminal(self.state) && !self.awaitingResponse && !self.applying &&
        !self.operationBusy && !self.pendingRetry && !self.pendingSelection && !self.pendingPreview) return NO;
    return self.lastResponse && [now timeIntervalSinceDate:self.lastResponse] > 15;
}
- (NSDictionary *)acceptNotification:(NSNotification *)notification {
    if (notification.userInfo || ![notification.object isKindOfClass:NSString.class]) return nil;
    // This exact payload has already passed validation. Keep the connection
    // alive without decoding/rebuilding its rows. An unacknowledged Apply must
    // still time out if the helper only replays the preceding review.
    if ([notification.object isEqual:self.lastResponseObject]) {
        if (!self.applying || self.applyAcknowledged) self.lastResponse = NSDate.date;
        return nil;
    }
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 262144) return nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *value = decoded;
    if (![value[@"version"] isEqual:@1] || ![value[@"request"] isEqual:self.requestID] ||
        ![value[@"revision"] isKindOfClass:NSNumber.class] || booleanValue(value[@"revision"]) ||
        [value[@"revision"] doubleValue] < 0 || floor([value[@"revision"] doubleValue]) != [value[@"revision"] doubleValue] ||
        ![value[@"message"] isKindOfClass:NSString.class] || ![value[@"state"] isKindOfClass:NSString.class] ||
        ![value[@"cuts"] isKindOfClass:NSArray.class] || [value[@"cuts"] count] > 2000 || !booleanValue(value[@"canApply"])) return nil;
    if (self.revision && [value[@"revision"] compare:self.revision] == NSOrderedAscending) return nil;
    if (self.applying) {
        BOOL terminal = CutdownReviewStateIsTerminal(value[@"state"]);
        if ([value[@"revision"] compare:self.applyRevision] != NSOrderedDescending ||
            (!terminal && ![value[@"state"] isEqual:CutdownReviewStateApplying])) return nil;
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
    if (self.pendingRetry && [self.revision compare:self.pendingRetry[@"expectedRevision"]] == NSOrderedDescending) self.pendingRetry = nil;
    if (self.pendingPreview && [self.revision compare:self.previewRevision] == NSOrderedDescending &&
        (![value[@"state"] isEqual:CutdownReviewStateReview] || [value[@"previewVisible"] isEqual:self.pendingPreview[@"included"]])) self.pendingPreview = nil;
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
        if (matches || ![value[@"state"] isEqual:CutdownReviewStateReview]) self.pendingSelection = nil;
    }
    return value;
}
@end
