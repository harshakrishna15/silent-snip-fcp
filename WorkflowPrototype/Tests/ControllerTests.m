#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import "Support/SSWorkflowPersistence-Swift.h"
#import <stdio.h>
#import <stdlib.h>
#import <math.h>

// This executable includes the actual controller implementation below. Only
// its persistence bridge, review/window transports, and SDK host objects are replaced through their
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
@property (nonatomic) CMTime duration;
@property (nonatomic) CMTime frameDuration;
@end
@implementation SSProxy
@end

@interface SSTimeline : NSObject
@property (nonatomic, strong) SSProxy *sequence;
@property (nonatomic) CMTime currentPlayhead;
@property (nonatomic, weak) NSObject<FCPXTimelineObserver> *observer;
@property (nonatomic) NSUInteger addCount;
@property (nonatomic) NSUInteger removeCount;
@property (nonatomic) NSUInteger activeSequenceReadCount;
@property (nonatomic) NSUInteger moveCount;
@property (nonatomic) BOOL usesFixedMoveResult;
@property (nonatomic) CMTime fixedMoveResult;
- (void)notifySequenceChanged;
@end
@implementation SSTimeline
- (FCPXSequence *)activeSequence { self.activeSequenceReadCount += 1; return (FCPXSequence *)self.sequence; }
- (CMTime)playheadTime { return self.currentPlayhead; }
- (CMTime)movePlayheadTo:(CMTime)time {
    self.moveCount += 1;
    self.currentPlayhead = self.usesFixedMoveResult ? self.fixedMoveResult : time;
    return self.currentPlayhead;
}
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

// Cursor policy exercises the real content view with recorded environment
// observations. No NSApplication, NSWindow, NSEvent, or displayed cursor is
// created or changed by these doubles.
@interface SSRecordingPointerCursor : NSObject
@property (nonatomic) NSUInteger setCount;
- (void)set;
@end
@implementation SSRecordingPointerCursor
- (void)set { self.setCount += 1; }
@end

@interface SSTestWorkflowContentView : SSWorkflowContentView
@property (nonatomic, strong) SSWorkflowPointerObservation *testObservation;
@property (nonatomic, strong) NSCursor *testCurrentCursor;
@property (nonatomic, strong) NSCursor *testSystemArrow;
@property (nonatomic, strong) SSRecordingPointerCursor *recordingCursor;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *pointerCompletions;
@property (nonatomic, strong) NSMutableArray<NSString *> *pointerPhases;
@property (nonatomic) NSUInteger cursorRectInvalidations;
@property (nonatomic, strong) NSCursor *registeredCursor;
@end
@implementation SSTestWorkflowContentView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.recordingCursor = [SSRecordingPointerCursor new];
        self.defaultCursor = (NSCursor *)self.recordingCursor;
        self.testSystemArrow = (NSCursor *)[NSObject new];
        self.testCurrentCursor = self.testSystemArrow;
        self.testObservation = [SSWorkflowPointerObservation new];
        self.pointerCompletions = [NSMutableArray new];
        self.pointerPhases = [NSMutableArray new];
    }
    return self;
}
- (SSWorkflowPointerObservation *)pointerObservationForEvent:(NSEvent *)event { return self.testObservation; }
- (NSCursor *)currentApplicationCursor { return self.testCurrentCursor; }
- (NSCursor *)systemArrowCursor { return self.testSystemArrow; }
- (void)enqueueDefaultCursorRefresh:(dispatch_block_t)refresh {
    if (!self.pointerCompletions) self.pointerCompletions = [NSMutableArray new];
    [self.pointerCompletions addObject:[refresh copy]];
}
- (void)invalidateOwnedCursorRects { self.cursorRectInvalidations += 1; }
- (void)addCursorRect:(NSRect)rect cursor:(NSCursor *)cursor { self.registeredCursor = cursor; }
- (void)recordPointerObservation:(SSWorkflowPointerObservation *)observation phase:(NSString *)phase
                     cursorKind:(NSString *)kind restored:(BOOL)restored {
    [self.pointerPhases addObject:phase];
    if (restored) self.testCurrentCursor = self.defaultCursor;
}
@end

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
- (BOOL)canUpdateCuts { unexpectedReviewBoundary(); return NO; }
- (BOOL)automaticPreviewAvailable { unexpectedReviewBoundary(); return NO; }
- (BOOL)updatingCuts { unexpectedReviewBoundary(); return NO; }
- (BOOL)canHighlight { unexpectedReviewBoundary(); return NO; }
- (BOOL)supportsNativeNavigation { unexpectedReviewBoundary(); return NO; }
- (void)markSettingsDirty { unexpectedReviewBoundary(); }
- (BOOL)updateCutsWithSettings:(NSDictionary *)settings gesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)automaticallyUpdateCutsWithSettings:(NSDictionary *)settings edit:(NSString *)edit { unexpectedReviewBoundary(); return NO; }
- (BOOL)highlightCut:(NSString *)cutID { unexpectedReviewBoundary(); return NO; }
- (BOOL)navigateCut:(NSString *)cutID gesture:(NSString *)gesture move:(BOOL (^)(NSDictionary *))move { unexpectedReviewBoundary(); return NO; }
- (BOOL)verifyExistingResultURL:(NSURL *)url libraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
                   projectName:(NSString *)projectName gesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)startWithLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings gesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)sendApplyWithGesture:(NSString *)gesture { unexpectedReviewBoundary(); return NO; }
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included { unexpectedReviewBoundary(); return NO; }
- (BOOL)selectAll:(BOOL)included { unexpectedReviewBoundary(); return NO; }
- (BOOL)retryVerification { unexpectedReviewBoundary(); return NO; }
- (void)cancel { unexpectedReviewBoundary(); }
- (void)detach { unexpectedReviewBoundary(); }
- (void)prepareWindowHelper:(void (^)(NSError *))completion { unexpectedReviewBoundary(); }
@end

// The lease transport is also excluded from this executable. Its real
// notification observers, timers, and helper activation cannot be reached.
static void unexpectedWindowBoundary(void) {
    fprintf(stderr, "FAIL: A controller test reached the real window-client boundary\n");
    abort();
}
@implementation SSWorkflowWindowClient
- (instancetype)initWithViewID:(NSString *)viewID { return [super init]; }
- (NSString *)state { unexpectedWindowBoundary(); return nil; }
- (void)start { unexpectedWindowBoundary(); }
- (void)stop { unexpectedWindowBoundary(); }
- (void)updateProjectName:(NSString *)projectName { unexpectedWindowBoundary(); }
@end

@interface SSFakeWorkflowWindowClient : SSWorkflowWindowClient
@property (nonatomic, copy) NSString *testViewID;
@property (nonatomic) NSUInteger startCount;
@property (nonatomic) NSUInteger stopCount;
@property (nonatomic) BOOL active;
@end
@implementation SSFakeWorkflowWindowClient
- (instancetype)initWithViewID:(NSString *)viewID {
    self = [super initWithViewID:viewID];
    if (self) _testViewID = [viewID copy];
    return self;
}
- (void)start { if (!self.active) { self.startCount += 1; self.active = YES; } }
- (void)stop { if (self.active) { self.stopCount += 1; self.active = NO; } }
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
@property (nonatomic) BOOL fakeCanUpdate;
@property (nonatomic) BOOL fakeDirty;
@property (nonatomic) NSUInteger dirtyCount;
@property (nonatomic) BOOL notifySequenceWhileMarkingDirty;
@property (nonatomic, copy) NSDictionary *updatePayload;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *automaticUpdatePayloads;
@property (nonatomic) BOOL fakeUpdatingCuts;
@property (nonatomic) BOOL fakeAutomaticForeground;
@property (nonatomic, copy) NSString *reentrantAutomaticThreshold;
@property (nonatomic) NSUInteger automaticUpdateAttemptCount;
- (void)acknowledgeAutomaticUpdate;
@property (nonatomic, copy) NSDictionary *verifyPayload;
@property (nonatomic, copy) NSString *highlightedCut;
@property (nonatomic) BOOL fakeNativeNavigation;
@property (nonatomic, copy) BOOL (^nativeMove)(NSDictionary *permit);
@property (nonatomic, copy) NSString *nativeNavigationMarker;
- (void)deliver:(NSDictionary *)response busy:(BOOL)busy canApply:(BOOL)canApply;
@end
@implementation SSFakeWorkflowReviewClient
- (instancetype)initWithViewID:(NSString *)viewID update:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure {
    self = [super initWithViewID:viewID update:update failure:failure];
    if (self) { _testUpdate = [update copy]; _testFailure = [failure copy]; _applyGestures = [NSMutableArray new]; _automaticUpdatePayloads = [NSMutableArray new]; _fakeAutomaticForeground = YES; }
    return self;
}
- (NSString *)requestID { return self.fakeRequestID; }
- (BOOL)busy { return self.fakeBusy; }
- (BOOL)canApply { return self.fakeCanApply; }
- (BOOL)canChangeSelection { return self.fakeCanChangeSelection; }
- (BOOL)canCancel { return self.fakeCanCancel; }
- (BOOL)canUpdateCuts { return self.fakeCanUpdate; }
- (BOOL)automaticPreviewAvailable {
    return self.fakeCanUpdate && !self.fakeCanRetry && [self.lastResponse[@"state"] isEqual:@"review"] &&
        (!self.fakeBusy || self.fakeUpdatingCuts);
}
- (BOOL)updatingCuts { return self.fakeUpdatingCuts; }
- (BOOL)canHighlight { return self.fakeCanChangeSelection && !self.fakeDirty && !self.fakeBusy; }
- (BOOL)supportsNativeNavigation { return self.fakeNativeNavigation; }
- (void)markSettingsDirty {
    self.fakeDirty = YES; self.dirtyCount += 1;
    self.fakeCanApply = NO; self.fakeCanChangeSelection = NO;
    if (self.notifySequenceWhileMarkingDirty) {
        self.notifySequenceWhileMarkingDirty = NO;
        [self.owner activeSequenceChanged];
    }
}
- (BOOL)automaticallyUpdateCutsWithSettings:(NSDictionary *)settings edit:(NSString *)edit {
    if (!self.automaticPreviewAvailable || self.fakeBusy || !self.fakeAutomaticForeground) return NO;
    self.automaticUpdateAttemptCount += 1;
    if (self.reentrantAutomaticThreshold) {
        NSString *next = self.reentrantAutomaticThreshold;
        self.reentrantAutomaticThreshold = nil;
        self.fakeBusy = YES; self.fakeUpdatingCuts = YES; self.fakeDirty = NO;
        self.owner.fields[0].stringValue = next;
        [self.owner settingsChanged:self.owner.fields[0]];
        // Model a synchronous publish whose post-publication generation guard
        // declines the obsolete packet before sending it to the worker.
        self.fakeBusy = NO; self.fakeUpdatingCuts = NO;
        self.fakeCanApply = NO; self.fakeCanChangeSelection = NO;
        return NO;
    }
    self.updatePayload = @{@"settings":[settings copy], @"edit":[edit copy],
        @"identifier":self.owner.settingsPanel.accessibilityIdentifier ?: @""};
    [self.automaticUpdatePayloads addObject:self.updatePayload];
    self.fakeBusy = YES; self.fakeUpdatingCuts = YES; self.fakeDirty = NO;
    self.fakeCanApply = NO; self.fakeCanChangeSelection = NO;
    return YES;
}
- (void)acknowledgeAutomaticUpdate {
    NSMutableDictionary *response = [self.lastResponse mutableCopy];
    response[@"settingsEdit"] = self.updatePayload[@"edit"];
    NSDictionary *submitted = self.updatePayload[@"settings"];
    response[@"settings"] = @{@"threshold":submitted[@"thresholdDBFS"],
        @"minimum":submitted[@"minimumSilenceDuration"], @"before":submitted[@"beforeSpeechPadding"],
        @"after":submitted[@"afterSpeechPadding"]};
    response[@"output"] = submitted[@"outputMode"];
    response[@"provisional"] = @NO;
    [response removeObjectForKey:@"rejectedSettingsEdit"];
    [response removeObjectForKey:@"rejectedSettingsSequence"];
    self.fakeBusy = NO; self.fakeUpdatingCuts = NO;
    self.fakeCanApply = !self.fakeDirty; self.fakeCanChangeSelection = !self.fakeDirty;
    self.lastResponse = response;
    self.testUpdate(response);
}
- (BOOL)highlightCut:(NSString *)cutID { self.highlightedCut = cutID; self.fakeBusy = YES; return YES; }
- (BOOL)navigateCut:(NSString *)cutID gesture:(NSString *)gesture move:(BOOL (^)(NSDictionary *))move {
    self.nativeMove = move;
    if (!self.owner.navigateMenu.enabled) self.nativeNavigationMarker = self.owner.navigateMenu.accessibilityIdentifier;
    self.fakeBusy = YES;
    return YES;
}
- (BOOL)verifyExistingResultURL:(NSURL *)url libraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
                   projectName:(NSString *)projectName gesture:(NSString *)gesture {
    self.verifyPayload = @{@"url":url, @"libraryURL":libraryURL, @"projectUID":projectUID,
        @"projectName":projectName, @"gesture":gesture, @"identifier":self.owner.verifyButton.accessibilityIdentifier,
        @"disabled":@(!self.owner.verifyButton.enabled)};
    self.fakeBusy = YES; return YES;
}
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
        response[@"message"] = @"Bring Final Cut Pro to the front, then click Apply Cuts.";
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
- (void)cancel {
    self.cancelCount += 1; self.fakeCanCancel = NO; self.fakeCanApply = NO;
    self.fakeCanChangeSelection = NO; self.fakeCanUpdate = NO;
}
- (void)detach {
    self.detachCount += 1;
    self.fakeBusy = NO;
    self.fakeCanApply = NO;
    self.fakeCanChangeSelection = NO;
    self.fakeCanCancel = NO;
    self.fakeCanRetry = NO;
    self.fakeCanUpdate = NO;
    self.fakeUpdatingCuts = NO;
    // Keep callbacks so tests can model already-queued messages after detach.
}
- (void)deliver:(NSDictionary *)response busy:(BOOL)busy canApply:(BOOL)canApply {
    self.lastResponse = response;
    self.fakeBusy = busy;
    if (!busy) self.fakeUpdatingCuts = NO;
    self.fakeCanApply = canApply && !self.fakeDirty;
    self.fakeCanChangeSelection = canApply && !self.fakeDirty;
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
@property (nonatomic, strong) NSMutableArray<SSFakeWorkflowWindowClient *> *windowClients;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *verificationCompletions;
@property (nonatomic, strong) NSMutableArray<dispatch_block_t> *automaticUpdateCompletions;
@property (nonatomic) BOOL fakeOwnsNavigationWindow;
@end
@implementation SSTestWorkflowViewController
- (BOOL)ownsNavigationWindow:(NSWindow *)window { return self.fakeOwnsNavigationWindow; }
- (SSWorkflowContentView *)newContentViewWithFrame:(NSRect)frame {
    return [[SSTestWorkflowContentView alloc] initWithFrame:frame];
}
- (void)startAutomaticUpdateObservers {}
- (void)stopAutomaticUpdateObservers {}
- (void)scheduleAutomaticUpdate:(dispatch_block_t)completion afterDelay:(NSTimeInterval)delay {
    if (!self.automaticUpdateCompletions) self.automaticUpdateCompletions = [NSMutableArray new];
    [self.automaticUpdateCompletions addObject:[completion copy]];
}
- (void)scheduleVerificationCompletion:(dispatch_block_t)completion afterDelay:(NSTimeInterval)delay {
    if (!self.verificationCompletions) self.verificationCompletions = [NSMutableArray new];
    [self.verificationCompletions addObject:[completion copy]];
}
- (SSWorkflowWindowClient *)newWindowClient {
    if (!self.windowClients) self.windowClients = [NSMutableArray new];
    SSFakeWorkflowWindowClient *client = [[SSFakeWorkflowWindowClient alloc] initWithViewID:self.viewID];
    [self.windowClients addObject:client];
    return client;
}
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

static void runAutomaticUpdates(SSTestWorkflowViewController *controller) {
    NSArray<dispatch_block_t> *ready = controller.automaticUpdateCompletions.copy;
    [controller.automaticUpdateCompletions removeAllObjects];
    for (dispatch_block_t completion in ready) completion();
}

static BOOL subtreeHasButton(NSView *view, NSString *title) {
    if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqual:title]) return YES;
    for (NSView *child in view.subviews) if (subtreeHasButton(child, title)) return YES;
    return NO;
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

static void windowLeaseTracksVisibleVerifiedHostWithoutProjectWork(void) {
    SSHost *current = host(nil);
    hostSingleton = current;
    SSTestWorkflowViewController *controller = [[SSTestWorkflowViewController alloc] initWithNibName:nil bundle:nil];
    controller.permissionStatus = noErr;
    controller.delaysPermission = YES;
    [controller loadView];
    check(controller.windowClients.count == 0 && controller.reviewClients.count == 0 && controller.settings.loads.count == 0,
          @"Loading an unseen controller cannot allocate a window lease or start project work");
    [controller viewDidAppear];
    SSFakeWorkflowWindowClient *client = controller.windowClients.lastObject;
    check(client != nil && controller.windowClients.count == 1 && client.active && client.startCount == 1 &&
          [client.testViewID isEqual:controller.viewID] && controller.viewVisible && controller.windowClientRunning,
          @"A visible verified Final Cut host starts one lease pinned to this view's native marker");
    check(current.timelineReadCount == 0 && controller.settings.loads.count == 0 && controller.reviewClients.count == 0,
          @"Window sizing starts independently of timeline permission, an active project, and Analyze");
    [controller viewDidAppear];
    check(client.startCount == 1 && controller.windowClients.count == 1 && controller.permissions.count == 1,
          @"Repeated appearance does not duplicate the running lease or reconnect the SDK host");
    completePermission(controller.permissions[0], errAEEventNotPermitted);
    check(client.active && client.startCount == 1 && client.stopCount == 0 && current.timelineReadCount == 0 &&
          controller.settings.loads.count == 0,
          @"Denied project Automation leaves a verified visible window lease independent of project-data access");
    [controller requestConnection:nil];
    completePermission(controller.permissions[1], noErr);
    check(client.active && client.startCount == 1 && current.timelineReadCount == 1 &&
          controller.projectUID == nil && controller.settings.loads.count == 0 && controller.reviewClients.count == 0,
          @"Successful connection with no open project does not restart sizing or manufacture analysis work");
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
    [current.testTimeline notifySequenceChanged];
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    current.testTimeline.sequence = nil;
    [current.testTimeline notifySequenceChanged];
    check(client.active && client.startCount == 1 && client.stopCount == 0 && controller.settings.loads.count == 1 &&
          controller.reviewClients.count == 0,
          @"Opening and closing a project cannot own the visible window lease or implicitly Analyze");
    [controller viewWillDisappear];
    [controller viewWillDisappear];
    NSUInteger permissions = controller.permissions.count;
    [controller requestConnection:nil];
    check(!client.active && client.stopCount == 1 && !controller.viewVisible && !controller.windowClientRunning &&
          client.startCount == 1 && controller.permissions.count == permissions,
          @"Disappearance revokes the lease once, and a hidden reconnect cannot restart it");

    [controller viewDidAppear];
    check(client.active && client.startCount == 2 && controller.windowClients.count == 1,
          @"Reopening a verified host restarts the same view lease without a project or Analyze");
    NSUInteger reads = current.timelineReadCount;
    permissions = controller.permissions.count;
    current.bundleIdentifier = @"example.unrelated-host";
    [controller requestConnection:nil];
    check(!client.active && client.stopCount == 2 && controller.permissions.count == permissions,
          @"Losing verified Final Cut identity stops sizing before requesting unrelated Automation access");
    completePermission(controller.permissions.lastObject, noErr);
    check(!client.active && client.startCount == 2 && current.timelineReadCount == reads && controller.reviewClients.count == 0,
          @"A delayed permission result cannot restore a lease or read data after the host identity changed");
    [controller viewWillDisappear];
    hostSingleton = current;
    [controller viewDidAppear];
    hostSingleton = [NSObject new];
    [controller viewDidAppear];
    check(!client.active && client.startCount == 2 && controller.windowClients.count == 1 &&
          controller.permissions.count == permissions,
          @"An unrelated bundle and a non-SDK host cannot create or restart a window lease");

    current.bundleIdentifier = @"com.apple.FinalCut";
    hostSingleton = current;
    [controller viewDidAppear];
    check(client.active && client.startCount == 3 && [client.testViewID isEqual:controller.viewID],
          @"A later verified appearance still uses the original view marker");
    [controller viewWillDisappear];
    completePermission(controller.permissions.lastObject, noErr);
    check(!client.active && client.stopCount == 3 && current.timelineReadCount == reads && controller.reviewClients.count == 0,
          @"A permission callback queued before disappearance cannot restart the lease or launch analysis");
    [controller viewDidAppear];
    client.active = NO; // Model an asynchronous quiet-launch failure, whose client is retryable.
    [controller requestConnection:nil];
    check(client.active && client.startCount == 5 && controller.windowClientRunning && controller.windowClients.count == 1 &&
          controller.reviewClients.count == 0,
          @"A verified visible reconnect retries a failed quiet launch despite the controller's prior running flag");
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

static NSDictionary *navigationTime(CMTime time) {
    return @{@"numerator": @(time.value), @"denominator": @(time.timescale)};
}

static void sdkNavigationRequiresExactProjectWindowAndReturnedTime(void) {
    SSProxy *source = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Same name");
    source.startTime = CMTimeMake(107892LL * 1001, 30000);
    source.duration = CMTimeMake(3600LL * 1001, 30000);
    source.frameDuration = CMTimeMake(1001, 30000);
    CMTime target = CMTimeMake((107892LL + 1800) * 1001, 30000);
    NSDictionary *permit = @{@"time":navigationTime(target), @"sequenceStart":navigationTime(source.startTime),
        @"sequenceDuration":navigationTime(source.duration), @"frameDuration":navigationTime(source.frameDuration)};
    SSHost *current = host(source);
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    client.fakeNativeNavigation = YES;
    controller.fakeOwnsNavigationWindow = YES;
    [controller goToCut:controller.navigateMenu.itemArray.lastObject];
    check(client.nativeMove && [client.nativeNavigationMarker hasPrefix:@"silentsnip.workflow.navigate.requested."] &&
          !controller.navigateMenu.enabled && !client.highlightedCut,
          @"SDK navigation exposes its disabled marker and skips the old keyboard request");
    check(client.nativeMove(permit) && current.testTimeline.moveCount == 1 && CMTimeCompare(current.testTimeline.currentPlayhead, target) == 0,
          @"The SDK receives the exact fractional frame at a nonzero project origin");
    [client deliver:reviewResponse(@"review", @"Navigation done") busy:NO canApply:YES];
    [controller goToCut:controller.navigateMenu.itemArray.lastObject];
    controller.fakeOwnsNavigationWindow = NO;
    check(!client.nativeMove(permit) && current.testTimeline.moveCount == 1,
          @"Losing the key Workflow window after the gesture denies SDK movement");
    [client deliver:reviewResponse(@"review", @"Navigation denied") busy:NO canApply:YES];
    controller.fakeOwnsNavigationWindow = YES;
    [controller goToCut:controller.navigateMenu.itemArray.lastObject];
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-A.fcpbundle", @"Same name");
    check(!client.nativeMove(permit) && current.testTimeline.moveCount == 1,
          @"An unannounced same-name project change cannot use the earlier permit");
    current.testTimeline.sequence = source;
    [client deliver:reviewResponse(@"review", @"Navigation denied") busy:NO canApply:YES];
    [controller goToCut:controller.navigateMenu.itemArray.lastObject];
    current.testTimeline.usesFixedMoveResult = YES;
    current.testTimeline.fixedMoveResult = CMTimeAdd(target, CMTimeMake(1, 60000));
    check(!client.nativeMove(permit) && current.testTimeline.moveCount == 2 && !client.highlightedCut,
          @"A subframe SDK result fails the acknowledgment after one move and no legacy retry");
    closeController(controller);
    groupCount += 1;
}

static void retainedUpdatesNavigationAndRecovery(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    client.fakeCanUpdate = YES;
    [controller updateReviewControls];
    check(!subtreeHasButton(controller.view, @"Update Cuts") && controller.navigateMenu.enabled,
          @"Eligible review keeps navigation without a separate Update Cuts button");
    check([controller.settingsPanel isAccessibilityElement] &&
          [controller.settingsPanel.accessibilityRole isEqual:NSAccessibilityGroupRole] &&
          [controller.settingsPanel.accessibilityIdentifier isEqual:@"silentsnip.workflow.settings"],
          @"The visible settings panel is the natural accessible group used to bind automatic snapshots");
    NSMenuItem *cut = controller.navigateMenu.itemArray.lastObject;
    check([cut.representedObject isEqual:@"cut-1"] && cut.action == @selector(goToCut:),
          @"Navigation menu uses exact reviewed cut IDs");
    [controller goToCut:cut];
    check([client.highlightedCut isEqual:@"cut-1"] && !controller.fields[0].enabled,
          @"Go to Cut dispatches navigation and locks settings while busy");
    [client deliver:reviewResponse(@"review", @"Navigation done") busy:NO canApply:YES];
    controller.fields[0].stringValue = @"-42";
    [controller settingsChanged:controller.fields[0]];
    [controller settingsChanged:controller.fields[0]];
    check(controller.reviewClient == client && client.dirtyCount >= 1 && client.cancelCount == 0 &&
          !controller.applyButton.enabled && !controller.navigateMenu.enabled && controller.fields[0].enabled &&
          client.automaticUpdatePayloads.count == 0,
          @"Repeated drafts retain audio and disable stale actions while awaiting the quiet debounce");
    runAutomaticUpdates(controller);
    NSString *edit = client.updatePayload[@"edit"];
    check([client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-42] &&
          [client.updatePayload[@"identifier"] isEqual:[@"silentsnip.workflow.settings.requested." stringByAppendingString:edit]] &&
          client.automaticUpdatePayloads.count == 1 && !controller.applyButton.enabled && controller.fields[0].enabled,
          @"Debounced update submits only the latest draft through its native settings group and keeps typing available");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && !controller.automaticUpdatePending &&
          [controller.settingsPanel.accessibilityIdentifier isEqual:@"silentsnip.workflow.settings"],
          @"The matching acknowledgement clears the native pending marker and enables the refreshed review");
    NSMutableDictionary *snapshot = [reviewResponse(@"review", @"Cuts use the last analyzed audio. Apply Cuts verifies the current audio before editing. Click Analyze Again after changing volume or audio effects. Analysis complete. Review the proposed ranges, then click Apply Cuts.") mutableCopy];
    snapshot[@"usesAudioSnapshot"] = @YES;
    [client deliver:snapshot busy:NO canApply:YES];
    check([controller.statusLabel.stringValue hasPrefix:@"Cuts updated."] && controller.detailsButton.hidden &&
          controller.applyButton.enabled, @"A successful snapshot update is informational and retains Apply authority");
    snapshot[@"message"] = @"Cuts use the last analyzed audio. Apply verifies current audio before editing. Use Analyze Audio Again after changing volume or effects. Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts.";
    [client deliver:snapshot busy:NO canApply:YES];
    check([controller.statusLabel.stringValue hasPrefix:@"Cuts updated."] && controller.detailsButton.hidden &&
          controller.applyButton.enabled, @"A legacy worker's successful snapshot update stays informational and retains Apply authority");
    NSDictionary *context = [controller observedProjectContext];
    NSUInteger generation = controller.contextGeneration;
    NSURL *receipt = [NSURL fileURLWithPath:@"/Test/Result/Silent Snip.fcpxml"];
    [controller verifyResultURL:receipt context:context generation:generation];
    SSFakeWorkflowReviewClient *recovery = controller.reviewClients.lastObject;
    NSString *gesture = recovery.verifyPayload[@"gesture"];
    check(recovery != client && [recovery.verifyPayload[@"url"] isEqual:receipt] &&
          [recovery.verifyPayload[@"projectUID"] isEqual:@"project-A"] &&
          [recovery.verifyPayload[@"identifier"] isEqual:[@"silentsnip.workflow.verify.requested." stringByAppendingString:gesture]] &&
          [recovery.verifyPayload[@"disabled"] boolValue] && recovery.startCount == 0,
          @"Explicit receipt recovery pins the project and native gesture without Analyze or Apply");
    recovery.fakeBusy = NO;
    NSUInteger count = controller.reviewClients.count;
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-A.fcpbundle", @"B");
    [controller verifyResultURL:receipt context:context generation:generation];
    check(controller.reviewClients.count == count, @"A stale file panel cannot dispatch recovery in a different project");
    closeController(controller);
    groupCount += 1;
}

static void runVerificationCompletion(SSTestWorkflowViewController *controller) {
    check(controller.verificationCompletions.count > 0, @"A panel completion belongs to an explicitly scheduled settle");
    dispatch_block_t block = controller.verificationCompletions.firstObject;
    [controller.verificationCompletions removeObjectAtIndex:0];
    block();
}

static void nativeChooserCompletionRetainsIdentityAndSettlesSDK(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Original title"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    NSUInteger generation = controller.contextGeneration;
    NSDictionary *ticket = [controller beginVerificationPanel];
    check(ticket != nil && controller.verificationPanelPending && !controller.verifyButton.enabled &&
        !controller.analyzeButton.enabled, @"The native chooser pins one project and prevents duplicate presentation");
    check([controller beginVerificationPanel] == nil, @"A pending native chooser cannot open another file sheet");
    current.testTimeline.sequence = nil;
    [current.testTimeline notifySequenceChanged];
    check(controller.settingsLoaded && controller.contextGeneration == generation &&
        [controller.projectUID isEqual:@"project-A"] && controller.settings.loads.count == 1,
        @"A transient empty SDK sequence during the native sheet does not unload its pinned project settings");
    NSURL *receipt = [NSURL fileURLWithPath:@"/Test/Result/Silent Snip.fcpxml"];
    [controller completeVerificationPanelWithURL:receipt ticket:ticket];
    check(controller.reviewClients.count == 0 && controller.verificationCompletions.count == 1,
        @"Selecting a real file defers dispatch until the sheet completion unwinds");
    runVerificationCompletion(controller);
    check(controller.reviewClients.count == 0 && controller.verificationCompletions.count == 1 &&
        controller.verificationPanelPending, @"A temporarily absent SDK project gets a bounded post-sheet settle");
    current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-A.fcpbundle/", @"Refreshed title");
    ((SSProxy *)((SSProxy *)current.testTimeline.sequence.container).container.container).name = @"Refreshed library label";
    runVerificationCompletion(controller);
    SSFakeWorkflowReviewClient *recovery = controller.reviewClients.lastObject;
    check(!controller.verificationPanelPending && recovery != nil &&
        [recovery.verifyPayload[@"projectUID"] isEqual:@"project-A"] &&
        [recovery.verifyPayload[@"projectName"] isEqual:@"Refreshed title"] &&
        [recovery.verifyPayload[@"url"] isEqual:receipt] && [recovery.verifyPayload[@"disabled"] boolValue],
        @"Settled identity uses path and UID despite refreshed display labels and keeps the fresh native gesture disabled");
    closeController(controller);
    groupCount += 1;
}

static void nativeChooserRejectsChangedClosedCancelledAndMissingContexts(void) {
    NSURL *receipt = [NSURL fileURLWithPath:@"/Test/Result/Silent Snip.fcpxml"];
    for (NSUInteger mode = 0; mode < 4; mode++) {
        SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Same title"));
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        NSDictionary *ticket = [controller beginVerificationPanel];
        if (mode == 0) {
            current.testTimeline.sequence = sequence(@"project-A", @"/Test/Library-B.fcpbundle", @"Same title");
            [controller completeVerificationPanelWithURL:receipt ticket:ticket]; runVerificationCompletion(controller);
            check(controller.reviewClients.count == 0 && [controller.statusDetails.stringValue containsString:@"project changed"],
                @"A same-named project/UID in another library is rejected with an actionable panel completion message");
        } else if (mode == 1) {
            [controller completeVerificationPanelWithURL:receipt ticket:ticket];
            [controller viewWillDisappear]; runVerificationCompletion(controller);
            check(controller.reviewClients.count == 0 && !controller.verificationPanelPending,
                @"Closing the Workflow view invalidates an already queued native sheet completion");
        } else if (mode == 2) {
            [controller completeVerificationPanelWithURL:nil ticket:ticket];
            check(controller.reviewClients.count == 0 && !controller.verificationPanelPending &&
                controller.verificationCompletions.count == 0 && controller.analyzeButton.enabled,
                @"Cancelling the native chooser restores idle actions without dispatch or scheduled work");
        } else {
            current.testTimeline.sequence = nil;
            [controller completeVerificationPanelWithURL:receipt ticket:ticket];
            for (NSUInteger i = 0; i < 11; i++) runVerificationCompletion(controller);
            check(controller.reviewClients.count == 0 && !controller.verificationPanelPending &&
                controller.verificationCompletions.count == 0 && [controller.statusDetails.stringValue containsString:@"did not restore"],
                @"Missing SDK identity stops after the bounded settle and reports why recovery did not start");
        }
        closeController(controller);
    }
    groupCount += 1;
}

static SSFakeWorkflowReviewClient *beginAutomaticReview(SSTestWorkflowViewController *controller) {
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    client.fakeCanUpdate = YES;
    [controller updateReviewControls];
    return client;
}

static void automaticDraftsCoalesceWithoutNewAnalysis(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    for (NSString *value in @[@"-49", @"-48", @"-47"]) {
        controller.fields[0].stringValue = value;
        [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
            object:controller.fields[0]]];
    }
    check(client.automaticUpdatePayloads.count == 0 && controller.automaticUpdatePending &&
          controller.fields[0].enabled && !controller.applyButton.enabled && !controller.navigateMenu.enabled,
          @"Typing drafts remains editable and disables stale actions without immediately dispatching work");
    check(controller.automaticUpdateCompletions.count > 0, @"A valid edit schedules a quiet automatic refresh");
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-47],
          @"Only the newest debounced settings snapshot is submitted");
    check(client.startCount == 1 && controller.reviewClients.count == 1 &&
          client.applyCommandCount == 0 && client.applyGestures.count == 0 && controller.settings.saves.count == 0,
          @"Automatic range updates neither Analyze again, Apply, nor persist settings");
    check(controller.fields[0].enabled && client.updatingCuts && !controller.applyButton.enabled &&
          !subtreeHasButton(controller.view, @"Update Cuts"),
          @"An in-flight range update permits further typing without exposing the removed action");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && !controller.automaticUpdatePending &&
          [controller.settingsPanel.accessibilityIdentifier isEqual:@"silentsnip.workflow.settings"],
          @"Only the acknowledged newest snapshot restores Apply and clears the pending native marker");
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1, @"Already consumed debounce callbacks cannot send a duplicate update");
    closeController(controller);
    groupCount += 1;
}

static void textEditingDefersSDKContextUntilDebounce(void) {
    for (NSNumber *changed in @[@NO, @YES]) {
        BOOL changedProject = changed.boolValue;
        SSProxy *original = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
        SSHost *current = host(original);
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
        current.testTimeline.sequence = nil; // The SDK proxy is absent only during the native text callback.
        NSUInteger reads = current.testTimeline.activeSequenceReadCount;
        controller.fields[0].stringValue = @"-42";
        [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
            object:controller.fields[0]]];
        check(current.testTimeline.activeSequenceReadCount == reads && controller.settingsLoaded &&
              [controller.projectUID isEqual:@"project-A"] && [controller.fields[0].stringValue isEqual:@"-42"] &&
              controller.reviewClient == client && controller.automaticUpdatePending && !controller.applyButton.enabled &&
              client.automaticUpdatePayloads.count == 0,
              @"The text notification records the draft and disables stale Apply without synchronously querying an unavailable SDK proxy");
        current.testTimeline.sequence = changedProject
            ? sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B") : original;
        runAutomaticUpdates(controller);
        if (changedProject) {
            check(client.automaticUpdatePayloads.count == 0 && controller.reviewClient == nil &&
                  !controller.settingsLoaded && [controller.projectUID isEqual:@"project-B"] &&
                  controller.settings.loads.count == 2 && !controller.applyButton.enabled,
                  @"The deferred identity check rejects an actual project switch before any retained-audio update is sent");
            completeLoad(controller.settings.loads[1], values(-31, YES), nil);
            check([controller.fields[0].stringValue isEqual:@"-31"] && controller.settings.saves.count == 0,
                  @"The new project loads only its own settings instead of adopting the previous project's typed draft");
        } else {
            check(client.automaticUpdatePayloads.count == 1 && controller.reviewClient == client &&
                  [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-42] &&
                  current.testTimeline.activeSequenceReadCount > reads && !controller.applyButton.enabled,
                  @"A matching SDK context on the debounced turn permits exactly the retained latest draft");
            [client acknowledgeAutomaticUpdate];
            check(controller.applyButton.enabled && !controller.automaticUpdatePending,
                  @"The matching fresh identity and acknowledged settings restore review authority");
        }
        closeController(controller);
    }
    groupCount += 1;
}

static void reentrantMissingSDKNoticeCannotEraseTypedDraft(void) {
    SSProxy *original = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
    SSHost *current = host(original);
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    client.notifySequenceWhileMarkingDirty = YES;
    current.testTimeline.sequence = nil;
    controller.fields[0].stringValue = @"-42";
    [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
        object:controller.fields[0]]];
    check(controller.settingsLoaded && [controller.projectUID isEqual:@"project-A"] &&
          [controller.fields[0].stringValue isEqual:@"-42"] && controller.reviewClient == client &&
          controller.automaticUpdatePending && !controller.applyButton.enabled &&
          controller.settings.loads.count == 1 && client.cancelCount == 0 && client.detachCount == 0,
          @"A nil SDK notification nested inside text editing cannot unload values or destroy retained review audio");
    current.testTimeline.sequence = original;
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-42],
          @"The retained draft still requires a matching fresh identity before its later update");
    [client acknowledgeAutomaticUpdate];
    closeController(controller);
    groupCount += 1;
}

static void missingSDKDuringAutomaticUpdateUsesWorkerAuthorityOnly(void) {
    for (NSNumber *reject in @[@NO, @YES]) {
        BOOL rejected = reject.boolValue;
        SSProxy *original = sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A");
        SSHost *current = host(original);
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
        current.testTimeline.sequence = nil;
        controller.fields[0].stringValue = @"-42";
        [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
            object:controller.fields[0]]];
        runAutomaticUpdates(controller);
        check(client.automaticUpdatePayloads.count == 1 && controller.settingsLoaded &&
              controller.reviewClient == client && [controller.projectUID isEqual:@"project-A"] &&
              [controller.fields[0].stringValue isEqual:@"-42"] && !controller.applyButton.enabled,
              @"A nil SDK context at the debounce cannot erase the owned draft and delegates only its local update to native worker authority");
        [current.testTimeline notifySequenceChanged];
        check(controller.settingsLoaded && controller.reviewClient == client &&
              [controller.fields[0].stringValue isEqual:@"-42"] && controller.automaticUpdatePending &&
              !controller.applyButton.enabled && client.cancelCount == 0 && client.detachCount == 0,
              @"A later nil SDK notification preserves an in-flight owned automatic review without restoring stale Apply");
        if (rejected) {
            NSMutableDictionary *response = [client.lastResponse mutableCopy];
            response[@"rejectedSettingsEdit"] = client.updatePayload[@"edit"];
            response[@"rejectedSettingsSequence"] = @1;
            client.fakeDirty = YES;
            [client deliver:response busy:NO canApply:NO];
            runAutomaticUpdates(controller);
            check(client.automaticUpdatePayloads.count == 1 && controller.automaticUpdatePending &&
                  controller.settingsLoaded && [controller.fields[0].stringValue isEqual:@"-42"] &&
                  !controller.applyButton.enabled,
                  @"A worker rejection under nil SDK keeps the draft inactive and cannot retry or authorize Apply");
            current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
            [current.testTimeline notifySequenceChanged];
            runAutomaticUpdates(controller);
            check(controller.reviewClient == nil && !controller.settingsLoaded &&
                  [controller.projectUID isEqual:@"project-B"] && controller.settings.loads.count == 2 &&
                  client.detachCount == 1 && client.automaticUpdatePayloads.count == 1,
                  @"A known different SDK project invalidates the retained draft despite earlier nil-context preservation");
            completeLoad(controller.settings.loads[1], values(-31, YES), nil);
        } else {
            [client acknowledgeAutomaticUpdate];
            check(controller.applyButton.enabled && !controller.automaticUpdatePending &&
                  controller.settingsLoaded && [controller.fields[0].stringValue isEqual:@"-42"] &&
                  client.applyCommandCount == 0 && client.startCount == 1,
                  @"Only the independent worker's exact latest acknowledgement activates the refreshed review, without fresh analysis or editing");
            [controller applyCuts:controller.applyButton];
            check(client.applyCommandCount == 0 && controller.reviewClient == nil && !controller.settingsLoaded,
                  @"Manual Apply still requires its separate fresh SDK identity and cannot edit while that context is missing");
        }
        check(client.startCount == 1 && client.applyCommandCount == 0,
              @"Missing SDK recovery never substitutes an automatic Analyze or Apply command");
        closeController(controller);
    }
    groupCount += 1;
}

static void automaticInvalidAndInFlightDraftsStayPending(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    for (NSString *value in @[@"", @"-", @".", @"-90"]) {
        controller.fields[0].stringValue = value;
        [controller controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
            object:controller.fields[0]]];
        runAutomaticUpdates(controller);
        check(client.automaticUpdatePayloads.count == 0 && controller.reviewClient == client &&
              !controller.applyButton.enabled && controller.fields[0].enabled && controller.detailsButton.hidden,
              @"Incomplete or out-of-range typing preserves retained audio without dispatch or an expanded error");
    }
    controller.fields[0].stringValue = @"-42";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1, @"A completed valid number begins one retained-audio update");
    NSString *firstEdit = client.updatePayload[@"edit"];
    controller.fields[0].stringValue = @"-38";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 && client.fakeDirty &&
          controller.fields[0].enabled && !controller.applyButton.enabled,
          @"A newer edit during an update is retained without overlapping backend work");
    [client acknowledgeAutomaticUpdate];
    check([controller.fields[0].stringValue isEqual:@"-38"] && !controller.applyButton.enabled &&
          controller.reviewClient == client,
          @"An older acknowledgement cannot replace the newer field draft or enable stale Apply");
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 2 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-38] &&
          ![client.updatePayload[@"edit"] isEqual:firstEdit],
          @"The acknowledged update is followed by exactly one latest draft with a new edit marker");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && !controller.automaticUpdatePending,
          @"Apply returns only after the newest draft is acknowledged");
    controller.fields[0].stringValue = @"-37";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    controller.fields[0].stringValue = @"";
    [controller settingsChanged:controller.fields[0]];
    [client acknowledgeAutomaticUpdate];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 3 && !controller.applyButton.enabled &&
          [controller.fields[0].stringValue isEqual:@""] && controller.fields[0].enabled,
          @"An invalid newer draft survives an old valid acknowledgement and cannot dispatch or authorize Apply");
    check(client.startCount == 1 && client.applyCommandCount == 0,
          @"Rapid and invalid drafts never substitute a fresh Analyze or Apply action");
    closeController(controller);
    groupCount += 1;
}

static void automaticCallbacksRespectReviewLifetime(void) {
    for (NSUInteger action = 0; action < 4; ++action) {
        SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
        controller.fields[0].stringValue = @"-42";
        [controller settingsChanged:controller.fields[0]];
        check(controller.automaticUpdateCompletions.count > 0, @"The lifetime fixture holds a pending debounce callback");
        if (action == 0) [controller cancelReview:controller.cancelButton];
        else if (action == 1) {
            current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
            [current.testTimeline notifySequenceChanged];
        } else if (action == 2) [controller viewWillDisappear];
        else [controller analyzeAudio:controller.analyzeButton];
        runAutomaticUpdates(controller);
        check(client.automaticUpdatePayloads.count == 0 && !controller.applyButton.enabled &&
              [controller.settingsPanel.accessibilityIdentifier isEqual:@"silentsnip.workflow.settings"],
              @"Cancel, project switch, close, or explicit Analyze invalidates queued updates and their native marker");
        if (action == 3) check(controller.reviewClients.count == 2 && controller.reviewClients.lastObject.startCount == 1,
              @"Only the deliberately clicked Analyze begins a replacement analysis");
        else check(controller.reviewClients.count == 1, @"Lifetime changes cannot silently create another analysis client");
        closeController(controller);
    }
    groupCount += 1;
}

static void automaticOutputAndSaveKeepAnalysisManual(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    [controller.output selectItemAtIndex:1];
    [controller settingsChanged:controller.output];
    check(!controller.applyButton.enabled && client.automaticUpdatePayloads.count == 0,
          @"Changing output immediately invalidates stale Apply while waiting for the automatic update");
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 &&
          [client.updatePayload[@"settings"][@"outputMode"] isEqual:@"gaps"],
          @"Output changes use the same retained-audio automatic update as detector values");
    [client acknowledgeAutomaticUpdate];
    controller.fields[0].stringValue = @"-45";
    [controller settingsChanged:controller.fields[0]];
    [controller settingsChanged:controller.fields[0]]; // Return/blur may report the same committed value.
    [controller saveSettings:controller.saveButton];
    check(controller.settings.saves.count == 1 &&
          [controller.settings.saves[0].values[@"outputMode"] isEqual:@"gaps"] &&
          [controller.settings.saves[0].values[@"thresholdDBFS"] isEqual:@-45],
          @"Save persists the current draft explicitly without restoring a different output or detector value");
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 && !controller.applyButton.enabled,
          @"A pending persistence completion defers the queued automatic update and keeps stale Apply disabled");
    completeSave(controller.settings.saves[0], nil);
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 2 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-45],
          @"Save completion resumes only the latest queued retained-audio snapshot");
    [client acknowledgeAutomaticUpdate];
    check(client.startCount == 1 && controller.reviewClients.count == 1 && client.applyCommandCount == 0 &&
          client.applyGestures.count == 0 && controller.settings.saves.count == 1,
          @"Return, blur, Save, and automatic refresh cannot launch a fresh Analyze or Apply");
    closeController(controller);
    groupCount += 1;
}

static void automaticRejectedSnapshotDoesNotLoop(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    controller.fields[0].stringValue = @"-42";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    NSString *rejectedEdit = client.updatePayload[@"edit"];
    NSMutableDictionary *rejection = [client.lastResponse mutableCopy];
    rejection[@"rejectedSettingsEdit"] = rejectedEdit;
    rejection[@"rejectedSettingsSequence"] = @1;
    client.fakeDirty = YES;
    [client deliver:rejection busy:NO canApply:NO];
    runAutomaticUpdates(controller);
    check(controller.automaticUpdatePending && !controller.applyButton.enabled && controller.fields[0].enabled &&
          client.automaticUpdatePayloads.count == 1,
          @"A declined native snapshot retains the draft but cannot loop or restore stale Apply");
    [client deliver:rejection busy:NO canApply:NO];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 && client.startCount == 1,
          @"Repeated rejection/status delivery does not retry the same snapshot or silently Analyze");
    controller.fields[0].stringValue = @"-41";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 2 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-41] &&
          ![client.updatePayload[@"edit"] isEqual:rejectedEdit] && !controller.applyButton.enabled,
          @"A new user edit permits one fresh native snapshot instead of replaying the rejected marker");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && !controller.automaticUpdatePending && client.applyCommandCount == 0,
          @"Only the newly accepted snapshot returns review authority without applying anything");
    closeController(controller);
    groupCount += 1;
}

static void automaticReentrantDeclineQueuesOnlyTheNewerDraft(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    client.reentrantAutomaticThreshold = @"-38";
    controller.fields[0].stringValue = @"-42";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdateAttemptCount == 1 && client.automaticUpdatePayloads.count == 0 &&
          controller.automaticUpdatePending && [controller.fields[0].stringValue isEqual:@"-38"] &&
          !controller.applyButton.enabled && controller.automaticUpdateCompletions.count > 0,
          @"A reentrant newer edit survives a declined older admission and queues its own debounce without sending stale settings");
    check(controller.automaticUpdateEdit == nil &&
          [controller.settingsPanel.accessibilityIdentifier isEqual:@"silentsnip.workflow.settings"],
          @"The declined packet clears only its own native edit marker before the newer snapshot is exposed");
    runAutomaticUpdates(controller);
    check(client.automaticUpdateAttemptCount == 2 && client.automaticUpdatePayloads.count == 1 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-38] && !controller.applyButton.enabled,
          @"Exactly one newest snapshot is sent after synchronous supersession, without needing another user edit");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && !controller.automaticUpdatePending &&
          client.startCount == 1 && client.applyCommandCount == 0,
          @"Only the latest accepted snapshot restores Apply, with no implicit Analyze or Apply");
    closeController(controller);
    groupCount += 1;
}

static void automaticForegroundPauseResumesOnlyForFinalCut(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginAutomaticReview(controller);
    client.fakeAutomaticForeground = NO;
    controller.fields[0].stringValue = @"-42";
    [controller settingsChanged:controller.fields[0]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 0 && controller.automaticUpdatePending &&
          !controller.applyButton.enabled && !client.busy && client.startCount == 1 &&
          controller.automaticUpdateCompletions.count == 0,
          @"Background refusal keeps the latest draft queued without dispatching or launching another analysis");
    SSHost *unrelated = [SSHost new]; unrelated.bundleIdentifier = @"example.unrelated";
    [controller hostDidActivate:[NSNotification notificationWithName:NSWorkspaceDidActivateApplicationNotification
        object:nil userInfo:@{NSWorkspaceApplicationKey:unrelated}]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 0 && controller.automaticUpdatePending,
          @"Another application's activation cannot resume the queued Final Cut update");
    client.fakeAutomaticForeground = YES;
    [controller hostDidActivate:[NSNotification notificationWithName:NSWorkspaceDidActivateApplicationNotification
        object:nil userInfo:@{NSWorkspaceApplicationKey:current}]];
    runAutomaticUpdates(controller);
    check(client.automaticUpdatePayloads.count == 1 &&
          [client.updatePayload[@"settings"][@"thresholdDBFS"] isEqual:@-42] && !controller.applyButton.enabled,
          @"Returning to Final Cut schedules exactly the latest retained-audio draft and waits for its acknowledgement");
    [client acknowledgeAutomaticUpdate];
    check(controller.applyButton.enabled && client.startCount == 1 && client.applyCommandCount == 0,
          @"Foreground resumption restores only reviewed-update authority, never an implicit Analyze or Apply");
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
              [controller.statusLabel.stringValue containsString:@"Analyze Again"],
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
    check([controller.statusLabel.stringValue isEqual:@""] && controller.analyzeButton.enabled &&
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
    [client deliver:reviewResponse(@"verifying", @"Verifying the existing result…") busy:YES canApply:NO];
    [current.testTimeline notifySequenceChanged];
    check(controller.reviewClient == client && controller.settings.loads.count == 1 && [controller.projectUID isEqual:@"project-A"],
          @"Clearing the retry flag during active verification still defers SDK rebinding until work finishes");
    [client deliver:reviewResponse(@"completed", @"Existing result verified") busy:NO canApply:NO];
    check(client.detachCount == 1 && controller.reviewClient == nil && [controller.projectUID isEqual:@"imported-result"] &&
          controller.settings.loads.count == 2 && controller.retryButton.hidden && !controller.analyzeButton.enabled,
          @"Successful verification settles recovery, then loads the actual result project's own settings");
    completeLoad(controller.settings.loads[1], values(-32, NO), nil);
    check(controller.analyzeButton.enabled && controller.saveButton.enabled && controller.fields[0].enabled &&
          [controller.fields[0].stringValue isEqual:@"-32"] && [controller.statusLabel.stringValue isEqual:@""] &&
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
    check([controller.statusLabel.stringValue isEqual:@"Bring Final Cut Pro to the front, then click Apply Cuts."],
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
    check([controller.projectUID isEqual:@"verified-result"] && [controller.statusLabel.stringValue isEqual:@""] &&
          !controller.completionMessage && !controller.completionContext,
          @"Automatic result rebinding clears a source-scoped notice because the response has no verified result identity");
    [current.testTimeline notifySequenceChanged];
    check(controller.settings.loads.count == 2 && [controller.statusLabel.stringValue isEqual:@""],
          @"Duplicate callbacks for the result preserve its current settings status without reviving a source notice");

    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-A.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    check(!controller.completionMessage && !controller.completionContext && !controller.reviewClient && !controller.applyButton.enabled,
          @"Changing project UID in the same library clears the prior verification notice and all review authority");
    completeLoad(controller.settings.loads[2], values(-32, YES), nil);
    check([controller.statusLabel.stringValue isEqual:@""] &&
          [controller.reviewSummary.stringValue isEqual:@"Select a clip to analyze."],
          @"The new project's own loaded status replaces the old result notice before another Analyze");
    client.testUpdate(reviewResponse(@"completed", @"Late verified Cleaned A"));
    check(!controller.completionMessage && [controller.statusLabel.stringValue isEqual:@""],
          @"A queued terminal callback cannot restore a cleared notice after rebinding");

    client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    [client deliver:reviewResponse(@"completed", @"Verified B in Library A") busy:NO canApply:NO];
    check([controller.completionContext[@"projectUID"] isEqual:@"project-B"], @"A same-context terminal result also receives a scoped notice");
    current.testTimeline.sequence = sequence(@"project-B", @"/Test/Library-B.fcpbundle", @"B");
    [current.testTimeline notifySequenceChanged];
    completeLoad(controller.settings.loads[3], values(-40, NO), nil);
    check(!controller.completionMessage && !controller.completionContext &&
          [controller.statusLabel.stringValue isEqual:@""],
          @"A reused project UID in another library cannot inherit the prior library's terminal notice");

    client = beginReview(controller);
    [controller applyCuts:controller.applyButton];
    [client deliver:reviewResponse(@"completed", @"Verified B in Library B") busy:NO canApply:NO];
    [controller viewWillDisappear];
    check(!controller.completionMessage && !controller.completionContext, @"Closing the extension clears its terminal notice identity");
    [controller viewDidAppear];
    completeLoad(controller.settings.loads[4], values(-40, YES), nil);
    check([controller.statusLabel.stringValue isEqual:@""] && !controller.completionMessage &&
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
    check([controller.statusLabel.stringValue isEqual:@""] && controller.analyzeButton.enabled &&
          !controller.applyButton.enabled, @"B finishes loading with only its own status and remains unanalyzed");
    client.testUpdate(reviewResponse(@"completed", @"Late second verified result for A"));
    check(!controller.completionMessage && [controller.statusLabel.stringValue isEqual:@""],
          @"A further queued terminal response cannot restore A's notice after B has bound");
    closeController(controller);
    groupCount += 1;
}

static BOOL nearlyEqualSize(NSSize first, NSSize second) {
    return fabs(first.width - second.width) < 0.5 && fabs(first.height - second.height) < 0.5;
}

static void logOffscreenGeometry(NSString *phase, NSView *parent, SSWorkflowViewController *controller) {
    if (!getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) return;
    fprintf(stderr, "%s parent=%s bounds=%s autosizes=%d root=%s mask=%lu translates=%d body=%s content=%s review=%s\n",
            phase.UTF8String, NSStringFromRect(parent.frame).UTF8String, NSStringFromRect(parent.bounds).UTF8String,
            parent.autoresizesSubviews, NSStringFromRect(controller.view.frame).UTF8String,
            (unsigned long)controller.view.autoresizingMask, controller.view.translatesAutoresizingMaskIntoConstraints,
            NSStringFromRect(controller.bodyView.frame).UTF8String, NSStringFromRect(controller.content.frame).UTF8String,
            NSStringFromRect(controller.reviewScroll.frame).UTF8String);
    fprintf(stderr, "parent constraints=%s\nroot constraints=%s\n", parent.constraints.description.UTF8String,
            controller.view.constraints.description.UTF8String);
}

static void settleOffscreenLayout(NSView *parent, SSWorkflowViewController *controller) {
    // Only the timestamp document tiles a scroller. Exercise the same bounded
    // parent/layout passes without a window, drawing, or event processing.
    for (NSUInteger pass = 0; pass < 3; ++pass) {
        [parent layoutSubtreeIfNeeded];
        [controller.view layoutSubtreeIfNeeded];
        [controller.reviewScroll tile];
        [controller viewDidLayout];
    }
}

static NSRect frameInRoot(NSView *view, SSWorkflowViewController *controller) {
    return [view convertRect:view.bounds toView:controller.view];
}

static void checkStickyChrome(SSWorkflowViewController *controller) {
    NSRect root = NSInsetRect(controller.view.bounds, -0.5, -0.5);
    NSRect column = frameInRoot(controller.contentColumn, controller);
    NSRect header = frameInRoot(controller.headerView, controller);
    NSRect footer = frameInRoot(controller.footerView, controller);
    NSRect body = frameInRoot(controller.bodyView, controller);
    check(fabs(column.size.width - fmin(560, controller.view.bounds.size.width)) < 0.5 &&
          fabs(column.size.height - controller.view.bounds.size.height) < 0.5 &&
          fabs(NSMaxY(column) - NSMaxY(controller.view.bounds)) < 0.5 &&
          fabs(NSMidX(column) - NSMidX(controller.view.bounds)) <= 0.5,
          @"The bounded content column stays centered and fills the host's fixed height");
    NSRect section = frameInRoot(controller.settingsPanel, controller);
    for (NSValue *value in @[[NSValue valueWithRect:header], [NSValue valueWithRect:footer]]) {
        NSRect part = value.rectValue;
        check(fabs(NSMinX(part) - NSMinX(section)) < 0.5 && fabs(part.size.width - section.size.width) < 0.5,
              @"The project header and footer align with the settings and review section edges");
    }
    check(fabs(NSMinX(body) - NSMinX(column)) < 0.5 && fabs(body.size.width - column.size.width) < 0.5,
          @"The plain body occupies the full centered column without an outer scrollbar gutter");
    check(!NSIsEmptyRect(header) && NSContainsRect(root, header) &&
          ![controller.headerView isDescendantOf:controller.content],
          @"The project header stays within the host viewport, outside the settings and review body");
    check(!NSIsEmptyRect(footer) && NSContainsRect(root, footer) &&
          ![controller.footerView isDescendantOf:controller.content],
          @"The action footer stays within the host viewport, outside the settings and review body");
    check(!NSIsEmptyRect(body) && NSContainsRect(root, body) &&
          !NSIntersectsRect(NSInsetRect(header, 0.5, 0.5), NSInsetRect(body, 0.5, 0.5)) &&
          !NSIntersectsRect(NSInsetRect(footer, 0.5, 0.5), NSInsetRect(body, 0.5, 0.5)),
          @"The body viewport occupies the space between the fixed header and actions");
    NSButton *resultAction = controller.retryButton.hidden ? controller.applyButton : controller.retryButton;
    for (NSButton *button in @[controller.analyzeButton, resultAction, controller.cancelButton]) {
        NSRect rect = frameInRoot(button, controller);
        check(!button.hidden && !NSIsEmptyRect(rect) && NSContainsRect(root, rect),
              @"Analyze, the current Apply or Retry action, and the native Cancel marker remain visible without body scrolling");
    }
    check([controller.cancelButton.accessibilityIdentifier isEqual:
           [@"silentsnip.workflow.review." stringByAppendingString:controller.viewID]],
          @"The fixed Cancel control preserves the worker's exact native view marker");
}

static void checkBodyWidth(SSWorkflowViewController *controller) {
    check(fabs(controller.content.frame.size.width - controller.bodyView.bounds.size.width) < 0.5 &&
          fabs(controller.content.frame.size.height - controller.bodyView.bounds.size.height) < 0.5,
          @"The content fills the plain body's actual width and height without a larger outer scroll document");
    check(controller.content.enclosingScrollView == nil && controller.bodyView.enclosingScrollView == nil,
          @"The body and settings stack have no enclosing scroll viewport");
    NSEdgeInsets insets = controller.content.edgeInsets;
    CGFloat expectedWidth = controller.content.bounds.size.width - insets.left - insets.right;
    for (NSView *panel in @[controller.settingsPanel, controller.reviewPanel]) {
        NSRect rect = [panel convertRect:panel.bounds toView:controller.content];
        check(!NSIsEmptyRect(rect) && fabs(NSMinX(rect) - insets.left) < 0.5 &&
              fabs(rect.size.width - expectedWidth) < 0.5 && rect.size.width <= 536.5,
              @"Settings and review fill the compact body without growing past its 560-point column");
    }
    check(controller.content.orientation == NSUserInterfaceLayoutOrientationVertical,
          @"Settings remain above the full-width review at every viewport size");
}

static void checkNumericGroupArrangement(SSWorkflowViewController *controller) {
    NSMutableArray<NSValue *> *rectangles = [NSMutableArray new];
    for (NSTextField *field in controller.fields) {
        NSRect rect = [field convertRect:field.bounds toView:controller.settingsPanel];
        check(!NSIsEmptyRect(rect) && NSContainsRect(NSInsetRect(controller.settingsPanel.bounds, -0.5, -0.5), rect),
              @"Every numeric setting stays inside the compact settings band");
        [rectangles addObject:[NSValue valueWithRect:rect]];
    }
    NSRect first = rectangles[0].rectValue, second = rectangles[1].rectValue;
    NSRect third = rectangles[2].rectValue, fourth = rectangles[3].rectValue;
    if (controller.contentColumn.bounds.size.width >= 530) {
        check(fabs(NSMidY(first) - NSMidY(second)) < 0.5 && fabs(NSMidY(first) - NSMidY(third)) < 0.5 &&
              fabs(NSMidY(first) - NSMidY(fourth)) < 0.5 && NSMaxX(first) < NSMinX(second) &&
              NSMaxX(second) < NSMinX(third) && NSMaxX(third) < NSMinX(fourth),
              @"A column at least 530 points wide uses one aligned row for all four numeric settings");
    } else {
        check(fabs(NSMidY(first) - NSMidY(second)) < 0.5 && fabs(NSMidY(third) - NSMidY(fourth)) < 0.5 &&
              fabs(NSMidY(first) - NSMidY(third)) >= first.size.height &&
              fabs(NSMinX(first) - NSMinX(third)) < 0.5 && fabs(NSMinX(second) - NSMinX(fourth)) < 0.5,
              @"A column narrower than 530 points retains two compact, aligned rows of settings");
    }
    NSRect output = [controller.output convertRect:controller.output.bounds toView:controller.settingsPanel];
    NSRect save = [controller.saveButton convertRect:controller.saveButton.bounds toView:controller.settingsPanel];
    check(fabs(NSMidY(output) - NSMidY(save)) <= 3 && NSMaxX(output) <= NSMinX(save),
          @"Output and Save share one compact row without overlapping");
    NSView *row = controller.output.superview;
    NSRect rowRect = [row convertRect:row.bounds toView:controller.settingsPanel];
    NSRect outputAlignment = [row convertRect:[controller.output alignmentRectForFrame:controller.output.frame]
                                      toView:controller.settingsPanel];
    NSRect saveAlignment = [row convertRect:[controller.saveButton alignmentRectForFrame:controller.saveButton.frame]
                                    toView:controller.settingsPanel];
    if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) fprintf(stderr,
        "output row root=%s column=%s row=%s output=%s save=%s outputAlign=%s saveAlign=%s\n",
        NSStringFromRect(controller.view.bounds).UTF8String, NSStringFromRect(controller.contentColumn.bounds).UTF8String,
        NSStringFromRect(rowRect).UTF8String, NSStringFromRect(output).UTF8String, NSStringFromRect(save).UTF8String,
        NSStringFromRect(outputAlignment).UTF8String, NSStringFromRect(saveAlignment).UTF8String);
    check(controller.saveButton.superview == row &&
          NSContainsRect(NSInsetRect(controller.settingsPanel.bounds, -0.5, -0.5), output) &&
          NSContainsRect(NSInsetRect(controller.settingsPanel.bounds, -0.5, -0.5), save) &&
          NSContainsRect(NSInsetRect(rowRect, -0.5, -0.5), outputAlignment) &&
          NSContainsRect(NSInsetRect(rowRect, -0.5, -0.5), saveAlignment) &&
          fabs(NSMaxX(saveAlignment) - NSMaxX(rowRect)) <= 1 &&
          NSMinX(saveAlignment) - NSMaxX(outputAlignment) <= 14,
          @"Output fills the row beside a visible trailing Save button without an empty spring gap");
}

static void checkBodyControlVisible(NSView *control, SSWorkflowViewController *controller) {
    NSRect rect = [control convertRect:control.bounds toView:controller.bodyView];
    check(!NSIsEmptyRect(rect) && NSContainsRect(NSInsetRect(controller.bodyView.bounds, -0.5, -0.5), rect),
          @"Each settings and review control is fully visible in the short plain body without scrolling");
    checkStickyChrome(controller);
}

static void checkOnlyTimestampScrolls(SSWorkflowViewController *controller) {
    NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:controller.view];
    NSMutableArray<NSScrollView *> *scrollViews = [NSMutableArray new];
    while (pending.count) {
        NSView *view = pending.lastObject;
        [pending removeLastObject];
        if ([view isKindOfClass:NSScrollView.class]) [scrollViews addObject:(NSScrollView *)view];
        [pending addObjectsFromArray:view.subviews];
    }
    check(scrollViews.count == 1 && scrollViews.firstObject == controller.reviewScroll,
          @"The timestamp list is the only NSScrollView anywhere in the main window");
    check(controller.reviewScroll.documentView == controller.cutList &&
          controller.cutList.enclosingScrollView == controller.reviewScroll &&
          controller.content.enclosingScrollView == nil && controller.headerView.enclosingScrollView == nil &&
          controller.footerView.enclosingScrollView == nil && controller.statusDetails.enclosingScrollView == nil,
          @"Only timestamp rows belong to a scroll document; settings, status, project and actions remain stationary");
    NSRect pane = [controller.reviewScroll convertRect:controller.reviewScroll.bounds toView:controller.bodyView];
    check(!controller.reviewScroll.hidden && !controller.cutColumnHeader.hidden && pane.size.height >= 79.5 &&
          NSContainsRect(NSInsetRect(controller.bodyView.bounds, -0.5, -0.5), pane),
          @"The adaptive cut viewport and both of its edges fit the plain body at supported short heights");
    checkBodyControlVisible(controller.cutColumnHeader, controller);
    checkStickyChrome(controller);
}

static void exerciseOffscreenParentResize(BOOL constrainsHostSize) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, NO), nil);
    controller.fields[0].stringValue = @"-43";
    NSUInteger generation = controller.contextGeneration;
    NSSize minimum = [controller preferredMinimumSize];
    NSSize maximum = [controller preferredMaximumSize];
    check(nearlyEqualSize(minimum, NSMakeSize(460, 540)) && maximum.width == 560 && maximum.height == CGFLOAT_MAX,
          @"The SDK minimum reserves room for stationary settings, actions and an adaptive timestamp list");
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
    check(controller.content.superview == controller.bodyView && controller.content.isFlipped &&
          ![controller.bodyView isKindOfClass:NSScrollView.class],
          @"The top-origin content stack belongs directly to a plain stationary body");
    check(controller.reviewScroll.documentView == controller.cutList,
          @"The cut list has its own review viewport instead of extending the whole window");
    checkStickyChrome(controller);
    checkBodyWidth(controller);
    checkOnlyTimestampScrolls(controller);
    CGFloat tallListHeight = controller.reviewScroll.frame.size.height;

    hostHeight.constant = minimum.height;
    [parent setFrameSize:NSMakeSize(480, minimum.height)];
    logOffscreenGeometry(@"shrink before layout", parent, controller);
    settleOffscreenLayout(parent, controller);
    logOffscreenGeometry(@"shrink after layout", parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"Reducing parent height resizes the root instead of clipping a fixed-height root");
    checkStickyChrome(controller);
    checkBodyWidth(controller);
    check(controller.content.orientation == NSUserInterfaceLayoutOrientationVertical,
          @"Narrow host windows keep settings above the full-width review");
    checkNumericGroupArrangement(controller);
    check(controller.reviewScroll.frame.size.height >= 79.5 &&
          controller.reviewScroll.frame.size.height < tallListHeight - 50,
          @"Reducing host height shrinks the timestamp viewport instead of creating outer body overflow");
    for (NSTextField *field in controller.fields) checkBodyControlVisible(field, controller);
    checkBodyControlVisible(controller.output, controller);
    checkBodyControlVisible(controller.saveButton, controller);
    for (NSView *control in @[controller.allButton, controller.noneButton, controller.reviewSummary, controller.cutColumnHeader])
        checkBodyControlVisible(control, controller);
    checkOnlyTimestampScrolls(controller);

    CGFloat narrowWidth = controller.content.frame.size.width;
    hostWidth.constant = 840;
    hostHeight.constant = minimum.height;
    [parent setFrameSize:NSMakeSize(840, minimum.height)];
    settleOffscreenLayout(parent, controller);
    logOffscreenGeometry(@"wide after layout", parent, controller);
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"The production-sized host still owns the root dimensions");
    check(controller.content.frame.size.width > narrowWidth + 50 && controller.content.frame.size.width <= 560.5 &&
          fabs(controller.content.frame.size.width - controller.bodyView.bounds.size.width) < 0.5,
          @"The stationary content grows only to its compact column cap when the host becomes wider");
    checkNumericGroupArrangement(controller);
    settleOffscreenLayout(parent, controller);
    checkStickyChrome(controller);
    checkBodyWidth(controller);
    NSMutableArray<NSView *> *normalControls = [controller.fields mutableCopy];
    [normalControls addObjectsFromArray:@[controller.output, controller.saveButton, controller.allButton,
        controller.noneButton, controller.reviewSummary, controller.cutColumnHeader]];
    for (NSView *control in normalControls) checkBodyControlVisible(control, controller);
    checkOnlyTimestampScrolls(controller);
    check([controller.fields[0].stringValue isEqual:@"-43"] && controller.contextGeneration == generation &&
          controller.settings.loads.count == 1 && controller.settings.saves.count == 0,
          @"Resizing the plain body preserves the draft without loading, saving, or rebinding settings");
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
            NSSize text = [values[column] sizeWithAttributes:@{NSFontAttributeName: [row textFontForColumn:column]}];
            if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG") && text.width > rect.size.width + 0.5)
                fprintf(stderr, "cut fit width=%.1f row=%lu col=%lu text=%s measured=%.2f rect=%s\n",
                    controller.view.bounds.size.width, (unsigned long)index, (unsigned long)column,
                    values[column].UTF8String, text.width, NSStringFromRect(rect).UTF8String);
            check(!NSIsEmptyRect(rect) && NSContainsRect(NSInsetRect(row.bounds, -0.5, -0.5), rect) &&
                  text.width <= rect.size.width + 0.5 && text.height <= rect.size.height + 1,
                  @"The actual drawing column fits the entire start, end, or long duration value without ellipsis or clipping");
            check(column == 0 ? NSMinX(rect) >= 24 : NSMaxX(previous) <= NSMinX(rect),
                  @"Timing columns do not overlap each other or the native checkbox");
            check([row textAlignmentForColumn:column] == (column < 2 ? NSTextAlignmentLeft : NSTextAlignmentRight),
                  @"Start and End draw beside their leading anchors while Duration draws against the trailing edge");
            if (column == 0) check(NSMinX(rect) >= 24 && NSMinX(rect) <= 30 && rect.size.width <= 110.5,
                  @"The Start value stays close to its checkbox instead of drifting across a wide row");
            else if (column == 1) check(NSMinX(rect) - NSMaxX(previous) <= 8.5 && rect.size.width <= 110.5,
                  @"End follows Start with a compact gutter and bounded width");
            else check(rect.size.width <= 140.5 && NSMaxX(row.bounds) - NSMaxX(rect) <= 8.5,
                  @"Duration stays bounded and aligned to the row's trailing edge");
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
    NSMutableArray<NSTextField *> *headingLabels = [NSMutableArray new];
    for (NSView *view in controller.cutColumnHeader.arrangedSubviews)
        if ([view isKindOfClass:NSTextField.class]) [headingLabels addObject:(NSTextField *)view];
    check(headingLabels.count == 3,
          @"Start, End, and Duration have separate column headings");
    NSArray *headings = @[@"Start", @"End", @"Duration"];
    if (getenv("SILENT_SNIP_CONTROLLER_LAYOUT_DEBUG")) fprintf(stderr,
        "cut header frame=%s bounds=%s constant=%.2f panel=%s\n",
        NSStringFromRect(controller.cutColumnHeader.frame).UTF8String,
        NSStringFromRect(controller.cutColumnHeader.bounds).UTF8String,
        controller.cutColumnHeaderWidthConstraint.constant, NSStringFromRect(controller.reviewPanel.bounds).UTF8String);
    for (NSUInteger column = 0; column < 3; ++column) {
        NSTextField *heading = headingLabels[column];
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
        CGFloat headingEdge = column < 2 ? NSMinX(headingRect) : NSMaxX(headingRect);
        CGFloat valueEdge = column < 2 ? NSMinX(valueRect) : NSMaxX(valueRect);
        check([heading.stringValue isEqual:headings[column]] && headingSize.width <= headingRect.size.width &&
              fabs(headingEdge - valueEdge) <= 1,
              @"Each visible heading aligns with the values in its timing column");
    }
    BOOL overflows = controller.cutList.frame.size.height > controller.reviewScroll.contentView.bounds.size.height + 0.5;
    if (controller.view.bounds.size.height <= [controller preferredMinimumSize].height + 0.5)
        check(overflows, @"Eighteen rows exercise actual timestamp-list scrolling in the supported short window");
    NSRect bodyBeforeScroll = frameInRoot(controller.bodyView, controller);
    NSRect settingsBeforeScroll = frameInRoot(controller.settingsPanel, controller);
    NSRect headerBeforeScroll = frameInRoot(controller.headerView, controller);
    NSRect footerBeforeScroll = frameInRoot(controller.footerView, controller);
    NSRect columnsBeforeScroll = frameInRoot(controller.cutColumnHeader, controller);
    NSRect contentBeforeScroll = controller.content.frame;
    SSWorkflowCutRow *last = (SSWorkflowCutRow *)controller.cutList.arrangedSubviews.lastObject;
    NSRect lastRect = [last convertRect:last.bounds toView:controller.cutList];
    [last scrollRectToVisible:last.bounds];
    [controller.reviewScroll reflectScrolledClipView:controller.reviewScroll.contentView];
    check(NSContainsRect(NSInsetRect(controller.reviewScroll.contentView.documentVisibleRect, -0.5, -0.5), lastRect),
          @"The final long-duration range remains fully reachable within the timestamp viewport");
    check(NSEqualRects(frameInRoot(controller.bodyView, controller), bodyBeforeScroll) &&
          NSEqualRects(frameInRoot(controller.settingsPanel, controller), settingsBeforeScroll) &&
          NSEqualRects(frameInRoot(controller.headerView, controller), headerBeforeScroll) &&
          NSEqualRects(frameInRoot(controller.footerView, controller), footerBeforeScroll) &&
          NSEqualRects(frameInRoot(controller.cutColumnHeader, controller), columnsBeforeScroll) &&
          NSEqualRects(controller.content.frame, contentBeforeScroll),
          @"Scrolling to the last timestamp moves no body, settings, heading, footer or review-column control");
    [controller.reviewScroll.contentView scrollToPoint:NSZeroPoint];
    [controller.reviewScroll reflectScrolledClipView:controller.reviewScroll.contentView];
    checkOnlyTimestampScrolls(controller);
    checkStickyChrome(controller);
}

static void invalidateOffscreenDisplaySubtree(NSView *view) {
    view.needsLayout = YES;
    view.needsDisplay = YES;
    [view.layer setNeedsDisplay];
    for (NSView *child in view.subviews) invalidateOffscreenDisplaySubtree(child);
}

static void displayOffscreenLayerSubtree(NSView *view) {
    for (NSView *child in view.subviews) displayOffscreenLayerSubtree(child);
    // Layer-backed views can otherwise retain a prior state's empty backing
    // store in a windowless cacheDisplay render. Refresh native drawing only;
    // no windows, run-loop events, or synthesized input are introduced.
    // Some AppKit image/label views advertise updateLayer without owning a
    // backing layer in this windowless fixture. Their native display path
    // must decide how to draw them; updateLayer requires an actual layer.
    if (view.wantsLayer && view.layer != nil && view.wantsUpdateLayer) [view updateLayer];
    [view displayIfNeeded];
    [view.layer displayIfNeeded];
}

static void renderSyntheticRegionWithAppearanceIfRequested(SSWorkflowViewController *controller, NSString *name,
                                                            NSAppearanceName appearanceName, NSRect region) {
    if (!getenv("SILENT_SNIP_CONTROLLER_LAYOUT_RENDER")) return;
    const char *requestedDirectory = getenv("SILENT_SNIP_CONTROLLER_LAYOUT_RENDER_OUTPUT");
    NSString *directory = requestedDirectory ? [NSString stringWithUTF8String:requestedDirectory] :
        [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@"build/WorkflowPrototype/Window21"];
    NSError *error;
    check([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error],
          @"The optional synthetic layout-render directory is writable");
    check([directory.stringByResolvingSymlinksInPath isEqual:directory.stringByStandardizingPath],
          @"Optional layout render output does not traverse a symlink");
    NSAppearance *previousAppearance = controller.view.appearance;
    NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName];
    check(appearance != nil, @"The optional layout render has an explicit supported native appearance");
    [controller.view setAppearance:appearance];
    [appearance performAsCurrentDrawingAppearance:^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        invalidateOffscreenDisplaySubtree(controller.view);
        [controller.view layoutSubtreeIfNeeded];
        displayOffscreenLayerSubtree(controller.view);
        [CATransaction commit];
        [CATransaction flush];
    }];
    region = NSIntegralRect(region);
    check(!NSIsEmptyRect(region) && NSContainsRect(NSInsetRect(controller.view.bounds, -0.5, -0.5), region),
          @"The optional native render covers only the requested visible UI region");
    NSBitmapImageRep *bitmap = [controller.view bitmapImageRepForCachingDisplayInRect:region];
    check(bitmap != nil, @"The offscreen view can create an optional bitmap without a window");
    CGFloat scaleX = bitmap.pixelsWide / region.size.width, scaleY = bitmap.pixelsHigh / region.size.height;
    CGFloat scale = round(scaleX);
    check(scale >= 1 && scale <= 4 && fabs(scaleX - scale) < 0.005 && fabs(scaleY - scale) < 0.005 &&
          bitmap.pixelsWide == llround(region.size.width * scale) &&
          bitmap.pixelsHigh == llround(region.size.height * scale),
          @"The rendered bitmap dimensions match the requested UI point dimensions at one native backing scale");
    [appearance performAsCurrentDrawingAppearance:^{
        [controller.view cacheDisplayInRect:region toBitmapImageRep:bitmap];
    }];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSBitmapImageRep *decoded = [NSBitmapImageRep imageRepWithData:png];
    check(decoded.pixelsWide == bitmap.pixelsWide && decoded.pixelsHigh == bitmap.pixelsHigh,
          @"The saved PNG preserves the checked native bitmap dimensions");
    NSString *path = [directory stringByAppendingPathComponent:name];
    check(png.length > 0 && [png writeToFile:path atomically:YES],
          @"The optional synthetic layout screenshot is saved");
    fprintf(stdout, "Synthetic layout render: %s (%.0fx%.0f pt, %ldx%ld px, %.0fx)\n", path.UTF8String,
        region.size.width, region.size.height, (long)bitmap.pixelsWide, (long)bitmap.pixelsHigh, scale);
    controller.view.appearance = previousAppearance;
}

static void renderSyntheticLayoutWithAppearanceIfRequested(SSWorkflowViewController *controller, NSString *name,
                                                            NSAppearanceName appearanceName) {
    renderSyntheticRegionWithAppearanceIfRequested(controller, name, appearanceName, controller.view.bounds);
}

static void renderSyntheticLayoutIfRequested(SSWorkflowViewController *controller, NSString *name) {
    renderSyntheticLayoutWithAppearanceIfRequested(controller, name, NSAppearanceNameDarkAqua);
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
    CGFloat cappedCardWidth = 0;
    NSRect cappedColumns[3];
    for (NSNumber *width in @[@460, @480, @529, @530, @560, @840]) {
        [parent setFrameSize:NSMakeSize(width.doubleValue, 540)];
        settleOffscreenLayout(parent, controller);
        checkBodyWidth(controller);
        checkNumericGroupArrangement(controller);
        checkStructuredCutRows(controller, response[@"cuts"]);
        SSWorkflowCutRow *first = (SSWorkflowCutRow *)controller.cutList.arrangedSubviews.firstObject;
        if (width.integerValue == 560) {
            cappedCardWidth = controller.reviewPanel.frame.size.width;
            for (NSUInteger column = 0; column < 3; ++column) cappedColumns[column] = [first columnRectForIndex:column];
        }
        if (width.integerValue == 840) {
            check(cappedCardWidth > 0 && fabs(controller.reviewPanel.frame.size.width - cappedCardWidth) < 0.5,
                  @"An 840-point host does not widen the review beyond its width at the 560-point cap");
            for (NSUInteger column = 0; column < 3; ++column)
                check(NSEqualRects([first columnRectForIndex:column], cappedColumns[column]),
                      @"Extra host width cannot spread the timing values farther apart after the column reaches its cap");
            checkBodyControlVisible(controller.reviewScroll, controller);
        }
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

static NSArray<NSValue *> *fixedPaneGeometry(SSWorkflowViewController *controller) {
    return @[[NSValue valueWithRect:frameInRoot(controller.contentColumn, controller)],
        [NSValue valueWithRect:frameInRoot(controller.headerView, controller)],
        [NSValue valueWithRect:frameInRoot(controller.footerView, controller)],
        [NSValue valueWithRect:frameInRoot(controller.bodyView, controller)],
        [NSValue valueWithRect:[controller.reviewPanel convertRect:controller.reviewPanel.bounds toView:controller.content]],
        [NSValue valueWithRect:[controller.reviewScroll convertRect:controller.reviewScroll.bounds toView:controller.content]],
        [NSValue valueWithRect:[controller.cutColumnHeader convertRect:controller.cutColumnHeader.bounds toView:controller.content]]];
}

static void checkFixedCutPane(SSWorkflowViewController *controller, NSView *parent,
                             NSUInteger rows, NSArray<NSValue *> *baseline) {
    check(nearlyEqualSize(controller.view.frame.size, parent.bounds.size),
          @"Changing cut counts leaves the complete frame-driven controller root owned by its host");
    check(!controller.reviewScroll.hidden && !controller.cutColumnHeader.hidden &&
          !controller.allButton.hidden && !controller.noneButton.hidden && controller.cutList.arrangedSubviews.count == rows,
          @"The predetermined table, column headings, and selection controls remain visible for zero, one, or many cuts");
    check(controller.reviewScroll.frame.size.height >= 79.5 &&
          controller.reviewScroll.contentView.bounds.size.height >= 77.5,
          @"The timestamp viewport retains its minimum usable height while adapting to its host");
    check(fabs(controller.reviewSummary.frame.size.height - 34) < 0.5,
          @"The reserved two-line review summary cannot move the predetermined table when a result arrives");
    check(!controller.reviewScroll.hasHorizontalScroller &&
          fabs(controller.cutList.frame.size.width - controller.reviewScroll.contentView.bounds.size.width) < 0.5 &&
          fabs(controller.cutColumnHeader.frame.size.width - controller.reviewScroll.contentView.bounds.size.width) < 0.5,
          @"The empty or populated table document and headings track its actual viewport width");
    check(controller.content.frame.size.height <= controller.bodyView.bounds.size.height + 0.5,
          @"The complete content fits the plain body without creating an outer scroll document");
    if (rows == 0) check(!controller.allButton.enabled && !controller.noneButton.enabled && !controller.applyButton.enabled,
          @"Keeping an empty table visible cannot enable selection commands or Apply");
    if (baseline) {
        NSArray<NSValue *> *geometry = fixedPaneGeometry(controller);
        for (NSUInteger index = 0; index < geometry.count; ++index) {
            NSRect actual = geometry[index].rectValue, expected = baseline[index].rectValue;
            BOOL same = NSEqualRects(actual, expected);
            if (index == geometry.count - 1) same = fabs(actual.origin.x - expected.origin.x) < 0.5 &&
                fabs(actual.origin.y - expected.origin.y) < 0.5 && fabs(actual.size.height - expected.size.height) < 0.5;
            check(same, @"Zero, one, and eighteen rows keep the outer frame, table position, toolbar, and footer geometry stable");
        }
    }
    checkBodyWidth(controller);
    checkOnlyTimestampScrolls(controller);
    checkNumericGroupArrangement(controller);
    checkStickyChrome(controller);
}

static void fixedCutPaneStaysStableAsRowsChange(void) {
    for (NSValue *hostSize in @[[NSValue valueWithSize:NSMakeSize(460, 540)],
                              [NSValue valueWithSize:NSMakeSize(615, 704)],
                              [NSValue valueWithSize:NSMakeSize(840, 798)]]) {
        SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Synthetic fixed-pane fixture"));
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
        [parent addSubview:controller.view];
        settleOffscreenLayout(parent, controller);
        [parent setFrameSize:hostSize.sizeValue];
        settleOffscreenLayout(parent, controller);
        fprintf(stdout, "Adaptive pane fixture %.0fx%.0f: content %.0f / body %.0f, timestamps %.0f\n",
            parent.bounds.size.width, parent.bounds.size.height, controller.content.frame.size.height,
            controller.bodyView.bounds.size.height, controller.reviewScroll.frame.size.height);
        checkFixedCutPane(controller, parent, 0, nil);
        NSArray<NSValue *> *baseline = fixedPaneGeometry(controller);
        renderSyntheticLayoutIfRequested(controller, [NSString stringWithFormat:@"Synthetic-0Cuts-%.0fx%.0f.png",
            parent.bounds.size.width, parent.bounds.size.height]);

        SSFakeWorkflowReviewClient *client = beginReview(controller);
        NSUInteger generation = controller.reviewGeneration;
        NSUInteger contextGeneration = controller.contextGeneration;
        NSDictionary *eighteen = syntheticEighteenCutReview();
        NSMutableDictionary *one = [eighteen mutableCopy];
        one[@"cuts"] = @[eighteen[@"cuts"][0]];
        one[@"summary"] = @"1 selected · 1 detected range";
        [client deliver:one busy:NO canApply:YES];
        settleOffscreenLayout(parent, controller);
        checkFixedCutPane(controller, parent, 1, baseline);
        NSButton *onlyRow = (NSButton *)controller.cutList.arrangedSubviews.firstObject;
        NSRect onlyRect = [onlyRow convertRect:onlyRow.bounds toView:controller.cutList];
        check(NSContainsRect(NSInsetRect(controller.reviewScroll.contentView.documentVisibleRect, -0.5, -0.5), onlyRect),
              @"A single cut remains fully visible inside the fixed area without resizing that area");

        [client deliver:eighteen busy:NO canApply:YES];
        settleOffscreenLayout(parent, controller);
        checkFixedCutPane(controller, parent, 18, baseline);
        checkStructuredCutRows(controller, eighteen[@"cuts"]);
        renderSyntheticLayoutIfRequested(controller, [NSString stringWithFormat:@"Synthetic-18Cuts-%.0fx%.0f.png",
            parent.bounds.size.width, parent.bounds.size.height]);

        NSMutableDictionary *none = [eighteen mutableCopy];
        none[@"cuts"] = @[];
        none[@"summary"] = @"No cut ranges detected";
        [client deliver:none busy:NO canApply:NO];
        settleOffscreenLayout(parent, controller);
        checkFixedCutPane(controller, parent, 0, baseline);
        check(controller.reviewClient == client && controller.reviewGeneration == generation &&
              controller.contextGeneration == contextGeneration && client.startCount == 1 && client.applyCommandCount == 0 &&
              client.applyGestures.count == 0 && client.retryCount == 0 && client.cancelCount == 0 &&
              controller.settings.loads.count == 1 && controller.settings.saves.count == 0,
              @"Fixed-frame layout and row-count changes cannot dispatch work or rebind project settings");
        [controller.view removeFromSuperview];
        closeController(controller);
    }
    groupCount += 1;
}

static NSString *longInformationalStatus(void) {
    return @"Analysis complete. Review the proposed ranges, then click Apply Cuts. "
        "Analyzed Final Cut Pro’s rendered audio, including clip volume and enabled audio effects. "
        "Threshold uses 10 ms average loudness (RMS), not peak meters. "
        "Apply cuts the source clips in a cleaned project copy and keeps their audio effects editable. "
        "Quiet breaths may qualify; this detector does not classify breaths.";
}

static NSString *legacyLongInformationalStatus(void) {
    return @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts. "
        "Analyzed Final Cut’s rendered audio, including clip volume and enabled effects. "
        "Threshold uses 10 ms average loudness (RMS), not peak meters. "
        "Apply creates a cleaned project copy with the retained processed sound preserved. "
        "The original project keeps its editable effects. "
        "Quiet breaths may qualify; this detector does not classify breaths.";
}

static void informationalCopyKeepsReviewAuthorityUnchanged(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = longInformationalStatus();
    [client deliver:reviewResponse(@"review", message) busy:NO canApply:YES];
    NSUInteger generation = controller.reviewGeneration;
    NSUInteger loads = controller.settings.loads.count;
    NSString *nativeMarker = controller.cancelButton.accessibilityIdentifier;
    check(controller.statusLabel.stringValue.length == 0 && [controller.statusLabel.toolTip isEqual:message],
          @"Canonical review boilerplate leaves no visible status copy while its raw message remains available as a tooltip");
    check(!controller.detailsExpanded && controller.statusDetails.hidden && controller.detailsButton.hidden,
          @"Routine informational boilerplate does not expose an unnecessary Details control");
    [controller toggleDetails:controller.detailsButton];
    [controller toggleDetails:controller.detailsButton];
    check(!controller.detailsExpanded && controller.statusDetails.hidden,
          @"A hidden informational disclosure cannot reveal stale expanded content");
    NSString *legacyMessage = legacyLongInformationalStatus();
    [client deliver:reviewResponse(@"review", legacyMessage) busy:NO canApply:YES];
    check(controller.statusLabel.stringValue.length == 0 && [controller.statusLabel.toolTip isEqual:legacyMessage] &&
          controller.statusDetails.hidden && controller.detailsButton.hidden,
          @"Known legacy worker wording stays compact while preserving the full original message");
    NSString *warning = @"Temporary isolation cleanup needs attention. Remove the temporary project manually.";
    NSString *withWarning = [message stringByAppendingFormat:@" %@", warning];
    [client deliver:reviewResponse(@"review", withWarning) busy:NO canApply:YES];
    check([controller.statusLabel.stringValue containsString:@"cleanup"] && [controller.statusLabel.toolTip isEqual:withWarning],
          @"Removing routine explanation cannot hide an actionable cleanup warning or discard its original message");
    NSString *legacyWithWarning = [legacyMessage stringByAppendingFormat:@" %@", warning];
    [client deliver:reviewResponse(@"review", legacyWithWarning) busy:NO canApply:YES];
    check([controller.statusLabel.stringValue containsString:@"cleanup"] &&
          [controller.statusLabel.toolTip isEqual:legacyWithWarning],
          @"Known legacy wording cannot hide an appended actionable warning");
    check(controller.reviewClient == client && controller.reviewGeneration == generation &&
          controller.applyButton.enabled && client.canApply && client.startCount == 1 &&
          client.applyCommandCount == 0 && client.applyGestures.count == 0 && client.retryCount == 0 &&
          controller.settings.loads.count == loads && controller.settings.saves.count == 0 &&
          [controller.cancelButton.accessibilityIdentifier isEqual:nativeMarker],
          @"Compacting informational copy and presenting a warning cannot alter review authority, dispatch work, or save settings");
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
    NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 460, 540)];
    [parent addSubview:controller.view];
    settleOffscreenLayout(parent, controller);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = @"The cleaned project was imported, but verification could not finish. "
        "Return to the intended project in Final Cut Pro and choose Retry Verification. "
        "This retry checks the existing imported result and its saved media evidence. "
        "Keep the original source and processed audio files available until verification completes. "
        "Do not create another result to resolve this pending verification.";
    NSMutableDictionary *response = [reviewResponse(@"failed", message) mutableCopy];
    response[@"canRetryVerification"] = @YES;
    [client deliver:response busy:NO canApply:NO];
    settleOffscreenLayout(parent, controller);
    check(controller.detailsExpanded && !controller.statusDetails.hidden &&
          [controller.statusDetails.stringValue isEqual:message] && [controller.statusDetails.toolTip isEqual:message],
          @"Long recovery instructions open a bounded disclosure while preserving their complete value and tooltip");
    NSTextField *details = controller.statusDetails;
    CGFloat lineHeight = ceil(details.font.ascender - details.font.descender + details.font.leading);
    check(details.maximumNumberOfLines == 3 && details.lineBreakMode == NSLineBreakByTruncatingTail &&
          details.selectable && details.frame.size.height > 0 && details.frame.size.height <= lineHeight * 3 + 8,
          @"Recovery details occupy at most three visible lines while their complete message remains selectable");
    checkBodyWidth(controller);
    checkOnlyTimestampScrolls(controller);
    checkBodyControlVisible(details, controller);
    for (NSTextField *field in controller.fields) checkBodyControlVisible(field, controller);
    checkBodyControlVisible(controller.output, controller);
    checkBodyControlVisible(controller.saveButton, controller);
    NSRect header = frameInRoot(controller.headerView, controller);
    NSRect footer = frameInRoot(controller.footerView, controller);
    NSRect settings = frameInRoot(controller.settingsPanel, controller);
    CGFloat expandedListHeight = controller.reviewScroll.frame.size.height;
    check(!controller.retryButton.hidden && controller.retryButton.enabled && !controller.applyButton.enabled &&
          !controller.analyzeButton.enabled && !controller.fields[0].enabled && controller.reviewClient == client,
          @"Expanded recovery retains the existing result and exposes Retry without permitting a new Analyze or Apply");
    [controller toggleDetails:controller.detailsButton];
    settleOffscreenLayout(parent, controller);
    check(controller.statusDetails.hidden && controller.reviewScroll.frame.size.height > expandedListHeight + 10 &&
          NSEqualRects(frameInRoot(controller.headerView, controller), header) &&
          NSEqualRects(frameInRoot(controller.footerView, controller), footer) &&
          NSEqualRects(frameInRoot(controller.settingsPanel, controller), settings),
          @"Collapsing Details returns space to the timestamp viewport without moving the header, settings or actions");
    checkOnlyTimestampScrolls(controller);
    check(controller.retryButton.enabled && !controller.applyButton.enabled && !controller.analyzeButton.enabled &&
          !controller.fields[0].enabled && client.startCount == 1 && client.applyCommandCount == 0 && client.retryCount == 0 &&
          controller.settings.saves.count == 0,
          @"Collapsing recovery details cannot bypass retained-result recovery or dispatch a command");
    [controller toggleDetails:controller.detailsButton];
    settleOffscreenLayout(parent, controller);
    check(!controller.statusDetails.hidden && [controller.statusDetails.stringValue isEqual:message] &&
          [controller.statusDetails.toolTip isEqual:message] &&
          fabs(controller.reviewScroll.frame.size.height - expandedListHeight) < 0.5,
          @"The same complete recovery instructions remain available after disclosure changes");
    checkOnlyTimestampScrolls(controller);
    [controller.view removeFromSuperview];
    closeController(controller);
    groupCount += 1;
}

static void longCancellationDetailsDoNotSuggestApply(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSFakeWorkflowReviewClient *client = beginReview(controller);
    NSString *message = @"Analysis was canceled before a cut review became available. The original project remains unchanged. "
        "Return to the intended project, select the clip in the timeline, then click Analyze Again. "
        "Any temporary analysis work has stopped, and this canceled request does not provide cuts that can be applied.";
    [client deliver:reviewResponse(@"cancelled", message) busy:NO canApply:NO];
    check(message.length > 180 && [controller.statusLabel.stringValue isEqual:@"Canceled. Review the details."],
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
    [client deliver:reviewResponse(@"cancelled", @"Analysis canceled.") busy:NO canApply:NO];
    check([controller.statusLabel.stringValue isEqual:@"Analysis canceled."] && controller.detailsButton.hidden &&
          controller.statusDetails.hidden && [controller.statusDetails.stringValue isEqual:@"Analysis canceled."],
          @"A later short cancellation stays exact and clears the earlier long explanation");
    [client deliver:reviewResponse(@"cancelled", @"Analysis cancelled.") busy:NO canApply:NO];
    check([controller.statusLabel.stringValue isEqual:@"Analysis cancelled."] &&
          [controller.statusLabel.toolTip isEqual:@"Analysis cancelled."],
          @"A legacy worker's short cancellation keeps its original diagnostic wording");
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
    check([controller.statusLabel.stringValue isEqual:@"Unable to complete the operation. Review the details."],
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

static NSTextField *labelWithTextInSubtree(NSView *view, NSString *text) {
    if ([view isKindOfClass:NSTextField.class] && [((NSTextField *)view).stringValue isEqual:text])
        return (NSTextField *)view;
    for (NSView *child in view.subviews) {
        NSTextField *result = labelWithTextInSubtree(child, text);
        if (result) return result;
    }
    return nil;
}

static CGFloat weightOfFont(NSFont *font) {
    NSDictionary *traits = [font.fontDescriptor objectForKey:NSFontTraitsAttribute];
    return [traits[NSFontWeightTrait] doubleValue];
}

static CGFloat linearColorComponent(CGFloat value) {
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static CGFloat contrastOfTextOnSurface(NSColor *textColor, NSView *surface, NSAppearance *appearance) {
    __block NSColor *foreground = nil, *background = nil;
    [appearance performAsCurrentDrawingAppearance:^{
        [surface updateLayer];
        foreground = [textColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        if (surface.layer.backgroundColor)
            background = [[NSColor colorWithCGColor:surface.layer.backgroundColor]
                colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    }];
    if (!foreground || !background) return 0;
    CGFloat fr, fg, fb, fa, br, bg, bb, ba;
    [foreground getRed:&fr green:&fg blue:&fb alpha:&fa];
    [background getRed:&br green:&bg blue:&bb alpha:&ba];
    if (ba < 0.999) return 0;
    fr = fr * fa + br * (1 - fa); fg = fg * fa + bg * (1 - fa); fb = fb * fa + bb * (1 - fa);
    CGFloat front = 0.2126 * linearColorComponent(fr) + 0.7152 * linearColorComponent(fg) + 0.0722 * linearColorComponent(fb);
    CGFloat back = 0.2126 * linearColorComponent(br) + 0.7152 * linearColorComponent(bg) + 0.0722 * linearColorComponent(bb);
    return (fmax(front, back) + 0.05) / (fmin(front, back) + 0.05);
}

static void checkNoImplicitReturnAction(SSWorkflowViewController *controller) {
    for (NSButton *button in @[controller.analyzeButton, controller.applyButton, controller.retryButton])
        check(![button.keyEquivalent isEqual:@"\r"] && ![button.keyEquivalent isEqual:@"\n"],
              @"Emphasizing an action cannot bind Return in a detection field to Analyze, Apply, or Retry");
}

static void checkReviewTextHierarchy(SSWorkflowViewController *controller, NSDictionary *response,
                                    NSAppearance *appearance) {
    NSString *expected = [NSString stringWithFormat:@"Clip: %@\n%@", response[@"targetClipName"], response[@"summary"]];
    NSAttributedString *styled = controller.reviewSummary.attributedStringValue;
    id accessibleValue = controller.reviewSummary.accessibilityValue;
    if ([accessibleValue isKindOfClass:NSAttributedString.class]) accessibleValue = [accessibleValue string];
    check([controller.reviewSummary.stringValue isEqual:expected] && [styled.string isEqual:expected] &&
          [controller.reviewSummary.toolTip isEqual:expected] && [accessibleValue isEqual:expected] &&
          [controller.reviewSummary.accessibilityIdentifier isEqual:@"silentsnip.workflow.summary"],
          @"The styled review preserves every original character for display, accessibility, copying, and tooltip reading");
    NSRange clip = [expected rangeOfString:response[@"targetClipName"]];
    NSRange metrics = [expected rangeOfString:response[@"summary"]];
    NSRange removed = [expected rangeOfString:@"15.400"];
    NSRange result = [expected rangeOfString:@"44.600"];
    check(clip.location != NSNotFound && metrics.location != NSNotFound && removed.location != NSNotFound && result.location != NSNotFound,
          @"The hierarchy fixture contains a clip identity, selected-cut count, and resulting duration");
    NSFont *prefixFont = [styled attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
    NSFont *clipFont = [styled attribute:NSFontAttributeName atIndex:clip.location effectiveRange:NULL];
    NSFont *countFont = [styled attribute:NSFontAttributeName atIndex:metrics.location effectiveRange:NULL];
    NSFont *bodyFont = [styled attribute:NSFontAttributeName atIndex:removed.location effectiveRange:NULL];
    NSFont *resultFont = [styled attribute:NSFontAttributeName atIndex:result.location effectiveRange:NULL];
    check(prefixFont && clipFont && bodyFont && countFont && resultFont &&
          clipFont.pointSize > prefixFont.pointSize && clipFont.pointSize > bodyFont.pointSize &&
          weightOfFont(clipFont) > weightOfFont(bodyFont) &&
          weightOfFont(countFont) > weightOfFont(bodyFont) && weightOfFont(resultFont) > weightOfFont(bodyFont),
          @"Clip identity, selected-count and resulting duration stand out from contextual labels and metric prose");
    NSSize ones = [@"111111" sizeWithAttributes:@{NSFontAttributeName: bodyFont}];
    NSSize eights = [@"888888" sizeWithAttributes:@{NSFontAttributeName: bodyFont}];
    check(fabs(ones.width - eights.width) < 0.1,
          @"Changing numeric totals keeps digit widths stable instead of moving the review metrics");
    NSTextField *settingName = labelWithTextInSubtree(controller.settingsPanel, @"Silence Threshold");
    NSTextField *sectionName = labelWithTextInSubtree(controller.reviewPanel, @"Cut Review");
    check(settingName && sectionName && controller.projectLabel.font.pointSize > controller.playheadLabel.font.pointSize &&
          sectionName.font.pointSize > settingName.font.pointSize &&
          controller.fields[0].font.pointSize > settingName.font.pointSize,
          @"Project and section headings, editable values, and descriptive labels have visibly different type roles");
    check(contrastOfTextOnSurface(settingName.textColor, controller.settingsPanel, appearance) >= 4.5,
          @"Small secondary setting labels retain readable contrast against their actual section surface");
    checkNoImplicitReturnAction(controller);
}

static void visualHierarchyRendersStatesWithoutChangingAuthority(void) {
    NSArray<NSValue *> *sizes = @[[NSValue valueWithSize:NSMakeSize(460, 540)],
                                 [NSValue valueWithSize:NSMakeSize(615, 704)]];
    NSArray<NSAppearanceName> *appearances = @[NSAppearanceNameDarkAqua, NSAppearanceNameAccessibilityHighContrastDarkAqua];
    for (NSValue *sizeValue in sizes) for (NSAppearanceName appearanceName in appearances) {
        NSSize size = sizeValue.sizeValue;
        NSAppearance *appearance = [NSAppearance appearanceNamed:appearanceName];
        NSString *variant = [appearanceName isEqual:NSAppearanceNameDarkAqua] ? @"Dark" : @"HighContrast";
        SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Synthetic style hierarchy"));
        SSTestWorkflowViewController *controller = openController(current);
        completeLoad(controller.settings.loads[0], values(-50, YES), nil);
        NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
        [parent addSubview:controller.view];
        controller.view.appearance = appearance;
        settleOffscreenLayout(parent, controller);
        [parent setFrameSize:size];
        settleOffscreenLayout(parent, controller);
        check(nearlyEqualSize(controller.view.bounds.size, size) && nearlyEqualSize(controller.view.frame.size, size),
              @"Each hierarchy fixture uses its named host dimensions instead of the controller's initial 480-by-640 frame");
        check(controller.analyzeButton.enabled && controller.analyzeButton.bezelColor != nil && !controller.applyButton.enabled,
              @"Idle emphasis identifies the available Analyze action without enabling Apply");
        checkNoImplicitReturnAction(controller);
        checkOnlyTimestampScrolls(controller);
        renderSyntheticLayoutWithAppearanceIfRequested(controller,
            [NSString stringWithFormat:@"Hierarchy-Idle-%@-%.0fx%.0f.png", variant, size.width, size.height], appearanceName);

        SSFakeWorkflowReviewClient *client = beginReview(controller);
        NSMutableDictionary *ready = [syntheticEighteenCutReview() mutableCopy];
        ready[@"targetClipName"] = @"Hard Magic vs Soft Magic";
        ready[@"summary"] = @"17 selected · 15.400 s removed · 60.000 s → 44.600 s";
        [client deliver:ready busy:NO canApply:YES];
        settleOffscreenLayout(parent, controller);
        NSUInteger generation = controller.reviewGeneration, contextGeneration = controller.contextGeneration;
        NSString *marker = controller.cancelButton.accessibilityIdentifier;
        checkReviewTextHierarchy(controller, ready, appearance);
        check(controller.applyButton.enabled && controller.applyButton.bezelColor != nil &&
              controller.analyzeButton.bezelColor == nil,
              @"A ready review emphasizes Apply while retaining a distinct secondary Analyze action");
        checkOnlyTimestampScrolls(controller);
        checkStructuredCutRows(controller, ready[@"cuts"]);
        renderSyntheticLayoutWithAppearanceIfRequested(controller,
            [NSString stringWithFormat:@"Hierarchy-Ready-%@-%.0fx%.0f.png", variant, size.width, size.height], appearanceName);
        if ([appearanceName isEqual:NSAppearanceNameDarkAqua] && nearlyEqualSize(size, NSMakeSize(615, 704))) {
            NSView *reviewHeading = controller.reviewPanel.arrangedSubviews.firstObject;
            NSRect heading = frameInRoot(reviewHeading, controller), summary = frameInRoot(controller.reviewSummary, controller);
            NSRect region = NSIntersectionRect(NSInsetRect(NSUnionRect(heading, summary), -12, -8),
                                               frameInRoot(controller.reviewPanel, controller));
            renderSyntheticRegionWithAppearanceIfRequested(controller, @"Review-Header.png", appearanceName, region);
        }

        NSMutableDictionary *provisional = [ready mutableCopy];
        provisional[@"state"] = @"analyzing"; provisional[@"provisional"] = @YES;
        provisional[@"message"] = @"Checking the rendered audio…"; provisional[@"progress"] = @0.6;
        [client deliver:provisional busy:YES canApply:NO];
        settleOffscreenLayout(parent, controller);
        check(!controller.applyButton.enabled && !controller.fields[0].enabled && controller.cancelButton.enabled,
              @"Readable provisional results remain inactive while capture is still running");
        checkNoImplicitReturnAction(controller);
        checkOnlyTimestampScrolls(controller);
        renderSyntheticLayoutWithAppearanceIfRequested(controller,
            [NSString stringWithFormat:@"Hierarchy-Provisional-%@-%.0fx%.0f.png", variant, size.width, size.height], appearanceName);

        [client deliver:ready busy:NO canApply:YES];
        client.fakeCanUpdate = YES; client.fakeUpdatingCuts = YES;
        NSMutableDictionary *updating = [ready mutableCopy];
        updating[@"message"] = @"Updating cut ranges…"; updating[@"progress"] = @0.8;
        [client deliver:updating busy:YES canApply:NO];
        settleOffscreenLayout(parent, controller);
        check(controller.fields[0].enabled && !controller.applyButton.enabled && !controller.navigateMenu.enabled,
              @"Automatic-update presentation keeps editing available while stale cuts and navigation stay inactive");
        checkNoImplicitReturnAction(controller);
        checkOnlyTimestampScrolls(controller);
        renderSyntheticLayoutWithAppearanceIfRequested(controller,
            [NSString stringWithFormat:@"Hierarchy-Updating-%@-%.0fx%.0f.png", variant, size.width, size.height], appearanceName);

        NSMutableDictionary *recovery = [ready mutableCopy];
        recovery[@"state"] = @"failed"; recovery[@"canRetryVerification"] = @YES;
        recovery[@"message"] = @"The cleaned project was imported, but verification could not finish. "
            "Return to the intended project in Final Cut Pro and choose Retry Verification. "
            "Keep the original source and processed audio files available until verification completes.";
        [client deliver:recovery busy:NO canApply:NO];
        settleOffscreenLayout(parent, controller);
        check(controller.detailsExpanded && !controller.statusDetails.hidden && !controller.retryButton.hidden &&
              controller.retryButton.enabled && controller.retryButton.bezelColor != nil &&
              !controller.analyzeButton.enabled && !controller.applyButton.enabled,
              @"Recovery emphasizes its existing verification action and complete bounded explanation without permitting another edit");
        check(contrastOfTextOnSurface(controller.statusLabel.textColor, controller.footerView, appearance) >= 4.5,
              @"Recovery guidance remains readable against the footer in standard and high-contrast appearances");
        checkNoImplicitReturnAction(controller);
        checkOnlyTimestampScrolls(controller);
        renderSyntheticLayoutWithAppearanceIfRequested(controller,
            [NSString stringWithFormat:@"Hierarchy-Recovery-%@-%.0fx%.0f.png", variant, size.width, size.height], appearanceName);

        [client deliver:ready busy:NO canApply:YES];
        settleOffscreenLayout(parent, controller);
        checkReviewTextHierarchy(controller, ready, appearance);
        check(controller.reviewClient == client && controller.reviewGeneration == generation &&
              controller.contextGeneration == contextGeneration && [controller.cancelButton.accessibilityIdentifier isEqual:marker] &&
              client.startCount == 1 && client.applyCommandCount == 0 && client.applyGestures.count == 0 &&
              client.retryCount == 0 && client.cancelCount == 0 && client.automaticUpdatePayloads.count == 0 &&
              controller.settings.loads.count == 1 && controller.settings.saves.count == 0,
              @"Changing visual state and native appearance preserves authority without launching, applying, retrying, canceling, or saving work");
        [controller.view removeFromSuperview];
        closeController(controller);
    }
    groupCount += 1;
}

static SSWorkflowPointerObservation *ownedPointerObservation(void) {
    SSWorkflowPointerObservation *observation = [SSWorkflowPointerObservation new];
    observation.hostForeground = YES;
    observation.visibleRoot = YES;
    observation.pointerInside = YES;
    observation.ownedHit = YES;
    observation.eventMatchesWindow = YES;
    observation.topmostMatchesWindow = YES;
    observation.windowNumber = 41;
    observation.windowAtPoint = 41;
    // The regression occurs while Final Cut's main window is key and the
    // extension's process/window is inactive. Those facts must not veto it.
    observation.keyWindow = NO;
    observation.applicationActive = NO;
    return observation;
}

static void runPointerRefreshes(SSTestWorkflowContentView *view) {
    NSArray<dispatch_block_t> *ready = view.pointerCompletions.copy;
    [view.pointerCompletions removeAllObjects];
    for (dispatch_block_t refresh in ready) refresh();
}

static void cursorSurvivesWholeReviewFlowWithoutNewCommands(void) {
    SSHost *current = host(sequence(@"project-A", @"/Test/Library-A.fcpbundle", @"Disposable A"));
    SSTestWorkflowViewController *controller = openController(current);
    completeLoad(controller.settings.loads[0], values(-50, YES), nil);
    SSTestWorkflowContentView *view = (SSTestWorkflowContentView *)controller.view;
    runPointerRefreshes(view);
    view.testObservation = ownedPointerObservation();
    view.testCurrentCursor = view.testSystemArrow;
    [controller analyzeAudio:controller.analyzeButton];
    SSFakeWorkflowReviewClient *client = controller.reviewClients.lastObject;
    check(!controller.fields[0].enabled && view.pointerCompletions.count == 1,
          @"Analyze's actual control disablement coalesces a cursor refresh");
    runPointerRefreshes(view);
    check(view.recordingCursor.setCount == 1,
          @"The sharp default returns with Final Cut foreground even when the extension loses key and app activation");

    NSArray<NSString *> *states = @[@"capturing", @"analyzing", @"review", @"recalculating",
        @"applying", @"verifying", @"completed", @"cancelled", @"failed"];
    for (NSString *state in states) {
        BOOL ready = [state isEqual:@"review"];
        BOOL terminal = [@[@"completed", @"cancelled", @"failed"] containsObject:state];
        NSUInteger previous = view.recordingCursor.setCount;
        view.testCurrentCursor = view.testSystemArrow;
        [client deliver:reviewResponse(state, @"Fixture state") busy:!ready && !terminal canApply:ready];
        check(view.pointerCompletions.count == 1,
              [NSString stringWithFormat:@"The %@ response queues one refresh even when enabled bits are unchanged", state]);
        runPointerRefreshes(view);
        check(view.recordingCursor.setCount == previous + 1,
              [NSString stringWithFormat:@"A default-arrow reset is repaired through %@", state]);
    }
    view.testCurrentCursor = view.testSystemArrow;
    NSUInteger previous = view.recordingCursor.setCount;
    [controller setControlsEnabled:NO];
    [controller setControlsEnabled:YES];
    runPointerRefreshes(view);
    check(view.recordingCursor.setCount == previous + 1,
          @"Reconnect-style disable and enable transitions share the cursor repair path");
    check(client.startCount == 1 && client.applyGestures.count == 0 && client.retryCount == 0 && client.cancelCount == 0,
          @"Pointer state changes do not start, apply, verify, retry, or cancel project work");
    closeController(controller);
    groupCount += 1;
}

static void cursorRepairRejectsForeignUnknownAndSpecializedContexts(void) {
    SSTestWorkflowContentView *view = [[SSTestWorkflowContentView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    NSEvent *localEventToken = (NSEvent *)[NSObject new];
    for (NSString *guard in @[@"hostForeground", @"visibleRoot", @"pointerInside", @"ownedHit", @"eventMatchesWindow"]) {
        view.testObservation = ownedPointerObservation();
        [view.testObservation setValue:@NO forKey:guard];
        [view mouseMoved:localEventToken];
        [view cursorUpdate:localEventToken];
        check(view.recordingCursor.setCount == 0,
              [NSString stringWithFormat:@"Missing %@ cannot replace a cursor from a queued local event", guard]);
    }
    view.testObservation = ownedPointerObservation();
    view.testObservation.pressedButtons = 1;
    [view mouseMoved:localEventToken];
    view.testObservation.pressedButtons = 0;
    view.testObservation.editableText = YES;
    [view mouseEntered:localEventToken];
    check(view.recordingCursor.setCount == 0, @"Mouse drags and editable native text keep their cursor ownership");

    view.testObservation = ownedPointerObservation();
    for (NSString *kind in @[@"I-beam", @"resize", @"drag", @"custom", @"unknown"]) {
        view.testCurrentCursor = [kind isEqual:@"unknown"] ? nil : (NSCursor *)[NSObject new];
        [view cursorUpdate:localEventToken];
        [view mouseEntered:localEventToken];
        [view mouseMoved:localEventToken];
        [view requestDefaultCursorRefreshForPhase:@"test-special"];
        runPointerRefreshes(view);
        check(view.recordingCursor.setCount == 0,
              [NSString stringWithFormat:@"%@ is preserved through normal, mouse, and state repair paths", kind]);
    }
    view.testCurrentCursor = view.testSystemArrow;
    view.testObservation.topmostMatchesWindow = NO;
    // A genuine event still belongs to this root even when the remote view's
    // onscreen window number is unavailable; state callbacks may not assume it.
    [view mouseMoved:localEventToken];
    check(view.recordingCursor.setCount == 1, @"A genuine owned mouse event repairs the default without a fabricated window-number match");
    [view mouseMoved:localEventToken];
    check(view.recordingCursor.setCount == 1, @"The retained host arrow is not repeatedly set during ordinary pointer movement");
    groupCount += 1;
}

static void cursorStateRefreshCoalescesAndRechecksStationaryOwnership(void) {
    SSTestWorkflowContentView *view = [[SSTestWorkflowContentView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    view.testObservation = ownedPointerObservation();
    [view requestDefaultCursorRefreshForPhase:@"controls"];
    [view requestDefaultCursorRefreshForPhase:@"rows"];
    [view requestDefaultCursorRefreshForPhase:@"layout"];
    check(view.pointerCompletions.count == 1 && [view.pendingCursorRefreshPhase isEqual:@"rows"],
          @"Controls, row rebuilds, and layout share one queued refresh without losing the meaningful phase");
    view.testObservation.hostForeground = NO;
    runPointerRefreshes(view);
    check(view.recordingCursor.setCount == 0 && view.cursorRectInvalidations == 1,
          @"An app switch before the queue drains refuses an explicit cursor set while allowing AppKit-owned rectangle invalidation");
    view.testObservation = ownedPointerObservation();
    view.testObservation.topmostMatchesWindow = NO;
    view.testObservation.windowNumber = 0;
    [view requestDefaultCursorRefreshForPhase:@"window-key"];
    runPointerRefreshes(view);
    check(view.recordingCursor.setCount == 0, @"An unknown remote window ID cannot authorize a stationary cursor set");
    view.testObservation = ownedPointerObservation();
    [view requestDefaultCursorRefreshForPhase:@"window-key"];
    runPointerRefreshes(view);
    check(view.recordingCursor.setCount == 1 && !view.cursorRefreshScheduled,
          @"A fresh exact topmost-owned-window observation restores the stationary pointer once without a polling loop");
    [view resetCursorRects];
    check(view.registeredCursor == view.defaultCursor,
          @"AppKit receives the retained host arrow for the owned root's default cursor rectangle");
    groupCount += 1;
}

static void cursorTrackingAndNativeTextRemainScoped(void) {
    SSTestWorkflowContentView *view = [[SSTestWorkflowContentView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    [view updateTrackingAreas];
    NSTrackingArea *oldCursor = view.defaultCursorTrackingArea;
    NSTrackingArea *oldMouse = view.defaultMouseTrackingArea;
    [view updateTrackingAreas];
    check(![view.trackingAreas containsObject:oldCursor] && ![view.trackingAreas containsObject:oldMouse] &&
          [view.trackingAreas containsObject:view.defaultCursorTrackingArea] &&
          [view.trackingAreas containsObject:view.defaultMouseTrackingArea],
          @"Tracking rebuild replaces both owned areas without accumulating stale registrations");
    check((view.defaultCursorTrackingArea.options & NSTrackingCursorUpdate) != 0 &&
          (view.defaultCursorTrackingArea.options & NSTrackingActiveAlways) == 0 &&
          (view.defaultMouseTrackingArea.options & NSTrackingCursorUpdate) == 0 &&
          (view.defaultMouseTrackingArea.options & NSTrackingActiveAlways) != 0,
          @"Always-active mouse repair stays separate from the AppKit-supported cursor-update activation scope");
    NSTextField *field = [NSTextField textFieldWithString:@"fixture"];
    [view addSubview:field];
    NSView *fieldChild = [NSView new];
    [field addSubview:fieldChild];
    check([view editableTextAtHitView:fieldChild], @"Native editable-field ancestry is protected even when its descendant is hit");
    field.enabled = NO;
    check(![view editableTextAtHitView:fieldChild], @"A disabled field can use the host's ordinary arrow");
    NSTextView *text = [NSTextView new];
    [view addSubview:text];
    check([view editableTextAtHitView:text], @"A native text view retains editing cursor ownership");
    NSButton *button = [NSButton new];
    [view addSubview:button];
    check(![view editableTextAtHitView:button], @"Ordinary buttons remain eligible for the host's default arrow");
    groupCount += 1;
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
        windowLeaseTracksVisibleVerifiedHostWithoutProjectWork();
        analyzeDispatchPinsPayloadAndGesture();
        applyRequiresReviewAndFreshGesture();
        sdkNavigationRequiresExactProjectWindowAndReturnedTime();
        retainedUpdatesNavigationAndRecovery();
        automaticDraftsCoalesceWithoutNewAnalysis();
        textEditingDefersSDKContextUntilDebounce();
        reentrantMissingSDKNoticeCannotEraseTypedDraft();
        missingSDKDuringAutomaticUpdateUsesWorkerAuthorityOnly();
        automaticInvalidAndInFlightDraftsStayPending();
        automaticCallbacksRespectReviewLifetime();
        automaticOutputAndSaveKeepAnalysisManual();
        automaticRejectedSnapshotDoesNotLoop();
        automaticReentrantDeclineQueuesOnlyTheNewerDraft();
        automaticForegroundPauseResumesOnlyForFinalCut();
        nativeChooserCompletionRetainsIdentityAndSettlesSDK();
        nativeChooserRejectsChangedClosedCancelledAndMissingContexts();
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
        fixedCutPaneStaysStableAsRowsChange();
        informationalCopyKeepsReviewAuthorityUnchanged();
        longRecoveryDetailsStayVisibleWithoutAuthorizingAnotherApply();
        longCancellationDetailsDoNotSuggestApply();
        longLocalSaveFailurePreservesReadyReview();
        longLocalSaveFailureOverridesCompletedHeadline();
        visualHierarchyRendersStatesWithoutChangingAuthority();
        cursorSurvivesWholeReviewFlowWithoutNewCommands();
        cursorRepairRejectsForeignUnknownAndSpecializedContexts();
        cursorStateRefreshCoalescesAndRechecksStationaryOwnership();
        cursorTrackingAndNativeTextRemainScoped();
        check(hostSingleton == nil, @"No host fixture survives the test groups");
        printf("Passed %lu controller groups (%lu assertions); no Final Cut, windows, events, notifications, helper launches, or settings files used.\n",
               (unsigned long)groupCount, (unsigned long)assertionCount);
    }
    return EXIT_SUCCESS;
}
