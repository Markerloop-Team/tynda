// Draws the Tynda icon — a voice wave inside a speech bubble — and writes every image the
// project needs. Run it with tools/make_icon.sh after changing the design.
//
//   make_icon <iconset dir> <docs dir>
//
// All coordinates below are on a 1024×1024 canvas with the origin at the top left.

#import <Cocoa/Cocoa.h>

static NSColor *RGB(int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0 green:((hex >> 8) & 255) / 255.0 blue:(hex & 255) / 255.0 alpha:1];
}

// The mark is defined once, on the 22×18 grid of the menu bar image in Sources/main.m:
// a bubble 20×12.6 with radius 5.4, a tail at the lower left, and a four-tooth wave cut through it.
// Here the same grid is blown up to the icon plate, so the icon and the menu bar mark have one shape.
static const CGFloat kUnit = 33.6;                 // one grid point on the 1024 canvas (bubble = 672 wide)
static const CGFloat kOriginX = 512 - 11 * kUnit;  // grid x 11 is the middle of the bubble
static const CGFloat kOriginY = 512 - 9.15 * kUnit; // grid y 9.15 is the middle of bubble + tail
static NSPoint G(CGFloat x, CGFloat y) { return NSMakePoint(kOriginX + x * kUnit, kOriginY + y * kUnit); }

static void DrawIcon(CGFloat s) {
    NSAffineTransform *t = [NSAffineTransform transform];  // 1024-canvas, y down → pixels, y up
    [t translateXBy:0 yBy:s];
    [t scaleXBy:s / 1024 yBy:-s / 1024];
    [t concat];

    [RGB(0xE5332A) setFill];  // red plate on Apple's icon grid
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(100, 100, 824, 824) xRadius:184 yRadius:184] fill];

    NSColor *black = RGB(0x0B0B0C);
    [black setFill];
    [black setStroke];
    NSBezierPath *tail = [NSBezierPath bezierPath];
    [tail moveToPoint:G(5.6, 12.0)];
    [tail lineToPoint:G(4.7, 16.6)];
    [tail lineToPoint:G(10.4, 12.6)];
    [tail closePath];
    tail.lineWidth = 1.0 * kUnit;
    tail.lineJoinStyle = NSLineJoinStyleRound;
    [tail fill];
    [tail stroke];
    NSPoint o = G(1, 1.2);
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(o.x, o.y, 20 * kUnit, 12.6 * kUnit) xRadius:5.4 * kUnit yRadius:5.4 * kUnit] fill];

    static const CGFloat amps[4] = {3.0, 6.6, 7.0, 3.4};
    const CGFloat step = 3.2, left = 11 - 4 * step / 2, mid = 7.5;
    NSBezierPath *wave = [NSBezierPath bezierPath];
    [wave moveToPoint:G(left, mid + amps[0] / 2)];
    for (int i = 0; i < 4; i++) {
        CGFloat x = left + (i + 1) * step;
        [wave lineToPoint:G(x, mid - amps[i] / 2)];
        if (i < 3) [wave lineToPoint:G(x, mid + amps[i + 1] / 2)];
    }
    wave.lineWidth = 1.3 * kUnit;
    wave.lineJoinStyle = NSLineJoinStyleRound;
    wave.lineCapStyle = NSLineCapStyleRound;
    [NSColor.whiteColor setStroke];
    [wave stroke];
}

static void WritePNG(NSString *path, int px) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    DrawIcon(px);
    [NSGraphicsContext restoreGraphicsState];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: make_icon <iconset dir> <docs dir>\n"); return 1; }
        NSString *iconset = @(argv[1]), *docs = @(argv[2]);
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            int n = sizes[i];
            WritePNG([iconset stringByAppendingFormat:@"/icon_%dx%d.png", n, n], n);
            WritePNG([iconset stringByAppendingFormat:@"/icon_%dx%d@2x.png", n, n], n * 2);
        }
        WritePNG([docs stringByAppendingString:@"/icon.png"], 512);
        WritePNG([docs stringByAppendingString:@"/favicon.png"], 64);
    }
    return 0;
}
