// The visible part of Tynda: the glass panel that drops from the menu bar and the Library window.
// Included into main.m (one translation unit), so it can use L(), NotesDir(), Log() and friends.

#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>

typedef NS_ENUM(NSInteger, LibrarySection) { SecDictations, SecMeetings, SecSettings };

// What the UI needs from the app.
@protocol TyndaActions <NSObject>
- (void)toggle;  // start / stop a meeting recording
- (BOOL)isRecordingMeeting;
- (NSDate *)meetingStartedAt;
- (BOOL)isProcessingMeeting;
- (BOOL)dictationEnabled;
- (void)toggleDictation;
- (BOOL)engineReady;
- (BOOL)fnListening;
- (void)showOnboarding;
- (void)showLibrary:(LibrarySection)section;
- (void)showLibraryMeeting:(NSString *)folder;
@end

#pragma mark - Small building blocks

static NSColor *Wh(CGFloat a) { return [NSColor colorWithWhite:1 alpha:a]; }
static NSColor *TyndaRed(void) { return [NSColor colorWithSRGBRed:0.898 green:0.200 blue:0.165 alpha:1]; }

static NSTextField *Lbl(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *f = [NSTextField labelWithString:text ?: @""];
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = color;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    return f;
}

static NSTextField *WrapLbl(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color, NSInteger maxLines) {
    NSTextField *f = [NSTextField wrappingLabelWithString:text ?: @""];
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = color;
    f.selectable = NO;
    f.maximumNumberOfLines = maxLines;
    f.cell.truncatesLastVisibleLine = YES;
    return f;
}

static CGFloat TextHeight(NSString *text, NSFont *font, CGFloat width) {
    NSRect r = [text boundingRectWithSize:NSMakeSize(width, 10000)
                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                               attributes:@{NSFontAttributeName: font}];
    return ceil(r.size.height);
}

// A view with its origin at the top left, like a page.
@interface Flip : NSView
@end
@implementation Flip
- (BOOL)isFlipped { return YES; }
@end

// A rounded, tinted surface. With onClick it behaves like a button and lights up under the pointer.
@interface Card : Flip
@property(nonatomic) CGFloat radius;
@property(nonatomic, strong) NSColor *fill, *hoverFill, *stroke;
@property(nonatomic, copy) void (^onClick)(void);
@end
@implementation Card {
    BOOL _hover;
    NSTrackingArea *_area;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.wantsLayer = YES;
    return self;
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    NSColor *c = (_hover && self.onClick) ? (self.hoverFill ?: self.fill) : self.fill;
    self.layer.backgroundColor = c.CGColor;
    self.layer.cornerRadius = self.radius;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.borderWidth = self.stroke ? 1 : 0;
    self.layer.borderColor = self.stroke.CGColor;
}
- (void)setFill:(NSColor *)fill { _fill = fill; self.needsDisplay = YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_area) [self removeTrackingArea:_area];
    _area = [[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways owner:self userInfo:nil];
    [self addTrackingArea:_area];
}
- (void)mouseEntered:(NSEvent *)e { _hover = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { _hover = NO; self.needsDisplay = YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e { if (!self.onClick) [super mouseDown:e]; }
- (void)mouseUp:(NSEvent *)e {
    if (self.onClick && NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds)) self.onClick();
    else [super mouseUp:e];
}
@end

static Card *MakeCard(NSRect frame, CGFloat radius, NSColor *fill, NSColor *stroke) {
    Card *c = [[Card alloc] initWithFrame:frame];
    c.radius = radius;
    c.fill = fill;
    c.stroke = stroke;
    return c;
}

// A capsule button: red for the one main action, translucent for the rest.
static Card *Pill(NSRect frame, NSString *title, BOOL red, BOOL dot, void (^handler)(void)) {
    Card *c = MakeCard(frame, frame.size.height / 2,
                       red ? TyndaRed() : Wh(0.14), red ? Wh(0.30) : Wh(0.22));
    c.hoverFill = red ? [NSColor colorWithSRGBRed:1 green:0.33 blue:0.29 alpha:1] : Wh(0.22);
    c.onClick = handler;
    NSTextField *t = Lbl(dot ? [@"●  " stringByAppendingString:title] : title, 13, NSFontWeightSemibold, NSColor.whiteColor);
    t.alignment = NSTextAlignmentCenter;
    t.frame = NSMakeRect(8, (frame.size.height - 18) / 2, frame.size.width - 16, 18);
    [c addSubview:t];
    return c;
}

// Liquid Glass on macOS 26; an ordinary blur on older systems.
static NSView *Glass(NSView *content, CGFloat radius, NSColor *tint) {
    Class cls = NSClassFromString(@"NSGlassEffectView");
    if (cls && [cls instancesRespondToSelector:NSSelectorFromString(@"setContentView:")]) {
        NSView *g = [[cls alloc] initWithFrame:content.frame];
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [g setValue:content forKey:@"contentView"];
        [g setValue:@(radius) forKey:@"cornerRadius"];
        if (tint) [g setValue:tint forKey:@"tintColor"];
        return g;
    }
    NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:content.frame];
    v.material = NSVisualEffectMaterialHUDWindow;
    v.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    v.state = NSVisualEffectStateActive;
    v.wantsLayer = YES;
    v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.masksToBounds = YES;
    v.layer.borderWidth = 1;
    v.layer.borderColor = Wh(0.18).CGColor;
    content.frame = v.bounds;
    content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [v addSubview:content];
    return v;
}

// A still waveform, for decoration.
@interface WaveView : NSView
@property(nonatomic, strong) NSColor *color;
@end
@implementation WaveView
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    CGFloat barW = 2.5, gap = 2.5;
    NSInteger n = (NSInteger)((b.size.width + gap) / (barW + gap));
    [(self.color ?: NSColor.whiteColor) setFill];
    for (NSInteger i = 0; i < n; i++) {
        double v = fabs(sin(i * 0.9 + 2) * 0.55 + sin(i * 0.31 + 4) * 0.45);
        v = 0.12 + 0.88 * v * (0.35 + 0.65 * sin(M_PI * (i + 1) / (n + 1)));
        CGFloat h = MAX(3, v * b.size.height);
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(i * (barW + gap), (b.size.height - h) / 2, barW, h) xRadius:barW / 2 yRadius:barW / 2] fill];
    }
}
@end

#pragma mark - What is on disk

static NSString *ReadText(NSURL *url) { return [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] ?: @""; }

// Newest first. Each: date (yyyy-MM-dd), time (HH:mm), text.
static NSArray<NSDictionary *> *LoadDictations(void) {
    NSMutableArray *out = [NSMutableArray new];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^- (\\d{4}-\\d{2}-\\d{2}) (\\d{2}:\\d{2}) — (.*)$" options:0 error:nil];
    for (NSString *line in [ReadText([NotesDir() URLByAppendingPathComponent:@"dictation.md"]) componentsSeparatedByString:@"\n"]) {
        NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (!m) continue;
        [out insertObject:@{@"date": [line substringWithRange:[m rangeAtIndex:1]],
                            @"time": [line substringWithRange:[m rangeAtIndex:2]],
                            @"text": [line substringWithRange:[m rangeAtIndex:3]]} atIndex:0];
    }
    return out;
}

static NSString *StripMarkdown(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"**" withString:@""];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Newest first. Each: folder, date, time, title, summary, minutes, note, transcript.
static NSArray<NSDictionary *> *LoadMeetings(void) {
    NSMutableArray *out = [NSMutableArray new];
    NSArray<NSString *> *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:NotesDir().path error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"^(\\d{4}-\\d{2}-\\d{2})_(\\d{2})-(\\d{2})" options:0 error:nil];
    for (NSString *name in names.reverseObjectEnumerator) {
        NSTextCheckingResult *m = [re firstMatchInString:name options:0 range:NSMakeRange(0, name.length)];
        if (!m) continue;
        NSURL *dir = [NotesDir() URLByAppendingPathComponent:name];
        NSString *note = ReadText([dir URLByAppendingPathComponent:@"note.md"]);
        NSString *transcript = ReadText([dir URLByAppendingPathComponent:@"transcript.md"]);
        NSString *time = [NSString stringWithFormat:@"%@:%@", [name substringWithRange:[m rangeAtIndex:2]], [name substringWithRange:[m rangeAtIndex:3]]];

        NSString *title = nil, *summary = nil;
        for (NSString *raw in [note componentsSeparatedByString:@"\n"]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length == 0 || [line hasPrefix:@"---"]) continue;
            if ([line hasPrefix:@"# "] && !title) { title = [line substringFromIndex:2]; continue; }
            if ([line hasPrefix:@"#"]) continue;
            if (!summary) { summary = StripMarkdown(line); break; }
        }
        if (!summary) {
            for (NSString *raw in [transcript componentsSeparatedByString:@"\n"]) {
                if (raw.length == 0 || [raw hasPrefix:@"#"]) continue;
                summary = StripMarkdown(raw);
                break;
            }
        }
        if (!title) title = [NSString stringWithFormat:@"%@ %@", L(@"Meeting at", @"Встреча в"), time];
        if (!summary) summary = L(@"Transcribing…", @"Расшифровывается…");

        NSDictionary *meta = nil;
        NSData *metaData = [NSData dataWithContentsOfURL:[dir URLByAppendingPathComponent:@"meta.json"]];
        if (metaData) meta = [NSJSONSerialization JSONObjectWithData:metaData options:0 error:nil];
        NSInteger minutes = MAX(1, (NSInteger)round([meta[@"duration_sec"] doubleValue] / 60));

        [out addObject:@{@"folder": name, @"date": [name substringWithRange:[m rangeAtIndex:1]], @"time": time,
                         @"title": title, @"summary": summary, @"minutes": @(minutes),
                         @"note": note, @"transcript": transcript}];
    }
    return out;
}

// "2026-11-18" → Today / Yesterday / Tue 18 Nov
static NSString *DayLabel(NSString *ymd) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd";
    NSDate *d = [f dateFromString:ymd];
    if (!d) return ymd;
    if ([NSCalendar.currentCalendar isDateInToday:d]) return L(@"TODAY", @"СЕГОДНЯ");
    if ([NSCalendar.currentCalendar isDateInYesterday:d]) return L(@"YESTERDAY", @"ВЧЕРА");
    f.dateFormat = @"EEE d MMM";
    return [f stringFromDate:d].uppercaseString;
}

static NSString *MinutesText(NSInteger m) { return [NSString stringWithFormat:L(@"%ld min", @"%ld мин"), (long)m]; }

// A small Markdown reader for notes and transcripts: #, ##, bullets and **bold**.
static NSAttributedString *RenderNote(NSString *md) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSRegularExpression *bold = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.+?)\\*\\*" options:0 error:nil];
    for (NSString *raw in [md componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line hasPrefix:@"---"] || [line hasPrefix:@"[Transcript]"] || [line hasPrefix:@"[Полная"]) continue;
        NSFont *font = [NSFont systemFontOfSize:14];
        NSColor *color = Wh(0.86);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineSpacing = 3;
        ps.paragraphSpacing = 7;
        if ([line hasPrefix:@"# "]) {
            line = [line substringFromIndex:2];
            font = [NSFont systemFontOfSize:23 weight:NSFontWeightBold];
            color = NSColor.whiteColor;
            ps.paragraphSpacing = 10;
        } else if ([line hasPrefix:@"## "]) {
            line = [line substringFromIndex:3].uppercaseString;
            font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            color = Wh(0.45);
            ps.paragraphSpacingBefore = 14;
            ps.paragraphSpacing = 6;
        } else if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "]) {
            line = [@"•  " stringByAppendingString:[line substringFromIndex:2]];
            ps.headIndent = 16;
            ps.paragraphSpacing = 4;
        } else if (line.length == 0) {
            continue;
        }
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:[line stringByAppendingString:@"\n"]
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color, NSParagraphStyleAttributeName: ps}];
        // **bold** → bold white, markers removed (from the end, so ranges stay valid)
        NSArray<NSTextCheckingResult *> *ms = [bold matchesInString:a.string options:0 range:NSMakeRange(0, a.length)];
        for (NSTextCheckingResult *m in ms.reverseObjectEnumerator) {
            NSString *inner = [a.string substringWithRange:[m rangeAtIndex:1]];
            NSAttributedString *b = [[NSAttributedString alloc] initWithString:inner attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold],
                NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: ps}];
            [a replaceCharactersInRange:m.range withAttributedString:b];
        }
        [out appendAttributedString:a];
    }
    return out;
}

static void CopyToClipboard(NSString *text) {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
}

#pragma mark - The panel under the menu bar icon

@interface KeyPanel : NSPanel
@end
@implementation KeyPanel
- (BOOL)canBecomeKeyWindow { return YES; }
@end

@interface TyndaPopover : NSObject
- (instancetype)initWithActions:(id<TyndaActions>)actions;
- (void)toggleBelow:(NSView *)anchor;
- (void)refresh;
- (void)close;
@property(nonatomic, readonly) BOOL visible;
@end

@implementation TyndaPopover {
    __weak id<TyndaActions> _actions;
    KeyPanel *_panel;
    Flip *_root;
    id _monitor;
    NSTextField *_heroTitle, *_heroSub;
    Card *_recordPill;
    BOOL _wasRecording, _wasProcessing;
}

static const CGFloat kPopW = 430, kPopPad = 18;

- (instancetype)initWithActions:(id<TyndaActions>)actions {
    if ((self = [super init])) _actions = actions;
    return self;
}

- (BOOL)visible { return _panel.isVisible; }

- (void)section:(NSString *)title at:(CGFloat *)y {
    NSTextField *cap = Lbl(title, 11, NSFontWeightSemibold, Wh(0.45));
    cap.frame = NSMakeRect(kPopPad + 12, *y, 300, 14);
    [_root addSubview:cap];
    *y += 14 + 6;
}

- (void)emptyRow:(NSString *)text at:(CGFloat *)y {
    NSTextField *t = Lbl(text, 13, NSFontWeightRegular, Wh(0.5));
    t.frame = NSMakeRect(kPopPad + 12, *y + 6, kPopW - 2 * kPopPad - 24, 18);
    [_root addSubview:t];
    *y += 34;
}

// Rebuilds the whole content; returns its height.
- (CGFloat)build {
    for (NSView *v in _root.subviews.copy) [v removeFromSuperview];
    CGFloat inner = kPopW - 2 * kPopPad, y = kPopPad;
    __weak TyndaPopover *weakSelf = self;
    id<TyndaActions> actions = _actions;

    // Hero: what Tynda is doing right now.
    Card *hero = MakeCard(NSMakeRect(kPopPad, y, inner, 128), 22, Wh(0.10), Wh(0.20));
    WaveView *wave = [[WaveView alloc] initWithFrame:NSMakeRect((inner - 270) / 2, 20, 270, 34)];
    [hero addSubview:wave];
    _heroTitle = Lbl(@"", 18, NSFontWeightBold, NSColor.whiteColor);
    _heroTitle.alignment = NSTextAlignmentCenter;
    _heroTitle.frame = NSMakeRect(10, 66, inner - 20, 24);
    [hero addSubview:_heroTitle];
    _heroSub = Lbl(@"", 13, NSFontWeightRegular, Wh(0.6));
    _heroSub.alignment = NSTextAlignmentCenter;
    _heroSub.frame = NSMakeRect(10, 92, inner - 20, 18);
    [hero addSubview:_heroSub];
    [_root addSubview:hero];
    y += 128 + 12;

    CGFloat half = (inner - 10) / 2;
    BOOL recording = [actions isRecordingMeeting];
    _recordPill = Pill(NSMakeRect(kPopPad, y, half, 44), recording ? L(@"Stop and transcribe", @"Остановить") : L(@"Record meeting", @"Записать встречу"), YES, !recording, ^{
        [actions toggle];
    });
    [_root addSubview:_recordPill];
    [_root addSubview:Pill(NSMakeRect(kPopPad + half + 10, y, half, 44), L(@"Open notes", @"Открыть заметки"), NO, NO, ^{
        [weakSelf close];
        [actions showLibrary:SecMeetings];
    })];
    y += 44 + 18;

    [self section:L(@"RECENT DICTATIONS", @"ПОСЛЕДНИЕ ДИКТОВКИ") at:&y];
    NSArray<NSDictionary *> *dictations = LoadDictations();
    if (dictations.count == 0) [self emptyRow:L(@"Nothing yet — hold fn and say something", @"Пока пусто — удерживай fn и скажи что-нибудь") at:&y];
    for (NSUInteger i = 0; i < MIN(dictations.count, 3); i++) {
        NSDictionary *d = dictations[i];
        Card *row = MakeCard(NSMakeRect(kPopPad, y, inner, 48), 14, i % 2 == 0 ? Wh(0.07) : NSColor.clearColor, nil);
        row.hoverFill = Wh(0.16);
        NSTextField *time = Lbl(d[@"time"], 11, NSFontWeightSemibold, Wh(0.45));
        time.frame = NSMakeRect(12, 8, 40, 14);
        [row addSubview:time];
        NSTextField *text = WrapLbl(d[@"text"], 13, NSFontWeightRegular, Wh(0.92), 2);
        text.frame = NSMakeRect(56, 6, inner - 56 - 44, 36);
        [row addSubview:text];
        NSTextField *copy = Lbl(@"⧉", 15, NSFontWeightRegular, Wh(0.5));
        copy.alignment = NSTextAlignmentCenter;
        copy.frame = NSMakeRect(inner - 36, 13, 24, 20);
        [row addSubview:copy];
        NSString *full = d[@"text"];
        row.onClick = ^{
            CopyToClipboard(full);
            copy.stringValue = @"✓";
            copy.textColor = NSColor.systemGreenColor;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                copy.stringValue = @"⧉";
                copy.textColor = Wh(0.5);
            });
        };
        row.toolTip = L(@"Click to copy", @"Нажми, чтобы скопировать");
        [_root addSubview:row];
        y += 48 + 2;
    }
    y += 12;

    [self section:L(@"MEETINGS", @"ВСТРЕЧИ") at:&y];
    NSArray<NSDictionary *> *meetings = LoadMeetings();
    if (meetings.count == 0) [self emptyRow:L(@"No meetings recorded yet", @"Встреч пока нет") at:&y];
    for (NSUInteger i = 0; i < MIN(meetings.count, 2); i++) {
        NSDictionary *m = meetings[i];
        Card *row = MakeCard(NSMakeRect(kPopPad, y, inner, 48), 14, i % 2 == 0 ? Wh(0.07) : NSColor.clearColor, nil);
        row.hoverFill = Wh(0.16);
        NSTextField *time = Lbl(m[@"time"], 11, NSFontWeightSemibold, Wh(0.45));
        time.frame = NSMakeRect(12, 8, 40, 14);
        [row addSubview:time];
        NSTextField *title = Lbl(m[@"title"], 13, NSFontWeightSemibold, NSColor.whiteColor);
        title.frame = NSMakeRect(56, 6, inner - 56 - 16, 18);
        [row addSubview:title];
        NSTextField *sub = Lbl([NSString stringWithFormat:@"%@ · %@", MinutesText([m[@"minutes"] integerValue]), DayLabel(m[@"date"]).capitalizedString],
                               12, NSFontWeightRegular, Wh(0.55));
        sub.frame = NSMakeRect(56, 25, inner - 56 - 16, 16);
        [row addSubview:sub];
        NSString *folder = m[@"folder"];
        row.onClick = ^{
            [weakSelf close];
            [actions showLibraryMeeting:folder];
        };
        [_root addSubview:row];
        y += 48 + 2;
    }
    y += 14;

    // Footer: the rest of the app.
    Card *seg = MakeCard(NSMakeRect(kPopPad, y, inner, 38), 19, [NSColor colorWithWhite:0 alpha:0.22], Wh(0.14));
    NSArray *items = @[@[L(@"Library", @"Библиотека"), ^{ [weakSelf close]; [actions showLibrary:SecDictations]; }],
                       @[L(@"Settings", @"Настройки"), ^{ [weakSelf close]; [actions showLibrary:SecSettings]; }],
                       @[L(@"Quit", @"Выйти"), ^{ [NSApp terminate:nil]; }]];
    CGFloat segW = (inner - 8) / items.count;
    for (NSUInteger i = 0; i < items.count; i++) {
        Card *b = MakeCard(NSMakeRect(4 + i * segW, 4, segW, 30), 15, NSColor.clearColor, nil);
        b.hoverFill = Wh(0.20);
        b.onClick = items[i][1];
        NSTextField *t = Lbl(items[i][0], 13, NSFontWeightSemibold, Wh(0.85));
        t.alignment = NSTextAlignmentCenter;
        t.frame = NSMakeRect(0, 6, segW, 18);
        [b addSubview:t];
        [seg addSubview:b];
    }
    [_root addSubview:seg];
    y += 38 + kPopPad;

    [self updateHero];
    return y;
}

- (void)updateHero {
    id<TyndaActions> a = _actions;
    if ([a isRecordingMeeting]) {
        int s = (int)[[NSDate date] timeIntervalSinceDate:[a meetingStartedAt]];
        _heroTitle.stringValue = [NSString stringWithFormat:@"%@  %d:%02d", L(@"Recording", @"Идёт запись"), s / 60, s % 60];
        _heroSub.stringValue = L(@"Stop to get the transcript and the notes", @"Останови — получишь расшифровку и конспект");
    } else if ([a isProcessingMeeting]) {
        _heroTitle.stringValue = L(@"Transcribing the meeting…", @"Расшифровываю встречу…");
        _heroSub.stringValue = L(@"The notes will open when ready", @"Конспект откроется, когда будет готов");
    } else if (![a fnListening] || ![a engineReady]) {
        _heroTitle.stringValue = L(@"Almost ready", @"Почти готово");
        _heroSub.stringValue = L(@"Finish the setup in Settings", @"Заверши настройку в «Настройках»");
    } else if (![a dictationEnabled]) {
        _heroTitle.stringValue = L(@"Dictation is off", @"Диктовка выключена");
        _heroSub.stringValue = L(@"Turn it on in Settings", @"Включи её в «Настройках»");
    } else {
        _heroTitle.stringValue = L(@"Hold fn and speak", @"Удерживай fn и говори");
        _heroSub.stringValue = L(@"Double-tap for hands-free", @"Двойное нажатие — без удержания");
    }
}

- (void)refresh {
    if (!self.visible) return;
    id<TyndaActions> a = _actions;
    BOOL rec = [a isRecordingMeeting], proc = [a isProcessingMeeting];
    if (rec != _wasRecording || proc != _wasProcessing) {  // state changed: rebuild lists and the button
        _wasRecording = rec;
        _wasProcessing = proc;
        [self layoutKeepingTop];
    } else {
        [self updateHero];
    }
}

- (void)layoutKeepingTop {
    CGFloat h = [self build];
    NSRect f = _panel.frame;
    [_panel setFrame:NSMakeRect(f.origin.x, NSMaxY(f) - h, kPopW, h) display:YES];
}

- (void)toggleBelow:(NSView *)anchor {
    if (self.visible) { [self close]; return; }
    if (!_panel) {
        _panel = [[KeyPanel alloc] initWithContentRect:NSMakeRect(0, 0, kPopW, 560)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
        _panel.opaque = NO;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.hasShadow = YES;
        _panel.level = NSPopUpMenuWindowLevel;
        _panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
        _root = [[Flip alloc] initWithFrame:NSMakeRect(0, 0, kPopW, 560)];
        _panel.contentView = Glass(_root, 30, nil);
    }
    _wasRecording = [_actions isRecordingMeeting];
    _wasProcessing = [_actions isProcessingMeeting];
    CGFloat h = [self build];

    // Hang under the icon; if the icon has no room in the menu bar, use the top right corner.
    NSScreen *screen = anchor.window.screen ?: NSScreen.mainScreen;
    NSRect vis = screen.visibleFrame;
    NSRect a = anchor.window ? [anchor.window convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]] : NSZeroRect;
    CGFloat x = NSMaxX(vis) - kPopW - 12, top = NSMaxY(vis) - 6;
    if (anchor.window && NSIntersectsRect(a, screen.frame) && a.size.width > 0) {
        x = MIN(MAX(NSMidX(a) - kPopW + 70, NSMinX(vis) + 12), NSMaxX(vis) - kPopW - 12);
        top = NSMinY(a) - 6;
    }
    [_panel setFrame:NSMakeRect(x, top - h, kPopW, h) display:YES];
    [_panel makeKeyAndOrderFront:nil];

    __weak TyndaPopover *weakSelf = self;
    _monitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *e) {
        [weakSelf close];
    }];
}

- (void)close {
    if (_monitor) { [NSEvent removeMonitor:_monitor]; _monitor = nil; }
    [_panel orderOut:nil];
}
@end

#pragma mark - The Library window

@interface TyndaLibrary : NSObject <NSWindowDelegate, NSSearchFieldDelegate>
- (instancetype)initWithActions:(id<TyndaActions>)actions;
- (void)show:(LibrarySection)section;
- (void)showMeeting:(NSString *)folder;
- (void)refreshStatus;
- (void)reloadIfVisible;
@end

@implementation TyndaLibrary {
    __weak id<TyndaActions> _actions;
    NSWindow *_window;
    Flip *_root, *_main, *_side;
    LibrarySection _section;
    NSMutableArray<Card *> *_navCards;
    NSTextField *_statusFn, *_statusModel;
    Card *_recordPill;
    NSString *_query, *_selectedFolder;
    NSArray<NSDictionary *> *_meetings;
    BOOL _wasRecording, _wasProcessing;
}

static const CGFloat kLibW = 1120, kLibH = 720, kSideW = 226, kMainX = 250, kMainW = 844, kBodyY = 78, kBodyH = 620;

- (instancetype)initWithActions:(id<TyndaActions>)actions {
    if ((self = [super init])) { _actions = actions; _section = SecMeetings; }
    return self;
}

- (void)buildWindow {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kLibW, kLibH)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.titlebarAppearsTransparent = YES;
    _window.titleVisibility = NSWindowTitleHidden;
    _window.title = @"Tynda";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.movableByWindowBackground = YES;
    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _window.opaque = NO;
    _window.backgroundColor = NSColor.clearColor;

    // The window itself is dark, blurred glass; the sidebar is a lighter sheet of glass laid on it.
    NSVisualEffectView *base = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, kLibW, kLibH)];
    base.material = NSVisualEffectMaterialHUDWindow;
    base.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    base.state = NSVisualEffectStateActive;
    // A dark veil over the blur, so white text stays readable on any wallpaper.
    NSView *veil = [[NSView alloc] initWithFrame:base.bounds];
    veil.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    veil.wantsLayer = YES;
    veil.layer.backgroundColor = [NSColor colorWithWhite:0.04 alpha:0.46].CGColor;
    [base addSubview:veil];
    _root = [[Flip alloc] initWithFrame:base.bounds];
    _root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [base addSubview:_root];
    _window.contentView = base;

    _side = [[Flip alloc] initWithFrame:NSMakeRect(0, 0, kSideW, kLibH - 20)];
    NSView *sideGlass = Glass(_side, 20, nil);
    sideGlass.frame = NSMakeRect(10, 10, kSideW, kLibH - 20);
    [_root addSubview:sideGlass];

    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    icon.frame = NSMakeRect(14, 48, 34, 34);
    [_side addSubview:icon];
    NSTextField *brand = Lbl(@"Tynda", 18, NSFontWeightBold, NSColor.whiteColor);
    brand.frame = NSMakeRect(54, 54, 150, 24);
    [_side addSubview:brand];

    _navCards = [NSMutableArray new];
    NSArray<NSString *> *titles = @[L(@"Dictations", @"Диктовки"), L(@"Meetings", @"Встречи"), L(@"Settings", @"Настройки")];
    __weak TyndaLibrary *weakSelf = self;
    for (NSInteger i = 0; i < 3; i++) {
        Card *nav = MakeCard(NSMakeRect(12, 104 + i * 40, kSideW - 24, 36), 11, NSColor.clearColor, nil);
        nav.hoverFill = Wh(0.12);
        nav.onClick = ^{ [weakSelf show:(LibrarySection)i]; };
        NSTextField *t = Lbl(titles[i], 14, NSFontWeightMedium, Wh(0.85));
        t.frame = NSMakeRect(14, 8, 130, 20);
        t.tag = 1;
        [nav addSubview:t];
        NSTextField *count = Lbl(@"", 12, NSFontWeightRegular, Wh(0.5));
        count.alignment = NSTextAlignmentRight;
        count.frame = NSMakeRect(kSideW - 24 - 60, 9, 48, 18);
        count.tag = 2;
        [nav addSubview:count];
        [_side addSubview:nav];
        [_navCards addObject:nav];
    }

    Card *status = MakeCard(NSMakeRect(12, kLibH - 20 - 12 - 88, kSideW - 24, 88), 14, Wh(0.08), Wh(0.12));
    _statusFn = Lbl(@"", 12, NSFontWeightRegular, Wh(0.85));
    _statusFn.frame = NSMakeRect(12, 12, kSideW - 48, 16);
    [status addSubview:_statusFn];
    _statusModel = Lbl(@"", 12, NSFontWeightRegular, Wh(0.85));
    _statusModel.frame = NSMakeRect(12, 32, kSideW - 48, 16);
    [status addSubview:_statusModel];
    NSTextField *priv = Lbl(L(@"Everything stays on this Mac", @"Всё остаётся на этом Mac"), 11, NSFontWeightRegular, Wh(0.4));
    priv.frame = NSMakeRect(12, 58, kSideW - 48, 16);
    [status addSubview:priv];
    [_side addSubview:status];

    _main = [[Flip alloc] initWithFrame:NSMakeRect(0, 0, kLibW, kLibH)];
    [_root addSubview:_main positioned:NSWindowBelow relativeTo:sideGlass];
}

- (void)refreshStatus {
    if (!_window.isVisible) return;
    id<TyndaActions> a = _actions;
    BOOL fn = [a fnListening] && [a dictationEnabled], model = [a engineReady];
    _statusFn.stringValue = [NSString stringWithFormat:@"%@  %@", fn ? @"🟢" : @"🟠",
        fn ? L(@"fn is listening", @"fn слушается") : ([a dictationEnabled] ? L(@"fn needs access", @"fn ждёт доступа") : L(@"Dictation is off", @"Диктовка выключена"))];
    _statusModel.stringValue = [NSString stringWithFormat:@"%@  %@", model ? @"🟢" : @"🟠",
        model ? L(@"Speech model loaded", @"Модель речи загружена") : L(@"Speech model is loading", @"Модель речи загружается")];
    BOOL rec = [a isRecordingMeeting], proc = [a isProcessingMeeting];
    if (rec != _wasRecording || proc != _wasProcessing) {
        _wasRecording = rec;
        _wasProcessing = proc;
        [self rebuildMain];
    }
}

- (void)reloadIfVisible { if (_window.isVisible) [self rebuildMain]; }

- (NSScrollView *)scrollIn:(NSRect)frame document:(NSView *)doc {
    NSScrollView *s = [[NSScrollView alloc] initWithFrame:frame];
    s.drawsBackground = NO;
    s.hasVerticalScroller = YES;
    s.scrollerStyle = NSScrollerStyleOverlay;
    s.documentView = doc;
    return s;
}

- (void)rebuildMain {
    for (NSView *v in _main.subviews.copy) [v removeFromSuperview];
    __weak TyndaLibrary *weakSelf = self;
    id<TyndaActions> actions = _actions;
    NSArray<NSDictionary *> *dictations = LoadDictations();
    NSArray<NSDictionary *> *all = LoadMeetings();

    for (NSInteger i = 0; i < 3; i++) {
        Card *nav = _navCards[i];
        nav.fill = i == _section ? Wh(0.20) : NSColor.clearColor;
        ((NSTextField *)[nav viewWithTag:1]).textColor = i == _section ? NSColor.whiteColor : Wh(0.8);
        ((NSTextField *)[nav viewWithTag:2]).stringValue = i == SecDictations ? @(dictations.count).stringValue : (i == SecMeetings ? @(all.count).stringValue : @"");
    }

    NSArray<NSString *> *titles = @[L(@"Dictations", @"Диктовки"), L(@"Meetings", @"Встречи"), L(@"Settings", @"Настройки")];
    NSTextField *title = Lbl(titles[_section], 28, NSFontWeightBold, NSColor.whiteColor);
    title.frame = NSMakeRect(kMainX, 22, 320, 36);
    [_main addSubview:title];

    BOOL recording = [actions isRecordingMeeting];
    _recordPill = Pill(NSMakeRect(kMainX + kMainW - 190, 22, 190, 36), recording ? L(@"Stop and transcribe", @"Остановить") : L(@"Record meeting", @"Записать встречу"), YES, !recording, ^{
        [actions toggle];
    });
    [_main addSubview:_recordPill];

    if (_section == SecMeetings) {
        NSSearchField *search = [[NSSearchField alloc] initWithFrame:NSMakeRect(kMainX + kMainW - 190 - 12 - 280, 25, 280, 30)];
        search.placeholderString = L(@"Search notes and transcripts", @"Поиск по конспектам и расшифровкам");
        search.stringValue = _query ?: @"";
        search.target = self;
        search.action = @selector(searchChanged:);
        search.sendsSearchStringImmediately = YES;
        [_main addSubview:search];

        NSMutableArray *found = [NSMutableArray new];
        for (NSDictionary *m in all) {
            if (_query.length == 0 || [[NSString stringWithFormat:@"%@\n%@\n%@", m[@"title"], m[@"note"], m[@"transcript"]] rangeOfString:_query options:NSCaseInsensitiveSearch].location != NSNotFound) [found addObject:m];
        }
        _meetings = found;
        NSDictionary *selected = nil;
        for (NSDictionary *m in found) if ([m[@"folder"] isEqualToString:_selectedFolder]) selected = m;
        if (!selected) selected = found.firstObject;
        _selectedFolder = selected[@"folder"];

        if (found.count == 0) {
            NSTextField *empty = WrapLbl(all.count ? L(@"Nothing matches the search.", @"По запросу ничего не нашлось.")
                                                   : L(@"No meetings yet. Press “Record meeting” before your next call — Tynda records you and the other side, then writes the transcript and the notes.",
                                                       @"Встреч пока нет. Нажми «Записать встречу» перед следующим созвоном — Tynda запишет тебя и собеседников, а потом сделает расшифровку и конспект."),
                                         15, NSFontWeightRegular, Wh(0.6), 4);
            empty.frame = NSMakeRect(kMainX, kBodyY + 20, 520, 90);
            [_main addSubview:empty];
            return;
        }

        // The list on the left.
        CGFloat listW = 330, y = 0;
        Flip *doc = [[Flip alloc] initWithFrame:NSMakeRect(0, 0, listW, 10)];
        NSString *day = nil;
        for (NSDictionary *m in found) {
            if (![m[@"date"] isEqualToString:day]) {
                day = m[@"date"];
                NSTextField *cap = Lbl(DayLabel(day), 11, NSFontWeightSemibold, Wh(0.45));
                cap.frame = NSMakeRect(4, y + (y > 0 ? 8 : 0), 300, 14);
                [doc addSubview:cap];
                y += (y > 0 ? 8 : 0) + 14 + 8;
            }
            BOOL sel = [m[@"folder"] isEqualToString:_selectedFolder];
            Card *card = MakeCard(NSMakeRect(0, y, listW - 12, 84), 18, sel ? Wh(0.18) : Wh(0.07), sel ? Wh(0.30) : Wh(0.11));
            card.hoverFill = sel ? Wh(0.18) : Wh(0.12);
            NSTextField *t = Lbl(m[@"title"], 14, NSFontWeightSemibold, NSColor.whiteColor);
            t.frame = NSMakeRect(16, 12, listW - 12 - 32, 18);
            [card addSubview:t];
            NSTextField *s = Lbl(m[@"summary"], 13, NSFontWeightRegular, Wh(0.6));
            s.frame = NSMakeRect(16, 33, listW - 12 - 32, 18);
            [card addSubview:s];
            NSTextField *meta = Lbl([NSString stringWithFormat:@"%@ · %@", MinutesText([m[@"minutes"] integerValue]), m[@"time"]], 12, NSFontWeightRegular, Wh(0.5));
            meta.frame = NSMakeRect(16, 57, listW - 12 - 32, 16);
            [card addSubview:meta];
            NSString *folder = m[@"folder"];
            card.onClick = ^{ [weakSelf showMeeting:folder]; };
            [doc addSubview:card];
            y += 84 + 10;
        }
        doc.frame = NSMakeRect(0, 0, listW, MAX(y, kBodyH));
        [_main addSubview:[self scrollIn:NSMakeRect(kMainX, kBodyY, listW, kBodyH) document:doc]];

        // The note on the right.
        CGFloat dx = kMainX + listW + 14, dw = kMainW - listW - 14;
        Card *detail = MakeCard(NSMakeRect(dx, kBodyY, dw, kBodyH), 22, Wh(0.08), Wh(0.14));
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, dw, kBodyH)];
        tv.drawsBackground = NO;
        tv.editable = NO;
        tv.textContainerInset = NSMakeSize(22, 22);
        tv.autoresizingMask = NSViewWidthSizable;
        NSMutableAttributedString *text = [NSMutableAttributedString new];
        NSString *when = [NSString stringWithFormat:@"## %@ · %@ · %@\n", DayLabel(selected[@"date"]), selected[@"time"], MinutesText([selected[@"minutes"] integerValue])];
        [text appendAttributedString:RenderNote(when)];
        NSString *note = selected[@"note"], *transcript = selected[@"transcript"];
        if (note.length) {
            [text appendAttributedString:RenderNote(note)];
        } else {
            [text appendAttributedString:RenderNote([NSString stringWithFormat:@"# %@\n", selected[@"title"]])];
        }
        if (transcript.length) {
            // Drop the transcript's own "# folder name" heading.
            NSMutableArray *lines = [[transcript componentsSeparatedByString:@"\n"] mutableCopy];
            if ([lines.firstObject hasPrefix:@"# "]) [lines removeObjectAtIndex:0];
            [text appendAttributedString:RenderNote([NSString stringWithFormat:@"## %@\n%@", L(@"Transcript", @"Расшифровка"), [lines componentsJoinedByString:@"\n"]])];
        } else {
            [text appendAttributedString:RenderNote(L(@"The transcript is not ready yet.", @"Расшифровка ещё не готова."))];
        }
        [tv.textStorage setAttributedString:text];
        NSScrollView *sv = [self scrollIn:NSMakeRect(0, 0, dw, kBodyH) document:tv];
        [detail addSubview:sv];
        [_main addSubview:detail];
        return;
    }

    if (_section == SecDictations) {
        if (dictations.count == 0) {
            NSTextField *empty = WrapLbl(L(@"Nothing dictated yet. Put the cursor in any text field, hold fn and speak — everything you dictate is also kept here, in case a paste lands in the wrong place.",
                                           @"Пока ничего не надиктовано. Поставь курсор в любое поле, удерживай fn и говори — всё надиктованное дублируется здесь на случай, если вставка уйдёт не туда."),
                                         15, NSFontWeightRegular, Wh(0.6), 4);
            empty.frame = NSMakeRect(kMainX, kBodyY + 20, 560, 90);
            [_main addSubview:empty];
            return;
        }
        CGFloat y = 0, textW = kMainW - 12 - 76 - 56;
        NSFont *font = [NSFont systemFontOfSize:14];
        Flip *doc = [[Flip alloc] initWithFrame:NSMakeRect(0, 0, kMainW, 10)];
        NSString *day = nil;
        for (NSDictionary *d in dictations) {
            if (![d[@"date"] isEqualToString:day]) {
                day = d[@"date"];
                NSTextField *cap = Lbl(DayLabel(day), 11, NSFontWeightSemibold, Wh(0.45));
                cap.frame = NSMakeRect(4, y + (y > 0 ? 10 : 0), 300, 14);
                [doc addSubview:cap];
                y += (y > 0 ? 10 : 0) + 14 + 8;
            }
            CGFloat th = MIN(TextHeight(d[@"text"], font, textW), 400), h = th + 28;
            Card *card = MakeCard(NSMakeRect(0, y, kMainW - 12, h), 16, Wh(0.07), Wh(0.11));
            card.hoverFill = Wh(0.13);
            NSTextField *time = Lbl(d[@"time"], 12, NSFontWeightSemibold, Wh(0.45));
            time.frame = NSMakeRect(18, 15, 50, 16);
            [card addSubview:time];
            NSTextField *text = WrapLbl(d[@"text"], 14, NSFontWeightRegular, Wh(0.92), 0);
            text.frame = NSMakeRect(76, 13, textW, th + 2);
            [card addSubview:text];
            NSTextField *copy = Lbl(@"⧉", 16, NSFontWeightRegular, Wh(0.45));
            copy.alignment = NSTextAlignmentCenter;
            copy.frame = NSMakeRect(kMainW - 12 - 40, 12, 24, 22);
            [card addSubview:copy];
            NSString *full = d[@"text"];
            card.onClick = ^{
                CopyToClipboard(full);
                copy.stringValue = @"✓";
                copy.textColor = NSColor.systemGreenColor;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    copy.stringValue = @"⧉";
                    copy.textColor = Wh(0.45);
                });
            };
            card.toolTip = L(@"Click to copy", @"Нажми, чтобы скопировать");
            [doc addSubview:card];
            y += h + 8;
        }
        doc.frame = NSMakeRect(0, 0, kMainW, MAX(y, kBodyH));
        [_main addSubview:[self scrollIn:NSMakeRect(kMainX, kBodyY, kMainW, kBodyH) document:doc]];
        return;
    }

    // Settings
    CGFloat w = 640, rowH = 50;
    NSString *noteCommand = [NSUserDefaults.standardUserDefaults stringForKey:@"noteCommand"];
    BOOL claude = NO;
    for (NSString *p in @[@"~/.local/bin/claude", @"/opt/homebrew/bin/claude", @"/usr/local/bin/claude"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:p.stringByExpandingTildeInPath]) claude = YES;
    }
    NSString *notesBy = noteCommand.length ? noteCommand : (claude ? @"Claude Code" : L(@"Transcript only — no LLM found", @"Только расшифровка — модель не найдена"));
    NSArray *rows = @[
        @[L(@"Dictation with fn", @"Диктовка по fn"), @"switch:dictation"],
        @[L(@"Hands-free", @"Без удержания"), L(@"Double-tap fn · Esc cancels", @"Двойное нажатие fn · Esc — отмена")],
        @[L(@"Languages", @"Языки"), L(@"Russian · English · Kazakh", @"Русский · английский · казахский")],
        @[L(@"Meeting notes by", @"Конспект встреч пишет"), notesBy],
        @[L(@"Launch at login", @"Запускать при входе"), @"switch:login"],
        @[L(@"Recordings folder", @"Папка с записями"), @"button:folder"],
        @[L(@"Permissions and first-run setup", @"Разрешения и первая настройка"), @"button:setup"],
    ];
    Card *card = MakeCard(NSMakeRect(kMainX, kBodyY, w, rows.count * rowH + 46), 22, Wh(0.08), Wh(0.14));
    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = i * rowH;
        if (i > 0) {
            NSView *line = [[NSView alloc] initWithFrame:NSMakeRect(22, y, w - 44, 1)];
            line.wantsLayer = YES;
            line.layer.backgroundColor = Wh(0.12).CGColor;
            [card addSubview:line];
        }
        NSTextField *name = Lbl(rows[i][0], 14, NSFontWeightMedium, NSColor.whiteColor);
        name.frame = NSMakeRect(22, y + 15, 280, 20);
        [card addSubview:name];
        NSString *value = rows[i][1];
        if ([value hasPrefix:@"switch:"]) {
            NSSwitch *sw = [[NSSwitch alloc] initWithFrame:NSMakeRect(w - 22 - 42, y + 13, 42, 24)];
            BOOL login = [value hasSuffix:@"login"];
            BOOL on = login ? SMAppService.mainAppService.status == SMAppServiceStatusEnabled : [actions dictationEnabled];
            sw.state = on ? NSControlStateValueOn : NSControlStateValueOff;
            sw.target = self;
            sw.action = login ? @selector(loginSwitched:) : @selector(dictationSwitched:);
            [card addSubview:sw];
        } else if ([value hasPrefix:@"button:"]) {
            BOOL folder = [value hasSuffix:@"folder"];
            if (folder) {
                NSTextField *path = Lbl(NotesDir().path.stringByAbbreviatingWithTildeInPath, 13, NSFontWeightRegular, Wh(0.55));
                path.alignment = NSTextAlignmentRight;
                path.frame = NSMakeRect(w - 22 - 110 - 10 - 220, y + 16, 220, 18);
                [card addSubview:path];
            }
            [card addSubview:Pill(NSMakeRect(w - 22 - 110, y + 10, 110, 30), folder ? L(@"Open", @"Открыть") : L(@"Open setup", @"Открыть"), NO, NO, ^{
                if (folder) {
                    [NSFileManager.defaultManager createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:nil];
                    [NSWorkspace.sharedWorkspace openURL:NotesDir()];
                } else {
                    [actions showOnboarding];
                }
            })];
        } else {
            NSTextField *v = Lbl(value, 13, NSFontWeightRegular, Wh(0.6));
            v.alignment = NSTextAlignmentRight;
            v.frame = NSMakeRect(300, y + 16, w - 322, 18);
            [card addSubview:v];
        }
    }
    NSTextField *foot = Lbl(L(@"Speech is recognised on this Mac. Nothing is uploaded.", @"Речь распознаётся на этом Mac. Ничего никуда не отправляется."), 12, NSFontWeightRegular, Wh(0.45));
    foot.frame = NSMakeRect(22, rows.count * rowH + 12, w - 44, 18);
    [card addSubview:foot];
    [_main addSubview:card];

    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSTextField *ver = Lbl([NSString stringWithFormat:@"Tynda %@ · %@", version, L(@"early alpha", @"ранняя альфа")], 12, NSFontWeightRegular, Wh(0.35));
    ver.frame = NSMakeRect(kMainX + 4, kBodyY + rows.count * rowH + 46 + 14, 400, 18);
    [_main addSubview:ver];
}

- (void)searchChanged:(NSSearchField *)field {
    _query = field.stringValue;
    [self rebuildMain];
    // Rebuilding replaced the field; give the new one the cursor back.
    for (NSView *v in _main.subviews) {
        if ([v isKindOfClass:NSSearchField.class]) {
            [_window makeFirstResponder:v];
            NSText *editor = [(NSSearchField *)v currentEditor];
            editor.selectedRange = NSMakeRange(editor.string.length, 0);
        }
    }
}

- (void)dictationSwitched:(NSSwitch *)sw {
    if (([_actions dictationEnabled] ? NSControlStateValueOn : NSControlStateValueOff) != sw.state) [_actions toggleDictation];
    [self refreshStatus];
}

- (void)loginSwitched:(NSSwitch *)sw {
    NSError *err = nil;
    BOOL ok = sw.state == NSControlStateValueOn ? [SMAppService.mainAppService registerAndReturnError:&err]
                                                : [SMAppService.mainAppService unregisterAndReturnError:&err];
    if (!ok) {
        Log(@"login item: %@", err);
        sw.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)show:(LibrarySection)section {
    if (!_window) [self buildWindow];
    _section = section;
    _wasRecording = [_actions isRecordingMeeting];
    _wasProcessing = [_actions isProcessingMeeting];
    [self rebuildMain];
    if (!_window.isVisible) [_window center];
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:nil];  // don't start with the cursor in the search field
    [self refreshStatus];
}

- (void)showMeeting:(NSString *)folder {
    _selectedFolder = folder;
    _query = nil;
    [self show:SecMeetings];
}
@end
