#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "../Extension/WorkflowReviewClient.h"
#import <stdio.h>
#import <stdlib.h>
#import <objc/runtime.h>

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
- (void)receiveConnection:(NSNotification *)notification;
- (void)poll;
- (void)publish;
- (void)activateHostForUserRequest:(void (^)(NSError *))completion;
- (NSArray<NSRunningApplication *> *)runningHostApplications;
- (NSRunningApplication *)frontmostApplication;
- (BOOL)requestActivationOfHost:(NSRunningApplication *)host;
- (NSTimeInterval)activationUptime;
- (void)scheduleActivationCheck:(void (^)(void))check;
- (BOOL)application:(NSRunningApplication *)app matchesPinnedURL:(NSURL *)url;
@end

@interface SSFakeHost : NSObject
@property (nonatomic, copy) NSString *bundleIdentifier;
@property (nonatomic) pid_t processIdentifier;
@property (nonatomic, getter=isTerminated) BOOL terminated;
@property (nonatomic, strong) NSURL *bundleURL;
@property (nonatomic, strong) NSURL *executableURL;
@end
@implementation SSFakeHost
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
@property (nonatomic, strong) NSError *helperError;
@property (nonatomic) NSUInteger analysisLaunches;
@property (nonatomic) NSUInteger pollingStarts;
@property (nonatomic) BOOL attached;
@property (nonatomic) NSUInteger activationRequests;
@property (nonatomic) BOOL deferActivation;
@property (nonatomic) BOOL useDefaultActivationPolicy;
@property (nonatomic, strong) NSError *activationError;
@property (nonatomic, strong) NSMutableArray<void (^)(NSError *)> *activationCompletions;
@property (nonatomic, copy) NSArray *fakeHosts;
@property (nonatomic, strong) SSFakeHost *fakeFront;
@property (nonatomic) NSTimeInterval fakeUptime;
@property (nonatomic) BOOL activationAccepted;
@property (nonatomic) NSUInteger hostActivationRequests;
@property (nonatomic, strong) NSMutableArray<void (^)(void)> *scheduledActivationChecks;
@property (nonatomic, copy) void (^afterPublish)(void);
- (instancetype)initForTests;
- (void)completeActivation:(NSError *)error;
- (void)runActivationCheck;
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
        _activationCompletions = [NSMutableArray new]; _scheduledActivationChecks = [NSMutableArray new];
        _activationAccepted = YES;
    }
    return self;
}
- (NSDate *)now { return self.clock; }
- (void)activateHostForUserRequest:(void (^)(NSError *))completion {
    self.activationRequests += 1; [self.events addObject:@"activate"];
    if (self.useDefaultActivationPolicy) { [super activateHostForUserRequest:completion]; return; }
    if (self.deferActivation) [self.activationCompletions addObject:[completion copy]];
    else completion(self.activationError);
}
- (void)completeActivation:(NSError *)error {
    void (^completion)(NSError *) = self.activationCompletions.firstObject;
    [self.activationCompletions removeObjectAtIndex:0];
    completion(error);
}
- (NSArray<NSRunningApplication *> *)runningHostApplications { return (id)self.fakeHosts; }
- (NSRunningApplication *)frontmostApplication { return (id)self.fakeFront; }
- (BOOL)requestActivationOfHost:(NSRunningApplication *)host { self.hostActivationRequests += 1; return self.activationAccepted; }
- (NSTimeInterval)activationUptime { return self.fakeUptime; }
- (void)scheduleActivationCheck:(void (^)(void))check { [self.scheduledActivationChecks addObject:[check copy]]; }
- (void)runActivationCheck {
    void (^check)(void) = self.scheduledActivationChecks.firstObject;
    [self.scheduledActivationChecks removeObjectAtIndex:0];
    check();
}
- (NSArray<NSURL *> *)registeredHelperURLs { return self.apps; }
- (NSURL *)siblingHelperURL { return self.sibling; }
- (NSDictionary *)helperInfoAtURL:(NSURL *)url {
    id value = self.infos[url.path];
    return value == NSNull.null ? nil : value ?: @{};
}
- (void)openHelperAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    [self.events addObject:@"helper"];
    self.launchedHelper = url; self.helperLaunches += 1;
    completion(self.helperError);
}
- (void)openAnalysisURL:(NSURL *)request helper:(NSURL *)url completion:(void (^)(NSError *))completion {
    [self.events addObject:@"analysis"];
    self.launchedHelper = url; self.launchedRequest = request; self.analysisLaunches += 1;
    completion(nil);
}
- (void)beginObserving { self.attached = YES; [self.events addObject:@"observe"]; }
- (void)endObserving { self.attached = NO; [self.events addObject:@"detach"]; }
- (void)startPolling { self.pollingStarts += 1; }
- (void)publish { [super publish]; if (self.afterPublish) self.afterPublish(); }
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
    NSMutableDictionary *value = [@{@"version": @1, @"request": client.requestID, @"revision": @(revision), @"state": state,
        @"message": @"Status\nwith details", @"summary": @"One candidate", @"targetClipName": @"Narration",
        @"cuts": @[cut(included)], @"canApply": review && included ? @YES : @NO, @"canChangeSelection": @(review),
        @"canCancel": @YES, @"canHighlight": @NO, @"canRetryVerification": @NO} mutableCopy];
    if ([client.launchedRequest.host isEqual:@"workflow-verify"]) {
        NSURLComponents *parts = [NSURLComponents componentsWithURL:client.launchedRequest resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in parts.queryItems) if ([item.name isEqual:@"gesture"]) value[@"workflowGesture"] = item.value;
    }
    return value;
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
    require(c.activationRequests == 2 && [c.events indexOfObject:@"activate"] < [c.events indexOfObject:@"analysis"],
        @"Analyze activates the host after preflight and again immediately before its one URL dispatch");
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

static void quietWindowPreparationUsesOnlyThePinnedHelper(void) {
    SSOfflineClient *c = client();
    NSURL *buildCopy = [NSURL fileURLWithPath:@"/Test/Repo/build/App/Silent Snip.app"];
    c.apps = @[buildCopy, c.sibling]; c.infos[buildCopy.path] = helperInfo();
    __block BOOL completed = NO;
    __block NSError *failure;
    [c prepareWindowHelper:^(NSError *error) { completed = YES; failure = error; }];
    require(completed && !failure && c.helperLaunches == 1 && [c.launchedHelper isEqual:c.sibling] &&
        c.analysisLaunches == 0 && c.activationRequests == 0 && c.posts.count == 0 && c.pollingStarts == 0 &&
        !c.attached && !c.requestID && !c.busy && c.updates.count == 0 && c.failures.count == 0,
        @"Quiet sizing preparation launches the pinned installed sibling without activating, analyzing, or creating review state");
    SSFakeHost *launched = [SSFakeHost new];
    launched.bundleIdentifier = @"local.silentsnip.app";
    launched.bundleURL = c.sibling;
    launched.executableURL = [c.sibling URLByAppendingPathComponent:@"Contents/MacOS/SilentSnip"];
    require([c application:(id)launched matchesPinnedURL:c.sibling], @"The launched helper must match its bundle, canonical installation, and executable");
    launched.bundleURL = buildCopy;
    require(![c application:(id)launched matchesPinnedURL:c.sibling], @"A launched build copy cannot satisfy the installed helper pin");
    launched.bundleURL = c.sibling; launched.executableURL = [c.sibling URLByAppendingPathComponent:@"Contents/MacOS/Other"];
    require(![c application:(id)launched matchesPinnedURL:c.sibling], @"An unexpected launched executable cannot satisfy the pin");
    launched.executableURL = [c.sibling URLByAppendingPathComponent:@"Contents/MacOS/SilentSnip"];
    launched.bundleIdentifier = @"example.unrelated";
    require(![c application:(id)launched matchesPinnedURL:c.sibling], @"An unrelated launched bundle cannot satisfy the pin");
    finish(c);

    c = client(); c.apps = @[]; failure = nil; completed = NO;
    [c prepareWindowHelper:^(NSError *error) { completed = YES; failure = error; }];
    require(completed && failure && c.helperLaunches == 0 && c.analysisLaunches == 0 && c.activationRequests == 0,
        @"An unregistered neighboring helper cannot authorize quiet launch");
    finish(c);

    c = client(); c.apps = @[buildCopy, c.sibling]; c.infos[buildCopy.path] = helperInfo();
    NSMutableDictionary *old = [helperInfo() mutableCopy]; old[@"SilentSnipWorkflowProtocolVersion"] = @2;
    c.infos[c.sibling.path] = old; failure = nil;
    [c prepareWindowHelper:^(NSError *error) { failure = error; }];
    require(failure && c.helperLaunches == 0 && c.activationRequests == 0,
        @"An incompatible pinned installation cannot silently fall back to a compatible build copy");
    finish(c);

    c = client(); c.helperError = [NSError errorWithDomain:@"test.quiet-launch" code:7 userInfo:nil]; failure = nil;
    [c prepareWindowHelper:^(NSError *error) { failure = error; }];
    require(failure == c.helperError && c.helperLaunches == 1 && c.analysisLaunches == 0 && c.activationRequests == 0 &&
        c.updates.count == 0 && c.failures.count == 0, @"A quiet launcher error returns only to its lease owner without changing review UI state");
    finish(c); groups += 1;
}

static void invalidPreflightNeverDispatches(void) {
    for (id protocol in @[@0, @2, @YES, @"1", NSNull.null]) {
        SSOfflineClient *c = client(); NSMutableDictionary *info = [helperInfo() mutableCopy];
        info[@"SilentSnipWorkflowProtocolVersion"] = protocol; c.infos[c.sibling.path] = info;
        require(!start(c, settings()) && c.analysisLaunches == 0 && c.helperLaunches == 0 && c.activationRequests == 0 && c.failures.count == 1,
            @"Old, boolean, string, and unsupported readable protocol values fail before launch");
        finish(c);
    }
    for (NSString *key in @[@"CFBundleExecutable", @"CFBundleURLTypes", @"com.apple.proapps.MediaAssetProtocol"]) {
        SSOfflineClient *c = client(); NSMutableDictionary *info = [helperInfo() mutableCopy]; [info removeObjectForKey:key]; c.infos[c.sibling.path] = info;
        require(!start(c, settings()) && c.analysisLaunches == 0 && c.activationRequests == 0, @"Missing executable or active routes cannot activate or launch"); finish(c);
    }
    for (id bad in @[@-81, @YES, @(INFINITY), @(NAN), @"-40"]) {
        SSOfflineClient *c = client(); NSMutableDictionary *value = [settings() mutableCopy]; value[@"thresholdDBFS"] = bad;
        require(!start(c, value) && c.analysisLaunches == 0 && c.activationRequests == 0 && !c.requestID,
            @"Invalid settings cannot activate an app or become an unanswered worker request"); finish(c);
    }
    SSOfflineClient *c = client();
    require(![c startWithLibraryURL:[NSURL URLWithString:@"https://example.invalid/Cutdown.fcpbundle"] projectUID:@"p"
        projectName:@"P" settings:settings() gesture:@"EA97943A-27BB-48BE-BB14-FB4F30314D52"], @"A nonlocal library cannot start Analyze");
    require(c.activationRequests == 0, @"Invalid project input never requests host activation");
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

static NSDate *cancelTestClock;
static id cancelTestDate(id receiver, SEL selector) { return cancelTestClock; }
static void cancellationRetriesUntilTerminalAcknowledgment(void) {
    // The shared connection timestamps heartbeats with NSDate.date. Advance
    // both sides of this offline transport together without real sleeps.
    cancelTestClock = NSDate.date;
    Method dateMethod = class_getClassMethod(NSDate.class, @selector(date));
    IMP originalDate = method_setImplementation(dateMethod, (IMP)cancelTestDate);
    @try {
        SSOfflineClient *c = client(); start(c, settings());
        NSDictionary *heartbeat = response(c, 1, @"review", YES);
        deliver(c, heartbeat); require(!c.busy && c.canCancel, @"A ready review can be cancelled");
        [c cancel];
        NSDictionary *cancel = c.posts.lastObject[@"packet"];
        require(commandCount(c, @"cancel") == 1 && [cancel[@"request"] isEqual:c.requestID],
            @"The first cancellation is bound to the current request");
        // Drop that first Cancel. The old review can still arrive as a healthy
        // heartbeat, but must not consume the pending cancellation.
        for (NSUInteger step = 0; step < 20; step++) {
            cancelTestClock = [cancelTestClock dateByAddingTimeInterval:2]; c.clock = cancelTestClock;
            deliver(c, heartbeat); [c poll];
        }
        require(commandCount(c, @"cancel") == 21 && commandCount(c, @"status") == 20 &&
            c.failures.count == 0 && c.busy && !c.canApply && !c.canCancel,
            @"Healthy unchanged heartbeats keep retrying a lost Cancel without restoring review actions");
        for (NSDictionary *post in c.posts) if ([post[@"packet"][@"command"] isEqual:@"cancel"])
            require([post[@"packet"] isEqual:cancel], @"Every cancellation retry is the same idempotent request-bound packet");
        NSMutableDictionary *wrong = response(c, 2, @"cancelled", NO); wrong[@"request"] = NSUUID.UUID.UUIDString;
        deliver(c, wrong); [c poll];
        require(commandCount(c, @"cancel") == 22 && c.busy, @"A terminal response for another request cannot acknowledge Cancel");
        deliver(c, response(c, 2, @"cancelled", NO)); [c poll]; [c cancel];
        require(commandCount(c, @"cancel") == 22 && !c.busy && !c.canApply && !c.canCancel,
            @"The owned terminal acknowledgment stops cancellation retries and consumes the review");
        finish(c);

        c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
        [c sendApplyWithGesture:NSUUID.UUID.UUIDString]; [c cancel]; [c poll];
        require(commandCount(c, @"apply") == 1 && commandCount(c, @"cancel") == 2,
            @"Cancel clears an unacknowledged Apply instead of replaying the edit while retrying cancellation");
        deliver(c, response(c, 2, @"completed", NO)); [c poll];
        require(commandCount(c, @"apply") == 1 && commandCount(c, @"cancel") == 2 && !c.busy,
            @"A real completed result also acknowledges cancellation without another Apply or import");
        finish(c);

        c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES)); [c cancel];
        NSString *oldRequest = c.requestID; [c detach]; [c poll];
        require(commandCount(c, @"cancel") == 1, @"Detaching retires cancellation retries");
        require(start(c, settings()) && ![c.requestID isEqual:oldRequest], @"A fresh request has a new cancellation scope");
        [c poll]; require(commandCount(c, @"cancel") == 1, @"The old Cancel never follows a new request");
        finish(c);

        c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES)); [c cancel];
        cancelTestClock = [cancelTestClock dateByAddingTimeInterval:16]; c.clock = cancelTestClock; [c poll]; [c poll];
        require(c.failures.count == 1 && !c.busy && commandCount(c, @"cancel") == 1,
            @"A silent helper still times out and stops cancellation retransmission");
        finish(c);
    } @finally {
        method_setImplementation(dateMethod, originalDate); cancelTestClock = nil;
    }
    groups += 1;
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

static NSError *activationFailure(void) {
    return [NSError errorWithDomain:@"OfflineActivation" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Bring Final Cut Pro to the front, then try again."}];
}
static void delayedAnalyzeActivationIsCancelledSafely(void) {
    SSOfflineClient *c = client(); c.deferActivation = YES;
    require(start(c, settings()) && c.busy && c.canCancel && c.activationRequests == 1,
        @"A validated Analyze becomes busy while asynchronous host activation is pending");
    [c poll]; deliver(c, response(c, 1, @"review", YES));
    require(c.posts.count == 0 && c.helperLaunches == 0 && c.analysisLaunches == 0 && !c.canApply,
        @"Pending activation sends no status/edit/start and cannot accept a review before URL dispatch");
    [c cancel]; [c completeActivation:nil];
    require(c.activationRequests == 1 && c.analysisLaunches == 0 && c.helperLaunches == 0 && !c.busy,
        @"Cancel before the first activation completes cannot reactivate or launch a helper");
    finish(c);

    c = client(); c.deferActivation = YES; start(c, settings()); [c completeActivation:activationFailure()];
    require(c.failures.count == 1 && c.activationRequests == 1 && c.analysisLaunches == 0 && c.helperLaunches == 0,
        @"Failed initial activation prevents both helper startup and analysis URL dispatch");
    finish(c);

    c = client(); c.deferActivation = YES; start(c, settings()); [c completeActivation:nil];
    require(c.activationRequests == 2 && c.analysisLaunches == 0 && c.busy,
        @"Successful preflight activation still requires a successful dispatch-time activation");
    [c completeActivation:activationFailure()];
    require(c.analysisLaunches == 0 && c.failures.count == 1, @"Failed final activation cannot dispatch an Analyze URL");
    finish(c);

    c = client(); c.deferActivation = YES; c.infos[c.sibling.path] = NSNull.null;
    start(c, settings()); [c completeActivation:nil];
    require(c.helperLaunches == 1 && c.analysisLaunches == 0, @"Only successful activation permits pinned helper capability startup");
    NSDictionary *reply = capabilityReply(c); [c receiveCapability:notification(reply, nil)];
    require(c.activationRequests == 2 && c.analysisLaunches == 0 && c.busy,
        @"A fresh capability reply waits for dispatch-time foreground confirmation");
    NSUInteger posts = c.posts.count; [c poll];
    require(c.posts.count == posts, @"Polling is silent during dispatch-time activation");
    [c cancel]; [c completeActivation:nil]; [c receiveCapability:notification(reply, nil)];
    require(c.activationRequests == 2 && c.analysisLaunches == 0 && commandCount(c, @"cancel") == 0,
        @"Cancellation consumes a pending capability dispatch without reactivation or an invented worker command");
    finish(c);

    c = client(); c.deferActivation = YES; start(c, settings()); [c completeActivation:nil];
    [c detach]; [c completeActivation:nil];
    require(c.analysisLaunches == 0 && !c.requestID && !c.busy, @"Detach invalidates a delayed successful final activation");
    finish(c); groups += 1;
}

static void applyActivationIsRecoverableAndRevisionBound(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    c.deferActivation = YES; NSUInteger activations = c.activationRequests;
    require(![c sendApplyWithGesture:@"invalid"] && c.activationRequests == activations,
        @"Invalid Apply gestures fail before requesting activation");
    require([c sendApplyWithGesture:NSUUID.UUID.UUIDString] && c.busy && !c.canApply && !c.canChangeSelection,
        @"Pending Apply activation disables edit controls without creating an outbound Apply packet");
    NSUInteger posts = c.posts.count; [c poll];
    require(c.posts.count == posts && commandCount(c, @"apply") == 0, @"The timer cannot retry or poll a not-yet-dispatched Apply");
    [c completeActivation:activationFailure()];
    require(c.failures.count == 0 && !c.busy && c.canApply && c.canChangeSelection && commandCount(c, @"apply") == 0 &&
        [c.updates.lastObject[@"message"] containsString:@"Bring Final Cut"],
        @"Activation failure leaves the exact review usable with a recoverable message and no edit");
    NSString *gesture = NSUUID.UUID.UUIDString; [c sendApplyWithGesture:gesture]; [c completeActivation:nil];
    require(commandCount(c, @"apply") == 1 && [c.posts.lastObject[@"packet"][@"applyGesture"] isEqual:gesture],
        @"A new explicit click can successfully activate and dispatch the retained plan once");
    finish(c);

    c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES)); c.deferActivation = YES;
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString]; deliver(c, response(c, 2, @"review", YES)); [c completeActivation:nil];
    require(commandCount(c, @"apply") == 0 && c.canApply && !c.busy,
        @"A changed revision during activation requires a fresh explicit Apply instead of dispatching stale authority");
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString]; [c cancel]; [c completeActivation:nil];
    require(commandCount(c, @"apply") == 0 && commandCount(c, @"cancel") == 1 && !c.canApply,
        @"Cancel invalidates a delayed Apply activation and sends only cancellation of the existing owned request");
    finish(c); groups += 1;
}

static void retryActivationNeverCreatesAnEdit(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    NSUInteger activations = c.activationRequests;
    require(![c retryVerification] && c.activationRequests == activations,
        @"An ineligible verification retry cannot activate an application");
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString];
    NSMutableDictionary *failed = response(c, 2, @"failed", YES); failed[@"canRetryVerification"] = @YES; deliver(c, failed);
    c.deferActivation = YES;
    require([c retryVerification] && c.busy && c.canCancel, @"Explicit retry waits for activation and can be cancelled before dispatch");
    NSUInteger posts = c.posts.count; [c poll];
    require(c.posts.count == posts && commandCount(c, @"retryVerification") == 0,
        @"Pending verification activation does not send retry/status commands");
    [c completeActivation:activationFailure()];
    require(!c.busy && c.failures.count == 0 && [c.updates.lastObject[@"canRetryVerification"] isEqual:@YES] &&
        commandCount(c, @"retryVerification") == 0, @"Activation failure preserves the explicit verification recovery option");
    [c retryVerification]; [c cancel]; [c completeActivation:nil];
    require(!c.busy && commandCount(c, @"retryVerification") == 0 && commandCount(c, @"cancel") == 0,
        @"Cancel before retry dispatch preserves the terminal result without an invented edit or cancellation");
    [c retryVerification]; [c completeActivation:nil];
    require(commandCount(c, @"retryVerification") == 1 && commandCount(c, @"apply") == 1 &&
        [c.posts.lastObject[@"packet"][@"expectedRevision"] isEqual:@2],
        @"Only a later explicit successfully activated retry sends the exact retained verification revision");
    finish(c); groups += 1;
}

static SSFakeHost *fakeHost(NSString *identifier, pid_t pid) {
    SSFakeHost *host = [SSFakeHost new]; host.bundleIdentifier = identifier; host.processIdentifier = pid; return host;
}
static void publicActivationPolicyRequiresExactForeground(void) {
    SSOfflineClient *c = client(); c.useDefaultActivationPolicy = YES;
    SSFakeHost *host = fakeHost(@"com.apple.FinalCut", 123); c.fakeHosts = @[host];
    c.fakeFront = fakeHost(@"com.openai.codex", 456);
    require(start(c, settings()) && c.hostActivationRequests == 1 && c.analysisLaunches == 0 && c.busy,
        @"AppKit accepting an activation request does not prove Final Cut is frontmost");
    c.fakeFront = fakeHost(@"com.openai.codex", 123); [c runActivationCheck];
    require(c.analysisLaunches == 0 && c.busy, @"Even the pinned PID cannot pass foreground observation with another bundle identity");
    c.fakeFront = host; [c runActivationCheck];
    require(c.analysisLaunches == 1 && c.hostActivationRequests == 2 && c.scheduledActivationChecks.count == 0,
        @"Only exact host PID and identity becoming frontmost permits Analyze, including its final activation check");
    finish(c);

    c = client(); c.useDefaultActivationPolicy = YES; c.fakeHosts = @[host, fakeHost(@"com.apple.FinalCut", 124)];
    start(c, settings());
    require(c.hostActivationRequests == 0 && c.analysisLaunches == 0 && c.failures.count == 1,
        @"Ambiguous running Final Cut processes fail before activation or dispatch");
    finish(c);

    c = client(); c.useDefaultActivationPolicy = YES; c.fakeHosts = @[host]; c.fakeFront = fakeHost(@"com.openai.codex", 456);
    start(c, settings()); c.fakeUptime = 2.01; [c runActivationCheck];
    require(c.analysisLaunches == 0 && c.failures.count == 1 && c.scheduledActivationChecks.count == 0,
        @"A different foreground application fails closed at the bounded deadline without another activation request");
    finish(c);

    c = client(); c.useDefaultActivationPolicy = YES; c.fakeHosts = @[host]; c.fakeFront = host; c.activationAccepted = NO;
    start(c, settings());
    require(c.analysisLaunches == 0 && c.failures.count == 1, @"A denied public activation request never dispatches analysis");
    finish(c); groups += 1;
}

static void synchronousUIDetachCannotDispatch(void) {
    SSOfflineClient *c = client();
    __weak SSOfflineClient *weak = c;
    c.afterPublish = ^{ SSOfflineClient *owner = weak; owner.afterPublish = nil; [owner detach]; };
    start(c, settings());
    require(c.activationRequests == 0 && c.analysisLaunches == 0 && c.helperLaunches == 0 && !c.requestID,
        @"A view detaching during the activating-status update prevents the activation request itself");
    finish(c);

    c = client(); start(c, settings()); deliver(c, response(c, 1, @"review", YES));
    weak = c;
    c.afterPublish = ^{
        SSOfflineClient *owner = weak;
        if (![owner.updates.lastObject[@"message"] isEqual:@"Activating Final Cut Pro…"]) {
            owner.afterPublish = nil; [owner detach];
        }
    };
    [c sendApplyWithGesture:NSUUID.UUID.UUIDString];
    require(commandCount(c, @"apply") == 0 && !c.requestID,
        @"A view detaching during the final Apply-status update cannot send a stale or nil edit packet");
    finish(c); groups += 1;
}

static NSMutableDictionary *snapshotResponse(SSOfflineClient *c, NSInteger revision) {
    NSMutableDictionary *value = response(c, revision, @"review", YES);
    value[@"canUpdateCuts"] = @YES; value[@"canHighlight"] = @YES;
    return value;
}
static void updateCutsRetainsAndAcknowledgesSnapshot(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, snapshotResponse(c, 1));
    require(c.canUpdateCuts && c.canHighlight, @"Snapshot review exposes explicit update and navigation capabilities");
    NSUInteger launches = c.analysisLaunches;
    [c markSettingsDirty]; [c markSettingsDirty];
    require(c.canUpdateCuts && !c.canApply && !c.canHighlight && !c.canChangeSelection && !c.busy,
        @"An edited draft retains snapshot update but invalidates every stale cut action");
    require(commandCount(c, @"preview") == 1 && commandCount(c, @"recalculate") == 0 && commandCount(c, @"cancel") == 0,
        @"Repeated typing only hides the stale overlay once, retaining measurements without implicit recalculation");
    deliver(c, snapshotResponse(c, 2));
    require(!c.canApply && c.canUpdateCuts && !c.canHighlight, @"Status polling cannot revive a locally dirty review");
    NSMutableDictionary *invalid = [settings() mutableCopy]; invalid[@"minimumSilenceDuration"] = @YES;
    require(![c updateCutsWithSettings:invalid gesture:NSUUID.UUID.UUIDString] && commandCount(c, @"recalculate") == 0,
        @"Invalid update settings cannot dispatch a recalculation");
    NSString *edit = NSUUID.UUID.UUIDString;
    require([c updateCutsWithSettings:settings() gesture:edit] && c.busy && !c.canApply && !c.canUpdateCuts,
        @"Only explicit Update Cuts submits the edited snapshot and consumes its actions");
    NSDictionary *command = c.posts.lastObject[@"packet"];
    require([command[@"command"] isEqual:@"recalculate"] && [command[@"settingsEdit"] isEqual:edit] &&
        [command[@"expectedRevision"] isEqual:@2] && [command[@"settingsSequence"] isEqual:@1] &&
        [command[@"localPreview"] isEqual:@YES] && [command[@"verifySettings"] isEqual:@YES] &&
        [command[@"settings"][@"threshold"] isEqual:settings()[@"thresholdDBFS"]] &&
        [command[@"output"] isEqual:@"gaps"], @"Recalculation pins immutable settings, output, edit identity and review revision");
    require([c.updates.lastObject[@"updateCutsAvailable"] isEqual:@YES], @"UI can retain its pending native Update marker while actions are busy");
    [c poll]; require(commandCount(c, @"recalculate") == 2 && c.analysisLaunches == launches,
        @"Dropped update packets retry the same command without another Analyze URL or Share request");
    deliver(c, snapshotResponse(c, 3)); require(c.busy && !c.canApply, @"An unrelated status cannot acknowledge this settings edit");
    NSMutableDictionary *ack = snapshotResponse(c, 3); ack[@"settingsEdit"] = edit; deliver(c, ack);
    require(!c.busy && c.canApply && c.canUpdateCuts && c.canHighlight,
        @"The exact newer settings-edit acknowledgment restores current review authority");
    [c markSettingsDirty]; [c updateCutsWithSettings:settings() gesture:NSUUID.UUID.UUIDString];
    require([c.posts.lastObject[@"packet"][@"settingsSequence"] isEqual:@2], @"Later updates use monotonically increasing edit sequence numbers");
    finish(c); groups += 1;
}
static void updateAndNavigationActivationRemainRevisionBound(void) {
    SSOfflineClient *c = client(); start(c, settings()); deliver(c, snapshotResponse(c, 1)); [c markSettingsDirty];
    c.deferActivation = YES;
    [c updateCutsWithSettings:settings() gesture:NSUUID.UUID.UUIDString]; [c completeActivation:activationFailure()];
    require(c.canUpdateCuts && !c.canApply && !c.busy && commandCount(c, @"recalculate") == 0,
        @"Failed update activation retains the draft and snapshot with no command");
    [c updateCutsWithSettings:settings() gesture:NSUUID.UUID.UUIDString]; deliver(c, snapshotResponse(c, 2)); [c completeActivation:nil];
    require(commandCount(c, @"recalculate") == 0 && c.canUpdateCuts, @"A changed revision during activation requires another explicit update");
    finish(c);
    c = client(); start(c, settings()); deliver(c, snapshotResponse(c, 1));
    require(![c highlightCut:@"missing"] && commandCount(c, @"highlight") == 0, @"An unknown cut cannot navigate");
    require([c highlightCut:@"cut-1"] && c.busy && !c.canApply, @"Go to Cut blocks conflicting actions until navigation acknowledgment");
    NSDictionary *command = c.posts.lastObject[@"packet"];
    require([command[@"command"] isEqual:@"highlight"] && [command[@"cutID"] isEqual:@"cut-1"] && [command[@"expectedRevision"] isEqual:@1],
        @"Navigation binds the exact reviewed cut and revision");
    [c poll]; [c poll]; require(commandCount(c, @"highlight") == 1 && commandCount(c, @"apply") == 0,
        @"Navigation sends once and polling cannot repeatedly move the playhead or apply edits");
    deliver(c, snapshotResponse(c, 1)); require(c.busy, @"An old heartbeat does not acknowledge navigation");
    deliver(c, response(c, 2, @"navigating", YES)); require(c.busy, @"Navigation progress retains the operation guard");
    deliver(c, snapshotResponse(c, 3)); require(!c.busy && c.canApply && c.canHighlight, @"Navigation completion restores review and inclusion choices");
    c.deferActivation = YES; [c highlightCut:@"cut-1"]; deliver(c, snapshotResponse(c, 4)); [c completeActivation:nil];
    require(commandCount(c, @"highlight") == 1, @"A changed revision during activation cannot navigate a stale cut");
    [c markSettingsDirty]; require(![c highlightCut:@"cut-1"], @"Dirty cuts remain unavailable for navigation");
    finish(c); groups += 1;
}
static NSMutableDictionary *automaticResponse(SSOfflineClient *c, NSInteger revision, NSString *state,
                                             NSDictionary *values, NSString *edit) {
    NSMutableDictionary *value = response(c, revision, state, YES);
    BOOL review = [state isEqual:@"review"];
    value[@"canUpdateCuts"] = @(review); value[@"canHighlight"] = @(review);
    value[@"automaticPreviewAvailable"] = @YES; value[@"usesAudioSnapshot"] = @YES;
    value[@"provisional"] = @([state isEqual:@"recalculating"]);
    value[@"settings"] = @{@"threshold": values[@"thresholdDBFS"], @"minimum": values[@"minimumSilenceDuration"],
        @"before": values[@"beforeSpeechPadding"], @"after": values[@"afterSpeechPadding"]};
    value[@"output"] = values[@"outputMode"];
    if (edit) value[@"settingsEdit"] = edit;
    return value;
}
static void frontmostHost(SSOfflineClient *c) {
    SSFakeHost *host = fakeHost(@"com.apple.FinalCut", 123);
    c.fakeHosts = @[host]; c.fakeFront = host;
}
static SSOfflineClient *automaticClient(void) {
    SSOfflineClient *c = client(); start(c, settings()); frontmostHost(c);
    deliver(c, automaticResponse(c, 1, @"review", settings(), nil)); return c;
}
static NSDictionary *lastCommand(SSOfflineClient *c, NSString *kind) {
    for (NSDictionary *post in c.posts.reverseObjectEnumerator)
        if ([post[@"packet"][@"command"] isEqual:kind]) return post[@"packet"];
    return nil;
}
static void sdkNavigationConsumesOnlyOneCurrentPermit(void) {
    SSOfflineClient *c = client(); start(c, settings()); frontmostHost(c);
    NSString *gesture = NSUUID.UUID.UUIDString;
    __block NSUInteger moves = 0;
    BOOL (^move)(NSDictionary *) = ^BOOL(NSDictionary *permit) { moves += 1; return YES; };
    deliver(c, snapshotResponse(c, 1));
    require(![c navigateCut:@"cut-1" gesture:gesture move:move], @"An older worker does not permit SDK navigation");
    NSMutableDictionary *ready = snapshotResponse(c, 2); ready[@"canNavigateWithSDK"] = @YES; deliver(c, ready);
    NSUInteger activations = c.activationRequests;
    require([c navigateCut:@"cut-1" gesture:gesture move:move] && c.busy && !c.canApply,
        @"SDK navigation starts once and locks review during authorization");
    NSDictionary *prepare = lastCommand(c, @"prepareNavigation");
    require([prepare[@"navigationGesture"] isEqual:gesture] && [prepare[@"expectedRevision"] isEqual:@2] &&
        [prepare[@"cutID"] isEqual:@"cut-1"] && c.activationRequests == activations,
        @"Preparation binds the exact view, gesture, cut and revision without activation");
    [c poll]; require(commandCount(c, @"prepareNavigation") == 1, @"Polling never resends a move request");
    NSMutableDictionary *permit = [@{@"gesture":gesture, @"view":prepare[@"view"], @"cutID":@"cut-1",
        @"expiresUptime":@(c.fakeUptime + 2), @"time":@{@"numerator":@1001, @"denominator":@30000},
        @"sequenceStart":@{@"numerator":@0, @"denominator":@1}, @"sequenceDuration":@{@"numerator":@2, @"denominator":@1},
        @"frameDuration":@{@"numerator":@1001, @"denominator":@30000}} mutableCopy];
    NSMutableDictionary *approved = response(c, 3, @"navigating", YES);
    approved[@"canNavigateWithSDK"] = @YES; approved[@"navigationPermit"] = permit;
    NSDictionary *target = permit[@"time"];
    permit[@"time"] = @{@"numerator":@1001, @"denominator":@0}; deliver(c, approved);
    require(moves == 0 && commandCount(c, @"navigationFinished") == 0, @"Invalid CMTime scale never reaches the move callback");
    permit[@"time"] = target; deliver(c, approved); deliver(c, approved);
    require(moves == 1 && [lastCommand(c, @"navigationFinished")[@"navigationSucceeded"] isEqual:@YES] && c.busy,
        @"One accepted permit makes one move and waits for read-only confirmation");
    [c poll];
    require(moves == 1 && commandCount(c, @"highlight") == 0 && commandCount(c, @"navigationFinished") == 2,
        @"Only the read-only acknowledgment may be retried");
    ready = snapshotResponse(c, 4); ready[@"canNavigateWithSDK"] = @YES; deliver(c, ready);
    require(!c.busy && c.canApply, @"Confirmation restores the current review");
    gesture = NSUUID.UUID.UUIDString;
    require([c navigateCut:@"cut-1" gesture:gesture move:move], @"A new user click can start a different gesture");
    permit[@"gesture"] = gesture; permit[@"expiresUptime"] = @(c.fakeUptime - 1); approved[@"revision"] = @5;
    deliver(c, approved); deliver(c, approved);
    require(moves == 1 && [lastCommand(c, @"navigationFinished")[@"navigationSucceeded"] isEqual:@NO],
        @"An expired permit is consumed without a move or legacy fallback");
    finish(c); groups += 1;
}
static NSMutableDictionary *rejectedAutomaticResponse(SSOfflineClient *c, NSInteger revision,
                                                       NSString *edit, NSNumber *sequence) {
    NSMutableDictionary *value = automaticResponse(c, revision, @"review", settings(), nil);
    value[@"rejectedSettingsEdit"] = edit; value[@"rejectedSettingsSequence"] = sequence;
    value[@"canApply"] = @NO; value[@"canChangeSelection"] = @NO; value[@"canHighlight"] = @NO;
    value[@"message"] = @"Settings changed before the update was verified."; return value;
}
static void automaticCapabilityAndForeground(void) {
    SSOfflineClient *c = client(); start(c, settings()); frontmostHost(c);
    deliver(c, snapshotResponse(c, 1)); [c markSettingsDirty];
    require(!c.automaticPreviewAvailable && ![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString],
        @"An older worker's explicit-update capability does not authorize an automatic packet");
    NSUInteger updates = c.updates.count;
    NSMutableDictionary *bad = automaticResponse(c, 2, @"review", settings(), nil); bad[@"automaticPreviewAvailable"] = @1;
    deliver(c, bad); require(c.updates.count == updates && !c.automaticPreviewAvailable,
        @"An integer cannot impersonate the new automatic capability flag");
    deliver(c, automaticResponse(c, 2, @"review", settings(), nil));
    require(c.automaticPreviewAvailable && c.canUpdateCuts && !c.canApply,
        @"The new capability retains the edited draft without restoring stale Apply");
    NSUInteger activations = c.activationRequests, launches = c.analysisLaunches, helpers = c.helperLaunches;
    c.fakeFront = fakeHost(@"com.openai.codex", 456);
    require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString],
        @"A background edit cannot activate Final Cut or dispatch a refresh");
    frontmostHost(c); c.fakeHosts = @[c.fakeFront, fakeHost(@"com.apple.FinalCut", 124)];
    require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString], @"Ambiguous host processes stop automatic refresh");
    frontmostHost(c); c.fakeFront.terminated = YES;
    require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString], @"A terminated host cannot authorize automatic refresh");
    frontmostHost(c); c.fakeFront = fakeHost(@"com.openai.codex", 123);
    require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString], @"Matching PID with another app identity is not foreground ownership");
    frontmostHost(c);
    NSMutableDictionary *invalid = [settings() mutableCopy]; invalid[@"minimumSilenceDuration"] = @YES;
    require(![c automaticallyUpdateCutsWithSettings:invalid edit:NSUUID.UUID.UUIDString] &&
        ![c automaticallyUpdateCutsWithSettings:settings() edit:@"bad-edit"], @"Invalid settings and nonce cannot dispatch");
    NSMutableDictionary *values = [settings() mutableCopy]; NSMutableString *output = [NSMutableString stringWithString:@"gaps"];
    values[@"outputMode"] = output; NSString *edit = NSUUID.UUID.UUIDString;
    require([c automaticallyUpdateCutsWithSettings:values edit:edit] && c.updatingCuts && c.busy &&
        c.automaticPreviewAvailable && !c.canApply && !c.canUpdateCuts, @"Automatic refresh consumes current actions while preserving the reusable capability");
    NSDictionary *command = lastCommand(c, @"recalculate");
    require([command[@"automaticPreview"] isEqual:@YES] && [command[@"localPreview"] isEqual:@YES] &&
        [command[@"verifySettings"] isEqual:@YES] && [command[@"settingsEdit"] isEqual:edit] &&
        [command[@"settingsSequence"] isEqual:@1] && [command[@"expectedRevision"] isEqual:@2],
        @"Automatic refresh pins the native edit, snapshot sequence and current review revision");
    require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString], @"An in-flight refresh cannot overlap another update");
    values[@"minimumSilenceDuration"] = @9; [output setString:@"remove"]; [c poll];
    require([lastCommand(c, @"recalculate") isEqual:command] && [lastCommand(c, @"recalculate")[@"output"] isEqual:@"gaps"],
        @"Polling retries only the immutable original snapshot, including a copied mutable output string");
    require(c.activationRequests == activations && c.analysisLaunches == launches && c.helperLaunches == helpers &&
        commandCount(c, @"apply") == 0, @"Automatic refresh never activates, launches, analyzes or applies");
    deliver(c, automaticResponse(c, 3, @"review", settings(), edit));
    require(!c.updatingCuts && !c.busy && c.canApply, @"Only the exact final settings snapshot acknowledgment restores Apply");
    finish(c); groups += 1;
}
static void automaticAcknowledgmentRequiresLatestDraft(void) {
    SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSString *first = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:first];
    NSMutableDictionary *next = [settings() mutableCopy]; next[@"minimumSilenceDuration"] = @0.7;
    NSString *second = NSUUID.UUID.UUIDString; [c markSettingsDirty];
    require(!c.canApply && c.updatingCuts && commandCount(c, @"recalculate") == 1 &&
        [lastCommand(c, @"preview")[@"view"] isEqual:@"2686A7A1-BC05-4885-82A2-C9EE8A096F45"] &&
        [lastCommand(c, @"preview")[@"settingsSequence"] isEqual:@2],
        @"Typing during a refresh marks a later draft and suspends the old overlay with its prospective sequence");
    deliver(c, automaticResponse(c, 2, @"recalculating", settings(), first));
    require(c.updatingCuts && c.busy && !c.canApply && !c.canChangeSelection,
        @"A provisional acknowledgment does not expose stale cut actions");
    __weak SSOfflineClient *weak = c;
    c.afterPublish = ^{
        SSOfflineClient *owner = weak;
        if (!owner.updatingCuts && owner.canUpdateCuts) {
            owner.afterPublish = nil;
            require([owner automaticallyUpdateCutsWithSettings:next edit:second], @"The latest queued draft can dispatch after its predecessor finishes");
        }
    };
    deliver(c, automaticResponse(c, 3, @"review", settings(), first));
    require(c.updatingCuts && c.busy && !c.canApply && commandCount(c, @"recalculate") == 2,
        @"A superseded final result cannot briefly enable Apply before the newest update");
    require([lastCommand(c, @"preview")[@"settingsSequence"] isEqual:@2],
        @"A hide generated before the publish callback retains sequence two, rather than hiding the newly dispatched result as sequence three");
    deliver(c, automaticResponse(c, 4, @"review", settings(), first));
    require(c.updatingCuts && !c.canApply, @"A later delayed reply for the old edit cannot acknowledge the new draft");
    deliver(c, automaticResponse(c, 5, @"review", next, second));
    require(!c.updatingCuts && !c.busy && c.canApply && c.canHighlight && c.canChangeSelection,
        @"The matching newest edit and echoed values alone restore review authority");
    finish(c); groups += 1;
}
static void automaticDeclineReleasesLatestDraft(void) {
    SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSString *first = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:first]; [c markSettingsDirty];
    NSMutableDictionary *decline = rejectedAutomaticResponse(c, 1, first, @1); deliver(c, decline);
    require(!c.updatingCuts && !c.busy && !c.canApply && c.canUpdateCuts && c.automaticPreviewAvailable,
        @"A matching same-revision decline releases only the in-flight packet while keeping the draft dirty");
    require([c.updates.lastObject[@"rejectedSettingsEdit"] isEqual:first] &&
        [c.updates.lastObject[@"rejectedSettingsSequence"] isEqual:@1], @"The controller receives the exact declined nonce and sequence");
    NSUInteger recalculate = commandCount(c, @"recalculate");
    c.clock = [c.clock dateByAddingTimeInterval:20]; deliver(c, decline); [c poll];
    require(c.failures.count == 0 && commandCount(c, @"recalculate") == recalculate,
        @"Repeated cached decline heartbeats keep the idle review alive without retrying the rejected draft");
    NSMutableDictionary *next = [settings() mutableCopy]; next[@"afterSpeechPadding"] = @0.2;
    NSString *second = NSUUID.UUID.UUIDString;
    require([c automaticallyUpdateCutsWithSettings:next edit:second] &&
        [lastCommand(c, @"recalculate")[@"settingsSequence"] isEqual:@2], @"A newer draft can proceed with the next monotonic sequence");
    require(c.updates.lastObject[@"rejectedSettingsEdit"] == nil, @"A new send clears stale rejection fields from published state");
    deliver(c, decline); require(c.updatingCuts && c.busy, @"An old cached decline cannot release a newer pending edit");
    deliver(c, automaticResponse(c, 2, @"review", next, second)); require(c.canApply && !c.updatingCuts, @"The newest accepted draft completes after its predecessor was declined");
    finish(c); groups += 1;
}
static void malformedAutomaticDeclinesCannotAcknowledge(void) {
    SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSString *edit = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:edit];
    NSMutableArray *invalid = [NSMutableArray new];
    NSMutableDictionary *value = rejectedAutomaticResponse(c, 1, NSUUID.UUID.UUIDString, @1); [invalid addObject:value];
    value = rejectedAutomaticResponse(c, 1, edit, @2); [invalid addObject:value];
    value = rejectedAutomaticResponse(c, 0, edit, @1); [invalid addObject:value];
    for (id sequence in @[@YES, @0, @-1, @"1", NSNull.null]) {
        value = rejectedAutomaticResponse(c, 1, edit, @1); value[@"rejectedSettingsSequence"] = sequence; [invalid addObject:value];
    }
    value = rejectedAutomaticResponse(c, 1, edit, @1); [value removeObjectForKey:@"rejectedSettingsSequence"]; [invalid addObject:value];
    for (NSDictionary *packet in invalid) {
        deliver(c, packet); require(c.updatingCuts && c.busy && !c.canApply, @"Malformed, stale or unrelated rejection cannot consume an automatic update");
    }
    value = rejectedAutomaticResponse(c, 2, edit, @1); value[@"state"] = @"recalculating"; value[@"canUpdateCuts"] = @NO;
    deliver(c, value); require(!c.updatingCuts && c.busy && !c.canApply && !c.canUpdateCuts,
        @"A decline during another retained operation releases this nonce but waits for its final review");
    deliver(c, automaticResponse(c, 3, @"review", settings(), nil));
    require(!c.busy && !c.canApply && c.canUpdateCuts, @"Ordinary completion after a decline never clears the locally dirty draft");
    finish(c); groups += 1;
}
static void automaticSettingsWaitForSelectionAcknowledgment(void) {
    SSOfflineClient *c = automaticClient();
    require([c setCut:@"cut-1" included:NO] && !c.canUpdateCuts, @"An inclusion choice waits for its own acknowledgment");
    [c markSettingsDirty];
    require(!c.canApply && !c.canUpdateCuts &&
        ![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString],
        @"Detection typing retains the pending inclusion revision instead of dispatching a stale settings snapshot");
    NSMutableDictionary *selected = automaticResponse(c, 2, @"review", settings(), nil);
    selected[@"cuts"] = @[cut(NO)]; selected[@"canApply"] = @NO;
    deliver(c, selected);
    require(c.canUpdateCuts && !c.canApply, @"The inclusion acknowledgment releases automatic refresh without clearing the dirty settings");
    NSString *edit = NSUUID.UUID.UUIDString;
    require([c automaticallyUpdateCutsWithSettings:settings() edit:edit] &&
        [lastCommand(c, @"recalculate")[@"expectedRevision"] isEqual:@2], @"The automatic snapshot binds the acknowledged inclusion revision");
    deliver(c, automaticResponse(c, 3, @"review", settings(), edit));
    require(c.canApply && !c.busy, @"Only the new settings acknowledgment can restore Apply after overlapping selection and detection edits");
    finish(c); groups += 1;
}
static void automaticEchoMismatchCannotEnableApply(void) {
    SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSString *edit = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:edit];
    NSMutableDictionary *different = [settings() mutableCopy]; different[@"thresholdDBFS"] = @-30;
    deliver(c, automaticResponse(c, 2, @"review", different, edit));
    require(!c.updatingCuts && !c.canApply && !c.canHighlight && c.canUpdateCuts &&
        [c.updates.lastObject[@"rejectedSettingsEdit"] isEqual:edit],
        @"A matching nonce with different echoed values cannot acknowledge the user's draft");
    deliver(c, automaticResponse(c, 3, @"review", settings(), edit));
    require(!c.canApply, @"A delayed ordinary response cannot revive a rejected draft without another explicit local edit send");
    finish(c);
    c = automaticClient(); [c markSettingsDirty]; edit = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:edit];
    NSMutableDictionary *missing = automaticResponse(c, 2, @"review", settings(), edit); [missing removeObjectForKey:@"settings"];
    deliver(c, missing); require(!c.canApply && !c.updatingCuts, @"A final update without a full settings echo remains dirty");
    finish(c); groups += 1;
}
static void automaticDispatchRespectsReentrantChanges(void) {
    for (NSString *change in @[@"cancel", @"detach", @"background", @"newDraft"]) {
        SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSUInteger activations = c.activationRequests;
        __weak SSOfflineClient *weak = c;
        c.afterPublish = ^{
            SSOfflineClient *owner = weak;
            if (!owner.updatingCuts) return;
            owner.afterPublish = nil;
            if ([change isEqual:@"cancel"]) [owner cancel];
            else if ([change isEqual:@"detach"]) [owner detach];
            else if ([change isEqual:@"background"]) owner.fakeFront = fakeHost(@"com.openai.codex", 456);
            else [owner markSettingsDirty];
        };
        require(![c automaticallyUpdateCutsWithSettings:settings() edit:NSUUID.UUID.UUIDString] &&
            commandCount(c, @"recalculate") == 0 && c.activationRequests == activations,
            @"Cancel, detach, lost foreground or a newer draft during publication prevents the old automatic dispatch");
        if ([change isEqual:@"cancel"]) deliver(c, response(c, 2, @"cancelled", NO));
        require(!c.updatingCuts && !c.busy && !c.canApply, @"An undispatched automatic packet cannot leave a pending-operation deadlock or stale Apply");
        finish(c);
    }
    groups += 1;
}
static void automaticTimeoutAndTerminalAreConsumed(void) {
    SSOfflineClient *c = automaticClient(); [c markSettingsDirty]; NSString *edit = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:edit];
    c.clock = [c.clock dateByAddingTimeInterval:20]; [c poll];
    require(c.failures.count == 1 && !c.updatingCuts && !c.busy && !c.canApply && !c.automaticPreviewAvailable,
        @"An automatic refresh timeout consumes the local capability without launching another task");
    deliver(c, automaticResponse(c, 3, @"review", settings(), edit));
    require(!c.canApply && !c.updatingCuts, @"A late successful update cannot revive a timed-out review");
    finish(c);
    c = automaticClient(); [c markSettingsDirty]; edit = NSUUID.UUID.UUIDString;
    [c automaticallyUpdateCutsWithSettings:settings() edit:edit]; [c cancel];
    deliver(c, automaticResponse(c, 2, @"review", settings(), edit));
    require(!c.canApply && !c.updatingCuts, @"Cancellation prevents a late update reply from restoring cut actions");
    deliver(c, automaticResponse(c, 3, @"cancelled", settings(), edit));
    require(!c.automaticPreviewAvailable && !c.busy && !c.canApply, @"A terminal canceled job cannot expose automatic update capability");
    finish(c); groups += 1;
}

static BOOL recover(SSOfflineClient *c, NSURL *result) {
    return [c verifyExistingResultURL:result libraryURL:[NSURL fileURLWithPath:@"/Test/Cutdown Integration.fcpbundle"]
        projectUID:@"project-A" projectName:@"Project & 20%" gesture:@"EA97943A-27BB-48BE-BB14-FB4F30314D52"];
}
static NSDictionary *recoveryConnection(void) {
    return @{@"version": @1, @"view": @"2686A7A1-BC05-4885-82A2-C9EE8A096F45",
        @"request": @"2A2937F3-93E5-4D3F-9CC9-26E591A337B6", @"output": @"remove",
        @"gesture": @"EA97943A-27BB-48BE-BB14-FB4F30314D52",
        @"settings": @{@"threshold": @-40, @"minimum": @0.5, @"before": @0.1, @"after": @0.1}};
}
static void explicitRecoveryAdoptsOnlyReadOnlyResult(void) {
    SSOfflineClient *c = client(); NSURL *result = [NSURL fileURLWithPath:@"/Test/Result 20%/Silent Snip.fcpxml"];
    require(!recover(c, [NSURL URLWithString:@"https://example.invalid/Silent%20Snip.fcpxml"]) &&
        !recover(c, [NSURL fileURLWithPath:@"/Test/other.fcpxml"]) && c.analysisLaunches == 0,
        @"Recovery rejects nonlocal or wrong-named files before launching");
    [c receiveConnection:notification(recoveryConnection(), nil)]; require(!c.requestID, @"Unsolicited connection messages cannot adopt any job");
    require(recover(c, result) && c.busy && !c.canCancel && c.analysisLaunches == 1,
        @"Explicit recovery launches one pinned read-only request and waits for its saved identity");
    NSURLComponents *parts = [NSURLComponents componentsWithURL:c.launchedRequest resolvingAgainstBaseURL:NO];
    NSMutableDictionary *fields = [NSMutableDictionary new]; for (NSURLQueryItem *item in parts.queryItems) fields[item.name] = item.value;
    require([parts.host isEqual:@"workflow-verify"] && fields.count == 6 && [fields[@"result"] isEqual:result.absoluteString] &&
        [fields[@"project"] isEqual:@"project-A"] && fields[@"gesture"] && !fields[@"request"],
        @"Recovery URL carries only the chosen result and verified native/project identity");
    NSString *pending = c.requestID;
    deliver(c, snapshotResponse(c, 5)); require([c.requestID isEqual:pending] && !c.canApply,
        @"Ordinary review responses cannot substitute for explicit recovery adoption");
    NSMutableDictionary *wrong = [recoveryConnection() mutableCopy]; wrong[@"view"] = NSUUID.UUID.UUIDString;
    [c receiveConnection:notification(wrong, nil)]; require([c.requestID isEqual:pending], @"Another view cannot bind the selected result");
    wrong = [recoveryConnection() mutableCopy]; wrong[@"gesture"] = NSUUID.UUID.UUIDString;
    [c receiveConnection:notification(wrong, nil)]; require([c.requestID isEqual:pending], @"A delayed earlier recovery gesture cannot adopt the wrong saved result");
    wrong = [recoveryConnection() mutableCopy]; wrong[@"settings"] = @{@"threshold": @YES};
    [c receiveConnection:notification(wrong, nil)]; require([c.requestID isEqual:pending], @"Malformed restored settings cannot adopt a result");
    [c receiveConnection:notification(recoveryConnection(), nil)];
    require([c.requestID isEqual:recoveryConnection()[@"request"]] && [c.posts.lastObject[@"packet"][@"command"] isEqual:@"status"],
        @"A matching reply adopts the saved request and immediately polls its status");
    NSUInteger updates = c.updates.count;
    NSMutableDictionary *stale = response(c, 99, @"completed", YES);
    [stale removeObjectForKey:@"workflowGesture"]; deliver(c, stale);
    stale[@"workflowGesture"] = NSUUID.UUID.UUIDString; deliver(c, stale);
    require(c.busy && c.updates.count == updates, @"A delayed prior Apply/verification terminal cannot finish or poison fresh recovery");
    deliver(c, snapshotResponse(c, 1));
    require(!c.canApply && !c.canChangeSelection && !c.canUpdateCuts && !c.canHighlight &&
        ![c sendApplyWithGesture:NSUUID.UUID.UUIDString] && ![c highlightCut:@"cut-1"],
        @"An adopted verification result never gains timeline editing or stale cut authority");
    deliver(c, response(c, 2, @"verifying", YES)); deliver(c, response(c, 3, @"completed", YES));
    require(!c.busy && commandCount(c, @"apply") == 0 && c.analysisLaunches == 1 &&
        [c.updates.lastObject[@"verificationOnly"] isEqual:@YES],
        @"Restart recovery observes and labels verification without another Analyze or Apply/import");
    finish(c);
    c = client(); recover(c, result);
    NSDictionary *error = @{@"version": @1, @"view": @"2686A7A1-BC05-4885-82A2-C9EE8A096F45", @"gesture": @"EA97943A-27BB-48BE-BB14-FB4F30314D52", @"error": @"Saved artifacts changed."};
    [c receiveConnection:notification(error, nil)]; require(c.failures.count == 1 && !c.busy && commandCount(c, @"apply") == 0,
        @"An explicit recovery connection error releases UI without inventing an edit"); finish(c);
    c = client(); recover(c, result); c.clock = [c.clock dateByAddingTimeInterval:16]; [c poll];
    [c receiveConnection:notification(recoveryConnection(), nil)];
    require(c.failures.count == 1 && !c.busy && ![c.requestID isEqual:recoveryConnection()[@"request"]],
        @"A late recovery connection cannot revive a timed-out operation"); finish(c);
    c = client(); c.deferActivation = YES; recover(c, result); [c cancel]; [c completeActivation:nil];
    require(c.analysisLaunches == 0 && commandCount(c, @"cancel") == 0 && !c.busy,
        @"Cancellation before recovery dispatch consumes activation without sending a fabricated worker identity"); finish(c);
    groups += 1;
}

int main(void) {
    @autoreleasepool {
        targetedLaunchAndURLBinding(); quietWindowPreparationUsesOnlyThePinnedHelper(); invalidPreflightNeverDispatches(); helperAmbiguityAndOldInstalledCopy();
        malformedResponsesDoNotReachUI(); selectionNeedsExactNewAcknowledgment(); applyRetriesOnlyTheOwnedCommand();
        cancellationRetriesUntilTerminalAcknowledgment(); retryVerificationDoesNotApplyAgain(); freshCapabilityNonceBeforeAnyAnalysis(); timeoutCannotReviveReview();
        delayedAnalyzeActivationIsCancelledSafely(); applyActivationIsRecoverableAndRevisionBound();
        retryActivationNeverCreatesAnEdit(); publicActivationPolicyRequiresExactForeground();
        synchronousUIDetachCannotDispatch();
        updateCutsRetainsAndAcknowledgesSnapshot(); updateAndNavigationActivationRemainRevisionBound();
        sdkNavigationConsumesOnlyOneCurrentPermit();
        automaticCapabilityAndForeground(); automaticAcknowledgmentRequiresLatestDraft(); automaticDeclineReleasesLatestDraft();
        malformedAutomaticDeclinesCannotAcknowledge(); automaticSettingsWaitForSelectionAcknowledgment(); automaticEchoMismatchCannotEnableApply();
        automaticDispatchRespectsReentrantChanges(); automaticTimeoutAndTerminalAreConsumed(); explicitRecoveryAdoptsOnlyReadOnlyResult();
        printf("Passed %lu review-client groups (%lu assertions); no real helper launch, DNC, timers, windows, or settings files.\n",
            (unsigned long)groups, (unsigned long)checks);
    }
    return EXIT_SUCCESS;
}
