#import "../Extension/SilentSnipAudioUnitFactory.h"
#import "../Extension/SilentSnipAudioUnit.h"
#import "../Extension/SilentSnipReviewConnection.h"

@interface SilentSnipAudioUnitFactory (Testing)
- (BOOL)openAnalysisURL:(NSURL *)URL;
- (void)reconnect:(NSNotification *)notification;
- (void)analyze:(id)sender;
- (void)refreshSettings;
- (BOOL)commitSettings;
- (void)sendCommand:(NSString *)command;
- (void)receive:(NSNotification *)notification;
- (void)sendPreviewCommand:(NSDictionary *)command;
- (void)pollStatus;
- (void)saveSettings:(id)sender;
- (void)restoreSavedSettings:(id)sender;
- (void)verifyExistingResult:(id)sender;
- (void)jumpToCut:(id)sender;
- (void)apply:(id)sender;
- (void)selectCuts:(id)sender;
- (void)updateMoreMenuVisibility;
- (void)retryVerification:(id)sender;
- (BOOL)restoreSettingsData:(NSData *)data;
@end

@interface TestFactory : SilentSnipAudioUnitFactory
@property(nonatomic) NSURL *openedURL;
@property(nonatomic) BOOL rejectLaunch;
@property(nonatomic) NSDictionary *previewCommand;
@property(nonatomic) NSMutableArray<NSString *> *commands;
@property(nonatomic) NSMutableArray<NSDictionary *> *packets;
@end
@implementation TestFactory
- (void)sendPreviewCommand:(NSDictionary *)command {
    self.previewCommand = command;
    if (!self.packets) self.packets = [NSMutableArray array];
    [self.packets addObject:command];
    [self sendCommand:command[@"command"]];
}
- (BOOL)openAnalysisURL:(NSURL *)URL { self.openedURL = URL; return !self.rejectLaunch; }
- (void)sendCommand:(NSString *)command {
    if (!self.commands) self.commands = [NSMutableArray array];
    [self.commands addObject:command];
}
@end

@interface StateObserver : NSObject
@property(nonatomic) NSUInteger changes;
@end
@implementation StateObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context { self.changes++; }
@end
static void require(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSString *json(NSDictionary *value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] encoding:NSUTF8StringEncoding];
}
static void deliver(TestFactory *factory, NSString *object) {
    [factory receive:[NSNotification notificationWithName:@"test" object:object]];
}
static SilentSnipReviewConnection *connection(TestFactory *factory) { return [factory valueForKey:@"connection"]; }
static void response(TestFactory *factory, NSInteger revision, NSString *state, NSDictionary *changes) {
    NSMutableDictionary *packet = [@{@"version":@1, @"request":connection(factory).requestID, @"revision":@(revision),
        @"state":state, @"message":@"Test response", @"canApply":@YES, @"previewVisible":@YES, @"canChangeSelection":@YES,
        @"cuts":@[@{@"id":@"cut-1", @"start":@"1s", @"end":@"2s", @"duration":@"1s", @"eligible":@YES, @"included":@YES}]} mutableCopy];
    [packet addEntriesFromDictionary:changes ?: @{}];
    deliver(factory, json(packet));
}
static NSUInteger commandCount(TestFactory *factory, NSString *command) {
    return [[factory.commands filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF == %@", command]] count];
}
static BOOL containsViewIdentifier(NSView *view, NSString *identifier) {
    if ([view.identifier isEqual:identifier]) return YES;
    for (NSView *child in view.subviews) if (containsViewIdentifier(child, identifier)) return YES;
    return NO;
}

/// Each scenario owns a fresh processor, private settings store, view and job.
@interface Fixture : NSObject
@property(nonatomic) TestFactory *factory;
@property(nonatomic) SilentSnipAudioUnit *unit;
@property(nonatomic) NSURL *settingsFile;
@property(nonatomic) NSArray<NSTextField *> *fields;
@property(nonatomic) NSButton *analyze;
@property(nonatomic) NSButton *apply;
- (void)review;
- (void)finish;
@end
@implementation Fixture
- (instancetype)init {
    if ((self = [super init])) {
        self.factory = [TestFactory new];
        AudioComponentDescription description = {'aufx','ctdn','Ctdn',0,0};
        NSError *error = nil;
        require([self.factory createAudioUnitWithComponentDescription:description error:&error] != nil && !error, @"Factory creates processor");
        self.settingsFile = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        self.unit = [[SilentSnipAudioUnit alloc] initWithComponentDescription:description options:0
            settingsStore:[[SilentSnipAudioLastUsedSettingsStore alloc] initWithFileURL:self.settingsFile] error:&error];
        require(self.unit && !error, @"Independent settings store");
        [self.factory setValue:self.unit forKey:@"audioUnit"];
        NSArray *values = @[@-26,@.75,@.125,@.25];
        for (NSUInteger i=0; i<4; i++) [self.unit.analysisParameterTree parameterWithAddress:i+1].value = [values[i] floatValue];
        (void)self.factory.view;
        self.fields = [self.factory valueForKey:@"fields"];
        self.analyze = [self.factory valueForKey:@"analyzeButton"];
        self.apply = [self.factory valueForKey:@"applyButton"];
    }
    return self;
}
- (void)review { [self.analyze performClick:nil]; response(self.factory, 1, @"review", nil); require(self.apply.enabled, @"Fixture reaches review"); }
- (void)finish { [self.factory viewDidDisappear]; [NSFileManager.defaultManager removeItemAtURL:self.settingsFile error:nil]; }
@end
static void run(NSString *name, void (^test)(Fixture *)) {
    @autoreleasepool {
        Fixture *fixture = [Fixture new];
        test(fixture);
        [fixture finish];
        printf("PASS: %s\n", name.UTF8String);
    }
}

int main(int argc, const char *argv[]) { @autoreleasepool {
    // Resolve the app beside this exact extension even when another copy is
    // registered. No application is launched by this test.
    NSURL *package = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL *app = [package URLByAppendingPathComponent:@"A copied Silent Snip.app" isDirectory:YES];
    NSURL *contents = [app URLByAppendingPathComponent:@"Contents" isDirectory:YES];
    NSURL *bundledExtension = [contents URLByAppendingPathComponent:@"PlugIns/SilentSnipAudio.appex" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:bundledExtension withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *infoFile = [bundledExtension URLByAppendingPathComponent:@"Contents/Info.plist"];
    [NSFileManager.defaultManager createDirectoryAtURL:infoFile.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *contract = [@{@"bundleIdentifier":@"local.silentsnip.app", @"executable":@"SilentSnip", @"enabled":@YES} mutableCopy];
    NSMutableDictionary *info = [@{@"CFBundleIdentifier":@"local.silentsnip.app.audio", @"SilentSnipContainingApp":contract} mutableCopy];
    [info writeToURL:infoFile atomically:YES];
    require([SilentSnipContainingApplicationURL(bundledExtension).path isEqual:app.path], @"Requests target their own app without reading sandbox-inaccessible parent metadata");
    contract[@"bundleIdentifier"] = @"other.app"; [info writeToURL:infoFile atomically:YES];
    require(!SilentSnipContainingApplicationURL(bundledExtension), @"Unrelated containing-app contracts are rejected");
    contract[@"bundleIdentifier"] = @"local.silentsnip.app"; contract[@"enabled"] = @NO; [info writeToURL:infoFile atomically:YES];
    require(!SilentSnipContainingApplicationURL(bundledExtension), @"An inert candidate cannot receive analysis requests");
    [info removeObjectForKey:@"SilentSnipContainingApp"]; [info writeToURL:infoFile atomically:YES];
    require(!SilentSnipContainingApplicationURL(bundledExtension), @"A legacy extension has no combined-app contract");
    require(!SilentSnipContainingApplicationURL(package), @"A loose extension has no containing app");
    [NSFileManager.defaultManager removeItemAtURL:package error:nil];
    puts("PASS: sandbox-safe copied app routing and invalid/candidate/legacy contract rejection");
    require(argc == 2, @"Pass extension Info.plist");
    NSDictionary *extension = [NSDictionary dictionaryWithContentsOfFile:@(argv[1])][@"NSExtension"];
    require([extension[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.AudioUnit-UI"], @"Custom effect window registration");
    require(NSClassFromString(extension[@"NSExtensionPrincipalClass"]) == SilentSnipAudioUnitFactory.class, @"Registered view factory");
    require([SilentSnipAudioUnitFactory isSubclassOfClass:AUViewController.class], @"Factory supplies the Audio Unit view");
    NSDictionary *component = [extension[@"NSExtensionAttributes"][@"AudioComponents"] firstObject];
    require([component[@"name"] isEqual:@"Silent Snip: Silent Snip Audio"] &&
            [component[@"description"] isEqual:@"Silent Snip Audio"], @"Silent Snip effect discovery names");
    require([component[@"manufacturer"] isEqual:@"Ctdn"] && [component[@"subtype"] isEqual:@"ctdn"],
            @"Existing projects retain the same Audio Unit identity");

    // Match AudioToolbox's XPC startup path with the main thread unavailable
    // until creation returns. Exercise both possible view/audio creation orders.
    for (NSNumber *preload in @[@NO, @YES]) {
        TestFactory *factory = [TestFactory new];
        if (preload.boolValue) (void)factory.view;
        dispatch_semaphore_t finished = dispatch_semaphore_create(0);
        __block SilentSnipAudioUnit *created = nil;
        __block NSError *creationError = nil;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            AudioComponentDescription description = {'aufx','ctdn','Ctdn',0,0};
            created = (SilentSnipAudioUnit *)[factory createAudioUnitWithComponentDescription:description error:&creationError];
            [created.analysisParameterTree parameterWithAddress:1].value = -37;
            dispatch_semaphore_signal(finished);
        });
        require(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
            @"Background creation returns without waiting for the main thread");
        require(created && !creationError && factory.isViewLoaded == preload.boolValue,
            @"Background creation succeeds without loading the view");
        __block BOOL drained = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ drained = YES; });
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!drained && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        require(drained && [factory valueForKey:@"audioUnit"] == created,
            @"Main thread connects the returned processor");
        (void)factory.view;
        NSArray<NSTextField *> *fields = [factory valueForKey:@"fields"];
        require(fields[0].doubleValue == -37 && [(NSButton *)[factory valueForKey:@"analyzeButton"] isEnabled] &&
            NSEqualSizes(factory.preferredContentSize, NSMakeSize(680, 476)),
            @"Both startup orders refresh settings, actions and stable review-ready size on the main thread");
        [factory viewDidDisappear];
    }
    puts("PASS: background AudioToolbox creation before and after view loading");

    run(@"late host changes update idle Controls", ^(Fixture *f) {
        StateObserver *observer = [StateObserver new];
        [f.unit addObserver:observer forKeyPath:@"fullStateForDocument" options:0 context:NULL];
        [f.unit.parameterTree parameterWithAddress:1].value = -37.25f;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (f.fields[0].floatValue != -37.25f && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(f.fields[0].floatValue == -37.25f, @"Inspector edits refresh the idle view after its initial appearance");
        require(observer.changes > 0, @"Host edits also notify document-state persistence");
        [f.unit removeObserver:observer forKeyPath:@"fullStateForDocument"];
        require(!f.factory.openedURL, @"Host parameter observation never starts an analysis");
    });

    run(@"busy Controls still publish native parameter state without replacing review fields", ^(Fixture *f) {
        [f review];
        float submitted = f.fields[0].floatValue;
        connection(f.factory).operationBusy = YES;
        StateObserver *observer = [StateObserver new];
        [f.unit addObserver:observer forKeyPath:@"fullStateForDocument" options:0 context:NULL];
        [f.unit.parameterTree parameterWithAddress:1].value = -37.25f;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (!observer.changes && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(observer.changes > 0 && f.fields[0].floatValue == submitted,
            @"Native settings can persist during verification while the displayed review remains immutable");
        [f.unit removeObserver:observer forKeyPath:@"fullStateForDocument"];
    });

    run(@"state persistence and native legacy compatibility", ^(Fixture *f) {
        require(f.unit.parameterTree.allParameters.count == 4 && f.fields.count == 4, @"Four settings exposed to the host and Controls");
        NSDictionary *saved = f.unit.fullStateForDocument;
        [f.unit.parameterTree parameterWithAddress:1].value = -10;
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -10, @"Inspector and Controls use the same parameter values");
        f.unit.fullStateForDocument = saved;
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -26, @"Private values survive document state restore");
        NSError *error = nil;
        NSXMLDocument *fixture = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"Tests/SilentSnipCoreTests/Fixtures/final-cut-12-3-native-audio.fcpxml"] options:NSXMLNodeLoadExternalEntitiesNever error:&error];
        NSString *encoded = [[fixture nodesForXPath:@"//filter-audio/data[@key='effectState']" error:&error].firstObject stringValue];
        NSData *archive = [[NSData alloc] initWithBase64EncodedString:encoded options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSKeyedUnarchiver *decoder = [[NSKeyedUnarchiver alloc] initForReadingFromData:archive error:&error];
        NSDictionary *legacy = [decoder decodeObjectOfClasses:[NSSet setWithArray:@[NSDictionary.class,NSString.class,NSNumber.class,NSData.class]] forKey:@"effectState"];
        [decoder finishDecoding];
        require(legacy && !error, @"Real native legacy state decoded");
        f.unit.fullStateForDocument = legacy;
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -32, @"Native preset restores through private codec");
        require([f.unit.fullStateForDocument[@"data"] isEqual:legacy[@"data"]], @"Native state bytes unchanged");
    });

    run(@"settings validation, document notification and exact Float32 precision", ^(Fixture *f) {
        require(!f.apply.enabled && !f.factory.openedURL, @"Opening view performs no action");
        require(!containsViewIdentifier(f.factory.view, @"silentsnip.preview") && [[f.factory valueForKey:@"cancelButton"] isHidden],
            @"Opening view hides actions that need an active analysis");
        StateObserver *observer = [StateObserver new];
        [f.unit addObserver:observer forKeyPath:@"allParameterValues" options:0 context:NULL];
        f.fields[0].stringValue = @"-20 trailing";
        [f.analyze performClick:nil];
        require(!f.factory.openedURL && observer.changes == 0, @"Invalid text never commits or launches");
        f.fields[0].stringValue = @"-20";
        [f.analyze performClick:nil];
        require([f.factory.openedURL.absoluteString containsString:@"threshold=-20"] && observer.changes > 0, @"Analyze sends exact values and notifies host to save state");
        NSUInteger beforeUnchangedCommit = observer.changes;
        require([f.factory commitSettings] && observer.changes > beforeUnchangedCommit,
            @"Explicit save materializes host state even when the submitted values are unchanged");
        [f.unit removeObserver:observer forKeyPath:@"allParameterValues"];
        for (NSNumber *number in @[@0.00123456789f, @1e-9f, @1.40129846e-45f, @0.1f, @2.f]) {
            [f.unit.analysisParameterTree parameterWithAddress:3].value = number.floatValue;
            [f.factory refreshSettings];
            require([f.factory commitSettings] && [f.unit.analysisParameterTree parameterWithAddress:3].value == number.floatValue, @"Formatter preserves exact Float32 padding");
        }
        [f.unit.analysisParameterTree parameterWithAddress:2].value = 0.0001f;
        [f.factory refreshSettings];
        require([f.factory commitSettings] && [f.unit.analysisParameterTree parameterWithAddress:2].value == 0.0001f, @"Minimum boundary survives formatting");
        NSNumberFormatter *display = [NSNumberFormatter new];
        display.numberStyle = NSNumberFormatterDecimalStyle;
        display.usesSignificantDigits = YES;
        display.minimumSignificantDigits = 1;
        display.maximumSignificantDigits = 1;
        require([f.fields[1].stringValue isEqual:[display stringFromNumber:@0.0001]], @"Minimum decimal does not expose Float32 noise");
        f.fields[1].stringValue = @"0.00009";
        require(![f.factory commitSettings], @"Below-minimum value rejected");
    });

    run(@"Analyze connection, duplicate clicks, launch failure and timeout", ^(Fixture *f) {
        f.factory.rejectLaunch = YES; [f.factory analyze:nil];
        require(f.analyze.enabled && !connection(f.factory).awaitingResponse, @"Launch failure releases guard");
        f.factory.rejectLaunch = NO; [f.factory analyze:nil];
        NSURL *launch = f.factory.openedURL; NSUInteger commands = f.factory.commands.count;
        [f.analyze performClick:nil]; [f.factory analyze:nil]; [f.factory refreshSettings];
        require([f.factory.openedURL isEqual:launch] && f.factory.commands.count == commands && !f.analyze.enabled, @"Pending Analyze cannot be replaced by clicks or view refresh");
        NSButton *save = [f.factory valueForKey:@"saveButton"];
        f.fields[0].stringValue = @"-30"; [f.factory saveSettings:nil];
        require(!save.enabled && [f.unit.analysisParameterTree parameterWithAddress:1].value == -26,
            @"Save cannot change controller settings while Analyze is connecting");
        f.fields[0].stringValue = @"-26";
        require(commandCount(f.factory, @"apply") == 0, @"Analyze never applies");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16]; [f.factory pollStatus];
        require(f.analyze.enabled && save.enabled && !connection(f.factory).awaitingResponse, @"Connection timeout releases controls");
        [f.factory analyze:nil]; require(!f.analyze.enabled, @"Can retry after timeout");
        response(f.factory, 1, @"unavailable", nil); require(!f.apply.enabled, @"Unavailable cannot authorize Apply");
    });

    run(@"unchanged heartbeats preserve rows and reject older responses", ^(Fixture *f) {
        [f review];
        NSArray *rows = [f.factory valueForKey:@"cutRows"];
        StateObserver *observer = [StateObserver new];
        [f.factory addObserver:observer forKeyPath:@"cutRows" options:0 context:NULL];
        NSString *cached = connection(f.factory).lastResponseObject;
        for (NSUInteger i=0; i<20; i++) {
            connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-14];
            deliver(f.factory, cached); [f.factory pollStatus];
        }
        deliver(f.factory, [cached stringByAppendingString:@"\n"]);
        response(f.factory, 0, @"review", nil);
        require(observer.changes == 0 && [f.factory valueForKey:@"cutRows"] == rows && f.apply.enabled, @"Identical/equal/older revisions do not rebuild rows or time out");
        [f.factory removeObserver:observer forKeyPath:@"cutRows"];
    });

    run(@"review has no hide-preview control", ^(Fixture *f) {
        [f review];
        require(!containsViewIdentifier(f.factory.view, @"silentsnip.preview") && f.apply.enabled,
            @"Valid guidelines cannot be hidden from Controls");
    });

    run(@"Apply replay, retransmission, acknowledgment and uncertain timeout", ^(Fixture *f) {
        [f review]; NSString *review = connection(f.factory).lastResponseObject;
        require([f.apply.title isEqual:@"Apply 1 Cut"], @"Review uses a counted action title");
        [f.apply performClick:nil];
        require(commandCount(f.factory, @"apply") == 1 && !f.apply.enabled && !f.analyze.enabled, @"Apply sent exactly once");
        NSDictionary *apply = f.factory.previewCommand;
        require([apply[@"expectedRevision"] isEqual:@1] && [apply[@"view"] isKindOfClass:NSString.class] &&
            [apply[@"applyGesture"] isKindOfClass:NSString.class] &&
            [f.apply.identifier isEqual:[@"silentsnip.apply.requested." stringByAppendingString:apply[@"applyGesture"]]] && !f.apply.hidden &&
            [f.apply.title isEqual:@"Apply 1 Cut"],
            @"A counted Apply button carries the fresh gesture independently of its title");
        NSDate *before = [NSDate dateWithTimeIntervalSinceNow:-5]; connection(f.factory).lastResponse = before;
        deliver(f.factory, review); [f.apply performClick:nil];
        require([connection(f.factory).lastResponse isEqual:before] && !connection(f.factory).applyAcknowledged && commandCount(f.factory, @"apply") == 1, @"Old review neither acknowledges nor postpones Apply timeout");
        [f.factory pollStatus]; require(commandCount(f.factory, @"apply") == 2 &&
            [f.factory.previewCommand isEqual:apply], @"Unacknowledged Apply retries the same gesture and revision");
        response(f.factory, 2, @"applying", @{@"canApply":@NO});
        require([f.apply.identifier isEqual:@"silentsnip.apply"] && connection(f.factory).pendingApply == nil,
            @"Acknowledgment consumes the Apply gesture");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16];
        deliver(f.factory, connection(f.factory).lastResponseObject); [f.factory pollStatus];
        require(commandCount(f.factory, @"apply") == 2 && connection(f.factory).applying, @"Acknowledged Apply only polls and remains alive on heartbeats");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16]; [f.factory pollStatus];
        require(f.analyze.enabled && !f.apply.enabled && !connection(f.factory).applying, @"Uncertain timeout consumes local review");
    });

    run(@"plural counted Apply exposes the same confirmation contract", ^(Fixture *f) {
        [f review];
        NSMutableArray *cuts = [NSMutableArray array];
        for (NSUInteger i = 0; i < 35; i++) [cuts addObject:@{
            @"id":[NSString stringWithFormat:@"cut-%lu", (unsigned long)i + 1],
            @"start":@"1s", @"end":@"2s", @"duration":@"1s", @"eligible":@YES, @"included":@YES}];
        response(f.factory, 2, @"review", @{@"cuts":cuts});
        require(f.apply.enabled && [f.apply.title isEqual:@"Apply 35 Cuts"], @"Plural label reflects selected cuts");
        [f.apply performClick:nil];
        NSDictionary *apply = f.factory.previewCommand;
        require([apply[@"expectedRevision"] isEqual:@2] && !f.apply.enabled && !f.apply.hidden &&
            [f.apply.title isEqual:@"Apply 35 Cuts"] &&
            [f.apply.identifier isEqual:[@"silentsnip.apply.requested." stringByAppendingString:apply[@"applyGesture"]]],
            @"The plural counted label preserves the fresh disabled gesture required by the helper");
    });

    run(@"early preview rows stay read-only until cleanup completes", ^(Fixture *f) {
        [f review];
        response(f.factory, 2, @"analyzing", @{@"canApply":@NO, @"canChangeSelection":@NO, @"message":@"Preview ready. Finishing cleanup…"});
        require([(NSArray *)[f.factory valueForKey:@"cutRows"] count] > 0, @"Early preview keeps its cut rows");
        require(!f.apply.enabled && !f.analyze.enabled, @"Cleanup owns the operation while preview is displayed");
        response(f.factory, 3, @"review", nil);
        require(f.apply.enabled && f.analyze.enabled, @"Completed cleanup enables the normal review");
    });

    run(@"returning Controls gets a fresh reply deadline", ^(Fixture *f) {
        [f review];
        [f.factory viewDidDisappear];
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-120];
        [f.factory viewDidAppear];
        require(!connection(f.factory).timedOut && f.apply.enabled, @"Hidden-view time is not a failed reconnect");
        response(f.factory, 2, @"failed", @{@"message":@"Rendered project verification failed.", @"canApply":@NO, @"cuts":@[]});
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-120];
        [f.factory pollStatus];
        require([(NSString *)[f.factory valueForKey:@"statusDetails"] isEqual:@"Rendered project verification failed."],
            @"Terminal error is never overwritten by an idle heartbeat timeout");
        require(!f.apply.enabled &&
            [[(NSTextField *)[f.factory valueForKey:@"summaryLabel"] stringValue] isEqual:@"Review the error details before continuing."],
            @"Failed analysis points to the retained details");
    });

    run(@"a delayed failure replaces timeout while expired Apply remains consumed", ^(Fixture *f) {
        [f review]; [f.apply performClick:nil];
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16];
        [f.factory pollStatus];
        require(connection(f.factory).timedOut && [(NSTimer *)[f.factory valueForKey:@"pollTimer"] isValid], @"Timeout keeps status recovery alive");
        NSUInteger applies = commandCount(f.factory, @"apply");
        [f.factory pollStatus];
        require(commandCount(f.factory, @"apply") == applies, @"Expired Apply is never retransmitted");
        response(f.factory, 3, @"failed", @{@"message":@"The render could not be verified.", @"canApply":@NO, @"cuts":@[], @"canRetryVerification":@YES});
        require([(NSString *)[f.factory valueForKey:@"statusDetails"] isEqual:@"The render could not be verified."], @"Late real failure replaces provisional timeout");
        [(NSButton *)[f.factory valueForKey:@"retryButton"] performClick:nil];
        require(!connection(f.factory).timedOut && connection(f.factory).pendingRetry, @"Explicit verification retry gets its own deadline");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16];
        [f.factory pollStatus];
        require(connection(f.factory).timedOut && !connection(f.factory).pendingRetry, @"Lost verification retry can time out again");
        [f.analyze performClick:nil];
        require(!connection(f.factory).timedOut && !connection(f.factory).state, @"New Analyze resets all prior connection state");
    });

    run(@"completed Apply cannot revive its consumed plan", ^(Fixture *f) {
        [f review]; [f.apply performClick:nil]; response(f.factory, 2, @"completed", @{@"canApply":@NO});
        require(f.analyze.enabled && !f.apply.enabled, @"Completion allows new analysis only");
        response(f.factory, 1, @"review", nil); [f.apply performClick:nil];
        require(commandCount(f.factory, @"apply") == 1, @"Old review cannot replay Apply");
    });

    run(@"selection waits for exact acknowledgments", ^(Fixture *f) {
        [f review];
        require(!containsViewIdentifier(f.factory.view, @"silentsnip.preview"), @"Review has no hide-preview control");
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        NSButton *cut = (NSButton *)[(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        require(cut.enabled && cut.state == NSControlStateValueOn, @"Eligible cuts have checkboxes");
        [cut performClick:nil];
        require([f.factory.previewCommand[@"cutID"] isEqual:@"cut-1"] && ![f.factory.previewCommand[@"included"] boolValue] && !f.apply.enabled, @"Exact selection sent and Apply blocked");
        require([f.factory.previewCommand[@"expectedRevision"] isEqual:@1], @"Selection names the review revision");
        deliver(f.factory, connection(f.factory).lastResponseObject);
        response(f.factory, 2, @"review", nil);
        require(connection(f.factory).pendingSelection != nil && !f.apply.enabled, @"Equal and unrelated revisions cannot acknowledge selection");
        response(f.factory, 3, @"review", @{@"canApply":@NO, @"cuts":@[@{@"id":@"cut-1", @"start":@"1s", @"end":@"2s", @"duration":@"1s", @"eligible":@YES, @"included":@NO}]});
        require(!connection(f.factory).pendingSelection && !f.apply.enabled, @"Deselection acknowledged");
        [f.factory selectCuts:[f.factory valueForKey:@"selectAllItem"]];
        require([f.factory.previewCommand[@"command"] isEqual:@"selectAll"], @"Select All uses helper rules");
        response(f.factory, 4, @"review", nil); require(f.apply.enabled, @"Select All acknowledged");
    });

    run(@"stable host size reserves an uncluttered review area", ^(Fixture *f) {
        NSView *review = [f.factory valueForKey:@"reviewArea"];
        NSView *heading = [f.factory valueForKey:@"reviewHeading"];
        NSView *table = [f.factory valueForKey:@"reviewScroll"];
        NSTextField *empty = [f.factory valueForKey:@"emptyReviewLabel"];
        require(!review.hidden && !heading.hidden && table.hidden && !empty.hidden && !f.analyze.hidden,
            @"Idle Controls reserves review space with one native empty-state message");
        NSSize initial = f.factory.preferredContentSize;
        [f review];
        require(!review.hidden && !heading.hidden && !table.hidden && empty.hidden &&
            NSEqualSizes(initial, f.factory.preferredContentSize),
            @"Returned cuts replace the placeholder without depending on host window resizing");
        response(f.factory, 2, @"review", @{@"canApply":@NO, @"cuts":@[@{@"id":@"cut-1", @"start":@"1s", @"end":@"2s", @"duration":@"1s", @"eligible":@YES, @"included":@NO}]});
        require(!table.hidden && !f.apply.enabled,
            @"Deselecting all cuts keeps the list available");
        response(f.factory, 3, @"review", @{@"canApply":@NO, @"cuts":@[]});
        require(table.hidden && !empty.hidden && [empty.stringValue isEqual:@"No cuts to review"] &&
            NSEqualSizes(initial, f.factory.preferredContentSize),
            @"An empty result explains its state without collapsing the host window");
    });

    run(@"review numbers stay aligned when earlier cuts are excluded", ^(Fixture *f) {
        [f review];
        response(f.factory, 2, @"review", @{@"cuts":@[
            @{@"id":@"cut-1", @"start":@"1s", @"end":@"2s", @"duration":@"1s", @"eligible":@YES, @"included":@NO},
            @{@"id":@"cut-2", @"start":@"3s", @"end":@"4s", @"duration":@"1s", @"eligible":@YES, @"included":@YES}]});
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        NSButton *first = (NSButton *)[(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        NSButton *second = (NSButton *)[(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[0] row:1];
        require([first.title hasPrefix:@"1.  "] && first.state == NSControlStateValueOff &&
            [second.title hasPrefix:@"2.  "] && second.state == NSControlStateValueOn,
            @"Row numbers refer to full review order rather than only checked cuts");
    });

    run(@"review presents scannable cuts and the current primary action", ^(Fixture *f) {
        require([f.analyze.title isEqual:@"Analyze Audio"] && !f.analyze.hidden && f.apply.hidden,
            @"Analyze is the only initial footer action");
        [f review];
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        require(table.tableColumns.count == 2 && table.headerView != nil &&
            !f.analyze.hidden && !f.apply.hidden, @"Review keeps reanalysis beside the primary Apply action");
        require(!containsViewIdentifier(f.factory.view, @"silentsnip.preview"), @"Guidelines stay on during review");
        [f.factory updateMoreMenuVisibility];
        NSMenu *more = [f.factory valueForKey:@"moreMenu"];
        [more update];
        require(!more.itemArray[0].hidden && !more.itemArray[2].hidden && more.itemArray[2].enabled,
            @"Reanalysis and bulk selection are available in More");
        NSButton *range = (NSButton *)[(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        NSView *durationCell = [(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[1] row:0];
        NSTextField *duration = durationCell.subviews.firstObject;
        require([range.title isEqual:@"1.  1s  →  2s"] && [duration.stringValue isEqual:@"1s"], @"The numbered range retains both edges and duration");
        response(f.factory, 2, @"review", @{@"cuts":@[@{@"id":@"cut-1", @"start":@"1s", @"end":@"2s", @"duration":@"1s",
            @"eligible":@NO, @"included":@NO, @"reason":@"Protected by a transition"}]});
        NSStackView *restricted = (NSStackView *)[(id<NSTableViewDelegate>)f.factory tableView:table viewForTableColumn:table.tableColumns[0] row:0];
        NSTextField *note = (NSTextField *)restricted.arrangedSubviews.lastObject;
        require([note.stringValue isEqual:@"Protected by a transition"] && !f.apply.enabled &&
            !f.analyze.hidden && f.apply.hidden, @"Unavailable reason stays in the review row");
    });

    run(@"navigation and lost verification retry delivery", ^(Fixture *f) {
        [f review]; response(f.factory, 2, @"review", @{@"canHighlight":@YES});
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [f.factory jumpToCut:nil];
        require([f.factory.previewCommand[@"command"] isEqual:@"highlight"] && [f.factory.previewCommand[@"cutID"] isEqual:@"cut-1"] &&
            [f.factory.previewCommand[@"expectedRevision"] isEqual:@2], @"Navigation sends selected identity and revision");
        response(f.factory, 3, @"failed", @{@"canRetryVerification":@YES});
        require(![(NSButton *)[f.factory valueForKey:@"retryButton"] isHidden] && f.analyze.hidden && f.apply.hidden,
            @"Retry is the sole primary action after a retryable failure");
        [f.factory retryVerification:nil]; [f.factory retryVerification:nil];
        require(commandCount(f.factory, @"retryVerification") == 1, @"Retry rejects duplicate clicks");
        NSDictionary *retry = f.factory.previewCommand;
        require([retry[@"expectedRevision"] isEqual:@3], @"Retry is bound to failed revision");
        deliver(f.factory, connection(f.factory).lastResponseObject); [f.factory pollStatus];
        require([f.factory.previewCommand isEqual:retry] && commandCount(f.factory, @"retryVerification") == 2, @"Dropped retry is retransmitted unchanged");
        response(f.factory, 4, @"verifying", nil); [f.factory pollStatus];
        require(!connection(f.factory).pendingRetry && commandCount(f.factory, @"retryVerification") == 2, @"Acknowledged retry stops retransmission");
        response(f.factory, 5, @"failed", @{@"canRetryVerification":@YES});
        require([(NSButton *)[f.factory valueForKey:@"retryButton"] isEnabled], @"New failed attempt is explicitly retryable");
    });

    run(@"explicit local cut updates retain analyzed audio without a helper relaunch", ^(Fixture *f) {
        [f.factory analyze:nil];
        response(f.factory, 1, @"review", @{@"canUpdateCuts":@YES});
        NSURL *launched = f.factory.openedURL;
        f.fields[1].stringValue = @"0.2";
        [f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[1]]];
        require([f.analyze.title isEqual:@"Update Cuts"] && !f.apply.enabled, @"Draft disables Apply and exposes explicit Update Cuts");
        require(commandCount(f.factory, @"recalculate") == 0 && commandCount(f.factory, @"cancel") == 0,
            @"Typing retains audio without analysis or cancellation");
        [f.factory controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:f.fields[1]]];
        require(commandCount(f.factory, @"recalculate") == 0, @"Field blur never starts cut calculation");
        [f.factory analyze:nil];
        NSDictionary *update = f.factory.previewCommand;
        require([update[@"command"] isEqual:@"recalculate"] && [update[@"localPreview"] isEqual:@YES], @"Explicit click requests a local preview");
        require([f.factory.openedURL isEqual:launched] && commandCount(f.factory, @"cancel") == 0,
            @"Local update does not launch another audio Analyze");
        require([f.analyze.identifier hasPrefix:@"silentsnip.preview.requested."] && !f.analyze.enabled,
            @"The disabled native button carries the exact preview gesture");
        response(f.factory, 2, @"review", @{@"canUpdateCuts":@YES, @"usesAudioSnapshot":@YES, @"settingsEdit":update[@"settingsEdit"]});
        require(f.apply.enabled && [f.analyze.identifier isEqual:@"silentsnip.analyze"], @"Acknowledged snapshot preview can request verified Apply");
        NSButton *refresh = [f.factory valueForKey:@"refreshAudioButton"];
        [f.factory.view setFrameSize:f.factory.preferredContentSize];
        [f.factory.view layoutSubtreeIfNeeded];
        require(!refresh.hidden && refresh.enabled && NSContainsRect(f.factory.view.bounds, [refresh convertRect:refresh.bounds toView:f.factory.view]),
            @"Fresh audio analysis stays visible beside Update Cuts");
        require(!NSIntersectsRect([refresh convertRect:refresh.bounds toView:f.factory.view], [f.analyze convertRect:f.analyze.bounds toView:f.factory.view]),
            @"The two explicit audio and cut actions do not overlap");
        [refresh performClick:nil];
        require(![f.factory.openedURL isEqual:launched] && commandCount(f.factory, @"cancel") == 1,
            @"Analyze Audio explicitly starts a fresh rendered analysis");
    });

    run(@"settings and output changes invalidate old reviews", ^(Fixture *f) {
        [f review]; f.fields[0].stringValue = @"-21";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[0]]];
        response(f.factory, 2, @"review", nil); require(!f.apply.enabled, @"Edited settings cannot use old plan");
        NSPopUpButton *output = [f.factory valueForKey:@"outputMode"];
        require(output.numberOfItems == 2, @"Two explicit output modes");
        [output selectItemAtIndex:1]; [NSApp sendAction:output.action to:output.target from:output];
        require(!f.apply.enabled, @"Changing output invalidates review");
        [f.analyze performClick:nil]; require([f.factory.openedURL.absoluteString containsString:@"output=gaps"], @"Gap mode bound to request");
        response(f.factory, 1, @"review", nil); [f.apply performClick:nil]; require(!output.enabled, @"Output locked during Apply");
    });

    run(@"recreated Controls reconnect without opening another window or starting analysis", ^(Fixture *f) {
        NSString *view = [f.factory valueForKey:@"viewID"], *request = NSUUID.UUID.UUIDString;
        NSDictionary *packet = @{@"version":@1, @"view":view, @"request":request, @"output":@"gaps",
            @"settings":@{@"threshold":@-41.25, @"minimum":@8, @"before":@1.5, @"after":@2}};
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(packet)]];
        require([connection(f.factory).requestID isEqual:request] && commandCount(f.factory, @"status") == 1,
            @"A recreated view queries the exact retained request");
        require(!f.apply.enabled && !f.analyze.enabled && !f.factory.openedURL, @"Reconnect neither starts analysis nor enables Apply before status");
        require(f.fields[0].doubleValue == -41.25 && f.fields[1].doubleValue == 8 &&
            [(NSPopUpButton *)[f.factory valueForKey:@"outputMode"] indexOfSelectedItem] == 1, @"Submitted settings and output restored");
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -26, @"Reconnection does not rewrite host document state");
        response(f.factory, 9, @"review", @{@"canCancel":@YES});
        require(f.apply.enabled, @"Retained review becomes actionable in Controls");
        [f.factory viewDidDisappear]; [f.factory viewDidAppear];
        require(f.fields[0].doubleValue == -41.25, @"Reappearing does not overwrite submitted review settings with host defaults");
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(packet)]];
        require([connection(f.factory).revision isEqual:@9], @"Duplicate handshake cannot reset accepted revision");
        NSButton *cancel = [f.factory valueForKey:@"cancelButton"];
        [cancel performClick:nil]; require(commandCount(f.factory, @"cancel") == 1, @"Single Controls window can cancel the helper job");
    });

    run(@"reconnect rejects unrelated malformed or edited views", ^(Fixture *f) {
        NSString *view = [f.factory valueForKey:@"viewID"];
        NSDictionary *valid = @{@"version":@1, @"view":view, @"request":NSUUID.UUID.UUIDString, @"output":@"remove",
            @"settings":@{@"threshold":@-40, @"minimum":@.1, @"before":@0, @"after":@0}};
        for (NSDictionary *change in @[@{@"view":NSUUID.UUID.UUIDString}, @{@"request":@"bad"}, @{@"version":@YES},
            @{@"output":@"unknown"}, @{@"settings":@{@"threshold":@YES, @"minimum":@.5, @"before":@0, @"after":@0}},
            @{@"settings":@{@"threshold":@-40, @"minimum":@11, @"before":@0, @"after":@0}}]) {
            NSMutableDictionary *packet = valid.mutableCopy; [packet addEntriesFromDictionary:change];
            [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(packet)]];
            require(!connection(f.factory).requestID, @"Invalid handshake rejected");
        }
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(valid) userInfo:@{@"unexpected":@YES}]];
        require(!connection(f.factory).requestID, @"Wrong envelope rejected");
        [f.factory setValue:@YES forKey:@"settingsDirty"];
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(valid)]];
        require(!connection(f.factory).requestID, @"Reconnection never replaces user edits");
        [f.factory setValue:@NO forKey:@"settingsDirty"];
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(valid)]];
        require(connection(f.factory).requestID != nil, @"Minimum-boundary settings reconnect");
    });

    run(@"manual settings recovery and compact window layout", ^(Fixture *f) {
        [f review];
        NSData *settings = [json(@{@"thresholdDBFS":@-32, @"minimumSilenceDuration":@.75, @"beforeSpeechPadding":@.125, @"afterSpeechPadding":@.25}) dataUsingEncoding:NSUTF8StringEncoding];
        require([f.factory restoreSettingsData:settings] && f.fields[0].doubleValue == -32 && !f.apply.enabled, @"Result settings restore and invalidate review");
        require(![f.factory restoreSettingsData:[@"{\"thresholdDBFS\":true}" dataUsingEncoding:NSUTF8StringEncoding]], @"Malformed settings rejected");
        f.fields[0].stringValue = @"-29"; NSURL *launch = f.factory.openedURL; [f.factory saveSettings:nil];
        NSTextField *status = [f.factory valueForKey:@"statusLabel"];
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -29 && [status.stringValue isEqual:@"Settings saved. Analyze again to update the cuts."] && [launch isEqual:f.factory.openedURL] && !f.apply.enabled, @"Save commits without analyzing or reviving Apply");
        f.fields[0].stringValue = @"invalid"; [f.factory saveSettings:nil];
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -29, @"Invalid automated save preserves values");
        status.stringValue = [@"Long recovery notice. " stringByPaddingToLength:1200 withString:@"More information. " startingAtIndex:0];
        [f.factory.view setFrameSize:f.factory.preferredContentSize];
        [f.factory.view layoutSubtreeIfNeeded];
        require(!f.apply.enabled && !f.apply.hidden && NSContainsRect(f.factory.view.bounds, [f.analyze convertRect:f.analyze.bounds toView:f.factory.view]),
            @"The relevant footer action stays visible with a long notice");
        NSButton *more = [f.factory valueForKey:@"moreButton"];
        require(NSContainsRect(f.factory.view.bounds, [more convertRect:more.bounds toView:f.factory.view]), @"More actions stay inside the single window");
        require([more.identifier isEqual:[@"silentsnip.review.reconnect." stringByAppendingString:[f.factory valueForKey:@"viewID"]]] &&
            !more.hidden && [more isKindOfClass:NSButton.class], @"Reconnection keeps an always-visible native button anchor");
        NSMenu *menu = [f.factory valueForKey:@"moreMenu"];
        [f.factory updateMoreMenuVisibility];
        require(menu.numberOfItems == 9 && menu.itemArray[5].action == @selector(restoreSavedSettings:) &&
            menu.itemArray[6].action == @selector(verifyExistingResult:) && menu.itemArray[0].hidden,
            @"Recovery actions remain available while review actions are hidden");
        [menu update];
        require(menu.itemArray[5].enabled && menu.itemArray[6].enabled, @"Recovery menu is available while idle");
        connection(f.factory).operationBusy = YES; [menu update];
        require(!menu.itemArray[5].enabled && !menu.itemArray[6].enabled, @"Recovery menu cannot interrupt an active operation");
        f.fields[0].stringValue = @"-29"; [f.analyze performClick:nil];
        response(f.factory, 2, @"analyzing", @{@"canCancel":@YES, @"progress":@0.5, @"message":status.stringValue});
        [f.factory.view setFrameSize:f.factory.preferredContentSize];
        [f.factory.view layoutSubtreeIfNeeded];
        require(f.factory.view.frame.size.width <= 680 && f.factory.view.frame.size.height <= 656,
            @"Progress and long notices fit the requested single-window size");
        NSView *results = [f.factory valueForKey:@"resultsView"];
        require(!NSIntersectsRect([results convertRect:results.bounds toView:f.factory.view], [f.analyze convertRect:f.analyze.bounds toView:f.factory.view]),
            @"Scrollable review does not overlap the fixed footer");
    });

    run(@"fixed-size AU hosts can scroll to every review control", ^(Fixture *f) {
        [f review];
        NSView *host = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 580, 220)];
        NSView *view = f.factory.view;
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:view];
        [NSLayoutConstraint activateConstraints:@[
            [host.widthAnchor constraintEqualToConstant:580],
            [host.heightAnchor constraintEqualToConstant:220],
            [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [view.topAnchor constraintEqualToAnchor:host.topAnchor],
            [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
        ]];
        [host layoutSubtreeIfNeeded];
        NSScrollView *inspector = [f.factory valueForKey:@"inspectorScroll"];
        NSView *document = inspector.documentView;
        NSView *review = [f.factory valueForKey:@"reviewArea"];
        NSRect reviewRect = [review convertRect:review.bounds toView:document];
        require(document.frame.size.height > inspector.contentView.bounds.size.height &&
            NSMaxY(reviewRect) <= NSHeight(document.bounds) + 1,
            @"The review belongs to a full-height scrolling document, even when Final Cut ignores preferredContentSize");
        [review scrollRectToVisible:review.bounds];
        [inspector reflectScrolledClipView:inspector.contentView];
        NSPoint scrolled = inspector.contentView.bounds.origin;
        [host layoutSubtreeIfNeeded];
        require(scrolled.y > 0 && NSEqualPoints(scrolled, inspector.contentView.bounds.origin) &&
            NSIntersectsRect(reviewRect, inspector.documentVisibleRect),
            @"Scrolling to the cut list must persist through layout instead of snapping back to Detection");
        [document scrollRectToVisible:NSMakeRect(0, 0, 1, 1)];
        [host layoutSubtreeIfNeeded];
        require(inspector.contentView.bounds.origin.y < scrolled.y,
            @"Detection remains reachable after reviewing cuts");
    });

    run(@"always-visible detection and full status details", ^(Fixture *f) {
        require(![(NSView *)[f.factory valueForKey:@"settingsView"] isHidden] && f.fields.count == 4 &&
            [[(NSButton *)[f.factory valueForKey:@"saveButton"] identifier] isEqual:@"silentsnip.saveSettings"],
            @"All four settings and the original recovery Save action remain visible");
        [f review];
        NSString *message = @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts. Threshold uses RMS. Original audio has processing effects.";
        response(f.factory, 2, @"review", @{@"message":message});
        require([(NSString *)[f.factory valueForKey:@"statusDetails"] isEqual:message] &&
            [[(NSTextField *)[f.factory valueForKey:@"statusLabel"] stringValue] length] < message.length,
            @"Successful technical details remain available behind the concise status");
        NSString *snapshot = @"Cuts use the last analyzed audio. Apply verifies current audio before editing. Use Analyze Audio Again after changing volume or effects.";
        response(f.factory, 3, @"review", @{@"message":snapshot});
        require([[(NSTextField *)[f.factory valueForKey:@"statusLabel"] stringValue] isEqual:@"Using analyzed audio"] &&
            [(NSString *)[f.factory valueForKey:@"statusDetails"] isEqual:snapshot],
            @"Audio snapshot review keeps a concise visible status and complete refresh guidance");
        response(f.factory, 4, @"review", @{@"message":@"Playhead moved to the selected cut’s start."});
        require([[(NSTextField *)[f.factory valueForKey:@"statusLabel"] stringValue] isEqual:@"Playhead moved"],
            @"Successful navigation keeps visible feedback beside the review actions");
        NSString *failure = [@"Verification failed. " stringByPaddingToLength:1200 withString:@"Recovery detail. " startingAtIndex:0];
        response(f.factory, 5, @"failed", @{@"message":failure, @"canApply":@NO});
        NSTextField *status = [f.factory valueForKey:@"statusLabel"];
        require([(NSString *)[f.factory valueForKey:@"statusDetails"] isEqual:failure] && status.stringValue.length < 100 &&
            [[(NSMenuItem *)[f.factory valueForKey:@"detailsItem"] title] isEqual:@"Error Details…"],
            @"Failures retain complete details while the inspector shows a short status");
        NSString *key = [f.factory valueForKey:@"lastErrorKey"];
        [f.factory setValue:nil forKey:@"pendingErrorMessage"];
        response(f.factory, 6, @"failed", @{@"message":failure, @"canApply":@NO});
        require([[f.factory valueForKey:@"lastErrorKey"] isEqual:key] && ![f.factory valueForKey:@"pendingErrorMessage"],
            @"Repeated failure status cannot queue the same alert again");
    });

    run(@"every detection setting waits for a manual Analyze click", ^(Fixture *f) {
        NSArray *tweaks = @[@"-35.25", @"0.65", @"0.15", @"0.35"];
        for (NSUInteger i = 0; i < 4; i++) {
            if (i == 0) [f review];
            NSString *request = connection(f.factory).requestID;
            NSURL *launched = f.factory.openedURL;
            NSArray *cuts = [[f.factory valueForKey:@"cutRows"] copy];
            f.fields[i].stringValue = tweaks[i];
            [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[i]]];
            [(id<NSTextFieldDelegate>)f.factory controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification
                object:f.fields[i] userInfo:@{@"NSTextMovement":@(NSReturnTextMovement)}]];
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.25];
            while (deadline.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
            [f.factory pollStatus];
            require([f.factory.openedURL isEqual:launched] && commandCount(f.factory, @"recalculate") == 0,
                @"Typing, Return, focus loss and polling never start analysis or recalculation");
            require(f.analyze.enabled && !f.apply.enabled && !f.apply.hidden &&
                !connection(f.factory).operationBusy && f.fields[i].enabled, @"Manual Analyze stays available; Apply stays visibly disabled");
            require([[f.factory valueForKey:@"cutRows"] isEqual:cuts] &&
                [[(NSTextField *)[f.factory valueForKey:@"summaryLabel"] stringValue] isEqual:@"Settings changed—Analyze again."],
                @"Keep the previous cuts inactive with an explicit stale message");
            response(f.factory, 20+i, @"review", nil);
            require(!f.apply.enabled, @"A delayed old review cannot restore Apply");
            [f.analyze performClick:nil];
            require(![connection(f.factory).requestID isEqual:request] && ![f.factory.openedURL isEqual:launched],
                @"Only the Analyze click creates the next request");
            response(f.factory, 1, @"review", nil);
            require(f.apply.enabled, @"The new analysis result restores Apply");
        }
    });
    run(@"Save and output changes do not start analysis", ^(Fixture *f) {
        [f review]; NSURL *launched = f.factory.openedURL;
        f.fields[0].stringValue = @"-34";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[0]]];
        [f.factory saveSettings:nil];
        NSPopUpButton *output = [f.factory valueForKey:@"outputMode"];
        [output selectItemAtIndex:1]; [NSApp sendAction:output.action to:output.target from:output];
        for (NSUInteger i = 0; i < 3; i++) [f.factory pollStatus];
        require([f.factory.openedURL isEqual:launched] && commandCount(f.factory, @"recalculate") == 0 && !f.apply.enabled,
            @"Save, output changes and status polls keep the old result invalidated");
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -34, @"Saving persists the draft without analyzing it");
        require(commandCount(f.factory, @"cancel") > 0, @"The old helper review is consumed without an export");
    });
    run(@"outdated edits reject reconnects and late packets", ^(Fixture *f) {
        [f review]; NSString *old = connection(f.factory).requestID;
        f.fields[0].stringValue = @"-35";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[0]]];
        NSDictionary *packet = @{@"version":@1, @"view":[f.factory valueForKey:@"viewID"], @"request":old,
            @"output":@"remove", @"settings":@{@"threshold":@-26,@"minimum":@.75,@"before":@.125,@"after":@.25}};
        [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(packet)]];
        response(f.factory, 30, @"review", @{@"canHighlight":@YES});
        [f.factory apply:nil];
        require(f.fields[0].floatValue == -35 && !f.apply.enabled && commandCount(f.factory, @"apply") == 0,
            @"Late replies cannot overwrite the draft or apply the previous cuts");
        [f.analyze performClick:nil];
        deliver(f.factory, json(@{@"version":@1,@"request":old,@"revision":@31,@"state":@"review",@"message":@"Old result",@"cuts":@[],@"canApply":@YES}));
        require(!f.apply.enabled, @"A stale request cannot supply the new analysis result");
        response(f.factory, 1, @"review", nil); require(f.apply.enabled, @"Only a fresh matching request can restore Apply");
    });
    run(@"incomplete typing never starts work or shows an automatic validation alert", ^(Fixture *f) {
        [f review]; NSURL *launched = f.factory.openedURL;
        f.fields[0].stringValue = @"-";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[0]]];
        [f.factory pollStatus];
        require(![f.factory valueForKey:@"pendingErrorMessage"] && !f.apply.enabled && [f.factory.openedURL isEqual:launched],
            @"An unfinished edit remains local");
        f.fields[0].stringValue = @"-35";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:f.fields[0]]];
        require(!f.apply.enabled && [f.factory.openedURL isEqual:launched], @"Finishing a valid edit still requires manual Analyze");
    });
    run(@"idle host parameter changes invalidate the current review without analysis", ^(Fixture *f) {
        [f review]; NSURL *launched = f.factory.openedURL;
        [f.unit.analysisParameterTree parameterWithAddress:1].value = -37.25f;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
        while (f.fields[0].floatValue != -37.25f && deadline.timeIntervalSinceNow > 0)
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        require(f.fields[0].floatValue == -37.25f && !f.apply.enabled && f.analyze.enabled && [f.factory.openedURL isEqual:launched],
            @"Inspector edits update the draft, consume the old review and wait for Analyze");
    });
    run(@"reconnect uses the processor's full supported minimum range", ^(Fixture *f) {
        for (NSNumber *minimum in @[@0.0001, @0.01, @0.1, @0.00001]) {
            [f.factory setValue:[SilentSnipReviewConnection new] forKey:@"connection"];
            NSDictionary *packet = @{@"version":@1, @"view":[f.factory valueForKey:@"viewID"], @"request":NSUUID.UUID.UUIDString,
                @"output":@"gaps", @"settings":@{@"threshold":@-35, @"minimum":minimum, @"before":@0.1, @"after":@0.1}};
            [f.factory reconnect:[NSNotification notificationWithName:@"test" object:json(packet)]];
            require((connection(f.factory).requestID != nil) == (minimum.floatValue >= [f.unit.analysisParameterTree parameterWithAddress:2].minValue),
                @"Reconnect accepts exactly the Audio Unit's parameter bounds");
        }
    });
    run(@"invalid settings block row double-click navigation", ^(Fixture *f) {
        [f review]; response(f.factory, 2, @"review", @{@"canHighlight":@YES});
        f.fields[0].stringValue = @"-";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:f.fields[0]]];
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [f.factory jumpToCut:nil];
        require(commandCount(f.factory, @"highlight") == 0, @"Double-click cannot use the old review while text is invalid");
        f.fields[0].stringValue = @"-35";
        [(id<NSTextFieldDelegate>)f.factory controlTextDidEndEditing:[NSNotification notificationWithName:NSControlTextDidEndEditingNotification object:f.fields[0]]];
        [f.factory jumpToCut:nil];
        require(commandCount(f.factory, @"highlight") == 0, @"Finishing the edit does not revive old navigation");
        [f.analyze performClick:nil]; response(f.factory, 1, @"review", @{@"canHighlight":@YES});
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [f.factory jumpToCut:nil];
        require(commandCount(f.factory, @"highlight") == 1, @"Manual Analyze restores navigation for the new result");
    });

    NSArray *states = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"AudioPlugin/Tests/review-states.json"] options:0 error:nil];
    require(states.count == 13, @"Shared protocol state fixture loaded");
    for (NSDictionary *entry in states) {
        require(SilentSnipReviewStateIsBusy(entry[@"state"]) == [entry[@"busy"] boolValue] &&
            SilentSnipReviewStateIsTerminal(entry[@"state"]) == [entry[@"terminal"] boolValue] &&
            SilentSnipReviewStateCanRetry(entry[@"state"]) == [entry[@"retry"] boolValue], @"Objective-C state policy matches Swift contract");
    }
    puts("PASS: shared protocol state contract");
    return 0;
} }
