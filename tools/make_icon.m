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

// The wave: a sawtooth (up-stroke, straight drop, up-stroke…) whose teeth grow and fade like a spoken word.
static NSBezierPath *Wave(CGFloat cx, CGFloat cy, CGFloat scale) {
    static const CGFloat amps[5] = {95, 210, 300, 170, 80};
    const CGFloat step = 112.8, width = 5 * step;
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:NSMakePoint(cx - width / 2 * scale, cy + amps[0] / 2 * scale)];
    for (int i = 0; i < 5; i++) {
        CGFloat x = cx + ((i + 1) * step - width / 2) * scale;
        [p lineToPoint:NSMakePoint(x, cy - amps[i] / 2 * scale)];
        if (i < 4) [p lineToPoint:NSMakePoint(x, cy + amps[i + 1] / 2 * scale)];
    }
    p.lineWidth = 60 * scale;
    p.lineJoinStyle = NSLineJoinStyleRound;
    p.lineCapStyle = NSLineCapStyleButt;
    return p;
}

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
    NSBezierPath *tail = [NSBezierPath bezierPath];  // the bubble's tail, with softened corners
    [tail moveToPoint:NSMakePoint(326, 646)];
    [tail lineToPoint:NSMakePoint(294, 798)];
    [tail lineToPoint:NSMakePoint(476, 656)];
    [tail closePath];
    tail.lineWidth = 36;
    tail.lineJoinStyle = NSLineJoinStyleRound;
    [tail fill];
    [tail stroke];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(176, 262, 672, 424) xRadius:170 yRadius:170] fill];

    [NSColor.whiteColor setStroke];
    [Wave(512, 474, 0.80) stroke];
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
