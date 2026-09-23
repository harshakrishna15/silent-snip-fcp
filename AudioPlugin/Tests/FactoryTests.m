#import "../Extension/CutdownAudioUnitFactory.h"
#import "../Extension/CutdownAudioUnit.h"
#import "../Extension/CutdownReviewConnection.h"

@interface CutdownAudioUnitFactory (Testing)
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
- (void)retryVerification:(id)sender;
- (BOOL)restoreSettingsData:(NSData *)data;
@end

@interface TestFactory : CutdownAudioUnitFactory
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
static CutdownReviewConnection *connection(TestFactory *factory) { return [factory valueForKey:@"connection"]; }
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

/// Each scenario owns a fresh processor, private settings store, view and job.
@interface Fixture : NSObject
@property(nonatomic) TestFactory *factory;
@property(nonatomic) CutdownAudioUnit *unit;
@property(nonatomic) NSURL *settingsFile;
@property(nonatomic) NSArray<NSTextField *> *fields;
@property(nonatomic) NSButton *analyze;
@property(nonatomic) NSButton *apply;
@property(nonatomic) NSButton *preview;
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
        self.unit = [[CutdownAudioUnit alloc] initWithComponentDescription:description options:0
            settingsStore:[[CutdownAudioLastUsedSettingsStore alloc] initWithFileURL:self.settingsFile] error:&error];
        require(self.unit && !error, @"Independent settings store");
        [self.factory setValue:self.unit forKey:@"audioUnit"];
        NSArray *values = @[@-26,@.75,@.125,@.25];
        for (NSUInteger i=0; i<4; i++) [self.unit.analysisParameterTree parameterWithAddress:i+1].value = [values[i] floatValue];
        (void)self.factory.view;
        self.fields = [self.factory valueForKey:@"fields"];
        self.analyze = [self.factory valueForKey:@"analyzeButton"];
        self.apply = [self.factory valueForKey:@"applyButton"];
        self.preview = [self.factory valueForKey:@"previewButton"];
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
    require(argc == 2, @"Pass extension Info.plist");
    NSDictionary *extension = [NSDictionary dictionaryWithContentsOfFile:@(argv[1])][@"NSExtension"];
    require([extension[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.AudioUnit-UI"], @"Custom effect window registration");
    require(NSClassFromString(extension[@"NSExtensionPrincipalClass"]) == CutdownAudioUnitFactory.class, @"Registered view factory");
    require([CutdownAudioUnitFactory isSubclassOfClass:AUViewController.class], @"Factory supplies the Audio Unit view");

    run(@"state persistence and native legacy compatibility", ^(Fixture *f) {
        require(f.unit.parameterTree.allParameters.count == 0 && f.fields.count == 4, @"Four private controls, no Inspector parameters");
        NSDictionary *saved = f.unit.fullStateForDocument;
        [f.unit.analysisParameterTree parameterWithAddress:1].value = -10;
        f.unit.fullStateForDocument = saved;
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -26, @"Private values survive document state restore");
        NSError *error = nil;
        NSXMLDocument *fixture = [[NSXMLDocument alloc] initWithContentsOfURL:[NSURL fileURLWithPath:@"Tests/CutdownCoreTests/Fixtures/final-cut-12-3-native-audio.fcpxml"] options:NSXMLNodeLoadExternalEntitiesNever error:&error];
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
        require(!f.apply.enabled && !f.factory.openedURL && !f.preview.enabled, @"Opening view performs no action");
        require([[f.factory valueForKey:@"reviewToolbar"] isHidden] && [[f.factory valueForKey:@"cancelButton"] isHidden],
            @"Opening view hides actions that need an active analysis");
        StateObserver *observer = [StateObserver new];
        [f.unit addObserver:observer forKeyPath:@"allParameterValues" options:0 context:NULL];
        f.fields[0].stringValue = @"-20 trailing";
        [f.analyze performClick:nil];
        require(!f.factory.openedURL && observer.changes == 0, @"Invalid text never commits or launches");
        f.fields[0].stringValue = @"-20";
        [f.analyze performClick:nil];
        require([f.factory.openedURL.absoluteString containsString:@"threshold=-20"] && observer.changes > 0, @"Analyze sends exact values and notifies host to save state");
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
        require(commandCount(f.factory, @"apply") == 0, @"Analyze never applies");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16]; [f.factory pollStatus];
        require(f.analyze.enabled && !connection(f.factory).awaitingResponse, @"Connection timeout releases Analyze");
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

    run(@"lost preview delivery retries until matching acknowledgment", ^(Fixture *f) {
        [f review]; [f.preview performClick:nil];
        NSDictionary *hide = f.factory.previewCommand;
        require([hide[@"included"] isEqual:@NO] && CFGetTypeID((__bridge CFTypeRef)hide[@"included"]) == CFBooleanGetTypeID(), @"Preview uses a JSON boolean");
        require([hide[@"expectedRevision"] isEqual:@1], @"Preview names the review revision");
        deliver(f.factory, connection(f.factory).lastResponseObject); [f.factory pollStatus];
        require([f.factory.previewCommand isEqual:hide] && !f.preview.enabled && f.preview.state == NSControlStateValueOn && f.apply.enabled, @"Pending hide retries and shows confirmed state without blocking Apply");
        response(f.factory, 2, @"review", nil);
        require(connection(f.factory).pendingPreview != nil && !f.preview.enabled, @"Unrelated revision is not an acknowledgment");
        response(f.factory, 3, @"review", @{@"previewVisible":@NO});
        require(!connection(f.factory).pendingPreview && f.preview.enabled && f.preview.state == NSControlStateValueOff, @"Matching hide acknowledged");
        [f.preview performClick:nil]; require([f.factory.previewCommand[@"included"] isEqual:@YES], @"Show uses true");
        response(f.factory, 4, @"review", nil);
        require(f.preview.enabled && f.preview.state == NSControlStateValueOn, @"Show acknowledged");
    });

    run(@"Apply replay, retransmission, acknowledgment and uncertain timeout", ^(Fixture *f) {
        [f review]; NSString *review = connection(f.factory).lastResponseObject;
        [f.apply performClick:nil];
        require(commandCount(f.factory, @"apply") == 1 && !f.apply.enabled && !f.analyze.enabled, @"Apply sent exactly once");
        NSDictionary *apply = f.factory.previewCommand;
        require([apply[@"expectedRevision"] isEqual:@1] && [apply[@"view"] isKindOfClass:NSString.class] &&
            [apply[@"applyGesture"] isKindOfClass:NSString.class] &&
            [f.apply.identifier isEqual:[@"cutdown.apply.requested." stringByAppendingString:apply[@"applyGesture"]]],
            @"Apply carries a fresh gesture exposed by its disabled button");
        NSDate *before = [NSDate dateWithTimeIntervalSinceNow:-5]; connection(f.factory).lastResponse = before;
        deliver(f.factory, review); [f.apply performClick:nil];
        require([connection(f.factory).lastResponse isEqual:before] && !connection(f.factory).applyAcknowledged && commandCount(f.factory, @"apply") == 1, @"Old review neither acknowledges nor postpones Apply timeout");
        [f.factory pollStatus]; require(commandCount(f.factory, @"apply") == 2 &&
            [f.factory.previewCommand isEqual:apply], @"Unacknowledged Apply retries the same gesture and revision");
        response(f.factory, 2, @"applying", @{@"canApply":@NO});
        require([f.apply.identifier isEqual:@"cutdown.apply"] && connection(f.factory).pendingApply == nil,
            @"Acknowledgment consumes the Apply gesture");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16];
        deliver(f.factory, connection(f.factory).lastResponseObject); [f.factory pollStatus];
        require(commandCount(f.factory, @"apply") == 2 && connection(f.factory).applying, @"Acknowledged Apply only polls and remains alive on heartbeats");
        connection(f.factory).lastResponse = [NSDate dateWithTimeIntervalSinceNow:-16]; [f.factory pollStatus];
        require(f.analyze.enabled && !f.apply.enabled && !connection(f.factory).applying, @"Uncertain timeout consumes local review");
    });

    run(@"early preview rows stay read-only until cleanup completes", ^(Fixture *f) {
        [f review];
        response(f.factory, 2, @"analyzing", @{@"canApply":@NO, @"canChangeSelection":@NO, @"message":@"Preview ready. Finishing cleanup…"});
        require([(NSArray *)[f.factory valueForKey:@"cutRows"] count] > 0, @"Early preview keeps its cut rows");
        require(!f.apply.enabled && !f.analyze.enabled && !f.preview.enabled, @"Cleanup owns the operation while preview is displayed");
        response(f.factory, 3, @"review", nil);
        require(f.apply.enabled && f.analyze.enabled && f.preview.enabled, @"Completed cleanup enables the normal review");
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
        require([[(NSTextField *)[f.factory valueForKey:@"statusLabel"] stringValue] isEqual:@"Rendered project verification failed."],
            @"Terminal error is never overwritten by an idle heartbeat timeout");
        require(!f.preview.enabled && !f.apply.enabled && ![[(NSTextField *)[f.factory valueForKey:@"summaryLabel"] stringValue] containsString:@"Waiting"],
            @"Failed analysis explains absent preview");
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
        require([[(NSTextField *)[f.factory valueForKey:@"statusLabel"] stringValue] isEqual:@"The render could not be verified."], @"Late real failure replaces provisional timeout");
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
        require(![[f.factory valueForKey:@"reviewToolbar"] isHidden], @"Cut controls appear with review results");
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
        [(NSButton *)[f.factory valueForKey:@"selectAllButton"] performClick:nil];
        require([f.factory.previewCommand[@"command"] isEqual:@"selectAll"], @"Select All uses helper rules");
        response(f.factory, 4, @"review", nil); require(f.apply.enabled, @"Select All acknowledged");
    });

    run(@"navigation and lost verification retry delivery", ^(Fixture *f) {
        [f review]; response(f.factory, 2, @"review", @{@"canHighlight":@YES});
        NSTableView *table = [f.factory valueForKey:@"resultsView"];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; [f.factory jumpToCut:nil];
        require([f.factory.previewCommand[@"command"] isEqual:@"highlight"] && [f.factory.previewCommand[@"cutID"] isEqual:@"cut-1"] &&
            [f.factory.previewCommand[@"expectedRevision"] isEqual:@2], @"Navigation sends selected identity and revision");
        response(f.factory, 3, @"failed", @{@"canRetryVerification":@YES});
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
        require(f.apply.enabled && f.preview.enabled, @"Retained review becomes actionable in Controls");
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
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -29 && [status.stringValue isEqual:@"Settings saved."] && [launch isEqual:f.factory.openedURL] && !f.apply.enabled, @"Save commits without analyzing or reviving Apply");
        f.fields[0].stringValue = @"invalid"; [f.factory saveSettings:nil];
        require([f.unit.analysisParameterTree parameterWithAddress:1].value == -29, @"Invalid automated save preserves values");
        status.stringValue = [@"Long recovery notice. " stringByPaddingToLength:1200 withString:@"More information. " startingAtIndex:0];
        [f.factory.view layoutSubtreeIfNeeded];
        require(NSContainsRect(f.factory.view.bounds, [f.apply convertRect:f.apply.bounds toView:f.factory.view]), @"Apply stays visible with a long notice");
        NSButton *more = [f.factory valueForKey:@"moreButton"];
        require(NSContainsRect(f.factory.view.bounds, [more convertRect:more.bounds toView:f.factory.view]), @"More actions stay inside the single window");
        require([more.identifier isEqual:[@"cutdown.review.reconnect." stringByAppendingString:[f.factory valueForKey:@"viewID"]]] &&
            !more.hidden && [more isKindOfClass:NSButton.class], @"Reconnection keeps an always-visible native button anchor");
        NSMenu *menu = [f.factory valueForKey:@"moreMenu"];
        require(menu.numberOfItems == 3 && menu.itemArray[0].action == @selector(restoreSavedSettings:) &&
            menu.itemArray[2].action == @selector(verifyExistingResult:), @"Recovery actions remain available in More");
        [menu update];
        require(menu.itemArray[0].enabled && menu.itemArray[2].enabled, @"Recovery menu is available while idle");
        connection(f.factory).operationBusy = YES; [menu update];
        require(!menu.itemArray[0].enabled && !menu.itemArray[2].enabled, @"Recovery menu cannot interrupt an active operation");
        response(f.factory, 2, @"analyzing", @{@"canCancel":@YES, @"progress":@0.5, @"message":status.stringValue});
        [f.factory.view layoutSubtreeIfNeeded];
        require(f.factory.view.frame.size.width <= 520 && f.factory.view.frame.size.height <= 560,
            @"Progress and long notices fit the requested single-window size");
        NSView *toolbar = [f.factory valueForKey:@"reviewToolbar"];
        require(NSMinY([toolbar convertRect:toolbar.bounds toView:f.factory.view]) >= NSMaxY([f.apply convertRect:f.apply.bounds toView:f.factory.view]) + 8,
            @"Review controls do not overlap the fixed Apply footer");
    });

    NSArray *states = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"AudioPlugin/Tests/review-states.json"] options:0 error:nil];
    require(states.count == 13, @"Shared protocol state fixture loaded");
    for (NSDictionary *entry in states) {
        require(CutdownReviewStateIsBusy(entry[@"state"]) == [entry[@"busy"] boolValue] &&
            CutdownReviewStateIsTerminal(entry[@"state"]) == [entry[@"terminal"] boolValue] &&
            CutdownReviewStateCanRetry(entry[@"state"]) == [entry[@"retry"] boolValue], @"Objective-C state policy matches Swift contract");
    }
    puts("PASS: shared protocol state contract");
    return 0;
} }
