// Draws the picture behind the icons in the Tynda disk image: the name as a dictionary entry,
// an arrow from the app to the Applications folder, and one line of instruction. Run by tools/make_dmg.sh.
//
//   make_dmg_background <out.png> <scale>
//
// The colours are the landing page's: near-black, warm ink, a quieter tone for the small print.
// Finder writes icon names in black in light mode and in white in dark mode, whatever the picture
// is, so in light mode the names under the icons cannot be seen here. The line at the bottom
// says what to do instead.

#import <Cocoa/Cocoa.h>

static const CGFloat kW = 640, kH = 360;   // the window, in points; keep in step with tools/dmg_settings.py

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: make_dmg_background <out.png> <scale>\n"); return 1; }
        int scale = atoi(argv[2]);
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:kW * scale pixelsHigh:kH * scale
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        rep.size = NSMakeSize(kW, kH);   // points, so the 2x picture is read as retina
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

        NSColor *ink = [NSColor colorWithSRGBRed:0xf4 / 255.0 green:0xf1 / 255.0 blue:0xea / 255.0 alpha:1];   // --ink
        NSColor *soft = [NSColor colorWithSRGBRed:0xa0 / 255.0 green:0x9c / 255.0 blue:0x93 / 255.0 alpha:1];  // --dim
        NSGradient *plate = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0x0b / 255.0 green:0x0b / 255.0 blue:0x0c / 255.0 alpha:1]    // --bg
                                                          endingColor:[NSColor colorWithSRGBRed:0x15 / 255.0 green:0x15 / 255.0 blue:0x17 / 255.0 alpha:1]];  // --panel
        [plate drawInRect:NSMakeRect(0, 0, kW, kH) angle:90];

        NSMutableParagraphStyle *center = [NSMutableParagraphStyle new];
        center.alignment = NSTextAlignmentCenter;

        // The name, the way a dictionary would put it. It sits at the top: a Finder with the path bar
        // or the tab bar switched on cuts the bottom of the picture off.
        NSMutableAttributedString *word = [[NSMutableAttributedString alloc] initWithString:@"Tyn·da" attributes:@{
            NSFontAttributeName: [NSFont fontWithName:@"Iowan Old Style Bold" size:30] ?: [NSFont boldSystemFontOfSize:30],
            NSForegroundColorAttributeName: ink, NSParagraphStyleAttributeName: center}];
        [word appendAttributedString:[[NSAttributedString alloc] initWithString:@"   /təŋˈdɑ/" attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:17],
            NSForegroundColorAttributeName: soft, NSParagraphStyleAttributeName: center}]];
        [word drawInRect:NSMakeRect(0, kH - 64, kW, 40)];
        [@"verb, imperative · Kazakh тыңда · “Listen.”" drawInRect:NSMakeRect(0, kH - 88, kW, 20) withAttributes:@{
            NSFontAttributeName: [NSFont fontWithName:@"Iowan Old Style Italic" size:14] ?: [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName: soft, NSParagraphStyleAttributeName: center}];

        [@"Drag Tynda into Applications, then open it there. It sets itself up." drawInRect:NSMakeRect(0, 30, kW, 20) withAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: ink, NSParagraphStyleAttributeName: center}];

        // The arrow sits between the two icons, level with their middles.
        const CGFloat y = kH - 170, x0 = 270, x1 = 370;
        NSBezierPath *arrow = [NSBezierPath bezierPath];
        [arrow moveToPoint:NSMakePoint(x0, y)];
        [arrow lineToPoint:NSMakePoint(x1, y)];
        [arrow moveToPoint:NSMakePoint(x1 - 16, y + 14)];
        [arrow lineToPoint:NSMakePoint(x1, y)];
        [arrow lineToPoint:NSMakePoint(x1 - 16, y - 14)];
        arrow.lineWidth = 5;
        arrow.lineCapStyle = NSLineCapStyleRound;
        arrow.lineJoinStyle = NSLineJoinStyleRound;
        [ink setStroke];
        [arrow stroke];

        [NSGraphicsContext restoreGraphicsState];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
    }
    return 0;
}
