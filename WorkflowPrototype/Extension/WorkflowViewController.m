#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreServices/CoreServices.h>
#import <QuartzCore/QuartzCore.h>
#import <ProExtension/ProExtension.h>
#import <ProExtensionHost/ProExtensionHost.h>
#import <math.h>
#import <os/log.h>
#import "SSWorkflowPersistence-Swift.h"
#import "WorkflowReviewClient.h"
#import "WorkflowWindowClient.h"

static NSCursor *SSWorkflowHostArrowCursor(void) {
    NSArray<NSRunningApplication *> *hosts =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.FinalCut"];
    NSRunningApplication *host = hosts.count == 1 ? hosts.firstObject : nil;
    NSURL *hostURL = host.bundleURL;
    if (!host || host.terminated || !hostURL.isFileURL ||
        ![host.bundleIdentifier isEqual:@"com.apple.FinalCut"]) return nil;
    NSBundle *hostBundle = [NSBundle bundleWithURL:hostURL];
    if (![hostBundle.bundleIdentifier isEqual:@"com.apple.FinalCut"]) return nil;

    // Read the running host's artwork as data; never load its framework code.
    // These resource names can change between Final Cut versions, so missing
    // or inaccessible data falls back to AppKit's standard arrow.
    NSURL *frameworkURL = [hostURL URLByAppendingPathComponent:@"Contents/Frameworks/LunaKit.framework" isDirectory:YES];
    NSBundle *artworkBundle = [NSBundle bundleWithURL:frameworkURL];
    NSURL *metadataURL = [artworkBundle URLForResource:@"LKCursor" withExtension:@"plist"];
    NSData *metadataData = metadataURL ? [NSData dataWithContentsOfURL:metadataURL options:0 error:NULL] : nil;
    id metadata = metadataData ? [NSPropertyListSerialization propertyListWithData:metadataData
        options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    if (![metadata isKindOfClass:NSDictionary.class]) return nil;
    id arrow = metadata[@"ArrowCursor"];
    if (![arrow isKindOfClass:NSDictionary.class]) return nil;
    id hotspotX = arrow[@"hotspotx"];
    id hotspotY = arrow[@"hotspoty"];
    if (![hotspotX isKindOfClass:NSNumber.class] || ![hotspotY isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)hotspotX) == CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)hotspotY) == CFBooleanGetTypeID()) return nil;

    NSImage *image = [artworkBundle imageForResource:@"ArrowCursor"];
    if (![image isKindOfClass:NSImage.class] || !image.isValid) return nil;
    NSSize size = image.size;
    double x = [hotspotX doubleValue];
    double y = [hotspotY doubleValue];
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 ||
        !isfinite(x) || !isfinite(y) || x < 0 || y < 0 || x >= size.width || y >= size.height) return nil;
    return [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(x, y)];
}

@interface SSWorkflowPointerObservation : NSObject
@property (nonatomic) BOOL hostForeground;
@property (nonatomic) BOOL visibleRoot;
@property (nonatomic) BOOL pointerInside;
@property (nonatomic) BOOL ownedHit;
@property (nonatomic) BOOL eventMatchesWindow;
@property (nonatomic) BOOL topmostMatchesWindow;
@property (nonatomic) BOOL editableText;
@property (nonatomic) NSUInteger pressedButtons;
@property (nonatomic) NSInteger windowNumber;
@property (nonatomic) NSInteger windowAtPoint;
@property (nonatomic) BOOL keyWindow;
@property (nonatomic) BOOL applicationActive;
@property (nonatomic) pid_t foregroundPID;
@property (nonatomic, copy) NSString *foregroundBundle;
@property (nonatomic, copy) NSString *windowClass;
@end
@implementation SSWorkflowPointerObservation
@end

@interface SSWorkflowContentView : NSView
@property (nonatomic, strong) NSCursor *defaultCursor;
@property (nonatomic, strong) NSTrackingArea *defaultCursorTrackingArea;
@property (nonatomic, strong) NSTrackingArea *defaultMouseTrackingArea;
@property (nonatomic, weak) NSWindow *pointerObservedWindow;
@property (nonatomic) BOOL cursorRefreshScheduled;
@property (nonatomic, copy) NSString *pendingCursorRefreshPhase;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *pointerDiagnostics;
- (void)requestDefaultCursorRefreshForPhase:(NSString *)phase;
@end
@implementation SSWorkflowContentView
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.defaultCursor = SSWorkflowHostArrowCursor();
        NSLog(@"Silent Snip pointer: %@", self.defaultCursor ? @"using Final Cut artwork" : @"system fallback");
        if (!self.defaultCursor) self.defaultCursor = NSCursor.arrowCursor;
    }
    return self;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.defaultCursorTrackingArea) [self removeTrackingArea:self.defaultCursorTrackingArea];
    if (self.defaultMouseTrackingArea) [self removeTrackingArea:self.defaultMouseTrackingArea];
    self.defaultCursorTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.defaultCursorTrackingArea];
    // CursorUpdate cannot use ActiveAlways. These local mouse events repair
    // a standard-arrow reset while another Final Cut window is key.
    self.defaultMouseTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:self.defaultMouseTrackingArea];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    // Let AppKit arbitrate stationary-pointer updates and nested native
    // editing/resize rectangles instead of forcing a global cursor change.
    if (self.defaultCursor) [self addCursorRect:self.visibleRect cursor:self.defaultCursor];
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.pointerObservedWindow) {
        [center removeObserver:self name:NSWindowDidBecomeKeyNotification object:self.pointerObservedWindow];
        [center removeObserver:self name:NSWindowDidResignKeyNotification object:self.pointerObservedWindow];
    }
    self.pointerObservedWindow = self.window;
    if (self.window) {
        [center addObserver:self selector:@selector(pointerWindowKeyChanged:) name:NSWindowDidBecomeKeyNotification object:self.window];
        [center addObserver:self selector:@selector(pointerWindowKeyChanged:) name:NSWindowDidResignKeyNotification object:self.window];
        [self requestDefaultCursorRefreshForPhase:@"window-attach"];
    }
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)pointerWindowKeyChanged:(NSNotification *)notification {
    if (notification.object == self.window)
        [self requestDefaultCursorRefreshForPhase:[notification.name isEqual:NSWindowDidBecomeKeyNotification] ? @"window-key" : @"window-resign"];
}
- (void)layout {
    [super layout];
    [self requestDefaultCursorRefreshForPhase:@"layout"];
}
- (BOOL)editableTextAtHitView:(NSView *)hit {
    for (NSView *view = hit; view; view = view.superview) {
        if ([view isKindOfClass:NSTextField.class]) {
            NSTextField *field = (NSTextField *)view;
            if (field.enabled && (field.editable || field.selectable)) return YES;
        }
        if ([view isKindOfClass:NSTextView.class]) {
            NSTextView *text = (NSTextView *)view;
            if (text.editable || text.selectable) return YES;
        }
        if (view == self) break;
    }
    return NO;
}
- (SSWorkflowPointerObservation *)pointerObservationForEvent:(NSEvent *)event {
    SSWorkflowPointerObservation *observation = [SSWorkflowPointerObservation new];
    NSWindow *window = self.window;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSArray<NSRunningApplication *> *hosts = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.FinalCut"];
    NSRunningApplication *host = hosts.count == 1 ? hosts.firstObject : nil;
    observation.hostForeground = host && !host.terminated && host.processIdentifier > 0 &&
        [host.bundleIdentifier isEqual:@"com.apple.FinalCut"] && front.processIdentifier == host.processIdentifier &&
        [front.bundleIdentifier isEqual:@"com.apple.FinalCut"];
    observation.foregroundPID = front.processIdentifier;
    observation.foregroundBundle = front.bundleIdentifier ?: @"none";
    observation.applicationActive = NSApp.isActive;
    observation.pressedButtons = NSEvent.pressedMouseButtons;
    observation.windowClass = window ? NSStringFromClass(window.class) : @"none";
    observation.windowNumber = window.windowNumber;
    observation.keyWindow = window.isKeyWindow;
    observation.visibleRoot = window && window.isVisible && !self.hiddenOrHasHiddenAncestor;
    observation.eventMatchesWindow = window && event && event.window == window;
    if (window) {
        NSPoint screenPoint = NSEvent.mouseLocation;
        NSPoint localPoint = [self convertPoint:[window convertPointFromScreen:screenPoint] fromView:nil];
        observation.pointerInside = NSPointInRect(localPoint, self.bounds) && NSPointInRect(localPoint, self.visibleRect);
        if (observation.pointerInside && observation.visibleRoot) {
            observation.windowAtPoint = [NSWindow windowNumberAtPoint:screenPoint belowWindowWithWindowNumber:0];
            observation.topmostMatchesWindow = observation.windowNumber > 0 &&
                observation.windowAtPoint == observation.windowNumber;
            NSView *hit = [self hitTest:[self convertPoint:localPoint toView:self.superview]];
            observation.ownedHit = hit && (hit == self || [hit isDescendantOf:self]);
            observation.editableText = [self editableTextAtHitView:hit];
        }
    }
    return observation;
}
- (NSCursor *)currentApplicationCursor { return NSCursor.currentCursor; }
- (NSCursor *)systemArrowCursor { return NSCursor.arrowCursor; }
- (void)recordPointerObservation:(SSWorkflowPointerObservation *)observation phase:(NSString *)phase
                     cursorKind:(NSString *)kind restored:(BOOL)restored {
    NSString *details = [NSString stringWithFormat:@"window=%@/%ld key=%d visible=%d appActive=%d front=%d/%@ inside=%d at=%ld cursor=%@ restored=%d",
        observation.windowClass ?: @"none", (long)observation.windowNumber, observation.keyWindow,
        observation.visibleRoot, observation.applicationActive, observation.foregroundPID,
        observation.foregroundBundle ?: @"none", observation.pointerInside, (long)observation.windowAtPoint, kind, restored];
    if (!self.pointerDiagnostics) self.pointerDiagnostics = [NSMutableDictionary new];
    if (![self.pointerDiagnostics[phase] isEqual:details]) {
        self.pointerDiagnostics[phase] = details;
        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "Silent Snip pointer %{public}s: %{public}s",
            phase.UTF8String, details.UTF8String);
    }
}
- (void)restoreDefaultCursorForEvent:(NSEvent *)event phase:(NSString *)phase {
    SSWorkflowPointerObservation *observation = [self pointerObservationForEvent:event];
    NSCursor *current = [self currentApplicationCursor];
    BOOL systemArrow = current && current == [self systemArrowCursor];
    BOOL ownArrow = current && current == self.defaultCursor;
    BOOL allowed = observation.hostForeground && observation.visibleRoot && observation.pointerInside && observation.ownedHit &&
        observation.pressedButtons == 0 && !observation.editableText &&
        (event ? observation.eventMatchesWindow : observation.topmostMatchesWindow);
    // Explicit repairs must never replace a child I-beam, resize, drag, or
    // custom cursor. AppKit owns transitions out of those cursor rectangles.
    BOOL restored = allowed && self.defaultCursor && !ownArrow && systemArrow;
    if (restored) [self.defaultCursor set];
    [self recordPointerObservation:observation phase:phase
        cursorKind:ownArrow ? @"host-arrow" : (systemArrow ? @"system-arrow" : @"special") restored:restored];
}
- (void)cursorUpdate:(NSEvent *)event {
    [self restoreDefaultCursorForEvent:event phase:@"cursor-update"];
}
- (void)mouseEntered:(NSEvent *)event {
    [self restoreDefaultCursorForEvent:event phase:@"mouse"];
}
- (void)mouseMoved:(NSEvent *)event {
    [self restoreDefaultCursorForEvent:event phase:@"mouse"];
}
- (void)enqueueDefaultCursorRefresh:(dispatch_block_t)refresh {
    dispatch_async(dispatch_get_main_queue(), refresh);
}
- (void)invalidateOwnedCursorRects {
    if (self.window) [self.window invalidateCursorRectsForView:self];
}
- (void)requestDefaultCursorRefreshForPhase:(NSString *)phase {
    if (!self.pendingCursorRefreshPhase || ![phase isEqual:@"layout"]) self.pendingCursorRefreshPhase = phase;
    if (self.cursorRefreshScheduled) return;
    self.cursorRefreshScheduled = YES;
    __weak SSWorkflowContentView *weakSelf = self;
    [self enqueueDefaultCursorRefresh:^{
        SSWorkflowContentView *view = weakSelf;
        if (!view) return;
        NSString *pendingPhase = view.pendingCursorRefreshPhase ?: @"state";
        view.pendingCursorRefreshPhase = nil;
        view.cursorRefreshScheduled = NO;
        [view invalidateOwnedCursorRects];
        [view restoreDefaultCursorForEvent:nil phase:pendingPhase];
    }];
}
@end

static BOOL SSWorkflowSetControlEnabled(NSControl *control, BOOL enabled) {
    if (!control || control.enabled == enabled) return NO;
    control.enabled = enabled;
    return YES;
}

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
    self.layer.borderWidth = 1;
    self.layer.borderColor = NSColor.separatorColor.CGColor;
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

@interface SSWorkflowCutList : SSWorkflowDocument
@property (nonatomic, copy) BOOL (^handleReviewKey)(NSEvent *);
@end
@implementation SSWorkflowCutList
- (BOOL)acceptsFirstResponder { return self.arrangedSubviews.count > 0; }
- (void)keyDown:(NSEvent *)event {
    if (!self.handleReviewKey || !self.handleReviewKey(event)) [super keyDown:event];
}
@end

@interface SSWorkflowCutRow : NSButton
@property (nonatomic, copy) NSString *startValue;
@property (nonatomic, copy) NSString *endValue;
@property (nonatomic, copy) NSString *durationValue;
@property (nonatomic) BOOL needsReview;
@property (nonatomic) BOOL activeRow;
@property (nonatomic) BOOL groupedRow;
@property (nonatomic, copy) void (^chooseRow)(NSEvent *);
@property (nonatomic, strong) NSFont *textFont;
- (NSRect)columnRectForIndex:(NSUInteger)index;
- (NSTextAlignment)textAlignmentForColumn:(NSUInteger)index;
- (NSFont *)textFontForColumn:(NSUInteger)index;
@end
@implementation SSWorkflowCutRow
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 22); }
- (BOOL)acceptsFirstResponder { return NO; }
- (void)mouseDown:(NSEvent *)event {
    if (self.chooseRow) self.chooseRow(event);
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (point.x < 24 && event.clickCount == 1 && !(event.modifierFlags & NSEventModifierFlagShift)) [super mouseDown:event];
}
- (void)setGroupedRow:(BOOL)groupedRow {
    if (_groupedRow == groupedRow) return;
    _groupedRow = groupedRow;
    self.needsDisplay = YES;
}
- (void)setActiveRow:(BOOL)activeRow {
    if (_activeRow == activeRow) return;
    _activeRow = activeRow;
    self.needsDisplay = YES;
}
- (NSRect)columnRectForIndex:(NSUInteger)index {
    CGFloat height = ceil(self.textFont.ascender - self.textFont.descender);
    CGFloat origin = index == 0 ? 26 : (index == 1 ? 144 : fmax(262, self.bounds.size.width - 148));
    CGFloat width = index < 2 ? 110 : fmax(0, fmin(140, self.bounds.size.width - origin - 8));
    return NSMakeRect(origin, floor((self.bounds.size.height - height) / 2), width, height);
}
- (NSTextAlignment)textAlignmentForColumn:(NSUInteger)index {
    return index < 2 ? NSTextAlignmentLeft : NSTextAlignmentRight;
}
- (NSFont *)textFontForColumn:(NSUInteger)index {
    return index == 2 ? [NSFont monospacedDigitSystemFontOfSize:self.textFont.pointSize weight:NSFontWeightMedium] : self.textFont;
}
- (void)drawRect:(NSRect)dirtyRect {
    if (self.activeRow || self.groupedRow || self.tag % 2 == 0) {
        NSColor *fill = self.activeRow || self.groupedRow ?
            [NSColor.controlAccentColor colorWithAlphaComponent:self.activeRow ? 0.23 : 0.13] :
            [NSColor.labelColor colorWithAlphaComponent:0.035];
        [fill setFill];
        NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    }
    [super drawRect:dirtyRect];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentRight;
    style.lineBreakMode = NSLineBreakByClipping;
    NSString *duration = self.durationValue ?: @"";
    if (self.needsReview) duration = [@"Review · " stringByAppendingString:duration];
    NSArray *values = @[self.startValue ?: @"", self.endValue ?: @"", duration];
    for (NSUInteger index = 0; index < values.count; ++index) {
        style.alignment = [self textAlignmentForColumn:index];
        NSColor *color = !self.enabled ? NSColor.disabledControlTextColor :
            (index == 2 && self.needsReview ? NSColor.systemOrangeColor :
             (index == 1 ? NSColor.secondaryLabelColor : NSColor.labelColor));
        NSDictionary *attributes = @{NSFontAttributeName: [self textFontForColumn:index],
            NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: style};
        [values[index] drawInRect:[self columnRectForIndex:index] withAttributes:attributes];
    }
}
@end

// The main-thread controller may be recreated while a system prompt is open.
static BOOL SSWorkflowPermissionPromptPending;

@interface SSWorkflowViewController : NSViewController <FCPXTimelineObserver, NSTextFieldDelegate>
@property (nonatomic, strong) id<FCPXHost> host;
@property (nonatomic, strong) SSWorkflowWindowClient *windowClient;
@property (nonatomic) BOOL viewVisible;
@property (nonatomic) BOOL handlingTextSettingsChange;
@property (nonatomic) BOOL windowClientRunning;
@property (nonatomic, strong) FCPXTimeline *timeline;
@property (nonatomic, strong) SSWorkflowSettingsBridge *settings;
@property (nonatomic, strong) NSTextField *projectLabel;
@property (nonatomic, strong) NSTextField *playheadLabel;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSImageView *statusIcon;
@property (nonatomic, strong) NSArray<NSTextField *> *fields;
@property (nonatomic, strong) NSPopUpButton *output;
@property (nonatomic, strong) NSTextField *pauseTargetField;
@property (nonatomic, strong) NSStackView *pauseTargetRow;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSObject *permissionWaitToken;
@property (nonatomic, strong) NSObject *permissionCheckToken;
@property (nonatomic, strong) NSView *bodyView;
@property (nonatomic, strong) NSStackView *content;
@property (nonatomic, strong) NSView *contentColumn;
@property (nonatomic, strong) NSView *headerView;
@property (nonatomic, strong) NSView *footerView;
@property (nonatomic, strong) NSLayoutConstraint *chromeLeadingConstraint;
@property (nonatomic, strong) NSLayoutConstraint *chromeWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *footerHeightConstraint;
@property (nonatomic, strong) NSStackView *settingsPanel;
@property (nonatomic, strong) NSStackView *settingsGroups;
@property (nonatomic, strong) NSStackView *settingsTopRow;
@property (nonatomic, strong) NSStackView *settingsBottomRow;
@property (nonatomic, strong) NSStackView *outputActions;
@property (nonatomic, strong) NSLayoutConstraint *outputRowWidthConstraint;
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
@property (nonatomic, strong) NSTimer *automaticUpdateTimer;
@property (nonatomic) NSUInteger automaticUpdateGeneration;
@property (nonatomic) NSUInteger automaticUpdateSubmittedGeneration;
@property (nonatomic) NSUInteger automaticUpdateRejectedGeneration;
@property (nonatomic) BOOL automaticUpdatePending;
@property (nonatomic) BOOL settingsSavePending;
@property (nonatomic, copy) NSDictionary *pendingAutomaticSettings;
@property (nonatomic, copy) NSDictionary *submittedAutomaticSettings;
@property (nonatomic, copy) NSString *automaticUpdateEdit;
@property (nonatomic, strong) NSButton *verifyButton;
@property (nonatomic, strong) NSButton *navigateButton;
@property (nonatomic, strong) NSButton *applyButton;
@property (nonatomic, strong) NSButton *cancelButton;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSButton *allButton;
@property (nonatomic, strong) NSButton *noneButton;
@property (nonatomic, strong) NSStackView *boundaryActions;
@property (nonatomic, strong) NSStepper *startStepper;
@property (nonatomic, strong) NSStepper *endStepper;
@property (nonatomic, strong) NSButton *resetCutButton;
@property (nonatomic, strong) NSTextField *reviewSummary;
@property (nonatomic, strong) NSTextField *analyzedSpanLabel;
@property (nonatomic, strong) NSProgressIndicator *progressIndicator;
@property (nonatomic, strong) SSWorkflowCutList *cutList;
@property (nonatomic, copy) NSString *activeCutID;
@property (nonatomic, copy) NSString *reviewSelectionAnchor;
@property (nonatomic, copy) NSArray<NSDictionary *> *reviewCuts;
@property (nonatomic, copy) NSDictionary *reviewResponse;
@property (nonatomic) BOOL navigationPending;
@property (nonatomic, copy) NSString *pointerReviewState;
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

- (void)styleReviewSummary {
    NSString *text = self.reviewSummary.stringValue ?: @"";
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular],
                     NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    NSRange newline = [text rangeOfString:@"\n"];
    if (newline.location != NSNotFound) {
        NSRange name = NSMakeRange(0, newline.location);
        [styled addAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                               NSForegroundColorAttributeName: NSColor.labelColor} range:name];
        if ([text hasPrefix:@"Clip: "]) {
            [styled addAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium],
                                   NSForegroundColorAttributeName: NSColor.secondaryLabelColor} range:NSMakeRange(0, 6)];
        }
        NSUInteger start = NSMaxRange(newline);
        NSRange separator = [text rangeOfString:@" · " options:0 range:NSMakeRange(start, text.length - start)];
        NSRange count = NSMakeRange(start, (separator.location == NSNotFound ? text.length : separator.location) - start);
        [styled addAttributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                               NSForegroundColorAttributeName: NSColor.labelColor} range:count];
        NSRange arrow = [text rangeOfString:@"→ " options:NSBackwardsSearch];
        if (arrow.location != NSNotFound && NSMaxRange(arrow) < text.length) {
            [styled addAttributes:@{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold],
                                   NSForegroundColorAttributeName: NSColor.labelColor}
                            range:NSMakeRange(NSMaxRange(arrow), text.length - NSMaxRange(arrow))];
        }
    }
    // Styling never replaces the worker's wording, exact values, or AX text.
    self.reviewSummary.attributedStringValue = styled;
}

- (void)updateActionAppearance {
    NSString *state = self.reviewResponse[@"state"];
    BOOL reviewing = [@[@"review", @"recalculating"] containsObject:state];
    for (NSButton *button in @[self.analyzeButton, self.applyButton, self.retryButton]) {
        BOOL primary = button == self.retryButton ? !self.retryButton.hidden :
            (button == self.applyButton ? reviewing && self.retryButton.hidden : !reviewing && self.retryButton.hidden);
        button.bezelColor = primary && button.enabled ? NSColor.controlAccentColor : nil;
        button.contentTintColor = primary && button.enabled ? NSColor.whiteColor : nil;
    }
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
- (NSSize)preferredMinimumSize { return NSMakeSize(460, 540); }

- (SSWorkflowContentView *)newContentViewWithFrame:(NSRect)frame {
    return [[SSWorkflowContentView alloc] initWithFrame:frame];
}

- (void)loadView {
    // The SDK owns the window size. Keep the root frame-driven so its remote
    // viewport can resize it without introducing preferred-size constraints.
    self.view = [self newContentViewWithFrame:NSMakeRect(0, 0, 480, 640)];
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
    self.bodyView = [NSView new];
    for (NSView *part in @[self.headerView, self.bodyView, self.footerView]) {
        part.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentColumn addSubview:part];
    }

    self.connectButton = [NSButton buttonWithTitle:@"Connect to Final Cut Pro" target:self action:@selector(requestConnection:)];
    self.connectButton.accessibilityIdentifier = @"silentsnip.workflow.connect";
    self.connectButton.hidden = YES;
    self.projectLabel = [self label:@"Connecting to Final Cut Pro…" size:15 weight:NSFontWeightSemibold];
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
    NSArray *labels = @[@"Silence Threshold", @"Minimum Silence", @"Before Speech", @"After Speech"];
    NSArray *units = @[@"dBFS", @"sec", @"sec", @"sec"];
    for (NSUInteger index = 0; index < labels.count; ++index) {
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
        field.controlSize = NSControlSizeSmall;
        field.bezelStyle = NSTextFieldSquareBezel;
        field.alignment = NSTextAlignmentRight;
        field.accessibilityLabel = labels[index];
        field.accessibilityIdentifier = [NSString stringWithFormat:@"silentsnip.workflow.setting.%lu", (unsigned long)index];
        field.delegate = self;
        [field.widthAnchor constraintEqualToConstant:64].active = YES;
        NSTextField *name = [self label:labels[index] size:10.5 weight:NSFontWeightMedium];
        name.textColor = NSColor.secondaryLabelColor;
        name.maximumNumberOfLines = 1;
        NSTextField *unit = [self label:units[index] size:10.5 weight:NSFontWeightRegular];
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
    self.saveButton.toolTip = @"Save these settings for the open project.";
    NSTextField *outputLabel = [self label:@"Output" size:10.5 weight:NSFontWeightMedium];
    outputLabel.textColor = NSColor.secondaryLabelColor;
    outputLabel.maximumNumberOfLines = 1;
    [outputLabel.widthAnchor constraintEqualToConstant:42].active = YES;
    [self.saveButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.saveButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *outputRow = [NSStackView stackViewWithViews:@[outputLabel, self.output, self.saveButton]];
    outputRow.distribution = NSStackViewDistributionFill;
    outputRow.spacing = 10;
    self.verifyButton = [NSButton buttonWithTitle:@"Verify Existing Result" target:self action:@selector(verifyExistingResult:)];
    self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
    self.verifyButton.toolTip = @"Verify an existing cleaned project using its saved Silent Snip.fcpxml file.";
    [self.verifyButton setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.verifyButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.outputActions = [NSStackView stackViewWithViews:@[outputRow, self.verifyButton]];
    self.outputActions.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.outputActions.alignment = NSLayoutAttributeLeading;
    self.outputActions.spacing = 4;
    self.outputRowWidthConstraint = [outputRow.widthAnchor constraintEqualToAnchor:self.outputActions.widthAnchor];
    self.pauseTargetField = [NSTextField textFieldWithString:@"0"];
    self.pauseTargetField.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.pauseTargetField.controlSize = NSControlSizeSmall;
    self.pauseTargetField.alignment = NSTextAlignmentRight;
    self.pauseTargetField.accessibilityLabel = @"Target Pause";
    self.pauseTargetField.accessibilityIdentifier = @"silentsnip.workflow.pause-target";
    self.pauseTargetField.toolTip = @"Keep this much original room tone in long pauses. Use 0 for standard silence removal.";
    self.pauseTargetField.delegate = self;
    [self.pauseTargetField.widthAnchor constraintEqualToConstant:64].active = YES;
    NSTextField *pauseLabel = [self label:@"Target Pause" size:10.5 weight:NSFontWeightMedium];
    NSTextField *pauseUnit = [self label:@"sec (0 = off)" size:10.5 weight:NSFontWeightRegular];
    pauseLabel.textColor = pauseUnit.textColor = NSColor.secondaryLabelColor;
    self.pauseTargetRow = [NSStackView stackViewWithViews:@[pauseLabel, self.pauseTargetField, pauseUnit]];
    self.pauseTargetRow.spacing = 8;
    NSTextField *settingsHeading = [self label:@"Detection Settings" size:14 weight:NSFontWeightSemibold];
    self.settingsPanel = [self cardWithViews:@[settingsHeading, self.settingsGroups, self.outputActions, self.pauseTargetRow]];
    self.settingsPanel.accessibilityElement = YES;
    self.settingsPanel.accessibilityRole = NSAccessibilityGroupRole;
    self.settingsPanel.accessibilityIdentifier = @"silentsnip.workflow.settings";

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
    self.statusDetails.maximumNumberOfLines = 3;
    self.statusDetails.lineBreakMode = NSLineBreakByTruncatingTail;
    self.statusDetails.selectable = YES;
    self.statusDetails.accessibilityIdentifier = @"silentsnip.workflow.status-details";
    self.statusDetails.hidden = YES;
    self.analyzeButton = [NSButton buttonWithTitle:@"Analyze Audio" target:self action:@selector(analyzeAudio:)];
    self.analyzeButton.accessibilityIdentifier = @"silentsnip.workflow.analyze";
    self.settingsPanel.spacing = 7;
    self.applyButton = [NSButton buttonWithTitle:@"Apply Cuts" target:self action:@selector(applyCuts:)];
    self.applyButton.accessibilityIdentifier = @"silentsnip.workflow.apply";
    self.cancelButton = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelReview:)];
    // This marker must remain visible even while idle and disabled: the worker
    // verifies this native view together with a fresh disabled gesture button.
    self.cancelButton.accessibilityIdentifier = [@"silentsnip.workflow.review." stringByAppendingString:self.viewID];
    self.retryButton = [NSButton buttonWithTitle:@"Retry Verification" target:self action:@selector(retryVerification:)];
    self.retryButton.hidden = YES;
    for (NSButton *button in @[self.connectButton, self.saveButton, self.verifyButton,
        self.analyzeButton, self.applyButton, self.retryButton, self.cancelButton]) {
        button.controlSize = NSControlSizeSmall;
        button.bezelStyle = NSBezelStyleAccessoryBarAction;
        button.font = [NSFont systemFontOfSize:10.5];
    }
    for (NSButton *button in @[self.analyzeButton, self.applyButton, self.retryButton]) {
        button.bezelStyle = NSBezelStyleRounded;
        button.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    }
    NSView *actionSpring = [NSView new];
    [actionSpring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *actions = [NSStackView stackViewWithViews:@[actionSpring, self.analyzeButton, self.applyButton, self.retryButton, self.cancelButton]];
    [actions setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    actions.spacing = 8;
    self.statusIcon = [NSImageView new];
    self.statusIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.statusIcon.accessibilityElement = NO;
    self.statusIcon.hidden = YES;
    [self.statusIcon.widthAnchor constraintEqualToConstant:12].active = YES;
    [self.statusIcon.heightAnchor constraintEqualToConstant:12].active = YES;
    NSStackView *status = [NSStackView stackViewWithViews:@[self.statusIcon, self.statusLabel, self.detailsButton]];
    status.spacing = 6;
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
    self.analyzedSpanLabel = [self label:@"" size:11 weight:NSFontWeightMedium];
    self.analyzedSpanLabel.accessibilityIdentifier = @"silentsnip.workflow.analysis-span";
    self.analyzedSpanLabel.textColor = NSColor.secondaryLabelColor;
    self.analyzedSpanLabel.maximumNumberOfLines = 1;
    self.analyzedSpanLabel.hidden = YES;
    [self styleReviewSummary];
    self.allButton = [NSButton buttonWithTitle:@"Select All" target:self action:@selector(selectAllCuts:)];
    self.noneButton = [NSButton buttonWithTitle:@"Deselect All" target:self action:@selector(deselectAllCuts:)];
    self.navigateButton = [NSButton buttonWithTitle:@"Go to Cut" target:self action:@selector(goToCut:)];
    self.navigateButton.accessibilityIdentifier = @"silentsnip.workflow.navigate";
    self.navigateButton.toolTip = @"Move the playhead to the active cut. Return when the cut list has focus.";
    for (NSButton *button in @[self.navigateButton, self.allButton, self.noneButton]) {
        button.controlSize = NSControlSizeSmall;
        button.font = [NSFont systemFontOfSize:10.5];
        button.bezelStyle = NSBezelStyleAccessoryBarAction;
    }
    NSView *reviewSpring = [NSView new];
    [reviewSpring setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *reviewActions = [NSStackView stackViewWithViews:@[[self label:@"Cut Review" size:14 weight:NSFontWeightSemibold], reviewSpring, self.navigateButton, self.allButton, self.noneButton]];
    reviewActions.spacing = 6;
    self.cutList = [SSWorkflowCutList new];
    __weak SSWorkflowViewController *cutListOwner = self;
    self.cutList.handleReviewKey = ^BOOL(NSEvent *event) { return [cutListOwner handleReviewKey:event]; };
    self.cutList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.cutList.alignment = NSLayoutAttributeLeading;
    self.cutList.spacing = 2;
    self.cutList.edgeInsets = NSEdgeInsetsMake(6, 6, 6, 6);
    self.cutList.translatesAutoresizingMaskIntoConstraints = YES;
    self.cutList.autoresizingMask = NSViewWidthSizable;
    self.reviewScroll = [NSScrollView new];
    self.reviewScroll.accessibilityIdentifier = @"silentsnip.workflow.cut-list";
    self.reviewScroll.drawsBackground = YES;
    self.reviewScroll.backgroundColor = SSWorkflowGray(0.105);
    self.reviewScroll.hasVerticalScroller = NO;
    self.reviewScroll.hasHorizontalScroller = NO;
    self.reviewScroll.autohidesScrollers = YES;
    self.reviewScroll.verticalScrollElasticity = NSScrollElasticityNone;
    self.reviewScroll.horizontalScrollElasticity = NSScrollElasticityNone;
    self.reviewScroll.borderType = NSBezelBorder;
    self.reviewScroll.documentView = self.cutList;
    self.reviewListHeightConstraint = [self.reviewScroll.heightAnchor constraintGreaterThanOrEqualToConstant:80];
    self.reviewListHeightConstraint.active = YES;
    NSMutableArray<NSTextField *> *columnLabels = [NSMutableArray new];
    for (NSString *title in @[@"Start", @"End", @"Duration"]) {
        NSTextField *column = [self label:title size:10.5 weight:NSFontWeightMedium];
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
    self.startStepper = [NSStepper new];
    self.endStepper = [NSStepper new];
    self.startStepper.accessibilityLabel = @"Adjust Cut Start";
    self.endStepper.accessibilityLabel = @"Adjust Cut End";
    for (NSStepper *stepper in @[self.startStepper, self.endStepper]) {
        stepper.controlSize = NSControlSizeSmall;
        stepper.minValue = -1;
        stepper.maxValue = 1;
        stepper.increment = 1;
        stepper.doubleValue = 0;
        stepper.valueWraps = NO;
        stepper.autorepeat = NO;
        stepper.target = self;
        stepper.action = @selector(stepCutBoundary:);
        stepper.toolTip = @"Move this boundary by one valid cut-grid interval.";
    }
    self.resetCutButton = [NSButton buttonWithTitle:@"Reset Cut" target:self action:@selector(resetCutBoundary:)];
    self.resetCutButton.controlSize = NSControlSizeSmall;
    self.resetCutButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    self.boundaryActions = [NSStackView stackViewWithViews:@[
        [self label:@"Start" size:11 weight:NSFontWeightMedium], self.startStepper,
        [self label:@"End" size:11 weight:NSFontWeightMedium], self.endStepper, self.resetCutButton]];
    self.boundaryActions.spacing = 7;
    self.boundaryActions.alignment = NSLayoutAttributeCenterY;
    self.boundaryActions.hidden = YES;
    self.reviewPanel = [self cardWithViews:@[reviewActions, self.reviewSummary, self.analyzedSpanLabel,
        self.statusDetails, self.cutColumnHeader, self.reviewScroll, self.boundaryActions]];
    self.reviewPanel.spacing = 4;
    [self.settingsPanel setHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    [self.reviewPanel setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [self.reviewScroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    self.content = [SSWorkflowDocument stackViewWithViews:@[self.settingsPanel, self.reviewPanel]];
    self.content.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.content.alignment = NSLayoutAttributeLeading;
    self.content.spacing = 12;
    self.content.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bodyView addSubview:self.content];
    self.settingsPanelWidthConstraint = [self.settingsPanel.widthAnchor constraintEqualToConstant:448];
    self.reviewPanelWidthConstraint = [self.reviewPanel.widthAnchor constraintEqualToConstant:448];
    self.chromeLeadingConstraint = [self.headerView.leadingAnchor constraintEqualToAnchor:self.contentColumn.leadingAnchor constant:12];
    self.chromeWidthConstraint = [self.headerView.widthAnchor constraintEqualToConstant:448];
    self.footerHeightConstraint = [self.footerView.heightAnchor constraintEqualToConstant:64];
    [NSLayoutConstraint activateConstraints:@[
        self.settingsPanelWidthConstraint, self.reviewPanelWidthConstraint,
        [self.content.leadingAnchor constraintEqualToAnchor:self.bodyView.leadingAnchor],
        [self.content.trailingAnchor constraintEqualToAnchor:self.bodyView.trailingAnchor],
        [self.content.topAnchor constraintEqualToAnchor:self.bodyView.topAnchor],
        [self.content.bottomAnchor constraintEqualToAnchor:self.bodyView.bottomAnchor],
        [self.settingsGroups.widthAnchor constraintEqualToAnchor:self.settingsPanel.widthAnchor constant:-24],
        [self.settingsTopRow.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        [self.settingsBottomRow.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        [self.outputActions.widthAnchor constraintEqualToAnchor:self.settingsGroups.widthAnchor],
        self.outputRowWidthConstraint,
        [self.reviewScroll.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [reviewActions.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [self.reviewSummary.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        [self.reviewSummary.heightAnchor constraintEqualToConstant:34],
        [self.statusDetails.widthAnchor constraintEqualToAnchor:self.reviewPanel.widthAnchor constant:-24],
        self.chromeLeadingConstraint,
        self.chromeWidthConstraint,
        [self.headerView.topAnchor constraintEqualToAnchor:self.contentColumn.topAnchor],
        [self.headerView.heightAnchor constraintEqualToConstant:46],
        [header.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor constant:12],
        [header.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:-12],
        [header.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [self.projectLabel.widthAnchor constraintEqualToAnchor:project.widthAnchor],
        [self.footerView.leadingAnchor constraintEqualToAnchor:self.headerView.leadingAnchor],
        [self.footerView.widthAnchor constraintEqualToAnchor:self.headerView.widthAnchor],
        [self.footerView.bottomAnchor constraintEqualToAnchor:self.contentColumn.bottomAnchor],
        self.footerHeightConstraint,
        [footer.leadingAnchor constraintEqualToAnchor:self.footerView.leadingAnchor constant:12],
        [footer.trailingAnchor constraintEqualToAnchor:self.footerView.trailingAnchor constant:-12],
        [footer.topAnchor constraintEqualToAnchor:self.footerView.topAnchor constant:7],
        [self.footerMainRow.widthAnchor constraintEqualToAnchor:footer.widthAnchor],
        [self.progressIndicator.widthAnchor constraintEqualToAnchor:footer.widthAnchor],
        [self.bodyView.leadingAnchor constraintEqualToAnchor:self.contentColumn.leadingAnchor],
        [self.bodyView.trailingAnchor constraintEqualToAnchor:self.contentColumn.trailingAnchor],
        [self.bodyView.topAnchor constraintEqualToAnchor:self.headerView.bottomAnchor],
        [self.bodyView.bottomAnchor constraintEqualToAnchor:self.footerView.topAnchor]
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
    if (self.updatingDocumentLayout || !self.content || !self.bodyView) return;
    CGFloat hostHeight = self.view.bounds.size.height;
    CGFloat columnWidth = fmin(560, self.view.bounds.size.width);
    if (columnWidth <= 48 || hostHeight <= 0) return;
    self.updatingDocumentLayout = YES;
    self.reviewScroll.hidden = NO;
    self.cutColumnHeader.hidden = NO;
    self.reviewScroll.hasVerticalScroller = self.reviewCuts.count > 0;
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
    // The body is fixed to the host viewport. Only the timestamp document
    // grows with analyzed ranges; its viewport takes the remaining height.
    NSRect columnFrame = NSMakeRect(floor((self.view.bounds.size.width - columnWidth) / 2),
        0, columnWidth, hostHeight);
    if (!NSEqualRects(self.contentColumn.frame, columnFrame)) self.contentColumn.frame = columnFrame;
    for (NSUInteger pass = 0; pass < 2; ++pass) {
        [self.contentColumn layoutSubtreeIfNeeded];
        CGFloat width = self.bodyView.bounds.size.width;
        NSEdgeInsets insets = self.content.edgeInsets;
        CGFloat cardWidth = width - insets.left - insets.right;
        self.chromeLeadingConstraint.constant = insets.left;
        self.chromeWidthConstraint.constant = cardWidth;
        self.settingsPanelWidthConstraint.constant = cardWidth;
        self.reviewPanelWidthConstraint.constant = cardWidth;
        // Fit both action titles and the longest output choice before using
        // one row. The fixed body never reserves an outer scrollbar gutter.
        CGFloat outputWidth = fmax(180, ceil(self.output.intrinsicContentSize.width));
        CGFloat actionsWidth = 42 + outputWidth + ceil(self.saveButton.intrinsicContentSize.width) +
            ceil(self.verifyButton.intrinsicContentSize.width) + 28;
        BOOL outputWide = cardWidth - 24 >= actionsWidth;
        self.outputRowWidthConstraint.active = !outputWide;
        self.outputActions.orientation = outputWide ? NSUserInterfaceLayoutOrientationHorizontal : NSUserInterfaceLayoutOrientationVertical;
        self.outputActions.alignment = outputWide ? NSLayoutAttributeCenterY : NSLayoutAttributeLeading;
        self.outputActions.spacing = outputWide ? 8 : 4;
        self.reviewSummary.preferredMaxLayoutWidth = cardWidth - 24;
        self.statusDetails.preferredMaxLayoutWidth = cardWidth - 24;
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
    }
    self.updatingDocumentLayout = NO;
}

- (void)setStatusMessage:(NSString *)message {
    [self setStatusMessage:message requiresAttention:NO];
}

- (void)setStatusMessage:(NSString *)message requiresAttention:(BOOL)requiresAttention {
    [self updateStatusContent:message requiresAttention:requiresAttention];
    [self updateDocumentFrame];
}

- (void)updateStatusContent:(NSString *)message requiresAttention:(BOOL)requiresAttention {
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
        if (requiresAttention) self.statusLabel.stringValue = @"Unable to complete the operation. Review the details.";
        else if ([self.reviewResponse[@"canRetryVerification"] boolValue]) self.statusLabel.stringValue = @"Unable to verify the result. Review the details.";
        else if ([state isEqual:@"cancelled"]) self.statusLabel.stringValue = @"Canceled. Review the details.";
        else if (attention) self.statusLabel.stringValue = @"Unable to complete the operation. Review the details.";
        else if (self.reviewClient.busy) self.statusLabel.stringValue = @"Working in Final Cut Pro…";
        else if ([@[@"completed", @"complete"] containsObject:state]) self.statusLabel.stringValue = @"Cuts applied.";
        else self.statusLabel.stringValue = @"";
    }
    self.statusDetails.hidden = !longMessage || !self.detailsExpanded;
    self.detailsButton.title = self.detailsExpanded ? @"Hide Details" : @"Details";
    NSString *state = self.reviewResponse[@"state"];
    BOOL warning = requiresAttention || [self.reviewResponse[@"canRetryVerification"] boolValue] ||
        [@[@"failed", @"unavailable", @"error"] containsObject:state];
    BOOL completed = !warning && [@[@"completed", @"complete"] containsObject:state];
    NSString *symbol = warning ? @"exclamationmark.triangle.fill" :
        (completed ? @"checkmark.circle.fill" : @"info.circle");
    self.statusIcon.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.statusIcon.contentTintColor = warning ? NSColor.systemOrangeColor :
        (completed ? NSColor.systemGreenColor : NSColor.secondaryLabelColor);
    self.statusIcon.hidden = self.statusLabel.stringValue.length == 0;
    self.statusLabel.textColor = warning ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.statusDetails.textColor = warning ? NSColor.labelColor : NSColor.secondaryLabelColor;
}

- (void)toggleDetails:(id)sender {
    if (self.detailsButton.hidden) return;
    self.detailsExpanded = !self.detailsExpanded;
    self.statusDetails.hidden = !self.detailsExpanded;
    self.detailsButton.title = self.detailsExpanded ? @"Hide Details" : @"Details";
    [self updateDocumentFrame];
}

- (void)setControlsEnabled:(BOOL)enabled {
    enabled = enabled && !self.verificationPanelPending &&
        (!self.reviewClient.busy || self.reviewClient.updatingCuts) && ![self.reviewResponse[@"canRetryVerification"] boolValue];
    BOOL changed = NO;
    for (NSTextField *field in self.fields) changed |= SSWorkflowSetControlEnabled(field, enabled);
    changed |= SSWorkflowSetControlEnabled(self.pauseTargetField, enabled && self.output.indexOfSelectedItem == 0);
    changed |= SSWorkflowSetControlEnabled(self.output, enabled);
    changed |= SSWorkflowSetControlEnabled(self.saveButton, enabled && !self.settingsSavePending);
    changed |= SSWorkflowSetControlEnabled(self.analyzeButton, enabled && !self.reviewClient.busy && !self.settingsSavePending);
    changed |= SSWorkflowSetControlEnabled(self.verifyButton, enabled && !self.settingsSavePending && !self.automaticUpdatePending && !self.reviewClient.updatingCuts);
    [self updateActionAppearance];
    if (changed) [(SSWorkflowContentView *)self.view requestDefaultCursorRefreshForPhase:@"controls"];
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
    [(SSWorkflowContentView *)self.view requestDefaultCursorRefreshForPhase:@"appear"];
    [self startAutomaticUpdateObservers];
    if (self.host) {
        [self startWindowClientIfVisible];
        return;
    }
    id singleton = ProExtensionHostSingleton();
    if (![singleton conformsToProtocol:@protocol(FCPXHost)]) {
        [self stopWindowClient];
        [self setStatusMessage:@"In Final Cut Pro, choose Window > Extensions > Silent Snip."];
        return;
    }
    self.host = singleton;
    if (![@"com.apple.FinalCut" isEqual:self.host.bundleIdentifier]) {
        [self stopWindowClient];
        self.host = nil;
        [self setStatusMessage:@"Unable to connect to Final Cut Pro. Open Silent Snip from Window > Extensions."];
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

- (void)recheckConnection:(id)sender { [self checkConnection:NO]; }

- (void)schedulePermissionWaitDeadline:(dispatch_block_t)block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), block);
}

- (void)showPermissionRecoveryAfterTimeout:(BOOL)timedOut {
    BOOL promptPending = SSWorkflowPermissionPromptPending;
    self.connectButton.hidden = NO;
    self.connectButton.enabled = !promptPending || !self.permissionCheckToken;
    self.connectButton.title = promptPending ? @"Check Permission" : @"Connect to Final Cut Pro";
    self.connectButton.action = promptPending ? @selector(recheckConnection:) : @selector(requestConnection:);
    self.projectLabel.stringValue = @"Connect to Final Cut Pro";
    [self setStatusMessage:(timedOut || promptPending)
        ? @"Check the macOS permission dialog or allow access in System Settings > Privacy & Security > Automation."
        : @"Allow Silent Snip to access Final Cut Pro to show the open project and playhead."];
}

- (void)checkConnection:(BOOL)ask {
    // Window sizing belongs to the verified visible extension, independent
    // of permission to inspect a project or the presence of a selection.
    [self startWindowClientIfVisible];
    if (!self.viewVisible || ![self hasVerifiedWindowHost] || self.timeline || self.permissionWaitToken) return;
    if (ask ? SSWorkflowPermissionPromptPending : self.permissionCheckToken != nil) return;
    NSObject *wait = [NSObject new];
    if (ask) SSWorkflowPermissionPromptPending = YES;
    else self.permissionCheckToken = wait;
    NSUInteger generation = self.contextGeneration;
    self.permissionWaitToken = wait;
    self.connectButton.enabled = NO;
    [self setStatusMessage:ask ? @"Waiting for macOS permission…" : @"Checking the Final Cut Pro connection…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self checkHostPermissionAskingUser:ask completion:^(OSStatus status) {
        SSWorkflowViewController *owner = weakSelf;
        if (ask) SSWorkflowPermissionPromptPending = NO;
        else if (owner.permissionCheckToken == wait) owner.permissionCheckToken = nil;
        if (!owner || !owner.viewVisible || generation != owner.contextGeneration) return;
        if (![owner hasVerifiedWindowHost]) {
            [owner stopWindowClient];
            return;
        }
        if (owner.timeline) return;
        if (status != noErr) {
            if (owner.permissionWaitToken && owner.permissionWaitToken != wait) return;
            owner.permissionWaitToken = nil;
            [owner showPermissionRecoveryAfterTimeout:NO];
            return;
        }
        owner.permissionWaitToken = nil;
        owner.connectButton.hidden = YES;
        owner.timeline = owner.host.timeline;
        [owner.timeline addTimelineObserver:owner];
        [owner refreshProject];
    }];
    if (self.permissionWaitToken != wait) return;
    [self schedulePermissionWaitDeadline:^{
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || !owner.viewVisible || generation != owner.contextGeneration ||
            owner.permissionWaitToken != wait || ![owner hasVerifiedWindowHost]) return;
        owner.permissionWaitToken = nil;
        [owner showPermissionRecoveryAfterTimeout:YES];
    }];
}

- (void)viewWillDisappear {
    self.viewVisible = NO;
    self.permissionWaitToken = nil;
    self.permissionCheckToken = nil;
    [self stopAutomaticUpdateObservers];
    self.verificationPanelPending = NO;
    self.verificationPanelToken += 1;
    [self stopWindowClient];
    [self clearCompletionMessage];
    [self invalidateReview];
    [self.timeline removeTimelineObserver:self];
    self.timeline = nil;
    self.host = nil;
    self.contextGeneration += 1;
    self.settingsSavePending = NO;
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
    return [self projectContextForSequence:self.timeline.activeSequence];
}

- (NSDictionary *)projectContextForSequence:(FCPXSequence *)sequence {
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
    if ((self.reviewClient.busy && !self.reviewClient.updatingCuts) ||
        [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    NSDictionary *context = [self observedProjectContext];
    BOOL ownsPendingAutomaticReview = self.automaticUpdatePending && self.settingsLoaded &&
        self.libraryURL != nil && self.projectUID.length && self.reviewClient.requestID.length;
    if (!context && (self.handlingTextSettingsChange || ownsPendingAutomaticReview)) return;
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
    self.settingsSavePending = NO;
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
        owner.pauseTargetField.stringValue = [values[@"pauseTargetDuration"] stringValue] ?: @"0";
        owner.pauseTargetRow.hidden = owner.output.indexOfSelectedItem == 1;
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
    if (![self addPauseTargetToValues:values]) {
        [self setStatusMessage:@"Enter a target pause between 0.001 and 10 seconds, or 0 to turn it off."];
        return nil;
    }
    return values;
}

- (BOOL)addPauseTargetToValues:(NSMutableDictionary *)values {
    if (![values[@"outputMode"] isEqual:@"remove"]) return YES;
    NSTextField *field = self.pauseTargetField;
    NSString *text = field.currentEditor ? field.currentEditor.string : field.stringValue;
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || [text hasSuffix:@"."]) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double seconds;
    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !isfinite(seconds) ||
        seconds < 0 || seconds > 10 || (seconds > 0 && seconds < 0.001)) return NO;
    if (seconds > 0) values[@"pauseTargetDuration"] = @(seconds);
    return YES;
}

- (BOOL)observedProjectMatchesSettings {
    NSDictionary *context = [self observedProjectContext];
    if (!self.libraryURL || !self.projectUID.length) return NO;
    return [self projectContext:context hasSameIdentityAs:@{@"projectUID": self.projectUID, @"libraryURL": self.libraryURL}];
}

- (void)invalidateReview {
    [self cancelAutomaticUpdate];
    self.navigationPending = NO;
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
    self.analyzedSpanLabel.hidden = YES;
    self.analyzedSpanLabel.stringValue = @"";
    [self styleReviewSummary];
    self.reviewSummary.toolTip = self.reviewSummary.stringValue;
    self.analyzeButton.title = @"Analyze Audio";
    self.analyzeButton.accessibilityIdentifier = @"silentsnip.workflow.analyze";
    self.applyButton.accessibilityIdentifier = @"silentsnip.workflow.apply";
    self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
    self.navigateButton.accessibilityIdentifier = @"silentsnip.workflow.navigate";
    self.activeCutID = nil;
    self.reviewSelectionAnchor = nil;
    [self updateReviewControls];
}

// Only retained measurements are refreshed here. A timer can never create an
// Analyze request, activate Final Cut, import a project, or apply timeline cuts.
- (void)startAutomaticUpdateObservers {
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    [center removeObserver:self name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [center addObserver:self selector:@selector(hostDidActivate:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
}

- (void)stopAutomaticUpdateObservers {
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self name:NSWorkspaceDidActivateApplicationNotification object:nil];
}

- (void)hostDidActivate:(NSNotification *)notification {
    id application = notification.userInfo[NSWorkspaceApplicationKey];
    if (![application respondsToSelector:@selector(bundleIdentifier)] ||
        ![[application bundleIdentifier] isEqual:@"com.apple.FinalCut"]) return;
    [self onMain:^{
        if (!self.automaticUpdatePending || !self.viewVisible) return;
        self.automaticUpdateRejectedGeneration = 0;
        [self queueAutomaticUpdate];
    }];
}

- (void)cancelAutomaticUpdate {
    [self.automaticUpdateTimer invalidate];
    self.automaticUpdateTimer = nil;
    self.automaticUpdateGeneration += 1;
    self.automaticUpdatePending = NO;
    self.pendingAutomaticSettings = nil;
    self.submittedAutomaticSettings = nil;
    self.automaticUpdateEdit = nil;
    self.automaticUpdateRejectedGeneration = 0;
    self.settingsPanel.accessibilityIdentifier = @"silentsnip.workflow.settings";
}

- (NSDictionary *)automaticSettingsValues {
    NSArray *keys = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    NSArray *lower = @[@-80, @0.0001, @0, @0], *upper = @[@0, @10, @2, @2];
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < keys.count; ++index) {
        NSTextField *field = self.fields[index];
        NSString *text = field.currentEditor ? field.currentEditor.string : field.stringValue;
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        // A decimal point or exponent suffix is still an unfinished draft.
        if (!text.length || [text hasSuffix:@"."] || [text hasSuffix:@"e"] || [text hasSuffix:@"E"] ||
            [text hasSuffix:@"+"] || [text hasSuffix:@"-"]) return nil;
        NSScanner *scanner = [NSScanner scannerWithString:text];
        scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        double number;
        if (![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number) ||
            number < [lower[index] doubleValue] || number > [upper[index] doubleValue]) return nil;
        values[keys[index]] = @(number);
    }
    values[@"outputMode"] = self.output.indexOfSelectedItem == 1 ? @"gaps" : @"remove";
    return [self addPauseTargetToValues:values] ? values : nil;
}

- (NSDictionary *)settingsValuesFromResponse:(NSDictionary *)response {
    NSDictionary *wire = response[@"settings"];
    if (![wire isKindOfClass:NSDictionary.class] || ![response[@"output"] isKindOfClass:NSString.class]) return nil;
    NSArray *source = @[@"threshold", @"minimum", @"before", @"after"];
    NSArray *target = @[@"thresholdDBFS", @"minimumSilenceDuration", @"beforeSpeechPadding", @"afterSpeechPadding"];
    NSMutableDictionary *values = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < source.count; ++index) {
        if (![wire[source[index]] isKindOfClass:NSNumber.class]) return nil;
        values[target[index]] = wire[source[index]];
    }
    values[@"outputMode"] = response[@"output"];
    if ([wire[@"pauseTarget"] isKindOfClass:NSNumber.class]) values[@"pauseTargetDuration"] = wire[@"pauseTarget"];
    return values;
}

// The harness injects this scheduler, so coalescing/cancellation tests use no
// real run loop, windows, host activation, or elapsed-time assumptions.
- (void)scheduleAutomaticUpdate:(dispatch_block_t)block afterDelay:(NSTimeInterval)delay {
    [self.automaticUpdateTimer invalidate];
    self.automaticUpdateTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) { block(); }];
    [NSRunLoop.mainRunLoop addTimer:self.automaticUpdateTimer forMode:NSRunLoopCommonModes];
}

- (void)queueAutomaticUpdate {
    if (!self.automaticUpdatePending || self.automaticUpdateEdit || self.reviewClient.updatingCuts ||
        self.automaticUpdateRejectedGeneration == self.automaticUpdateGeneration) return;
    NSUInteger generation = self.automaticUpdateGeneration;
    __weak SSWorkflowViewController *weakSelf = self;
    [self scheduleAutomaticUpdate:^{ [weakSelf performAutomaticUpdate:generation]; } afterDelay:0.25];
}

- (void)performAutomaticUpdate:(NSUInteger)generation {
    if (generation != self.automaticUpdateGeneration || !self.automaticUpdatePending ||
        !self.viewVisible || !self.timeline || !self.settingsLoaded || self.verificationPanelPending ||
        self.settingsSavePending || self.automaticUpdateEdit || self.reviewClient.busy ||
        self.automaticUpdateRejectedGeneration == generation) return;
    if (!self.libraryURL || !self.projectUID.length) return;
    NSDictionary *context = [self observedProjectContext];
    if (context && ![self projectContext:context hasSameIdentityAs:
        @{@"projectUID": self.projectUID, @"libraryURL": self.libraryURL}]) {
        [self refreshProject]; return;
    }
    // A missing SDK proxy cannot erase an already-owned local draft. This
    // read-only command still requires the worker's independent fresh native
    // project, selection, view, and visible-settings authorization. Manual
    // Analyze and Apply retain their separate fresh SDK identity checks.
    NSDictionary *values = [self automaticSettingsValues];
    if (!values) return;
    if (![values isEqual:self.pendingAutomaticSettings]) { [self settingsChanged:nil]; return; }
    if (!self.reviewClient.automaticPreviewAvailable || !self.reviewClient.canUpdateCuts) return;
    NSString *edit = NSUUID.UUID.UUIDString;
    self.automaticUpdateEdit = edit;
    self.automaticUpdateSubmittedGeneration = generation;
    self.submittedAutomaticSettings = values;
    self.settingsPanel.accessibilityIdentifier = [@"silentsnip.workflow.settings.requested." stringByAppendingString:edit];
    [self setStatusMessage:@"Updating cut ranges…"];
    if (![self.reviewClient automaticallyUpdateCutsWithSettings:values edit:edit]) {
        BOOL superseded = generation != self.automaticUpdateGeneration;
        if ([self.automaticUpdateEdit isEqual:edit]) {
            self.automaticUpdateEdit = nil;
            self.submittedAutomaticSettings = nil;
            self.settingsPanel.accessibilityIdentifier = @"silentsnip.workflow.settings";
            [self setStatusMessage:superseded ? @"Updating cut ranges…" : @"Return to Final Cut Pro to update the ranges."];
        }
        // A synchronous client publication can reenter with a newer draft.
        // Resume that generation only; an unchanged background refusal waits
        // for foreground activation rather than starting a retry loop.
        if (superseded) [self queueAutomaticUpdate];
    }
    [self updateReviewControls];
}

- (void)settingsChanged:(id)sender {
    if ((self.reviewClient.busy && !self.reviewClient.updatingCuts) ||
        [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
    if (!self.handlingTextSettingsChange && ![self observedProjectMatchesSettings]) { [self refreshProject]; return; }
    if (sender == self.output) {
        self.pauseTargetRow.hidden = self.output.indexOfSelectedItem == 1;
        self.pauseTargetField.enabled = self.settingsLoaded && !self.pauseTargetRow.hidden;
    }
    [self clearCompletionMessage];
    BOOL hadReview = self.reviewClient != nil;
    if (self.reviewClient.automaticPreviewAvailable || self.reviewClient.updatingCuts) {
        NSDictionary *values = [self automaticSettingsValues];
        if (values && ((self.automaticUpdatePending && [values isEqual:self.pendingAutomaticSettings]) ||
            (!self.automaticUpdatePending && !self.reviewClient.updatingCuts &&
             [values isEqual:[self settingsValuesFromResponse:self.reviewResponse]]))) return;
        [self.automaticUpdateTimer invalidate];
        self.automaticUpdateTimer = nil;
        self.automaticUpdateGeneration += 1;
        self.automaticUpdateRejectedGeneration = 0;
        self.automaticUpdatePending = YES;
        self.pendingAutomaticSettings = values;
        // Invalidate the old native snapshot immediately, including while its
        // reply is in flight. It cannot represent the user's newer field text.
        self.settingsPanel.accessibilityIdentifier = @"silentsnip.workflow.settings";
        [self.reviewClient markSettingsDirty];
        [self updateReviewControls];
        [self setStatusMessage:values ? @"Updating cut ranges…" : @"Finish entering detection settings."];
        [self queueAutomaticUpdate];
        return;
    }
    [self invalidateReview];
    self.analyzeButton.enabled = self.settingsLoaded;
    if (hadReview) {
        self.analyzeButton.title = @"Analyze Again";
        [self setStatusMessage:@"Click Analyze Again to update the cuts."];
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    // During the native field-editor notification the SDK can temporarily
    // omit its active sequence. Record the draft without synchronously asking
    // the host; the debounced update still requires a fresh identity match.
    BOOL previous = self.handlingTextSettingsChange;
    self.handlingTextSettingsChange = YES;
    [self settingsChanged:notification.object];
    self.handlingTextSettingsChange = previous;
}

- (void)updateReviewControls {
    [self updateReviewControlsRefreshingSelection:NO];
}

- (void)updateReviewControlsRefreshingSelection:(BOOL)refreshSelection {
    BOOL currentRanges = !self.automaticUpdatePending && !self.reviewClient.updatingCuts;
    BOOL canChangeSelection = self.reviewClient.canChangeSelection;
    BOOL changed = SSWorkflowSetControlEnabled(self.applyButton, currentRanges && self.reviewClient.canApply);
    changed |= SSWorkflowSetControlEnabled(self.cancelButton, self.reviewClient.canCancel);
    changed |= [self updateGroupControls];
    [self updateBoundaryControls];
    changed |= SSWorkflowSetControlEnabled(self.navigateButton,
        currentRanges && self.reviewClient.canHighlight && self.activeCutID.length > 0);
    BOOL previousRetryHidden = self.retryButton.hidden;
    BOOL previousApplyHidden = self.applyButton.hidden;
    self.retryButton.hidden = ![self.reviewResponse[@"canRetryVerification"] boolValue];
    self.applyButton.hidden = !self.retryButton.hidden;
    self.cancelButton.hidden = NO;
    self.allButton.hidden = NO;
    self.noneButton.hidden = NO;
    changed |= previousRetryHidden != self.retryButton.hidden || previousApplyHidden != self.applyButton.hidden;
    changed |= SSWorkflowSetControlEnabled(self.retryButton, !self.reviewClient.busy);
    self.progressIndicator.hidden = !self.reviewClient.busy;
    NSNumber *fraction = self.reviewResponse[@"progress"];
    self.progressIndicator.indeterminate = fraction == nil;
    if (fraction) self.progressIndicator.doubleValue = fraction.doubleValue;
    if (self.reviewClient.busy && !fraction) [self.progressIndicator startAnimation:nil];
    else [self.progressIndicator stopAnimation:nil];
    for (NSButton *row in self.cutList.arrangedSubviews) {
        NSUInteger index = (NSUInteger)row.tag;
        NSDictionary *cut = index < self.reviewCuts.count ? self.reviewCuts[index] : nil;
        // An equal snapshot can be published while the worker is still handling
        // the click. Keep the optimistic state until a fresh snapshot or unlock.
        if (cut && (refreshSelection || canChangeSelection)) {
            NSControlStateValue state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            if (row.state != state) row.state = state;
        }
        changed |= SSWorkflowSetControlEnabled(row, canChangeSelection && [cut[@"eligible"] boolValue]);
    }
    [self updateActionAppearance];
    [self updateDocumentFrame];
    NSString *state = self.reviewResponse[@"state"] ?: @"idle";
    if (self.reviewClient.updatingCuts) state = @"recalculating";
    NSArray *knownStates = @[@"idle", @"starting", @"capturing", @"rendering", @"analyzing", @"review",
        @"recalculating", @"applying", @"importing", @"verifying", @"completed", @"complete", @"cancelled", @"cancelling", @"failed"];
    if (![knownStates containsObject:state]) state = @"working";
    if (![self.pointerReviewState isEqual:state]) {
        self.pointerReviewState = state;
        changed = YES;
    }
    if (changed) [(SSWorkflowContentView *)self.view requestDefaultCursorRefreshForPhase:[@"state-" stringByAppendingString:state]];
}

- (void)updateReviewStatusContent:(NSDictionary *)response {
    NSString *message = response[@"message"] ?: @"";
    NSString *state = response[@"state"];
    BOOL recovery = [response[@"canRetryVerification"] boolValue];
    BOOL completed = [@[@"completed", @"complete"] containsObject:state] && !recovery;
    // Accept the previous worker's known informational copy as well as the
    // current wording. Unknown appended warnings must remain visible.
    NSArray<NSString *> *normalReviews = @[
        @"Analysis complete. Review the proposed ranges, then click Apply Cuts.",
        @"Analysis complete. Review the proposed ranges, then choose Apply Selected Cuts."
    ];
    NSString *normalReview = nil;
    for (NSString *candidate in normalReviews) {
        if ([message hasPrefix:candidate]) { normalReview = candidate; break; }
    }
    BOOL snapshot = [response[@"usesAudioSnapshot"] boolValue];
    NSArray<NSString *> *snapshotNotices = @[
        @"Cuts use the last analyzed audio. Apply Cuts verifies the current audio before editing. Click Analyze Again after changing volume or audio effects.",
        @"Cuts use the last analyzed audio. Apply verifies current audio before editing. Use Analyze Audio Again after changing volume or effects."
    ];
    BOOL knownSnapshotMessage = NO;
    for (NSString *notice in snapshotNotices) {
        for (NSString *review in normalReviews) {
            if ([message isEqual:[NSString stringWithFormat:@"%@ %@", notice, review]]) knownSnapshotMessage = YES;
        }
    }
    if (!recovery && snapshot && [state isEqual:@"review"] &&
        knownSnapshotMessage) {
        [self updateStatusContent:@"Cuts updated. Apply Cuts verifies the current audio. Click Analyze Again after changing volume or audio effects."
                requiresAttention:NO];
        self.statusDetails.stringValue = message;
        self.statusDetails.toolTip = message;
        self.statusLabel.toolTip = message;
        return;
    }
    if (completed || (!recovery && !snapshot && [state isEqual:@"review"] && normalReview != nil)) {
        NSString *remaining = message;
        if (!completed) {
            // Remove only known informational copy. Any appended cleanup or
            // recovery notice remains actionable rather than disappearing.
            NSArray<NSString *> *boilerplate = @[
                normalReview,
                @"Reused verified audio measurements after checking the current project and source contents.",
                @"Analyzed original audio; this clip has no audio adjustments or processing effects.",
                @"Analyzed Final Cut Pro’s rendered audio, including clip volume and enabled audio effects.",
                @"Analyzed Final Cut’s rendered audio, including clip volume and enabled effects.",
                @"Threshold uses 10 ms average loudness (RMS), not peak meters.",
                @"Apply creates a cleaned project copy with the retained processed sound preserved.",
                @"The original project keeps its editable effects.",
                @"Apply cuts the source clips in a cleaned project copy and keeps their audio effects editable.",
                @"Quiet breaths may qualify; this detector does not classify breaths."
            ];
            for (NSString *text in boilerplate) remaining = [remaining stringByReplacingOccurrencesOfString:text withString:@""];
            remaining = [remaining stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
        [self updateStatusContent:completed ? ([response[@"verificationOnly"] boolValue] ? @"Result verified." : @"Cuts applied.") : remaining
                requiresAttention:!completed && remaining.length > 0];
        self.statusDetails.stringValue = message;
        self.statusDetails.toolTip = message;
        self.statusLabel.toolTip = message;
        return;
    }
    [self updateStatusContent:message requiresAttention:[state isEqual:@"review"] && (snapshot || message.length > 180)];
}

- (BOOL)canReuseCutRowsForCuts:(NSArray<NSDictionary *> *)cuts {
    NSArray<NSView *> *rows = self.cutList.arrangedSubviews;
    if (cuts.count != self.reviewCuts.count || rows.count != cuts.count) return NO;
    for (NSUInteger index = 0; index < cuts.count; ++index) {
        if (![rows[index] isKindOfClass:SSWorkflowCutRow.class] || ((SSWorkflowCutRow *)rows[index]).tag != (NSInteger)index) return NO;
        if (![cuts[index][@"id"] isEqual:self.reviewCuts[index][@"id"]]) return NO;
    }
    return YES;
}

- (void)updateDetailsForRow:(SSWorkflowCutRow *)row cut:(NSDictionary *)cut {
    row.title = [NSString stringWithFormat:@"%@ – %@  (%@)", cut[@"start"], cut[@"end"], cut[@"duration"]];
    row.startValue = cut[@"start"];
    row.endValue = cut[@"end"];
    row.durationValue = cut[@"duration"];
    row.needsReview = [cut[@"needsReview"] boolValue];
    row.accessibilityLabel = row.needsReview ? [row.title stringByAppendingString:@", Review needed"] : row.title;
    row.toolTip = [NSString stringWithFormat:@"%@%@%@", row.title,
        [cut[@"reason"] length] ? @" — " : @"", cut[@"reason"] ?: @""];
    if (row.needsReview) {
        row.toolTip = [row.toolTip stringByAppendingString:@"\nThis pause changed after you chose to keep it. Review the new range before including it."];
    }
    row.accessibilityHelp = row.toolTip;
    row.needsDisplay = YES;
}

- (void)receiveReview:(NSDictionary *)response {
    NSString *state = response[@"state"];
    BOOL terminal = [@[@"completed", @"complete", @"failed", @"cancelled", @"unavailable"] containsObject:state];
    if (terminal) {
        [self cancelAutomaticUpdate];
    } else if (self.automaticUpdateEdit && !self.reviewClient.updatingCuts &&
        ([response[@"settingsEdit"] isEqual:self.automaticUpdateEdit] ||
         [response[@"rejectedSettingsEdit"] isEqual:self.automaticUpdateEdit])) {
        BOOL rejected = [response[@"rejectedSettingsEdit"] isEqual:self.automaticUpdateEdit];
        BOOL latest = self.automaticUpdateSubmittedGeneration == self.automaticUpdateGeneration;
        BOOL accepted = !rejected && [state isEqual:@"review"] && ![response[@"provisional"] boolValue] &&
            [[self settingsValuesFromResponse:response] isEqual:self.submittedAutomaticSettings] &&
            [[self automaticSettingsValues] isEqual:self.submittedAutomaticSettings];
        self.automaticUpdateEdit = nil;
        self.submittedAutomaticSettings = nil;
        self.settingsPanel.accessibilityIdentifier = @"silentsnip.workflow.settings";
        if (latest && accepted) {
            self.automaticUpdatePending = NO;
            self.pendingAutomaticSettings = nil;
            [self.automaticUpdateTimer invalidate];
            self.automaticUpdateTimer = nil;
        } else if (latest && rejected) {
            // A rejected native snapshot is not an accepted settings revision.
            // Wait for a new edit/foreground return instead of resending it in
            // an endless timer loop.
            self.automaticUpdateRejectedGeneration = self.automaticUpdateGeneration;
        }
    }
    BOOL navigationSettled = !self.reviewClient.busy &&
        (self.navigationPending || [self.reviewResponse[@"state"] isEqual:@"navigating"]);
    if (navigationSettled) self.navigationPending = NO;
    self.reviewResponse = response;
    if (!self.reviewClient.busy) {
        self.verifyButton.accessibilityIdentifier = @"silentsnip.workflow.verify";
        self.navigateButton.accessibilityIdentifier = @"silentsnip.workflow.navigate";
    }
    BOOL deferRanges = self.automaticUpdatePending && !terminal;
    NSArray *cuts = deferRanges || [state isEqual:@"navigating"] ? self.reviewCuts : (response[@"cuts"] ?: @[]);
    BOOL cutsChanged = ![cuts isEqual:self.reviewCuts];
    BOOL rebuildRows = cutsChanged && ![self canReuseCutRowsForCuts:cuts];
    NSArray *previousCuts = self.reviewCuts;
    if (cutsChanged) self.reviewCuts = cuts;
    if (rebuildRows) {
        for (NSView *row in self.cutList.arrangedSubviews.copy) [row removeFromSuperview];
        for (NSUInteger index = 0; index < cuts.count; ++index) {
            NSDictionary *cut = cuts[index];
            SSWorkflowCutRow *row = [[SSWorkflowCutRow alloc] initWithFrame:NSZeroRect];
            row.cell = [SSWorkflowCutCell new];
            row.buttonType = NSButtonTypeSwitch;
            row.imagePosition = NSImageLeft;
            row.alignment = NSTextAlignmentLeft;
            row.target = self;
            row.action = @selector(toggleCut:);
            row.controlSize = NSControlSizeSmall;
            row.textFont = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            row.tag = (NSInteger)index;
            row.state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
            row.font = row.textFont;
            [self updateDetailsForRow:row cut:cut];
            row.accessibilityIdentifier = [@"silentsnip.workflow.cut." stringByAppendingString:cut[@"id"]];
            __weak SSWorkflowViewController *weakSelf = self;
            row.chooseRow = ^(NSEvent *event) {
                SSWorkflowViewController *owner = weakSelf;
                [owner.view.window makeFirstResponder:owner.cutList];
                BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
                [owner selectReviewRow:index scroll:NO extending:shift];
                if (event.clickCount == 2 && !shift) [owner goToCut:nil];
            };
            [self.cutList addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.cutList.widthAnchor constant:-12].active = YES;
        }
        NSUInteger index = [self activeCutIndex];
        [self selectReviewRow:index == NSNotFound ? 0 : index scroll:NO];
        [(SSWorkflowContentView *)self.view requestDefaultCursorRefreshForPhase:@"rows"];
    } else if (cutsChanged) {
        NSArray *displayedFields = @[@"start", @"end", @"duration", @"reason", @"needsReview"];
        for (SSWorkflowCutRow *row in self.cutList.arrangedSubviews) {
            NSUInteger index = (NSUInteger)row.tag;
            NSDictionary *cut = cuts[index], *previous = previousCuts[index];
            for (NSString *field in displayedFields) {
                if (cut[field] == previous[field] || [cut[field] isEqual:previous[field]]) continue;
                [self updateDetailsForRow:row cut:cut];
                break;
            }
        }
    }
    NSString *summary = response[@"summary"] ?: @"";
    NSString *target = response[@"targetClipName"];
    // The controls update below lays out the complete response once.
    if (!deferRanges) {
        if (![state isEqual:@"navigating"]) {
            self.analyzedSpanLabel.stringValue = response[@"analyzedSpan"] ?: @"";
            self.analyzedSpanLabel.hidden = self.analyzedSpanLabel.stringValue.length == 0;
        }
        self.reviewSummary.stringValue = target.length ? [NSString stringWithFormat:@"Clip: %@\n%@", target, summary] : summary;
        [self styleReviewSummary];
        self.reviewSummary.toolTip = self.reviewSummary.stringValue;
        [self updateReviewStatusContent:response];
    } else {
        [self updateStatusContent:!self.pendingAutomaticSettings ? @"Finish entering detection settings." :
            (self.automaticUpdateRejectedGeneration == self.automaticUpdateGeneration ?
                @"Unable to update the ranges. Click Analyze Again to refresh the audio." : @"Updating cut ranges…") requiresAttention:NO];
    }
    [self setControlsEnabled:self.settingsLoaded && (!self.reviewClient.busy || self.reviewClient.updatingCuts)];
    self.analyzeButton.title = @"Analyze Again";
    [self updateReviewControlsRefreshingSelection:cutsChanged && !rebuildRows];
    if (terminal) {
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
    } else {
        // An SDK sequence change may have arrived while navigation was busy.
        // Recheck now, after rendering this response, so invalidation can
        // discard all of the previous project's rows and settings.
        if (navigationSettled) [self refreshProject];
        if (self.automaticUpdatePending && !self.reviewClient.busy && !self.automaticUpdateEdit) {
            [self queueAutomaticUpdate];
        }
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
    if (!self.settingsLoaded || self.settingsSavePending || self.reviewClient.busy || [self.reviewResponse[@"canRetryVerification"] boolValue]) return;
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
    [self setStatusMessage:@"Analyzing the selected timeline clip…"];
    [self.reviewClient startWithLibraryURL:self.libraryURL projectUID:self.projectUID
        projectName:self.projectLabel.stringValue settings:values gesture:gesture];
    [self updateReviewControls];
}

- (void)applyCuts:(id)sender {
    if (self.automaticUpdatePending || self.reviewClient.updatingCuts || !self.reviewClient.canApply) return;
    if (![self observedProjectMatchesSettings]) { [self refreshProject]; return; }
    NSString *gesture = NSUUID.UUID.UUIDString;
    self.applyButton.accessibilityIdentifier = [@"silentsnip.workflow.apply.requested." stringByAppendingString:gesture];
    self.applyButton.enabled = NO;
    [self.reviewClient sendApplyWithGesture:gesture];
    [self setControlsEnabled:self.settingsLoaded && (!self.reviewClient.busy || self.reviewClient.updatingCuts)];
    [self updateReviewControls];
}

static CMTime SSNavigationTimeFromWire(NSDictionary *time) {
    return CMTimeMake([time[@"numerator"] longLongValue], [time[@"denominator"] intValue]);
}

static BOOL SSExactNavigationTime(CMTime actual, CMTime expected) {
    return CMTIME_IS_NUMERIC(actual) && CMTIME_IS_NUMERIC(expected) &&
        actual.epoch == expected.epoch && CMTimeCompare(actual, expected) == 0;
}

- (BOOL)ownsNavigationWindow:(NSWindow *)window {
    return self.viewVisible && [self hasVerifiedWindowHost] && window && self.view.window == window &&
        window.isVisible && window.isKeyWindow && !self.view.hiddenOrHasHiddenAncestor;
}

- (BOOL)movePlayheadForPermit:(NSDictionary *)permit context:(NSDictionary *)context window:(NSWindow *)window {
    FCPXTimeline *timeline = self.timeline;
    FCPXSequence *sequence = timeline.activeSequence;
    if (![self projectContext:[self projectContextForSequence:sequence] hasSameIdentityAs:context]) return NO;
    CMTime start = SSNavigationTimeFromWire(permit[@"sequenceStart"]);
    CMTime duration = SSNavigationTimeFromWire(permit[@"sequenceDuration"]);
    CMTime frame = SSNavigationTimeFromWire(permit[@"frameDuration"]);
    CMTime target = SSNavigationTimeFromWire(permit[@"time"]);
    CMTime end = CMTimeAdd(start, duration);
    if (!SSExactNavigationTime(sequence.startTime, start) || !SSExactNavigationTime(sequence.duration, duration) ||
        !SSExactNavigationTime(sequence.frameDuration, frame) || !CMTIME_IS_NUMERIC(target) || !CMTIME_IS_NUMERIC(end) ||
        CMTimeCompare(target, start) < 0 || CMTimeCompare(target, end) >= 0 || self.timeline != timeline ||
        ![self projectContext:[self observedProjectContext] hasSameIdentityAs:context] ||
        ![self ownsNavigationWindow:window]) return NO;
    // Only this explicit, consumed permit sends a native command. An invalid
    // or different result is reported to the worker without another attempt.
    CMTime actual = [timeline movePlayheadTo:target];
    return SSExactNavigationTime(actual, target) && self.timeline == timeline &&
        [self projectContext:[self observedProjectContext] hasSameIdentityAs:context];
}

- (void)goToCut:(id)sender {
    NSString *cutID = self.activeCutID;
    if (!cutID.length || !self.reviewClient.canHighlight || !self.viewVisible || self.automaticUpdatePending) return;
    NSDictionary *context = [self observedProjectContext];
    if (![self projectContext:context hasSameIdentityAs:@{@"projectUID": self.projectUID ?: @"",
        @"libraryURL": self.libraryURL ?: NSNull.null}]) return;
    BOOL useSDK = self.reviewClient.supportsNativeNavigation && [self.timeline respondsToSelector:@selector(movePlayheadTo:)];
    __weak NSWindow *window = useSDK ? self.view.window : nil;
    if (useSDK && ![self ownsNavigationWindow:window]) return;
    // Track both dispatch paths, including requests rejected before the
    // worker publishes a navigating state.
    self.navigationPending = YES;
    BOOL accepted;
    if (useSDK) {
        NSString *gesture = NSUUID.UUID.UUIDString;
        self.navigateButton.accessibilityIdentifier = [@"silentsnip.workflow.navigate.requested." stringByAppendingString:gesture];
        self.navigateButton.enabled = NO;
        NSUInteger generation = self.reviewGeneration;
        NSUInteger contextGeneration = self.contextGeneration;
        __weak SSWorkflowViewController *weakSelf = self;
        accepted = [self.reviewClient navigateCut:cutID gesture:gesture move:^BOOL(NSDictionary *permit) {
            SSWorkflowViewController *owner = weakSelf;
            return owner && owner.viewVisible && owner.reviewGeneration == generation &&
                owner.contextGeneration == contextGeneration && !owner.automaticUpdatePending &&
                [owner movePlayheadForPermit:permit context:context window:window];
        }];
    } else {
        accepted = [self.reviewClient highlightCut:cutID];
    }
    if (!accepted) {
        self.navigationPending = NO;
        self.navigateButton.accessibilityIdentifier = @"silentsnip.workflow.navigate";
    }
    [self setControlsEnabled:self.settingsLoaded && (!self.reviewClient.busy || self.reviewClient.updatingCuts)];
    [self updateReviewControls];
}

// Keep panel selection separate from dispatch so stale panels cannot act on a
// newly opened project and the native gesture exists only for an explicit action.
- (void)verifyResultURL:(NSURL *)url context:(NSDictionary *)context generation:(NSUInteger)generation {
    if (!self.viewVisible || !self.timeline) return;
    NSDictionary *current = [self observedProjectContext];
    if (generation != self.contextGeneration || !self.settingsLoaded || self.reviewClient.busy ||
        ![self observedProjectMatchesSettings] || ![self projectContext:context hasSameIdentityAs:current]) {
        [self setStatusMessage:@"The active project changed. Open the intended project and click Verify Existing Result." requiresAttention:YES];
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
    [self setStatusMessage:@"Verifying the existing result…"];
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
    if (!self.settingsLoaded || self.settingsSavePending || self.automaticUpdatePending || self.verificationPanelPending || self.reviewClient.busy ||
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
        [self setStatusMessage:@"Final Cut Pro did not restore the open project after the file dialog closed. Click Verify Existing Result to try again." requiresAttention:YES];
        return;
    }
    if ([ticket[@"generation"] unsignedIntegerValue] != self.contextGeneration ||
        ![self projectContext:ticket[@"context"] hasSameIdentityAs:current]) {
        [self refreshProject];
        [self setStatusMessage:@"The active project changed while selecting the result. Open the intended project and click Verify Existing Result." requiresAttention:YES];
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
    panel.title = @"Verify Existing Result";
    panel.prompt = @"Verify";
    panel.message = @"Select Silent Snip.fcpxml from the saved result folder. Silent Snip verifies the existing project without importing it again.";
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    __weak SSWorkflowViewController *weakSelf = self;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        NSURL *selected = response == NSModalResponseOK ? panel.URL : nil;
        [weakSelf completeVerificationPanelWithURL:selected ticket:ticket];
    }];
}

- (void)cancelReview:(id)sender {
    [self cancelAutomaticUpdate];
    if (self.reviewClient.canCancel) [self.reviewClient cancel];
    [self updateReviewControls];
}

- (NSUInteger)activeCutIndex {
    return [self indexOfCutID:self.activeCutID];
}

- (NSUInteger)indexOfCutID:(NSString *)cutID {
    return [self.reviewCuts indexOfObjectPassingTest:^BOOL(NSDictionary *cut, NSUInteger index, BOOL *stop) {
        return [cut[@"id"] isEqual:cutID];
    }];
}

- (void)selectReviewRow:(NSUInteger)index scroll:(BOOL)scroll {
    [self selectReviewRow:index scroll:scroll extending:NO];
}

- (NSRange)reviewGroup {
    if (![self.reviewResponse[@"canSelectGroup"] boolValue]) return NSMakeRange(NSNotFound, 0);
    NSUInteger active = [self activeCutIndex], anchor = [self indexOfCutID:self.reviewSelectionAnchor];
    if (active == NSNotFound || anchor == NSNotFound || active == anchor) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(MIN(active, anchor), MAX(active, anchor) - MIN(active, anchor) + 1);
}

- (BOOL)updateGroupControls {
    NSRange group = [self reviewGroup];
    BOOL grouped = group.length > 1;
    BOOL hasEligibleCut = !grouped;
    for (NSUInteger index = 0; index < group.length; ++index) {
        if ([self.reviewCuts[group.location + index][@"eligible"] boolValue]) {
            hasEligibleCut = YES;
            break;
        }
    }
    self.allButton.title = grouped ? @"Cut Selected" : @"Select All";
    self.noneButton.title = grouped ? @"Keep Selected" : @"Deselect All";
    BOOL enabled = !self.automaticUpdatePending && !self.reviewClient.updatingCuts &&
        self.reviewClient.canChangeSelection && hasEligibleCut;
    BOOL changed = SSWorkflowSetControlEnabled(self.allButton, enabled);
    changed |= SSWorkflowSetControlEnabled(self.noneButton, enabled);
    return changed;
}

- (void)updateBoundaryControls {
    BOOL hasEditableCuts = [self.reviewCuts indexOfObjectPassingTest:^BOOL(NSDictionary *cut, NSUInteger index, BOOL *stop) {
        return [cut[@"editMask"] unsignedIntegerValue] != 0;
    }] != NSNotFound;
    self.boundaryActions.hidden = !hasEditableCuts;
    NSUInteger index = [self activeCutIndex];
    NSUInteger mask = index < self.reviewCuts.count ? [self.reviewCuts[index][@"editMask"] unsignedIntegerValue] : 0;
    if (self.automaticUpdatePending || !self.reviewClient.canChangeSelection) mask = 0;
    self.startStepper.minValue = (mask & SSReviewBoundaryStartEarlier) != 0 ? -1 : 0;
    self.startStepper.maxValue = (mask & SSReviewBoundaryStartLater) != 0 ? 1 : 0;
    self.endStepper.minValue = (mask & SSReviewBoundaryEndEarlier) != 0 ? -1 : 0;
    self.endStepper.maxValue = (mask & SSReviewBoundaryEndLater) != 0 ? 1 : 0;
    self.startStepper.enabled = (mask & (SSReviewBoundaryStartEarlier | SSReviewBoundaryStartLater)) != 0;
    self.endStepper.enabled = (mask & (SSReviewBoundaryEndEarlier | SSReviewBoundaryEndLater)) != 0;
    self.resetCutButton.enabled = (mask & SSReviewBoundaryReset) != 0;
}

- (void)sendBoundaryEdit:(SSReviewBoundaryEdit)edit {
    if (self.automaticUpdatePending || !self.reviewClient.canChangeSelection || !self.activeCutID.length) return;
    [self.reviewClient adjustCut:self.activeCutID edit:edit];
    [self updateReviewControls];
}

- (void)stepCutBoundary:(NSStepper *)sender {
    double direction = sender.doubleValue;
    sender.doubleValue = 0;
    if (direction == 0) return;
    SSReviewBoundaryEdit edit = sender == self.startStepper
        ? (direction > 0 ? SSReviewBoundaryStartLater : SSReviewBoundaryStartEarlier)
        : (direction > 0 ? SSReviewBoundaryEndLater : SSReviewBoundaryEndEarlier);
    [self sendBoundaryEdit:edit];
}

- (void)resetCutBoundary:(id)sender { [self sendBoundaryEdit:SSReviewBoundaryReset]; }

- (void)selectReviewRow:(NSUInteger)index scroll:(BOOL)scroll extending:(BOOL)extending {
    NSArray<SSWorkflowCutRow *> *rows = (NSArray *)self.cutList.arrangedSubviews;
    NSString *previous = self.activeCutID;
    self.activeCutID = index < self.reviewCuts.count ? self.reviewCuts[index][@"id"] : nil;
    if (!extending) self.reviewSelectionAnchor = self.activeCutID;
    else if (!self.reviewSelectionAnchor) self.reviewSelectionAnchor = previous ?: self.activeCutID;
    NSRange group = [self reviewGroup];
    for (SSWorkflowCutRow *row in rows) {
        row.activeRow = (NSUInteger)row.tag == index;
        row.groupedRow = NSLocationInRange((NSUInteger)row.tag, group);
    }
    [self updateGroupControls];
    [self updateBoundaryControls];
    if (scroll && index < rows.count) [rows[index] scrollRectToVisible:rows[index].bounds];
}

- (BOOL)handleReviewKey:(NSEvent *)event {
    if (self.reviewCuts.count == 0 || event.charactersIgnoringModifiers.length != 1 ||
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
            NSEventModifierFlagOption))) return NO;
    BOOL shift = (event.modifierFlags & NSEventModifierFlagShift) != 0;
    NSUInteger index = [self activeCutIndex];
    if (index == NSNotFound) index = 0;
    switch ([event.charactersIgnoringModifiers characterAtIndex:0]) {
        case NSUpArrowFunctionKey:
            [self selectReviewRow:index > 0 ? index - 1 : 0 scroll:YES extending:shift];
            return YES;
        case NSDownArrowFunctionKey:
            [self selectReviewRow:MIN(index + 1, self.reviewCuts.count - 1) scroll:YES extending:shift];
            return YES;
        case ' ': {
            if (shift) return NO;
            NSButton *row = (NSButton *)self.cutList.arrangedSubviews[index];
            if (row.enabled) {
                row.state = row.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
                [self toggleCut:row];
            }
            return YES;
        }
        case '\r':
        case '\x03':
            if (shift) return NO;
            [self goToCut:nil];
            return YES;
        default: return NO;
    }
}

- (void)toggleCut:(NSButton *)sender {
    NSUInteger index = (NSUInteger)sender.tag;
    if (!self.reviewClient.canChangeSelection || index >= self.reviewCuts.count) return;
    if (index != [self activeCutIndex]) [self selectReviewRow:index scroll:NO];
    NSDictionary *cut = self.reviewCuts[index];
    if (![self.reviewClient setCut:cut[@"id"] included:sender.state == NSControlStateValueOn]) {
        sender.state = [cut[@"included"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self updateReviewControls];
}
- (void)setReviewGroupIncluded:(BOOL)included {
    if (self.automaticUpdatePending || !self.reviewClient.canChangeSelection) return;
    NSRange group = [self reviewGroup];
    if (group.length > 1) {
        [self.reviewClient setCutsFrom:self.reviewCuts[group.location][@"id"]
            through:self.reviewCuts[NSMaxRange(group) - 1][@"id"] included:included];
    } else {
        [self.reviewClient selectAll:included];
    }
    [self updateReviewControls];
}
- (void)selectAllCuts:(id)sender { [self setReviewGroupIncluded:YES]; }
- (void)deselectAllCuts:(id)sender { [self setReviewGroupIncluded:NO]; }
- (void)retryVerification:(id)sender { [self.reviewClient retryVerification]; [self updateReviewControls]; }

- (void)saveSettings:(id)sender {
    if (!self.settingsLoaded || self.settingsSavePending || (self.reviewClient.busy && !self.reviewClient.updatingCuts) || !self.libraryURL || !self.projectUID.length) return;
    // A pending host notification must not let old visible controls write
    // settings under a different project's identity.
    if (![self observedProjectMatchesSettings]) {
        [self refreshProject];
        return;
    }
    NSDictionary *values = [self currentSettingsValues];
    if (!values) return;
    NSUInteger generation = self.contextGeneration;
    self.settingsSavePending = YES;
    [self setControlsEnabled:self.reviewClient.automaticPreviewAvailable || self.reviewClient.updatingCuts];
    [self setStatusMessage:@"Saving settings…"];
    __weak SSWorkflowViewController *weakSelf = self;
    [self.settings saveValues:values libraryURL:self.libraryURL projectUID:self.projectUID completion:^(NSError *error) {
        SSWorkflowViewController *owner = weakSelf;
        if (!owner || generation != owner.contextGeneration || !owner.timeline) return;
        owner.settingsSavePending = NO;
        [owner setControlsEnabled:YES];
        if (owner.automaticUpdatePending) {
            owner.automaticUpdateRejectedGeneration = 0;
            [owner queueAutomaticUpdate];
        }
        if (!owner.automaticUpdatePending && !owner.reviewClient.busy && ![owner.reviewResponse[@"canRetryVerification"] boolValue])
            [owner setStatusMessage:error ? error.localizedDescription : @"Settings saved." requiresAttention:error != nil];
    }];
}
@end
