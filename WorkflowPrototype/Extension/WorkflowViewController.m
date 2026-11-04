#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreServices/CoreServices.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import "SSWorkflowPersistence-Swift.h"

@interface SSWorkflowDocument : NSStackView
@end
@implementation SSWorkflowDocument
- (BOOL)isFlipped { return YES; }
@end

@interface SSWorkflowViewController : NSViewController <FCPXTimelineObserver>
@property (nonatomic, strong) id<FCPXHost> host;
@property (nonatomic, strong) FCPXTimeline *timeline;
@property (nonatomic, strong) SSWorkflowSettingsBridge *settings;
@property (nonatomic, strong) NSTextField *projectLabel;
@property (nonatomic, strong) NSTextField *libraryLabel;
@property (nonatomic, strong) NSTextField *playheadLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSArray<NSTextField *> *fields;
@property (nonatomic, strong) NSPopUpButton *output;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSStackView *content;
@property (nonatomic) BOOL updatingDocumentLayout;
@property (nonatomic, strong) NSURL *libraryURL;
@property (nonatomic, strong) NSString *projectUID;
@property (nonatomic) NSUInteger contextGeneration;
@property (nonatomic) BOOL settingsLoaded;
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

- (void)loadView {
    // The SDK owns the window size. preferredContentSize installs root-size
    // constraints that can outgrow its remote viewport and clip the header.
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 640)];
    self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSScrollView *scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];
    self.scroll = scroll;
    self.settings = [SSWorkflowSettingsBridge new];
    self.connectButton = [NSButton buttonWithTitle:@"Connect to Final Cut Pro" target:self action:@selector(requestConnection:)];
    self.connectButton.accessibilityIdentifier = @"silentsnip.workflow.connect";
    self.connectButton.hidden = YES;
    NSTextField *title = [self label:@"Silent Snip" size:25 weight:NSFontWeightBold];
    NSTextField *subtitle = [self label:@"Workflow Prototype" size:12 weight:NSFontWeightMedium];
    subtitle.textColor = NSColor.secondaryLabelColor;
    self.projectLabel = [self label:@"Connecting to Final Cut Pro…" size:17 weight:NSFontWeightSemibold];
    self.projectLabel.accessibilityIdentifier = @"silentsnip.workflow.project";
    self.libraryLabel = [self label:@"" size:12 weight:NSFontWeightRegular];
    self.libraryLabel.textColor = NSColor.secondaryLabelColor;
    self.libraryLabel.accessibilityIdentifier = @"silentsnip.workflow.library";
    self.playheadLabel = [self label:@"Playhead —" size:13 weight:NSFontWeightRegular];
    self.playheadLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    self.playheadLabel.accessibilityIdentifier = @"silentsnip.workflow.playhead";
    NSTextField *heading = [self label:@"Detection settings" size:14 weight:NSFontWeightSemibold];
    NSMutableArray *fields = [NSMutableArray new];
    NSArray *labels = @[@"Silence threshold", @"Minimum silence", @"Before speech", @"After speech"];
    NSArray *units = @[@"dBFS", @"sec", @"sec", @"sec"];
    NSMutableArray *rows = [NSMutableArray new];
    for (NSUInteger index = 0; index < labels.count; ++index) {
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.alignment = NSTextAlignmentRight;
        field.accessibilityLabel = labels[index];
        field.accessibilityIdentifier = [NSString stringWithFormat:@"silentsnip.workflow.setting.%lu", (unsigned long)index];
        [field.widthAnchor constraintEqualToConstant:90].active = YES;
        NSTextField *name = [self label:labels[index] size:13 weight:NSFontWeightRegular];
        [name.widthAnchor constraintEqualToConstant:160].active = YES;
        NSTextField *unit = [self label:units[index] size:12 weight:NSFontWeightRegular];
        unit.textColor = NSColor.secondaryLabelColor;
        NSStackView *row = [NSStackView stackViewWithViews:@[name, field, unit]];
        row.spacing = 12;
        [rows addObject:row];
        [fields addObject:field];
    }
    self.fields = fields;
    self.output = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.output addItemsWithTitles:@[@"Remove Silence", @"Replace with 1-Second Gaps"]];
    self.output.accessibilityLabel = @"Output";
    self.output.accessibilityIdentifier = @"silentsnip.workflow.output";
    NSStackView *outputRow = [NSStackView stackViewWithViews:@[[self label:@"Output" size:13 weight:NSFontWeightRegular], self.output]];
    outputRow.spacing = 16;
    self.saveButton = [NSButton buttonWithTitle:@"Save Settings" target:self action:@selector(saveSettings:)];
    self.saveButton.bezelStyle = NSBezelStyleRounded;
    self.saveButton.accessibilityIdentifier = @"silentsnip.workflow.save";
    self.statusLabel = [self label:@"Waiting for a project…" size:12 weight:NSFontWeightRegular];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    self.statusLabel.accessibilityIdentifier = @"silentsnip.workflow.status";
    NSTextField *scope = [self label:@"This preview saves settings for the open project. Analysis and timeline cuts are coming later." size:12 weight:NSFontWeightRegular];
    scope.textColor = NSColor.secondaryLabelColor;
    NSMutableArray *views = [NSMutableArray arrayWithArray:@[title, subtitle, self.projectLabel, self.libraryLabel, self.playheadLabel, self.connectButton, heading]];
    [views addObjectsFromArray:rows];
    [views addObjectsFromArray:@[outputRow, self.saveButton, self.statusLabel, scope]];
    NSStackView *stack = [SSWorkflowDocument stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    stack.translatesAutoresizingMaskIntoConstraints = YES;
    stack.autoresizingMask = NSViewWidthSizable;
    scroll.documentView = stack;
    self.content = stack;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self setControlsEnabled:NO];
    [self updateDocumentFrame];
}

- (void)viewDidLayout {
    [super viewDidLayout];
    [self updateDocumentFrame];
}

- (void)updateDocumentFrame {
    if (self.updatingDocumentLayout || !self.content || !self.scroll) return;
    CGFloat width = self.scroll.contentView.bounds.size.width;
    if (width <= 48) return;
    self.updatingDocumentLayout = YES;
    for (NSView *child in self.content.arrangedSubviews) {
        if ([child isKindOfClass:NSTextField.class]) ((NSTextField *)child).preferredMaxLayoutWidth = width - 48;
    }
    [self.content setFrameSize:NSMakeSize(width, self.content.frame.size.height)];
    CGFloat height = fmax(1, ceil(self.content.fittingSize.height));
    NSSize size = NSMakeSize(width, height);
    if (!NSEqualSizes(self.content.frame.size, size)) [self.content setFrameSize:size];
    [self.content layoutSubtreeIfNeeded];
    self.updatingDocumentLayout = NO;
}

- (void)setStatusMessage:(NSString *)message {
    self.statusLabel.stringValue = message;
    [self updateDocumentFrame];
}

- (void)setControlsEnabled:(BOOL)enabled {
    for (NSTextField *field in self.fields) field.enabled = enabled;
    self.output.enabled = enabled;
    self.saveButton.enabled = enabled;
}

- (void)viewDidAppear {
    [super viewDidAppear];
    if (self.host) return;
    id singleton = ProExtensionHostSingleton();
    if (![singleton conformsToProtocol:@protocol(FCPXHost)]) {
        [self setStatusMessage:@"Open this extension from Final Cut Pro."];
        return;
    }
    self.host = singleton;
    if (![@"com.apple.FinalCut" isEqual:self.host.bundleIdentifier]) {
        self.host = nil;
        [self setStatusMessage:@"The Final Cut host could not be verified."];
        return;
    }
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
    NSUInteger generation = self.contextGeneration;
    self.connectButton.enabled = NO;
    [self setStatusMessage:ask ? @"Waiting for macOS permission…" : @"Checking the Final Cut connection…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self checkHostPermissionAskingUser:ask completion:^(OSStatus status) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || !owner.host || generation != owner.contextGeneration) return;
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
    NSDictionary *context = [self observedProjectContext];
    self.projectLabel.stringValue = context[@"projectName"] ?: @"Open a project in Final Cut Pro";
    self.libraryLabel.stringValue = context[@"libraryName"] ?: @"";
    [self refreshPlayhead];
    // Proxy refreshes can repeat for the same project. Preserve unsaved edits
    // and an in-flight load instead of replacing either with saved defaults.
    if (context && [context[@"projectUID"] isEqual:self.projectUID] &&
        [context[@"libraryURL"] isEqual:self.libraryURL]) return;
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
            [owner setStatusMessage:error.localizedDescription];
            return;
        }
        NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
        for (NSUInteger index = 0; index < keys.count; ++index) owner.fields[index].stringValue = [values[keys[index]] stringValue];
        [owner.output selectItemAtIndex:[values[@"outputMode"] isEqual:@"gaps"] ? 1 : 0];
        owner.settingsLoaded = YES;
        [owner setControlsEnabled:YES];
        [owner setStatusMessage:[values[@"wasSaved"] boolValue] ? @"Saved settings loaded for this project." : @"Ready. Save settings for this project."];
    }];
}

- (void)refreshPlayhead {
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

- (void)saveSettings:(id)sender {
    if (!self.settingsLoaded || !self.libraryURL || !self.projectUID.length) return;
    // A pending host notification must not let old visible controls write
    // settings under a different project's identity.
    NSDictionary *context = [self observedProjectContext];
    if (![context[@"projectUID"] isEqual:self.projectUID] ||
        ![context[@"libraryURL"] isEqual:self.libraryURL]) {
        [self refreshProject];
        return;
    }
    NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < keys.count; ++index) {
        NSScanner *scanner = [NSScanner scannerWithString:self.fields[index].stringValue];
        double value;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value)) {
            [self setStatusMessage:@"Enter a valid number for each detection setting."];
            return;
        }
        values[keys[index]] = @(value);
    }
    values[@"outputMode"] = self.output.indexOfSelectedItem == 1 ? @"gaps" : @"remove";
    NSUInteger generation = self.contextGeneration;
    [self setControlsEnabled:NO];
    [self setStatusMessage:@"Saving…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self.settings saveValues:values libraryURL:self.libraryURL projectUID:self.projectUID completion:^(NSError *error) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || generation != owner.contextGeneration || !owner.timeline) return;
        [owner setControlsEnabled:YES];
        [owner setStatusMessage:error ? error.localizedDescription : @"Settings saved for this project."];
    }];
}
@end
