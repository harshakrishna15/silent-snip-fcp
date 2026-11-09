#import "WorkflowReviewClient.h"
#import "SilentSnipReviewConnection.h"
#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <sys/stat.h>
#import <math.h>
#import <errno.h>

static NSString * const SSCommandName = @"local.silentsnip.review.command.v1";
static NSString * const SSCapabilityName = @"local.silentsnip.workflow.capabilities.v1";
static NSString * const SSHelperID = @"local.silentsnip.app";
static NSString * const SSHostID = @"com.apple.FinalCut";
static NSString * const SSInstallMessage = @"Install the updated Silent Snip app, then try again.";

static BOOL SSBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static BOOL SSInteger(id value, long long expected) {
    return [value isKindOfClass:NSNumber.class] && !SSBoolean(value) &&
        isfinite([value doubleValue]) && [value longLongValue] == expected && [value doubleValue] == (double)expected;
}
static BOOL SSUUID(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length == 36 && [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL SSText(id value, NSUInteger maximum, BOOL empty) {
    return [value isKindOfClass:NSString.class] && (empty || [value length] > 0) &&
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum &&
        [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL SSNavigationTime(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSNumber *numerator = value[@"numerator"], *denominator = value[@"denominator"];
    if (![numerator isKindOfClass:NSNumber.class] || ![denominator isKindOfClass:NSNumber.class]) return NO;
    long long scale = denominator.longLongValue;
    return SSInteger(numerator, numerator.longLongValue) && SSInteger(denominator, scale) && scale > 0 && scale <= INT32_MAX;
}
static BOOL SSDisplayText(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum;
}
static BOOL SSLocalURL(NSURL *url) {
    return [url isKindOfClass:NSURL.class] && url.isFileURL && url.path.length > 1 &&
        (!url.host.length || [url.host.lowercaseString isEqual:@"localhost"]) &&
        !url.query && !url.fragment && !url.user && !url.password && !url.port;
}
static BOOL SSProject(NSURL *libraryURL, NSString *projectUID, NSString *projectName) {
    return SSLocalURL(libraryURL) && [libraryURL.pathExtension.lowercaseString isEqual:@"fcpbundle"] &&
        SSText(libraryURL.path, 4096, NO) && SSText(projectUID, 4096, NO) &&
        [projectUID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length &&
        SSText(projectName, 4096, NO) &&
        [projectName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
}
static BOOL SSSettings(NSDictionary *settings) {
    if (![settings isKindOfClass:NSDictionary.class]) return NO;
    NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    const double lower[] = {-80, 0.0001, 0, 0}, upper[] = {0, 10, 2, 2};
    for (NSUInteger i = 0; i < keys.count; ++i) {
        id value = settings[keys[i]];
        if (![value isKindOfClass:NSNumber.class] || SSBoolean(value) || !isfinite([value doubleValue]) ||
            [value doubleValue] < lower[i] || [value doubleValue] > upper[i]) return NO;
    }
    return [@[@"remove", @"gaps"] containsObject:settings[@"outputMode"]];
}
static NSURL *SSCanonicalAppURL(NSURL *url) {
    if (!SSLocalURL(url) || ![url.pathExtension isEqual:@"app"]) return nil;
    return url.URLByStandardizingPath.URLByResolvingSymlinksInPath;
}
static NSString *SSResponseName(NSString *request) {
    return [@"local.silentsnip.review.response.v1." stringByAppendingString:request];
}

@interface SSWorkflowReviewClient ()
@property (nonatomic, copy) NSString *viewID;
@property (nonatomic, copy) void (^update)(NSDictionary *);
@property (nonatomic, copy) void (^failure)(NSString *);
@property (nonatomic, strong) SilentSnipReviewConnection *connection;
@property (nonatomic, copy) NSDictionary *response;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSURL *helperURL;
@property (nonatomic, strong) NSURL *analysisURL;
@property (nonatomic, copy) NSString *capabilityNonce;
@property (nonatomic, strong) NSDate *capabilityStarted;
@property (nonatomic) BOOL helperLaunched;
@property (nonatomic) BOOL cancelRequested;
@property (nonatomic, copy) NSDictionary *pendingCancel;
@property (nonatomic) BOOL locallyFailed;
@property (nonatomic) BOOL observing;
@property (nonatomic) BOOL analysisDispatched;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL activationPending;
@property (nonatomic) NSUInteger activationToken;
@property (nonatomic, copy) NSString *localMessage;
@property (nonatomic) BOOL settingsDirty;
@property (nonatomic) BOOL recoveryOnly;
@property (nonatomic) BOOL recoveryPending;
@property (nonatomic, copy) NSString *recoveryGesture;
@property (nonatomic) NSUInteger settingsSequence;
@property (nonatomic) NSUInteger settingsDraftGeneration;
@property (nonatomic) NSUInteger automaticSettingsDraftGeneration;
@property (nonatomic) NSUInteger automaticSettingsSequence;
@property (nonatomic, copy) NSString *automaticSettingsEdit;
@property (nonatomic, copy) NSDictionary *automaticSettingsValues;
@property (nonatomic, copy) NSString *rejectedAutomaticSettingsEdit;
@property (nonatomic, strong) NSNumber *rejectedAutomaticSettingsSequence;
@property (nonatomic, copy) NSNumber *navigationRevision;
@property (nonatomic, copy) NSDictionary *pendingNativeNavigation;
@property (nonatomic, copy) NSDictionary *navigationAcknowledgment;
@property (nonatomic, copy) BOOL (^nativeMove)(NSDictionary *);
@property (nonatomic) NSTimeInterval nativeNavigationDeadline;
@end

@implementation SSWorkflowReviewClient
- (instancetype)initWithViewID:(NSString *)viewID update:(void (^)(NSDictionary *))update failure:(void (^)(NSString *))failure {
    self = [super init];
    if (self) { _viewID = [viewID copy]; _update = [update copy]; _failure = [failure copy]; }
    return self;
}
- (NSString *)requestID { return self.connection.requestID; }
- (BOOL)busy {
    if (!self.requestID || self.locallyFailed || self.connection.timedOut) return NO;
    return self.activationPending || self.capabilityNonce != nil || self.connection.awaitingResponse || self.connection.operationBusy ||
        self.connection.applying || self.connection.pendingRetry != nil || self.connection.pendingSettings != nil ||
        self.navigationRevision != nil || self.pendingNativeNavigation != nil || self.cancelRequested;
}
- (BOOL)canApply {
    if (self.settingsDirty || self.recoveryOnly || !self.requestID || self.busy || self.connection.timedOut || self.locallyFailed || self.cancelRequested ||
        self.connection.pendingSelection || self.connection.pendingRetry || self.connection.pendingApply ||
        !self.connection.revision || ![self.connection.state isEqual:SilentSnipReviewStateReview] ||
        ![self.response[@"canApply"] isEqual:@YES]) return NO;
    for (NSDictionary *cut in self.response[@"cuts"]) if ([cut[@"eligible"] boolValue] && [cut[@"included"] boolValue]) return YES;
    return NO;
}
- (BOOL)canChangeSelection {
    return !self.settingsDirty && !self.recoveryOnly && self.requestID && !self.busy && !self.locallyFailed && !self.connection.timedOut && !self.cancelRequested &&
        !self.connection.pendingSelection && !self.connection.pendingRetry && !self.connection.pendingApply &&
        self.connection.revision && [self.connection.state isEqual:SilentSnipReviewStateReview] &&
        [self.response[@"canChangeSelection"] isEqual:@YES];
}
- (BOOL)canUpdateCuts {
    return !self.recoveryOnly && self.requestID && !self.busy && !self.locallyFailed && !self.connection.timedOut &&
        !self.cancelRequested && !self.connection.pendingSelection && self.connection.revision &&
        [self.connection.state isEqual:SilentSnipReviewStateReview] && [self.response[@"canUpdateCuts"] isEqual:@YES];
}
- (BOOL)automaticPreviewAvailable {
    return !self.recoveryOnly && self.requestID && !self.locallyFailed && !self.connection.timedOut &&
        !self.cancelRequested && !SilentSnipReviewStateIsTerminal(self.connection.state) &&
        [self.response[@"automaticPreviewAvailable"] isEqual:@YES];
}
- (BOOL)updatingCuts {
    return self.automaticSettingsEdit != nil && !self.locallyFailed && !self.connection.timedOut &&
        !self.cancelRequested && !SilentSnipReviewStateIsTerminal(self.connection.state);
}
- (BOOL)hostIsAlreadyFrontmost {
    NSArray<NSRunningApplication *> *hosts = [self runningHostApplications];
    NSRunningApplication *host = hosts.count == 1 ? hosts.firstObject : nil;
    NSRunningApplication *front = [self frontmostApplication];
    return host && !host.terminated && host.processIdentifier > 0 && [host.bundleIdentifier isEqual:SSHostID] &&
        front.processIdentifier == host.processIdentifier && [front.bundleIdentifier isEqual:SSHostID];
}
- (void)clearAutomaticUpdate {
    self.automaticSettingsEdit = nil;
    self.automaticSettingsValues = nil;
    self.automaticSettingsSequence = 0;
    self.automaticSettingsDraftGeneration = 0;
}
- (BOOL)canHighlight {
    return !self.settingsDirty && !self.recoveryOnly && self.canChangeSelection && [self.response[@"canHighlight"] isEqual:@YES];
}
- (BOOL)supportsNativeNavigation { return [self.response[@"canNavigateWithSDK"] isEqual:@YES]; }
- (void)clearNativeNavigation {
    self.pendingNativeNavigation = nil;
    self.nativeMove = nil;
    self.nativeNavigationDeadline = 0;
}
- (BOOL)canCancel {
    if (self.recoveryPending && self.analysisDispatched) return NO;
    return self.requestID && !self.cancelRequested && (self.activationPending || (!SilentSnipReviewStateIsTerminal(self.connection.state) &&
        (self.connection.awaitingResponse || self.capabilityNonce || [self.response[@"canCancel"] isEqual:@YES])));
}

// Dependency boundaries also permit offline tests to use no Launch Services,
// distributed notifications, timers, or filesystem settings.
- (NSDate *)now { return NSDate.date; }
- (NSArray<NSRunningApplication *> *)runningHostApplications {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:SSHostID];
}
- (NSRunningApplication *)frontmostApplication { return NSWorkspace.sharedWorkspace.frontmostApplication; }
- (BOOL)requestActivationOfHost:(NSRunningApplication *)host {
    return [host activateFromApplication:NSRunningApplication.currentApplication options:0];
}
- (NSTimeInterval)activationUptime { return NSProcessInfo.processInfo.systemUptime; }
- (void)scheduleActivationCheck:(void (^)(void))check {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
}
- (NSError *)hostActivationError {
    return [NSError errorWithDomain:@"SilentSnipWorkflow" code:2 userInfo:@{NSLocalizedDescriptionKey:
        @"Final Cut Pro could not become active. Bring Final Cut Pro to the front, then try the action again."}];
}
- (void)observeHostActivation:(NSRunningApplication *)host deadline:(NSTimeInterval)deadline
                  generation:(NSUInteger)generation token:(NSUInteger)token completion:(void (^)(NSError *))completion {
    if (generation != self.generation || token != self.activationToken || !self.activationPending) return;
    NSArray<NSRunningApplication *> *hosts = [self runningHostApplications];
    if (host.terminated || hosts.count != 1 || hosts.firstObject.processIdentifier != host.processIdentifier ||
        ![hosts.firstObject.bundleIdentifier isEqual:SSHostID]) { completion([self hostActivationError]); return; }
    NSRunningApplication *front = [self frontmostApplication];
    if (front.processIdentifier == host.processIdentifier && [front.bundleIdentifier isEqual:SSHostID]) { completion(nil); return; }
    if ([self activationUptime] >= deadline) { completion([self hostActivationError]); return; }
    __weak SSWorkflowReviewClient *weakSelf = self;
    [self scheduleActivationCheck:^{
        [weakSelf observeHostActivation:host deadline:deadline generation:generation token:token completion:completion];
    }];
}
// A request returning YES only means AppKit accepted it. Observe the exact
// pinned host PID becoming frontmost before any worker edit/start command.
- (void)activateHostForUserRequest:(void (^)(NSError *))completion {
    NSArray<NSRunningApplication *> *hosts = [self runningHostApplications];
    NSRunningApplication *host = hosts.count == 1 ? hosts.firstObject : nil;
    if (!host || host.terminated || host.processIdentifier <= 0 || ![host.bundleIdentifier isEqual:SSHostID] ||
        ![self requestActivationOfHost:host]) { completion([self hostActivationError]); return; }
    [self observeHostActivation:host deadline:[self activationUptime] + 2.0
        generation:self.generation token:self.activationToken completion:completion];
}
- (void)prepareHostForUserRequest:(void (^)(NSError *))completion {
    self.activationPending = YES;
    self.activationToken += 1;
    NSUInteger generation = self.generation, token = self.activationToken;
    self.localMessage = @"Activating Final Cut Pro…";
    [self publish];
    if (generation != self.generation || token != self.activationToken || !self.activationPending ||
        !self.requestID || self.cancelRequested || self.locallyFailed) return;
    [self activateHostForUserRequest:^(NSError *error) {
        if (generation != self.generation || token != self.activationToken || !self.activationPending || !self.requestID ||
            self.cancelRequested || self.locallyFailed) return;
        self.activationPending = NO;
        self.localMessage = nil;
        completion(error);
    }];
}
- (NSArray<NSURL *> *)registeredHelperURLs { return [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:SSHelperID]; }
- (NSURL *)siblingHelperURL {
    NSURL *extension = NSBundle.mainBundle.bundleURL;
    if (![extension.pathExtension isEqual:@"appex"]) return nil;
    NSURL *plugins = extension.URLByDeletingLastPathComponent;
    NSURL *contents = plugins.URLByDeletingLastPathComponent;
    NSURL *container = contents.URLByDeletingLastPathComponent;
    if (![plugins.lastPathComponent isEqual:@"PlugIns"] || ![contents.lastPathComponent isEqual:@"Contents"] ||
        ![container.pathExtension isEqual:@"app"]) return nil;
    return SSCanonicalAppURL([container.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Silent Snip.app"]);
}
- (NSDictionary *)helperInfoAtURL:(NSURL *)app {
    NSURL *info = [app URLByAppendingPathComponent:@"Contents/Info.plist"];
    struct stat stamp;
    if (lstat(info.fileSystemRepresentation, &stamp) != 0) return errno == EACCES || errno == EPERM ? nil : @{};
    if (!S_ISREG(stamp.st_mode) || stamp.st_size <= 0 || stamp.st_size > 262144) return @{};
    NSData *data = [NSData dataWithContentsOfURL:info options:0 error:nil];
    if (!data) return nil; // Sandbox can deny an external app's Info contents.
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}
- (BOOL)verifiedHelperInfo:(NSDictionary *)info {
    if (![info[@"CFBundleIdentifier"] isEqual:SSHelperID] || ![info[@"CFBundleExecutable"] isEqual:@"SilentSnip"] ||
        !SSInteger(info[@"SilentSnipWorkflowProtocolVersion"], 1) ||
        ![info[@"com.apple.proapps.MediaAssetProtocol"] isKindOfClass:NSDictionary.class]) return NO;
    id routes = info[@"CFBundleURLTypes"];
    if (![routes isKindOfClass:NSArray.class]) return NO;
    for (id route in routes) {
        if (![route isKindOfClass:NSDictionary.class] || ![route[@"CFBundleURLSchemes"] isKindOfClass:NSArray.class]) continue;
        if ([route[@"CFBundleURLSchemes"] containsObject:@"silentsnip"]) return YES;
    }
    return NO;
}
- (NSURL *)resolveHelperURL {
    NSArray *registered = [self registeredHelperURLs];
    if (![registered isKindOfClass:NSArray.class] || registered.count > 64) return nil;
    NSMutableOrderedSet<NSURL *> *urls = [NSMutableOrderedSet new];
    for (id raw in registered) {
        NSURL *url = [raw isKindOfClass:NSURL.class] ? SSCanonicalAppURL(raw) : nil;
        if (url) [urls addObject:url];
    }
    // The installed frontend/helper pair is authoritative over repo builds.
    // Require the exact sibling to be registered for the expected bundle ID;
    // an arbitrary filesystem neighbor never authorizes launch.
    NSURL *sibling = SSCanonicalAppURL([self siblingHelperURL]);
    if (sibling && [urls containsObject:sibling]) {
        NSDictionary *info = [self helperInfoAtURL:sibling];
        return !info || [self verifiedHelperInfo:info] ? sibling : nil;
    }
    NSMutableArray<NSURL *> *viable = [NSMutableArray new];
    for (NSURL *url in urls) {
        NSDictionary *info = [self helperInfoAtURL:url];
        if (!info || [self verifiedHelperInfo:info]) [viable addObject:url];
    }
    return viable.count == 1 ? viable[0] : nil;
}
- (BOOL)application:(NSRunningApplication *)app matchesPinnedURL:(NSURL *)url {
    return [app.bundleIdentifier isEqual:SSHelperID] && [SSCanonicalAppURL(app.bundleURL) isEqual:url] &&
        [app.executableURL.lastPathComponent isEqual:@"SilentSnip"];
}
- (void)openHelperAtURL:(NSURL *)url completion:(void (^)(NSError *))completion {
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    configuration.addsToRecentItems = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *result = error;
            if (!result && ![self application:app matchesPinnedURL:url]) result = [NSError errorWithDomain:@"SilentSnipWorkflow" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Silent Snip could not verify the app that opened. Reopen the installed app and try again."}];
            completion(result);
        });
    }];
}
- (void)openAnalysisURL:(NSURL *)request helper:(NSURL *)url completion:(void (^)(NSError *))completion {
    NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
    configuration.activates = NO;
    configuration.addsToRecentItems = NO;
    [NSWorkspace.sharedWorkspace openURLs:@[request] withApplicationAtURL:url configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *result = error;
            if (!result && ![self application:app matchesPinnedURL:url]) result = [NSError errorWithDomain:@"SilentSnipWorkflow" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"The request was sent to a different app. Reopen the installed Silent Snip app and try again."}];
            completion(result);
        });
    }];
}
- (void)prepareWindowHelper:(void (^)(NSError *))completion {
    NSURL *helper = [self resolveHelperURL];
    if (!helper) {
        completion([NSError errorWithDomain:@"SilentSnipWorkflow" code:1
            userInfo:@{NSLocalizedDescriptionKey: SSInstallMessage}]);
        return;
    }
    [self openHelperAtURL:helper completion:completion];
}
- (void)beginObserving {
    self.observing = YES;
    NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(receive:) name:SSResponseName(self.requestID) object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if (self.recoveryPending) [center addObserver:self selector:@selector(receiveConnection:)
        name:[@"local.silentsnip.review.connected.v1." stringByAppendingString:self.viewID] object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    if (self.capabilityNonce) [center addObserver:self selector:@selector(receiveCapability:)
        name:[SSCapabilityName stringByAppendingFormat:@".%@", self.viewID] object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
}
- (void)endObserving {
    if (self.observing) [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    self.observing = NO;
}
- (void)postObject:(NSString *)object name:(NSString *)name {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:name object:object userInfo:nil deliverImmediately:YES];
}
- (void)startPolling {
    [self.timer invalidate];
    __weak SSWorkflowReviewClient *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *timer) { [weakSelf poll]; }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)send:(NSDictionary *)command name:(NSString *)name {
    NSData *data = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    if (data && data.length <= 262144) [self postObject:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] name:name];
}
- (void)publish {
    NSMutableDictionary *value = [self.response mutableCopy] ?: [@{@"version": @1, @"request": self.requestID ?: @"",
        @"revision": @0, @"state": @"capturing", @"message": @"Connecting to Silent Snip…", @"cuts": @[]} mutableCopy];
    value[@"canApply"] = @(self.canApply);
    value[@"canChangeSelection"] = @(self.canChangeSelection);
    value[@"canCancel"] = @(self.canCancel);
    value[@"canUpdateCuts"] = @(self.canUpdateCuts);
    value[@"updateCutsAvailable"] = @(!self.recoveryOnly && !self.locallyFailed && !self.connection.timedOut &&
        [self.response[@"canUpdateCuts"] isEqual:@YES]);
    value[@"canHighlight"] = @(self.canHighlight);
    value[@"automaticPreviewAvailable"] = @(self.automaticPreviewAvailable);
    value[@"updatingCuts"] = @(self.updatingCuts);
    value[@"settingsDirty"] = @(self.settingsDirty);
    [value removeObjectForKey:@"rejectedSettingsEdit"];
    [value removeObjectForKey:@"rejectedSettingsSequence"];
    if (self.rejectedAutomaticSettingsEdit) {
        value[@"rejectedSettingsEdit"] = self.rejectedAutomaticSettingsEdit;
        value[@"rejectedSettingsSequence"] = self.rejectedAutomaticSettingsSequence;
    }
    value[@"verificationOnly"] = @(self.recoveryOnly);
    if (self.localMessage) value[@"message"] = self.localMessage;
    if (self.update) self.update(value);
}
- (void)fail:(NSString *)message {
    self.locallyFailed = YES;
    self.connection.timedOut = YES;
    self.connection.pendingApply = nil;
    self.connection.pendingSelection = nil;
    self.connection.pendingRetry = nil;
    self.connection.pendingSettings = nil;
    self.pendingCancel = nil;
    [self clearAutomaticUpdate];
    self.navigationRevision = nil;
    [self clearNativeNavigation];
    self.navigationAcknowledgment = nil;
    self.capabilityNonce = nil;
    self.activationPending = NO;
    self.activationToken += 1;
    [self.timer invalidate]; self.timer = nil;
    if (self.failure) self.failure(message);
}

- (BOOL)startWithLibraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID projectName:(NSString *)projectName
                  settings:(NSDictionary *)settings gesture:(NSString *)gesture {
    if (self.busy) { if (self.failure) self.failure(@"Wait for Silent Snip to finish the current task."); return NO; }
    if (!SSUUID(self.viewID) || !SSUUID(gesture) || !SSProject(libraryURL, projectUID, projectName) || !SSSettings(settings)) {
        if (self.failure) self.failure(@"Open a project in Final Cut Pro and check the settings before clicking Analyze Audio."); return NO;
    }
    return [self beginRequestWithFields:@{@"view": self.viewID, @"gesture": gesture,
        @"library": libraryURL.absoluteString, @"project": projectUID, @"projectName": projectName,
        @"threshold": [settings[@"thresholdDBFS"] stringValue], @"minimum": [settings[@"minimumSilenceDuration"] stringValue],
        @"before": [settings[@"beforeSpeechPadding"] stringValue], @"after": [settings[@"afterSpeechPadding"] stringValue],
        @"output": settings[@"outputMode"]} route:@"workflow-analyze" recovery:NO];
}
- (BOOL)verifyExistingResultURL:(NSURL *)resultURL libraryURL:(NSURL *)libraryURL projectUID:(NSString *)projectUID
                  projectName:(NSString *)projectName gesture:(NSString *)gesture {
    if (self.busy || !SSUUID(self.viewID) || !SSUUID(gesture) || !SSProject(libraryURL, projectUID, projectName) ||
        !SSLocalURL(resultURL) || ![resultURL.lastPathComponent isEqual:@"Silent Snip.fcpxml"] ||
        !SSText(resultURL.path, 16384, NO)) return NO;
    return [self beginRequestWithFields:@{@"view": self.viewID, @"gesture": gesture,
        @"library": libraryURL.absoluteString, @"project": projectUID, @"projectName": projectName,
        @"result": resultURL.absoluteString} route:@"workflow-verify" recovery:YES];
}
- (BOOL)beginRequestWithFields:(NSDictionary *)payload route:(NSString *)route recovery:(BOOL)recovery {
    NSURL *helper = [self resolveHelperURL];
    if (!helper) { if (self.failure) self.failure(SSInstallMessage); return NO; }
    NSDictionary *info = [self helperInfoAtURL:helper];
    if (info && ![self verifiedHelperInfo:info]) { if (self.failure) self.failure(SSInstallMessage); return NO; }
    if (self.requestID && !SilentSnipReviewStateIsTerminal(self.connection.state)) [self cancel];
    [self detach];
    self.helperURL = helper;
    self.connection = [SilentSnipReviewConnection new];
    self.connection.requestID = NSUUID.UUID.UUIDString;
    self.connection.awaitingResponse = YES;
    self.connection.lastResponse = [self now];
    self.capabilityNonce = info ? nil : NSUUID.UUID.UUIDString;
    self.capabilityStarted = self.capabilityNonce ? [self now] : nil;
    self.recoveryOnly = recovery;
    self.recoveryPending = recovery;
    self.recoveryGesture = recovery ? payload[@"gesture"] : nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:[@"silentsnip://" stringByAppendingString:route]];
    NSMutableArray *items = [NSMutableArray new];
    NSMutableDictionary *fields = [payload mutableCopy];
    if (!recovery) fields[@"request"] = self.requestID;
    for (NSString *key in fields) [items addObject:[NSURLQueryItem queryItemWithName:key value:fields[key]]];
    components.queryItems = items;
    self.analysisURL = components.URL;
    [self beginObserving];
    [self startPolling];
    NSUInteger generation = self.generation;
    [self prepareHostForUserRequest:^(NSError *activationError) {
        if (activationError) { [self fail:activationError.localizedDescription]; return; }
        if (self.capabilityNonce) {
            self.capabilityStarted = [self now];
            [self openHelperAtURL:helper completion:^(NSError *error) {
                if (generation != self.generation || !self.requestID || self.cancelRequested || self.locallyFailed) return;
                if (error) { [self fail:error.localizedDescription]; return; }
                self.helperLaunched = YES;
                self.capabilityStarted = [self now];
                [self poll];
            }];
        } else [self dispatchAnalysis];
    }];
    return YES;
}
- (void)dispatchAnalysis {
    if (self.locallyFailed || self.cancelRequested || self.activationPending || self.analysisDispatched || !self.requestID || !self.analysisURL) return;
    NSDictionary *info = [self helperInfoAtURL:self.helperURL];
    if (info && ![self verifiedHelperInfo:info]) { [self fail:SSInstallMessage]; return; }
    [self prepareHostForUserRequest:^(NSError *activationError) {
        if (activationError) { [self fail:activationError.localizedDescription]; return; }
        NSDictionary *currentInfo = [self helperInfoAtURL:self.helperURL];
        if (currentInfo && ![self verifiedHelperInfo:currentInfo]) { [self fail:SSInstallMessage]; return; }
        NSUInteger generation = self.generation;
        self.connection.lastResponse = [self now];
        self.analysisDispatched = YES; // An uncertain OS launch is never retried.
        [self openAnalysisURL:self.analysisURL helper:self.helperURL completion:^(NSError *error) {
            if (generation != self.generation || !self.requestID) return;
            if (error) [self fail:error.localizedDescription];
        }];
        if (generation == self.generation && self.requestID && !self.locallyFailed) [self publish];
    }];
}
- (void)receiveCapability:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self receiveCapability:notification]; });
        return;
    }
    if (self.locallyFailed || self.cancelRequested || self.connection.timedOut ||
        !self.capabilityNonce || !self.helperLaunched || notification.userInfo || ![notification.object isKindOfClass:NSString.class]) return;
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 2048) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || !SSInteger(value[@"version"], 1) ||
        !SSInteger(value[@"protocol"], 1) || ![value[@"view"] isEqual:self.viewID] ||
        ![value[@"nonce"] isEqual:self.capabilityNonce]) return;
    self.capabilityNonce = nil;
    self.connection.lastResponse = [self now];
    [self dispatchAnalysis]; // Consume the nonce before the one real URL dispatch.
}
- (void)receiveConnection:(NSNotification *)notification {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self receiveConnection:notification]; }); return; }
    if (!self.recoveryPending || !self.analysisDispatched || self.capabilityNonce || self.locallyFailed || self.cancelRequested ||
        notification.userInfo || ![notification.object isKindOfClass:NSString.class]) return;
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 4096) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![value isKindOfClass:NSDictionary.class] || !SSInteger(value[@"version"], 1) || ![value[@"view"] isEqual:self.viewID] ||
        ![value[@"gesture"] isEqual:self.recoveryGesture]) return;
    if (SSDisplayText(value[@"error"], 16384)) { [self fail:value[@"error"]]; return; }
    if (!SSUUID(value[@"request"]) || ![value[@"settings"] isKindOfClass:NSDictionary.class] ||
        ![@[@"remove", @"gaps"] containsObject:value[@"output"]]) return;
    NSDictionary *wire = value[@"settings"];
    NSDictionary *settings = @{@"thresholdDBFS": wire[@"threshold"] ?: NSNull.null,
        @"minimumSilenceDuration": wire[@"minimum"] ?: NSNull.null,
        @"beforeSpeechPadding": wire[@"before"] ?: NSNull.null,
        @"afterSpeechPadding": wire[@"after"] ?: NSNull.null, @"outputMode": value[@"output"]};
    if (!SSSettings(settings)) return;
    [self endObserving];
    self.recoveryPending = NO;
    self.connection = [SilentSnipReviewConnection new];
    self.connection.requestID = value[@"request"];
    self.connection.awaitingResponse = YES;
    self.connection.lastResponse = [self now];
    [self beginObserving];
    [self send:@{@"version": @1, @"request": self.requestID, @"command": @"status"} name:SSCommandName];
    [self publish];
}
- (BOOL)validResponse:(NSDictionary *)value {
    if (![value isKindOfClass:NSDictionary.class] || !SSInteger(value[@"version"], 1) ||
        ![value[@"request"] isEqual:self.requestID] || !SSDisplayText(value[@"message"], 16384) ||
        (value[@"workflowGesture"] && !SSUUID(value[@"workflowGesture"])) ||
        (self.recoveryOnly && ![value[@"workflowGesture"] isEqual:self.recoveryGesture])) return NO;
    id revision = value[@"revision"];
    if (![revision isKindOfClass:NSNumber.class] || SSBoolean(revision) || !isfinite([revision doubleValue]) ||
        [revision longLongValue] < 0 || [revision doubleValue] != (double)[revision longLongValue]) return NO;
    NSArray *states = @[@"analyzing", @"capturing", @"recalculating", @"review", @"applying", @"verifying",
        @"navigating", @"cancelling", @"completed", @"complete", @"failed", @"cancelled", @"unavailable"];
    if (![states containsObject:value[@"state"]]) return NO;
    for (NSString *key in @[@"canApply", @"canChangeSelection", @"canCancel", @"canHighlight"])
        if (!SSBoolean(value[key])) return NO;
    for (NSString *key in @[@"canRetryVerification", @"previewVisible", @"provisional", @"canUpdateCuts", @"usesAudioSnapshot", @"automaticPreviewAvailable", @"canNavigateWithSDK"])
        if (value[key] && !SSBoolean(value[key])) return NO;
    id permit = value[@"navigationPermit"];
    if (permit) {
        if (![permit isKindOfClass:NSDictionary.class] || ![value[@"state"] isEqual:@"navigating"] ||
            ![value[@"canNavigateWithSDK"] isEqual:@YES] || !SSUUID(permit[@"view"]) || !SSUUID(permit[@"gesture"]) ||
            !SSText(permit[@"cutID"], 200, NO) || ![permit[@"expiresUptime"] isKindOfClass:NSNumber.class] ||
            SSBoolean(permit[@"expiresUptime"]) || !isfinite([permit[@"expiresUptime"] doubleValue])) return NO;
        for (NSString *key in @[@"time", @"sequenceStart", @"sequenceDuration", @"frameDuration"])
            if (!SSNavigationTime(permit[key])) return NO;
    }
    for (NSString *key in @[@"summary", @"targetClipName"])
        if (value[key] && !SSDisplayText(value[key], 16384)) return NO;
    if (value[@"settingsEdit"] && !SSUUID(value[@"settingsEdit"])) return NO;
    if ((value[@"rejectedSettingsEdit"] != nil) != (value[@"rejectedSettingsSequence"] != nil)) return NO;
    if (value[@"rejectedSettingsEdit"] && (!SSUUID(value[@"rejectedSettingsEdit"]) ||
        ![value[@"rejectedSettingsSequence"] isKindOfClass:NSNumber.class] ||
        !SSInteger(value[@"rejectedSettingsSequence"], [value[@"rejectedSettingsSequence"] longLongValue]) ||
        [value[@"rejectedSettingsSequence"] longLongValue] <= 0)) return NO;
    id progress = value[@"progress"];
    if (progress && (![progress isKindOfClass:NSNumber.class] || SSBoolean(progress) || !isfinite([progress doubleValue]) ||
        [progress doubleValue] < 0 || [progress doubleValue] > 1)) return NO;
    id cuts = value[@"cuts"];
    if (![cuts isKindOfClass:NSArray.class] || [cuts count] > 2000) return NO;
    NSMutableSet *ids = [NSMutableSet new];
    for (id row in cuts) {
        if (![row isKindOfClass:NSDictionary.class] || !SSText(row[@"id"], 1024, NO) || [ids containsObject:row[@"id"]] ||
            !SSText(row[@"start"], 128, NO) || !SSText(row[@"end"], 128, NO) || !SSText(row[@"duration"], 128, NO) ||
            !SSBoolean(row[@"eligible"]) || !SSBoolean(row[@"included"]) ||
            ([row[@"included"] boolValue] && ![row[@"eligible"] boolValue]) ||
            (row[@"reason"] && !SSDisplayText(row[@"reason"], 16384))) return NO;
        [ids addObject:row[@"id"]];
    }
    return YES;
}
- (void)receive:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self receive:notification]; });
        return;
    }
    if (self.recoveryPending || !self.requestID || !self.analysisDispatched || self.capabilityNonce || notification.userInfo || ![notification.object isKindOfClass:NSString.class]) return;
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 262144) return;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![self validResponse:value]) return;
    if (SilentSnipReviewStateIsTerminal(self.connection.state) && !self.connection.pendingRetry) return;
    if (self.connection.pendingRetry && !SilentSnipReviewStateIsTerminal(value[@"state"]) && ![value[@"state"] isEqual:@"verifying"]) return;
    // A declined automatic edit is a read-only acknowledgment of that exact
    // nonce/sequence, not a new accepted review revision. Handle it before the
    // shared connection's ordinary same-revision heartbeat deduplication.
    if (value[@"rejectedSettingsEdit"]) {
        BOOL current = [value[@"rejectedSettingsEdit"] isEqual:self.automaticSettingsEdit] &&
            [value[@"rejectedSettingsSequence"] isEqual:@(self.automaticSettingsSequence)] &&
            [self.connection.pendingSettings[@"settingsEdit"] isEqual:self.automaticSettingsEdit] &&
            [self.connection.pendingSettings[@"automaticPreview"] isEqual:@YES] &&
            [@[SilentSnipReviewStateReview, SilentSnipReviewStateRecalculating] containsObject:value[@"state"]] &&
            [value[@"revision"] compare:self.connection.revision] != NSOrderedAscending;
        if (!current) {
            if (!self.automaticSettingsEdit && !self.connection.pendingSettings &&
                [value[@"rejectedSettingsEdit"] isEqual:self.rejectedAutomaticSettingsEdit] &&
                [value[@"rejectedSettingsSequence"] isEqual:self.rejectedAutomaticSettingsSequence] &&
                [value[@"revision"] compare:self.connection.revision] != NSOrderedAscending)
                self.connection.lastResponse = [self now];
            return;
        }
        self.rejectedAutomaticSettingsEdit = self.automaticSettingsEdit;
        self.rejectedAutomaticSettingsSequence = @(self.automaticSettingsSequence);
        self.settingsDirty = YES;
        self.connection.pendingSettings = nil;
        self.connection.awaitingResponse = NO;
        self.connection.lastResponse = [self now];
        [self clearAutomaticUpdate];
        NSDictionary *newer = [self.connection acceptNotification:notification];
        if (newer) self.response = newer;
        self.connection.lastResponse = [self now];
        self.connection.operationBusy = SilentSnipReviewStateIsBusy(value[@"state"]);
        self.localMessage = value[@"message"];
        [self publish];
        return;
    }
    NSDictionary *accepted = [self.connection acceptNotification:notification];
    if (!accepted) return;
    self.response = accepted;
    BOOL hideSupersededPreview = NO;
    if (self.automaticSettingsEdit && [accepted[@"settingsEdit"] isEqual:self.automaticSettingsEdit] &&
        [accepted[@"state"] isEqual:SilentSnipReviewStateReview] && ![accepted[@"provisional"] isEqual:@YES]) {
        NSDictionary *wire = accepted[@"settings"];
        NSDictionary *wanted = self.automaticSettingsValues;
        BOOL sameSnapshot = [wire isKindOfClass:NSDictionary.class] &&
            [wire[@"threshold"] isEqual:wanted[@"thresholdDBFS"]] &&
            [wire[@"minimum"] isEqual:wanted[@"minimumSilenceDuration"]] &&
            [wire[@"before"] isEqual:wanted[@"beforeSpeechPadding"]] &&
            [wire[@"after"] isEqual:wanted[@"afterSpeechPadding"]] &&
            [accepted[@"output"] isEqual:wanted[@"outputMode"]];
        BOOL newestDraft = self.settingsDraftGeneration == self.automaticSettingsDraftGeneration;
        self.settingsDirty = !sameSnapshot || !newestDraft;
        hideSupersededPreview = self.settingsDirty;
        if (!sameSnapshot) {
            self.rejectedAutomaticSettingsEdit = self.automaticSettingsEdit;
            self.rejectedAutomaticSettingsSequence = @(self.automaticSettingsSequence);
        }
        [self clearAutomaticUpdate];
    }
    if (self.navigationRevision && [accepted[@"revision"] compare:self.navigationRevision] == NSOrderedDescending) self.navigationRevision = nil;
    NSDictionary *navigation = self.pendingNativeNavigation;
    NSDictionary *permit = accepted[@"navigationPermit"];
    BOOL (^move)(NSDictionary *) = nil;
    if (navigation && [accepted[@"revision"] compare:navigation[@"expectedRevision"]] == NSOrderedDescending) {
        if ([permit[@"view"] isEqual:self.viewID] && [permit[@"gesture"] isEqual:navigation[@"navigationGesture"]] &&
            [permit[@"cutID"] isEqual:navigation[@"cutID"]] &&
            [accepted[@"revision"] longLongValue] - [navigation[@"expectedRevision"] longLongValue] == 1) move = self.nativeMove;
        // Consume before publishing or invoking the SDK. Heartbeats can carry
        // the same permit but can never execute the move again.
        [self clearNativeNavigation];
    }
    if (self.navigationAcknowledgment &&
        [accepted[@"revision"] compare:self.navigationAcknowledgment[@"expectedRevision"]] == NSOrderedDescending)
        self.navigationAcknowledgment = nil;
    if (!self.activationPending) self.localMessage = nil;
    if (self.connection.applying && ([accepted[@"state"] isEqual:@"applying"] || SilentSnipReviewStateIsTerminal(accepted[@"state"]))) {
        self.connection.applyAcknowledged = YES;
        self.connection.pendingApply = nil;
        self.connection.applying = NO;
    }
    self.connection.operationBusy = SilentSnipReviewStateIsBusy(accepted[@"state"]);
    if (SilentSnipReviewStateIsTerminal(accepted[@"state"])) {
        self.cancelRequested = NO;
        self.pendingCancel = nil;
        [self clearAutomaticUpdate];
        [self clearNativeNavigation];
        self.navigationAcknowledgment = nil;
        [self.timer invalidate]; self.timer = nil;
    }
    NSUInteger generation = self.generation;
    NSString *request = self.requestID;
    // Publishing can synchronously dispatch the next coalesced draft. Pin this
    // hide to that draft's prospective sequence before its send increments it.
    NSDictionary *hide = hideSupersededPreview && self.settingsSequence < NSIntegerMax
        ? @{@"version": @1, @"request": request, @"command": @"preview", @"included": @NO,
            @"localPreview": @YES, @"expectedRevision": accepted[@"revision"], @"view": self.viewID,
            @"settingsSequence": @(self.settingsSequence + 1)} : nil;
    [self publish];
    if (move && generation == self.generation && [request isEqual:self.requestID] &&
        [accepted[@"revision"] isEqual:self.connection.revision] && !self.cancelRequested && !self.locallyFailed) {
        BOOL moved = [self activationUptime] <= [permit[@"expiresUptime"] doubleValue] &&
            [self hostIsAlreadyFrontmost] && !self.settingsDirty && move(permit);
        if (generation == self.generation && [request isEqual:self.requestID] && !self.cancelRequested && !self.locallyFailed &&
            [accepted[@"revision"] isEqual:self.connection.revision]) {
            self.navigationAcknowledgment = @{@"version": @1, @"request": request, @"command": @"navigationFinished",
                @"cutID": permit[@"cutID"], @"expectedRevision": accepted[@"revision"], @"view": self.viewID,
                @"navigationGesture": permit[@"gesture"], @"navigationSucceeded": @(moved)};
            [self send:self.navigationAcknowledgment name:SSCommandName];
        }
    }
    if (hide && generation == self.generation && [request isEqual:self.requestID] &&
        self.settingsDirty && !self.cancelRequested && !self.locallyFailed)
        [self send:hide name:SSCommandName];
}
- (void)poll {
    if (!self.requestID || self.locallyFailed || self.activationPending) return;
    if (self.capabilityNonce) {
        if (self.capabilityStarted && [[self now] timeIntervalSinceDate:self.capabilityStarted] > (self.helperLaunched ? 5 : 15)) {
            [self fail:SSInstallMessage]; return;
        }
        if (self.helperLaunched) [self send:@{@"version": @1, @"view": self.viewID, @"nonce": self.capabilityNonce} name:SSCapabilityName];
        return;
    }
    if ([self.connection hasTimedOutAt:[self now]]) { [self fail:@"Silent Snip stopped responding. Check Final Cut Pro before starting another task."]; return; }
    if (self.recoveryPending) return;
    if (self.pendingNativeNavigation && [self activationUptime] >= self.nativeNavigationDeadline) {
        [self clearNativeNavigation];
        self.localMessage = @"Final Cut Pro did not confirm the playhead move.";
        [self publish];
    }
    if (self.pendingCancel) {
        // Cancellation is idempotent and bound to this exact request. A lost
        // notification must not leave a live review permanently locked while
        // ordinary status heartbeats continue to keep the connection alive.
        NSDictionary *command = self.pendingCancel;
        NSUInteger generation = self.generation;
        [self send:command name:SSCommandName];
        if (generation != self.generation || self.pendingCancel != command || self.locallyFailed) return;
    }
    for (NSDictionary *command in self.connection.commandsToRetry) [self send:command name:SSCommandName];
    if (self.navigationAcknowledgment) [self send:self.navigationAcknowledgment name:SSCommandName];
    [self send:@{@"version": @1, @"request": self.requestID, @"command": @"status"} name:SSCommandName];
}
- (BOOL)selection:(NSDictionary *)fields {
    if (!self.canChangeSelection) return NO;
    NSMutableDictionary *command = [@{@"version": @1, @"request": self.requestID, @"expectedRevision": self.connection.revision} mutableCopy];
    [command addEntriesFromDictionary:fields];
    self.connection.pendingSelection = command;
    self.connection.selectionRevision = self.connection.revision;
    [self publish];
    [self send:command name:SSCommandName];
    return YES;
}
- (BOOL)setCut:(NSString *)cutID included:(BOOL)included {
    for (NSDictionary *cut in self.response[@"cuts"]) if ([cut[@"id"] isEqual:cutID] && [cut[@"eligible"] boolValue])
        return [self selection:@{@"command": @"include", @"cutID": cutID, @"included": @(included)}];
    return NO;
}
- (BOOL)selectAll:(BOOL)included { return [self selection:@{@"command": included ? @"selectAll" : @"deselectAll"}]; }
- (void)markSettingsDirty {
    if ((self.busy && !self.updatingCuts) || self.recoveryOnly || !self.requestID || self.cancelRequested ||
        self.locallyFailed || self.connection.timedOut ||
        (![self.connection.state isEqual:SilentSnipReviewStateReview] && !self.updatingCuts)) return;
    self.settingsDraftGeneration += 1;
    BOOL alreadyDirty = self.settingsDirty;
    BOOL supersedingUpdate = self.updatingCuts;
    self.settingsDirty = YES;
    if (alreadyDirty && !supersedingUpdate) return;
    // Inclusion edits already in flight must acknowledge their revision before
    // the coalesced settings snapshot can bind a new recalculation to it.
    if (!self.automaticPreviewAvailable) self.connection.pendingSelection = nil;
    NSDictionary *command = self.settingsSequence < NSIntegerMax
        ? @{@"version": @1, @"request": self.requestID, @"command": @"preview", @"included": @NO,
            @"localPreview": @YES, @"expectedRevision": self.connection.revision, @"view": self.viewID,
            @"settingsSequence": @(self.settingsSequence + 1)} : nil;
    NSUInteger generation = self.generation;
    if (!alreadyDirty) [self publish];
    if (command && generation == self.generation && self.settingsDirty && !self.locallyFailed && !self.cancelRequested)
        [self send:command name:SSCommandName];
}
- (BOOL)automaticallyUpdateCutsWithSettings:(NSDictionary *)settings edit:(NSString *)edit {
    if (!self.automaticPreviewAvailable || !self.canUpdateCuts || !self.settingsDirty ||
        self.automaticSettingsEdit || !SSUUID(edit) || !SSSettings(settings) ||
        self.settingsSequence >= NSIntegerMax || ![self hostIsAlreadyFrontmost]) return NO;
    NSDictionary *values = @{@"thresholdDBFS": settings[@"thresholdDBFS"],
        @"minimumSilenceDuration": settings[@"minimumSilenceDuration"],
        @"beforeSpeechPadding": settings[@"beforeSpeechPadding"],
        @"afterSpeechPadding": settings[@"afterSpeechPadding"], @"outputMode": [settings[@"outputMode"] copy]};
    NSNumber *revision = self.connection.revision;
    self.settingsSequence += 1;
    self.automaticSettingsSequence = self.settingsSequence;
    self.automaticSettingsDraftGeneration = self.settingsDraftGeneration;
    self.automaticSettingsEdit = [edit copy];
    self.automaticSettingsValues = values;
    self.rejectedAutomaticSettingsEdit = nil;
    self.rejectedAutomaticSettingsSequence = nil;
    NSDictionary *command = @{@"version": @1, @"request": self.requestID, @"command": @"recalculate",
        @"expectedRevision": revision, @"view": self.viewID, @"settingsEdit": edit,
        @"settingsSequence": @(self.settingsSequence), @"verifySettings": @YES, @"localPreview": @YES,
        @"automaticPreview": @YES,
        @"settings": @{@"threshold": values[@"thresholdDBFS"], @"minimum": values[@"minimumSilenceDuration"],
            @"before": values[@"beforeSpeechPadding"], @"after": values[@"afterSpeechPadding"]},
        @"output": values[@"outputMode"]};
    self.connection.pendingSettings = command;
    self.connection.awaitingResponse = YES;
    self.connection.lastResponse = [self now];
    self.localMessage = @"Updating cuts from the last analyzed audio…";
    NSUInteger generation = self.generation, draft = self.settingsDraftGeneration;
    [self publish];
    if (generation != self.generation || self.cancelRequested || self.locallyFailed ||
        self.connection.pendingSettings != command || draft != self.settingsDraftGeneration || ![self hostIsAlreadyFrontmost]) {
        if (generation == self.generation && self.connection.pendingSettings == command) {
            self.connection.pendingSettings = nil;
            self.connection.awaitingResponse = NO;
            [self clearAutomaticUpdate];
            self.localMessage = nil;
            [self publish];
        }
        return NO;
    }
    [self send:command name:SSCommandName];
    return YES;
}
- (BOOL)updateCutsWithSettings:(NSDictionary *)settings gesture:(NSString *)gesture {
    if (!self.canUpdateCuts || !SSUUID(gesture) || !SSSettings(settings)) return NO;
    NSNumber *revision = self.connection.revision;
    // Copy the values before asynchronous activation; callers may keep editing
    // their own mutable dictionary while this immutable request is pending.
    NSDictionary *values = [settings copy];
    [self prepareHostForUserRequest:^(NSError *error) {
        if (error || ![self.connection.revision isEqual:revision] || !self.canUpdateCuts) {
            self.localMessage = error.localizedDescription ?: @"The review changed. Review the current ranges before trying again.";
            [self publish]; return;
        }
        self.settingsSequence += 1;
        self.settingsDirty = NO;
        self.connection.pendingSettings = @{@"version": @1, @"request": self.requestID, @"command": @"recalculate",
            @"expectedRevision": revision, @"view": self.viewID, @"settingsEdit": gesture,
            @"settingsSequence": @(self.settingsSequence), @"verifySettings": @YES, @"localPreview": @YES,
            @"settings": @{@"threshold": values[@"thresholdDBFS"], @"minimum": values[@"minimumSilenceDuration"],
                @"before": values[@"beforeSpeechPadding"], @"after": values[@"afterSpeechPadding"]}, @"output": values[@"outputMode"]};
        self.connection.awaitingResponse = YES;
        self.connection.lastResponse = [self now];
        self.localMessage = @"Updating cuts from the last analyzed audio…";
        NSUInteger generation = self.generation, token = self.activationToken;
        NSDictionary *command = self.connection.pendingSettings;
        [self publish];
        if (generation == self.generation && token == self.activationToken && !self.cancelRequested &&
            !self.locallyFailed && self.connection.pendingSettings == command) [self send:command name:SSCommandName];
    }];
    return YES;
}
- (BOOL)highlightCut:(NSString *)cutID {
    if (!self.canHighlight) return NO;
    BOOL known = NO;
    for (NSDictionary *cut in self.response[@"cuts"]) if ([cut[@"id"] isEqual:cutID]) known = YES;
    if (!known) return NO;
    NSNumber *revision = self.connection.revision;
    [self prepareHostForUserRequest:^(NSError *error) {
        if (error || ![self.connection.revision isEqual:revision] || !self.canHighlight) {
            self.localMessage = error.localizedDescription ?: @"The review changed. Review the current ranges before trying again.";
            [self publish]; return;
        }
        self.navigationRevision = revision;
        self.connection.lastResponse = [self now];
        NSUInteger generation = self.generation, token = self.activationToken;
        NSDictionary *command = @{@"version": @1, @"request": self.requestID, @"command": @"highlight",
            @"cutID": cutID, @"expectedRevision": revision, @"view": self.viewID};
        [self publish];
        // Navigation is deliberately sent once: a dropped reply must not
        // repeatedly move the playhead as polling continues.
        if (generation == self.generation && token == self.activationToken && !self.cancelRequested &&
            !self.locallyFailed && self.navigationRevision == revision) [self send:command name:SSCommandName];
    }];
    return YES;
}
- (BOOL)navigateCut:(NSString *)cutID gesture:(NSString *)gesture move:(BOOL (^)(NSDictionary *))move {
    if (!self.canHighlight || !self.supportsNativeNavigation || !SSUUID(gesture) || !move || ![self hostIsAlreadyFrontmost]) return NO;
    BOOL known = NO;
    for (NSDictionary *cut in self.response[@"cuts"]) if ([cut[@"id"] isEqual:cutID]) known = YES;
    if (!known) return NO;
    NSDictionary *command = @{@"version": @1, @"request": self.requestID, @"command": @"prepareNavigation",
        @"cutID": cutID, @"expectedRevision": self.connection.revision, @"view": self.viewID, @"navigationGesture": gesture};
    self.pendingNativeNavigation = command;
    self.nativeMove = move;
    self.nativeNavigationDeadline = [self activationUptime] + 3;
    NSUInteger generation = self.generation;
    [self publish];
    if (generation == self.generation && self.pendingNativeNavigation == command && !self.cancelRequested &&
        !self.locallyFailed && !self.settingsDirty) [self send:command name:SSCommandName];
    return YES;
}
- (BOOL)sendApplyWithGesture:(NSString *)gesture {
    if (!SSUUID(gesture) || !self.canApply) return NO;
    NSNumber *revision = self.connection.revision;
    [self prepareHostForUserRequest:^(NSError *error) {
        if (error || ![self.connection.revision isEqual:revision] || !self.canApply) {
            self.localMessage = error.localizedDescription ?: @"The review changed before Apply Cuts. Review the current ranges, then try again.";
            [self publish];
            return;
        }
        self.connection.applying = YES;
        self.connection.applyAcknowledged = NO;
        self.connection.applyRevision = revision;
        self.connection.lastResponse = [self now];
        self.connection.pendingApply = @{@"version": @1, @"request": self.requestID, @"command": @"apply",
            @"expectedRevision": revision, @"view": self.viewID, @"applyGesture": gesture};
        NSUInteger generation = self.generation, token = self.activationToken;
        NSDictionary *command = self.connection.pendingApply;
        [self publish];
        if (generation == self.generation && token == self.activationToken && !self.cancelRequested &&
            !self.locallyFailed && !self.connection.timedOut && self.connection.pendingApply == command)
            [self send:command name:SSCommandName];
    }];
    return YES;
}
- (BOOL)canRetryVerification {
    if (!self.requestID || self.busy || self.locallyFailed || self.connection.timedOut || !self.connection.revision ||
        !SilentSnipReviewStateCanRetry(self.connection.state) || ![self.response[@"canRetryVerification"] isEqual:@YES]) return NO;
    return YES;
}
- (BOOL)retryVerification {
    if (![self canRetryVerification]) return NO;
    NSNumber *revision = self.connection.revision;
    [self prepareHostForUserRequest:^(NSError *error) {
        if (error || ![self.connection.revision isEqual:revision] || ![self canRetryVerification]) {
            self.localMessage = error.localizedDescription ?: @"The result changed. Review it in Final Cut Pro before clicking Retry Verification.";
            [self publish];
            return;
        }
        self.connection.pendingRetry = @{@"version": @1, @"request": self.requestID, @"command": @"retryVerification",
            @"expectedRevision": revision};
        self.connection.lastResponse = [self now];
        [self startPolling];
        NSUInteger generation = self.generation, token = self.activationToken;
        NSDictionary *command = self.connection.pendingRetry;
        [self publish];
        if (generation == self.generation && token == self.activationToken && !self.cancelRequested &&
            !self.locallyFailed && !self.connection.timedOut && self.connection.pendingRetry == command)
            [self send:command name:SSCommandName];
    }];
    return YES;
}
- (void)cancel {
    if (!self.requestID || self.cancelRequested || (SilentSnipReviewStateIsTerminal(self.connection.state) && !self.activationPending)) return;
    self.activationToken += 1;
    self.activationPending = NO;
    self.localMessage = nil;
    if (SilentSnipReviewStateIsTerminal(self.connection.state)) {
        self.localMessage = @"Verification retry canceled before it started.";
        [self publish];
        return;
    }
    self.cancelRequested = YES;
    self.connection.pendingSelection = nil;
    self.connection.pendingRetry = nil;
    self.connection.pendingApply = nil;
    self.connection.pendingSettings = nil;
    [self clearAutomaticUpdate];
    self.rejectedAutomaticSettingsEdit = nil;
    self.rejectedAutomaticSettingsSequence = nil;
    self.navigationRevision = nil;
    [self clearNativeNavigation];
    self.navigationAcknowledgment = nil;
    self.capabilityNonce = nil;
    if (!self.analysisDispatched) {
        self.generation += 1;
        self.connection.awaitingResponse = NO;
        self.connection.state = SilentSnipReviewStateCancelled;
        self.response = @{@"version": @1, @"request": self.requestID, @"revision": @0,
            @"state": @"cancelled", @"message": @"Analysis canceled before it started.", @"cuts": @[], @"canApply": @NO};
        self.cancelRequested = NO;
        [self.timer invalidate]; self.timer = nil;
        [self publish];
        return;
    }
    self.pendingCancel = @{@"version": @1, @"request": self.requestID, @"command": @"cancel"};
    [self send:self.pendingCancel name:SSCommandName];
    [self publish];
}
- (void)detach {
    self.generation += 1;
    [self.timer invalidate]; self.timer = nil;
    [self endObserving];
    self.connection = nil; self.response = nil;
    self.helperURL = nil; self.analysisURL = nil; self.capabilityNonce = nil; self.capabilityStarted = nil;
    self.helperLaunched = NO; self.cancelRequested = NO; self.locallyFailed = NO;
    self.pendingCancel = nil;
    self.analysisDispatched = NO;
    self.settingsDirty = NO; self.recoveryOnly = NO; self.recoveryPending = NO;
    self.settingsSequence = 0; self.settingsDraftGeneration = 0;
    [self clearAutomaticUpdate];
    self.rejectedAutomaticSettingsEdit = nil; self.rejectedAutomaticSettingsSequence = nil;
    self.navigationRevision = nil; self.recoveryGesture = nil;
    [self clearNativeNavigation];
    self.navigationAcknowledgment = nil;
    self.activationPending = NO; self.activationToken += 1; self.localMessage = nil;
}
- (void)dealloc {
    [_timer invalidate];
    if (_observing) [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}
@end
