#import <AppKit/AppKit.h>

@interface SSWorkflowPrototypeApp : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation SSWorkflowPrototypeApp
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 210)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Silent Snip Workflow Prototype";
    NSTextField *title = [NSTextField labelWithString:@"Ready to open in Final Cut Pro"];
    title.font = [NSFont boldSystemFontOfSize:19];
    NSTextField *detail = [NSTextField wrappingLabelWithString:
        @"Choose Silent Snip Workflow Prototype from Final Cut Pro’s Extensions menu.\n\nSelect a timeline clip, Analyze its audio, review the pauses, then Apply to create a cleaned project copy. Keep the updated Silent Snip app installed for processing."];
    NSButton *done = [NSButton buttonWithTitle:@"Done" target:NSApp action:@selector(terminate:)];
    NSStackView *stack = [NSStackView stackViewWithViews:@[title, detail, done]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:24]
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
