#import "CutdownAudioUnitFactory.h"
#import "CutdownAudioUnit.h"
#import "CutdownReviewConnection.h"
#include <math.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const commandName = @"local.cutdown.review.command.v1";
static NSString *responseName(NSString *request) {
    return [@"local.cutdown.review.response.v1." stringByAppendingString:request];
}
static NSTextField *label(NSString *text, BOOL bold) {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = bold ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:11];
    return field;
}
static void compactControl(NSControl *control) {
    control.controlSize = NSControlSizeSmall;
    control.font = [NSFont systemFontOfSize:11];
}
// Show the shortest decimal that still round-trips to the stored AUValue.
// This removes Float32 noise (0.100000001) without rounding away user settings.
static NSString *settingText(float value) {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.usesGroupingSeparator = NO;
    formatter.usesSignificantDigits = YES;
    formatter.minimumSignificantDigits = 1;
    for (NSUInteger digits = 1; digits <= 9; digits++) {
        formatter.maximumSignificantDigits = digits;
        NSString *text = [formatter stringFromNumber:@(value)];
        if ([formatter numberFromString:text].floatValue == value) return text;
    }
    return [formatter stringFromNumber:@(value)];
}
static NSStackView *horizontalRow(NSArray<NSView *> *views) {
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    return row;
}
static NSView *flexibleSpace(void) {
    NSView *space = [NSView new];
    [space setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return space;
}
static BOOL booleanValue(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

@interface CutdownAudioUnitFactory () <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) CutdownReviewConnection *connection;
@property(nonatomic) CutdownAudioUnit *audioUnit;
@property(nonatomic) NSArray<NSTextField *> *fields;
@property(nonatomic) NSButton *analyzeButton;
@property(nonatomic) NSButton *applyButton;
@property(nonatomic) NSButton *previewButton;
@property(nonatomic) NSButton *jumpButton;
@property(nonatomic) NSButton *retryButton;
@property(nonatomic) NSButton *cancelButton;
@property(nonatomic) NSString *viewID;
@property(nonatomic) NSDate *verificationPending;
@property(nonatomic) NSMenuItem *verifyItem;
@property(nonatomic) NSButton *moreButton;
@property(nonatomic) NSMenu *moreMenu;
@property(nonatomic) NSStackView *reviewToolbar;
@property(nonatomic) NSTextField *emptyLabel;
@property(nonatomic) BOOL canHighlight;
@property(nonatomic) NSPopUpButton *outputMode;
@property(nonatomic) NSTextField *statusLabel;
@property(nonatomic) NSTextField *summaryLabel;
@property(nonatomic) NSTableView *resultsView;
@property(nonatomic) NSArray<NSDictionary *> *cutRows;
@property(nonatomic) NSButton *selectAllButton;
@property(nonatomic) NSButton *deselectAllButton;
@property(nonatomic) BOOL canChangeSelection;
@property(nonatomic) NSArray<NSNumber *> *submittedSettings;
@property(nonatomic) NSTimer *pollTimer;
@property(nonatomic) BOOL canApply;
@property(nonatomic) BOOL settingsDirty;
@property(nonatomic) NSProgressIndicator *progressBar;
@property(nonatomic) NSTextField *progressLabel;
@property(nonatomic) NSDate *operationStarted;
@end

@implementation CutdownAudioUnitFactory

- (CutdownReviewConnection *)connection {
    if (!_connection) _connection = [CutdownReviewConnection new];
    return _connection;
}

- (nullable AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)description
                                                          error:(NSError **)error {
    self.audioUnit = [[CutdownAudioUnit alloc] initWithComponentDescription:description options:0 error:error];
    if (self.isViewLoaded) [self refreshSettings];
    return self.audioUnit;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 560)];
    self.preferredContentSize = self.view.frame.size;
    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 8;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-16]
    ]];
    NSTextField *title = label(@"Cutdown Audio", YES);
    title.font = [NSFont boldSystemFontOfSize:16];
    self.moreButton = [NSButton buttonWithTitle:@"More…" target:self action:@selector(showMoreActions:)];
    self.moreMenu = [NSMenu new];
    compactControl(self.moreButton);
    self.moreButton.accessibilityLabel = @"More actions";
    NSMenuItem *restore = [[NSMenuItem alloc] initWithTitle:@"Restore Saved Settings…" action:@selector(restoreSavedSettings:) keyEquivalent:@""];
    restore.target = self;
    [self.moreMenu addItem:restore];
    [self.moreMenu addItem:NSMenuItem.separatorItem];
    self.verifyItem = [[NSMenuItem alloc] initWithTitle:@"Verify Existing Result…" action:@selector(verifyExistingResult:) keyEquivalent:@""];
    self.verifyItem.target = self;
    [self.moreMenu addItem:self.verifyItem];
    NSStackView *header = horizontalRow(@[title, flexibleSpace(), self.moreButton]);
    [content addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    NSButton *save = [NSButton buttonWithTitle:@"Save Settings" target:self action:@selector(saveSettings:)];
    compactControl(save); save.identifier = @"cutdown.saveSettings";
    save.bezelStyle = NSBezelStyleInline;
    // The always-visible More button supplies the helper's native ownership
    // anchor, even while Cancel is hidden. Save keeps its recovery identifier.
    self.viewID = NSUUID.UUID.UUIDString;
    self.moreButton.identifier = [@"cutdown.review.reconnect." stringByAppendingString:self.viewID];
    NSStackView *settingsHeader = horizontalRow(@[label(@"1. Detection", YES), flexibleSpace(), save]);
    [content addArrangedSubview:settingsHeader];
    [settingsHeader.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    NSArray *names = @[@"Silence Threshold", @"Minimum Silence", @"Before Speech", @"After Speech"];
    NSMutableArray *fields = [NSMutableArray array];
    for (NSUInteger i=0; i<4; i++) {
        NSTextField *name = label(names[i], NO);
        [name.widthAnchor constraintEqualToConstant:144].active = YES;
        NSTextField *field = [NSTextField textFieldWithString:@""];
        compactControl(field);
        field.tag = i;
        field.delegate = self;
        field.alignment = NSTextAlignmentRight;
        field.accessibilityLabel = names[i];
        field.identifier = [NSString stringWithFormat:@"cutdown.setting.%lu", (unsigned long)i];
        [field.widthAnchor constraintEqualToConstant:80].active = YES;
        [fields addObject:field];
        NSStackView *row = horizontalRow(@[name, field, label(i==0 ? @"dBFS" : @"sec", NO)]);
        row.spacing = 8;
        [content addArrangedSubview:row];
    }
    self.fields = fields;
    self.outputMode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    compactControl(self.outputMode);
    [self.outputMode addItemsWithTitles:@[@"Remove Silence", @"Replace with 1-Second Gaps"]];
    self.outputMode.identifier = @"cutdown.output";
    self.outputMode.accessibilityLabel = @"Output";
    self.outputMode.target = self; self.outputMode.action = @selector(outputChanged:);
    NSTextField *outputLabel = label(@"Output", NO);
    [outputLabel.widthAnchor constraintEqualToConstant:144].active = YES;
    NSStackView *outputRow = horizontalRow(@[outputLabel, self.outputMode]);
    outputRow.spacing = 8;
    [content addArrangedSubview:outputRow];
    self.analyzeButton = [NSButton buttonWithTitle:@"Analyze" target:self action:@selector(analyze:)];
    self.analyzeButton.bezelStyle = NSBezelStyleRounded;
    compactControl(self.analyzeButton);
    self.analyzeButton.identifier = @"cutdown.analyze";
    self.statusLabel = label(@"Select the audio clip in the timeline, then click Analyze.", NO);
    self.statusLabel.identifier = @"cutdown.status";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.maximumNumberOfLines = 4;
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    NSStackView *analysisRow = horizontalRow(@[self.statusLabel, flexibleSpace(), self.analyzeButton]);
    [content addArrangedSubview:analysisRow];
    [analysisRow.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:360].active = YES;
    [self.analyzeButton setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.progressBar = [[NSProgressIndicator alloc] init];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.controlSize = NSControlSizeSmall;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 100;
    self.progressBar.hidden = YES;
    [content addArrangedSubview:self.progressBar];
    [self.progressBar.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    self.progressLabel = label(@"", NO);
    self.progressLabel.hidden = YES;
    [content addArrangedSubview:self.progressLabel];
    NSBox *divider = [[NSBox alloc] init];
    divider.boxType = NSBoxSeparator;
    [content addArrangedSubview:divider];
    [divider.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    [content addArrangedSubview:label(@"2. Review", YES)];
    self.summaryLabel = label(@"Review detected silence before applying cuts.", NO);
    self.summaryLabel.maximumNumberOfLines = 3;
    [content addArrangedSubview:self.summaryLabel];
    [self.summaryLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.verticalScroller.controlSize = NSControlSizeSmall;
    scroll.borderType = NSBezelBorder;
    self.resultsView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 464, 88)];
    self.resultsView.accessibilityIdentifier = @"cutdown.review.cuts";
    self.resultsView.headerView = nil;
    self.resultsView.rowHeight = 22;
    self.resultsView.dataSource = self; self.resultsView.delegate = self;
    self.resultsView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"cut"];
    column.width = 464;
    [self.resultsView addTableColumn:column];
    scroll.documentView = self.resultsView;
    NSView *reviewArea = [NSView new];
    [reviewArea setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [reviewArea addSubview:scroll];
    self.emptyLabel = label(@"Detected cuts will appear here after analysis.", NO);
    self.emptyLabel.textColor = NSColor.secondaryLabelColor;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [reviewArea addSubview:self.emptyLabel];
    [content addArrangedSubview:reviewArea];
    [NSLayoutConstraint activateConstraints:@[
        [reviewArea.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [reviewArea.heightAnchor constraintGreaterThanOrEqualToConstant:88],
        [scroll.leadingAnchor constraintEqualToAnchor:reviewArea.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:reviewArea.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:reviewArea.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:reviewArea.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:reviewArea.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:reviewArea.centerYAnchor]
    ]];
    self.selectAllButton = [NSButton buttonWithTitle:@"All" target:self action:@selector(selectCuts:)];
    self.deselectAllButton = [NSButton buttonWithTitle:@"None" target:self action:@selector(selectCuts:)];
    compactControl(self.selectAllButton); compactControl(self.deselectAllButton);
    self.selectAllButton.accessibilityLabel = @"Select All Cuts";
    self.deselectAllButton.accessibilityLabel = @"Select No Cuts";
    self.selectAllButton.bezelStyle = NSBezelStyleInline;
    self.deselectAllButton.bezelStyle = NSBezelStyleInline;
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;

    self.applyButton = [NSButton buttonWithTitle:@"Apply Cuts" target:self action:@selector(apply:)];
    self.applyButton.bezelStyle = NSBezelStyleRounded;
    compactControl(self.applyButton);
    self.applyButton.identifier = @"cutdown.apply";
    self.applyButton.toolTip = @"Available only after a valid analysis. This is a separate action from Analyze.";
    self.applyButton.enabled = NO;
    self.previewButton = [NSButton checkboxWithTitle:@"Show Preview" target:self action:@selector(togglePreview:)];
    compactControl(self.previewButton);
    self.previewButton.identifier = @"cutdown.preview";
    self.previewButton.toolTip = @"Show or hide the timeline cut lines without discarding your analysis. Closing this window leaves the preview on.";
    self.previewButton.enabled = NO;
    self.jumpButton = [NSButton buttonWithTitle:@"Go to Cut" target:self action:@selector(jumpToCut:)];
    self.jumpButton.accessibilityLabel = @"Go to Selected Cut";
    self.jumpButton.toolTip = @"Select a review row, then go to its start in the timeline.";
    compactControl(self.jumpButton);
    self.jumpButton.enabled = NO;
    self.reviewToolbar = horizontalRow(@[label(@"Include:", NO), self.selectAllButton, self.deselectAllButton,
        flexibleSpace(), self.previewButton, self.jumpButton]);
    self.reviewToolbar.hidden = YES;
    [content addArrangedSubview:self.reviewToolbar];
    [self.reviewToolbar.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    self.retryButton = [NSButton buttonWithTitle:@"Retry Verification" target:self action:@selector(retryVerification:)];
    compactControl(self.retryButton);
    self.retryButton.enabled = NO; self.retryButton.hidden = YES;
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    compactControl(self.cancelButton); self.cancelButton.enabled = NO; self.cancelButton.hidden = YES;
    NSStackView *footer = horizontalRow(@[self.cancelButton, flexibleSpace(), self.retryButton, self.applyButton]);
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-16],
        [content.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-12]
    ]];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(reconnect:)
        name:[@"local.cutdown.review.connected.v1." stringByAppendingString:self.viewID]
        object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self refreshSettings];
}

- (void)showMoreActions:(NSButton *)sender {
    [self.moreMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds) + 4) inView:sender];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    return self.audioUnit != nil && !self.connection.operationBusy && !self.connection.applying &&
        !self.connection.awaitingResponse && !self.verificationPending;
}

- (void)refreshSettings {
    for (NSUInteger i=0; i<self.fields.count; i++) {
        AUParameter *parameter = [self.audioUnit.analysisParameterTree parameterWithAddress:i+1];
        self.fields[i].stringValue = parameter ? settingText(parameter.value) : @"";
    }
    self.analyzeButton.enabled = self.audioUnit != nil && !self.connection.applying && !self.connection.operationBusy && !self.connection.awaitingResponse;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self.view.window center];
    if (!self.settingsDirty && !self.connection.requestID) [self refreshSettings];
    // No polls run while this hosted view is absent. Allow a fresh reply
    // before evaluating a deadline left over from the preceding appearance.
    if (self.connection.requestID) self.connection.lastResponse = NSDate.date;
    [self startPolling];
    [self pollStatus];
}
- (void)viewDidDisappear {
    [super viewDidDisappear];
    [self.pollTimer invalidate]; self.pollTimer = nil;
}

- (void)controlTextDidChange:(NSNotification *)notification {
    self.settingsDirty = YES;
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
    self.canApply = NO; self.applyButton.enabled = NO;
    self.summaryLabel.stringValue = @"Settings changed. Analyze updates the preview and reuses audio when unchanged.";
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (self.settingsDirty) [self commitSettings];
}
- (NSArray<NSNumber *> *)readFields {
    NSMutableArray *values = [NSMutableArray array];
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.lenient = NO;
    for (NSUInteger i=0; i<4; i++) {
        NSString *text = [self.fields[i].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange range = NSMakeRange(0,text.length);
        id number = nil;
        BOOL parsed = [formatter getObjectValue:&number forString:text range:&range error:nil];
        AUParameter *parameter = [self.audioUnit.analysisParameterTree parameterWithAddress:i+1];
        double value = [number isKindOfClass:NSNumber.class] ? [number doubleValue] : NAN;
        // The parameter limits and persisted value are Float32. A decimal that
        // rounds back to the exact minimum (e.g. 0.1f) must not fail a Double comparison.
        float stored = (float)value;
        if (!parsed || !text.length || range.length != text.length || !parameter || !isfinite(value) || !isfinite(stored) || stored < parameter.minValue || stored > parameter.maxValue) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Enter a valid %@ between %g and %g.", parameter.displayName ?: @"setting", parameter.minValue, parameter.maxValue];
            return nil;
        }
        [values addObject:@(stored)];
    }
    return values;
}
- (BOOL)commitSettings {
    NSArray *values = [self readFields];
    if (!values) return NO;
    return [self.audioUnit setAnalysisSettings:values error:nil];
}

- (void)saveSettings:(id)sender {
    if (self.connection.applying || self.connection.operationBusy || ![self commitSettings]) return;
    self.settingsDirty = YES; self.canApply = NO; self.applyButton.enabled = NO;
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
    [self refreshSettings];
    self.statusLabel.stringValue = @"Settings saved.";
}

- (BOOL)restoreSettingsData:(NSData *)data {
    if (self.connection.applying || self.connection.operationBusy || data.length > 16384) return NO;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return NO;
    NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    NSMutableArray *values = [NSMutableArray array];
    for (NSString *key in keys) {
        id value = decoded[key];
        if (![value isKindOfClass:NSNumber.class] || booleanValue(value)) return NO;
        [values addObject:value];
    }
    if (![self.audioUnit setAnalysisSettings:values error:nil]) return NO;
    self.settingsDirty = YES; self.canApply = NO; self.applyButton.enabled = NO;
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
    [self refreshSettings];
    self.statusLabel.stringValue = @"Saved detection settings restored. Analyze again before applying cuts.";
    return YES;
}
- (void)restoreSavedSettings:(id)sender {
    if (self.connection.applying || self.connection.operationBusy) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[UTTypeJSON];
    panel.message = @"Choose Analysis-Settings.json from the Cutdown result folder.";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;
        NSNumber *size = nil; [panel.URL getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        NSData *data = size && size.unsignedLongLongValue <= 16384 ? [NSData dataWithContentsOfURL:panel.URL] : nil;
        if (!data || ![self restoreSettingsData:data]) self.statusLabel.stringValue = @"That file does not contain four valid Cutdown detection settings.";
    }];
}

- (void)outputChanged:(id)sender {
    self.settingsDirty = YES;
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
    self.canApply = NO; self.applyButton.enabled = NO;
    self.summaryLabel.stringValue = @"Output changed. Analyze again before applying.";
}

// Kept as a separate method so the UI harness can test clicks without launching apps.
- (BOOL)openAnalysisURL:(NSURL *)URL { return [NSWorkspace.sharedWorkspace openURL:URL]; }

- (void)analyze:(id)sender {
    if (self.verificationPending || self.connection.applying || self.connection.operationBusy || self.connection.awaitingResponse || ![self commitSettings]) return;
    NSError *error = nil;
    CutdownAudioAnalysisRequest *request = [self.audioUnit analysisRequestWithError:&error];
    if (!request) { self.statusLabel.stringValue = error.localizedDescription; return; }
    if (self.connection.requestID) {
        [self sendCommand:@"cancel"];
        [NSDistributedNotificationCenter.defaultCenter removeObserver:self name:responseName(self.connection.requestID) object:nil];
    }
    self.connection = [CutdownReviewConnection new];
    self.applyButton.identifier = @"cutdown.apply";
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO].queryItems)
        if ([item.name isEqual:@"request"]) self.connection.requestID = item.value;
    self.connection.revision = nil; self.connection.lastResponseObject = nil; self.submittedSettings = [self readFields];
    self.canApply = NO; self.applyButton.enabled = NO; self.settingsDirty = NO;
    self.cutRows = @[]; [self.resultsView reloadData];
    self.reviewToolbar.hidden = YES; self.emptyLabel.hidden = NO;
    self.emptyLabel.stringValue = @"Detected cuts will appear here after analysis.";
    self.connection.pendingSelection = nil; self.connection.pendingRetry = nil; self.connection.pendingPreview = nil; self.canChangeSelection = NO;
    self.summaryLabel.stringValue = @"Waiting for analysis. No cuts have been applied.";
    self.statusLabel.stringValue = @"Connecting to Cutdown…";
    self.connection.awaitingResponse = YES; self.connection.lastResponse = NSDate.date;
    self.analyzeButton.enabled = NO;
    self.outputMode.enabled = NO;
    for (NSTextField *field in self.fields) field.enabled = NO;
    self.operationStarted = NSDate.date;
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(receive:)
        name:responseName(self.connection.requestID) object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    NSURLComponents *launch = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    launch.queryItems = [launch.queryItems arrayByAddingObject:[NSURLQueryItem queryItemWithName:@"output"
        value:self.outputMode.indexOfSelectedItem == 1 ? @"gaps" : @"remove"]];
    if (![self openAnalysisURL:launch.URL]) {
        self.connection.awaitingResponse = NO;
        self.analyzeButton.enabled = YES; self.outputMode.enabled = YES;
        for (NSTextField *field in self.fields) field.enabled = YES;
        self.statusLabel.stringValue = @"Cutdown could not open its background helper. Check the local installation, then Analyze again.";
        return;
    }
    [self.audioUnit rememberSettingsForRequest:request error:nil];
    [self startPolling];
}

- (void)startPolling {
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf pollStatus];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}
// Commands are idempotent for one helper-owned job. Retry an unacknowledged
// request with that SAME identity; never create another import on a timeout.
- (void)pollStatus {
    if (!self.connection.requestID) {
        if (self.verificationPending) {
            if (-self.verificationPending.timeIntervalSinceNow > 15) {
                self.verificationPending = nil;
                self.statusLabel.stringValue = @"Verification could not be connected. Check the existing result before retrying; no new import was requested.";
            }
            return;
        }
        if (!self.settingsDirty) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"view":self.viewID} options:0 error:nil];
            [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"local.cutdown.review.reconnect.v1"
                object:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] userInfo:nil deliverImmediately:YES];
        }
        return;
    }
    [self sendCommand:@"status"];
    for (NSDictionary *command in self.connection.commandsToRetry) [self sendPreviewCommand:command];
    if (self.connection.operationBusy) {
        self.progressLabel.stringValue = [NSString stringWithFormat:@"Elapsed %.0f seconds · %@", -self.operationStarted.timeIntervalSinceNow,
            self.progressBar.indeterminate ? @"Waiting for Final Cut" : @"Audio measurement progress"];
    }
    if ([self.connection hasTimedOutAt: NSDate.date]) {
        self.connection.timedOut = YES;
        BOOL uncertainApply = self.connection.applying;
        self.connection.applying = NO; self.connection.operationBusy = NO; self.connection.awaitingResponse = NO;
        self.settingsDirty = YES; self.canApply = NO; self.applyButton.enabled = NO;
        self.connection.pendingSelection = nil; self.canChangeSelection = NO;
        self.connection.pendingRetry = nil; self.connection.pendingPreview = nil;
        self.connection.pendingApply = nil; self.applyButton.identifier = @"cutdown.apply";
        self.previewButton.enabled = NO; self.jumpButton.enabled = NO; self.cancelButton.enabled = NO;
        self.cancelButton.hidden = YES;
        self.progressBar.hidden = YES; self.progressLabel.hidden = YES;
        self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
        self.analyzeButton.enabled = YES; self.outputMode.enabled = YES;
        for (NSTextField *field in self.fields) field.enabled = YES;
        [self.resultsView reloadData];
        self.statusLabel.stringValue = uncertainApply
            ? @"Apply could not be confirmed. Check your project before analyzing again; replacement may already have completed."
            : @"The helper is not responding. Analyze again to reconnect.";
        // Continue read-only status polls. A delayed final failure must replace
        // this provisional timeout; no Apply command is retried after timeout.
    }
}

// The helper replies only to a view whose UUID it finds in the original
// clip's native Controls window. Never adopt an unsolicited global "latest job".
- (void)reconnect:(NSNotification *)notification {
    if (self.connection.requestID || self.settingsDirty || notification.userInfo ||
        ![notification.object isKindOfClass:NSString.class]) return;
    NSData *data = [notification.object dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length > 4096) return;
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return;
    NSDictionary *value = decoded;
    if (self.verificationPending && [value[@"version"] isEqual:@1] && [value[@"view"] isEqual:self.viewID] &&
        [value[@"error"] isKindOfClass:NSString.class]) {
        self.verificationPending = nil; self.statusLabel.stringValue = value[@"error"]; return;
    }
    if (![value[@"version"] isEqual:@1] || booleanValue(value[@"version"]) || ![value[@"view"] isEqual:self.viewID] ||
        ![value[@"request"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:value[@"request"]] ||
        ![@[@"remove", @"gaps"] containsObject:value[@"output"] ?: NSNull.null] ||
        ![value[@"settings"] isKindOfClass:NSDictionary.class]) return;
    NSMutableArray *settings = [NSMutableArray array];
    NSArray *keys = @[@"threshold", @"minimum", @"before", @"after"];
    const double lower[] = {-80, .1, 0, 0}, upper[] = {0, 10, 2, 2};
    for (NSUInteger i=0; i<4; i++) {
        id number = value[@"settings"][keys[i]];
        if (![number isKindOfClass:NSNumber.class] || booleanValue(number) || !isfinite([number doubleValue]) ||
            [number doubleValue] < lower[i] || [number doubleValue] > upper[i]) return;
        [settings addObject:number];
    }
    self.verificationPending = nil;
    self.connection = [CutdownReviewConnection new];
    self.applyButton.identifier = @"cutdown.apply";
    self.connection.requestID = value[@"request"];
    self.connection.lastResponse = NSDate.date; self.connection.awaitingResponse = YES;
    for (NSUInteger i=0; i<4; i++) self.fields[i].stringValue = settingText([settings[i] floatValue]);
    self.submittedSettings = [self readFields];
    [self.outputMode selectItemAtIndex:[value[@"output"] isEqual:@"gaps"] ? 1 : 0];
    self.analyzeButton.enabled = NO; self.outputMode.enabled = NO;
    for (NSTextField *field in self.fields) field.enabled = NO;
    self.operationStarted = NSDate.date;
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(receive:)
        name:responseName(self.connection.requestID) object:nil suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self sendCommand:@"status"];
}
- (void)verifyExistingResult:(id)sender {
    if (self.connection.operationBusy || self.connection.applying || self.connection.awaitingResponse || self.verificationPending) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
    panel.message = @"Choose Cutdown.fcpxml from an existing result folder. This verifies that result without importing again.";
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        if (![panel.URL.lastPathComponent isEqual:@"Cutdown.fcpxml"]) {
            self.statusLabel.stringValue = @"Choose the Cutdown.fcpxml file in the saved result folder."; return;
        }
        if (self.connection.requestID)
            [NSDistributedNotificationCenter.defaultCenter removeObserver:self name:responseName(self.connection.requestID) object:nil];
        self.connection = [CutdownReviewConnection new]; self.settingsDirty = NO;
        self.applyButton.identifier = @"cutdown.apply";
        self.canApply = NO; self.applyButton.enabled = NO; self.cancelButton.enabled = NO;
        self.canChangeSelection = NO; self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
        self.previewButton.enabled = NO; self.jumpButton.enabled = NO; self.retryButton.enabled = NO;
        self.cutRows = @[]; [self.resultsView reloadData];
        self.reviewToolbar.hidden = YES; self.emptyLabel.hidden = NO;
        self.emptyLabel.stringValue = @"Detected cuts will appear here after analysis.";
        self.cancelButton.hidden = YES;
        NSURLComponents *url = [NSURLComponents componentsWithString:@"cutdown://verify"];
        url.queryItems = @[[NSURLQueryItem queryItemWithName:@"view" value:self.viewID],
            [NSURLQueryItem queryItemWithName:@"result" value:panel.URL.absoluteString]];
        self.verificationPending = NSDate.date;
        self.statusLabel.stringValue = @"Connecting to the saved result…";
        if (![self openAnalysisURL:url.URL]) {
            self.verificationPending = nil;
            self.statusLabel.stringValue = @"Cutdown could not open its background helper.";
        }
        [self startPolling];
    }];
}
- (void)cancel:(id)sender {
    if (!self.cancelButton.enabled) return;
    self.cancelButton.enabled = NO; self.cancelButton.hidden = YES;
    [self sendCommand:@"cancel"];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.cutRows.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *cut = self.cutRows[row];
    NSString *title = [NSString stringWithFormat:@"%@ → %@   %@%@", cut[@"start"], cut[@"end"], cut[@"duration"],
        [cut[@"eligible"] boolValue] ? @"" : @" (unavailable)"];
    NSButton *button = [NSButton checkboxWithTitle:title target:self action:@selector(includeCut:)];
    compactControl(button); button.tag = row;
    button.state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    button.enabled = self.canChangeSelection && !self.connection.pendingSelection && !self.connection.applying && [cut[@"eligible"] boolValue];
    button.toolTip = [cut[@"reason"] isKindOfClass:NSString.class] ? cut[@"reason"] : title;
    return button;
}
- (void)requestSelection:(NSDictionary *)fields {
    if (!self.canChangeSelection || self.connection.pendingSelection || self.connection.applying || !self.connection.revision) return;
    NSMutableDictionary *command = [@{@"version":@1, @"request":self.connection.requestID} mutableCopy];
    [command addEntriesFromDictionary:fields];
    command[@"expectedRevision"] = self.connection.revision;
    self.connection.pendingSelection = command; self.connection.selectionRevision = self.connection.revision;
    self.canApply = NO; self.applyButton.enabled = NO;
    [self.resultsView reloadData];
    [self sendPreviewCommand:command];
}
- (void)includeCut:(NSButton *)sender {
    if (sender.tag < 0 || sender.tag >= self.cutRows.count) return;
    NSDictionary *cut = self.cutRows[sender.tag];
    if (![cut[@"eligible"] boolValue]) return;
    [self requestSelection:@{@"command":@"include", @"cutID":cut[@"id"],
        @"included":sender.state == NSControlStateValueOn ? @YES : @NO}];
}
- (void)selectCuts:(NSButton *)sender {
    [self requestSelection:@{@"command":sender == self.selectAllButton ? @"selectAll" : @"deselectAll"}];
}

- (void)sendCommand:(NSString *)command {
    if (!self.connection.requestID) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"request":self.connection.requestID, @"command":command} options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:commandName object:json userInfo:nil deliverImmediately:YES];
}
- (void)receive:(NSNotification *)notification {
    NSDictionary *value = [self.connection acceptNotification:notification];
    if (!value) return;
    self.cancelButton.enabled = [value[@"canCancel"] isEqual:@YES];
    self.cancelButton.hidden = !self.cancelButton.enabled;
    self.statusLabel.stringValue = value[@"message"];
    self.statusLabel.toolTip = value[@"message"];
    NSUInteger included = 0;
    for (NSDictionary *row in value[@"cuts"]) if ([row[@"eligible"] boolValue] && [row[@"included"] boolValue]) included++;
    self.canHighlight = [value[@"state"] isEqual:CutdownReviewStateReview] && [value[@"canHighlight"] isEqual:@YES];
    self.jumpButton.enabled = self.canHighlight;
    BOOL canRetry = [value[@"canRetryVerification"] isEqual:@YES] && CutdownReviewStateCanRetry(value[@"state"]);
    self.retryButton.enabled = canRetry && !self.connection.pendingRetry;
    self.retryButton.hidden = !canRetry;
    self.cutRows = value[@"cuts"];
    self.reviewToolbar.hidden = self.cutRows.count == 0;
    self.emptyLabel.hidden = self.cutRows.count > 0;
    self.emptyLabel.stringValue = [value[@"state"] isEqual:CutdownReviewStateReview]
        ? @"No silence found with these settings." : @"Detected cuts will appear here after analysis.";
    self.canChangeSelection = !self.settingsDirty && [value[@"state"] isEqual:CutdownReviewStateReview] && [value[@"canChangeSelection"] isEqual:@YES];
    self.selectAllButton.enabled = self.canChangeSelection && !self.connection.pendingSelection;
    self.deselectAllButton.enabled = self.canChangeSelection && !self.connection.pendingSelection;
    [self.resultsView reloadData];
    if (self.connection.applying && [value[@"state"] isEqual:CutdownReviewStateApplying]) self.connection.applyAcknowledged = YES;
    if (self.connection.applyAcknowledged || (self.connection.applying && CutdownReviewStateIsTerminal(value[@"state"]))) {
        self.connection.pendingApply = nil;
        self.applyButton.identifier = @"cutdown.apply";
    }
    if ([value[@"summary"] isKindOfClass:NSString.class]) self.summaryLabel.stringValue = value[@"summary"];
    else if ([value[@"state"] isEqual:CutdownReviewStateUnavailable]) self.summaryLabel.stringValue = @"Analysis is unavailable in this build. No cuts have been applied.";
    else if ([value[@"state"] isEqual:CutdownReviewStateFailed] || [value[@"state"] isEqual:CutdownReviewStateCancelled])
        self.summaryLabel.stringValue = @"The operation stopped. No cut preview is available; see the status above.";
    BOOL busy = CutdownReviewStateIsBusy(value[@"state"]);
    self.connection.operationBusy = busy;
    self.outputMode.enabled = !busy;
    self.previewButton.enabled = !busy && !self.connection.pendingPreview && [value[@"state"] isEqual:CutdownReviewStateReview] && booleanValue(value[@"previewVisible"]);
    self.previewButton.state = [value[@"previewVisible"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.progressBar.hidden = !busy;
    self.progressLabel.hidden = !busy;
    id fraction = value[@"progress"];
    BOOL measured = [fraction isKindOfClass:NSNumber.class] && !booleanValue(fraction) && isfinite([fraction doubleValue]) && [fraction doubleValue] >= 0 && [fraction doubleValue] <= 1;
    self.progressBar.indeterminate = !measured;
    if (busy && !measured) [self.progressBar startAnimation:nil];
    else { [self.progressBar stopAnimation:nil]; self.progressBar.doubleValue = measured ? [fraction doubleValue] * 100 : 0; }
    if (!busy) self.progressLabel.stringValue = @"";
    self.analyzeButton.enabled = !busy;
    for (NSTextField *field in self.fields) field.enabled = !busy;
    self.canApply = !self.connection.pendingSelection && !self.connection.applying && !self.settingsDirty && included > 0 && [value[@"state"] isEqual:CutdownReviewStateReview] && [value[@"canApply"] boolValue];
    self.applyButton.enabled = self.canApply;
    if (self.connection.applying && !busy) {
        self.connection.applying = NO;
        self.analyzeButton.enabled = YES;
        // A consumed plan cannot be enabled by a duplicate/stale response.
        self.settingsDirty = YES;
    }
}
- (void)jumpToCut:(id)sender {
    NSInteger row = self.resultsView.selectedRow;
    if (!self.connection.requestID || !self.connection.revision || !self.canHighlight || self.connection.operationBusy || self.connection.applying || row < 0 || row >= self.cutRows.count) return;
    [self sendPreviewCommand:@{@"version":@1, @"request":self.connection.requestID, @"command":@"highlight", @"cutID":self.cutRows[row][@"id"], @"expectedRevision":self.connection.revision}];
}
- (void)retryVerification:(id)sender {
    if (!self.connection.requestID || !self.retryButton.enabled || self.connection.operationBusy || self.connection.applying) return;
    self.retryButton.enabled = NO;
    self.connection.pendingRetry = @{@"version":@1, @"request":self.connection.requestID, @"command":@"retryVerification", @"expectedRevision":self.connection.revision};
    self.connection.timedOut = NO;
    self.connection.lastResponse = NSDate.date;
    [self startPolling];
    [self sendPreviewCommand:self.connection.pendingRetry];
}
- (void)togglePreview:(id)sender {
    if (!self.connection.requestID || !self.connection.revision || self.connection.operationBusy || self.connection.applying || self.connection.pendingPreview) return;
    NSDictionary *command = @{@"version":@1, @"request":self.connection.requestID, @"command":@"preview",
        @"included":self.previewButton.state == NSControlStateValueOn ? @YES : @NO,
        @"expectedRevision":self.connection.revision};
    self.connection.pendingPreview = command; self.connection.previewRevision = self.connection.revision;
    // Keep showing the acknowledged helper state while delivery is pending.
    self.previewButton.state = self.previewButton.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
    self.previewButton.enabled = NO;
    [self sendPreviewCommand:command];
}
- (void)sendPreviewCommand:(NSDictionary *)command {
    NSData *data = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:commandName
        object:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        userInfo:nil deliverImmediately:YES];
}

- (void)apply:(id)sender {
    self.operationStarted = NSDate.date;
    if (!self.canApply || !self.connection.revision || self.connection.applying || ![[self readFields] isEqual:self.submittedSettings]) return;
    self.canApply = NO; self.applyButton.enabled = NO; self.connection.applying = YES;
    self.connection.applyAcknowledged = NO; self.connection.lastResponse = NSDate.date;
    self.canChangeSelection = NO; [self.resultsView reloadData];
    self.selectAllButton.enabled = NO; self.deselectAllButton.enabled = NO;
    self.previewButton.enabled = NO;
    self.outputMode.enabled = NO;
    self.connection.applyRevision = self.connection.revision;
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.applyButton.identifier = [@"cutdown.apply.requested." stringByAppendingString:gesture];
    self.connection.pendingApply = @{@"version":@1, @"request":self.connection.requestID,
        @"command":@"apply", @"expectedRevision":self.connection.revision,
        @"view":self.viewID, @"applyGesture":gesture};
    self.analyzeButton.enabled = NO;
    for (NSTextField *field in self.fields) field.enabled = NO;
    self.statusLabel.stringValue = @"Requesting Apply Cuts…";
    [self sendPreviewCommand:self.connection.pendingApply];
}
- (void)dealloc {
    [_pollTimer invalidate];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}
@end
