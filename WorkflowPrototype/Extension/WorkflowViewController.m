#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreServices/CoreServices.h>
#import <QuartzCore/QuartzCore.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import "SSWorkflowPersistence-Swift.h"
#import "WorkflowReviewClient.h"
#import "WorkflowWindowClient.h"

static NSColor *SSWorkflowGray(CGFloat value) {
    return [NSColor colorWithSRGBRed:value green:value blue:value alpha:1];
}

@interface SSWorkflowDocument : NSStackView
@end
@implementation SSWorkflowDocument
- (BOOL)isFlipped { return YES; }
@end

// Final Cut's inspector uses flat charcoal sections. Keep AppKit responsible
// for text, focus rings, menus and control states inside those surfaces.
@interface SSWorkflowSection : SSWorkflowDocument
@end
@implementation SSWorkflowSection
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.backgroundColor = SSWorkflowGray(0.145).CGColor;
    self.layer.borderWidth = 0;
    self.layer.cornerRadius = 0;
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

// Keep each cut a native checkbox for selection and accessibility, while
// drawing its timing values in stable columns instead of one clipped title.
@interface SSWorkflowCutCell : NSButtonCell
@end
@implementation SSWorkflowCutCell
- (NSRect)drawTitle:(NSAttributedString *)title withFrame:(NSRect)frame inView:(NSView *)view { return frame; }
@end

@interface SSWorkflowCutRow : NSButton
@property (nonatomic, copy) NSString *startValue;
@property (nonatomic, copy) NSString *endValue;
@property (nonatomic, copy) NSString *durationValue;
@property (nonatomic, strong) NSFont *textFont;
- (NSRect)columnRectForIndex:(NSUInteger)index;
- (NSTextAlignment)textAlignmentForColumn:(NSUInteger)index;
@end
@implementation SSWorkflowCutRow
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 22); }
- (NSRect)columnRectForIndex:(NSUInteger)index {
    CGFloat height = ceil(self.textFont.ascender - self.textFont.descender);
    CGFloat origin = index == 0 ? 26 : (index == 1 ? 144 : fmax(262, self.bounds.size.width - 148));
    CGFloat width = index < 2 ? 110 : fmax(0, fmin(140, self.bounds.size.width - origin - 8));
    return NSMakeRect(origin, floor((self.bounds.size.height - height) / 2), width, height);
}
- (NSTextAlignment)textAlignmentForColumn:(NSUInteger)index {
    return index < 2 ? NSTextAlignmentLeft : NSTextAlignmentRight;
}
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentRight;
    style.lineBreakMode = NSLineBreakByClipping;
    NSDictionary *attributes = @{NSFontAttributeName: self.textFont,
        NSForegroundColorAttributeName: self.enabled ? NSColor.controlTextColor : NSColor.disabledControlTextColor,
        NSParagraphStyleAttributeName: style};
    NSArray *values = @[self.startValue ?: @"", self.endValue ?: @"", self.durationValue ?: @""];
    for (NSUInteger index = 0; index < values.count; ++index) {
        style.alignment = [self textAlignmentForColumn:index];
        [values[index] drawInRect:[self columnRectForIndex:index] withAttributes:attributes];
    }
}
@end

@interface SSWorkflowViewController : NSViewController <FCPXTimelineObserver, NSTextFieldDelegate>
@property (nonatomic, strong) id<FCPXHost> host;
@property (nonatomic, strong) SSWorkflowWindowClient *windowClient;
@property (nonatomic) BOOL viewVisible;
@property (nonatomic) BOOL windowClientRunning;
@property (nonatomic, strong) FCPXTimeline *timeline;
@property (nonatomic, strong) SSWorkflowSettingsBridge *settings;
@property (nonatomic, strong) NSTextField *projectLabel;
@property (nonatomic, strong) NSTextField *playheadLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSArray<NSTextField *> *fields;
@property (nonatomic, strong) NSPopUpButton *output;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSStackView *content;
@property (nonatomic, strong) NSView *contentColumn;
@property (nonatomic, strong) NSView *headerView;
@property (nonatomic, strong) NSView *footerView;
@property (nonatomic, strong) NSLayoutConstraint *footerHeightConstraint;
@property (nonatomic, strong) NSStackView *settingsPanel;
@property (nonatomic, strong) NSStackView *settingsGroups;
@property (nonatomic, strong) NSStackView *settingsTopRow;
@property (nonatomic, strong) NSStackView *settingsBottomRow;
@property (nonatomic, copy) NSArray<NSView *> *numericGroups;
@property (nonatomic) BOOL settingsWideLayout;
@property (nonatomic, strong) NSStackView *cutColumnHeader;
@property (nonatomic, strong) NSLayoutConstraint *cutColumnHeaderWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *durationHeaderWidthConstraint;
@property (nonatomic, strong) NSStackView *footerMainRow;
@property (nonatomic, strong) NSLayoutConstraint *footerStatusWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *footerActionsWidthConstraint;
@property (nonatomic, strong) NSStackView *reviewPanel;
@property (nonatomic, strong) NSScrollView *reviewScroll;
@property (nonatomic, strong) NSLayoutConstraint *reviewListHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *settingsPanelWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *reviewPanelWidthConstraint;
@property (nonatomic, strong) NSButton *detailsButton;
@property (nonatomic, strong) NSTextField *statusDetails;
@property (nonatomic) BOOL detailsExpanded;
@property (nonatomic) BOOL updatingDocumentLayout;
@property (nonatomic, strong) NSURL *libraryURL;
@property (nonatomic, strong) NSString *projectUID;
@property (nonatomic) NSUInteger contextGeneration;
@property (nonatomic) BOOL verificationPanelPending;
@property (nonatomic) NSUInteger verificationPanelToken;
@property (nonatomic) BOOL settingsLoaded;
@property (nonatomic, copy) NSString *viewID;
@property (nonatomic, strong) SSWorkflowReviewClient *reviewClient;
@property (nonatomic, strong) NSButton *analyzeButton;
@property (nonatomic, strong) NSButton *updateButton;
@property (nonatomic, strong) NSButton *verifyButton;
@property (nonatomic, strong) NSPopUpButton *navigateMenu;
@property (nonatomic, strong) NSButton *applyButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSButton *allButton;
@property (nonatomic, strong) NSButton *noneButton;
@property (nonatomic, strong) NSTextField *reviewSummary;
@property (nonatomic, strong) NSProgressIndicator *progressIndicator;
@property (nonatomic, strong) NSStackView *cutList;
@property (nonatomic, copy) NSArray<NSDictionary *> *reviewCuts;
@property (nonatomic, copy) NSDictionary *reviewResponse;
@property (nonatomic, copy) NSString *completionMessage;
@property (nonatomic, copy) NSDictionary *completionContext;
@property (nonatomic) NSUInteger reviewGeneration;
@end

@implementation SSWorkflowViewController

// The SDK can instantiate the principal controller off the main thread.
// Establish AppKit's main-thread initialization boundary before any views or
// Swift objects are created. No Swift actor checks are disabled.
- (instancetype)initWithNibName:(NSNibName)nibNameOrNil bundle:(NSBundle *)bundle {
    if (NSThread.isMainThread) return [super initWithNibName:nil bundle:nil];
    __block SSWorkflowViewController *initialized;
    dispatch_sync(dispatch_get_main_queue(), ^{ initialized = [super initWithNibName:nil bundle:nil]; });
    self = initialized;
    return self;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    return label;
}

- (NSStackView *)cardWithViews:(NSArray<NSView *> *)views {
    NSStackView *card = [SSWorkflowSection stackViewWithViews:views];
    card.wantsLayer = YES;
    card.orientation = NSUserInterfaceLayoutOrientationVertical;
    card.alignment = NSLayoutAttributeLeading;
    card.spacing = 8;
    card.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    return card;
}

// These read-only extension size hints are advisory; the host can ignore
// them. They do not install preferredContentSize constraints on the root.
- (NSSize)preferredMaximumSize { return NSMakeSize(560, CGFLOAT_MAX); }
- (NSSize)preferredMinimumSize { return NSMakeSize(460, 300); }

- (void)loadView {
    // The SDK owns the window size. Keep the root frame-driven so its remote
    // viewport can resize it without introducing preferred-size constraints.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
    self.view.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.view.wantsLayer = YES;
    self.view.layer.backgroundColor = SSWorkflowGray(0.12).CGColor;
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.settings = [SSWorkflowSettingsBridge new];
    self.viewID = NSUUID.UUID.UUIDString;
    self.contentColumn = [[NSView alloc] initWithFrame:self.view.bounds];
    self.contentColumn.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    [self.view addSubview:self.contentColumn];
    self.headerView = [NSView new];
    self.footerView = [NSView new];
    for (NSView *chrome in @[self.headerView, self.footerView]) {
        chrome.wantsLayer = YES;
        chrome.layer.backgroundColor = SSWorkflowGray(0.145).CGColor;
    }
    self.scroll = [NSScrollView new];
    self.scroll.drawsBackground = NO;
    self.scroll.hasVerticalScroller = YES;
    self.scroll.hasHorizontalScroller = NO;
    self.scroll.autohidesScrollers = YES;
    for (NSView *part in @[self.headerView, self.scroll, self.footerView]) {
        part.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentColumn addSubview:part];
    }

    self.connectButton = [NSButton buttonWithTitle:@"Connect to Final Cut Pro" target:self action:@selector(requestConnection:)];
    self.connectButton.accessibilityIdentifier = @"silentsnip.workflow.connect";
    self.connectButton.hidden = YES;
    self.projectLabel = [self label:@"Connecting to Final Cut Pro…" size:13 weight:NSFontWeightSemibold];
    self.projectLabel.maximumNumberOfLines = 1;
    self.projectLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.projectLabel.accessibilityIdentifier = @"silentsnip.workflow.project";
    [self.projectLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.playheadLabel = [self label:@"Playhead —" size:11 weight:NSFontWeightRegular];
    self.playheadLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.playheadLabel.textColor = NSColor.secondaryLabelColor;
    self.playheadLabel.maximumNumberOfLines = 1;
    self.playheadLabel.accessibilityIdentifier = @"silentsnip.workflow.playhead";
    NSStackView *project = [NSStackView stackViewWithViews:@[self.projectLabel, self.playheadLabel]];
    project.orientation = NSUserInterfaceLayoutOrientationVertical;
    project.alignment = NSLayoutAttributeLeading;
    project.spacing = 3;
    NSMutableArray *headerItems = [NSMutableArray new];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil];
    if (icon) {
        NSImageView *image = [NSImageView imageViewWithImage:icon];
        image.imageScaling = NSImageScaleProportionallyUpOrDown;
        image.contentTintColor = NSColor.secondaryLabelColor;
        [image.widthAnchor constraintEqualToConstant:18].active = YES;
        [image.heightAnchor constraintEqualToConstant:18].active = YES;
        [headerItems addObject:image];
    }
    [headerItems addObjectsFromArray:@[project, self.connectButton]];
    NSStackView *header = [NSStackView stackViewWithViews:headerItems];
    header.spacing = 8;
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:header];
    NSBox *headerRule = [NSBox new];
    NSBox *footerRule = [NSBox new];
    headerRule.boxType = footerRule.boxType = NSBoxSeparator;
    for (NSBox *rule in @[headerRule, footerRule]) rule.translatesAutoresizingMaskIntoConstraints = NO;
    [self.headerView addSubview:headerRule];
    [self.footerView addSubview:footerRule];
    [NSLayoutConstraint activateConstraints:@[
        [headerRule.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [headerRule.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor],
        [headerRule.bottomAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [headerRule.heightAnchor constraintEqualToConstant:1],
        [footerRule.leadingAnchor constraintEqualToAnchor:self.footerView.leadingAnchor],
        [footerRule.trailingAnchor constraintEqualToAnchor:self.footerView.trailingAnchor],
        [footerRule.topAnchor constraintEqualToAnchor:self.footerView.topAnchor],
        [footerRule.heightAnchor constraintEqualToConstant:1]
    ]];

    NSMutableArray *fields = [NSMutableArray new];
    NSMutableArray *groups = [NSMutableArray new];
    NSArray *labels = @[@"Silence threshold", @"Minimum silence", @"Before speech", @"After speech"];
    NSArray *units = @[@"dBFS", @"sec", @"sec", @"sec"];
    for (NSUInteger index = 0; index < labels.count; ++index) {
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
        field.controlSize = NSControlSizeSmall;
        field.bezelStyle = NSTextFieldSquareBezel;
        field.alignment = NSTextAlignmentRight;
        field.accessibilityLabel = labels[index];
        field.accessibilityIdentifier = [NSString stringWithFormat:@"silentsnip.workflow.setting.%lu", (unsigned long)index];
        field.delegate = self;
        [field.widthAnchor constraintEqualToConstant:64].active = YES;
        NSTextField *name = [self label:labels[index] size:11 weight:NSFontWeightRegular];
        name.maximumNumberOfLines = 1;
        NSTextField *unit = [self label:units[index] size:11 weight:NSFontWeightRegular];
        unit.textColor = NSColor.secondaryLabelColor;
        unit.maximumNumberOfLines = 1;
        unit.lineBreakMode = NSLineBreakByClipping;
        [unit.widthAnchor constraintEqualToConstant:36].active = YES;
        NSStackView *value = [NSStackView stackViewWithViews:@[field, unit]];
        value.spacing = 6;
        NSStackView *group = [NSStackView stackViewWithViews:@[name, value]];
        group.orientation = NSUserInterfaceLayoutOrientationVertical;
        group.alignment = NSLayoutAttributeLeading;
        group.spacing = 3;
        [groups addObject:group];
        [fields addObject:field];
    }
    self.fields = fields;
    self.numericGroups = groups;
    self.settingsTopRow = [NSStackView stackViewWithViews:@[groups[0], groups[1]]];
    self.settingsBottomRow = [NSStackView stackViewWithViews:@[groups[2], groups[3]]];
    for (NSStackView *row in @[self.settingsTopRow, self.settingsBottomRow]) {
        row.distribution = NSStackViewDistributionFillEqually;
        row.spacing = 14;
    }
    self.settingsGroups = [NSStackView stackViewWithViews:@[self.settingsTopRow, self.settingsBottomRow]];
    self.settingsGroups.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.settingsGroups.alignment = NSLayoutAttributeLeading;
    self.settingsGroups.spacing = 8;
    self.output = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.output.font = [NSFont systemFontOfSize:11];
    self.output.controlSize = NSControlSizeSmall;
    self.output.bezelStyle = NSBezelStyleAccessoryBarAction;
    [self.output addItemsWithTitles:@[@"Remove Silence", @"Replace with 1-Second Gaps"]];
    self.output.accessibilityLabel = @"Output";
    self.output.accessibilityIdentifier = @"silentsnip.workflow.output";
    self.output.target = self;
    self.output.action = @selector(settingsChanged:);
    [self.output setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.output setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.saveButton = [NSButton buttonWithTitle:@"Save Settings" target:self action:@selector(saveSettings:)];
    self.saveButton.accessibilityIdentifier = @"silentsnip.workflow.save";
    NSTextField *outputLabel = [self label:@"Output" size:11 weight:NSFontWeightRegular];
    outputLabel.maximumNumberOfLines = 1;
    [outputLabel.widthAnchor constraintEqualToConstant:42].active = YES;
    [self.saveButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.saveButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *outputRow = [NSStackView stackViewWithViews:@[outputLabel, self.output, self.saveButton]];
    outputRow.distribution = NSStackViewDistributionFill;
    outputRow.spacing = 10;
    self.settingsPanel = [self cardWithViews:@[self.settingsGroups, outputRow]];

    self.statusLabel = [self label:@"" size:11 weight:NSFontWeightRegular];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.maximumNumberOfLines = 2;
    self.statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusLabel.accessibilityIdentifier = @"silentsnip.workflow.status";
    [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.detailsButton = [NSButton buttonWithTitle:@"Details" target:self action:@selector(toggleDetails:)];
    self.detailsButton.bezelStyle = NSBezelStyleInline;
    self.detailsButton.font = [NSFont systemFontOfSize:11];
    self.detailsButton.accessibilityIdentifier = @"silentsnip.workflow.details";
    self.detailsButton.hidden = YES;
    self.statusDetails = [self label:self.statusLabel.stringValue size:11 weight:NSFontWeightRegular];
    self.statusDetails.textColor = NSColor.secondaryLabelColor;
    self.statusDetails.accessibilityIdentifier = @"silentsnip.workflow.status-details";
    self.statusDetails.hidden = YES;
    self.analyzeButton = [NSButton buttonWithTitle:@"Analyze Audio" target:self action:@selector(analyzeAudio:)];
    self.analyzeButton.accessibilityIdentifier = @"silentsnip.workflow.analyze";
    self.updateButton = [NSButton buttonWithTitle:@"Update Cuts" target:self action:@selector(updateCuts:)];
    self.updateButton.accessibilityIdentifier = @"silentsnip.workflow.update";
    self.verifyButton = [NSButton buttonWithTitle:@"Verify Existing Result…" target:self action:@selector(verifyExistingResult:)];
    self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
    [self.settingsPanel addArrangedSubview:self.verifyButton];
    self.settingsPanel.spacing = 4;
    self.applyButton = [NSButton buttonWithTitle:@"Apply Cuts" target:self action:@selector(applyCuts:)];
    self.applyButton.accessibilityIdentifier = @"silentsnip.workflow.apply";
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelReview:)];
    // This marker must remain visible even while idle and disabled: the worker
    // verifies this native view together with a fresh disabled gesture button.
    self.cancelButton.accessibilityIdentifier = [@"silentsnip.workflow.review." stringByAppendingString:self.viewID];
    self.retryButton = [NSButton buttonWithTitle:@"Retry Verification" target:self action:@selector(retryVerification:)];
    self.retryButton.hidden = YES;
    for (NSButton *button in @[self.connectButton, self.saveButton, self.verifyButton,
        self.analyzeButton, self.updateButton, self.applyButton, self.retryButton, self.cancelButton]) {
        button.controlSize = NSControlSizeSmall;
        button.bezelStyle = NSBezelStyleAccessoryBarAction;
        button.font = [NSFont systemFontOfSize:11];
    }
    NSView *actionSpring = [NSView new];
    [actionSpring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *actions = [NSStackView stackViewWithViews:@[actionSpring, self.analyzeButton, self.updateButton, self.applyButton, self.retryButton, self.cancelButton]];
    [actions setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    actions.spacing = 8;
    NSStackView *status = [NSStackView stackViewWithViews:@[self.statusLabel, self.detailsButton]];
    status.spacing = 8;
    status.alignment = NSLayoutAttributeCenterY;
    self.progressIndicator = [NSProgressIndicator new];
    self.progressIndicator.style = NSProgressIndicatorStyleBar;
    self.progressIndicator.minValue = 0;
    self.progressIndicator.maxValue = 1;
    self.progressIndicator.hidden = YES;
    [self.progressIndicator.heightAnchor constraintEqualToConstant:3].active = YES;
    self.footerMainRow = [NSStackView stackViewWithViews:@[status, actions]];
    self.footerMainRow.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.footerMainRow.alignment = NSLayoutAttributeLeading;
    self.footerMainRow.spacing = 3;
    self.footerStatusWidthConstraint = [status.widthAnchor constraintEqualToAnchor:self.footerMainRow.widthAnchor];
    self.footerActionsWidthConstraint = [actions.widthAnchor constraintEqualToAnchor:self.footerMainRow.widthAnchor];
    NSStackView *footer = [NSStackView stackViewWithViews:@[self.footerMainRow, self.progressIndicator]];
    footer.orientation = NSUserInterfaceLayoutOrientationVertical;
    footer.alignment = NSLayoutAttributeLeading;
    footer.spacing = 3;
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.footerView addSubview:footer];

    self.reviewSummary = [self label:@"Select a clip to analyze." size:12 weight:NSFontWeightRegular];
    self.reviewSummary.accessibilityIdentifier = @"silentsnip.workflow.summary";
    self.reviewSummary.maximumNumberOfLines = 2;
    self.reviewSummary.lineBreakMode = NSLineBreakByTruncatingTail;
    self.allButton = [NSButton buttonWithTitle:@"Select All" target:self action:@selector(selectAllCuts:)];
    self.noneButton = [NSButton buttonWithTitle:@"Deselect All" target:self action:@selector(deselectAllCuts:)];
    self.navigateMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    [self.navigateMenu addItemWithTitle:@"Go to Cut"];
    self.navigateMenu.accessibilityIdentifier = @"silentsnip.workflow.navigate";
    self.navigateMenu.controlSize = NSControlSizeSmall;
    self.navigateMenu.bezelStyle = NSBezelStyleAccessoryBarAction;
    self.navigateMenu.font = [NSFont systemFontOfSize:11];
    for (NSButton *button in @[self.allButton, self.noneButton]) {
        button.controlSize = NSControlSizeSmall;
        button.font = [NSFont systemFontOfSize:11];
        button.bezelStyle = NSBezelStyleAccessoryBarAction;
    }
    NSView *reviewSpring = [NSView new];
    [reviewSpring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *reviewActions = [NSStackView stackViewWithViews:@[[self label:@"Cut review" size:12 weight:NSFontWeightSemibold], reviewSpring, self.navigateMenu, self.allButton, self.noneButton]];
    reviewActions.spacing = 6;
    self.cutList = [SSWorkflowDocument stackViewWithViews:@[]];
    self.cutList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.cutList.alignment = NSLayoutAttributeLeading;
    self.cutList.spacing = 2;
    self.cutList.edgeInsets = NSEdgeInsetsMake(6, 6, 6, 6);
    self.cutList.translatesAutoresizingMaskIntoConstraints = YES;
    self.cutList.autoresizingMask = NSViewWidthSizable;
    self.reviewScroll = [NSScrollView new];
    self.reviewScroll.drawsBackground = YES;
    self.reviewScroll.backgroundColor = SSWorkflowGray(0.105);
    self.reviewScroll.hasVerticalScroller = YES;
    self.reviewScroll.hasHorizontalScroller = NO;
    self.reviewScroll.autohidesScrollers = YES;
    self.reviewScroll.borderType = NSBezelBorder;
    self.reviewScroll.documentView = self.cutList;
    self.reviewListHeightConstraint = [self.reviewScroll.heightAnchor constraintEqualToConstant:320];
    self.reviewListHeightConstraint.active = YES;
    NSMutableArray<NSTextField *> *columnLabels = [NSMutableArray new];
    for (NSString *title in @[@"Start", @"End", @"Duration"]) {
        NSTextField *column = [self label:title size:11 weight:NSFontWeightMedium];
        column.textColor = NSColor.secondaryLabelColor;
        column.alignment = columnLabels.count < 2 ? NSTextAlignmentLeft : NSTextAlignmentRight;
        column.maximumNumberOfLines = 1;
        [columnLabels addObject:column];
    }
    NSView *columnSpring = [NSView new];
    [columnSpring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.cutColumnHeader = [NSStackView stackViewWithViews:@[columnLabels[0], columnLabels[1], columnSpring, columnLabels[2]]];
    self.cutColumnHeader.distribution = NSStackViewDistributionFill;
    [columnLabels[0].widthAnchor constraintEqualToConstant:110].active = YES;
    [columnLabels[1].widthAnchor constraintEqualToConstant:110].active = YES;
    self.durationHeaderWidthConstraint = [columnLabels[2].widthAnchor constraintEqualToConstant:140];
    self.durationHeaderWidthConstraint.active = YES;
    self.cutColumnHeader.spacing = 8;
    [self.cutColumnHeader setCustomSpacing:0 afterView:columnLabels[1]];
    self.cutColumnHeader.edgeInsets = NSEdgeInsetsMake(0, 33, 0, 13);
    self.cutColumnHeaderWidthConstraint = [self.cutColumnHeader.widthAnchor constraintEqualToConstant:400];
    self.cutColumnHeaderWidthConstraint.active = YES;
    self.reviewPanel = [self cardWithViews:@[reviewActions, self.reviewSummary,
        self.statusDetails, self.cutColumnHeader, self.reviewScroll]];
    self.reviewPanel.spacing = 4;
    self.content = [SSWorkflowDocument stackViewWithViews:@[self.settingsPanel, self.reviewPanel]];
    self.content.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.content.alignment = NSLayoutAttributeLeading;
    self.content.spacing = 12;
    self.content.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    self.content.translatesAutoresizingMaskIntoConstraints = YES;
    self.content.autoresizingMask = NSViewWidthSizable;
    self.scroll.documentView = self.content;
    self.settingsPanelWidthConstraint = [self.settingsPanel.widthAnchor constraintEqualToConstant:448];
    self.reviewPanelWidthConstraint = [self.reviewPanel.widthAnchor constraintEqualToConstant:448];
    self.footerHeightConstraint = [self.footerView.heightAnchor constraintEqualToConstant:64];
    [NSLayoutConstraint activateConstraints:@[
        self.settingsPanelWidthConstraint, self.reviewPanelWidthConstraint,
        [self.settingsGroups.widthAnchor constraintEqualToAnchor:self.settingsPanel.widthAnchor constant:-24],
        [self.settingsTopRow.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        [self.settingsBottomRow.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        [outputRow.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        [self.reviewScroll.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [reviewActions.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [self.reviewSummary.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [self.reviewSummary.heightAnchor constraintEqualToConstant:30],
        [self.statusDetails.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [self.headerView.leadingAnchor constraintEqualToAnchor:self.contentColumn.leadingAnchor],
        [self.headerView.trailingAnchor constraintEqualToAnchor:self.contentColumn.trailingAnchor],
        [self.headerView.topAnchor constraintEqualToAnchor:self.contentColumn.topAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:44],
        [header.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:16],
        [header.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-16],
        [header.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.projectLabel.widthAnchor constraintEqualToAnchor:project.widthAnchor],
        [self.footerView.leadingAnchor constraintEqualToAnchor:self.contentColumn.leadingAnchor],
        [self.footerView.trailingAnchor constraintEqualToAnchor:self.contentColumn.trailingAnchor],
        [self.footerView.bottomAnchor constraintEqualToAnchor:self.contentColumn.bottomAnchor],
        self.footerHeightConstraint,
        [footer.leadingAnchor constraintEqualToAnchor:self.footerView.leadingAnchor constant:16],
        [footer.trailingAnchor constraintEqualToAnchor:self.footerView.trailingAnchor constant:-16],
        [footer.topAnchor constraintEqualToAnchor:self.footerView.topAnchor constant:7],
        [self.footerMainRow.widthAnchor constraintEqualToAnchor:footer.widthAnchor],
        [self.progressIndicator.widthAnchor constraintEqualToAnchor:footer.widthAnchor],
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.contentColumn.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.contentColumn.trailingAnchor],
        [self.scroll.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.footerView.topAnchor]
    ]];
    [self setControlsEnabled:NO];
    [self updateReviewControls];
    [self updateDocumentFrame];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self updateDocumentFrame];
}

- (void)updateDocumentFrame {
    if (self.updatingDocumentLayout || !self.content || !self.scroll) return;
    CGFloat hostHeight = self.view.bounds.size.height;
    CGFloat columnWidth = fmin(560, self.view.bounds.size.width);
    if (columnWidth <= 48 || hostHeight <= 0) return;
    self.updatingDocumentLayout = YES;
    self.reviewScroll.hidden = NO;
    self.cutColumnHeader.hidden = NO;
    self.reviewListHeightConstraint.constant = 320;
    BOOL settingsWide = columnWidth >= 530;
    if (self.settingsWideLayout != settingsWide) {
        for (NSUInteger index = 2; index < self.numericGroups.count; ++index) {
            NSView *group = self.numericGroups[index];
            NSStackView *source = settingsWide ? self.settingsBottomRow : self.settingsTopRow;
            NSStackView *destination = settingsWide ? self.settingsTopRow : self.settingsBottomRow;
            [source removeArrangedSubview:group];
            [group removeFromSuperview];
            [destination addArrangedSubview:group];
        }
        self.settingsWideLayout = settingsWide;
    }
    self.settingsBottomRow.hidden = settingsWide;
    self.footerHeightConstraint.constant = 64;
    self.footerStatusWidthConstraint.active = YES;
    self.footerActionsWidthConstraint.active = YES;
    self.footerMainRow.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.footerMainRow.alignment = NSLayoutAttributeLeading;
    self.content.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.content.alignment = NSLayoutAttributeLeading;
    self.statusLabel.preferredMaxLayoutWidth = fmax(100, columnWidth - 104);
    // The host owns root size. Reserve the same review area for idle, short,
    // and long reviews; only the list and the surrounding body can scroll.
    NSRect columnFrame = NSMakeRect(floor((self.view.bounds.size.width - columnWidth) / 2),
        0, columnWidth, hostHeight);
    if (!NSEqualRects(self.contentColumn.frame, columnFrame)) self.contentColumn.frame = columnFrame;
    for (NSUInteger pass = 0; pass < 2; ++pass) {
        [self.contentColumn layoutSubtreeIfNeeded];
        [self.scroll tile];
        CGFloat width = self.scroll.contentView.bounds.size.width;
        CGFloat cardWidth = width - 24;
        self.settingsPanelWidthConstraint.constant = cardWidth;
        self.reviewPanelWidthConstraint.constant = cardWidth;
        self.reviewSummary.preferredMaxLayoutWidth = cardWidth - 24;
        self.statusDetails.preferredMaxLayoutWidth = cardWidth - 24;
        NSSize contentWidthSize = NSMakeSize(width, self.content.frame.size.height);
        if (!NSEqualSizes(self.content.frame.size, contentWidthSize)) [self.content setFrameSize:contentWidthSize];
        [self.content layoutSubtreeIfNeeded];
        [self.reviewScroll tile];
        CGFloat listWidth = self.reviewScroll.contentView.bounds.size.width;
        self.cutColumnHeaderWidthConstraint.constant = fmax(1, listWidth);
        CGFloat rowWidth = listWidth - 12;
        CGFloat durationOrigin = fmax(262, rowWidth - 148);
        self.durationHeaderWidthConstraint.constant = fmax(0, fmin(140, rowWidth - durationOrigin - 8));
        NSSize listSize = NSMakeSize(fmax(1, listWidth), fmax(1, ceil(self.cutList.fittingSize.height)));
        if (!NSEqualSizes(self.cutList.frame.size, listSize)) [self.cutList setFrameSize:listSize];
        [self.cutList layoutSubtreeIfNeeded];
        NSSize bodySize = NSMakeSize(width, fmax(1, ceil(self.content.fittingSize.height)));
        if (!NSEqualSizes(self.content.frame.size, bodySize)) [self.content setFrameSize:bodySize];
        [self.content layoutSubtreeIfNeeded];
    }
    self.updatingDocumentLayout = NO;
}

- (void)setStatusMessage:(NSString *)message {
    [self setStatusMessage:message requiresAttention:NO];
}

- (void)setStatusMessage:(NSString *)message requiresAttention:(BOOL)requiresAttention {
    message = message ?: @"";
    BOOL changed = ![self.statusDetails.stringValue isEqual:message];
    self.statusDetails.stringValue = message;
    self.statusDetails.toolTip = message;
    self.statusLabel.toolTip = message;
    BOOL longMessage = message.length > 180;
    self.detailsButton.hidden = !longMessage;
    if (!longMessage) {
        self.statusLabel.stringValue = message;
        self.detailsExpanded = NO;
    } else {
        NSString *state = self.reviewResponse[@"state"];
        BOOL attention = requiresAttention || [self.reviewResponse[@"canRetryVerification"] boolValue] ||
            [@[@"failed", @"unavailable", @"error", @"cancelled"] containsObject:state];
        // Local persistence and transport errors carry explicit presentation
        // intent: an earlier review or completion cannot classify that error.
        if (changed || requiresAttention) self.detailsExpanded = attention;
        if (requiresAttention) self.statusLabel.stringValue = @"Unable to finish. Review the details.";
        else if ([self.reviewResponse[@"canRetryVerification"] boolValue]) self.statusLabel.stringValue = @"Verification needs attention. Review the details.";
        else if ([state isEqual:@"cancelled"]) self.statusLabel.stringValue = @"Cancelled. Review the details.";
        else if (attention) self.statusLabel.stringValue = @"Unable to finish. Review the details.";
        else if (self.reviewClient.busy) self.statusLabel.stringValue = @"Working in Final Cut Pro…";
        else if ([@[@"completed", @"complete"] containsObject:state]) self.statusLabel.stringValue = @"Cuts applied.";
        else self.statusLabel.stringValue = @"";
    }
    self.statusDetails.hidden = !longMessage || !self.detailsExpanded;
    self.detailsButton.title = self.detailsExpanded ? @"Hide Details" : @"Details";
    [self updateDocumentFrame];
}

- (void)toggleDetails:(id)sender {
    if (self.detailsButton.hidden) return;
    self.detailsExpanded = !self.detailsExpanded;
    self.statusDetails.hidden = !self.detailsExpanded;
    self.detailsButton.title = self.detailsExpanded ? @"Hide Details" : @"Details";
    [self updateDocumentFrame];
}

- (void)setControlsEnabled:(BOOL)enabled {
    enabled = enabled && !self.verificationPanelPending && !self.reviewClient.busy && ![self.reviewResponse[@"canRetryVerification"] boolValue];
    for (NSTextField *field in self.fields) field.enabled = enabled;
    self.output.enabled = enabled;
    self.saveButton.enabled = enabled;
    self.analyzeButton.enabled = enabled && !self.reviewClient.busy;
    self.verifyButton.enabled = enabled;
}

- (SSWorkflowWindowClient *)newWindowClient {
    return [[SSWorkflowWindowClient alloc] initWithViewID:self.viewID];
}

- (BOOL)hasVerifiedWindowHost {
    return [self.host conformsToProtocol:@protocol(FCPXHost)] &&
        [@"com.apple.FinalCut" isEqual:self.host.bundleIdentifier];
}

- (void)stopWindowClient {
    if (!self.windowClientRunning) return;
    self.windowClientRunning = NO;
    [self.windowClient stop];
}

- (void)startWindowClientIfVisible {
    if (!self.viewVisible || ![self hasVerifiedWindowHost]) {
        [self stopWindowClient];
        return;
    }
    if (!self.windowClient) self.windowClient = [self newWindowClient];
    if (!self.windowClient) return;
    self.windowClientRunning = YES;
    [self.windowClient start];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    self.viewVisible = YES;
    if (self.host) {
        [self startWindowClientIfVisible];
        return;
    }
    id singleton = ProExtensionHostSingleton();
    if (![singleton conformsToProtocol:@protocol(FCPXHost)]) {
        [self stopWindowClient];
        [self setStatusMessage:@"Open this extension from Final Cut Pro."];
        return;
    }
    self.host = singleton;
    if (![@"com.apple.FinalCut" isEqual:self.host.bundleIdentifier]) {
        [self stopWindowClient];
        self.host = nil;
        [self setStatusMessage:@"The Final Cut host could not be verified."];
        return;
    }
    [self startWindowClientIfVisible];
    [self checkConnection:NO];
}

// The public permission API may wait indefinitely for a user's response and
// must run off the main thread. ask=NO observes permission without prompting.
- (void)checkHostPermissionAskingUser:(BOOL)ask completion:(void (^)(OSStatus))completion {
    NSString *bundleIdentifier = [self.host.bundleIdentifier copy];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *identifier = [bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding];
        AEAddressDesc target = {typeNull, NULL};
        OSStatus status = AECreateDesc(typeApplicationBundleID, identifier.bytes, identifier.length, &target);
        if (status == noErr) {
            status = AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, ask);
            AEDisposeDesc(&target);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status); });
    });
}

- (void)requestConnection:(id)sender { [self checkConnection:YES]; }

- (void)checkConnection:(BOOL)ask {
    // Window sizing belongs to the verified visible extension, independent
    // of permission to inspect a project or the presence of a selection.
    [self startWindowClientIfVisible];
    if (!self.viewVisible || ![self hasVerifiedWindowHost]) return;
    NSUInteger generation = self.contextGeneration;
    self.connectButton.enabled = NO;
    [self setStatusMessage:ask ? @"Waiting for macOS permission…" : @"Checking the Final Cut connection…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self checkHostPermissionAskingUser:ask completion:^(OSStatus status) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || !owner.viewVisible || generation != owner.contextGeneration) return;
        if (![owner hasVerifiedWindowHost]) {
            [owner stopWindowClient];
            return;
        }
        if (status != noErr) {
            owner.connectButton.hidden = NO;
            owner.connectButton.enabled = YES;
            owner.projectLabel.stringValue = @"Connect to Final Cut Pro";
            [owner setStatusMessage:@"Allow access to display the open project and playhead."];
            return;
        }
        owner.connectButton.hidden = YES;
        owner.timeline = owner.host.timeline;
        [owner.timeline addTimelineObserver:owner];
        [owner refreshProject];
    }];
}

- (void)viewWillDisappear {
    self.viewVisible = NO;
    self.verificationPanelPending = NO;
    self.verificationPanelToken += 1;
    [self stopWindowClient];
    [self clearCompletionMessage];
    [self invalidateReview];
    [self.timeline removeTimelineObserver:self];
    self.timeline = nil;
    self.host = nil;
    self.contextGeneration += 1;
    self.libraryURL = nil;
    self.projectUID = nil;
    self.settingsLoaded = NO;
    [self setControlsEnabled:NO];
    [super viewWillDisappear];
}

- (void)activeSequenceChanged { [self onMain:^{ if (self.timeline) [self refreshProject]; }]; }
- (void)sequenceTimeRangeChanged { [self onMain:^{ if (self.timeline) [self refreshPlayhead]; }]; }
- (void)playheadTimeChanged { [self onMain:^{ if (self.timeline) [self refreshPlayhead]; }]; }
- (void)onMain:(dispatch_block_t)block {
    if (NSThread.isMainThread) block(); else dispatch_async(dispatch_get_main_queue(), block);
}

- (NSDictionary *)observedProjectContext {
    FCPXSequence *sequence = self.timeline.activeSequence;
    if (!sequence || sequence.objectType != kFCPXObjectType_Sequence) return nil;
    // Proxy classes have no linkable class symbols. Discriminate each public
    // objectType before a C cast; require the complete documented ancestry.
    FCPXObject *projectObject = sequence.container;
    if (!projectObject || projectObject.objectType != kFCPXObjectType_Project) return nil;
    FCPXProject *project = (FCPXProject *)projectObject;
    FCPXObject *event = project.container;
    if (!event || event.objectType != kFCPXObjectType_Event) return nil;
    FCPXObject *libraryObject = event.container;
    if (!libraryObject || libraryObject.objectType != kFCPXObjectType_Library) return nil;
    FCPXLibrary *library = (FCPXLibrary *)libraryObject;
    if (!project.UID.length || !library.url.isFileURL) return nil;
    return @{@"projectUID": project.UID, @"libraryURL": library.url.standardizedURL,
             @"projectName": project.name ?: @"Untitled project", @"libraryName": library.name ?: @""};
}

- (void)refreshProject {
    // The host can temporarily omit its active sequence while an extension's
    // file sheet owns presentation. Its pinned identity is checked again after
    // dismissal; these transient notifications must not unload its settings.
    if (self.verificationPanelPending) return;
    // The worker can temporarily open an isolated analysis project or the
    // verified result. Keep its request bound until that operation settles.
    if (self.reviewClient.busy || [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    NSDictionary *context = [self observedProjectContext];
    if (self.completionMessage && (![context[@"projectUID"] isEqual:self.completionContext[@"projectUID"]] ||
        ![context[@"libraryURL"] isEqual:self.completionContext[@"libraryURL"]])) [self clearCompletionMessage];
    self.projectLabel.stringValue = context[@"projectName"] ?: @"Open a project in Final Cut Pro";
    self.projectLabel.toolTip = self.projectLabel.stringValue;
    [self refreshPlayhead];
    // Proxy refreshes can repeat for the same project. Preserve unsaved edits
    // and an in-flight load instead of replacing either with saved defaults.
    if (context && [context[@"projectUID"] isEqual:self.projectUID] &&
        [context[@"libraryURL"] isEqual:self.libraryURL]) return;
    [self invalidateReview];
    self.contextGeneration += 1;
    NSUInteger generation = self.contextGeneration;
    self.libraryURL = nil;
    self.projectUID = nil;
    self.settingsLoaded = NO;
    [self setControlsEnabled:NO];
    if (!context) {
        for (NSTextField *field in self.fields) field.stringValue = @"";
        [self setStatusMessage:@"Settings are available when a project is open."];
        return;
    }
    self.libraryURL = context[@"libraryURL"];
    self.projectUID = context[@"projectUID"];
    [self setStatusMessage:@"Loading project settings…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self.settings loadForLibraryURL:self.libraryURL projectUID:self.projectUID completion:^(NSDictionary *values, NSError *error) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || generation != owner.contextGeneration || !owner.timeline) return;
        if (error) {
            [owner setStatusMessage:error.localizedDescription requiresAttention:YES];
            return;
        }
        NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
        for (NSUInteger index = 0; index < keys.count; ++index) owner.fields[index].stringValue = [values[keys[index]] stringValue];
        [owner.output selectItemAtIndex:[values[@"outputMode"] isEqual:@"gaps"] ? 1 : 0];
        owner.settingsLoaded = YES;
        [owner setControlsEnabled:YES];
        [owner setStatusMessage:owner.completionMessage ?: @""];
    }];
}

- (void)refreshPlayhead {
    if (self.verificationPanelPending) return;
    if (self.reviewClient.busy || [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    if (!self.timeline || !self.timeline.activeSequence) {
        self.playheadLabel.stringValue = @"Playhead —";
        return;
    }
    CMTime time = [self.timeline playheadTime];
    CMTime start = self.timeline.activeSequence.startTime;
    CMTime relative = CMTimeSubtract(time, start);
    if (!CMTIME_IS_NUMERIC(time) || !CMTIME_IS_NUMERIC(start) || !isfinite(CMTimeGetSeconds(relative))) {
        self.playheadLabel.stringValue = @"Playhead —";
        return;
    }
    double seconds = CMTimeGetSeconds(relative);
    self.playheadLabel.stringValue = [NSString stringWithFormat:@"Playhead %.3f sec", seconds];
}

- (NSDictionary *)currentSettingsValues {
    NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < keys.count; ++index) {
        NSScanner *scanner = [NSScanner scannerWithString:self.fields[index].stringValue];
        double value;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value)) {
            [self setStatusMessage:@"Enter a valid number for each detection setting."];
            return nil;
        }
        values[keys[index]] = @(value);
    }
    values[@"outputMode"] = self.output.indexOfSelectedItem == 1 ? @"gaps" : @"remove";
    return values;
}

- (BOOL)observedProjectMatchesSettings {
    NSDictionary *context = [self observedProjectContext];
    if (!self.libraryURL || !self.projectUID.length) return NO;
    return [self projectContext:context hasSameIdentityAs:@{@"projectUID": self.projectUID, @"libraryURL": self.libraryURL}];
}

- (void)invalidateReview {
    self.reviewGeneration += 1;
    if (self.reviewClient.canCancel) [self.reviewClient cancel];
    [self.reviewClient detach];
    self.reviewClient = nil;
    self.reviewResponse = nil;
    self.detailsExpanded = NO;
    self.statusDetails.stringValue = @"";
    self.statusDetails.toolTip = nil;
    self.statusDetails.hidden = YES;
    self.detailsButton.hidden = YES;
    self.detailsButton.title = @"Details";
    self.statusLabel.toolTip = nil;
    self.reviewCuts = @[];
    for (NSView *row in self.cutList.arrangedSubviews.copy) [row removeFromSuperview];
    self.reviewSummary.stringValue = @"Select a clip to analyze.";
    self.reviewSummary.toolTip = self.reviewSummary.stringValue;
    self.analyzeButton.title = @"Analyze Audio";
    self.analyzeButton.accessibilityIdentifier = @"silentsnip.workflow.analyze";
    self.applyButton.accessibilityIdentifier = @"silentsnip.workflow.apply";
    self.updateButton.accessibilityIdentifier = @"silentsnip.workflow.update";
    self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
    [self.navigateMenu removeAllItems];
    [self.navigateMenu addItemWithTitle:@"Go to Cut"];
    [self updateReviewControls];
}

- (void)settingsChanged:(id)sender {
    if (self.reviewClient.busy || [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    [self clearCompletionMessage];
    BOOL hadReview = self.reviewClient != nil;
    if (self.reviewClient.canUpdateCuts) {
        [self.reviewClient markSettingsDirty];
        [self updateReviewControls];
        [self setStatusMessage:@"Settings changed—click Update Cuts."];
        return;
    }
    [self invalidateReview];
    self.analyzeButton.enabled = self.settingsLoaded;
    if (hadReview) [self setStatusMessage:@"Analyze again to update cuts."];
}

- (void)controlTextDidChange:(NSNotification *)notification { [self settingsChanged:notification.object]; }

- (void)updateReviewControls {
    self.applyButton.enabled = self.reviewClient.canApply;
    self.cancelButton.enabled = self.reviewClient.canCancel;
    self.allButton.enabled = self.reviewClient.canChangeSelection;
    self.noneButton.enabled = self.reviewClient.canChangeSelection;
    self.navigateMenu.enabled = self.reviewClient.canHighlight;
    BOOL pendingUpdate = self.reviewClient.busy &&
        [self.updateButton.accessibilityIdentifier hasPrefix:@"silentsnip.workflow.update.requested."];
    self.updateButton.hidden = !self.reviewClient.canUpdateCuts && !pendingUpdate;
    self.updateButton.enabled = self.settingsLoaded && self.reviewClient.canUpdateCuts && !self.reviewClient.busy;
    self.retryButton.hidden = ![self.reviewResponse[@"canRetryVerification"] boolValue];
    self.applyButton.hidden = !self.retryButton.hidden;
    self.cancelButton.hidden = NO;
    self.allButton.hidden = NO;
    self.noneButton.hidden = NO;
    self.retryButton.enabled = !self.reviewClient.busy;
    self.progressIndicator.hidden = !self.reviewClient.busy;
    NSNumber *fraction = self.reviewResponse[@"progress"];
    self.progressIndicator.indeterminate = fraction == nil;
    if (fraction) self.progressIndicator.doubleValue = fraction.doubleValue;
    if (self.reviewClient.busy && !fraction) [self.progressIndicator startAnimation:nil];
    else [self.progressIndicator stopAnimation:nil];
    for (NSButton *row in self.cutList.arrangedSubviews) {
        NSUInteger index = (NSUInteger)row.tag;
        row.enabled = self.reviewClient.canChangeSelection && index < self.reviewCuts.count &&
            [self.reviewCuts[index][@"eligible"] boolValue];
    }
    [self updateDocumentFrame];
}

- (void)setReviewStatus:(NSDictionary *)response {
    NSString *message = response[@"message"] ?: @"";
    NSString *state = response[@"state"];
    BOOL recovery = [response[@"canRetryVerification"] boolValue];
    BOOL completed = [@[@"completed", @"complete"] containsObject:state] && !recovery;
    NSString *normalReview = @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts.";
    BOOL snapshot = [response[@"usesAudioSnapshot"] boolValue];
    NSString *snapshotNotice = @"Cuts use the last analyzed audio. Apply verifies current audio before editing. Use Analyze Audio Again after changing volume or effects.";
    if (!recovery && snapshot && [state isEqual:@"review"] &&
        [message isEqual:[NSString stringWithFormat:@"%@ %@", snapshotNotice, normalReview]]) {
        [self setStatusMessage:@"Cuts updated. Apply verifies current audio; Analyze again after changing volume or effects."];
        self.statusDetails.stringValue = message;
        self.statusDetails.toolTip = message;
        self.statusLabel.toolTip = message;
        return;
    }
    if (completed || (!recovery && !snapshot && [state isEqual:@"review"] && [message hasPrefix:normalReview])) {
        NSString *remaining = message;
        if (!completed) {
            // Remove only known informational copy. Any appended cleanup or
            // recovery notice remains actionable rather than disappearing.
            NSArray<NSString *> *boilerplate = @[
                normalReview,
                @"Reused verified audio measurements after checking the current project and source contents.",
                @"Analyzed original audio; this clip has no audio adjustments or processing effects.",
                @"Analyzed Final Cut’s rendered audio, including clip volume and enabled effects.",
                @"Threshold uses 10 ms average loudness (RMS), not peak meters.",
                @"Apply creates a cleaned project copy with the retained processed sound preserved.",
                @"The original project keeps its editable effects.",
                @"Quiet breaths may qualify; this detector does not classify breaths."
            ];
            for (NSString *text in boilerplate) remaining = [remaining stringByReplacingOccurrencesOfString:text withString:@""];
            remaining = [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        [self setStatusMessage:completed ? ([response[@"verificationOnly"] boolValue] ? @"Result verified." : @"Cuts applied.") : remaining requiresAttention:!completed && remaining.length > 0];
        self.statusDetails.stringValue = message;
        self.statusDetails.toolTip = message;
        self.statusLabel.toolTip = message;
        return;
    }
    [self setStatusMessage:message requiresAttention:[state isEqual:@"review"] && (snapshot || message.length > 180)];
}

- (void)receiveReview:(NSDictionary *)response {
    self.reviewResponse = response;
    if (!self.reviewClient.busy) {
        self.updateButton.accessibilityIdentifier = @"silentsnip.workflow.update";
        self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
    }
    NSArray *cuts = response[@"cuts"] ?: @[];
    if (![cuts isEqual:self.reviewCuts]) {
        self.reviewCuts = cuts;
        [self.navigateMenu removeAllItems];
        [self.navigateMenu addItemWithTitle:@"Go to Cut"];
        for (NSView *row in self.cutList.arrangedSubviews.copy) [row removeFromSuperview];
        for (NSUInteger index = 0; index < cuts.count; ++index) {
            NSDictionary *cut = cuts[index];
            NSMenuItem *navigation = [[NSMenuItem alloc] initWithTitle:
                [NSString stringWithFormat:@"%lu: %@ – %@", (unsigned long)index + 1, cut[@"start"], cut[@"end"]]
                action:@selector(goToCut:) keyEquivalent:@""];
            navigation.target = self;
            navigation.representedObject = cut[@"id"];
            [self.navigateMenu.menu addItem:navigation];
            NSString *title = [NSString stringWithFormat:@"%@ – %@  (%@)", cut[@"start"], cut[@"end"], cut[@"duration"]];
            SSWorkflowCutRow *row = [[SSWorkflowCutRow alloc] initWithFrame:NSZeroRect];
            row.cell = [SSWorkflowCutCell new];
            row.buttonType = NSButtonTypeSwitch;
            row.imagePosition = NSImageLeft;
            row.alignment = NSTextAlignmentLeft;
            row.title = title;
            row.target = self;
            row.action = @selector(toggleCut:);
            row.startValue = [cut[@"start"] description];
            row.endValue = [cut[@"end"] description];
            row.durationValue = [cut[@"duration"] description];
            row.controlSize = NSControlSizeSmall;
            row.textFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            row.accessibilityLabel = title;
            row.tag = (NSInteger)index;
            row.state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            row.font = row.textFont;
            row.toolTip = [NSString stringWithFormat:@"%@%@%@", title,
                [cut[@"reason"] length] ? @" — " : @"", cut[@"reason"] ?: @""];
            row.accessibilityHelp = row.toolTip;
            row.accessibilityIdentifier = [@"silentsnip.workflow.cut." stringByAppendingString:cut[@"id"]];
            [self.cutList addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.cutList.widthAnchor constant:-12].active = YES;
        }
    }
    NSString *summary = response[@"summary"] ?: @"";
    NSString *target = response[@"targetClipName"];
    self.reviewSummary.stringValue = target.length ? [NSString stringWithFormat:@"Clip: %@\n%@", target, summary] : summary;
    self.reviewSummary.toolTip = self.reviewSummary.stringValue;
    [self setReviewStatus:response];
    [self setControlsEnabled:self.settingsLoaded && !self.reviewClient.busy];
    self.analyzeButton.title = @"Analyze Again";
    [self updateReviewControls];
    NSString *state = response[@"state"];
    if ([@[@"completed", @"complete", @"failed", @"cancelled", @"unavailable"] containsObject:state]) {
        self.completionMessage = [@[@"completed", @"complete"] containsObject:state] &&
            ![response[@"canRetryVerification"] boolValue] ? ([response[@"verificationOnly"] boolValue] ? @"Result verified." : @"Cuts applied.") : response[@"message"];
        // The response has no explicit result identity. Only the request's
        // pinned project can own its notice; a delayed response must not bind
        // verification to whichever project the user has since opened.
        self.completionContext = self.libraryURL && self.projectUID ?
            @{@"libraryURL": self.libraryURL, @"projectUID": self.projectUID} : nil;
        // Apply can open its verified project copy; bind the settings UI to the
        // SDK's new active project only after the worker has finished.
        [self refreshProject];
    }
}

- (void)clearCompletionMessage {
    self.completionMessage = nil;
    self.completionContext = nil;
}

- (SSWorkflowReviewClient *)newReviewClientWithUpdate:(void (^)(NSDictionary *))update
                                            failure:(void (^)(NSString *))failure {
    return [[SSWorkflowReviewClient alloc] initWithViewID:self.viewID update:update failure:failure];
}

- (void)analyzeAudio:(id)sender {
    if (!self.settingsLoaded || self.reviewClient.busy || [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    if (![self observedProjectMatchesSettings]) { [self refreshProject]; return; }
    NSDictionary *values = [self currentSettingsValues];
    if (!values) return;
    [self clearCompletionMessage];
    [self invalidateReview];
    NSUInteger generation = self.reviewGeneration;
    __weak SSWorkflowViewController *weakSelf = self;
    self.reviewClient = [self newReviewClientWithUpdate:^(NSDictionary *response) {
        SSWorkflowViewController *owner = weakSelf;
        if (owner && generation == owner.reviewGeneration && owner.timeline) [owner receiveReview:response];
    } failure:^(NSString *message) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || generation != owner.reviewGeneration || !owner.timeline) return;
        [owner invalidateReview];
        [owner setControlsEnabled:owner.settingsLoaded];
        [owner setStatusMessage:message requiresAttention:YES];
    }];
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.analyzeButton.accessibilityIdentifier = [@"silentsnip.workflow.analyze.requested." stringByAppendingString:gesture];
    [self setControlsEnabled:NO];
    [self setStatusMessage:@"Starting analysis of the selected timeline clip…"];
    [self.reviewClient startWithLibraryURL:self.libraryURL projectUID:self.projectUID
        projectName:self.projectLabel.stringValue settings:values gesture:gesture];
    [self updateReviewControls];
}

- (void)applyCuts:(id)sender {
    if (!self.reviewClient.canApply) return;
    if (![self observedProjectMatchesSettings]) { [self refreshProject]; return; }
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.applyButton.accessibilityIdentifier = [@"silentsnip.workflow.apply.requested." stringByAppendingString:gesture];
    self.applyButton.enabled = NO;
    [self.reviewClient sendApplyWithGesture:gesture];
    [self setControlsEnabled:self.settingsLoaded && !self.reviewClient.busy];
    [self updateReviewControls];
}

- (void)updateCuts:(id)sender {
    if (!self.settingsLoaded || !self.reviewClient.canUpdateCuts || self.reviewClient.busy) return;
    if (![self observedProjectMatchesSettings]) { [self refreshProject]; return; }
    NSDictionary *values = [self currentSettingsValues];
    if (!values) return;
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.updateButton.accessibilityIdentifier = [@"silentsnip.workflow.update.requested." stringByAppendingString:gesture];
    self.updateButton.enabled = NO;
    if (![self.reviewClient updateCutsWithSettings:values gesture:gesture]) {
        self.updateButton.accessibilityIdentifier = @"silentsnip.workflow.update";
        [self setStatusMessage:@"The review changed. Analyze again to refresh cuts." requiresAttention:YES];
    }
    [self setControlsEnabled:self.settingsLoaded && !self.reviewClient.busy];
    [self updateReviewControls];
}

- (void)goToCut:(NSMenuItem *)sender {
    if (!self.reviewClient.canHighlight || ![self observedProjectMatchesSettings]) return;
    [self.reviewClient highlightCut:sender.representedObject];
    [self setControlsEnabled:self.settingsLoaded && !self.reviewClient.busy];
    [self updateReviewControls];
}

// Keep panel selection separate from dispatch so stale panels cannot act on a
// newly opened project and the native gesture exists only for an explicit action.
- (void)verifyResultURL:(NSURL *)url context:(NSDictionary *)context generation:(NSUInteger)generation {
    if (!self.viewVisible || !self.timeline) return;
    NSDictionary *current = [self observedProjectContext];
    if (generation != self.contextGeneration || !self.settingsLoaded || self.reviewClient.busy ||
        ![self observedProjectMatchesSettings] || ![self projectContext:context hasSameIdentityAs:current]) {
        [self setStatusMessage:@"The open project changed. Choose Verify Existing Result again from the intended project." requiresAttention:YES];
        return;
    }
    [self clearCompletionMessage];
    [self invalidateReview];
    NSUInteger reviewGeneration = self.reviewGeneration;
    __weak SSWorkflowViewController *weakSelf = self;
    self.reviewClient = [self newReviewClientWithUpdate:^(NSDictionary *response) {
        SSWorkflowViewController *owner = weakSelf;
        if (owner && reviewGeneration == owner.reviewGeneration && owner.timeline) [owner receiveReview:response];
    } failure:^(NSString *message) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || reviewGeneration != owner.reviewGeneration || !owner.timeline) return;
        [owner invalidateReview];
        [owner setControlsEnabled:owner.settingsLoaded];
        [owner setStatusMessage:message requiresAttention:YES];
    }];
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.verifyButton.accessibilityIdentifier = [@"silentsnip.workflow.verify.requested." stringByAppendingString:gesture];
    [self setControlsEnabled:NO];
    [self setStatusMessage:@"Checking the existing result…"];
    if (![self.reviewClient verifyExistingResultURL:url libraryURL:self.libraryURL projectUID:self.projectUID
        projectName:current[@"projectName"] gesture:gesture]) {
        [self invalidateReview];
        [self setControlsEnabled:self.settingsLoaded];
        [self setStatusMessage:@"Choose Silent Snip.fcpxml from a saved result folder." requiresAttention:YES];
    }
    [self updateReviewControls];
}

// Compare only durable SDK identity. Display names are allowed to refresh
// while the native chooser is open; trailing directory slashes are immaterial.
- (BOOL)projectContext:(NSDictionary *)context hasSameIdentityAs:(NSDictionary *)other {
    NSURL *first = context[@"libraryURL"], *second = other[@"libraryURL"];
    return [first isKindOfClass:NSURL.class] && first.isFileURL &&
        [second isKindOfClass:NSURL.class] && second.isFileURL &&
        [context[@"projectUID"] isKindOfClass:NSString.class] && [context[@"projectUID"] length] &&
        [context[@"projectUID"] isEqual:other[@"projectUID"]] &&
        [first.standardizedURL.path isEqual:second.standardizedURL.path];
}

// These two boundaries let the harness model the real file-sheet completion
// and delayed SDK restoration without opening a panel or running host events.
- (NSDictionary *)beginVerificationPanel {
    if (!self.settingsLoaded || self.verificationPanelPending || self.reviewClient.busy ||
        [self.reviewResponse[@"canRetryVerification"] boolValue] || ![self observedProjectMatchesSettings]) return nil;
    NSDictionary *context = [self observedProjectContext];
    if (!context) return nil;
    self.verificationPanelPending = YES;
    self.verificationPanelToken += 1;
    [self setControlsEnabled:NO];
    return @{@"context": context, @"generation": @(self.contextGeneration), @"token": @(self.verificationPanelToken)};
}

- (void)scheduleVerificationCompletion:(dispatch_block_t)completion afterDelay:(NSTimeInterval)delay {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), completion);
}

- (void)settleVerificationPanelURL:(NSURL *)url ticket:(NSDictionary *)ticket attemptsRemaining:(NSUInteger)attempts {
    if ([ticket[@"token"] unsignedIntegerValue] != self.verificationPanelToken || !self.verificationPanelPending) return;
    if (!self.viewVisible || !self.timeline) {
        self.verificationPanelPending = NO;
        return;
    }
    NSDictionary *current = [self observedProjectContext];
    if (!current && attempts > 0 && [ticket[@"generation"] unsignedIntegerValue] == self.contextGeneration) {
        __weak SSWorkflowViewController *weakSelf = self;
        [self scheduleVerificationCompletion:^{
            [weakSelf settleVerificationPanelURL:url ticket:ticket attemptsRemaining:attempts - 1];
        } afterDelay:0.05];
        return;
    }
    self.verificationPanelPending = NO;
    [self setControlsEnabled:self.settingsLoaded];
    if (!current) {
        [self setStatusMessage:@"Final Cut did not restore the open project after closing the file chooser. Reopen Verify Existing Result to try again." requiresAttention:YES];
        return;
    }
    if ([ticket[@"generation"] unsignedIntegerValue] != self.contextGeneration ||
        ![self projectContext:ticket[@"context"] hasSameIdentityAs:current]) {
        [self refreshProject];
        [self setStatusMessage:@"The open project changed while choosing the result. Choose Verify Existing Result again from the intended project." requiresAttention:YES];
        return;
    }
    [self verifyResultURL:url context:ticket[@"context"] generation:[ticket[@"generation"] unsignedIntegerValue]];
}

- (void)completeVerificationPanelWithURL:(NSURL *)url ticket:(NSDictionary *)ticket {
    if ([ticket[@"token"] unsignedIntegerValue] != self.verificationPanelToken || !self.verificationPanelPending) return;
    if (!url) {
        self.verificationPanelPending = NO;
        [self setControlsEnabled:self.settingsLoaded];
        [self refreshProject];
        return;
    }
    // The sheet is still unwinding during its completion callback. Defer one
    // main-loop turn so native focus and the SDK can return before dispatch;
    // transient missing SDK identity gets a bounded half-second settle.
    __weak SSWorkflowViewController *weakSelf = self;
    [self scheduleVerificationCompletion:^{
        [weakSelf settleVerificationPanelURL:url ticket:ticket attemptsRemaining:10];
    } afterDelay:0];
}

- (void)verifyExistingResult:(id)sender {
    NSDictionary *ticket = [self beginVerificationPanel];
    if (!ticket) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.message = @"Choose Silent Snip.fcpxml from the saved result folder. Verification checks the existing project without importing again.";
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    __weak SSWorkflowViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        NSURL *selected = response == NSModalResponseOK ? panel.URL : nil;
        [weakSelf completeVerificationPanelWithURL:selected ticket:ticket];
    }];
}

- (void)cancelReview:(id)sender {
    if (self.reviewClient.canCancel) [self.reviewClient cancel];
    [self updateReviewControls];
}
- (void)toggleCut:(NSButton *)sender {
    NSUInteger index = (NSUInteger)sender.tag;
    if (!self.reviewClient.canChangeSelection || index >= self.reviewCuts.count) return;
    [self.reviewClient setCut:self.reviewCuts[index][@"id"] included:sender.state == NSControlStateValueOn];
    [self updateReviewControls];
}
- (void)selectAllCuts:(id)sender { [self.reviewClient selectAll:YES]; [self updateReviewControls]; }
- (void)deselectAllCuts:(id)sender { [self.reviewClient selectAll:NO]; [self updateReviewControls]; }
- (void)retryVerification:(id)sender { [self.reviewClient retryVerification]; [self updateReviewControls]; }

- (void)saveSettings:(id)sender {
    if (!self.settingsLoaded || self.reviewClient.busy || !self.libraryURL || !self.projectUID.length) return;
    // A pending host notification must not let old visible controls write
    // settings under a different project's identity.
    if (![self observedProjectMatchesSettings]) {
        [self refreshProject];
        return;
    }
    NSDictionary *values = [self currentSettingsValues];
    if (!values) return;
    NSUInteger generation = self.contextGeneration;
    [self setControlsEnabled:NO];
    [self setStatusMessage:@"Saving…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self.settings saveValues:values libraryURL:self.libraryURL projectUID:self.projectUID completion:^(NSError *error) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || generation != owner.contextGeneration || !owner.timeline) return;
        [owner setControlsEnabled:YES];
        if (!owner.reviewClient.busy && ![owner.reviewResponse[@"canRetryVerification"] boolValue])
            [owner setStatusMessage:error ? error.localizedDescription : @"Settings saved." requiresAttention:error != nil];
    }];
}
@end
