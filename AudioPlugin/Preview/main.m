#import "../Extension/CutdownAudioUnitFactory.h"
#import "../Extension/CutdownAudioUnit.h"
#import "../Extension/CutdownReviewConnection.h"

@interface CutdownAudioUnitFactory (Preview)
- (void)analyze:(id)sender;
- (void)receive:(NSNotification *)notification;
- (void)updateInspectorSize;
- (void)updatePrimaryAction;
- (void)setStatusMessage:(NSString *)message;
@end

// Developer-only transport. This preview never opens Final Cut or the helper,
// sends distributed commands, or writes the real last-used settings file.
@interface PreviewFactory : CutdownAudioUnitFactory
- (void)showState:(NSString *)state;
- (void)previewState:(NSMenuItem *)sender;
- (void)toggleAppearance:(id)sender;
@end
@implementation PreviewFactory
- (void)previewState:(NSMenuItem *)sender {
    [self setValue:[CutdownReviewConnection new] forKey:@"connection"];
    [self setValue:@NO forKey:@"settingsDirty"];
    [self setValue:@NO forKey:@"retryAvailable"];
    [self showState:sender.representedObject];
}
- (void)toggleAppearance:(id)sender {
    BOOL dark = [self.view.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    self.view.window.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
}
- (BOOL)openAnalysisURL:(NSURL *)url { return YES; }
- (void)sendCommand:(NSString *)command {}
- (void)sendPreviewCommand:(NSDictionary *)command {}
- (void)updateInspectorSize {
    [super updateInspectorSize];
    if (self.view.window) [self.view.window setContentSize:self.preferredContentSize];
}
- (void)showState:(NSString *)state {
    if ([state isEqual:@"idle"]) {
        [self setValue:@[] forKey:@"cutRows"];
        [self setValue:@NO forKey:@"canApply"];
        ((NSButton *)[self valueForKey:@"applyButton"]).enabled = NO;
        ((NSButton *)[self valueForKey:@"analyzeButton"]).enabled = YES;
        ((NSPopUpButton *)[self valueForKey:@"outputMode"]).enabled = YES;
        for (NSTextField *field in [self valueForKey:@"fields"]) field.enabled = YES;
        ((NSProgressIndicator *)[self valueForKey:@"progressBar"]).hidden = YES;
        ((NSTextField *)[self valueForKey:@"progressLabel"]).hidden = YES;
        ((NSButton *)[self valueForKey:@"cancelButton"]).hidden = YES;
        ((NSTextField *)[self valueForKey:@"summaryLabel"]).stringValue = @"Analyze to find quiet ranges.";
        ((NSTextField *)[self valueForKey:@"lengthLabel"]).stringValue = @"";
        [self setStatusMessage:@"Ready"];
        [self updatePrimaryAction];
        return;
    }
    [self analyze:nil];
    CutdownReviewConnection *connection = [self valueForKey:@"connection"];
    NSMutableArray *cuts = [NSMutableArray array];
    NSUInteger count = [state isEqual:@"many"] ? 16 : 2;
    for (NSUInteger i = 0; i < count; i++) {
        BOOL eligible = ![state isEqual:@"restricted"] || i > 0;
        [cuts addObject:@{@"id":[NSString stringWithFormat:@"cut-%lu", (unsigned long)i],
            @"start": i == 0 ? @"00:00:02:03" : @"00:00:05:03",
            @"end": i == 0 ? @"00:00:03:13" : @"00:00:06:28",
            @"duration": i == 0 ? @"1.333 s" : @"1.833 s", @"eligible":@(eligible), @"included":@(eligible),
            @"reason":eligible ? @"" : @"Protected by a transition. Adjust the transition in Final Cut before including this range."}];
    }
    NSString *wireState = [state isEqual:@"error"] ? @"failed" : ([state isEqual:@"busy"] ? @"analyzing" : @"review");
    NSString *message = @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts. Analyzed original audio; this clip has no audio adjustments or processing effects. Threshold uses 10 ms average loudness (RMS), not peak meters. Apply replaces this clip with the verified edited result; recovery files are saved with it.";
    if ([state isEqual:@"error"]) message = @"The edited project could not be verified. Your original project is unchanged. Open the recovery folder to inspect the exported XML and verification report, then choose Retry Verification. If the source media moved, relink it in Final Cut before retrying. No additional cuts will be applied by this retry.";
    if ([state isEqual:@"busy"]) message = @"Analyzing the selected audio…";
    NSString *summary = @"2 selected · 3.167 s removed · 10.000 s → 6.833 s";
    if ([state isEqual:@"restricted"]) summary = @"1 selected · 1.833 s removed · 10.000 s → 8.167 s";
    if ([state isEqual:@"many"]) summary = @"16 cuts selected";
    if ([state isEqual:@"error"] || [state isEqual:@"busy"]) summary = @"No cuts have been applied.";
    NSDictionary *packet = @{@"version":@1, @"request":connection.requestID, @"revision":@1,
        @"state":wireState, @"message":message, @"summary":summary,
        @"canApply":@([wireState isEqual:@"review"]), @"canChangeSelection":@YES,
        @"canCancel":@([state isEqual:@"busy"]), @"canHighlight":@YES, @"previewVisible":@YES,
        @"canRetryVerification":@([state isEqual:@"error"]), @"progress":@0.42,
        @"cuts":[state isEqual:@"error"] || [state isEqual:@"busy"] ? @[] : cuts};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:packet options:0 error:nil] encoding:NSUTF8StringEncoding];
    [self receive:[NSNotification notificationWithName:@"preview" object:json]];
    [self viewDidDisappear]; // No polling or timeouts in a static visual fixture.
}
@end

int main(int argc, const char *argv[]) { @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    PreviewFactory *factory = [PreviewFactory new];
    AudioComponentDescription description = {'aufx','ctdn','Ctdn',0,0};
    NSURL *settings = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    CutdownAudioUnit *unit = [[CutdownAudioUnit alloc] initWithComponentDescription:description options:0 settingsStore:[[CutdownAudioLastUsedSettingsStore alloc] initWithFileURL:settings] error:nil];
    [factory setValue:unit forKey:@"audioUnit"];
    NSArray *values = @[@-47,@.1,@.05,@.1];
    for (NSUInteger i = 0; i < 4; i++) [unit.analysisParameterTree parameterWithAddress:i+1].value = [values[i] floatValue];
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu *menu = [NSMenu new];
    appItem.submenu = menu;
    for (NSString *state in @[@"idle", @"review", @"restricted", @"many", @"error", @"busy"]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:state.capitalizedString action:@selector(previewState:) keyEquivalent:@""];
        item.target = factory; item.representedObject = state;
        [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *appearance = [[NSMenuItem alloc] initWithTitle:@"Toggle Light / Dark" action:@selector(toggleAppearance:) keyEquivalent:@"l"];
    appearance.target = factory;
    [menu addItem:appearance];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Preview" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
    [menu addItem:quit];
    NSApp.mainMenu = bar;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 506)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Silent Snip — Native UI Preview";
    window.contentViewController = factory;
    window.minSize = NSMakeSize(560, 360);
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [factory showState:@"review"];
        [window setContentSize:factory.preferredContentSize];
        [window.contentView layoutSubtreeIfNeeded];
    });
    [NSApp run];
    [NSFileManager.defaultManager removeItemAtURL:settings error:nil];
    return 0;
} }
