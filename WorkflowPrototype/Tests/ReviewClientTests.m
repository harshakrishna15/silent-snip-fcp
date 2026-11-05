#import <Foundation/Foundation.h>
#import "../Extension/WorkflowReviewClient.h"
#import <stdio.h>
#import <stdlib.h>

@interface SSWorkflowReviewClient (OfflineTesting)
- (NSDate *)now;
- (NSArray<NSURL *> *)registeredHelperURLs;
- (NSURL *)siblingHelperURL;
- (NSDictionary *)helperInfoAtURL:(NSURL *)url;
- (void)openHelperAtURL:(NSURL *)url completion:(void (^)(NSError *))completion;
- (void)openAnalysisURL:(NSURL *)request helper:(NSURL *)url completion:(void (^)(NSError *))completion;
- (void)beginObserving;
- (void)endObserving;
- (void)startPolling;
- (void)postObject:(NSString *)object name:(NSString *)name;
- (void)receive:(NSNotification *)notification;
- (void)receiveCapability:(NSNotification *)notification;
- (void)poll;
@end

@interface SSOfflineClient : SSWorkflowReviewClient
@property (nonatomic, strong) NSDate *clock;
@property (nonatomic, copy) NSArray<NSURL *> *apps;
@property (nonatomic, strong) NSURL *sibling;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *infos;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *updates;
@property (nonatomic, strong) NSMutableArray<NSString *> *failures;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *posts;
@property (nonatomic, strong) NSURL *launchedHelper;
@property (nonatomic, strong) NSURL *launchedRequest;
@property (nonatomic) NSUInteger helperLaunches;
@property (nonatomic) NSUInteger analysisLaunches;
@property (nonatomic) NSUInteger pollingStarts;
@property (nonatomic) BOOL attached;
- (instancetype)initForTests;
@end

@implementation SSOfflineClient
- (instancetype)initForTests {
    NSMutableArray *updates = [NSMutableArray new], *failures = [NSMutableArray new];
    self = [super initWithViewID:@"2686A7A1-BC05-4885-82A2-C9EE8A096F45"
        update:^(NSDictionary *value) { [updates addObject:value]; }
        failure:^(NSString *value) { [failures addObject:value]; }];
    if (self) {
        _updates = updates; _failures = failures;
        _events = [NSMutableArray new]; _posts = [NSMutableArray new];
        _infos = [NSMutableDictionary new]; _clock = NSDate.date;
    }
    return self;
}
- (NSDate *)now { return self.clock; }
- (NSArray<NSURL *> *)registeredHelperURLs { return self.apps; }
- (NSURL *)siblingHelperURL { return self.sibling; }
- (NSDictionary *)helperInfoAtURL:(NSURL *)url {
    id value = self.infos[url.path];
    return value == NSNull.null ? nil : value ?: @{};
}
- (void)openHelperAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    [self.events addObject:@"helper"];
    self.launchedHelper = url; self.helperLaunches += 1;
    completion(nil);
}
- (void)openAnalysisURL:(NSURL *)request helper:(NSURL *)url completion:(void (^)(NSError *))completion {
    [self.events addObject:@"analysis"];
    self.launchedHelper = url; self.launchedRequest = request; self.analysisLaunches += 1;
    completion(nil);
}
- (void)beginObserving { self.attached = YES; [self.events addObject:@"observe"]; }
- (void)endObserving { self.attached = NO; [self.events addObject:@"detach"]; }
- (void)startPolling { self.pollingStarts += 1; }
- (void)postObject:(NSString *)object name:(NSString *)name {
    id packet = [NSJSONSerialization JSONObjectWithData:[object dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    [self.posts addObject:@{@"name": name, @"packet": packet ?: NSNull.null}];
}
@end

static NSUInteger checks, groups;
static void require(BOOL condition, NSString *message) {
    checks += 1;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(EXIT_FAILURE); }
}
static NSDictionary *helperInfo(void) {
    return @{@"CFBundleIdentifier": @"local.silentsnip.app", @"CFBundleExecutable": @"SilentSnip",
        @"SilentSnipWorkflowProtocolVersion": @1, @"com.apple.proapps.MediaAssetProtocol": @{},
        @"CFBundleURLTypes": @[@{@"CFBundleURLSchemes": @[@"silentsnip"]}]};
}
static NSDictionary *settings(void) {
    return @{@"thresholdDBFS": @-47, @"minimumSilenceDuration": @0.1,
        @"beforeSpeechPadding": @0.05, @"afterSpeechPadding": @0.05, @"outputMode": @"gaps"};
}
static SSOfflineClient *client(void) {
    SSOfflineClient *value = [[SSOfflineClient alloc] initForTests];
    value.sibling = [NSURL fileURLWithPath:@"/Test/Applications/Silent Snip.app"];
    value.apps = @[value.sibling]; value.infos[value.sibling.path] = helperInfo();
    return value;
}
static BOOL start(SSOfflineClient *client, NSDictionary *value) {
    return [client startWithLibraryURL:[NSURL fileURLWithPath:@"/Test/Cutdown Integration.fcpbundle"]
        projectUID:@"project-A" projectName:@"Project & 20%" settings:value
        gesture:@"EA97943A-27BB-48BE-BB14-FB4F30314D52"];
}
static NSDictionary *cut(BOOL included) {
    return @{@"id": @"cut-1", @"start": @"00:00:01:00", @"end": @"00:00:02:00", @"duration": @"1.000s",
        @"eligible": @YES, @"included": @(included)};
}
static NSMutableDictionary *response(SSOfflineClient *client, NSInteger revision, NSString *state, BOOL included) {
    BOOL review = [state isEqual:@"review"];
    return [@{@"version": @1, @"request": client.requestID, @"revision": @(revision), @"state": state,
        @"message": @"Status\nwith details", @"summary": @"One candidate", @"targetClipName": @"Narration",
        @"cuts": @[cut(included)], @"canApply": review && included ? @YES : @NO, @"canChangeSelection": @(review),
        @"canCancel": @YES, @"canHighlight": @NO, @"canRetryVerification": @NO} mutableCopy];
}
static NSNotification *notification(NSDictionary *value, NSDictionary *userInfo) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return [NSNotification notificationWithName:@"test" object:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] userInfo:userInfo];
}
static void deliver(SSOfflineClient *client, NSDictionary *value) { [client receive:notification(value, nil)]; }
static NSUInteger commandCount(SSOfflineClient *client, NSString *name) {
    NSUInteger count = 0;
    for (NSDictionary *post in client.posts) if ([post[@"packet"][@"command"] isEqual:name]) count += 1;
    return count;
}
static NSDictionary *capabilityReply(SSOfflineClient *client) {
    NSDictionary *query = client.posts.lastObject[@"packet"];
    return @{@"version": @1, @"view": query[@"view"], @"nonce": query[@"nonce"], @"protocol": @1};
}
static void finish(SSOfflineClient *client) {
    [client detach];
    require(!client.attached && !client.requestID && !client.canApply && !client.busy,
        @"Detaching removes the owned request and capabilities without a new command");
}

static void targetedLaunchAndURLBinding(void) {
    SSOfflineClient *c = client();
    NSURL *buildCopy = [NSURL fileURLWithPath:@"/Test/Repo/build/App/Silent Snip.app"];
    c.apps = @[buildCopy, c.sibling]; c.infos[buildCopy.path] = helperInfo();
    require(start(c, settings()), @"A verified installed sibling can start a request");
    require([c.launchedHelper isEqual:c.sibling] && c.analysisLaunches == 1 && c.helperLaunches == 0,
        @"The registered installed sibling wins over a supported repo build copy");
    require([c.events indexOfObject:@"observe"] < [c.events indexOfObject:@"analysis"], @"Observers attach before the one analysis dispatch");
    NSURLComponents *parts = [NSURLComponents componentsWithURL:c.launchedRequest resolvingAgainstBaseURL:NO];
    NSMutableDictionary *fields = [NSMutableDictionary new];
    for (NSURLQueryItem *item in parts.queryItems) fields[item.name] = item.value;
    require([parts.scheme isEqual:@"silentsnip"] && [parts.host isEqual:@"workflow-analyze"] && fields.count == 11,
        @"The request uses the dedicated bounded workflow URL contract");
    require([fields[@"project"] isEqual:@"project-A"] && [fields[@"projectName"] isEqual:@"Project & 20%"] &&
        [fields[@"view"] isEqual:@"2686A7A1-BC05-4885-82A2-C9EE8A096F45"] &&
        [fields[@"gesture"] isEqual:@"EA97943A-27BB-48BE-BB14-FB4F30314D52"] &&
        [fields[@"request"] isEqual:c.requestID] && [fields[@"output"] isEqual:@"gaps"],
        @"Project, settings, view, and native gesture survive URL encoding exactly");
    require(c.busy && !c.canApply, @"Launching cannot enable Apply before a validated review");
    deliver(c, response(c, 1, @"review", YES));
    if (c.busy || !c.canApply || !c.canChangeSelection) fprintf(stderr, "Review state: busy=%d apply=%d selection=%d updates=%s\n",
        c.busy, c.canApply, c.canChangeSelection, c.updates.description.UTF8String);
    require(!c.busy && c.canApply && c.canChangeSelection, @"A valid current review enables its capabilities");
    finish(c); groups += 1;
}

static void invalidPreflightNeverDispatches(void) {
    for (id protocol in @[@0, @2, @YES, @"1", NSNull.null]) {
        SSOfflineClient *c = client(); NSMutableDictionary *info = [helperInfo() mutableCopy];
        info[@"SilentSnipWorkflowProtocolVersion"] = protocol; c.infos[c.sibling.path] = info;
        require(!start(c, settings()) && c.analysisLaunches == 0 && c.helperLaunches == 0 && c.failures.count == 1,
            @"Old, boolean, string, and unsupported readable protocol values fail before launch");
        finish(c);
    }
    for (NSString *key in @[@"CFBundleExecutable", @"CFBundleURLTypes", @"com.apple.proapps.MediaAssetProtocol"]) {
        SSOfflineClient *c = client(); NSMutableDictionary *info = [helperInfo() mutableCopy]; [info removeObjectForKey:key]; c.infos[c.sibling.path] = info;
        require(!start(c, settings()) && c.analysisLaunches == 0, @"Missing executable or active routes cannot authorize launch"); finish(c);
    }
    for (id bad in @[@-81, @YES, @(INFINITY), @(NAN), @"-40"]) {
        SSOfflineClient *c = client(); NSMutableDictionary *value = [settings() mutableCopy]; value[@"thresholdDBFS"] = bad;
        require(!start(c, value) && c.analysisLaunches == 0 && !c.requestID, @"Invalid settings cannot become an unanswered worker request"); finish(c);
    }
    SSOfflineClient *c = client();
    require(![c startWithLibraryURL:[NSURL URLWithString:@"https://example.invalid/Cutdown.fcpbundle"] projectUID:@"p"
        projectName:@"P" settings:settings() gesture:@"EA97943A-27BB-48BE-BB14-FB4F30314D52"], @"A nonlocal library cannot start Analyze");
    finish(c); groups += 1;
}

static void helperAmbiguityAndOldInstalledCopy(void) {
    SSOfflineClient *c = client(); NSURL *other = [NSURL fileURLWithPath:@"/Test/Other/Silent Snip.app"];
    c.apps = @[c.sibling, other]; c.infos[other.path] = helperInfo(); c.infos[c.sibling.path] = @{};
    require(!start(c, settings()) && c.analysisLaunches == 0, @"An old installed sibling cannot silently fall back to a supported build copy"); finish(c);
    c = client(); c.sibling = nil;
    c.apps = @[[NSURL fileURLWithPath:@"/Test/One/Silent Snip.app"], other];
    for (NSURL *url in c.apps) c.infos[url.path] = helperInfo();
    require(!start(c, settings()), @"Two supported registered copies without an installed sibling are ambiguous"); finish(c);
    c = client(); c.sibling = nil;
    NSURL *old = [NSURL fileURLWithPath:@"/Test/Old/Silent Snip.app"];
    c.apps = @[old, other]; c.infos[old.path] = @{}; c.infos[other.path] = helperInfo();
    require(start(c, settings()) && [c.launchedHelper isEqual:other], @"A single supported registered copy remains usable after excluding readable old copies");
    finish(c); groups += 1;
}

static void malformedResponsesDoNotReachUI(void) {
    SSOfflineClient *c = client(); require(start(c, settings()), @"Response fixture starts"); deliver(c, response(c, 1, @"review", YES));
    NSUInteger count = c.updates.count;
    NSDictionary *bad = @{@"summary": NSNull.null, @"targetClipName": @4, @"canCancel": @1,
        @"canChangeSelection": @"true", @"canRetryVerification": NSNull.null, @"progress": @1.5,
        @"version": @YES, @"revision": @YES, @"state": @"invented", @"message": NSNull.null};
    for (NSString *key in bad) { NSMutableDictionary *packet = response(c, 2, @"review", YES); packet[key] = bad[key]; deliver(c, packet); }
    NSMutableDictionary *packet = response(c, 2, @"review", YES); packet[@"cuts"] = @[cut(YES), cut(YES)]; deliver(c, packet);
    [c receive:notification(response(c, 2, @"review", YES), @{@"untrusted": @YES})];
    require(c.updates.count == count && c.canApply, @"Malformed optional values, flags, duplicate IDs, and userInfo cannot reach the UI or replace a valid review");
    packet = response(c, 2, @"review", YES); packet[@"progress"] = @0.5; deliver(c, packet);
    require(c.updates.count == count + 1, @"A valid finite progress value and multiline message remain accepted");
    finish(c); groups += 1;
}

static void selectionNeedsExactNewAcknowledgment(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    require([c setCut:@"cut-1" included:NO] && !c.canApply && !c.canChangeSelection && !c.busy,
        @"A pending row choice blocks Apply without classifying a review edit as a host job");
    NSDictionary *command = c.posts.lastObject[@"packet"];
    require([command[@"command"] isEqual:@"include"] && [command[@"expectedRevision"] isEqual:@1] && [command[@"included"] isEqual:@NO],
        @"Selection command binds the exact revision and choice");
    require(![c selectAll:YES] && ![c sendApplyWithGesture:NSUUID.UUID.UUIDString], @"Pending selection cannot be overtaken by another choice or Apply");
    deliver(c, response(c, 1, @"review", NO)); require(!c.canChangeSelection, @"Equal revisions are not selection acknowledgments");
    deliver(c, response(c, 2, @"review", YES)); require(!c.canChangeSelection, @"A newer mismatched choice is not an acknowledgment");
    deliver(c, response(c, 3, @"review", NO)); require(c.canChangeSelection && !c.canApply, @"A newer exact choice acknowledges the row, retaining the no-selected-cuts Apply guard");
    require([c selectAll:YES], @"Select All can follow its preceding acknowledgment"); deliver(c, response(c, 4, @"review", YES));
    require(c.canApply, @"Acknowledged Select All enables Apply for the reviewed selection");
    finish(c); groups += 1;
}

static void applyRetriesOnlyTheOwnedCommand(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    NSString *gesture = NSUUID.UUID.UUIDString;
    require([c sendApplyWithGesture:gesture] && c.busy && !c.canApply, @"Apply consumes local review capabilities before posting");
    NSDictionary *apply = c.posts.lastObject[@"packet"];
    require([apply[@"expectedRevision"] isEqual:@1] && [apply[@"applyGesture"] isEqual:gesture] &&
        [apply[@"view"] isEqual:@"2686A7A1-BC05-4885-82A2-C9EE8A096F45"], @"Apply carries the exact native gesture and reviewed revision");
    require(![c sendApplyWithGesture:NSUUID.UUID.UUIDString], @"Another click cannot create a second Apply command");
    [c poll]; require(commandCount(c, @"apply") == 2, @"Before acknowledgment only the same owned Apply packet is retried");
    deliver(c, response(c, 2, @"review", YES)); require(c.busy && !c.canApply, @"A replayed review cannot revive an in-flight Apply");
    deliver(c, response(c, 2, @"applying", YES)); [c poll];
    require(commandCount(c, @"apply") == 2 && c.busy, @"An applying acknowledgment stops all Apply retransmission");
    deliver(c, response(c, 3, @"completed", YES)); NSUInteger count = c.updates.count;
    deliver(c, response(c, 4, @"review", YES));
    require(!c.busy && !c.canApply && !c.canCancel && c.updates.count == count,
        @"A completed outcome is immutable and no delayed review can re-enable it");
    finish(c); groups += 1;
}

static void retryVerificationDoesNotApplyAgain(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString]; NSMutableDictionary *failed = response(c, 2, @"failed", YES);
    failed[@"canRetryVerification"] = @YES; deliver(c, failed);
    require([c retryVerification] && c.busy && !c.canApply, @"Only a recoverable terminal result permits explicit verification retry");
    require([c.posts.lastObject[@"packet"][@"command"] isEqual:@"retryVerification"] &&
        [c.posts.lastObject[@"packet"][@"expectedRevision"] isEqual:@2], @"Verification retry is revision-bound");
    deliver(c, response(c, 3, @"review", YES)); require(c.busy && !c.canApply, @"A retry cannot transition to editable review");
    deliver(c, response(c, 3, @"verifying", YES)); deliver(c, response(c, 4, @"completed", YES));
    require(commandCount(c, @"apply") == 1 && !c.canApply && ![c retryVerification], @"Verification recovery never creates another Apply/import command");
    finish(c); groups += 1;
}

static void freshCapabilityNonceBeforeAnyAnalysis(void) {
    SSOfflineClient *c = client(); c.infos[c.sibling.path] = NSNull.null;
    require(start(c, settings()) && c.helperLaunches == 1 && c.analysisLaunches == 0,
        @"Unreadable external metadata launches only the pinned background helper first");
    NSDictionary *reply = capabilityReply(c); NSMutableDictionary *wrong = [reply mutableCopy]; wrong[@"nonce"] = NSUUID.UUID.UUIDString;
    [c receiveCapability:notification(wrong, nil)]; require(c.analysisLaunches == 0, @"A stale capability nonce cannot dispatch Analyze");
    wrong = [reply mutableCopy]; wrong[@"protocol"] = @YES; [c receiveCapability:notification(wrong, nil)];
    require(c.analysisLaunches == 0, @"A boolean protocol cannot satisfy capability negotiation");
    [c receiveCapability:notification(reply, nil)]; require(c.analysisLaunches == 1, @"Only the fresh matching capability permits the one analysis URL");
    [c receiveCapability:notification(reply, nil)]; require(c.analysisLaunches == 1, @"Capability replay cannot dispatch again");
    finish(c);
    c = client(); c.infos[c.sibling.path] = NSNull.null; start(c, settings()); reply = capabilityReply(c);
    c.clock = [c.clock dateByAddingTimeInterval:6]; [c poll];
    [c receiveCapability:notification(reply, nil)];
    require(c.failures.count == 1 && c.analysisLaunches == 0 && !c.busy, @"A late capability after timeout cannot restart a failed connection");
    finish(c);
    c = client(); c.infos[c.sibling.path] = NSNull.null; start(c, settings()); reply = capabilityReply(c);
    [c cancel]; [c receiveCapability:notification(reply, nil)];
    require(c.analysisLaunches == 0 && !c.busy && [c.updates.lastObject[@"state"] isEqual:@"cancelled"],
        @"Cancel before capability completion is local and prevents any analysis URL");
    require(commandCount(c, @"cancel") == 0, @"No worker command is invented for an analysis that never started");
    finish(c); groups += 1;
}

static void timeoutCannotReviveReview(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString]; c.clock = [c.clock dateByAddingTimeInterval:20]; [c poll];
    require(c.failures.count == 1 && !c.canApply && !c.busy, @"An unacknowledged Apply times out without new authority");
    deliver(c, response(c, 20, @"review", YES)); require(!c.canApply, @"Late progress/review cannot revive a consumed local review");
    deliver(c, response(c, 21, @"completed", YES));
    require([c.updates.lastObject[@"state"] isEqual:@"completed"] && !c.canApply, @"The real terminal outcome remains observable after a local timeout");
    finish(c); groups += 1;
}

int main(void) {
    @autoreleasepool {
        targetedLaunchAndURLBinding(); invalidPreflightNeverDispatches(); helperAmbiguityAndOldInstalledCopy();
        malformedResponsesDoNotReachUI(); selectionNeedsExactNewAcknowledgment(); applyRetriesOnlyTheOwnedCommand();
        retryVerificationDoesNotApplyAgain(); freshCapabilityNonceBeforeAnyAnalysis(); timeoutCannotReviveReview();
        printf("Passed %lu review-client groups (%lu assertions); no real helper launch, DNC, timers, windows, or settings files.\n",
            (unsigned long)groups, (unsigned long)checks);
    }
    return EXIT_SUCCESS;
}
