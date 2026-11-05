#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import "Support/SSWorkflowPersistence-Swift.h"
#import <stdio.h>
#import <stdlib.h>

// This executable includes the actual controller implementation below. Only
// its persistence bridge, review transport, and SDK host objects are replaced, through their
// public interfaces. No NSApplication, NSWindow, events, Final Cut connection,
// filesystem settings, or SDK bootstrap is created by this harness.
@interface SSPendingLoad : NSObject
@property (nonatomic, copy) NSURL *libraryURL;
@property (nonatomic, copy) NSString *projectUID;
@property (nonatomic, copy) void (^completion)(NSDictionary *, NSError *);
@end
@implementation SSPendingLoad
@end

@interface SSPendingSave : NSObject
@property (nonatomic, copy) NSURL *libraryURL;
@property (nonatomic, copy) NSString *projectUID;
@property (nonatomic, copy) NSDictionary *values;
@property (nonatomic, copy) void (^completion)(NSError *);
@end
@implementation SSPendingSave
@end

@interface SSWorkflowSettingsBridge ()
@property (nonatomic, strong) NSMutableArray<SSPendingLoad *> *loads;
@property (nonatomic, strong) NSMutableArray<SSPendingSave *> *saves;
@end
@implementation SSWorkflowSettingsBridge
- (instancetype)init {
    self = [super init];
    if (self) { _loads = [NSMutableArray new]; _saves = [NSMutableArray new]; }
    return self;
}
- (void)loadForLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
              completion:(void (^)(NSDictionary *, NSError *))completion {
    SSPendingLoad *request = [SSPendingLoad new];
    request.libraryURL = libraryURL;
    request.projectUID = projectUID;
    request.completion = completion;
    [self.loads addObject:request];
}
- (void)saveValues:(NSDictionary *)values libraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
       completion:(void (^)(NSError *))completion {
    SSPendingSave *request = [SSPendingSave new];
    request.libraryURL = libraryURL;
    request.projectUID = projectUID;
    request.values = values;
    request.completion = completion;
    [self.saves addObject:request];
}
@end

// These NSObject mocks implement the documented instance selectors. Their
// types deliberately are not FCPX proxy subclasses: the SDK provides headers,
// not linkable proxy class implementations, just as in the actual extension.
@interface SSProxy : NSObject
@property (nonatomic) FCPXObjectType objectType;
@property (nonatomic, strong) SSProxy *container;
@property (nonatomic, copy) NSString *UID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSURL *url;
@property (nonatomic) CMTime startTime;
@end
@implementation SSProxy
@end

@interface SSTimeline : NSObject
@property (nonatomic, strong) SSProxy *sequence;
@property (nonatomic) CMTime currentPlayhead;
@property (nonatomic, weak) NSObject<FCPXTimelineObserver> *observer;
@property (nonatomic) NSUInteger addCount;
@property (nonatomic) NSUInteger removeCount;
- (void)notifySequenceChanged;
@end
@implementation SSTimeline
- (FCPXSequence *)activeSequence { return (FCPXSequence *)self.sequence; }
- (CMTime)playheadTime { return self.currentPlayhead; }
- (void)addTimelineObserver:(NSObject<FCPXTimelineObserver> *)observer {
    self.observer = observer;
    self.addCount += 1;
}
- (void)removeTimelineObserver:(NSObject<FCPXTimelineObserver> *)observer {
    if (self.observer == observer) self.observer = nil;
    self.removeCount += 1;
}
- (void)notifySequenceChanged {
    if ([self.observer respondsToSelector:@selector(activeSequenceChanged)]) [self.observer activeSequenceChanged];
}
@end

@interface SSHost : NSObject <FCPXHost>
@property (nonatomic, strong) NSString *name;
@property (nonatomic, strong) NSString *versionString;
@property (nonatomic, strong) NSString *bundleIdentifier;
@property (nonatomic, strong) SSTimeline *testTimeline;
@property (nonatomic) NSUInteger timelineReadCount;
@end
@implementation SSHost
- (FCPXTimeline *)timeline {
    self.timelineReadCount += 1;
    return (FCPXTimeline *)self.testTimeline;
}
@end

static id<NSObject> hostSingleton;
id<NSObject> ProExtensionHostSingleton(void) { return hostSingleton; }

#import "../Extension/WorkflowViewController.m"

// The real transport has its own offline test executable. Keep even its
// destructor and notification-center cleanup out of these controller tests.
// Every transport operation must dispatch to the explicit fake subclass.
static void unexpectedReviewBoundary(void) {
    fprintf(stderr, "FAIL: A controller test reached the real review-client boundary\n");
    abort();
}
@implementation SSWorkflowReviewClient
- (instancetype)initWithViewID:(NSString *)viewID update:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure {
    return [super init];
}
- (NSString *)requestID { unexpectedReviewBoundary(); return nil; }
- (BOOL)busy { unexpectedReviewBoundary(); return NO; }
- (BOOL)canApply { unexpectedReviewBoundary(); return NO; }
- (BOOL)canChangeSelection { unexpectedReviewBoundary(); return NO; }
- (BOOL)canCancel { unexpectedReviewBoundary(); return NO; }
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings gesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)sendApplyWithGesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included { unexpectedReviewBoundary(); return NO; }
- (BOOL)selectAll:(BOOL)included { unexpectedReviewBoundary(); return NO; }
- (BOOL)retryVerification { unexpectedReviewBoundary(); return NO; }
- (void)cancel { unexpectedReviewBoundary(); }
- (void)detach { unexpectedReviewBoundary(); }
@end

@interface SSFakeWorkflowReviewClient : SSWorkflowReviewClient
@property (nonatomic, weak) SSWorkflowViewController *owner;
@property (nonatomic, copy) void (^testUpdate)(NSDictionary *);
@property (nonatomic, copy) void (^testFailure)(NSString *);
@property (nonatomic, copy) NSString *fakeRequestID;
@property (nonatomic) BOOL fakeBusy;
@property (nonatomic) BOOL fakeCanApply;
@property (nonatomic) BOOL fakeCanChangeSelection;
@property (nonatomic) BOOL fakeCanCancel;
@property (nonatomic) BOOL fakeCanRetry;
@property (nonatomic, copy) NSDictionary *lastResponse;
@property (nonatomic, copy) NSDictionary *startPayload;
@property (nonatomic) NSUInteger startCount;
@property (nonatomic, strong) NSMutableArray<NSString *> *applyGestures;
@property (nonatomic, copy) NSString *analyzeIdentifierAtDispatch;
@property (nonatomic, copy) NSString *applyIdentifierAtDispatch;
@property (nonatomic) BOOL analyzeDisabledAtDispatch;
@property (nonatomic) BOOL applyDisabledAtDispatch;
@property (nonatomic) NSUInteger cancelCount;
@property (nonatomic) NSUInteger detachCount;
@property (nonatomic) NSUInteger retryCount;
@property (nonatomic) BOOL failApplyActivationSynchronously;
@property (nonatomic) NSUInteger applyCommandCount;
- (void)deliver:(NSDictionary *)response busy:(BOOL)busy canApply:(BOOL)canApply;
@end
@implementation SSFakeWorkflowReviewClient
- (instancetype)initWithViewID:(NSString *)viewID update:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure {
    self = [super initWithViewID:viewID update:update failure:failure];
    if (self) { _testUpdate = [update copy]; _testFailure = [failure copy]; _applyGestures = [NSMutableArray new]; }
    return self;
}
- (NSString *)requestID { return self.fakeRequestID; }
- (BOOL)busy { return self.fakeBusy; }
- (BOOL)canApply { return self.fakeCanApply; }
- (BOOL)canChangeSelection { return self.fakeCanChangeSelection; }
- (BOOL)canCancel { return self.fakeCanCancel; }
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings gesture:(NSString *)gesture {
    self.startCount += 1;
    self.startPayload = @{@"libraryURL": libraryURL, @"projectUID": projectUID, @"projectName": projectName,
                          @"settings": settings, @"gesture": gesture};
    self.analyzeIdentifierAtDispatch = self.owner.analyzeButton.accessibilityIdentifier;
    self.analyzeDisabledAtDispatch = !self.owner.analyzeButton.enabled;
    self.fakeRequestID = NSUUID.UUID.UUIDString;
    self.fakeBusy = YES;
    self.fakeCanCancel = YES;
    return YES;
}
- (BOOL)sendApplyWithGesture:(NSString *)gesture {
    [self.applyGestures addObject:gesture];
    self.applyIdentifierAtDispatch = self.owner.applyButton.accessibilityIdentifier;
    self.applyDisabledAtDispatch = !self.owner.applyButton.enabled;
    if (self.failApplyActivationSynchronously) {
        NSMutableDictionary *response = [self.lastResponse mutableCopy];
        response[@"message"] = @"Activate Final Cut Pro, then choose Apply again.";
        self.lastResponse = response;
        self.testUpdate(response);
        return NO;
    }
    self.applyCommandCount += 1;
    self.fakeBusy = YES;
    self.fakeCanApply = NO;
    self.fakeCanChangeSelection = NO;
    return YES;
}
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included { return self.fakeCanChangeSelection; }
- (BOOL)selectAll:(BOOL)included { return self.fakeCanChangeSelection; }
- (BOOL)retryVerification {
    if (!self.fakeCanRetry || self.fakeBusy) return NO;
    self.retryCount += 1;
    self.fakeBusy = YES;
    self.fakeCanApply = NO;
    self.fakeCanChangeSelection = NO;
    self.fakeCanCancel = YES;
    self.testUpdate(self.lastResponse); // The real client publishes its pending state synchronously.
    return YES;
}
- (void)cancel { self.cancelCount += 1; self.fakeCanCancel = NO; }
- (void)detach {
    self.detachCount += 1;
    self.fakeBusy = NO;
    self.fakeCanApply = NO;
    self.fakeCanChangeSelection = NO;
    self.fakeCanCancel = NO;
    self.fakeCanRetry = NO;
    // Keep callbacks so tests can model already-queued messages after detach.
}
- (void)deliver:(NSDictionary *)response busy:(BOOL)busy canApply:(BOOL)canApply {
    self.lastResponse = response;
    self.fakeBusy = busy;
    self.fakeCanApply = canApply;
    self.fakeCanChangeSelection = canApply;
    self.fakeCanCancel = busy || canApply;
    self.fakeCanRetry = [response[@"canRetryVerification"] boolValue];
    self.testUpdate(response);
}
@end

@interface SSPendingPermission : NSObject
@property (nonatomic) BOOL asksUser;
@property (nonatomic, copy) void (^completion)(OSStatus);
@end
@implementation SSPendingPermission
@end

// Every controller allocated by this harness is this subclass. The override
// records the permission contract without invoking the real Apple Event or
// TCC APIs, including for the explicit Connect action.
@interface SSTestWorkflowViewController : SSWorkflowViewController
@property (nonatomic) OSStatus permissionStatus;
@property (nonatomic) BOOL delaysPermission;
@property (nonatomic, strong) NSMutableArray<SSPendingPermission *> *permissions;
@property (nonatomic, strong) NSMutableArray<SSFakeWorkflowReviewClient *> *reviewClients;
@end
@implementation SSTestWorkflowViewController
- (SSWorkflowReviewClient *)newReviewClientWithUpdate:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure {
    if (!self.reviewClients) self.reviewClients = [NSMutableArray new];
    SSFakeWorkflowReviewClient *client = [[SSFakeWorkflowReviewClient alloc] initWithViewID:self.viewID update:update failure:failure];
    client.owner = self;
    [self.reviewClients addObject:client];
    return client;
}
- (void)checkHostPermissionAskingUser:(BOOL)ask completion:(void (^)(OSStatus))completion {
    if (!self.permissions) self.permissions = [NSMutableArray new];
    SSPendingPermission *request = [SSPendingPermission new];
    request.asksUser = ask;
    request.completion = completion;
    [self.permissions addObject:request];
    if (!self.delaysPermission) {
        void (^ready)(OSStatus) = request.completion;
        request.completion = nil;
        ready(self.permissionStatus);
    }
}
@end

static NSUInteger assertionCount;
static NSUInteger groupCount;
static void check(BOOL condition, NSString *message) {
    assertionCount += 1;
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(EXIT_FAILURE);
    }
}

static NSDictionary *values(double threshold, BOOL saved) {
    return @{@"thresholdDBFS": @(threshold), @"minimumSilenceDuration": @0.1,
             @"beforeSpeechPadding": @0.05, @"afterSpeechPadding": @0.05,
             @"outputMode": @"remove", @"wasSaved": @(saved)};
}

static void completeLoad(SSPendingLoad *request, NSDictionary *settings, NSError *error) {
    check(request.completion != nil, @"A load completion is consumed exactly once");
    void (^completion)(NSDictionary *, NSError *) = request.completion;
    request.completion = nil;
    completion(settings, error);
}

static void completeSave(SSPendingSave *request, NSError *error) {
    check(request.completion != nil, @"A save completion is consumed exactly once");
    void (^completion)(NSError *) = request.completion;
    request.completion = nil;
    completion(error);
}

static void completePermission(SSPendingPermission *request, OSStatus status) {
    check(request.completion != nil, @"A permission completion is consumed exactly once");
    void (^completion)(OSStatus) = request.completion;
    request.completion = nil;
    completion(status);
}

static SSProxy *sequence(NSString *UID, NSString *libraryPath, NSString *projectName) {
    SSProxy *library = [SSProxy new];
    library.objectType = kFCPXObjectType_Library;
    library.name = libraryPath.lastPathComponent;
    library.url = [NSURL fileURLWithPath:libraryPath isDirectory:YES];
    SSProxy *event = [SSProxy new];
    event.objectType = kFCPXObjectType_Event;
    event.name = @"Disposable event";
    event.UID = @"event-id";
    event.container = library;
    SSProxy *project = [SSProxy new];
    project.objectType = kFCPXObjectType_Project;
    project.name = projectName;
    project.UID = UID;
    project.container = event;
    SSProxy *result = [SSProxy new];
    result.objectType = kFCPXObjectType_Sequence;
    result.name = projectName;
    result.startTime = CMTimeMake(3600, 1);
    result.container = project;
    return result;
}

static SSHost *host(SSProxy *activeSequence) {
    SSHost *result = [SSHost new];
    result.name = @"Final Cut Pro (test double)";
    result.versionString = @"12.4";
    result.bundleIdentifier = @"com.apple.FinalCut";
    result.testTimeline = [SSTimeline new];
    result.testTimeline.sequence = activeSequence;
    result.testTimeline.currentPlayhead = CMTimeMake(7225, 2); // 12.5 seconds relative to project start.
    return result;
}

static SSTestWorkflowViewController *openControllerWithPermission(id<NSObject> testHost, OSStatus status, BOOL delayed) {
    hostSingleton = testHost;
    SSTestWorkflowViewController *controller = [[SSTestWorkflowViewController alloc] initWithNibName:nil bundle:nil];
    controller.permissionStatus = status;
    controller.delaysPermission = delayed;
    [controller loadView];
    [controller viewDidAppear];
    return controller;
}

static SSTestWorkflowViewController *openController(id<NSObject> testHost) {
    return openControllerWithPermission(testHost, noErr, NO);
}

static void closeController(SSWorkflowViewController *controller) {
    [controller viewWillDisappear];
    SSTestWorkflowViewController *testController = (SSTestWorkflowViewController *)controller;
    for (SSPendingPermission *request in testController.permissions) {
        if (request.completion) completePermission(request, errAEEventNotPermitted);
    }
    NSError *cancelled = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
    for (SSPendingLoad *request in controller.settings.loads) {
        if (request.completion) completeLoad(request, nil, cancelled);
    }
    for (SSPendingSave *request in controller.settings.saves) {
        if (request.completion) completeSave(request, cancelled);
    }
    for (SSPendingLoad *request in controller.settings.loads) check(request.completion == nil, @"No delayed load survives teardown");
    for (SSPendingSave *request in controller.settings.saves) check(request.completion == nil, @"No delayed save survives teardown");
    for (SSPendingPermission *request in testController.permissions) check(request.completion == nil, @"No delayed permission completion survives teardown");
    check(!controller.saveButton.enabled, @"Closing the view disables persistence controls");
    hostSingleton = nil;
}

static void sameProjectPreservesDraft(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Same name"));
    SSWorkflowViewController *controller = openController(current);
    check(current.testTimeline.addCount == 1, @"Opening registers one timeline observer");
    check(controller.settings.loads.count == 1, @"Opening loads settings for the verified identity");
    check(!controller.saveButton.enabled, @"Pending settings are not editable");
    NSUInteger generation = controller.contextGeneration;
    [current.testTimeline notifySequenceChanged];
    check(controller.settings.loads.count == 1, @"A duplicate callback preserves the in-flight load");
    check(controller.contextGeneration == generation, @"A duplicate identity does not invalidate its pending completion");
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    check(controller.saveButton.enabled, @"The retained pending completion enables this project's settings");
    controller.fields[0].stringValue = @"-42";
    [controller.output selectItemAtIndex:1];
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Renamed project");
    [current.testTimeline notifySequenceChanged];
    check(controller.settings.loads.count == 1, @"A rebuilt proxy with the same identity does not reload the archive");
    check([controller.fields[0].stringValue isEqual:@"-42"], @"Repeated same-project observations preserve unsaved numeric edits");
    check(controller.output.indexOfSelectedItem == 1, @"Repeated same-project observations preserve the output draft");
    check([controller.projectLabel.stringValue isEqual:@"Renamed project"], @"A name refresh does not change the persistence key");
    check([controller.playheadLabel.stringValue containsString:@"12.500"], @"Playhead is shown relative to sequence start");
    closeController(controller);
    check(current.testTimeline.observer == nil && current.testTimeline.removeCount == 1, @"Closing removes the observer");
    groupCount += 1;
}

static void lateLoadCannotCrossProjects(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Shared.fcpbundle", @"Same name"));
    SSWorkflowViewController *controller = openController(current);
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Shared.fcpbundle", @"Same name");
    [current.testTimeline notifySequenceChanged];
    check(controller.settings.loads.count == 2, @"Same-named distinct project UIDs require separate loads");
    completeLoad(controller.settings.loads[0], values(-10, YES), nil);
    check(!controller.saveButton.enabled && !controller.settingsLoaded, @"Late A settings cannot enable pending B controls");
    check(![controller.fields[0].stringValue isEqual:@"-10"], @"Late A settings are never displayed under B");
    completeLoad(controller.settings.loads[1], values(-35, YES), nil);
    check([controller.fields[0].stringValue isEqual:@"-35"] && controller.saveButton.enabled, @"Only B's completion supplies B's values");
    [controller saveSettings:nil];
    check(controller.settings.saves.count == 1, @"Explicit Save dispatches one request");
    check([controller.settings.saves[0].projectUID isEqual:@"project-B"], @"Save uses the current project UID");
    completeSave(controller.settings.saves[0], nil);
    closeController(controller);
    groupCount += 1;
}

static void identicalUIDInAnotherLibraryCannotReceiveOldDraft(void) {
    SSHost *current = host(sequence(@"shared-project-id", @"/Test/Library-A.fcpbundle", @"Same name"));
    SSWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    controller.fields[0].stringValue = @"-46";
    // The host has changed, but its notification has not reached the UI yet.
    current.testTimeline.sequence = sequence(@"shared-project-id", @"/Test/Library-B.fcpbundle", @"Same name");
    [controller saveSettings:nil];
    check(controller.settings.saves.count == 0, @"A live library mismatch stops Save before persistence");
    check(controller.settings.loads.count == 2 && !controller.saveButton.enabled, @"A pending host notification triggers B's own load");
    check([controller.settings.loads[1].libraryURL.path isEqual:@"/Test/Library-B.fcpbundle"], @"Library location participates in the key");
    completeLoad(controller.settings.loads[1], values(-30, YES), nil);
    [controller saveSettings:nil];
    check(controller.settings.saves.count == 1, @"Save becomes available after B's values load");
    check([controller.settings.saves[0].libraryURL.path isEqual:@"/Test/Library-B.fcpbundle"] &&
          [controller.settings.saves[0].values[@"thresholdDBFS"] doubleValue] == -30,
          @"B receives its loaded settings, not A's unsaved draft");
    completeSave(controller.settings.saves[0], nil);
    closeController(controller);
    groupCount += 1;
}

static void lateSaveCannotEnableAnotherProject(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    controller.fields[0].stringValue = @"-41";
    [controller saveSettings:nil];
    check(controller.settings.saves.count == 1 && !controller.saveButton.enabled, @"A's explicit Save waits for its completion");
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    NSString *pendingStatus = controller.statusLabel.stringValue;
    completeSave(controller.settings.saves[0], nil);
    check(!controller.saveButton.enabled && !controller.settingsLoaded, @"Late A Save cannot enable pending B controls");
    check([controller.statusLabel.stringValue isEqual:pendingStatus], @"Late A Save does not replace B's pending status");
    check([controller.settings.saves[0].projectUID isEqual:@"project-A"], @"The already-requested Save remains bound to A");
    completeLoad(controller.settings.loads[1], values(-32, NO), nil);
    check(controller.saveButton.enabled, @"B enables only after its own load");
    closeController(controller);
    groupCount += 1;
}

static void disappearanceInvalidatesCallbacksAndReopenReloads(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSWorkflowViewController *controller = openController(current);
    [controller viewWillDisappear];
    check(current.testTimeline.observer == nil, @"Disappearance stops timeline observation");
    completeLoad(controller.settings.loads[0], values(-12, YES), nil);
    check(!controller.saveButton.enabled && controller.projectUID == nil, @"A completion after disappearance cannot reactivate the view");
    [controller viewDidAppear];
    check(current.testTimeline.addCount == 2 && controller.settings.loads.count == 2, @"Reopen registers once and reloads even the same project");
    completeLoad(controller.settings.loads[1], values(-47, YES), nil);
    check(controller.saveButton.enabled && [controller.fields[0].stringValue isEqual:@"-47"], @"Reopened view accepts only its new load");
    closeController(controller);
    groupCount += 1;
}

static void invalidHostAndIdentityNeverLoad(void) {
    SSWorkflowViewController *controller = openController([NSObject new]);
    check(controller.settings.loads.count == 0 && !controller.saveButton.enabled, @"An object lacking FCPXHost conformance cannot load settings");
    closeController(controller);
    SSHost *unrelated = host(sequence(@"project-A", @"/Test/A.fcpbundle", @"A"));
    unrelated.bundleIdentifier = @"example.unrelated-host";
    controller = openController(unrelated);
    check(controller.settings.loads.count == 0 && unrelated.testTimeline.addCount == 0, @"An unrelated host bundle cannot register observations or load settings");
    closeController(controller);
    for (NSString *unsupportedBundle in @[@"com.apple.FinalCutApp", @"com.apple.FinalCutTrial"]) {
        SSHost *unsupported = host(sequence(@"project-A", @"/Test/A.fcpbundle", @"A"));
        unsupported.bundleIdentifier = unsupportedBundle;
        SSTestWorkflowViewController *unsupportedController = openController(unsupported);
        check(unsupportedController.permissions.count == 0 && unsupported.timelineReadCount == 0 &&
              unsupported.testTimeline.addCount == 0 && unsupportedController.settings.loads.count == 0 &&
              !unsupportedController.saveButton.enabled,
              @"An unevidenced Final Cut variant cannot request consent, read project data, or load settings");
        closeController(unsupportedController);
    }
    SSHost *malformed = host(sequence(@"project-A", @"/Test/A.fcpbundle", @"A"));
    malformed.testTimeline.sequence.container.container.objectType = kFCPXObjectType_Project;
    controller = openController(malformed);
    check(controller.settings.loads.count == 0 && !controller.saveButton.enabled, @"Malformed project/event/library ancestry is unbound");
    closeController(controller);
    SSHost *remote = host(sequence(@"project-A", @"/Test/A.fcpbundle", @"A"));
    remote.testTimeline.sequence.container.container.container.url = [NSURL URLWithString:@"https://example.invalid/A.fcpbundle"];
    controller = openController(remote);
    check(controller.settings.loads.count == 0 && !controller.saveButton.enabled, @"A non-file library URL cannot authorize persistence");
    closeController(controller);
    SSHost *empty = host(nil);
    controller = openController(empty);
    check(controller.settings.loads.count == 0 && [controller.playheadLabel.stringValue isEqual:@"Playhead —"], @"No active sequence remains unbound without a manufactured playhead");
    closeController(controller);
    groupCount += 1;
}

static void invalidNumbersNeverDispatchSave(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    for (NSString *bad in @[@"not a number", @"-45 trailing", @"nan", @"inf"]) {
        controller.fields[0].stringValue = bad;
        [controller saveSettings:nil];
        check(controller.settings.saves.count == 0, @"Invalid or nonfinite numeric text never reaches persistence");
        check([controller.statusLabel.stringValue containsString:@"valid number"], @"Invalid numeric text reports an actionable status");
        check(controller.saveButton.enabled, @"A local input error leaves settings editable");
    }
    controller.fields[0].stringValue = @"-44.5";
    [controller.output selectItemAtIndex:1];
    [controller saveSettings:nil];
    check(controller.settings.saves.count == 1 &&
          [controller.settings.saves[0].values[@"thresholdDBFS"] doubleValue] == -44.5 &&
          [controller.settings.saves[0].values[@"outputMode"] isEqual:@"gaps"], @"A valid explicit Save carries the exact numeric value and selected output mode");
    completeSave(controller.settings.saves[0], [NSError errorWithDomain:@"test.persistence" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Test persistence failed"}]);
    check(controller.saveButton.enabled && [controller.statusLabel.stringValue isEqual:@"Test persistence failed"], @"A persistence failure is visible and permits correcting or retrying Save");
    closeController(controller);
    groupCount += 1;
}

static void delayedPermissionCannotReconnectHiddenView(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openControllerWithPermission(current, noErr, YES);
    check(controller.permissions.count == 1 && !controller.permissions[0].asksUser,
          @"Opening checks permission without requesting a user prompt");
    check(current.timelineReadCount == 0 && current.testTimeline.addCount == 0 && controller.settings.loads.count == 0,
          @"Pending permission does not query the SDK timeline, register an observer, or load settings");
    [controller viewWillDisappear];
    completePermission(controller.permissions[0], noErr);
    check(current.timelineReadCount == 0 && controller.timeline == nil && controller.settings.loads.count == 0,
          @"A late permission grant cannot reconnect a disappeared view");
    check(!controller.saveButton.enabled, @"A late permission grant cannot enable hidden persistence controls");
    [controller viewDidAppear];
    check(controller.permissions.count == 2 && !controller.permissions[1].asksUser,
          @"Reopening makes a new nonprompting permission check");
    NSUInteger generation = controller.contextGeneration;
    [controller activeSequenceChanged]; // A queued notification from the old appearance.
    check(controller.contextGeneration == generation && current.timelineReadCount == 0,
          @"A stale sequence callback while disconnected cannot invalidate the current permission check");
    completePermission(controller.permissions[1], noErr);
    check(current.timelineReadCount == 1 && current.testTimeline.addCount == 1 && controller.settings.loads.count == 1,
          @"Only the current appearance's permission completion connects and loads settings");
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    closeController(controller);
    groupCount += 1;
}

static void deniedPermissionKeepsConnectExplicit(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openControllerWithPermission(current, errAEEventWouldRequireUserConsent, NO);
    check(controller.permissions.count == 1 && !controller.permissions[0].asksUser,
          @"Initial consent-required observation cannot ask for permission");
    check(!controller.connectButton.hidden && controller.connectButton.enabled && !controller.saveButton.enabled,
          @"Consent-required state offers Connect while persistence stays disabled");
    check(current.timelineReadCount == 0 && controller.settings.loads.count == 0,
          @"Consent-required state does not access project data");
    controller.delaysPermission = YES;
    [controller requestConnection:nil]; // Direct action call, never an NSApp/UI event.
    check(controller.permissions.count == 2 && controller.permissions[1].asksUser,
          @"Only the explicit Connect action requests permission");
    check(!controller.connectButton.enabled && current.timelineReadCount == 0,
          @"Connect remains disabled while the explicit permission request is pending");
    completePermission(controller.permissions[1], errAEEventNotPermitted);
    check(!controller.connectButton.hidden && controller.connectButton.enabled && !controller.saveButton.enabled,
          @"Denied consent leaves Connect available and settings disabled");
    check(current.timelineReadCount == 0 && current.testTimeline.addCount == 0 && controller.settings.loads.count == 0,
          @"Denied consent never queries the timeline or starts persistence");
    controller.delaysPermission = NO;
    controller.permissionStatus = noErr; // Models a later external permission change, not a real grant.
    [controller requestConnection:nil];
    check(controller.permissions.count == 3 && controller.permissions[2].asksUser,
          @"A later explicit reconnect still uses the consent-request path");
    check(controller.connectButton.hidden && current.timelineReadCount == 1 && controller.settings.loads.count == 1,
          @"A successful current reconnect reads the timeline and hides Connect");
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    check(controller.saveButton.enabled, @"Persistence enables only after permission and the project load succeed");
    closeController(controller);
    groupCount += 1;
}

static NSDictionary *reviewResponse(NSString *state, NSString *message) {
    BOOL reviewing = [state isEqual:@"review"];
    return @{@"state": state, @"message": message, @"targetClipName": @"Disposable clip",
             @"summary": @"One selected silence", @"canRetryVerification": @NO,
             @"cuts": reviewing ? @[@{@"id": @"cut-1", @"start": @"1.000", @"end": @"2.000",
                 @"duration": @"1.000 sec", @"included": @YES, @"eligible": @YES}] : @[]};
}

static SSFakeWorkflowReviewClient *beginReview(SSTestWorkflowViewController *controller) {
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    check(client != nil && controller.reviewClient == client, @"Analyze uses the overridable transport factory");
    [client deliver:reviewResponse(@"review", @"Review the selected silence") busy:NO canApply:YES];
    return client;
}

static void analyzeDispatchPinsPayloadAndGesture(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Disposable A"));
    SSTestWorkflowViewController *controller = openController(current);
    check(controller.analyzeButton.target == controller && controller.analyzeButton.action == @selector(analyzeAudio:),
          @"The actual Analyze button is wired to the tested action");
    check(!controller.analyzeButton.enabled && !controller.applyButton.enabled, @"Analysis and Apply wait for project settings");
    [controller analyzeAudio:controller.analyzeButton];
    [controller applyCuts:controller.applyButton];
    check(controller.reviewClients.count == 0, @"Pending settings cannot create a review request");
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    controller.fields[0].stringValue = @"-41.5";
    controller.fields[1].stringValue = @"0.35";
    controller.fields[2].stringValue = @"0.12";
    controller.fields[3].stringValue = @"0.18";
    [controller.output selectItemAtIndex:1];
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    NSDictionary *payload = client.startPayload;
    check(client.startCount == 1 && controller.reviewClients.count == 1, @"One explicit Analyze starts exactly one request");
    check([payload[@"libraryURL"] isEqual:[NSURL fileURLWithPath:@"/Test/Library-A.fcpbundle" isDirectory:YES]] &&
          [payload[@"projectUID"] isEqual:@"project-A"] && [payload[@"projectName"] isEqual:@"Disposable A"],
          @"Analyze pins the SDK library URL, project UID, and displayed project name");
    check([payload[@"settings"] isEqual:@{@"thresholdDBFS": @-41.5, @"minimumSilenceDuration": @0.35,
          @"beforeSpeechPadding": @0.12, @"afterSpeechPadding": @0.18, @"outputMode": @"gaps"}],
          @"Analyze sends all current numeric drafts and the chosen output mode without a Save");
    NSString *gesture = payload[@"gesture"];
    check([[NSUUID alloc] initWithUUIDString:gesture] != nil &&
          [client.analyzeIdentifierAtDispatch isEqual:[@"silentsnip.workflow.analyze.requested." stringByAppendingString:gesture]],
          @"A canonical Analyze gesture is exposed by the actual button before client dispatch");
    check(client.analyzeDisabledAtDispatch && !controller.analyzeButton.enabled && !controller.applyButton.enabled &&
          !controller.saveButton.enabled && !controller.fields[0].enabled && !controller.output.enabled,
          @"Analyze disables itself and settings before dispatch and keeps Apply unavailable while pending");
    [controller analyzeAudio:controller.analyzeButton];
    [controller applyCuts:controller.applyButton];
    check(controller.reviewClients.count == 1 && client.startCount == 1 && client.applyGestures.count == 0,
          @"Repeated actions while pending neither launch another analysis nor apply an unreviewed plan");
    check(controller.settings.saves.count == 0, @"Analyze does not implicitly persist the settings draft");
    closeController(controller);
    groupCount += 1;
}

static void applyRequiresReviewAndFreshGesture(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    [controller applyCuts:controller.applyButton];
    check(!controller.applyButton.enabled && client.applyGestures.count == 0, @"An analysis without a ready review cannot Apply");
    [client deliver:reviewResponse(@"review", @"Review ready") busy:NO canApply:YES];
    check(controller.applyButton.target == controller && controller.applyButton.action == @selector(applyCuts:),
          @"The actual Apply button is wired to the tested action");
    check(controller.applyButton.enabled && controller.allButton.enabled && controller.noneButton.enabled &&
          controller.cutList.arrangedSubviews.count == 1 && ((NSButton *)controller.cutList.arrangedSubviews[0]).enabled,
          @"A ready review enables Apply and its eligible cut selection");
    [controller applyCuts:controller.applyButton];
    NSString *gesture = client.applyGestures.lastObject;
    check(client.applyGestures.count == 1 && [[NSUUID alloc] initWithUUIDString:gesture] != nil &&
          ![gesture isEqual:client.startPayload[@"gesture"]], @"Apply dispatches one new gesture distinct from Analyze");
    check(client.applyDisabledAtDispatch &&
          [client.applyIdentifierAtDispatch isEqual:[@"silentsnip.workflow.apply.requested." stringByAppendingString:gesture]],
          @"Apply is disabled and exposes its fresh authorization gesture before client dispatch");
    check(!controller.applyButton.enabled && !controller.analyzeButton.enabled && !controller.fields[0].enabled &&
          !controller.allButton.enabled && !((NSButton *)controller.cutList.arrangedSubviews[0]).enabled,
          @"Applying locks analysis, settings, and cut-selection actions");
    [controller applyCuts:controller.applyButton];
    check(client.applyGestures.count == 1, @"A second Apply action cannot duplicate an in-flight edit");
    closeController(controller);
    groupCount += 1;
}

static void editsInvalidateEveryReviewedSetting(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    for (NSUInteger index = 0; index < 5; ++index) {
        SSFakeWorkflowReviewClient *client = beginReview(controller);
        NSUInteger requests = controller.reviewClients.count;
        if (index < controller.fields.count) {
            controller.fields[index].stringValue = index == 0 ? @"-44" : @"0.2";
            [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:controller.fields[index]]];
        } else {
            [controller.output selectItemAtIndex:1];
            [controller settingsChanged:controller.output];
        }
        check(controller.reviewClient == nil && controller.reviewResponse == nil && controller.cutList.arrangedSubviews.count == 0 &&
              !controller.applyButton.enabled, @"Editing any reviewed field or output mode discards its applicable cut plan");
        check(client.cancelCount == 1 && client.detachCount == 1, @"An invalidated review is cancelled and detached once");
        check(controller.analyzeButton.enabled && controller.reviewClients.count == requests && controller.settings.saves.count == 0 &&
              [controller.statusLabel.stringValue containsString:@"Analyze again"],
              @"An edit stays local and requires a new explicit analysis without automatically saving or launching");
        NSString *status = controller.statusLabel.stringValue;
        client.testUpdate(reviewResponse(@"review", @"Stale review"));
        client.testFailure(@"Stale failure");
        check(controller.reviewClient == nil && !controller.applyButton.enabled && [controller.statusLabel.stringValue isEqual:status],
              @"Queued callbacks cannot restore a plan invalidated by a settings edit");
    }
    closeController(controller);
    groupCount += 1;
}

static void projectSwitchDiscardsIdleReview(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    check(client.cancelCount == 1 && client.detachCount == 1 && controller.reviewClient == nil && !controller.applyButton.enabled,
          @"An idle SDK project switch discards and detaches A's ready review");
    check([controller.projectUID isEqual:@"project-B"] && controller.settings.loads.count == 2 && !controller.settingsLoaded,
          @"A project switch binds B only through B's own settings load");
    NSString *status = controller.statusLabel.stringValue;
    client.testUpdate(reviewResponse(@"review", @"Late A review"));
    client.testFailure(@"Late A failure");
    check(controller.reviewClient == nil && !controller.applyButton.enabled && [controller.statusLabel.stringValue isEqual:status],
          @"A's late review and failure cannot change B's pending state");
    completeLoad(controller.settings.loads[1], values(-32, YES), nil);
    SSFakeWorkflowReviewClient *second = beginReview(controller);
    check([second.startPayload[@"projectUID"] isEqual:@"project-B"] &&
          [second.startPayload[@"libraryURL"] isEqual:[NSURL fileURLWithPath:@"/Test/Library-B.fcpbundle" isDirectory:YES]],
          @"The next explicit Analyze carries B's identity, never A's stale plan");
    check(![second.startPayload[@"gesture"] isEqual:client.startPayload[@"gesture"]], @"Each new Analyze exposes a fresh gesture");
    closeController(controller);
    groupCount += 1;
}

static void liveIdentityMismatchStopsAnalyzeAndApply(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Same name"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-B.fcpbundle", @"Same name");
    [controller analyzeAudio:controller.analyzeButton]; // SDK notification has not arrived.
    check(controller.reviewClients.count == 0 && controller.settings.loads.count == 2 && !controller.analyzeButton.enabled,
          @"Analyze checks the live library identity before creating a client even for a reused project UID");
    completeLoad(controller.settings.loads[1], values(-32, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    current.testTimeline.sequence = sequence(@"project-C", @"/Test/Library-B.fcpbundle", @"Same name");
    [controller applyCuts:controller.applyButton];
    check(client.applyGestures.count == 0 && client.detachCount == 1 && controller.settings.loads.count == 3 &&
          [controller.projectUID isEqual:@"project-C"] && !controller.applyButton.enabled,
          @"Apply checks the live project UID before sending an edit and invalidates the displaced review");
    closeController(controller);
    groupCount += 1;
}

static void busyWorkerDefersTemporarySDKBinding(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    NSUInteger generation = controller.contextGeneration;
    current.testTimeline.sequence = sequence(@"temporary-analysis", @"/Test/Library-A.fcpbundle", @"Temporary analysis");
    [current.testTimeline notifySequenceChanged];
    check([controller.projectUID isEqual:@"project-A"] && [controller.projectLabel.stringValue isEqual:@"A"] &&
          controller.contextGeneration == generation && controller.settings.loads.count == 1 && client.detachCount == 0,
          @"A busy Analyze defers temporary sequence callbacks without changing its pinned project or settings");
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
    [client deliver:reviewResponse(@"review", @"Review ready") busy:NO canApply:YES];
    [current.testTimeline notifySequenceChanged];
    check(controller.reviewClient == client && controller.applyButton.enabled && controller.settings.loads.count == 1,
          @"Returning to the original project preserves the finished Analyze review");
    [controller applyCuts:controller.applyButton];
    current.testTimeline.sequence = sequence(@"verified-result", @"/Test/Library-A.fcpbundle", @"Cleaned A");
    [current.testTimeline notifySequenceChanged];
    check([controller.projectUID isEqual:@"project-A"] && controller.contextGeneration == generation && client.detachCount == 0,
          @"A busy Apply also defers the worker's result-project callback");
    [client deliver:reviewResponse(@"completed", @"Verified result opened") busy:NO canApply:NO];
    check([controller.projectUID isEqual:@"verified-result"] && controller.settings.loads.count == 2 &&
          controller.reviewClient == nil && !controller.applyButton.enabled,
          @"Only terminal worker completion binds the SDK result project and drops the old review");
    completeLoad(controller.settings.loads[1], values(-50, NO), nil);
    check([controller.statusLabel.stringValue isEqual:@"Ready. Save settings for this project."] && controller.analyzeButton.enabled &&
          !controller.completionMessage,
          @"The result's settings load restores analysis without attaching a source-scoped notice to a new SDK identity");
    closeController(controller);
    groupCount += 1;
}

static void closingReviewRejectsLateCallbacksAfterReopen(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *old = controller.reviewClients.lastObject;
    [controller viewWillDisappear];
    check(old.cancelCount == 1 && old.detachCount == 1 && controller.reviewClient == nil && !controller.analyzeButton.enabled &&
          !controller.applyButton.enabled, @"Closing cancels and detaches the active request and disables its controls");
    NSString *closedStatus = controller.statusLabel.stringValue;
    old.testUpdate(reviewResponse(@"review", @"Late hidden review"));
    old.testFailure(@"Late hidden failure");
    check(controller.reviewClient == nil && controller.reviewResponse == nil && !controller.applyButton.enabled &&
          [controller.statusLabel.stringValue isEqual:closedStatus], @"Late transport callbacks cannot reactivate a hidden view");
    [controller viewDidAppear];
    completeLoad(controller.settings.loads[1], values(-47, YES), nil);
    SSFakeWorkflowReviewClient *fresh = beginReview(controller);
    NSString *freshStatus = controller.statusLabel.stringValue;
    old.testUpdate(reviewResponse(@"review", @"Late previous appearance"));
    old.testFailure(@"Late previous failure");
    check(controller.reviewClient == fresh && controller.applyButton.enabled && fresh.detachCount == 0 &&
          [controller.statusLabel.stringValue isEqual:freshStatus], @"Old appearance callbacks cannot replace or detach the new ready review");
    closeController(controller);
    groupCount += 1;
}

static void malformedAnalyzeAndCurrentFailureStayLocal(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    for (NSString *bad in @[@"nan", @"-40 trailing", @"not a number"]) {
        controller.fields[0].stringValue = bad;
        [controller analyzeAudio:controller.analyzeButton];
        check(controller.reviewClients.count == 0 && controller.analyzeButton.enabled &&
              [controller.statusLabel.stringValue containsString:@"valid number"],
              @"Malformed Analyze values fail locally before creating a client and remain editable");
    }
    controller.fields[0].stringValue = @"-47";
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    client.testFailure(@"Updated worker required");
    check(client.detachCount == 1 && controller.reviewClient == nil && controller.analyzeButton.enabled &&
          controller.fields[0].enabled && !controller.applyButton.enabled &&
          [controller.statusLabel.stringValue isEqual:@"Updated worker required"],
          @"A current client failure drops its plan, displays the exact error, and restores editable Analyze controls");
    closeController(controller);
    groupCount += 1;
}

static void retryableResultRetainsRecoveryUntilVerified(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    current.testTimeline.sequence = sequence(@"imported-result", @"/Test/Library-A.fcpbundle", @"Cleaned A");
    [current.testTimeline notifySequenceChanged];
    NSMutableDictionary *failed = [reviewResponse(@"failed", @"Result exists; retry verification") mutableCopy];
    failed[@"canRetryVerification"] = @YES;
    [client deliver:failed busy:NO canApply:NO];
    check(controller.reviewClient == client && client.detachCount == 0 && client.cancelCount == 0 &&
          [controller.projectUID isEqual:@"project-A"] && controller.settings.loads.count == 1,
          @"A retryable failure after the imported result opens retains the original request instead of rebinding or detaching it");
    check(!controller.retryButton.hidden && controller.retryButton.enabled && !controller.applyButton.enabled &&
          !controller.analyzeButton.enabled && !controller.saveButton.enabled && !controller.fields[0].enabled && !controller.output.enabled,
          @"Retry remains available while new analysis, Apply, and setting edits stay disabled during recovery");
    NSString *playhead = controller.playheadLabel.stringValue;
    NSUInteger generation = controller.contextGeneration;
    current.testTimeline.currentPlayhead = CMTimeMake(3619, 1);
    [current.testTimeline notifySequenceChanged];
    [controller playheadTimeChanged];
    [controller sequenceTimeRangeChanged];
    [controller settingsChanged:controller.output];
    [controller analyzeAudio:controller.analyzeButton];
    check(controller.reviewClient == client && client.detachCount == 0 && controller.reviewClients.count == 1 &&
          controller.contextGeneration == generation && controller.settings.loads.count == 1 &&
          [controller.playheadLabel.stringValue isEqual:playhead],
          @"Deferred SDK/result callbacks and stale edit or Analyze actions cannot discard a pending result-verification request");
    [controller retryVerification:controller.retryButton];
    [controller retryVerification:controller.retryButton];
    check(client.retryCount == 1 && client.busy && !controller.retryButton.enabled && !controller.analyzeButton.enabled,
          @"The retained Retry action starts one verification and cannot duplicate it while pending");
    [client deliver:reviewResponse(@"verifying", @"Checking the existing imported result") busy:YES canApply:NO];
    [current.testTimeline notifySequenceChanged];
    check(controller.reviewClient == client && controller.settings.loads.count == 1 && [controller.projectUID isEqual:@"project-A"],
          @"Clearing the retry flag during active verification still defers SDK rebinding until work finishes");
    [client deliver:reviewResponse(@"completed", @"Existing result verified") busy:NO canApply:NO];
    check(client.detachCount == 1 && controller.reviewClient == nil && [controller.projectUID isEqual:@"imported-result"] &&
          controller.settings.loads.count == 2 && controller.retryButton.hidden && !controller.analyzeButton.enabled,
          @"Successful verification settles recovery, then loads the actual result project's own settings");
    completeLoad(controller.settings.loads[1], values(-32, NO), nil);
    check(controller.analyzeButton.enabled && controller.saveButton.enabled && controller.fields[0].enabled &&
          [controller.fields[0].stringValue isEqual:@"-32"] && [controller.statusLabel.stringValue isEqual:@"Ready. Save settings for this project."] &&
          !controller.completionMessage,
          @"Only the result's own settings completion restores editing without borrowing the source project's terminal notice");
    closeController(controller);
    groupCount += 1;
}

static void busyPlayheadWaitsForTheSettledProject(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    NSString *originalPlayhead = controller.playheadLabel.stringValue;
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    current.testTimeline.sequence = sequence(@"temporary-analysis", @"/Test/Library-A.fcpbundle", @"Temporary");
    current.testTimeline.sequence.startTime = CMTimeMake(0, 1);
    current.testTimeline.currentPlayhead = CMTimeMake(9, 1);
    [controller playheadTimeChanged];
    [controller sequenceTimeRangeChanged];
    [current.testTimeline notifySequenceChanged];
    check([controller.projectLabel.stringValue isEqual:@"A"] && [controller.playheadLabel.stringValue isEqual:originalPlayhead],
          @"Busy SDK time and range callbacks cannot display a temporary project's playhead under the pinned original name");
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
    current.testTimeline.currentPlayhead = CMTimeMake(7229, 2); // 14.5 seconds in the settled original project.
    [client deliver:reviewResponse(@"review", @"Review ready") busy:NO canApply:YES];
    [controller playheadTimeChanged];
    check([controller.playheadLabel.stringValue isEqual:@"Playhead 14.500 sec"] && controller.reviewClient == client,
          @"Once analysis settles, a current-project time callback updates the playhead without discarding its review");
    [controller applyCuts:controller.applyButton];
    current.testTimeline.sequence = sequence(@"result-project", @"/Test/Library-A.fcpbundle", @"Cleaned A");
    current.testTimeline.sequence.startTime = CMTimeMake(0, 1);
    current.testTimeline.currentPlayhead = CMTimeMake(7, 1);
    [controller playheadTimeChanged];
    check([controller.playheadLabel.stringValue isEqual:@"Playhead 14.500 sec"], @"Apply also freezes the original playhead while its result is opening");
    [client deliver:reviewResponse(@"completed", @"Verified result") busy:NO canApply:NO];
    check([controller.projectLabel.stringValue isEqual:@"Cleaned A"] && [controller.playheadLabel.stringValue isEqual:@"Playhead 7.000 sec"],
          @"Terminal completion updates project identity and playhead together from the settled SDK context");
    closeController(controller);
    groupCount += 1;
}

static void pendingSaveCannotReplaceWorkerProgressOrRecovery(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    [controller saveSettings:controller.saveButton];
    check(controller.settings.saves.count == 1 && controller.applyButton.enabled,
          @"The fixture holds one Save completion while an already-reviewed Apply remains available");
    [controller applyCuts:controller.applyButton];
    [client deliver:reviewResponse(@"applying", @"Rendering current audio for Apply") busy:YES canApply:NO];
    completeSave(controller.settings.saves[0], nil);
    check([controller.statusLabel.stringValue isEqual:@"Rendering current audio for Apply"] && !controller.fields[0].enabled &&
          !controller.saveButton.enabled && !controller.analyzeButton.enabled,
          @"A successful delayed Save cannot overwrite active worker progress or re-enable settings during Apply");
    closeController(controller);
    current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    client = beginReview(controller);
    [controller saveSettings:controller.saveButton];
    check(controller.settings.saves.count == 1, @"The recovery case holds a separate pending Save completion");
    [controller applyCuts:controller.applyButton];
    NSMutableDictionary *failed = [reviewResponse(@"failed", @"Result pending verification; use Retry") mutableCopy];
    failed[@"canRetryVerification"] = @YES;
    [client deliver:failed busy:NO canApply:NO];
    completeSave(controller.settings.saves[0], [NSError errorWithDomain:@"test.persistence" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Late Save failed"}]);
    check([controller.statusLabel.stringValue isEqual:@"Result pending verification; use Retry"] && controller.retryButton.enabled &&
          !controller.analyzeButton.enabled && !controller.saveButton.enabled && !controller.fields[0].enabled,
          @"Even a delayed Save error cannot replace recovery guidance or unlock a retryable result's settings");
    closeController(controller);
    groupCount += 1;
}

static void synchronousApplyActivationFailureKeepsReviewUsable(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSArray *cuts = controller.reviewCuts;
    client.failApplyActivationSynchronously = YES;
    [controller applyCuts:controller.applyButton];
    check(client.applyGestures.count == 1 && client.applyCommandCount == 0 && !client.busy,
          @"An immediate Apply activation failure sends no worker Apply command and releases local pending state");
    check(controller.reviewClient == client && client.detachCount == 0 && [controller.reviewCuts isEqual:cuts] &&
          controller.applyButton.enabled && controller.analyzeButton.enabled && controller.saveButton.enabled &&
          controller.fields[0].enabled && controller.output.enabled,
          @"A synchronous recoverable failure preserves the plan and leaves Apply and settings usable after the action returns");
    check([controller.statusLabel.stringValue isEqual:@"Activate Final Cut Pro, then choose Apply again."],
          @"The recoverable activation guidance survives the remainder of the Apply action");
    NSString *failedGesture = client.applyGestures.lastObject;
    client.failApplyActivationSynchronously = NO;
    [controller applyCuts:controller.applyButton];
    check(client.applyGestures.count == 2 && client.applyCommandCount == 1 && client.busy && !controller.applyButton.enabled &&
          ![client.applyGestures.lastObject isEqual:failedGesture],
          @"A later explicit Apply can retry the same review with a fresh gesture and dispatch only once");
    closeController(controller);
    groupCount += 1;
}

static void terminalNoticeStaysWithItsPinnedProject(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    current.testTimeline.sequence = sequence(@"verified-result", @"/Test/Library-A.fcpbundle", @"Cleaned A");
    [current.testTimeline notifySequenceChanged];
    [client deliver:reviewResponse(@"completed", @"Verified Cleaned A") busy:NO canApply:NO];
    completeLoad(controller.settings.loads[1], values(-47, NO), nil);
    check([controller.projectUID isEqual:@"verified-result"] && [controller.statusLabel.stringValue isEqual:@"Ready. Save settings for this project."] &&
          !controller.completionMessage && !controller.completionContext,
          @"Automatic result rebinding clears a source-scoped notice because the response has no verified result identity");
    [current.testTimeline notifySequenceChanged];
    check(controller.settings.loads.count == 2 && [controller.statusLabel.stringValue isEqual:@"Ready. Save settings for this project."],
          @"Duplicate callbacks for the result preserve its current settings status without reviving a source notice");

    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-A.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    check(!controller.completionMessage && !controller.completionContext && !controller.reviewClient && !controller.applyButton.enabled,
          @"Changing project UID in the same library clears the prior verification notice and all review authority");
    completeLoad(controller.settings.loads[2], values(-32, YES), nil);
    check([controller.statusLabel.stringValue isEqual:@"Saved settings loaded for this project."] &&
          [controller.reviewSummary.stringValue isEqual:@"Select one timeline clip with audio, then Analyze."],
          @"The new project's own loaded status replaces the old result notice before another Analyze");
    client.testUpdate(reviewResponse(@"completed", @"Late verified Cleaned A"));
    check(!controller.completionMessage && [controller.statusLabel.stringValue isEqual:@"Saved settings loaded for this project."],
          @"A queued terminal callback cannot restore a cleared notice after rebinding");

    client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    [client deliver:reviewResponse(@"completed", @"Verified B in Library A") busy:NO canApply:NO];
    check([controller.completionContext[@"projectUID"] isEqual:@"project-B"], @"A same-context terminal result also receives a scoped notice");
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    completeLoad(controller.settings.loads[3], values(-40, NO), nil);
    check(!controller.completionMessage && !controller.completionContext &&
          [controller.statusLabel.stringValue isEqual:@"Ready. Save settings for this project."],
          @"A reused project UID in another library cannot inherit the prior library's terminal notice");

    client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    [client deliver:reviewResponse(@"completed", @"Verified B in Library B") busy:NO canApply:NO];
    [controller viewWillDisappear];
    check(!controller.completionMessage && !controller.completionContext, @"Closing the extension clears its terminal notice identity");
    [controller viewDidAppear];
    completeLoad(controller.settings.loads[4], values(-40, YES), nil);
    check([controller.statusLabel.stringValue isEqual:@"Saved settings loaded for this project."] && !controller.completionMessage &&
          !controller.applyButton.enabled, @"Reopening the same project shows its current settings status without a historical verification claim");
    closeController(controller);
    groupCount += 1;
}

static void delayedTerminalCannotClaimTheNewSDKProject(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"Unrelated B");
    [current.testTimeline notifySequenceChanged];
    check([controller.projectUID isEqual:@"project-A"] && controller.settings.loads.count == 1 && client.busy,
          @"The unrelated SDK switch is deferred while A's actual request is still busy");
    [client deliver:reviewResponse(@"completed", @"Verified result for A") busy:NO canApply:NO];
    check([controller.projectUID isEqual:@"project-B"] && [controller.projectLabel.stringValue isEqual:@"Unrelated B"] &&
          !controller.completionMessage && !controller.completionContext && !controller.reviewClient && !controller.applyButton.enabled &&
          [controller.statusLabel.stringValue isEqual:@"Loading project settings…"],
          @"Delayed completion for A cannot attach a verified notice or edit authority to the unrelated SDK project B");
    completeLoad(controller.settings.loads[1], values(-32, YES), nil);
    check([controller.statusLabel.stringValue isEqual:@"Saved settings loaded for this project."] && controller.analyzeButton.enabled &&
          !controller.applyButton.enabled, @"B finishes loading with only its own status and remains unanalyzed");
    client.testUpdate(reviewResponse(@"completed", @"Late second verified result for A"));
    check(!controller.completionMessage && [controller.statusLabel.stringValue isEqual:@"Saved settings loaded for this project."],
          @"A further queued terminal response cannot restore A's notice after B has bound");
    closeController(controller);
    groupCount += 1;
}

static BOOL nearlyEqualSize(NSSize first, NSSize second) {
    return fabs(first.width - second.width) < 0.5 && fabs(first.height - second.height) < 0.5;
}

static void logOffscreenGeometry(NSString *phase, NSView *parent, SSWorkflowViewController *controller) {
    if (!getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) return;
    fprintf(stderr, "%s parent=%s bounds=%s autosizes=%d root=%s mask=%lu translates=%d scroll=%s clip=%s document=%s\n",
            phase.UTF8String, NSStringFromRect(parent.frame).UTF8String, NSStringFromRect(parent.bounds).UTF8String,
            parent.autoresizesSubviews, NSStringFromRect(controller.view.frame).UTF8String,
            (unsigned long)controller.view.autoresizingMask, controller.view.translatesAutoresizingMaskIntoConstraints,
            NSStringFromRect(controller.scroll.frame).UTF8String, NSStringFromRect(controller.scroll.contentView.bounds).UTF8String,
            NSStringFromRect(controller.content.frame).UTF8String);
    fprintf(stderr, "parent constraints=%s\nroot constraints=%s\n", parent.constraints.description.UTF8String,
            controller.view.constraints.description.UTF8String);
}

static void settleOffscreenLayout(NSView *parent, SSWorkflowViewController *controller) {
    // A document-height change can make the automatic scroller appear and
    // change the clip width. Exercise the same bounded layout/tile passes an
    // AppKit parent performs, without a window, drawing, or event processing.
    for (NSUInteger pass = 0; pass < 3; ++pass) {
        [parent layoutSubtreeIfNeeded];
        [controller.view layoutSubtreeIfNeeded];
        [controller.scroll tile];
        [controller.reviewScroll tile];
        [controller viewDidLayout];
    }
}

static NSRect frameInRoot(NSView *view, SSWorkflowViewController *controller) {
    return [view convertRect:view.bounds toView:controller.view];
}

static void checkStickyChrome(SSWorkflowViewController *controller) {
    NSRect root = NSInsetRect(controller.view.bounds, -0.5, -0.5);
    NSRect header = frameInRoot(controller.headerView, controller);
    NSRect footer = frameInRoot(controller.footerView, controller);
    NSRect body = frameInRoot(controller.scroll, controller);
    check(!NSIsEmptyRect(header) && NSContainsRect(root, header) &&
          ![controller.headerView isDescendantOf:controller.content],
          @"The project header stays within the host viewport, outside the scrolling body");
    check(!NSIsEmptyRect(footer) && NSContainsRect(root, footer) &&
          ![controller.footerView isDescendantOf:controller.content],
          @"The action footer stays within the host viewport, outside the scrolling body");
    check(!NSIsEmptyRect(body) && NSContainsRect(root, body) &&
          !NSIntersectsRect(NSInsetRect(header, 0.5, 0.5), NSInsetRect(body, 0.5, 0.5)) &&
          !NSIntersectsRect(NSInsetRect(footer, 0.5, 0.5), NSInsetRect(body, 0.5, 0.5)),
          @"The body viewport occupies the space between the fixed header and actions");
    for (NSButton *button in @[controller.analyzeButton, controller.applyButton, controller.cancelButton]) {
        NSRect rect = frameInRoot(button, controller);
        check(!button.hidden && !NSIsEmptyRect(rect) && NSContainsRect(root, rect),
              @"Analyze, Apply, and the native Cancel marker remain visible without body scrolling");
    }
    check([controller.cancelButton.accessibilityIdentifier isEqual:
           [@"silentsnip.workflow.review." stringByAppendingString:controller.viewID]],
          @"The fixed Cancel control preserves the worker's exact native view marker");
}

static void checkBodyWidth(SSWorkflowViewController *controller) {
    check(fabs(controller.content.frame.size.width - controller.scroll.contentView.bounds.size.width) < 0.5,
          @"Document width follows the actual body clip width, including scroller space");
    check(!controller.scroll.hasHorizontalScroller,
          @"The compact body does not require horizontal scrolling");
    NSEdgeInsets insets = controller.content.edgeInsets;
    CGFloat expectedWidth = controller.content.bounds.size.width - insets.left - insets.right;
    for (NSView *panel in @[controller.settingsPanel, controller.reviewPanel]) {
        NSRect rect = [panel convertRect:panel.bounds toView:controller.content];
        check(!NSIsEmptyRect(rect) && fabs(NSMinX(rect) - insets.left) < 0.5 &&
              fabs(rect.size.width - expectedWidth) < 0.5,
              @"The compact settings band and review each use the full body width");
    }
    check(controller.content.orientation == NSUserInterfaceLayoutOrientationVertical,
          @"Settings remain above the full-width review at every viewport size");
}

static void checkNumericGroupArrangement(SSWorkflowViewController *controller, BOOL wide) {
    NSMutableArray<NSValue *> *rectangles = [NSMutableArray new];
    for (NSTextField *field in controller.fields) {
        NSRect rect = [field convertRect:field.bounds toView:controller.settingsPanel];
        check(!NSIsEmptyRect(rect) && NSContainsRect(NSInsetRect(controller.settingsPanel.bounds, -0.5, -0.5), rect),
              @"Every numeric setting stays inside the compact settings band");
        [rectangles addObject:[NSValue valueWithRect:rect]];
    }
    NSRect first = rectangles[0].rectValue, second = rectangles[1].rectValue;
    NSRect third = rectangles[2].rectValue, fourth = rectangles[3].rectValue;
    if (wide) {
        check(fabs(NSMidY(first) - NSMidY(second)) < 0.5 && fabs(NSMidY(first) - NSMidY(third)) < 0.5 &&
              fabs(NSMidY(first) - NSMidY(fourth)) < 0.5 && NSMaxX(first) < NSMinX(second) &&
              NSMaxX(second) < NSMinX(third) && NSMaxX(third) < NSMinX(fourth),
              @"The normal window presents all four numeric settings in one compact row");
    } else {
        check(fabs(NSMidY(first) - NSMidY(second)) < 0.5 && fabs(NSMidY(third) - NSMidY(fourth)) < 0.5 &&
              fabs(NSMidY(first) - NSMidY(third)) >= first.size.height &&
              fabs(NSMinX(first) - NSMinX(third)) < 0.5 && fabs(NSMinX(second) - NSMinX(fourth)) < 0.5,
              @"A narrow window reflows the four settings into two aligned rows of two");
    }
    NSRect output = [controller.output convertRect:controller.output.bounds toView:controller.settingsPanel];
    NSRect save = [controller.saveButton convertRect:controller.saveButton.bounds toView:controller.settingsPanel];
    check(fabs(NSMidY(output) - NSMidY(save)) <= 3 && NSMaxX(output) <= NSMinX(save),
          @"Output and Save share one compact row without overlapping");
}

static void revealBodyControl(NSView *control, SSWorkflowViewController *controller) {
    NSRect rect = [control convertRect:control.bounds toView:controller.content];
    check(!NSIsEmptyRect(rect), @"A scrollable settings or review control has usable geometry");
    [controller.content scrollRectToVisible:rect];
    [controller.scroll reflectScrolledClipView:controller.scroll.contentView];
    NSRect visible = controller.scroll.contentView.documentVisibleRect;
    check(NSContainsRect(NSInsetRect(visible, -0.5, -0.5), rect),
          @"Each settings and review control can be brought fully into the short body viewport");
    checkStickyChrome(controller);
}

static void exerciseOffscreenParentResize(BOOL constrainsHostSize) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    controller.fields[0].stringValue = @"-43";
    NSUInteger generation = controller.contextGeneration;
    NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
    NSLayoutConstraint *hostWidth = nil;
    NSLayoutConstraint *hostHeight = nil;
    if (constrainsHostSize) {
        // Exercise a host with authoritative Auto Layout dimensions as well
        // as the frame-driven host below. Neither case changes the actual
        // controller root's autoresizing mask or content constraints.
        parent.translatesAutoresizingMaskIntoConstraints = NO;
        hostWidth = [parent.widthAnchor constraintEqualToConstant:480];
        hostHeight = [parent.heightAnchor constraintEqualToConstant:640];
        [NSLayoutConstraint activateConstraints:@[hostWidth, hostHeight]];
    }
    [parent addSubview:controller.view];
    settleOffscreenLayout(parent, controller);
    logOffscreenGeometry(@"initial", parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"The initial root view fills its host-sized parent");
    check(controller.scroll.documentView == controller.content && controller.content.isFlipped,
          @"The scroll document uses a top-origin coordinate system");
    check(controller.reviewScroll.documentView == controller.cutList,
          @"The cut list has its own review viewport instead of extending the whole window");
    checkStickyChrome(controller);
    checkBodyWidth(controller);

    hostHeight.constant = 300;
    [parent setFrameSize:NSMakeSize(480, 300)];
    logOffscreenGeometry(@"shrink before layout", parent, controller);
    settleOffscreenLayout(parent, controller);
    logOffscreenGeometry(@"shrink after layout", parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"Reducing parent height resizes the root instead of clipping a fixed-height root");
    checkStickyChrome(controller);
    checkBodyWidth(controller);
    check(controller.content.orientation == NSUserInterfaceLayoutOrientationVertical,
          @"Narrow host windows keep settings above the full-width review");
    checkNumericGroupArrangement(controller, NO);
    check(controller.content.frame.size.height > controller.scroll.contentView.bounds.size.height,
          @"The short parent exercises real vertical overflow rather than compressing away content");
    for (NSTextField *field in controller.fields) revealBodyControl(field, controller);
    revealBodyControl(controller.output, controller);
    revealBodyControl(controller.saveButton, controller);
    revealBodyControl(controller.reviewScroll, controller);

    CGFloat narrowWidth = controller.content.frame.size.width;
    hostWidth.constant = 840;
    hostHeight.constant = 477;
    [parent setFrameSize:NSMakeSize(840, 477)];
    settleOffscreenLayout(parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"The production-sized host still owns the root dimensions");
    check(controller.content.frame.size.width > narrowWidth + 200 &&
          fabs(controller.content.frame.size.width - controller.scroll.contentView.bounds.size.width) < 0.5,
          @"The document follows a wider clip viewport");
    checkNumericGroupArrangement(controller, YES);
    [controller.scroll.contentView scrollToPoint:NSZeroPoint];
    [controller.scroll reflectScrolledClipView:controller.scroll.contentView];
    settleOffscreenLayout(parent, controller);
    checkStickyChrome(controller);
    checkBodyWidth(controller);
    NSRect visible = NSInsetRect(controller.scroll.contentView.documentVisibleRect, -0.5, -0.5);
    NSMutableArray<NSView *> *normalControls = [controller.fields mutableCopy];
    [normalControls addObjectsFromArray:@[controller.output, controller.saveButton, controller.reviewScroll]];
    for (NSView *control in normalControls) {
        NSRect rect = [control convertRect:control.bounds toView:controller.content];
        check(!NSIsEmptyRect(rect) && NSContainsRect(visible, rect),
              @"The compact settings band and review viewport fit the normal 840-by-477 window without outer scrolling");
    }
    check([controller.fields[0].stringValue isEqual:@"-43"] && controller.contextGeneration == generation &&
          controller.settings.loads.count == 1 && controller.settings.saves.count == 0,
          @"Resizing and scrolling preserve the draft without loading, saving, or rebinding settings");
    [controller.view removeFromSuperview];
    closeController(controller);
    groupCount += 1;
}

static void offscreenParentResizeKeepsContentReachable(void) {
    exerciseOffscreenParentResize(YES);
}

static void frameDrivenParentResizeKeepsContentReachable(void) {
    // The native SDK window can supply a frame-driven viewport without
    // required parent-size constraints in the extension's layout engine.
    // A preferredContentSize assignment previously installed priority-501
    // root dimensions and made this exact case revert to 480x640, clipping
    // the header while the scroll viewport incorrectly thought it all fit.
    // Use the actual production controller: no preferred-size override.
    exerciseOffscreenParentResize(NO);
}

static NSDictionary *syntheticEighteenCutReview(void) {
    NSMutableArray *cuts = [NSMutableArray new];
    for (NSUInteger index = 0; index < 18; ++index) {
        NSString *start = [NSString stringWithFormat:@"01:00:%02lu:00", (unsigned long)(index * 3)];
        NSString *end = [NSString stringWithFormat:@"01:00:%02lu:00", (unsigned long)(index * 3 + 1)];
        NSString *duration = @"1.000 sec";
        if (index == 0) {
            start = @"123:59:59:29";
            end = @"124:01:23:13";
            duration = @"1 min 23.456 sec";
        } else if (index == 17) {
            start = @"00:00:00:00";
            end = @"34:17:36:23";
            duration = @"123456.767 sec";
        }
        [cuts addObject:@{@"id": [NSString stringWithFormat:@"synthetic-cut-%lu", (unsigned long)index],
            @"start": start, @"end": end, @"duration": duration, @"included": @(index != 3),
            @"eligible": @(index != 3), @"reason": index == 3 ? @"Protected synthetic range" : @""}];
    }
    return @{@"state": @"review", @"message": @"Review the generated cut ranges.",
        @"targetClipName": @"Synthetic 18-cut layout fixture", @"summary": @"17 selected · 18 detected ranges",
        @"canRetryVerification": @NO, @"cuts": cuts};
}

static void checkStructuredCutRows(SSWorkflowViewController *controller, NSArray<NSDictionary *> *cuts) {
    check(controller.cutList.arrangedSubviews.count == 18 && cuts.count == 18,
          @"The generated review exercises eighteen complete structured cut rows");
    if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) fprintf(stderr,
        "cut document root=%s frame=%s bounds=%s clip=%s viewport=%s horizontal=%d\n",
        NSStringFromRect(controller.view.bounds).UTF8String, NSStringFromRect(controller.cutList.frame).UTF8String,
        NSStringFromRect(controller.cutList.bounds).UTF8String, NSStringFromRect(controller.reviewScroll.contentView.bounds).UTF8String,
        NSStringFromRect(controller.reviewScroll.frame).UTF8String, controller.reviewScroll.hasHorizontalScroller);
    check(!controller.reviewScroll.hasHorizontalScroller &&
          fabs(controller.cutList.frame.size.width - controller.reviewScroll.contentView.bounds.size.width) < 0.5,
          @"The cut document follows its review viewport without horizontal overflow");
    NSRect priorColumns[3];
    for (NSUInteger index = 0; index < cuts.count; ++index) {
        NSView *view = controller.cutList.arrangedSubviews[index];
        check([view isKindOfClass:SSWorkflowCutRow.class],
              @"A structured timing row remains a native checkbox subclass");
        SSWorkflowCutRow *row = (SSWorkflowCutRow *)view;
        NSDictionary *cut = cuts[index];
        NSArray<NSString *> *values = @[row.startValue, row.endValue, row.durationValue];
        check([row.startValue isEqual:cut[@"start"]] && [row.endValue isEqual:cut[@"end"]] &&
              [row.durationValue isEqual:cut[@"duration"]] && row.tag == (NSInteger)index &&
              row.target == controller && row.action == @selector(toggleCut:),
              @"Each checkbox retains its full timing values, row identity, and selection action");
        check(row.state == ([cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff) &&
              row.enabled == [cut[@"eligible"] boolValue],
              @"Included and protected ranges keep their native checkbox state and eligibility");
        NSRect rowRect = [row convertRect:row.bounds toView:controller.cutList];
        check(!NSIsEmptyRect(rowRect) && NSMinX(rowRect) >= -0.5 &&
              NSMaxX(rowRect) <= NSMaxX(controller.cutList.bounds) + 0.5,
              @"Every row fills the available review width without extending beyond its document");
        NSRect previous = NSZeroRect;
        for (NSUInteger column = 0; column < values.count; ++column) {
            NSRect rect = [row columnRectForIndex:column];
            NSSize text = [values[column] sizeWithAttributes:@{NSFontAttributeName: row.textFont}];
            if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG") && text.width > rect.size.width + 0.5)
                fprintf(stderr, "cut fit width=%.1f row=%lu col=%lu text=%s measured=%.2f rect=%s\n",
                    controller.view.bounds.size.width, (unsigned long)index, (unsigned long)column,
                    values[column].UTF8String, text.width, NSStringFromRect(rect).UTF8String);
            check(!NSIsEmptyRect(rect) && NSContainsRect(NSInsetRect(row.bounds, -0.5, -0.5), rect) &&
                  text.width <= rect.size.width + 0.5 && text.height <= rect.size.height + 1,
                  @"The actual drawing column fits the entire start, end, or long duration value without ellipsis or clipping");
            check(column == 0 ? NSMinX(rect) >= 24 : NSMaxX(previous) <= NSMinX(rect),
                  @"Timing columns do not overlap each other or the native checkbox");
            check([row.accessibilityLabel containsString:values[column]] && [row.toolTip containsString:values[column]],
                  @"Complete displayed timing values remain available to accessibility and tooltips");
            if (index > 0) check(fabs(NSMinX(rect) - NSMinX(priorColumns[column])) < 0.5 &&
                                 fabs(rect.size.width - priorColumns[column].size.width) < 0.5,
                                 @"Every cut uses the same aligned timing-column geometry");
            priorColumns[column] = rect;
            previous = rect;
        }
    }
    SSWorkflowCutRow *first = (SSWorkflowCutRow *)controller.cutList.arrangedSubviews.firstObject;
    check(controller.cutColumnHeader.arrangedSubviews.count == 3,
          @"Start, End, and Duration have separate column headings");
    NSArray *headings = @[@"Start", @"End", @"Duration"];
    if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) fprintf(stderr,
        "cut header frame=%s bounds=%s constant=%.2f panel=%s\n",
        NSStringFromRect(controller.cutColumnHeader.frame).UTF8String,
        NSStringFromRect(controller.cutColumnHeader.bounds).UTF8String,
        controller.cutColumnHeaderWidthConstraint.constant, NSStringFromRect(controller.reviewPanel.bounds).UTF8String);
    for (NSUInteger column = 0; column < 3; ++column) {
        NSTextField *heading = (NSTextField *)controller.cutColumnHeader.arrangedSubviews[column];
        // NSStackView places label alignment rectangles. NSTextField's frame
        // and cell drawing/title rects include its extra native side padding,
        // so compare that documented alignment anchor, not the outer frame.
        NSRect headingAlignment = [heading alignmentRectForFrame:heading.frame];
        NSRect headingRect = [heading.superview convertRect:headingAlignment toView:controller.reviewPanel];
        NSRect valueRect = [first convertRect:[first columnRectForIndex:column] toView:controller.reviewPanel];
        if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) fprintf(stderr,
            "cut heading rootWidth=%.1f column=%lu heading=%s value=%s title=%s align=%s\n", controller.view.bounds.size.width,
            (unsigned long)column, NSStringFromRect(headingRect).UTF8String, NSStringFromRect(valueRect).UTF8String,
            NSStringFromRect([heading.cell titleRectForBounds:heading.bounds]).UTF8String,
            NSStringFromRect([heading alignmentRectForFrame:heading.frame]).UTF8String);
        NSSize headingSize = [heading.stringValue sizeWithAttributes:@{NSFontAttributeName: heading.font}];
        check([heading.stringValue isEqual:headings[column]] && headingSize.width <= headingRect.size.width &&
              fabs(NSMaxX(headingRect) - NSMaxX(valueRect)) <= 1,
              @"Each visible heading aligns with the values in its timing column");
    }
    check(controller.cutList.frame.size.height > controller.reviewScroll.contentView.bounds.size.height,
          @"The eighteen rows exercise actual inner-list scrolling");
    SSWorkflowCutRow *last = (SSWorkflowCutRow *)controller.cutList.arrangedSubviews.lastObject;
    NSRect lastRect = [last convertRect:last.bounds toView:controller.cutList];
    [last scrollRectToVisible:last.bounds];
    [controller.reviewScroll reflectScrolledClipView:controller.reviewScroll.contentView];
    check(NSContainsRect(NSInsetRect(controller.reviewScroll.contentView.documentVisibleRect, -0.5, -0.5), lastRect),
          @"The final long-duration range remains fully reachable through the inner list");
    [controller.reviewScroll.contentView scrollToPoint:NSZeroPoint];
    [controller.reviewScroll reflectScrolledClipView:controller.reviewScroll.contentView];
    checkStickyChrome(controller);
}

static void renderSyntheticLayoutIfRequested(SSWorkflowViewController *controller, NSString *name) {
    if (!getenv("SILENT_SNIP_CONTROLLER_LAYOUT_RENDER")) return;
    NSString *directory = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"build/WorkflowPrototype/Window11"];
    NSError *error;
    check([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error],
          @"The optional synthetic layout-render directory is writable");
    check([directory.stringByResolvingSymlinksInPath isEqual:directory.stringByStandardizingPath],
          @"Optional layout render output does not traverse a symlink");
    [controller.view setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    [controller.view layoutSubtreeIfNeeded];
    [controller.view setNeedsDisplay:YES];
    NSBitmapImageRep *bitmap = [controller.view bitmapImageRepForCachingDisplayInRect:controller.view.bounds];
    check(bitmap != nil, @"The offscreen view can create an optional bitmap without a window");
    [controller.view cacheDisplayInRect:controller.view.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [directory stringByAppendingPathComponent:name];
    check(png.length > 0 && [png writeToFile:path atomically:YES],
          @"The optional synthetic eighteen-cut screenshot is saved");
    fprintf(stdout, "Synthetic layout render: %s\n", path.UTF8String);
}

static void structuredEighteenCutReviewFitsNarrowAndWideWindows(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Synthetic layout project"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSDictionary *response = syntheticEighteenCutReview();
    [client deliver:response busy:NO canApply:YES];
    NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
    [parent addSubview:controller.view];
    settleOffscreenLayout(parent, controller);
    NSUInteger generation = controller.reviewGeneration;
    NSUInteger contextGeneration = controller.contextGeneration;
    NSString *marker = controller.cancelButton.accessibilityIdentifier;
    for (NSNumber *width in @[@460, @480, @840]) {
        [parent setFrameSize:NSMakeSize(width.doubleValue, 477)];
        settleOffscreenLayout(parent, controller);
        checkBodyWidth(controller);
        checkNumericGroupArrangement(controller, width.doubleValue >= 700);
        checkStructuredCutRows(controller, response[@"cuts"]);
        if (width.integerValue == 840) {
            NSRect visible = NSInsetRect(controller.scroll.contentView.documentVisibleRect, -0.5, -0.5);
            NSRect review = [controller.reviewScroll convertRect:controller.reviewScroll.bounds toView:controller.content];
            check(NSContainsRect(visible, review), @"The wide review uses the visible body area instead of a clipped or offscreen list");
        }
        if (width.integerValue != 480) renderSyntheticLayoutIfRequested(controller,
            [NSString stringWithFormat:@"Synthetic-18Cuts-%ldx477.png", (long)width.integerValue]);
    }
    [client deliver:response busy:YES canApply:NO];
    settleOffscreenLayout(parent, controller);
    for (NSButton *row in controller.cutList.arrangedSubviews) check(!row.enabled,
          @"Every structured checkbox disables while the reviewed request is pending");
    check(!controller.applyButton.enabled && !controller.fields[0].enabled,
          @"The compact presentation preserves busy Apply and settings guards");
    [client deliver:response busy:NO canApply:YES];
    settleOffscreenLayout(parent, controller);
    checkStructuredCutRows(controller, response[@"cuts"]);
    check(controller.reviewClient == client && controller.reviewGeneration == generation &&
          controller.contextGeneration == contextGeneration && client.startCount == 1 && client.applyCommandCount == 0 &&
          client.applyGestures.count == 0 && client.retryCount == 0 && controller.settings.loads.count == 1 &&
          controller.settings.saves.count == 0 && [controller.cancelButton.accessibilityIdentifier isEqual:marker],
          @"Resizing, list scrolling, and drawing eighteen ranges cannot rebind settings or dispatch backend work");
    [controller.view removeFromSuperview];
    closeController(controller);
    groupCount += 1;
}

static NSString *longInformationalStatus(void) {
    return @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts. "
        "Analyzed Final Cut's rendered audio, including clip volume and enabled effects. "
        "The threshold uses average loudness over short windows. Apply creates a cleaned project copy "
        "with the retained processed sound preserved, while the original project keeps editable effects.";
}

static void informationalDetailsKeepReviewAuthorityUnchanged(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = longInformationalStatus();
    [client deliver:reviewResponse(@"review", message) busy:NO canApply:YES];
    NSUInteger generation = controller.reviewGeneration;
    NSUInteger loads = controller.settings.loads.count;
    NSString *nativeMarker = controller.cancelButton.accessibilityIdentifier;
    check(controller.statusLabel.stringValue.length < message.length &&
          [controller.statusDetails.stringValue isEqual:message],
          @"Long informational status is compact while its full explanation remains available");
    check(!controller.detailsExpanded && controller.statusDetails.hidden && !controller.detailsButton.hidden &&
          controller.detailsButton.enabled && controller.detailsButton.title.length > 0,
          @"The full informational explanation starts collapsed behind a named, reachable disclosure");
    [controller toggleDetails:controller.detailsButton];
    check(controller.detailsExpanded && !controller.statusDetails.hidden &&
          [controller.statusDetails.stringValue isEqual:message],
          @"Opening Details exposes every word of the current backend explanation");
    [controller toggleDetails:controller.detailsButton];
    check(!controller.detailsExpanded && controller.statusDetails.hidden,
          @"Closing Details restores the compact review presentation");
    check(controller.reviewClient == client && controller.reviewGeneration == generation &&
          controller.applyButton.enabled && client.canApply && client.startCount == 1 &&
          client.applyCommandCount == 0 && client.applyGestures.count == 0 && client.retryCount == 0 &&
          controller.settings.loads.count == loads && controller.settings.saves.count == 0 &&
          [controller.cancelButton.accessibilityIdentifier isEqual:nativeMarker],
          @"Showing status details cannot alter a review, dispatch work, save settings, or replace the native authorization marker");
    [client deliver:reviewResponse(@"review", @"Review ready") busy:NO canApply:YES];
    check([controller.statusLabel.stringValue isEqual:@"Review ready"] && controller.detailsButton.hidden &&
          controller.statusDetails.hidden && ![controller.statusDetails.stringValue containsString:message],
          @"A later short status clears the previous expanded explanation instead of leaving stale information");
    closeController(controller);
    groupCount += 1;
}

static void longRecoveryDetailsStayVisibleWithoutAuthorizingAnotherApply(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = @"The cleaned project was imported, but verification could not finish. "
        "Return to the intended project in Final Cut Pro and choose Retry Verification. "
        "This retry checks the existing imported result and its saved media evidence. "
        "Keep the original source and processed audio files available until verification completes. "
        "Do not create another result to resolve this pending verification.";
    NSMutableDictionary *response = [reviewResponse(@"failed", message) mutableCopy];
    response[@"canRetryVerification"] = @YES;
    [client deliver:response busy:NO canApply:NO];
    check(controller.detailsExpanded && !controller.statusDetails.hidden &&
          [controller.statusDetails.stringValue isEqual:message],
          @"Long recovery instructions expand automatically rather than being hidden by the compact status");
    check(!controller.retryButton.hidden && controller.retryButton.enabled && !controller.applyButton.enabled &&
          !controller.analyzeButton.enabled && !controller.fields[0].enabled && controller.reviewClient == client,
          @"Expanded recovery retains the existing result and exposes Retry without permitting a new Analyze or Apply");
    [controller toggleDetails:controller.detailsButton];
    check(controller.retryButton.enabled && !controller.applyButton.enabled && !controller.analyzeButton.enabled &&
          !controller.fields[0].enabled && client.startCount == 1 && client.applyCommandCount == 0 && client.retryCount == 0 &&
          controller.settings.saves.count == 0,
          @"Collapsing recovery details cannot bypass retained-result recovery or dispatch a command");
    [controller toggleDetails:controller.detailsButton];
    check(!controller.statusDetails.hidden && [controller.statusDetails.stringValue isEqual:message],
          @"The same complete recovery instructions remain available after disclosure changes");
    closeController(controller);
    groupCount += 1;
}

static void longCancellationDetailsDoNotSuggestApply(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = @"Analysis was cancelled before a cut review became available. The original project remains unchanged. "
        "Return to the intended project and select the source timeline clip before choosing Analyze Audio again. "
        "Any temporary analysis work has stopped, and this cancelled request does not provide cuts that can be applied.";
    [client deliver:reviewResponse(@"cancelled", message) busy:NO canApply:NO];
    check(message.length > 180 && [controller.statusLabel.stringValue isEqual:@"Cancelled. Review the details."],
          @"A long cancelled response reports cancellation rather than suggesting an analysis is ready");
    check(controller.detailsExpanded && !controller.statusDetails.hidden && !controller.detailsButton.hidden &&
          [controller.statusDetails.stringValue isEqual:message] && [controller.statusLabel.toolTip isEqual:message],
          @"The complete cancellation explanation expands automatically and remains available in the tooltip");
    check(controller.reviewClient == client && !controller.applyButton.enabled && !client.canApply &&
          controller.analyzeButton.enabled && controller.retryButton.hidden,
          @"Cancellation keeps Apply disabled while permitting a new explicit analysis");
    [controller toggleDetails:controller.detailsButton];
    [controller toggleDetails:controller.detailsButton];
    check(controller.settings.loads.count == 1 && controller.settings.saves.count == 0 &&
          client.startCount == 1 && client.applyCommandCount == 0 && client.applyGestures.count == 0 &&
          client.retryCount == 0 && client.cancelCount == 0 && client.detachCount == 0,
          @"Showing cancellation details cannot dispatch additional analysis, Apply, Retry, Cancel, or settings work");
    [client deliver:reviewResponse(@"cancelled", @"Analysis cancelled.") busy:NO canApply:NO];
    check([controller.statusLabel.stringValue isEqual:@"Analysis cancelled."] && controller.detailsButton.hidden &&
          controller.statusDetails.hidden && [controller.statusDetails.stringValue isEqual:@"Analysis cancelled."],
          @"A later short cancellation stays exact and clears the earlier long explanation");
    closeController(controller);
    groupCount += 1;
}

static void exerciseLongLocalSaveFailureAfterState(NSString *state, BOOL canApply) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    [client deliver:reviewResponse(state, longInformationalStatus()) busy:NO canApply:canApply];
    NSUInteger generation = controller.reviewGeneration;
    NSUInteger contextGeneration = controller.contextGeneration;
    NSArray *cuts = controller.reviewCuts;
    NSString *marker = controller.cancelButton.accessibilityIdentifier;
    NSString *message = @"Project settings remain unsaved. Check the destination folder's permissions and available storage, "
        "then choose Save Settings again. Detection values are still shown in the window so that you can review "
        "the intended values before retrying this explicit settings save. Your existing cut review remains available.";
    check(message.length > 180 && controller.saveButton.enabled,
          @"The local error fixture exercises a real explicit Save after an informational worker state");
    [controller saveSettings:controller.saveButton];
    check(controller.settings.saves.count == 1 && !controller.saveButton.enabled,
          @"Only the explicit Save creates the pending persistence request");
    completeSave(controller.settings.saves[0], [NSError errorWithDomain:@"test.persistence" code:2
        userInfo:@{NSLocalizedDescriptionKey: message}]);
    check(controller.detailsExpanded && !controller.statusDetails.hidden && !controller.detailsButton.hidden &&
          [controller.statusDetails.stringValue isEqual:message] && [controller.statusLabel.toolTip isEqual:message],
          @"A long local Save error exposes its full text regardless of the retained worker state");
    check([controller.statusLabel.stringValue isEqual:@"Unable to finish. Review the details."],
          @"A local Save error uses an error headline rather than the earlier review or completion headline");
    check(controller.reviewClient == client && controller.reviewGeneration == generation &&
          controller.contextGeneration == contextGeneration && controller.reviewCuts == cuts &&
          [controller.reviewResponse[@"state"] isEqual:state] && client.canApply == canApply &&
          controller.applyButton.enabled == canApply && controller.saveButton.enabled &&
          [controller.cancelButton.accessibilityIdentifier isEqual:marker],
          @"Presenting the local Save error preserves the existing review identity, cut data, and Apply authority");
    [controller toggleDetails:controller.detailsButton];
    [controller toggleDetails:controller.detailsButton];
    check(controller.detailsExpanded && [controller.statusDetails.stringValue isEqual:message] &&
          controller.settings.loads.count == 1 && controller.settings.saves.count == 1 &&
          client.startCount == 1 && client.applyCommandCount == 0 && client.applyGestures.count == 0 &&
          client.retryCount == 0 && client.cancelCount == 0 && client.detachCount == 0,
          @"Presenting or toggling the local error cannot dispatch backend work or an additional settings save");
    closeController(controller);
    groupCount += 1;
}

static void longLocalSaveFailurePreservesReadyReview(void) {
    exerciseLongLocalSaveFailureAfterState(@"review", YES);
}

static void longLocalSaveFailureOverridesCompletedHeadline(void) {
    exerciseLongLocalSaveFailureAfterState(@"completed", NO);
}

int main(void) {
    @autoreleasepool {
        check(NSThread.isMainThread, @"The offscreen controller harness starts on the main thread");
        sameProjectPreservesDraft();
        lateLoadCannotCrossProjects();
        identicalUIDInAnotherLibraryCannotReceiveOldDraft();
        lateSaveCannotEnableAnotherProject();
        disappearanceInvalidatesCallbacksAndReopenReloads();
        invalidHostAndIdentityNeverLoad();
        invalidNumbersNeverDispatchSave();
        delayedPermissionCannotReconnectHiddenView();
        deniedPermissionKeepsConnectExplicit();
        analyzeDispatchPinsPayloadAndGesture();
        applyRequiresReviewAndFreshGesture();
        editsInvalidateEveryReviewedSetting();
        projectSwitchDiscardsIdleReview();
        liveIdentityMismatchStopsAnalyzeAndApply();
        busyWorkerDefersTemporarySDKBinding();
        closingReviewRejectsLateCallbacksAfterReopen();
        malformedAnalyzeAndCurrentFailureStayLocal();
        retryableResultRetainsRecoveryUntilVerified();
        busyPlayheadWaitsForTheSettledProject();
        pendingSaveCannotReplaceWorkerProgressOrRecovery();
        synchronousApplyActivationFailureKeepsReviewUsable();
        terminalNoticeStaysWithItsPinnedProject();
        delayedTerminalCannotClaimTheNewSDKProject();
        offscreenParentResizeKeepsContentReachable();
        frameDrivenParentResizeKeepsContentReachable();
        structuredEighteenCutReviewFitsNarrowAndWideWindows();
        informationalDetailsKeepReviewAuthorityUnchanged();
        longRecoveryDetailsStayVisibleWithoutAuthorizingAnotherApply();
        longCancellationDetailsDoNotSuggestApply();
        longLocalSaveFailurePreservesReadyReview();
        longLocalSaveFailureOverridesCompletedHeadline();
        check(hostSingleton == nil, @"No host fixture survives the test groups");
        printf("Passed %lu controller groups (%lu assertions); no Final Cut, windows, events, notifications, helper launches, or settings files used.\n",
               (unsigned long)groupCount, (unsigned long)assertionCount);
    }
    return EXIT_SUCCESS;
}
