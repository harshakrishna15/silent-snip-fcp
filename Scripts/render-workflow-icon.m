// Regenerate the code-drawn Workflow icon without opening an app or using fonts.
// xcrun clang -fobjc-arc -framework AppKit Scripts/render-workflow-icon.m -o /tmp/silentsnip-icon
// /tmp/silentsnip-icon WorkflowPrototype/Resources
#import <AppKit/AppKit.h>

static NSData *DrawIcon(NSInteger pixels, BOOL coloredBadge) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    // Keep the offscreen context in pixel coordinates. Retina scale is carried
    // by the standard iconset filenames rather than a second context transform.
    bitmap.size = NSMakeSize(pixels, pixels);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
    [[NSColor clearColor] setFill];
    NSRectFillUsingOperation(NSMakeRect(0, 0, pixels, pixels), NSCompositingOperationCopy);
    NSAffineTransform *scale = [NSAffineTransform transform];
    [scale scaleBy:(CGFloat)pixels / 32.0];
    [scale concat];

    if (coloredBadge) {
        NSBezierPath *badge = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2, 2, 28, 28)
            xRadius:7 yRadius:7];
        NSColor *bottom = [NSColor colorWithSRGBRed:0.075 green:0.714 blue:0.541 alpha:1];
        NSColor *top = [NSColor colorWithSRGBRed:0.255 green:0.871 blue:0.706 alpha:1];
        [[[NSGradient alloc] initWithStartingColor:bottom endingColor:top]
            drawInBezierPath:badge angle:90];
        [[NSColor colorWithWhite:1 alpha:0.16] setStroke];
        NSBezierPath *edge = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2.5, 2.5, 27, 27)
            xRadius:6.5 yRadius:6.5];
        edge.lineWidth = 0.5;
        [edge stroke];
    }

    // Two short waveforms meet across a clear cut. The rounded bars remain
    // distinct at the official SDK template's 32 pt / 64 px toolbar sizes.
    const CGFloat badgeCenters[] = {6.8, 10.1, 13.4, 18.6, 21.9, 25.2};
    const CGFloat badgeHeights[] = {7, 15, 11, 11, 15, 7};
    const CGFloat toolbarCenters[] = {4, 8, 12, 20, 24, 28};
    const CGFloat toolbarHeights[] = {10, 22, 16, 16, 22, 10};
    const CGFloat *centers = coloredBadge ? badgeCenters : toolbarCenters;
    const CGFloat *heights = coloredBadge ? badgeHeights : toolbarHeights;
    CGFloat width = coloredBadge ? 2.4 : 2.8;
    [[NSColor colorWithWhite:1 alpha:coloredBadge ? 0.98 : 1] setFill];
    for (NSUInteger index = 0; index < 6; ++index) {
        NSRect bar = NSMakeRect(centers[index] - width / 2, 16 - heights[index] / 2,
                               width, heights[index]);
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:width / 2 yRadius:width / 2] fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: render-workflow-icon RESOURCE_DIRECTORY\n");
            return 2;
        }
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *output = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        NSError *error;
        if (![files createDirectoryAtURL:output withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
        }
        NSArray<NSNumber *> *sizes = @[@16, @32, @128, @256, @512];
        BOOL success = YES;
        for (NSString *stem in @[@"ExtensionIcon", @"WorkflowBadge"]) {
        BOOL coloredBadge = [stem isEqualToString:@"WorkflowBadge"];
        NSURL *temporary = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".iconset"] isDirectory:YES];
        if (![files createDirectoryAtURL:temporary withIntermediateDirectories:NO attributes:nil error:&error]) return 1;
        for (NSNumber *size in sizes) {
            for (NSInteger density = 1; density <= 2; ++density) {
                NSInteger points = size.integerValue, pixels = points * density;
                NSString *name = [NSString stringWithFormat:@"icon_%ldx%ld%@.png",
                    (long)points, (long)points, density == 2 ? @"@2x" : @""];
                NSData *data = DrawIcon(pixels, coloredBadge);
                if (![data writeToURL:[temporary URLByAppendingPathComponent:name]
                    options:NSDataWritingAtomic error:&error]) { success = NO; break; }
                if (points == 32) {
                    NSString *resource = [stem stringByAppendingString:density == 1 ? @".png" : @"@2x.png"];
                    if (![data writeToURL:[output URLByAppendingPathComponent:resource]
                        options:NSDataWritingAtomic error:&error]) { success = NO; break; }
                }
            }
            if (!success) break;
        }
        if (success) {
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/iconutil"];
            task.arguments = @[@"-c", @"icns", temporary.path, @"-o",
                [output URLByAppendingPathComponent:[stem stringByAppendingString:@".icns"]].path];
            success = [task launchAndReturnError:&error];
            if (success) { [task waitUntilExit]; success = task.terminationStatus == 0; }
        }
        [files removeItemAtURL:temporary error:nil];
        if (!success) break;
        }
        if (!success) {
            fprintf(stderr, "Icon generation failed: %s\n", error.localizedDescription.UTF8String ?: "iconutil error");
            return 1;
        }
        printf("Generated split-waveform icon in %s\n", output.path.UTF8String);
    }
    return 0;
}
