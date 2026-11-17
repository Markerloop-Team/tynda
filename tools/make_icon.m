// Draws the Tynda mark — five bars of a voice waveform — and writes every image the
// project needs. Run it with tools/make_icon.sh after changing the design.
//
//   make_icon <iconset dir> <docs dir>

#import <Cocoa/Cocoa.h>

static const CGFloat kHeights[5] = {0.30, 0.62, 1.00, 0.48, 0.22};  // the waveform, tallest in the middle

static NSColor *RGB(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

// Bars centred in `box`; the tallest one fills the box height.
static void DrawBars(NSRect box, NSColor *color, NSColor *accent) {
    CGFloat slot = box.size.width / 5, barW = slot * 0.56;
    for (int i = 0; i < 5; i++) {
        CGFloat h = MAX(barW, box.size.height * kHeights[i]);
        NSRect r = NSMakeRect(box.origin.x + slot * i + (slot - barW) / 2, NSMidY(box) - h / 2, barW, h);
        [(i == 2 && accent ? accent : color) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:r xRadius:barW / 2 yRadius:barW / 2] fill];
    }
}

static void WritePNG(NSString *path, int px, void (^draw)(CGFloat size)) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    draw(px);
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// The app icon: a near-black rounded square on Apple's icon grid, cream bars, one brass.
static void DrawAppIcon(CGFloat s) {
    CGFloat inset = s * 100 / 1024, side = s - inset * 2, radius = side * 0.2237;
    NSRect plate = NSMakeRect(inset, inset, side, side);
    NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:radius yRadius:radius];
    NSGradient *bg = [[NSGradient alloc] initWithStartingColor:RGB(0x232326) endingColor:RGB(0x09090a)];
    [bg drawInBezierPath:shape angle:-90];
    [[NSColor colorWithWhite:1 alpha:0.10] setStroke];
    shape.lineWidth = MAX(1, s / 512);
    [shape stroke];
    DrawBars(NSInsetRect(plate, side * 0.20, side * 0.25), RGB(0xf4f1ea), RGB(0xd9a441));
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: make_icon <iconset dir> <docs dir>\n"); return 1; }
        NSString *iconset = @(argv[1]), *docs = @(argv[2]);
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            int n = sizes[i];
            WritePNG([iconset stringByAppendingFormat:@"/icon_%dx%d.png", n, n], n, ^(CGFloat s) { DrawAppIcon(s); });
            WritePNG([iconset stringByAppendingFormat:@"/icon_%dx%d@2x.png", n, n], n * 2, ^(CGFloat s) { DrawAppIcon(s); });
        }
        WritePNG([docs stringByAppendingString:@"/icon.png"], 512, ^(CGFloat s) { DrawAppIcon(s); });
        WritePNG([docs stringByAppendingString:@"/favicon.png"], 64, ^(CGFloat s) { DrawAppIcon(s); });
    }
    return 0;
}
