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
    field.font = bold ? [NSFont boldSystemFontOfSize:12] : [NSFont systemFontOfSize:12];
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
@property(nonatomic) NSButton *saveButton;
@property(nonatomic) NSButton *retryButton;
@property(nonatomic) NSButton *cancelButton;
@property(nonatomic) NSString *viewID;
@property(nonatomic) NSDate *verificationPending;
@property(nonatomic) NSMenuItem *verifyItem;
@property(nonatomic) NSMenuItem *analyzeAgainItem;
@property(nonatomic) NSMenuItem *jumpItem;
@property(nonatomic) NSMenuItem *selectAllItem;
@property(nonatomic) NSMenuItem *deselectAllItem;
@property(nonatomic) NSMenuItem *reviewActionsSeparator;
@property(nonatomic) NSButton *moreButton;
@property(nonatomic) NSMenu *moreMenu;
@property(nonatomic) NSTextField *emptyLabel;
@property(nonatomic) BOOL canHighlight;
@property(nonatomic) NSPopUpButton *outputMode;
@property(nonatomic) NSTextField *statusLabel;
@property(nonatomic) NSTextField *summaryLabel;
@property(nonatomic) NSTableView *resultsView;
@property(nonatomic) NSArray<NSDictionary *> *cutRows;
@property(nonatomic) BOOL canChangeSelection;
@property(nonatomic) BOOL retryAvailable;
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
    if (self.isViewLoaded) { [self refreshSettings]; [self updatePrimaryAction]; }
    return self.audioUnit;
}

- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 500)];
    self.preferredContentSize = self.view.frame.size;
    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 9;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-16]
    ]];
    NSTextField *title = label(@"Cutdown Audio", YES);
    title.font = [NSFont boldSystemFontOfSize:17];
    title.toolTip = @"Analyze an audio clip, review the proposed cuts, then apply them.";
    self.moreButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showMoreActions:)];
    self.moreMenu = [NSMenu new];
    compactControl(self.moreButton);
    self.moreButton.image = [NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"More actions"];
    self.moreButton.imagePosition = NSImageOnly;
    self.moreButton.bezelStyle = NSBezelStyleRounded;
    [self.moreButton.widthAnchor constraintEqualToConstant:28].active = YES;
    self.moreButton.accessibilityLabel = @"More actions";
    self.moreButton.toolTip = @"Review and recovery actions.";
    self.analyzeAgainItem = [[NSMenuItem alloc] initWithTitle:@"Analyze Again" action:@selector(analyze:) keyEquivalent:@""];
    self.analyzeAgainItem.target = self;
    [self.moreMenu addItem:self.analyzeAgainItem];
    self.jumpItem = [[NSMenuItem alloc] initWithTitle:@"Go to Selected Cut" action:@selector(jumpToCut:) keyEquivalent:@""];
    self.jumpItem.target = self;
    [self.moreMenu addItem:self.jumpItem];
    self.selectAllItem = [[NSMenuItem alloc] initWithTitle:@"Select All Cuts" action:@selector(selectCuts:) keyEquivalent:@""];
    self.selectAllItem.tag = 1; self.selectAllItem.target = self;
    [self.moreMenu addItem:self.selectAllItem];
    self.deselectAllItem = [[NSMenuItem alloc] initWithTitle:@"Select No Cuts" action:@selector(selectCuts:) keyEquivalent:@""];
    self.deselectAllItem.target = self;
    [self.moreMenu addItem:self.deselectAllItem];
    self.reviewActionsSeparator = NSMenuItem.separatorItem;
    [self.moreMenu addItem:self.reviewActionsSeparator];
    NSMenuItem *restore = [[NSMenuItem alloc] initWithTitle:@"Restore Saved Settings…" action:@selector(restoreSavedSettings:) keyEquivalent:@""];
    restore.target = self;
    [self.moreMenu addItem:restore];
    self.verifyItem = [[NSMenuItem alloc] initWithTitle:@"Verify Existing Result…" action:@selector(verifyExistingResult:) keyEquivalent:@""];
    self.verifyItem.target = self;
    [self.moreMenu addItem:self.verifyItem];
    NSStackView *header = horizontalRow(@[title, flexibleSpace(), self.moreButton]);
    [content addArrangedSubview:header];
    [header.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    self.statusLabel = label(@"Select an audio clip, then Analyze.", NO);
    self.statusLabel.identifier = @"cutdown.status";
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.maximumNumberOfLines = 3;
    self.statusLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.statusLabel.toolTip = self.statusLabel.stringValue;
    [content addArrangedSubview:self.statusLabel];
    [self.statusLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;

    self.saveButton = [NSButton buttonWithTitle:@"" target:self action:@selector(saveSettings:)];
    compactControl(self.saveButton); self.saveButton.identifier = @"cutdown.saveSettings";
    self.saveButton.image = [NSImage imageWithSystemSymbolName:@"square.and.arrow.down" accessibilityDescription:@"Save Settings"];
    self.saveButton.imagePosition = NSImageOnly;
    self.saveButton.bezelStyle = NSBezelStyleRounded;
    self.saveButton.accessibilityLabel = @"Save Settings";
    [self.saveButton.widthAnchor constraintEqualToConstant:28].active = YES;
    // The always-visible More button supplies the helper's native ownership
    // anchor, even while Cancel is hidden. Save keeps its recovery identifier.
    self.viewID = NSUUID.UUID.UUIDString;
    self.moreButton.identifier = [@"cutdown.review.reconnect." stringByAppendingString:self.viewID];
    self.saveButton.toolTip = @"Save the detection values to the selected clip without starting analysis.";
    NSTextField *detectionLabel = label(@"Detection", YES);
    detectionLabel.toolTip = @"Adjust how Cutdown finds quiet passages. Analyze to preview the result.";
    NSStackView *settingsHeader = horizontalRow(@[detectionLabel, flexibleSpace(), self.saveButton]);
    [content addArrangedSubview:settingsHeader];
    [settingsHeader.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    NSArray *names = @[@"Silence Threshold", @"Minimum Silence", @"Before Speech", @"After Speech"];
    NSArray *explanations = @[
        @"Audio below this level in every channel may count as silence. Move toward 0 dBFS to include louder quiet passages.",
        @"The removable quiet portion must be at least this long after padding and frame rounding.",
        @"Keep this much quiet audio immediately before speech resumes.",
        @"Keep this much quiet audio immediately after speech ends."
    ];
    NSMutableArray *fields = [NSMutableArray array];
    NSMutableArray<NSStackView *> *settingRows = [NSMutableArray array];
    for (NSUInteger i=0; i<4; i++) {
        NSTextField *name = label(names[i], NO);
        name.toolTip = explanations[i];
        [name.widthAnchor constraintEqualToConstant:112].active = YES;
        NSTextField *field = [NSTextField textFieldWithString:@""];
        compactControl(field);
        field.tag = i;
        field.delegate = self;
        field.alignment = NSTextAlignmentRight;
        field.accessibilityLabel = names[i];
        field.toolTip = explanations[i];
        field.identifier = [NSString stringWithFormat:@"cutdown.setting.%lu", (unsigned long)i];
        [field.widthAnchor constraintEqualToConstant:62].active = YES;
        [fields addObject:field];
        NSTextField *unit = label(i==0 ? @"dBFS" : @"sec", NO);
        unit.textColor = NSColor.secondaryLabelColor;
        unit.toolTip = explanations[i];
        [unit.widthAnchor constraintEqualToConstant:30].active = YES;
        NSStackView *row = horizontalRow(@[name, field, unit]);
        row.spacing = 5;
        [settingRows addObject:row];
    }
    for (NSUInteger i=0; i<2; i++) {
        NSStackView *pair = horizontalRow(@[settingRows[i*2], flexibleSpace(), settingRows[i*2+1]]);
        [content addArrangedSubview:pair];
        [pair.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    }
    self.fields = fields;
    self.outputMode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    compactControl(self.outputMode);
    [self.outputMode addItemsWithTitles:@[@"Remove Silence", @"Replace with 1-Second Gaps"]];
    self.outputMode.identifier = @"cutdown.output";
    self.outputMode.accessibilityLabel = @"Output";
    self.outputMode.toolTip = @"Remove selected pauses, or replace each with a one-second gap.";
    self.outputMode.target = self; self.outputMode.action = @selector(outputChanged:);
    NSTextField *outputLabel = label(@"Output", NO);
    outputLabel.toolTip = self.outputMode.toolTip;
    [outputLabel.widthAnchor constraintEqualToConstant:112].active = YES;
    NSStackView *outputRow = horizontalRow(@[outputLabel, self.outputMode]);
    outputRow.spacing = 8;
    [content addArrangedSubview:outputRow];
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
    [content addArrangedSubview:label(@"Review", YES)];
    self.summaryLabel = label(@"Review detected silence before applying cuts.", NO);
    self.summaryLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.summaryLabel.maximumNumberOfLines = 2;
    self.summaryLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addArrangedSubview:self.summaryLabel];
    [self.summaryLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor].active = YES;
    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.hasVerticalScroller = YES;
    scroll.verticalScroller.controlSize = NSControlSizeSmall;
    scroll.borderType = NSBezelBorder;
    self.resultsView = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 464, 88)];
    self.resultsView.accessibilityIdentifier = @"cutdown.review.cuts";
    self.resultsView.target = self;
    self.resultsView.doubleAction = @selector(jumpToCut:);
    self.resultsView.toolTip = @"Double-click a cut to go to it in the timeline.";
    self.resultsView.headerView = [NSTableHeaderView new];
    self.resultsView.rowHeight = 24;
    self.resultsView.usesAlternatingRowBackgroundColors = YES;
    self.resultsView.dataSource = self; self.resultsView.delegate = self;
    self.resultsView.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    NSArray<NSString *> *columnIDs = @[@"start", @"end", @"duration", @"availability"];
    NSArray<NSString *> *columnTitles = @[@"Include · Start", @"End", @"Duration", @"Note"];
    CGFloat widths[] = {154, 92, 75, 143};
    for (NSUInteger i=0; i<columnIDs.count; i++) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:columnIDs[i]];
        column.title = columnTitles[i];
        column.width = widths[i];
        column.minWidth = i == 3 ? 100 : widths[i];
        [self.resultsView addTableColumn:column];
    }
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
        [reviewArea.heightAnchor constraintGreaterThanOrEqualToConstant:112],
        [scroll.leadingAnchor constraintEqualToAnchor:reviewArea.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:reviewArea.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:reviewArea.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:reviewArea.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:reviewArea.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:reviewArea.centerYAnchor]
    ]];
    self.applyButton = [NSButton buttonWithTitle:@"Apply Cuts" target:self action:@selector(apply:)];
    self.applyButton.bezelStyle = NSBezelStyleRounded;
    self.applyButton.controlSize = NSControlSizeRegular;
    self.applyButton.font = [NSFont systemFontOfSize:12];
    self.applyButton.identifier = @"cutdown.apply";
    self.applyButton.toolTip = @"Available only after a valid analysis. This is a separate action from Analyze.";
    self.applyButton.enabled = NO;
    self.analyzeButton = [NSButton buttonWithTitle:@"Analyze" target:self action:@selector(analyze:)];
    self.analyzeButton.bezelStyle = NSBezelStyleRounded;
    self.analyzeButton.controlSize = NSControlSizeRegular;
    self.analyzeButton.font = [NSFont systemFontOfSize:12];
    self.analyzeButton.identifier = @"cutdown.analyze";
    [self.analyzeButton setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.retryButton = [NSButton buttonWithTitle:@"Retry Verification" target:self action:@selector(retryVerification:)];
    self.retryButton.controlSize = NSControlSizeRegular;
    self.retryButton.font = [NSFont systemFontOfSize:12];
    self.retryButton.enabled = NO; self.retryButton.hidden = YES;
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    compactControl(self.cancelButton); self.cancelButton.enabled = NO; self.cancelButton.hidden = YES;
    NSStackView *footer = horizontalRow(@[self.cancelButton, flexibleSpace(), self.retryButton, self.analyzeButton, self.applyButton]);
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
    [self updatePrimaryAction];
}

- (void)updatePrimaryAction {
    BOOL reviewing = [self.connection.state isEqual:CutdownReviewStateReview] && !self.settingsDirty && !self.connection.applying;
    BOOL hasEligibleCut = NO;
    for (NSDictionary *cut in self.cutRows) if ([cut[@"eligible"] boolValue]) { hasEligibleCut = YES; break; }
    BOOL showApply = self.connection.applying || (reviewing && hasEligibleCut);
    BOOL busy = self.connection.operationBusy || self.connection.awaitingResponse || self.connection.pendingRetry != nil || self.verificationPending != nil;
    BOOL showRetry = self.retryAvailable && !self.connection.pendingRetry && !busy;
    self.saveButton.enabled = self.audioUnit != nil && !busy && !self.connection.applying;
    self.analyzeButton.title = reviewing ? @"Analyze Again" : @"Analyze";
    self.analyzeButton.hidden = showApply || showRetry || busy;
    self.applyButton.hidden = !showApply;
    self.retryButton.hidden = !showRetry;
    self.analyzeButton.bezelColor = self.analyzeButton.hidden ? nil : NSColor.controlAccentColor;
    self.applyButton.bezelColor = self.applyButton.enabled ? NSColor.controlAccentColor : nil;
}

- (void)setStatusMessage:(NSString *)message {
    self.statusLabel.stringValue = message ?: @"";
    self.statusLabel.toolTip = message;
}

- (void)updateMoreMenuVisibility {
    BOOL reviewHasCuts = [self.connection.state isEqual:CutdownReviewStateReview] && !self.settingsDirty && self.cutRows.count > 0;
    BOOL hasEligibleCut = NO;
    for (NSDictionary *cut in self.cutRows) if ([cut[@"eligible"] boolValue]) { hasEligibleCut = YES; break; }
    self.analyzeAgainItem.hidden = !reviewHasCuts || !hasEligibleCut;
    self.jumpItem.hidden = !reviewHasCuts;
    self.selectAllItem.hidden = !reviewHasCuts || !hasEligibleCut;
    self.deselectAllItem.hidden = !reviewHasCuts || !hasEligibleCut;
    self.reviewActionsSeparator.hidden = !reviewHasCuts;
}
- (void)showMoreActions:(NSButton *)sender {
    [self updateMoreMenuVisibility];
    [self.moreMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMaxY(sender.bounds) + 4) inView:sender];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    BOOL idle = self.audioUnit != nil && !self.connection.operationBusy && !self.connection.applying &&
        !self.connection.awaitingResponse && !self.connection.pendingRetry && !self.verificationPending;
    if (item == self.analyzeAgainItem) return idle && [self.connection.state isEqual:CutdownReviewStateReview] && !self.settingsDirty;
    if (item == self.jumpItem) return idle && self.canHighlight && self.resultsView.selectedRow >= 0;
    if (item == self.selectAllItem || item == self.deselectAllItem)
        return idle && self.canChangeSelection && !self.connection.pendingSelection;
    return idle;
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
    self.canApply = NO; self.applyButton.enabled = NO;
    [self updatePrimaryAction];
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
            [self setStatusMessage:[NSString stringWithFormat:@"Enter a valid %@ between %g and %g.", parameter.displayName ?: @"setting", parameter.minValue, parameter.maxValue]];
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
    if (self.connection.applying || self.connection.operationBusy || self.connection.awaitingResponse ||
        self.connection.pendingRetry || self.verificationPending || ![self commitSettings]) return;
    self.settingsDirty = YES; self.canApply = NO; self.applyButton.enabled = NO;
    [self updatePrimaryAction];
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    [self refreshSettings];
    [self setStatusMessage:@"Settings saved."];
}

- (BOOL)restoreSettingsData:(NSData *)data {
    if (self.connection.applying || self.connection.operationBusy || self.connection.awaitingResponse ||
        self.connection.pendingRetry || self.verificationPending || data.length > 16384) return NO;
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
    [self updatePrimaryAction];
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    [self refreshSettings];
    [self setStatusMessage:@"Saved detection settings restored. Analyze again before applying cuts."];
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
        if (!data || ![self restoreSettingsData:data]) [self setStatusMessage:@"That file does not contain four valid Cutdown detection settings."];
    }];
}

- (void)outputChanged:(id)sender {
    self.settingsDirty = YES;
    self.canChangeSelection = NO; self.connection.pendingSelection = nil; [self.resultsView reloadData];
    self.canApply = NO; self.applyButton.enabled = NO;
    [self updatePrimaryAction];
    self.summaryLabel.stringValue = @"Output changed. Analyze again before applying.";
}

// Kept as a separate method so the UI harness can test clicks without launching apps.
- (BOOL)openAnalysisURL:(NSURL *)URL { return [NSWorkspace.sharedWorkspace openURL:URL]; }

- (void)analyze:(id)sender {
    if (self.verificationPending || self.connection.applying || self.connection.operationBusy || self.connection.awaitingResponse ||
        self.connection.pendingRetry || ![self commitSettings]) return;
    NSError *error = nil;
    CutdownAudioAnalysisRequest *request = [self.audioUnit analysisRequestWithError:&error];
    if (!request) { [self setStatusMessage:error.localizedDescription]; return; }
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
    self.retryAvailable = NO;
    [self updatePrimaryAction];
    self.cutRows = @[]; [self.resultsView reloadData];
    self.emptyLabel.hidden = NO;
    self.emptyLabel.stringValue = @"Detected cuts will appear here after analysis.";
    self.connection.pendingSelection = nil; self.connection.pendingRetry = nil; self.connection.pendingPreview = nil; self.canChangeSelection = NO;
    self.summaryLabel.stringValue = @"Waiting for analysis. No cuts have been applied.";
    [self setStatusMessage:@"Connecting to Cutdown…"];
    self.connection.awaitingResponse = YES; self.connection.lastResponse = NSDate.date;
    self.analyzeButton.enabled = NO;
    [self updatePrimaryAction];
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
        [self updatePrimaryAction];
        for (NSTextField *field in self.fields) field.enabled = YES;
        [self setStatusMessage:@"Cutdown could not open its background helper. Check the local installation, then Analyze again."];
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
                [self setStatusMessage:@"Verification could not be connected. Check the existing result before retrying; no new import was requested."];
                [self updatePrimaryAction];
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
        self.retryAvailable = NO;
        [self updatePrimaryAction];
        self.connection.pendingSelection = nil; self.canChangeSelection = NO;
        self.connection.pendingRetry = nil; self.connection.pendingPreview = nil;
        self.connection.pendingApply = nil; self.applyButton.identifier = @"cutdown.apply";
        self.cancelButton.enabled = NO;
        self.cancelButton.hidden = YES;
        self.progressBar.hidden = YES; self.progressLabel.hidden = YES;
        self.analyzeButton.enabled = YES; self.outputMode.enabled = YES;
        for (NSTextField *field in self.fields) field.enabled = YES;
        [self.resultsView reloadData];
        [self setStatusMessage:uncertainApply
            ? @"Apply could not be confirmed. Check your project before analyzing again; replacement may already have completed."
            : @"The helper is not responding. Analyze again to reconnect."];
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
        self.verificationPending = nil; [self setStatusMessage:value[@"error"]];
        [self updatePrimaryAction]; return;
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
    self.retryAvailable = NO;
    self.applyButton.identifier = @"cutdown.apply";
    self.connection.requestID = value[@"request"];
    self.connection.lastResponse = NSDate.date; self.connection.awaitingResponse = YES;
    for (NSUInteger i=0; i<4; i++) self.fields[i].stringValue = settingText([settings[i] floatValue]);
    self.submittedSettings = [self readFields];
    [self.outputMode selectItemAtIndex:[value[@"output"] isEqual:@"gaps"] ? 1 : 0];
    self.analyzeButton.enabled = NO; self.outputMode.enabled = NO;
    [self updatePrimaryAction];
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
            [self setStatusMessage:@"Choose the Cutdown.fcpxml file in the saved result folder."]; return;
        }
        if (self.connection.requestID)
            [NSDistributedNotificationCenter.defaultCenter removeObserver:self name:responseName(self.connection.requestID) object:nil];
        self.connection = [CutdownReviewConnection new]; self.settingsDirty = NO;
        self.retryAvailable = NO;
        self.applyButton.identifier = @"cutdown.apply";
        self.canApply = NO; self.applyButton.enabled = NO; self.cancelButton.enabled = NO;
        [self updatePrimaryAction];
        self.canChangeSelection = NO;
        self.retryButton.enabled = NO;
        self.cutRows = @[]; [self.resultsView reloadData];
        self.emptyLabel.hidden = NO;
        self.emptyLabel.stringValue = @"Detected cuts will appear here after analysis.";
        self.cancelButton.hidden = YES;
        NSURLComponents *url = [NSURLComponents componentsWithString:@"cutdown://verify"];
        url.queryItems = @[[NSURLQueryItem queryItemWithName:@"view" value:self.viewID],
            [NSURLQueryItem queryItemWithName:@"result" value:panel.URL.absoluteString]];
        self.verificationPending = NSDate.date;
        [self updatePrimaryAction];
        [self setStatusMessage:@"Connecting to the saved result…"];
        if (![self openAnalysisURL:url.URL]) {
            self.verificationPending = nil;
            [self setStatusMessage:@"Cutdown could not open its background helper."];
            [self updatePrimaryAction];
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
    NSString *identifier = column.identifier;
    if ([identifier isEqualToString:@"start"]) {
        NSButton *button = [NSButton checkboxWithTitle:cut[@"start"] ?: @"" target:self action:@selector(includeCut:)];
        compactControl(button); button.tag = row;
        button.state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        button.enabled = self.canChangeSelection && !self.connection.pendingSelection && !self.connection.applying && [cut[@"eligible"] boolValue];
        button.toolTip = [cut[@"reason"] isKindOfClass:NSString.class] ? cut[@"reason"] : @"Include this proposed cut";
        return button;
    }
    NSString *text = @"";
    if ([identifier isEqualToString:@"end"]) text = cut[@"end"] ?: @"";
    else if ([identifier isEqualToString:@"duration"]) text = cut[@"duration"] ?: @"";
    else if (![cut[@"eligible"] boolValue]) text = [cut[@"reason"] isKindOfClass:NSString.class] ? cut[@"reason"] : @"Unavailable";
    NSTextField *value = label(text, NO);
    value.font = [NSFont systemFontOfSize:11];
    value.textColor = [identifier isEqualToString:@"availability"] ? NSColor.secondaryLabelColor : NSColor.labelColor;
    value.maximumNumberOfLines = 1;
    value.lineBreakMode = NSLineBreakByTruncatingTail;
    value.toolTip = text;
    return value;
}
- (void)requestSelection:(NSDictionary *)fields {
    if (!self.canChangeSelection || self.connection.pendingSelection || self.connection.applying || !self.connection.revision) return;
    NSMutableDictionary *command = [@{@"version":@1, @"request":self.connection.requestID} mutableCopy];
    [command addEntriesFromDictionary:fields];
    command[@"expectedRevision"] = self.connection.revision;
    self.connection.pendingSelection = command; self.connection.selectionRevision = self.connection.revision;
    self.canApply = NO; self.applyButton.enabled = NO;
    [self updatePrimaryAction];
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
- (void)selectCuts:(NSMenuItem *)sender {
    [self requestSelection:@{@"command":sender == self.selectAllItem ? @"selectAll" : @"deselectAll"}];
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
    [self setStatusMessage:value[@"message"]];
    NSUInteger included = 0;
    for (NSDictionary *row in value[@"cuts"]) if ([row[@"eligible"] boolValue] && [row[@"included"] boolValue]) included++;
    self.canHighlight = [value[@"state"] isEqual:CutdownReviewStateReview] && [value[@"canHighlight"] isEqual:@YES];
    BOOL canRetry = [value[@"canRetryVerification"] isEqual:@YES] && CutdownReviewStateCanRetry(value[@"state"]);
    self.retryAvailable = canRetry;
    self.retryButton.enabled = canRetry && !self.connection.pendingRetry;
    self.cutRows = value[@"cuts"];
    self.emptyLabel.hidden = self.cutRows.count > 0;
    self.emptyLabel.stringValue = [value[@"state"] isEqual:CutdownReviewStateReview]
        ? @"No silence found with these settings." : @"Detected cuts will appear here after analysis.";
    self.canChangeSelection = !self.settingsDirty && [value[@"state"] isEqual:CutdownReviewStateReview] && [value[@"canChangeSelection"] isEqual:@YES];
    [self.resultsView reloadData];
    if (self.connection.applying && [value[@"state"] isEqual:CutdownReviewStateApplying]) self.connection.applyAcknowledged = YES;
    if (self.connection.applyAcknowledged || (self.connection.applying && CutdownReviewStateIsTerminal(value[@"state"]))) {
        self.connection.pendingApply = nil;
        self.applyButton.identifier = @"cutdown.apply";
    }
    if ([value[@"summary"] isKindOfClass:NSString.class]) self.summaryLabel.stringValue = value[@"summary"];
    else if ([value[@"state"] isEqual:CutdownReviewStateUnavailable]) self.summaryLabel.stringValue = @"Analysis is unavailable in this build. No cuts have been applied.";
    else if ([value[@"state"] isEqual:CutdownReviewStateFailed])
        self.summaryLabel.stringValue = [value[@"message"] isKindOfClass:NSString.class] && [value[@"message"] length] > 0
            ? value[@"message"] : @"Analysis stopped. No cut preview is available.";
    else if ([value[@"state"] isEqual:CutdownReviewStateCancelled])
        self.summaryLabel.stringValue = @"Analysis cancelled. No cut preview is available.";
    self.summaryLabel.toolTip = self.summaryLabel.stringValue;
    BOOL busy = CutdownReviewStateIsBusy(value[@"state"]);
    self.connection.operationBusy = busy;
    self.outputMode.enabled = !busy;
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
    [self updatePrimaryAction];
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
    [self updatePrimaryAction];
    self.connection.timedOut = NO;
    self.connection.lastResponse = NSDate.date;
    [self startPolling];
    [self sendPreviewCommand:self.connection.pendingRetry];
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
    [self updatePrimaryAction];
    self.connection.applyAcknowledged = NO; self.connection.lastResponse = NSDate.date;
    self.canChangeSelection = NO; [self.resultsView reloadData];
    self.outputMode.enabled = NO;
    self.connection.applyRevision = self.connection.revision;
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.applyButton.identifier = [@"cutdown.apply.requested." stringByAppendingString:gesture];
    self.connection.pendingApply = @{@"version":@1, @"request":self.connection.requestID,
        @"command":@"apply", @"expectedRevision":self.connection.revision,
        @"view":self.viewID, @"applyGesture":gesture};
    self.analyzeButton.enabled = NO;
    for (NSTextField *field in self.fields) field.enabled = NO;
    [self setStatusMessage:@"Requesting Apply Cuts…"];
    [self sendPreviewCommand:self.connection.pendingApply];
}
- (void)dealloc {
    [_pollTimer invalidate];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
}
@end
