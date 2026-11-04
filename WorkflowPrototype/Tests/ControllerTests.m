#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import "Support/SSWorkflowPersistence-Swift.h"
#import <stdio.h>
#import <stdlib.h>

// This executable includes the actual controller implementation below. Only
// its persistence bridge and SDK host objects are replaced, through their
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
@end
@implementation SSTestWorkflowViewController
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
        [controller viewDidLayout];
    }
}

static void checkHeaderReachable(SSWorkflowViewController *controller) {
    NSView *header = controller.content.arrangedSubviews.firstObject;
    NSRect headerRect = [header convertRect:header.bounds toView:controller.content];
    check(!NSIsEmptyRect(headerRect) &&
          NSContainsRect(NSInsetRect(controller.content.bounds, -0.5, -0.5), headerRect),
          @"The header has nonnegative, nonempty geometry inside the document");
    [header scrollRectToVisible:header.bounds];
    [controller.scroll reflectScrolledClipView:controller.scroll.contentView];
    NSRect visible = controller.scroll.contentView.documentVisibleRect;
    check(NSIntersectsRect(headerRect, visible) && NSMinY(headerRect) >= NSMinY(visible) - 0.5,
          @"The document header is reachable at the top of the scroll viewport");
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
    checkHeaderReachable(controller);

    hostHeight.constant = 300;
    [parent setFrameSize:NSMakeSize(480, 300)];
    logOffscreenGeometry(@"shrink before layout", parent, controller);
    settleOffscreenLayout(parent, controller);
    logOffscreenGeometry(@"shrink after layout", parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"Reducing parent height resizes the root instead of clipping a fixed-height root");
    check(nearlyEqualSize(controller.scroll.frame.size, controller.view.bounds.size) &&
          fabs(NSMinX(controller.scroll.frame) - NSMinX(controller.view.bounds)) < 0.5 &&
          fabs(NSMinY(controller.scroll.frame) - NSMinY(controller.view.bounds)) < 0.5,
          @"The scroll viewport covers the root after the height reduction");
    check(nearlyEqualSize(NSMakeSize(controller.content.frame.size.width, 0),
                          NSMakeSize(controller.scroll.contentView.bounds.size.width, 0)),
          @"Document width follows the actual clip width, including scroller space");
    check(controller.content.frame.size.height > controller.scroll.contentView.bounds.size.height,
          @"The short parent exercises real vertical overflow rather than compressing away content");
    checkHeaderReachable(controller);
    NSView *scope = controller.content.arrangedSubviews.lastObject;
    NSRect scopeRect = [scope convertRect:scope.bounds toView:controller.content];
    [scope scrollRectToVisible:scope.bounds];
    [controller.scroll reflectScrolledClipView:controller.scroll.contentView];
    check(!NSIsEmptyRect(scopeRect) &&
          NSContainsRect(NSInsetRect(controller.scroll.contentView.documentVisibleRect, -0.5, -0.5), scopeRect),
          @"The bottom scope explanation remains fully reachable by scrolling");
    checkHeaderReachable(controller);

    CGFloat narrowWidth = controller.content.frame.size.width;
    hostWidth.constant = 760;
    [parent setFrameSize:NSMakeSize(760, 300)];
    settleOffscreenLayout(parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size) &&
          nearlyEqualSize(controller.scroll.frame.size, controller.view.bounds.size),
          @"Widening the parent resizes both root and viewport");
    check(controller.content.frame.size.width > narrowWidth + 200 &&
          fabs(controller.content.frame.size.width - controller.scroll.contentView.bounds.size.width) < 0.5,
          @"The document follows a wider clip viewport");
    checkHeaderReachable(controller);
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
        offscreenParentResizeKeepsContentReachable();
        frameDrivenParentResizeKeepsContentReachable();
        check(hostSingleton == nil, @"No host fixture survives the test groups");
        printf("Passed %lu controller groups (%lu assertions); no Final Cut, windows, events, or settings files used.\n",
               (unsigned long)groupCount, (unsigned long)assertionCount);
    }
    return EXIT_SUCCESS;
}
