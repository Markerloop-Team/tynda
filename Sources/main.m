// Tynda — a personal menu bar recorder: microphone + system audio into two
// files, then a local pipeline (process.py) turns them into a transcript and a note.
//
// Objective-C on purpose: it builds with the plain Command Line Tools.

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UserNotifications/UserNotifications.h>

// The Python scripts travel inside the app bundle.
static NSURL *ScriptsDir(void) { return NSBundle.mainBundle.resourceURL; }

// Recordings, transcripts and notes. Change with: defaults write app.tynda.mac notesDir /some/folder
static NSURL *NotesDir(void) {
    NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:@"notesDir"];
    NSString *path = custom.length ? custom.stringByExpandingTildeInPath : [NSHomeDirectory() stringByAppendingPathComponent:@"Tynda"];
    return [NSURL fileURLWithPath:path];
}

// The Python that has mlx-whisper installed: the one install.sh creates, or a `uv tool install mlx-whisper`.
// Override with: defaults write app.tynda.mac python /path/to/python
static NSString *PythonPath(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    NSString *custom = [NSUserDefaults.standardUserDefaults stringForKey:@"python"];
    if (custom.length) [candidates addObject:custom.stringByExpandingTildeInPath];
    [candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tynda/venv/bin/python"]];
    [candidates addObject:[NSHomeDirectory() stringByAppendingPathComponent:@".local/share/uv/tools/mlx-whisper/bin/python"]];
    for (NSString *c in candidates) if ([NSFileManager.defaultManager isExecutableFileAtPath:c]) return c;
    return nil;
}

// English by default, Russian when the system language is Russian.
static NSString *L(NSString *en, NSString *ru) {
    static BOOL russian;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ russian = [NSLocale.preferredLanguages.firstObject hasPrefix:@"ru"]; });
    return russian ? ru : en;
}
static NSString *TyndaLang(void) { return L(@"en", @"ru"); }

// Diagnostics go to ~/Library/Logs/Tynda.log.
static void Log(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], msg];
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Tynda.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
static BOOL SelfTest(void) { return [NSProcessInfo.processInfo.arguments containsObject:@"--selftest"]; }

#pragma mark - System audio (what the other side says)

@interface SystemAudioRecorder : NSObject <SCStreamOutput, SCStreamDelegate>
@property(atomic, strong) NSDate *firstSampleAt;
- (void)startWithURL:(NSURL *)url completion:(void (^)(NSError *error))done;
- (void)stopWithCompletion:(void (^)(BOOL wroteFile))done;
@end

@implementation SystemAudioRecorder {
    SCStream *_stream;
    AVAssetWriter *_writer;
    AVAssetWriterInput *_input;
    BOOL _sessionStarted;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("tynda.system-audio", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)startWithURL:(NSURL *)url completion:(void (^)(NSError *))done {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                               onScreenWindowsOnly:NO
                                                 completionHandler:^(SCShareableContent *content, NSError *error) {
        if (error || content.displays.count == 0) {
            done(error ?: [NSError errorWithDomain:@"Tynda" code:1 userInfo:@{NSLocalizedDescriptionKey: @"No display found"}]);
            return;
        }
        SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                                     excludingApplications:@[]
                                                          exceptingWindows:@[]];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new];
        cfg.capturesAudio = YES;
        cfg.excludesCurrentProcessAudio = YES;
        cfg.sampleRate = 48000;
        cfg.channelCount = 2;
        // Video is not used; keep it as cheap as possible.
        cfg.width = 2;
        cfg.height = 2;
        cfg.minimumFrameInterval = CMTimeMake(1, 1);

        NSError *err = nil;
        AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeAppleM4A error:&err];
        if (!writer) { done(err); return; }
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
            AVFormatIDKey: @(kAudioFormatMPEG4AAC),
            AVSampleRateKey: @48000,
            AVNumberOfChannelsKey: @2,
            AVEncoderBitRateKey: @96000,
        }];
        input.expectsMediaDataInRealTime = YES;
        [writer addInput:input];
        if (![writer startWriting]) { done(writer.error); return; }
        self->_writer = writer;
        self->_input = input;

        SCStream *stream = [[SCStream alloc] initWithFilter:filter configuration:cfg delegate:self];
        if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self->_queue error:&err]) {
            done(err);
            return;
        }
        [stream startCaptureWithCompletionHandler:^(NSError *startError) {
            if (!startError) self->_stream = stream;
            done(startError);
        }];
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio || !CMSampleBufferIsValid(sb)) return;
    if (!_writer || _writer.status != AVAssetWriterStatusWriting) return;
    if (!_sessionStarted) {
        [_writer startSessionAtSourceTime:CMSampleBufferGetPresentationTimeStamp(sb)];
        _sessionStarted = YES;
        self.firstSampleAt = [NSDate date];
    }
    if (_input.isReadyForMoreMediaData) [_input appendSampleBuffer:sb];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    NSLog(@"system audio stream stopped: %@", error);
}

- (void)stopWithCompletion:(void (^)(BOOL))done {
    void (^finish)(void) = ^{
        dispatch_async(self->_queue, ^{
            if (!self->_writer || !self->_sessionStarted) {
                [self->_writer cancelWriting];
                done(NO);
                return;
            }
            [self->_input markAsFinished];
            [self->_writer finishWritingWithCompletionHandler:^{
                done(self->_writer.status == AVAssetWriterStatusCompleted);
            }];
        });
    };
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:^(NSError *e) { finish(); }];
        _stream = nil;
    } else {
        finish();
    }
}
@end

#pragma mark - Dictation: microphone into memory, with a live level for the waveform

@interface DictationRecorder : NSObject
@property(atomic) float level;      // 0…1, smoothed for drawing
@property(atomic) float peakLevel;  // loudest moment of this recording
- (void)startWithFailure:(void (^)(NSError *error))failed;  // returns at once; `failed` comes on the main queue
- (NSTimeInterval)stopAndWriteWAV:(NSURL *)url;  // returns the duration in seconds
- (void)cancel;
@end

@implementation DictationRecorder {
    AVAudioEngine *_engine;
    NSMutableData *_samples;  // float32 mono
    double _sampleRate;
    dispatch_queue_t _queue;  // starting the microphone takes 0.1–0.3 s; keep that off the main thread
}

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("tynda.dictation-audio", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)startWithFailure:(void (^)(NSError *))failed {
    self.level = 0;
    self.peakLevel = 0;
    dispatch_async(_queue, ^{
        NSError *err = nil;
        if (![self startNow:&err]) dispatch_async(dispatch_get_main_queue(), ^{ failed(err); });
    });
}

- (void)cancel {
    dispatch_sync(_queue, ^{ [self cancelNow]; });
}

- (NSTimeInterval)stopAndWriteWAV:(NSURL *)url {
    __block NSTimeInterval duration = 0;
    dispatch_sync(_queue, ^{ duration = [self stopNowAndWriteWAV:url]; });
    return duration;
}

- (BOOL)startNow:(NSError **)error {
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    if (fmt.sampleRate == 0 || fmt.channelCount == 0) {
        if (error) *error = [NSError errorWithDomain:@"Tynda" code:4 userInfo:@{NSLocalizedDescriptionKey: L(@"Microphone is unavailable", @"Микрофон недоступен")}];
        _engine = nil;
        return NO;
    }
    _sampleRate = fmt.sampleRate;
    NSMutableData *samples = [NSMutableData new];
    _samples = samples;
    __weak DictationRecorder *weakSelf = self;
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        float *const *channels = buf.floatChannelData;
        if (!channels || buf.frameLength == 0) return;
        const float *ch = channels[0];
        AVAudioFrameCount n = buf.frameLength;
        double sum = 0;
        for (AVAudioFrameCount i = 0; i < n; i++) sum += ch[i] * ch[i];
        @synchronized (samples) { [samples appendBytes:ch length:n * sizeof(float)]; }
        // Map roughly -50…-5 dB onto 0…1; the curve keeps normal speech in the middle of the range.
        double db = 10 * log10(sum / n + 1e-12);
        float v = (float)pow(fmin(fmax((db + 50) / 45, 0), 1), 1.6);
        DictationRecorder *me = weakSelf;
        if (me) {
            me.level = v;
            if (v > me.peakLevel) me.peakLevel = v;
        }
    }];
    [_engine prepare];
    if (![_engine startAndReturnError:error]) {
        [input removeTapOnBus:0];
        _engine = nil;
        return NO;
    }
    return YES;
}

- (void)cancelNow {
    if (!_engine) return;
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    _engine = nil;
    self.level = 0;
}

- (NSTimeInterval)stopNowAndWriteWAV:(NSURL *)url {
    NSMutableData *samples = _samples;
    double rate = _sampleRate;
    _samples = nil;
    [self cancelNow];
    if (!samples || rate == 0) return 0;
    NSData *pcm;
    @synchronized (samples) { pcm = [samples copy]; }
    // Minimal WAV header: 32-bit float, mono.
    uint32_t dataLen = (uint32_t)pcm.length, riffLen = 36 + dataLen, fmtLen = 16, sr = (uint32_t)rate, byteRate = sr * 4;
    uint16_t format = 3, channels = 1, blockAlign = 4, bits = 32;
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataLen];
    [wav appendBytes:"RIFF" length:4]; [wav appendBytes:&riffLen length:4];
    [wav appendBytes:"WAVEfmt " length:8]; [wav appendBytes:&fmtLen length:4];
    [wav appendBytes:&format length:2]; [wav appendBytes:&channels length:2];
    [wav appendBytes:&sr length:4]; [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2]; [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4]; [wav appendBytes:&dataLen length:4];
    [wav appendData:pcm];
    [wav writeToURL:url atomically:YES];
    return (pcm.length / sizeof(float)) / rate;
}
@end

#pragma mark - Dictation: the transcription engine kept warm (dictate_server.py)

@interface Transcriber : NSObject
@property(atomic) BOOL ready;
@property(nonatomic, copy) void (^onReady)(void);
- (void)start;
- (void)transcribe:(NSString *)path completion:(void (^)(NSString *text, NSString *error))done;
@end

@implementation Transcriber {
    NSTask *_task;
    NSFileHandle *_stdin;
    NSMutableData *_buffer;
    NSMutableArray<NSMutableDictionary *> *_queue;  // phrases wait their turn, order is kept
    NSMutableDictionary *_current;
    NSUInteger _token;
}

- (void)start {
    if (!_queue) _queue = [NSMutableArray new];
    NSString *python = PythonPath();
    if (!python) {
        Log(@"dictation: no Python with mlx-whisper found — run install.sh");
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:python];
    task.arguments = @[[ScriptsDir() URLByAppendingPathComponent:@"dictate_server.py"].path];
    NSPipe *inPipe = [NSPipe pipe], *outPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    task.standardOutput = outPipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    _buffer = [NSMutableData new];
    __weak Transcriber *weakSelf = self;
    outPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (d.length == 0) { h.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:d]; });
    };
    task.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf died:t]; });
    };
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        Log(@"dictation: cannot start engine: %@", err);
        return;
    }
    _task = task;
    _stdin = inPipe.fileHandleForWriting;
}

- (void)died:(NSTask *)task {
    if (task != _task) return;
    Log(@"dictation: engine stopped");
    _task = nil;
    _stdin = nil;
    self.ready = NO;
    if (_current && ![_current[@"retried"] boolValue]) {
        // Give the phrase one more chance on a fresh engine.
        _current[@"retried"] = @YES;
        [_queue insertObject:_current atIndex:0];
        _current = nil;
        _token++;
        [self pump];
    } else {
        [self answer:nil error:L(@"Transcription failed", @"Расшифровка не удалась")];
    }
}

- (void)consume:(NSData *)data {
    [_buffer appendData:data];
    while (YES) {
        NSRange nl = [_buffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, _buffer.length)];
        if (nl.location == NSNotFound) break;
        NSData *line = [_buffer subdataWithRange:NSMakeRange(0, nl.location)];
        [_buffer replaceBytesInRange:NSMakeRange(0, nl.location + 1) withBytes:NULL length:0];
        NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![msg isKindOfClass:NSDictionary.class]) continue;
        if (msg[@"ready"]) {
            self.ready = YES;
            Log(@"dictation: engine ready");
            if (self.onReady) self.onReady();
        } else if (msg[@"error"]) {
            [self answer:nil error:[msg[@"error"] description]];
        } else {
            [self answer:[msg[@"text"] description] ?: @"" error:nil];
        }
    }
}

- (void)answer:(NSString *)text error:(NSString *)error {
    NSMutableDictionary *job = _current;
    _current = nil;
    _token++;
    if (job) ((void (^)(NSString *, NSString *))job[@"done"])(text, error);
    [self pump];
}

- (void)pump {
    if (_current || _queue.count == 0) return;
    if (!_task) [self start];
    _current = _queue.firstObject;
    [_queue removeObjectAtIndex:0];
    if (!_task) { [self answer:nil error:L(@"The transcription engine is not running", @"Движок расшифровки не запущен")]; return; }
    NSUInteger token = _token;
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:@{@"path": _current[@"path"]} options:0 error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    @try { [_stdin writeData:line]; } @catch (NSException *e) { [self answer:nil error:L(@"The transcription engine is unavailable", @"Движок расшифровки недоступен")]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (self->_token == token && self->_current) [self answer:nil error:L(@"Transcription took too long", @"Расшифровка заняла слишком долго")];
    });
}

- (void)transcribe:(NSString *)path completion:(void (^)(NSString *, NSString *))done {
    if (!_queue) _queue = [NSMutableArray new];
    [_queue addObject:[@{@"path": path, @"done": [done copy]} mutableCopy]];
    [self pump];
}
@end

#pragma mark - Dictation: the black island with the waveform

typedef NS_ENUM(NSInteger, IslandMode) { IslandRecording, IslandLocked, IslandTranscribing, IslandMessage };

@interface IslandView : NSView
@property(nonatomic) IslandMode mode;
@property(nonatomic, copy) NSString *message;
- (void)pushLevel:(float)level;
- (void)resetLevels;
@end

#define ISLAND_BARS 64

@implementation IslandView {
    float _levels[ISLAND_BARS];
    NSUInteger _tick;
}

- (BOOL)isFlipped { return NO; }

- (void)resetLevels { memset(_levels, 0, sizeof(_levels)); }

- (void)pushLevel:(float)level {
    memmove(_levels, _levels + 1, sizeof(float) * (ISLAND_BARS - 1));
    // Fast attack, soft release — the wave looks alive but not jittery.
    float prev = _levels[ISLAND_BARS - 2];
    _levels[ISLAND_BARS - 1] = level > prev ? level : prev * 0.75f + level * 0.25f;
    _tick++;
    self.needsDisplay = YES;
}

- (void)drawText:(NSString *)text inRect:(NSRect)r alpha:(CGFloat)alpha align:(NSTextAlignment)align {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:alpha],
        NSParagraphStyleAttributeName: ps,
    };
    CGFloat h = [text sizeWithAttributes:attrs].height;
    [text drawInRect:NSMakeRect(r.origin.x, NSMidY(r) - h / 2, r.size.width, h) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:b.size.height / 2 yRadius:b.size.height / 2];
    [[NSColor colorWithWhite:0 alpha:0.94] setFill];
    [pill fill];
    [[NSColor colorWithWhite:1 alpha:0.14] setStroke];
    pill.lineWidth = 1;
    [pill stroke];

    CGFloat pad = 16;
    if (self.mode == IslandMessage) {
        [self drawText:self.message ?: @"" inRect:NSInsetRect(b, pad, 0) alpha:0.85 align:NSTextAlignmentCenter];
        return;
    }
    if (self.mode == IslandTranscribing) {
        // Three dots breathing in turn.
        CGFloat cx = NSMidX(b), cy = NSMidY(b);
        for (int i = 0; i < 3; i++) {
            double phase = fmod(_tick / 30.0 * 1.6 - i * 0.18, 1.0);
            if (phase < 0) phase += 1;
            CGFloat a = 0.3 + 0.7 * fmax(0, sin(phase * M_PI));
            [[NSColor colorWithWhite:1 alpha:a] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(cx - 14 + i * 11, cy - 3, 6, 6)] fill];
        }
        return;
    }

    // Recording: a red dot, the wave, and in hands-free mode a hint on how to stop.
    CGFloat pulse = 0.65 + 0.35 * sin(_tick / 30.0 * 2 * M_PI * 0.8);
    [[NSColor colorWithRed:1 green:0.27 blue:0.23 alpha:pulse] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pad, NSMidY(b) - 4, 8, 8)] fill];

    CGFloat left = pad + 8 + 10, right = b.size.width - pad;
    if (self.mode == IslandLocked) {
        CGFloat hintW = 150;
        [self drawText:L(@"fn — stop · esc — cancel", @"fn — стоп · esc — отмена") inRect:NSMakeRect(right - hintW, 0, hintW, b.size.height) alpha:0.55 align:NSTextAlignmentRight];
        right -= hintW + 8;
    }
    CGFloat barW = 3, gap = 2.5, maxH = b.size.height - 16;
    NSInteger count = MIN((NSInteger)((right - left + gap) / (barW + gap)), ISLAND_BARS);
    CGFloat x = right - barW;
    for (NSInteger i = 0; i < count; i++) {
        float v = _levels[ISLAND_BARS - 1 - i];
        CGFloat h = MAX(3, v * maxH);
        // Older bars fade out towards the left edge.
        CGFloat a = 0.35 + 0.65 * (1.0 - (CGFloat)i / count);
        [[NSColor colorWithWhite:1 alpha:a] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, NSMidY(b) - h / 2, barW, h) xRadius:barW / 2 yRadius:barW / 2] fill];
        x -= barW + gap;
    }
}
@end

@interface Island : NSObject
- (void)show:(IslandMode)mode message:(NSString *)message levelSource:(float (^)(void))level;
- (void)hideAfter:(NSTimeInterval)delay;
@property(nonatomic, readonly) BOOL visible;
@end

@implementation Island {
    NSPanel *_panel;
    IslandView *_view;
    NSTimer *_timer;
    float (^_level)(void);
    NSUInteger _generation;
}

- (BOOL)visible { return _panel.isVisible && _panel.alphaValue > 0; }

- (void)show:(IslandMode)mode message:(NSString *)message levelSource:(float (^)(void))level {
    _generation++;
    CGFloat w = mode == IslandLocked ? 330 : (mode == IslandRecording ? 180 : (mode == IslandMessage ? 280 : 96)), h = 38;
    if (!_panel) {
        _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
        _panel.opaque = NO;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.hasShadow = YES;
        _panel.level = NSStatusWindowLevel;
        _panel.ignoresMouseEvents = YES;
        _panel.hidesOnDeactivate = NO;
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorStationary;
        _view = [[IslandView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
        _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _panel.contentView = _view;
        _panel.alphaValue = 0;
    }
    BOOL wasVisible = self.visible;
    if (!wasVisible) [_view resetLevels];
    _view.mode = mode;
    _view.message = message;
    _level = [level copy];

    // Top centre of the screen the user is working on, right under the menu bar.
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect vis = screen.visibleFrame;
    NSRect frame = NSMakeRect(NSMidX(screen.frame) - w / 2, NSMaxY(vis) - h - 8, w, h);
    if (wasVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.18;
            [self->_panel.animator setFrame:frame display:YES];
        }];
    } else {
        [_panel setFrame:frame display:YES];
        [_panel orderFrontRegardless];
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.12;
        self->_panel.animator.alphaValue = 1;
    }];
    _view.needsDisplay = YES;
    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
            [self->_view pushLevel:self->_level ? self->_level() : 0];
        }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
}

- (void)hideAfter:(NSTimeInterval)delay {
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != self->_generation) return;  // shown again meanwhile
        [self->_timer invalidate];
        self->_timer = nil;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.15;
            self->_panel.animator.alphaValue = 0;
        } completionHandler:^{
            if (gen == self->_generation) [self->_panel orderOut:nil];
        }];
    });
}
@end

#pragma mark - App

#pragma mark - The mark in the menu bar

// Five bars of a waveform — the same mark as the app icon. Without a colour it adapts to the menu bar.
static NSImage *BarsImage(NSColor *color) {
    NSImage *img = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:NO drawingHandler:^BOOL(NSRect r) {
        static const CGFloat heights[5] = {0.30, 0.62, 1.00, 0.48, 0.22};
        CGFloat barW = 2, gap = 1.6, total = 5 * barW + 4 * gap, x = (r.size.width - total) / 2, maxH = 14;
        [(color ?: NSColor.blackColor) setFill];
        for (int i = 0; i < 5; i++) {
            CGFloat h = MAX(barW, maxH * heights[i]);
            [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, (r.size.height - h) / 2, barW, h) xRadius:1 yRadius:1] fill];
            x += barW + gap;
        }
        return YES;
    }];
    img.template = color == nil;
    return img;
}

#pragma mark - First run: one window that walks through the permissions

@interface SetupRow : NSObject
@property(nonatomic, strong) NSTextField *mark, *title, *detail;
@property(nonatomic, strong) NSButton *button;
@property(nonatomic, strong) NSView *view;
@end
@implementation SetupRow
@end

@interface Onboarding : NSObject <NSWindowDelegate>
+ (BOOL)micGranted;
@property(nonatomic, copy) BOOL (^engineReady)(void);
@property(nonatomic, copy) BOOL (^engineInstalled)(void);
@property(nonatomic, copy) BOOL (^listening)(void);
- (void)show;
+ (BOOL)needed;
@end

@implementation Onboarding {
    NSWindow *_window;
    SetupRow *_mic, *_access, *_fn, *_engine;
    NSTextField *_tryLabel, *_tryField;
    NSButton *_done;
    NSTimer *_timer;
}

+ (BOOL)micGranted { return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized; }

// The fn / globe key must not be taken by a system action.
+ (BOOL)fnFree {
    NSNumber *v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("AppleFnUsageType"), CFSTR("com.apple.HIToolbox")));
    return [v isKindOfClass:NSNumber.class] && v.integerValue == 0;
}

+ (BOOL)needed {
    return ![NSUserDefaults.standardUserDefaults boolForKey:@"onboarded"] || ![self micGranted] || !AXIsProcessTrusted();
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight color:(NSColor *)color {
    NSTextField *f = [NSTextField wrappingLabelWithString:text];
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = color;
    f.selectable = NO;
    return f;
}

- (SetupRow *)row:(NSString *)title action:(SEL)action {
    SetupRow *row = [SetupRow new];
    row.mark = [self label:@"○" size:15 weight:NSFontWeightSemibold color:NSColor.tertiaryLabelColor];
    row.title = [self label:title size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    row.detail = [self label:@"" size:12 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    row.button = [NSButton buttonWithTitle:@"" target:self action:action];
    row.button.bezelStyle = NSBezelStyleRounded;
    [row.mark.widthAnchor constraintEqualToConstant:20].active = YES;
    [row.button.widthAnchor constraintEqualToConstant:128].active = YES;
    NSStackView *text = [NSStackView stackViewWithViews:@[row.title, row.detail]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    NSStackView *h = [NSStackView stackViewWithViews:@[row.mark, text, row.button]];
    h.alignment = NSLayoutAttributeTop;
    h.spacing = 10;
    h.distribution = NSStackViewDistributionFill;
    // The text takes all the room that is left, so the buttons line up on the right edge.
    [text.widthAnchor constraintEqualToConstant:520 - 64 - 20 - 128 - 20].active = YES;
    h.detachesHiddenViews = NO;
    [text setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row.button setContentHuggingPriority:999 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row.button setContentCompressionResistancePriority:999 forOrientation:NSLayoutConstraintOrientationHorizontal];
    row.view = h;
    return row;
}

- (void)build {
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 600)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.titlebarAppearsTransparent = YES;
    _window.title = @"";
    _window.releasedWhenClosed = NO;
    _window.delegate = self;
    _window.movableByWindowBackground = YES;

    NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    [icon.widthAnchor constraintEqualToConstant:72].active = YES;
    [icon.heightAnchor constraintEqualToConstant:72].active = YES;
    NSTextField *title = [self label:L(@"Welcome to Tynda", @"Добро пожаловать в Tynda") size:24 weight:NSFontWeightBold color:NSColor.labelColor];
    NSTextField *sub = [self label:L(@"Hold fn, speak, and the text is typed where your cursor is. Four things to set up — it takes a minute.",
                                     @"Удерживай fn, говори — и текст появится там, где стоит курсор. Нужно настроить четыре вещи, это минута.")
                              size:13 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];

    _mic = [self row:L(@"Microphone", @"Микрофон") action:@selector(micAction)];
    _access = [self row:L(@"Accessibility", @"Универсальный доступ") action:@selector(accessAction)];
    _fn = [self row:L(@"The fn key", @"Клавиша fn") action:@selector(fnAction)];
    _engine = [self row:L(@"Speech model", @"Модель распознавания речи") action:@selector(engineAction)];

    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    _tryLabel = [self label:@"" size:13 weight:NSFontWeightSemibold color:NSColor.labelColor];
    _tryField = [NSTextField textFieldWithString:@""];
    _tryField.placeholderString = L(@"Click here, hold fn and say something", @"Нажми сюда, удерживай fn и скажи что-нибудь");
    _tryField.font = [NSFont systemFontOfSize:14];
    _tryField.usesSingleLineMode = NO;
    _tryField.cell.wraps = YES;
    _tryField.cell.scrollable = NO;
    [_tryField.heightAnchor constraintEqualToConstant:64].active = YES;
    NSTextField *hint = [self label:L(@"Hold fn — talk — let go.\nDouble-tap fn — hands-free; fn again to finish.\nEsc — cancel.",
                                      @"Удерживай fn — говори — отпусти.\nДвойной fn — без удержания; ещё раз fn — готово.\nEsc — отмена.")
                               size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    NSTextField *meetings = [self label:L(@"Meetings: the Tynda icon in the menu bar → Record meeting. macOS will ask for one more permission then, to record the other side of the call.",
                                          @"Встречи: значок Tynda в строке меню → «Начать запись». Тогда macOS спросит ещё одно разрешение — чтобы записывать собеседников.")
                                   size:11 weight:NSFontWeightRegular color:NSColor.secondaryLabelColor];
    _done = [NSButton buttonWithTitle:L(@"Done", @"Готово") target:self action:@selector(doneAction)];
    _done.bezelStyle = NSBezelStyleRounded;
    _done.keyEquivalent = @"\r";

    [_done.widthAnchor constraintEqualToConstant:128].active = YES;
    NSView *spacer = [NSView new];
    NSStackView *footer = [NSStackView stackViewWithViews:@[spacer, _done]];
    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, title, sub, _mic.view, _access.view, _fn.view, _engine.view, line, _tryLabel, _tryField, hint, meetings, footer]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(36, 32, 24, 32);
    [stack setCustomSpacing:6 afterView:title];
    [stack setCustomSpacing:22 afterView:sub];
    [stack setCustomSpacing:8 afterView:_tryLabel];
    [stack setCustomSpacing:8 afterView:_tryField];
    [stack setCustomSpacing:18 afterView:meetings];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *content = [NSView new];
    [content addSubview:stack];
    _window.contentView = content;
    CGFloat inner = 520 - 64;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [content.widthAnchor constraintEqualToConstant:520],
    ]];
    for (NSView *v in @[sub, _mic.view, _access.view, _fn.view, _engine.view, line, _tryField, hint, meetings, footer]) {
        [v.widthAnchor constraintEqualToConstant:inner].active = YES;
    }
}

- (void)set:(SetupRow *)row ok:(BOOL)ok busy:(BOOL)busy detail:(NSString *)detail button:(NSString *)button {
    row.mark.stringValue = ok ? @"✓" : (busy ? @"…" : @"○");
    row.mark.textColor = ok ? NSColor.systemGreenColor : (busy ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor);
    row.detail.stringValue = detail;
    row.button.hidden = ok || button == nil;
    if (button) row.button.title = button;
}

- (void)refresh {
    AVAuthorizationStatus mic = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    BOOL micOK = mic == AVAuthorizationStatusAuthorized;
    [self set:_mic ok:micOK busy:NO
       detail:micOK ? L(@"Tynda can hear you.", @"Tynda тебя слышит.")
                    : L(@"To hear what you say. Audio never leaves this Mac.", @"Чтобы слышать, что ты говоришь. Звук не покидает этот Mac.")
       button:mic == AVAuthorizationStatusNotDetermined ? L(@"Allow", @"Разрешить") : L(@"Open Settings", @"Открыть настройки")];

    BOOL axOK = AXIsProcessTrusted();
    [self set:_access ok:axOK busy:NO
       detail:axOK ? L(@"Tynda notices fn and can type for you.", @"Tynda видит fn и может печатать за тебя.")
                   : L(@"To notice the fn key and to type the text into the app you are in. Turn on Tynda in the list that opens.",
                       @"Чтобы замечать fn и вставлять текст в программу, где ты работаешь. В открывшемся списке включи Tynda.")
       button:L(@"Open Settings", @"Открыть настройки")];

    BOOL fnOK = [Onboarding fnFree];
    [self set:_fn ok:fnOK busy:NO
       detail:fnOK ? L(@"The key is free for dictation.", @"Клавиша свободна для диктовки.")
                   : L(@"macOS uses fn for something else. In Keyboard settings set \"Press 🌐 key to\" to \"Do Nothing\".",
                       @"macOS занимает fn другим действием. В настройках клавиатуры поставь «Нажатие клавиши 🌐» → «Ничего не делать».")
       button:L(@"Open Settings", @"Открыть настройки")];

    BOOL installed = self.engineInstalled && self.engineInstalled();
    BOOL ready = self.engineReady && self.engineReady();
    [self set:_engine ok:ready busy:installed && !ready
       detail:ready ? L(@"Loaded. Recognition runs on this Mac.", @"Загружена. Распознавание идёт на этом Mac.")
                    : (installed ? L(@"Loading, a few seconds…", @"Загружается, несколько секунд…")
                                 : L(@"Not installed. Run install.sh from the project folder.", @"Не установлена. Запусти install.sh из папки проекта."))
       button:nil];

    BOOL all = micOK && axOK && ready && self.listening && self.listening();
    _tryLabel.stringValue = all ? L(@"Everything is ready — try it", @"Всё готово — попробуй")
                                : L(@"Try it once the steps above are green", @"Попробуй, когда шаги выше станут зелёными");
    _tryLabel.textColor = all ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    _tryField.enabled = all;
}

- (void)openSettings:(NSString *)url { [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]]; }

- (void)micAction {
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            Log(@"setup: microphone granted=%d", granted);
            dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
        }];
    } else {
        [self openSettings:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"];
    }
}

- (void)accessAction {
    // Puts Tynda into the Accessibility list, then opens that list.
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt: @YES});
    [self openSettings:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
}

- (void)fnAction { [self openSettings:@"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"]; }
- (void)engineAction {}

- (void)doneAction {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboarded"];
    [_window close];
}

- (void)show {
    if (!_window) [self build];
    [self refresh];
    if (!_timer) {
        _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    [_window layoutIfNeeded];
    [_window center];
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeKeyAndOrderFront:nil];
}

- (void)windowWillClose:(NSNotification *)note {
    [_timer invalidate];
    _timer = nil;
}
@end

// fn held = push-to-talk; a quick double tap = hands-free until the next fn.
typedef NS_ENUM(NSInteger, DictState) { DIdle, DHolding, DTapWait, DLocked };

static const NSTimeInterval kTapMax = 0.50;          // shorter than this is always a tap, not a hold
static const NSTimeInterval kSlowTapMax = 1.0;       // up to this it is still a tap if nothing was said
static const NSTimeInterval kSecondTapWait = 0.60;   // how long to wait for the second tap
static const NSTimeInterval kSilenceStop = 45;       // hands-free: stop by itself after this much silence
static const NSTimeInterval kMaxDictation = 15 * 60; // hands-free: hard cap
static const CGKeyCode kKeyFn = 63, kKeyGlobe = 179, kKeyEsc = 53, kKeyV = 9;

static BOOL DemoDictation(void) { return [NSProcessInfo.processInfo.arguments containsObject:@"--demo-dictation"]; }

@interface AppDelegate : NSObject <NSApplicationDelegate>
- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type;
@end

static CGEventRef TapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    return [(__bridge AppDelegate *)info handleEvent:event type:type];
}

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    NSMenuItem *_toggleItem;
    NSMenuItem *_infoItem;
    AVAudioRecorder *_mic;
    SystemAudioRecorder *_system;
    NSURL *_sessionDir;
    NSDate *_startedAt;
    NSTimer *_timer;
    NSInteger _processing;
    BOOL _busy;

    // Dictation
    NSMenuItem *_dictationItem;
    NSMenuItem *_accessItem;
    DictationRecorder *_dictation;
    Transcriber *_transcriber;
    Island *_island;
    CFMachPortRef _tap;
    NSTimer *_tapTimer;
    DictState _dState;
    BOOL _fnDown;           // touched only on the key-listener thread
    NSDate *_fnDownAt;
    NSTimeInterval _fnDownT; // keyboard event time of the press, seconds since boot
    NSUInteger _dGeneration;
    NSString *_demoOut;
    NSTimer *_watchdog;
    NSDate *_recStartedAt;
    NSDate *_lastVoiceAt;
    NSInteger _jobs;        // phrases being transcribed right now
    NSUInteger _wavCounter;
    NSString *_lastText;
    NSMenuItem *_copyLastItem;
    Onboarding *_onboarding;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSMenu *menu = [NSMenu new];
    _infoItem = [[NSMenuItem alloc] initWithTitle:L(@"Ready", @"Готов к записи") action:nil keyEquivalent:@""];
    _infoItem.enabled = NO;
    [menu addItem:_infoItem];
    [menu addItem:NSMenuItem.separatorItem];
    _toggleItem = [[NSMenuItem alloc] initWithTitle:L(@"Record meeting", @"Начать запись") action:@selector(toggle) keyEquivalent:@"r"];
    _toggleItem.target = self;
    [menu addItem:_toggleItem];
    NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:L(@"Open notes folder", @"Открыть папку заметок") action:@selector(openNotes) keyEquivalent:@"o"];
    open.target = self;
    [menu addItem:open];
    [menu addItem:NSMenuItem.separatorItem];
    _dictationItem = [[NSMenuItem alloc] initWithTitle:L(@"Dictation with fn", @"Диктовка по fn") action:@selector(toggleDictation) keyEquivalent:@""];
    _dictationItem.target = self;
    _dictationItem.toolTip = L(@"Hold fn and speak — the text is typed where your cursor is. Double-tap fn for hands-free, fn again to stop, Esc to cancel.", @"Удерживай fn и говори — текст вставится на месте курсора. Двойной fn — запись без удержания, ещё один fn — стоп, Esc — отмена.");
    [menu addItem:_dictationItem];
    _copyLastItem = [[NSMenuItem alloc] initWithTitle:L(@"Copy last dictation", @"Скопировать последнюю диктовку") action:@selector(copyLast) keyEquivalent:@""];
    _copyLastItem.target = self;
    _copyLastItem.hidden = YES;
    [menu addItem:_copyLastItem];
    _accessItem = [[NSMenuItem alloc] initWithTitle:L(@"Setup…", @"Настройка…") action:@selector(showOnboarding) keyEquivalent:@""];
    _accessItem.target = self;
    [menu addItem:_accessItem];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:L(@"Quit", @"Выйти") action:@selector(terminate:) keyEquivalent:@"q"]];
    _statusItem.menu = menu;
    [self refresh];
    [UNUserNotificationCenter.currentNotificationCenter
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                      completionHandler:^(BOOL granted, NSError *error) {}];

    [self setUpDictation];

    // `--selftest N`: record N seconds, process, quit. Used to verify the build.
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:@"--selftest"];
    if (i != NSNotFound && i + 1 < args.count) {
        double secs = args[i + 1].doubleValue;
        [self startRecording:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self stopRecording:^{}];
            });
        }];
    }
}

#pragma mark Dictation

- (BOOL)dictationEnabled {
    id v = [NSUserDefaults.standardUserDefaults objectForKey:@"dictationEnabled"];
    return v ? [v boolValue] : YES;
}

- (void)toggleDictation {
    [NSUserDefaults.standardUserDefaults setBool:![self dictationEnabled] forKey:@"dictationEnabled"];
    if (![self dictationEnabled]) [self cancelDictation:NO];
    [self refreshDictationMenu];
}

- (void)refreshDictationMenu {
    _dictationItem.state = [self dictationEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)showOnboarding {
    if (!_onboarding) {
        _onboarding = [Onboarding new];
        __weak AppDelegate *weakSelf = self;
        _onboarding.engineInstalled = ^BOOL { return PythonPath() != nil; };
        _onboarding.engineReady = ^BOOL { AppDelegate *me = weakSelf; return me ? me->_transcriber.ready : NO; };
        _onboarding.listening = ^BOOL { AppDelegate *me = weakSelf; return me ? me->_tap != NULL : NO; };
    }
    [_onboarding show];
}

// ⌘V, ⌘C and friends need an Edit menu to exist, even in an app without a menu bar of its own.
- (void)installEditMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [main addItemWithTitle:@"Tynda" action:nil keyEquivalent:@""];
    appItem.submenu = [[NSMenu alloc] initWithTitle:@"Tynda"];
    [appItem.submenu addItemWithTitle:L(@"Quit Tynda", @"Завершить Tynda") action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *editItem = [main addItemWithTitle:@"Edit" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:L(@"Edit", @"Правка")];
    [edit addItemWithTitle:L(@"Undo", @"Отменить") action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [edit addItemWithTitle:L(@"Cut", @"Вырезать") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:L(@"Copy", @"Скопировать") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:L(@"Paste", @"Вставить") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:L(@"Select All", @"Выбрать всё") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = main;
}

- (void)setUpDictation {
    _dictation = [DictationRecorder new];
    _island = [Island new];
    _transcriber = [Transcriber new];
    [_transcriber start];
    [self refreshDictationMenu];

    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:@"--demo-dictation"];
    if (i != NSNotFound && i + 2 < args.count) {
        // `--demo-dictation N FILE`: hands-free dictation for N seconds, result into FILE, quit.
        double secs = args[i + 1].doubleValue;
        _demoOut = args[i + 2];
        __weak AppDelegate *weakSelf = self;
        _transcriber.onReady = ^{
          [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
           dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *me = weakSelf;
            Log(@"demo: microphone granted=%d", granted);
            NSTimeInterval (^now)(void) = ^{ return NSProcessInfo.processInfo.systemUptime; };
            [me fnPressed:now()];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [me fnReleased:now()]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [me fnPressed:now()]; [me fnReleased:now()]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(secs * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [me fnPressed:now()]; });
           });
          }];
        };
        return;
    }
    if (SelfTest()) return;

    // Watching fn and pasting need the Accessibility permission; the setup window walks through it.
    Log(@"dictation: accessibility trusted=%d, microphone=%d", AXIsProcessTrusted(), [Onboarding micGranted]);
    [self installEditMenu];
    if ([Onboarding needed]) [self showOnboarding];
    [self installTap];
    if (!_tap) {
        _tapTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
            [self installTap];
            if (self->_tap) { [t invalidate]; self->_tapTimer = nil; }
        }];
    }
}

- (void)installTap {
    if (_tap || !AXIsProcessTrusted()) return;
    CGEventMask mask = CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(kCGEventKeyDown);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, TapCallback, (__bridge void *)self);
    if (!_tap) return;
    // Its own thread: if the main thread is busy for a moment, no key press is lost or delayed.
    CFMachPortRef tap = _tap;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
        CFRelease(src);
        CGEventTapEnable(tap, true);
        CFRunLoopRun();
    }];
    thread.name = @"tynda.keys";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
    Log(@"dictation: fn listener installed");
    [self refreshDictationMenu];
}

- (CGEventRef)handleEvent:(CGEventRef)event type:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }
    CGKeyCode key = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (type == kCGEventFlagsChanged) {
        if (key == kKeyFn) {
            BOOL down = (CGEventGetFlags(event) & kCGEventFlagMaskSecondaryFn) != 0;
            if (down != _fnDown) {
                _fnDown = down;
                NSTimeInterval t = CGEventGetTimestamp(event) / 1e9;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (down) [self fnPressed:t]; else [self fnReleased:t];
                });
            }
        }
        return event;
    }
    if (type == kCGEventKeyDown) {
        // fn + another key is a normal shortcut (fn+arrows, fn+delete…), not dictation.
        DictState state = _dState;
        // A quick tap of fn (the globe key) also arrives as a key press of its own. It is not "another key".
        if (key == kKeyFn || key == kKeyGlobe) return event;
        if (state == DHolding || state == DTapWait) Log(@"dictation: key %d pressed with fn, not a dictation", (int)key);
        if (state != DIdle && key == kKeyEsc) {  // "I changed my mind"
            dispatch_async(dispatch_get_main_queue(), ^{ [self cancelDictation:YES]; });
            return NULL;
        }
        if (state == DHolding || state == DTapWait) dispatch_async(dispatch_get_main_queue(), ^{ [self cancelDictation:NO]; });
    }
    return event;
}

- (void)fnPressed:(NSTimeInterval)t {
    switch (_dState) {
        case DIdle: {
            if (![self dictationEnabled]) return;
            if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized) {
                Log(@"dictation: no microphone permission yet, asking");
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {}];
                [_island show:IslandMessage message:L(@"No microphone access", @"Нет доступа к микрофону") levelSource:nil];
                [_island hideAfter:2];
                return;
            }
            [_dictation startWithFailure:^(NSError *err) {
                Log(@"dictation: microphone start failed: %@", err);
                if (self->_dState == DIdle) return;
                self->_dGeneration++;
                [self stopWatchdog];
                [self->_dictation cancel];
                self->_dState = DIdle;
                [self islandSay:L(@"Microphone is unavailable", @"Микрофон недоступен") for:1.5];
            }];
            _dState = DHolding;
            _fnDownT = t;
            _fnDownAt = [NSDate date];
            _recStartedAt = _fnDownAt;
            _lastVoiceAt = _fnDownAt;
            [self startWatchdog];
            NSUInteger gen = ++_dGeneration;
            // The island waits a moment: a tap (the first half of a double tap), fn+arrow and stray
            // touches must not flash it. On a double tap it appears at once, already locked.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (gen == self->_dGeneration && self->_dState == DHolding) [self showRecordingIsland:IslandRecording];
            });
            break;
        }
        case DTapWait:
            Log(@"dictation: second tap — hands-free");
            _dGeneration++;
            _dState = DLocked;
            [self showRecordingIsland:IslandLocked];
            break;
        case DLocked:
            [self finishDictation:NO];
            break;
        default:
            break;
    }
}

- (void)fnReleased:(NSTimeInterval)t {
    if (_dState != DHolding) return;
    NSTimeInterval held = t - _fnDownT;
    BOOL tap = held < kTapMax || (held < kSlowTapMax && _dictation.peakLevel < 0.05);
    Log(@"dictation: fn released after %.2fs — %@", held, tap ? @"tap, waiting for the second one" : @"hold");
    if (!tap) {
        [self finishDictation:NO];
        return;
    }
    _dState = DTapWait;
    NSUInteger gen = ++_dGeneration;
    [self islandToRest];  // if a slow tap let the island show up, take it away until the second tap
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSecondTapWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_dGeneration && self->_dState == DTapWait) [self cancelDictation:NO];
    });
}

- (void)showRecordingIsland:(IslandMode)mode {
    DictationRecorder *rec = _dictation;
    [_island show:mode message:nil levelSource:^float { return rec.level; }];
}

// Safety net while a recording is running, 4 times a second.
- (void)startWatchdog {
    [_watchdog invalidate];
    _watchdog = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) { [self watchdogTick]; }];
    [NSRunLoop.mainRunLoop addTimer:_watchdog forMode:NSRunLoopCommonModes];
}

- (void)stopWatchdog {
    [_watchdog invalidate];
    _watchdog = nil;
}

- (void)watchdogTick {
    NSDate *now = [NSDate date];
    if (_dictation.level > 0.12) _lastVoiceAt = now;
    if (_dState == DHolding && !DemoDictation()) {
        // The release of fn can get lost (password fields hide keys from us). Ask the keyboard itself.
        BOOL physicallyDown = (CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState) & kCGEventFlagMaskSecondaryFn) != 0;
        if (!physicallyDown && [now timeIntervalSinceDate:_fnDownAt] > kSlowTapMax + 0.25) {
            Log(@"dictation: fn release was missed, finishing");
            _fnDown = NO;
            [self finishDictation:NO];
        }
    } else if (_dState == DLocked) {
        // Forgotten hands-free recording: stop, but don't paste into whatever is focused by now.
        if ([now timeIntervalSinceDate:_lastVoiceAt] > kSilenceStop || [now timeIntervalSinceDate:_recStartedAt] > kMaxDictation) {
            Log(@"dictation: hands-free stopped automatically");
            [self finishDictation:YES];
        }
    }
}

// What the island shows when no recording is running.
- (void)islandToRest {
    if (_jobs > 0) [_island show:IslandTranscribing message:nil levelSource:nil];
    else [_island hideAfter:0];
}

- (void)islandSay:(NSString *)message for:(NSTimeInterval)seconds {
    [_island show:IslandMessage message:message levelSource:nil];
    NSUInteger gen = _dGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == self->_dGeneration && self->_dState == DIdle) [self islandToRest];
    });
}

- (void)cancelDictation:(BOOL)byUser {
    if (_dState == DIdle) return;
    _dGeneration++;
    [self stopWatchdog];
    [_dictation cancel];
    _dState = DIdle;
    if (byUser) {
        Log(@"dictation: cancelled with Esc");
        [self islandSay:L(@"Cancelled", @"Отменено") for:0.8];
    } else {
        [self islandToRest];
    }
}

// `automatic` = the app stopped a forgotten recording itself: the text goes to the clipboard, not into a field.
- (void)finishDictation:(BOOL)automatic {
    _dGeneration++;
    [self stopWatchdog];
    float peak = _dictation.peakLevel;
    NSString *name = [NSString stringWithFormat:@"tynda-dictation-%lu.wav", (unsigned long)++_wavCounter];
    NSURL *wav = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    NSTimeInterval duration = [_dictation stopAndWriteWAV:wav];
    NSDate *sentAt = [NSDate date];
    _dState = DIdle;
    Log(@"dictation: recorded %.1fs, peak %.2f%@", duration, peak, automatic ? @" (auto-stop)" : @"");
    if (duration < 0.4 || peak < 0.05) {  // too short or nothing but silence
        [NSFileManager.defaultManager removeItemAtURL:wav error:nil];
        if (automatic) [self islandSay:L(@"Stopped: silence", @"Остановил запись: тишина") for:2.5];
        else if (duration >= 0.4) [self islandSay:L(@"Didn't catch that", @"Не расслышал") for:1.2];
        else [self islandToRest];
        [self demoFinish:@""];
        return;
    }
    _jobs++;
    [_island show:IslandTranscribing message:nil levelSource:nil];
    [_transcriber transcribe:wav.path completion:^(NSString *text, NSString *error) {
        self->_jobs--;
        [NSFileManager.defaultManager removeItemAtURL:wav error:nil];
        Log(@"dictation: %lu chars in %.1fs%@", (unsigned long)text.length, [[NSDate date] timeIntervalSinceDate:sentAt], error ? [@", error: " stringByAppendingString:error] : @"");
        BOOL recordingNow = self->_dState != DIdle;  // a new phrase is already being spoken
        if (error || text.length == 0) {
            if (!recordingNow) [self islandSay:error ?: L(@"Didn't catch that", @"Не расслышал") for:error ? 2.5 : 1.2];
            [self demoFinish:error ? [@"ERROR: " stringByAppendingString:error] : @""];
            return;
        }
        [self logDictation:text];
        self->_lastText = text;
        self->_copyLastItem.hidden = NO;
        if (DemoDictation()) {
            [self demoFinish:text];
        } else if (automatic) {
            [self copyLast];
            if (!recordingNow) [self islandSay:L(@"Stopped — the text is on the clipboard", @"Остановил запись — текст в буфере обмена") for:4];
            return;
        } else {
            [self paste:text];
        }
        if (!recordingNow) [self islandToRest];
    }];
}

- (void)copyLast {
    if (!_lastText) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:_lastText forType:NSPasteboardTypeString];
}

- (void)demoFinish:(NSString *)text {
    if (!_demoOut) return;
    [text writeToFile:_demoOut atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

// Every dictated phrase is also kept in a local file, in case a paste lands in the wrong place.
- (void)logDictation:(NSString *)text {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    NSString *line = [NSString stringWithFormat:@"- %@ — %@\n", [fmt stringFromDate:[NSDate date]], text];
    NSString *path = [NotesDir() URLByAppendingPathComponent:@"dictation.md"].path;
    [NSFileManager.defaultManager createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:nil];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

// Put the text on the clipboard, press ⌘V in the focused app, then give the clipboard back.
- (void)paste:(NSString *)text {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    NSMutableArray<NSDictionary<NSPasteboardType, NSData *> *> *saved = [NSMutableArray new];
    for (NSPasteboardItem *item in pb.pasteboardItems) {
        NSMutableDictionary *d = [NSMutableDictionary new];
        for (NSPasteboardType type in item.types) {
            NSData *data = [item dataForType:type];
            if (data) d[type] = data;
        }
        if (d.count) [saved addObject:d];
    }
    [pb clearContents];
    [pb setString:[text stringByAppendingString:@" "] forType:NSPasteboardTypeString];
    NSInteger ours = pb.changeCount;

    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, kKeyV, true);
    CGEventRef up = CGEventCreateKeyboardEvent(src, kKeyV, false);
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
    if (src) CFRelease(src);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (pb.changeCount != ours) return;  // the user copied something else meanwhile
        [pb clearContents];
        NSMutableArray *items = [NSMutableArray new];
        for (NSDictionary<NSPasteboardType, NSData *> *d in saved) {
            NSPasteboardItem *item = [NSPasteboardItem new];
            for (NSPasteboardType type in d) [item setData:d[type] forType:type];
            [items addObject:item];
        }
        if (items.count) [pb writeObjects:items];
    });
}

#pragma mark Meetings

- (void)openNotes {
    [NSFileManager.defaultManager createDirectoryAtURL:NotesDir() withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:NotesDir()];
}

- (void)toggle {
    if (_busy) return;
    _busy = YES;
    void (^done)(void) = ^{ self->_busy = NO; };
    if (_startedAt) [self stopRecording:done]; else [self startRecording:done];
}

- (void)refresh {
    BOOL recording = _startedAt != nil;
    NSString *title = @"";
    if (recording) {
        int s = (int)[[NSDate date] timeIntervalSinceDate:_startedAt];
        title = [NSString stringWithFormat:@" %d:%02d", s / 60, s % 60];
    } else if (_processing > 0) {
        title = @" …";
    }
    _statusItem.button.image = BarsImage(recording ? NSColor.systemRedColor : nil);
    _statusItem.button.imagePosition = NSImageLeft;
    _statusItem.button.title = title;
    _toggleItem.title = recording ? L(@"Stop and transcribe", @"Остановить и расшифровать") : L(@"Record meeting", @"Начать запись");
    if (recording) _infoItem.title = _system ? L(@"Recording", @"Идёт запись") : L(@"Recording (microphone only)", @"Идёт запись (только микрофон)");
    else _infoItem.title = _processing > 0 ? L(@"Transcribing…", @"Расшифровываю…") : L(@"Ready", @"Готов к записи");
}

// Completion blocks are always called on the main queue.
- (void)startRecording:(void (^)(void))done {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) {
                [self alert:L(@"No microphone access", @"Нет доступа к микрофону")
                       text:L(@"System Settings → Privacy & Security → Microphone → turn on Tynda.", @"Системные настройки → Конфиденциальность и безопасность → Микрофон → включить Tynda.")];
                done();
                return;
            }
            NSDateFormatter *fmt = [NSDateFormatter new];
            fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
            NSURL *dir = [NotesDir() URLByAppendingPathComponent:[fmt stringFromDate:[NSDate date]]];
            NSError *err = nil;
            [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err];
            AVAudioRecorder *rec = err ? nil : [[AVAudioRecorder alloc] initWithURL:[dir URLByAppendingPathComponent:@"mic.m4a"] settings:@{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @48000,
                AVNumberOfChannelsKey: @1,
                AVEncoderBitRateKey: @64000,
            } error:&err];
            if (!rec || ![rec record]) {
                [self alert:L(@"Could not start recording", @"Не удалось начать запись") text:err.localizedDescription ?: L(@"Microphone is unavailable.", @"Микрофон недоступен.")];
                done();
                return;
            }
            self->_mic = rec;
            self->_sessionDir = dir;
            self->_startedAt = [NSDate date];

            SystemAudioRecorder *sys = [SystemAudioRecorder new];
            [sys startWithURL:[dir URLByAppendingPathComponent:@"system.m4a"] completion:^(NSError *sysErr) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (sysErr) {
                        self->_system = nil;
                        [self alert:L(@"Recording the microphone only", @"Пишу только микрофон")
                               text:[NSString stringWithFormat:L(@"The other side is not being recorded: permission is missing. System Settings → Privacy & Security → Screen & System Audio Recording → turn on Tynda, then restart it.\n\n(%@)", @"Звук собеседников не записывается: нет разрешения. Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → включить Tynda, затем перезапустить его.\n\n(%@)"), sysErr.localizedDescription]];
                    } else {
                        self->_system = sys;
                    }
                    self->_timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
                    [self refresh];
                    done();
                });
            }];
        });
    }];
}

- (void)stopRecording:(void (^)(void))done {
    if (!_sessionDir || !_startedAt) { done(); return; }
    NSURL *dir = _sessionDir;
    NSDate *startedAt = _startedAt;
    SystemAudioRecorder *sys = _system;
    [_timer invalidate];
    _timer = nil;
    [_mic stop];
    _mic = nil;
    NSTimeInterval duration = [[NSDate date] timeIntervalSinceDate:startedAt];

    void (^finish)(BOOL) = ^(BOOL hasSystem) {
        dispatch_async(dispatch_get_main_queue(), ^{
            double offset = sys.firstSampleAt ? [sys.firstSampleAt timeIntervalSinceDate:startedAt] : 0;
            NSDictionary *meta = @{
                @"started_at": [[NSISO8601DateFormatter new] stringFromDate:startedAt],
                @"duration_sec": @(duration),
                @"system_offset_sec": @(offset),
                @"has_system": @(hasSystem),
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
            [data writeToURL:[dir URLByAppendingPathComponent:@"meta.json"] atomically:YES];
            self->_system = nil;
            self->_startedAt = nil;
            self->_sessionDir = nil;
            self->_processing += 1;
            [self refresh];
            [self process:dir];
            done();
        });
    };
    if (sys) [sys stopWithCompletion:finish]; else finish(NO);
}

- (void)process:(NSURL *)dir {
    NSString *python = PythonPath();
    if (!python) {
        _processing -= 1;
        [self refresh];
        [self alert:L(@"Could not start transcription", @"Не удалось запустить расшифровку") text:L(@"No Python with mlx-whisper found. Run install.sh from the project folder.", @"Не найден Python с mlx-whisper. Запусти install.sh из папки проекта.")];
        return;
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:python];
    task.arguments = @[[ScriptsDir() URLByAppendingPathComponent:@"process.py"].path, dir.path];
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"TYNDA_LANG"] = TyndaLang();
    // Notes can come from any command-line LLM: defaults write app.tynda.mac noteCommand "ollama run llama3.2"
    NSString *noteCommand = [NSUserDefaults.standardUserDefaults stringForKey:@"noteCommand"];
    if (noteCommand.length) env[@"TYNDA_NOTE_CMD"] = noteCommand;
    task.environment = env;
    NSString *logPath = [dir URLByAppendingPathComponent:@"process.log"].path;
    [NSFileManager.defaultManager createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (log) {
        task.standardOutput = log;
        task.standardError = log;
    }
    task.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_processing -= 1;
            [self refresh];
            BOOL ok = t.terminationStatus == 0;
            NSURL *noteURL = [dir URLByAppendingPathComponent:@"note.md"];
            NSURL *transcriptURL = [dir URLByAppendingPathComponent:@"transcript.md"];
            if (SelfTest()) { [NSApp terminate:nil]; return; }
            if ([NSFileManager.defaultManager fileExistsAtPath:noteURL.path]) [NSWorkspace.sharedWorkspace openURL:noteURL];
            else if ([NSFileManager.defaultManager fileExistsAtPath:transcriptURL.path]) [NSWorkspace.sharedWorkspace openURL:transcriptURL];
            [self notify:ok ? L(@"Note is ready", @"Конспект готов") : L(@"Something went wrong", @"Не всё получилось")
                    body:ok ? dir.lastPathComponent : L(@"See process.log in the recording's folder", @"Подробности в process.log в папке записи")];
        });
    };
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) {
        _processing -= 1;
        [self refresh];
        [self alert:L(@"Could not start transcription", @"Не удалось запустить расшифровку") text:err.localizedDescription];
    }
}

- (void)notify:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *c = [UNMutableNotificationContent new];
    c.title = title;
    c.body = body;
    [UNUserNotificationCenter.currentNotificationCenter
        addNotificationRequest:[UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString content:c trigger:nil]
         withCompletionHandler:nil];
}

- (void)alert:(NSString *)title text:(NSString *)text {
    if (SelfTest()) {
        fprintf(stderr, "ALERT: %s: %s\n", title.UTF8String, text.UTF8String);
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text;
    [a runModal];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!_startedAt) return NSTerminateNow;
    // Don't lose a recording in progress: finish the files first.
    [self stopRecording:^{ [NSApp replyToApplicationShouldTerminate:YES]; }];
    return NSTerminateLater;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
