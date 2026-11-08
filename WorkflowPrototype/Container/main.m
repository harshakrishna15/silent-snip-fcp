#import <AppKit/AppKit.h>

static NSTextField *SSWelcomeLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.maximumNumberOfLines = 0;
    return label;
}

static NSStackView *SSWelcomeStep(NSString *number, NSString *title, NSString *detail) {
    NSTextField *index = SSWelcomeLabel(number, 12, NSFontWeightMedium, NSColor.secondaryLabelColor);
    index.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    index.alignment = NSTextAlignmentCenter;
    index.translatesAutoresizingMaskIntoConstraints = NO;
    [index.widthAnchor constraintEqualToConstant:22].active = YES;
    NSTextField *heading = SSWelcomeLabel(title, 13, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *description = SSWelcomeLabel(detail, 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    description.preferredMaxLayoutWidth = 370;
    NSStackView *copy = [NSStackView stackViewWithViews:@[heading, description]];
    copy.orientation = NSUserInterfaceLayoutOrientationVertical;
    copy.alignment = NSLayoutAttributeLeading;
    copy.spacing = 3;
    NSStackView *row = [NSStackView stackViewWithViews:@[index, copy]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 10;
    return row;
}

@interface SSWorkflowPrototypeApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation SSWorkflowPrototypeApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 390)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Silent Snip";
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.backgroundColor = [NSColor colorWithSRGBRed:0.125 green:0.125 blue:0.125 alpha:1];

    NSTextField *title = SSWelcomeLabel(@"Silent Snip", 20, NSFontWeightSemibold, NSColor.labelColor);
    NSTextField *subtitle = SSWelcomeLabel(@"Remove quiet pauses in Final Cut Pro.", 13, NSFontWeightRegular,
        NSColor.secondaryLabelColor);
    NSStackView *titleCopy = [NSStackView stackViewWithViews:@[title, subtitle]];
    titleCopy.orientation = NSUserInterfaceLayoutOrientationVertical;
    titleCopy.alignment = NSLayoutAttributeLeading;
    titleCopy.spacing = 4;
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil];
    NSImageView *icon = [NSImageView imageViewWithImage:[symbol imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:25 weight:NSFontWeightRegular]]];
    icon.contentTintColor = NSColor.secondaryLabelColor;
    icon.accessibilityElement = NO;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:32],
        [icon.heightAnchor constraintEqualToConstant:36]
    ]];
    NSStackView *header = [NSStackView stackViewWithViews:@[icon, titleCopy]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 12;

    NSTextField *openLabel = SSWelcomeLabel(@"Open the Workflow Extension", 12, NSFontWeightMedium,
        NSColor.secondaryLabelColor);
    NSTextField *path = SSWelcomeLabel(@"Window → Extensions → Silent Snip", 13, NSFontWeightSemibold,
        NSColor.labelColor);
    NSStackView *opening = [NSStackView stackViewWithViews:@[openLabel, path]];
    opening.orientation = NSUserInterfaceLayoutOrientationVertical;
    opening.alignment = NSLayoutAttributeLeading;
    opening.spacing = 4;

    NSBox *separator = [NSBox new];
    separator.boxType = NSBoxSeparator;
    NSStackView *steps = [NSStackView stackViewWithViews:@[
        SSWelcomeStep(@"1", @"Select a Clip", @"Choose a clip in the Final Cut Pro timeline."),
        SSWelcomeStep(@"2", @"Analyze Audio", @"Review the proposed ranges and adjust your settings."),
        SSWelcomeStep(@"3", @"Apply Cuts", @"Create a cleaned project copy. Your original stays intact.")
    ]];
    steps.orientation = NSUserInterfaceLayoutOrientationVertical;
    steps.alignment = NSLayoutAttributeLeading;
    steps.spacing = 14;
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:NSApp action:@selector(terminate:)];
    done.bezelStyle = NSBezelStyleRounded;
    done.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done.widthAnchor constraintGreaterThanOrEqualToConstant:72].active = YES;
    NSView *spacer = [NSView new];
    NSStackView *actions = [NSStackView stackViewWithViews:@[spacer, done]];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actions.alignment = NSLayoutAttributeCenterY;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, opening, separator, steps, actions]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.window.contentView.bottomAnchor constant:-24],
        [separator.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [actions.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        SSWorkflowPrototypeApp *delegate = [SSWorkflowPrototypeApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
