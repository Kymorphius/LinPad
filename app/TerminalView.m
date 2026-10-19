//
//  TerminalView.m
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import "ScrollbarView.h"
#import "TerminalView.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "NSObject+SaneKVO.h"
#import "TerminalViewportTraceValidation.h"
#import <QuartzCore/QuartzCore.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

struct rowcol {
    int row;
    int col;
};

@interface WeakScriptMessageHandler : NSObject <WKScriptMessageHandler>
@property (weak) id <WKScriptMessageHandler> handler;
@end
@implementation WeakScriptMessageHandler
- (instancetype)initWithHandler:(id <WKScriptMessageHandler>)handler {
    if (self = [super init]) {
        self.handler = handler;
    }
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    [self.handler userContentController:userContentController didReceiveScriptMessage:message];
}
@end

// The coordinator exists only in an explicitly flagged diagnostic build. Normal
// builds never install its bridge, create timers/observers, evaluate its JS, or
// touch its files. All coordinator state is confined to the main thread.
@interface LPViewportTrace : NSObject
+ (instancetype)enabledCoordinator;
- (void)installOwner:(TerminalView *)owner;
- (void)uninstallOwner:(TerminalView *)owner destroyed:(BOOL)destroyed;
- (void)receive:(WKScriptMessage *)message owner:(TerminalView *)owner;
- (void)recordOwner:(TerminalView *)owner event:(NSUInteger)event markJS:(BOOL)mark;
- (void)keyboardOwner:(TerminalView *)owner event:(NSUInteger)event screen:(CGRect)screen local:(CGRect)local padding:(CGFloat)padding controller:(UIView *)controller;
@end

@interface TerminalView ()

@property (nonatomic) NSMutableArray<UIKeyCommand *> *keyCommands;
@property ScrollbarView *scrollbarView;
@property (nonatomic) BOOL terminalFocused;
@property (nonatomic) NSUInteger webScrollUpdateDepth;
@property (nonatomic) BOOL numericTraceInstalled;
@property (nonatomic) BOOL numericTraceReady;
@property (strong, nonatomic) NSObject *numericTraceInstallation;
@property (nonatomic) BOOL numericTraceOwnsRun;

@property (nullable) NSString *markedText;
@property (nullable) NSString *selectedText;
@property UITextRange *markedRange;
@property UITextRange *selectedRange;

@property struct rowcol floatingCursor;
@property CGSize floatingCursorSensitivity;
@property CGSize actualFloatingCursorSensitivity;

@end

@interface LPViewportTrace ()
@property (weak) TerminalView *owner;
@property (weak) WKWebView *webView;
@property (weak) UIView *controllerView;
@property (strong) NSNumber *requestID;
@property (strong) NSObject *runToken;
@property (strong) NSNumber *lastRequestID;
@property (strong) NSNumber *build;
@property (strong) NSMutableArray<NSDictionary *> *rows;
@property (strong) dispatch_queue_t writer;
@property (strong) NSTimer *deadline;
@property (strong) CADisplayLink *displayLink;
@property (strong) id backgroundObserver;
@property (strong) id sceneBackgroundObserver;
@property NSTimeInterval begin;
@property NSTimeInterval burstEnd;
@property NSTimeInterval lastCheckpoint;
@property NSTimeInterval jsSend;
@property (strong) id jsCompletion;
@property (strong) id jsBegin;
@property NSUInteger sequence;
@property NSUInteger lastJSSequence;
@property NSUInteger bytes;
@property BOOL active;
@property BOOL complete;
@property NSUInteger stopReason;
@property CGRect keyboardEnd;
@property CGRect keyboardLocal;
@property CGFloat padding;
- (void)appendJS:(NSDictionary *)body;
- (void)append:(NSDictionary *)row;
- (void)checkpoint;
- (void)finish:(NSUInteger)reason;
@end

static id LPTraceFinite(double value) {
    return isfinite(value) ? @(value) : NSNull.null;
}
static NSArray *LPTracePoint(CGPoint value) {
    return @[LPTraceFinite(value.x), LPTraceFinite(value.y)];
}
static NSArray *LPTraceSize(CGSize value) {
    return @[LPTraceFinite(value.width), LPTraceFinite(value.height)];
}
static NSArray *LPTraceRect(CGRect value) {
    if (CGRectIsNull(value) || CGRectIsInfinite(value)) return @[NSNull.null, NSNull.null, NSNull.null, NSNull.null];
    return @[LPTraceFinite(value.origin.x), LPTraceFinite(value.origin.y), LPTraceFinite(value.size.width), LPTraceFinite(value.size.height)];
}
static NSArray *LPTraceInsets(UIEdgeInsets value) {
    return @[LPTraceFinite(value.top), LPTraceFinite(value.left), LPTraceFinite(value.bottom), LPTraceFinite(value.right)];
}
static NSArray *LPTraceWindowRect(UIView *view, UIWindow *window, BOOL presentation) {
    if (!view || !window) return LPTraceRect(CGRectNull);
    if (!presentation) return LPTraceRect([view convertRect:view.bounds toView:window]);
    CALayer *source = view.layer.presentationLayer;
    CALayer *target = window.layer.presentationLayer;
    return LPTraceRect(source && target ? [source convertRect:source.bounds toLayer:target] : CGRectNull);
}
// O_NOFOLLOW also prevents an arm/result symlink from reading another file.
static NSData *LPTraceReadBounded(NSString *path, NSUInteger maximum) {
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) return nil;
    struct stat info;
    if (fstat(descriptor, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > maximum) {
        close(descriptor); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(descriptor, (char *)data.mutableBytes + offset, data.length - offset);
        if (count <= 0) { close(descriptor); return nil; }
        offset += (NSUInteger)count;
    }
    close(descriptor);
    return data;
}

@implementation LPViewportTrace
+ (instancetype)enabledCoordinator {
    static LPViewportTrace *coordinator;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id flag = [NSBundle.mainBundle objectForInfoDictionaryKey:@"LinPadNumericViewportTrace"];
        if (flag == (__bridge id)kCFBooleanTrue) coordinator = [LPViewportTrace new];
    });
    return coordinator;
}
- (instancetype)init {
    if ((self = [super init])) {
        self.writer = dispatch_queue_create("LinPad.numeric-viewport-writer", DISPATCH_QUEUE_SERIAL);
        // Bundle version is a trusted numeric build identifier; diagnostics do
        // not include bundle strings or any terminal/user identifiers.
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        NSScanner *scanner = [NSScanner scannerWithString:[version isKindOfClass:NSString.class] ? version : @""];
        long long number = 0;
        if ([scanner scanLongLong:&number] && scanner.isAtEnd && number > 0 && number < 9007199254740992LL) self.build = @(number);
    }
    return self;
}
- (NSString *)directory {
    return [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"LinPadViewportTrace"];
}
- (void)installOwner:(TerminalView *)owner {
    WKWebView *web = owner.terminal.webView;
    id handler = [[WeakScriptMessageHandler alloc] initWithHandler:owner];
    [web.configuration.userContentController addScriptMessageHandler:handler name:@"viewportTrace"];
    owner.numericTraceInstalled = YES; owner.numericTraceReady = NO;
    NSObject *installation = [NSObject new]; owner.numericTraceInstallation = installation;
    __weak TerminalView *weakOwner = owner;
    [web evaluateJavaScript:@"exports.installNumericViewportTrace()" completionHandler:^(id result, NSError *error) {
        TerminalView *view = weakOwner;
        if (!view || view.numericTraceInstallation != installation) return;
        view.numericTraceReady = !error && result == (__bridge id)kCFBooleanTrue;
        if (!view.numericTraceReady) [self uninstallOwner:view destroyed:NO];
    }];
}
- (void)uninstallOwner:(TerminalView *)owner destroyed:(BOOL)destroyed {
    // A weak reference may already read nil while its owner is deallocating.
    // The per-view scalar claim still lets that path cancel immediately.
    if (self.active && owner.numericTraceOwnsRun) [self finish:destroyed ? 5 : 4];
    if (!owner.numericTraceInstalled) return;
    owner.numericTraceInstalled = NO; owner.numericTraceReady = NO; owner.numericTraceInstallation = nil;
    WKWebView *web = owner.terminal.webView;
    [web evaluateJavaScript:@"exports.uninstallNumericViewportTrace()" completionHandler:nil];
    [web.configuration.userContentController removeScriptMessageHandlerForName:@"viewportTrace"];
}
- (BOOL)eligible:(TerminalView *)owner web:(WKWebView *)web {
    UIWindow *window = owner.window;
    if (!owner.numericTraceInstalled || !owner.numericTraceReady || !owner.terminal.loaded || web != owner.terminal.webView || web.superview != owner.scrollbarView ||
        !window.isKeyWindow || !window.windowScene || UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        window.windowScene.activationState != UISceneActivationStateForegroundActive) return NO;
    for (UIView *view = owner; view; view = view.superview) if (view.hidden || view.alpha <= 0.01) return NO;
    CGRect intersection = CGRectIntersection([owner convertRect:owner.bounds toView:window], window.bounds);
    return !CGRectIsNull(intersection) && !CGRectIsInfinite(intersection) &&
        isfinite(intersection.size.width) && isfinite(intersection.size.height) &&
        intersection.size.width > 0 && intersection.size.height > 0;
}
- (void)receive:(WKScriptMessage *)message owner:(TerminalView *)owner {
    if (!message.frameInfo.isMainFrame || message.webView != owner.terminal.webView ||
        message.webView.superview != owner.scrollbarView || !LPTraceMessageValid(message.body)) return;
    NSDictionary *body = message.body;
    if ([body[@"kind"] integerValue] == 1) {
        if (self.active || ![self eligible:owner web:message.webView] || !self.build) return;
        NSString *path = [[self directory] stringByAppendingPathComponent:@"arm.json"];
        NSData *data = LPTraceReadBounded(path, 4096);
        NSDictionary *arm = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (!LPTraceArmValid(arm, self.build)) return;
        if (!self.lastRequestID) {
            NSData *previousData = LPTraceReadBounded([[self directory] stringByAppendingPathComponent:@"result.json"], 1048576);
            id previous = previousData ? [NSJSONSerialization JSONObjectWithData:previousData options:0 error:nil] : nil;
            if ([previous isKindOfClass:NSDictionary.class] && LPTraceInteger(previous[@"requestId"], 1, 9007199254740992.0)) self.lastRequestID = previous[@"requestId"];
        }
        if ([self.lastRequestID isEqualToNumber:arm[@"requestId"]]) return;
        // Remove only the fully validated, accepted arm file. No timer or
        // startup action reads it; failed/duplicate arms remain inspectable.
        if (unlink(path.fileSystemRepresentation) != 0) return;
        self.owner = owner; self.webView = message.webView; owner.numericTraceOwnsRun = YES;
        self.requestID = arm[@"requestId"]; self.lastRequestID = self.requestID;
        self.rows = [NSMutableArray new]; self.sequence = 0; self.bytes = 0;
        // Tap sequence belongs to the installed passive listener; each JS run
        // has an independent sample sequence beginning at one.
        self.lastJSSequence = 0; self.runToken = [NSObject new];
        self.begin = NSProcessInfo.processInfo.systemUptime;
        self.lastCheckpoint = -INFINITY; self.active = YES; self.complete = NO; self.stopReason = 0;
        self.keyboardEnd = CGRectNull; self.keyboardLocal = CGRectNull; self.padding = NAN;
        self.jsBegin = NSNull.null; self.jsCompletion = NSNull.null;
        UIResponder *responder = owner.nextResponder;
        while (responder && ![responder isKindOfClass:UIViewController.class]) responder = responder.nextResponder;
        self.controllerView = [(UIViewController *)responder viewIfLoaded];
        __weak LPViewportTrace *weakSelf = self;
        self.backgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf finish:3]; }];
        self.sceneBackgroundObserver = [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidEnterBackgroundNotification object:owner.window.windowScene queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf finish:3]; }];
        self.deadline = [NSTimer timerWithTimeInterval:60 repeats:NO block:^(NSTimer *timer) { [weakSelf finish:1]; }];
        [NSRunLoop.mainRunLoop addTimer:self.deadline forMode:NSRunLoopCommonModes];
        self.jsSend = NAN;
        [self appendJS:body];
        [self recordOwner:owner event:100 markJS:NO];
        NSNumber *request = self.requestID;
        NSObject *runToken = self.runToken;
        self.jsSend = NSProcessInfo.processInfo.systemUptime - self.begin;
        [message.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.startNumericViewportTrace(%.0f,60000,512)", request.doubleValue] completionHandler:^(id result, NSError *error) {
            if (!self.active || self.runToken != runToken) return;
            self.jsCompletion = @(NSProcessInfo.processInfo.systemUptime - self.begin);
            if (error || !LPTraceNumber(result) || [result doubleValue] < 0) { [self finish:6]; return; }
            self.jsBegin = result;
        }];
        return;
    }
    if (!self.active || self.owner != owner || self.webView != message.webView ||
        ![self.requestID isEqualToNumber:body[@"requestId"]] ||
        [body[@"seq"] unsignedIntegerValue] <= self.lastJSSequence) return;
    self.lastJSSequence = [body[@"seq"] unsignedIntegerValue];
    [self appendJS:body];
}
- (void)appendJS:(NSDictionary *)body {
    // Never persist the caller dictionary. Rebuild only the fixed validated
    // numeric whitelist and retain native receipt time separately from JS t.
    [self append:@{@"source": @1, @"seq": @(++self.sequence), @"event": body[@"event"],
        @"t": @(NSProcessInfo.processInfo.systemUptime - self.begin), @"jsTime": body[@"t"],
        @"jsSeq": body[@"seq"], @"x": body[@"x"], @"y": body[@"y"], @"mark": body[@"mark"], @"v": [body[@"v"] copy]}];
}
- (void)recordOwner:(TerminalView *)owner event:(NSUInteger)event markJS:(BOOL)mark {
    if (!self.active || self.owner != owner) return;
    if (NSProcessInfo.processInfo.systemUptime - self.begin >= 60) { [self finish:1]; return; }
    WKWebView *web = self.webView;
    UIWindow *window = owner.window;
    UIScrollView *inner = web.scrollView;
    ScrollbarView *outer = owner.scrollbarView;
    UIView *controller = self.controllerView;
    [self append:@{@"source": @0, @"seq": @(++self.sequence), @"event": @(event),
        @"t": @(NSProcessInfo.processInfo.systemUptime - self.begin),
        @"wkOffset": LPTracePoint(inner.contentOffset), @"wkInset": LPTraceInsets(inner.contentInset),
        @"wkAdjusted": LPTraceInsets(inner.adjustedContentInset), @"wkSize": LPTraceSize(inner.contentSize),
        @"wkBounds": LPTraceRect(inner.bounds), @"wkZoom": LPTraceFinite(inner.zoomScale),
        @"outerOffset": LPTracePoint(outer.contentOffset), @"outerSize": LPTraceSize(outer.contentSize),
        @"outerBounds": LPTraceRect(outer.bounds), @"depth": @(owner.webScrollUpdateDepth),
        @"wkRect": LPTraceWindowRect(web, window, NO), @"wkPresentation": LPTraceWindowRect(web, window, YES),
        @"viewRect": LPTraceWindowRect(owner, window, NO), @"viewPresentation": LPTraceWindowRect(owner, window, YES),
        @"controllerRect": LPTraceWindowRect(controller, window, NO), @"controllerPresentation": LPTraceWindowRect(controller, window, YES),
        @"windowBounds": LPTraceRect(window ? window.bounds : CGRectNull), @"screenBounds": LPTraceRect(window ? window.screen.bounds : CGRectNull),
        @"safeArea": LPTraceInsets(owner.safeAreaInsets), @"firstResponder": @(owner.isFirstResponder ? 1 : 0),
        @"keyboardEnd": LPTraceRect(self.keyboardEnd), @"keyboardLocal": LPTraceRect(self.keyboardLocal), @"padding": LPTraceFinite(self.padding)}];
    if (mark && self.active) {
        NSObject *runToken = self.runToken;
        [web evaluateJavaScript:[NSString stringWithFormat:@"exports.markNumericViewportTrace(%lu)", (unsigned long)event] completionHandler:^(id result, NSError *error) {
            if (error && self.active && self.runToken == runToken) [self finish:6];
        }];
    }
}
- (void)keyboardOwner:(TerminalView *)owner event:(NSUInteger)event screen:(CGRect)screen local:(CGRect)local padding:(CGFloat)padding controller:(UIView *)controller {
    if (!self.active || self.owner != owner) return;
    self.keyboardEnd = screen; self.keyboardLocal = local; self.padding = padding; self.controllerView = controller;
    [self recordOwner:owner event:event markJS:YES];
    if (self.active && (event == 120 || event == 121)) {
        self.burstEnd = MIN(self.begin + 60, NSProcessInfo.processInfo.systemUptime + 0.8);
        if (!self.displayLink) {
            self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayFrame:)];
            self.displayLink.preferredFramesPerSecond = 60;
            [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        }
    }
}
- (void)displayFrame:(CADisplayLink *)link {
    if (!self.active || NSProcessInfo.processInfo.systemUptime >= self.burstEnd) {
        [self.displayLink invalidate]; self.displayLink = nil; return;
    }
    TerminalView *owner = self.owner;
    if (!owner) { [self finish:5]; return; }
    [self recordOwner:owner event:126 markJS:NO];
}
- (void)append:(NSDictionary *)row {
    if (!self.active) return;
    if (NSProcessInfo.processInfo.systemUptime - self.begin >= 60) { [self finish:1]; return; }
    if (self.rows.count >= 512) { [self finish:2]; return; }
    if (!LPTraceRowValid(row)) { [self finish:8]; return; }
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if (!encoded) { [self finish:8]; return; }
    // Reserve metadata space and hard-limit even future additions to native
    // numeric arrays. The combined JS/native budget is enforced here only.
    if (!LPTraceBudgetAllows(self.rows.count, self.bytes, encoded.length)) { [self finish:7]; return; }
    self.bytes += encoded.length + 1;
    [self.rows addObject:row];
    if (self.rows.count >= 512) { [self finish:2]; return; }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastCheckpoint >= 0.5) { self.lastCheckpoint = now; [self checkpoint]; }
}
- (void)checkpoint {
    if (!self.requestID || !self.rows) return;
    NSDictionary *snapshot = @{@"schema": @1, @"build": self.build, @"requestId": self.requestID,
        @"complete": @(self.complete ? 1 : 0), @"stopReason": @(self.stopReason),
        @"count": @(self.rows.count), @"clock": @[LPTraceFinite(self.jsSend), self.jsCompletion ?: NSNull.null, self.jsBegin ?: NSNull.null],
        @"rows": [self.rows copy]};
    NSString *directory = [self directory];
    // Serial immutable snapshots cannot finish out of order. The terminal/main
    // thread only enqueues; JSON serialization and atomic I/O happen off-thread.
    dispatch_async(self.writer, ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (!data || data.length > 1048576) return;
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSString *path = [directory stringByAppendingPathComponent:@"result.json"];
        if ([data writeToFile:path options:NSDataWritingAtomic error:nil])
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
    });
}
- (void)finish:(NSUInteger)reason {
    if (!self.active) return;
    self.active = NO; self.complete = YES; self.stopReason = reason; self.runToken = nil;
    [self.deadline invalidate]; self.deadline = nil;
    [self.displayLink invalidate]; self.displayLink = nil;
    if (self.backgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:self.backgroundObserver];
    if (self.sceneBackgroundObserver) [NSNotificationCenter.defaultCenter removeObserver:self.sceneBackgroundObserver];
    self.backgroundObserver = nil; self.sceneBackgroundObserver = nil;
    WKWebView *web = self.webView;
    NSNumber *request = self.requestID;
    [web evaluateJavaScript:[NSString stringWithFormat:@"exports.stopNumericViewportTrace(%.0f)", request.doubleValue] completionHandler:nil];
    [self checkpoint];
    self.owner.numericTraceOwnsRun = NO;
    self.owner = nil; self.webView = nil; self.controllerView = nil;
}
@end

@implementation TerminalView
@synthesize inputDelegate;
@synthesize tokenizer;
@synthesize canBecomeFirstResponder;

- (void)awakeFromNib {
    [super awakeFromNib];
    self.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputAssistantItem.trailingBarButtonGroups = @[];

    ScrollbarView *scrollbarView = self.scrollbarView = [[ScrollbarView alloc] initWithFrame:self.bounds];
    scrollbarView.delegate = self;
    scrollbarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scrollbarView.bounces = NO;
    [self addSubview:scrollbarView];

    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"capsLockMapping", @"optionMapping", @"backtickMapEscape", @"overrideControlSpace"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_keyCommands = nil;
        });
    }];
    [prefs observe:@[@"colorScheme", @"fontFamily", @"fontSize", @"theme", @"cursorStyle", @"blinkCursor"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyle];
        });
    }];

    self.markedRange = [UITextRange new];
    self.selectedRange = [UITextRange new];
}

- (void)dealloc {
    [[LPViewportTrace enabledCoordinator] uninstallOwner:self destroyed:YES];
    self.terminal = nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (object == _terminal) {
        if (_terminal.loaded) {
            [self installTerminalView];
            [self _updateStyle];
        }
    }
}

static NSString *const HANDLERS[] = {@"syncFocus", @"focus", @"newScrollHeight", @"newScrollTop", @"openLink"};

- (void)setTerminal:(Terminal *)terminal {
    if (_terminal) {
        [_terminal removeObserver:self forKeyPath:@"loaded"];
        [self uninstallTerminalView];
    }

    _terminal = terminal;
    [_terminal addObserver:self forKeyPath:@"loaded" options:NSKeyValueObservingOptionInitial context:nil];
    if (_terminal.loaded)
        [self installTerminalView];
}

- (void)installTerminalView {
    NSAssert(_terminal.loaded, @"should probably not be installing a non-loaded terminal");
    UIView *superview = self.terminal.webView.superview;
    if (superview != nil) {
        NSAssert(superview == self.scrollbarView, @"installing terminal that is already installed elsewhere");
        return;
    }

    WKWebView *webView = _terminal.webView;
    _terminal.enableVoiceOverAnnounce = YES;
    webView.scrollView.scrollEnabled = NO;
    webView.scrollView.delaysContentTouches = NO;
    webView.scrollView.canCancelContentTouches = NO;
    webView.scrollView.panGestureRecognizer.enabled = NO;
    id <WKScriptMessageHandler> handler = [[WeakScriptMessageHandler alloc] initWithHandler:self];
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [webView.configuration.userContentController addScriptMessageHandler:handler name:HANDLERS[i]];
    }
    webView.frame = self.bounds;
    self.opaque = webView.opaque = NO;
    webView.backgroundColor = UIColor.clearColor;
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    self.scrollbarView.contentView = webView;
    [self.scrollbarView addSubview:webView];
    [[LPViewportTrace enabledCoordinator] installOwner:self];
}

- (void)uninstallTerminalView {
    // remove old terminal
    UIView *superview = _terminal.webView.superview;
    if (superview != self.scrollbarView) {
        NSAssert(superview == nil, @"uninstalling terminal that is installed elsewhere");
        return;
    }

    [[LPViewportTrace enabledCoordinator] uninstallOwner:self destroyed:NO];
    [_terminal.webView removeFromSuperview];
    self.scrollbarView.contentView = nil;
    for (int i = 0; i < sizeof(HANDLERS)/sizeof(HANDLERS[0]); i++) {
        [_terminal.webView.configuration.userContentController removeScriptMessageHandlerForName:HANDLERS[i]];
    }
    _terminal.enableVoiceOverAnnounce = NO;
}

#pragma mark Styling

- (void)_updateStyle {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    if (!self.terminal.loaded)
        return;
    UserPreferences *prefs = [UserPreferences shared];
    if (_overrideFontSize == prefs.fontSize.doubleValue)
        _overrideFontSize = 0;
    Palette *palette = prefs.palette;
    if (self.overrideAppearance != OverrideAppearanceNone) {
        palette = self.overrideAppearance == OverrideAppearanceLight ? prefs.theme.lightPalette : prefs.theme.darkPalette;
    }
    NSMutableDictionary<NSString *, id> *themeInfo = [@{
        @"fontFamily": prefs.fontFamily,
        @"fontSize": @(self.effectiveFontSize),
        @"foregroundColor": palette.foregroundColor,
        @"backgroundColor": palette.backgroundColor,
        @"blinkCursor": @(prefs.blinkCursor),
        @"cursorShape": prefs.htermCursorShape,
    } mutableCopy];
    if (prefs.palette.colorPaletteOverrides) {
        themeInfo[@"colorPaletteOverrides"] = palette.colorPaletteOverrides;
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:themeInfo options:0 error:nil] encoding:NSUTF8StringEncoding];
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.updateStyle(%@)", json] completionHandler:^(id result, NSError *error){
        [self updateFloatingCursorSensitivity];
    }];
}

- (void)setOverrideFontSize:(CGFloat)overrideFontSize {
    _overrideFontSize = overrideFontSize;
    [self _updateStyle];
}

- (void)setOverrideAppearance:(enum OverrideAppearance)overrideAppearance {
    _overrideAppearance = overrideAppearance;
    [self _updateStyle];
}

- (CGFloat)effectiveFontSize {
    if (self.overrideFontSize != 0)
        return self.overrideFontSize;
    return UserPreferences.shared.fontSize.doubleValue;
}

#pragma mark Focus and scrolling

- (void)setTerminalFocused:(BOOL)terminalFocused {
    [[LPViewportTrace enabledCoordinator] recordOwner:self event:103 markJS:NO];
    _terminalFocused = terminalFocused;
    NSString *script = terminalFocused ? @"exports.setFocused(true)" : @"exports.setFocused(false)";
    [self.terminal.webView evaluateJavaScript:script completionHandler:nil];
    [[LPViewportTrace enabledCoordinator] recordOwner:self event:104 markJS:NO];
}

- (BOOL)becomeFirstResponder {
    BOOL acquired = [super becomeFirstResponder];
    if (acquired) {
        self.terminalFocused = YES;
        [self reloadInputViews];
    }
    return acquired;
}
- (BOOL)resignFirstResponder {
    BOOL resigned = [super resignFirstResponder];
    if (resigned) self.terminalFocused = NO;
    return resigned;
}
- (void)windowDidBecomeKey:(NSNotification *)notif {
    self.terminalFocused = self.isFirstResponder;
}
- (void)windowDidResignKey:(NSNotification *)notif {
    self.terminalFocused = NO;
}

- (IBAction)loseFocus:(id)sender {
    [self resignFirstResponder];
}

- (void)willMoveToWindow:(UIWindow *)newWindow {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.window != nil) {
        [center removeObserver:self
                          name:UIWindowDidBecomeKeyNotification
                        object:self.window];
        [center removeObserver:self
                          name:UIWindowDidResignKeyNotification
                        object:self.window];
    }
    if (newWindow != nil) {
        [center addObserver:self
                   selector:@selector(windowDidBecomeKey:)
                       name:UIWindowDidBecomeKeyNotification
                     object:newWindow];
        [center addObserver:self
                   selector:@selector(windowDidResignKey:)
                       name:UIWindowDidResignKeyNotification
                     object:newWindow];
    }
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"viewportTrace"]) {
        [[LPViewportTrace enabledCoordinator] receive:message owner:self];
        return;
    }
    if ([message.name isEqualToString:@"syncFocus"]) {
        self.terminalFocused = self.terminalFocused;
    } else if ([message.name isEqualToString:@"focus"]) {
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:101 markJS:NO];
        // A genuine terminal-body tap is an explicit request even if UIKit kept
        // the responder while the software keyboard was dismissed.
        if (self.isFirstResponder) [self reloadInputViews];
        else [self becomeFirstResponder];
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:102 markJS:NO];
    } else if ([message.name isEqualToString:@"newScrollHeight"]) {
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:105 markJS:NO];
        self.webScrollUpdateDepth++;
        @try {
            self.scrollbarView.contentSize = CGSizeMake(0, [message.body doubleValue]);
        } @finally {
            self.webScrollUpdateDepth--;
        }
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:106 markJS:NO];
    } else if ([message.name isEqualToString:@"newScrollTop"]) {
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:107 markJS:NO];
        CGFloat newOffset = [message.body doubleValue];
        if (self.scrollbarView.contentOffset.y == newOffset) {
            [[LPViewportTrace enabledCoordinator] recordOwner:self event:108 markJS:NO];
            return;
        }
        self.webScrollUpdateDepth++;
        @try {
            [self.scrollbarView setContentOffset:CGPointMake(0, newOffset) animated:NO];
        } @finally {
            self.webScrollUpdateDepth--;
        }
        [[LPViewportTrace enabledCoordinator] recordOwner:self event:108 markJS:NO];
    } else if ([message.name isEqualToString:@"openLink"]) {
        [UIApplication openURL:message.body];
    }
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    [[LPViewportTrace enabledCoordinator] recordOwner:self event:109 markJS:NO];
    // Web-originated updates may already be stale by the time they reach us.
    // Keep ScrollbarView's frame compensation, but do not echo them back to JS.
    if (self.webScrollUpdateDepth != 0)
        return;
    [self.terminal.webView evaluateJavaScript:[NSString stringWithFormat:@"exports.newScrollTop(%f)", scrollView.contentOffset.y] completionHandler:nil];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [[LPViewportTrace enabledCoordinator] recordOwner:self event:110 markJS:NO];
}

- (BOOL)numericViewportTraceEnabled {
    return [LPViewportTrace enabledCoordinator] != nil;
}

- (void)traceKeyboardEvent:(NSUInteger)event screenFrame:(CGRect)screenFrame localFrame:(CGRect)localFrame padding:(CGFloat)padding controllerView:(UIView *)controllerView {
    [[LPViewportTrace enabledCoordinator] keyboardOwner:self event:event screen:screenFrame local:localFrame padding:padding controller:controllerView];
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    BOOL needsFirstResponderDance = self.isFirstResponder && _keyboardAppearance != keyboardAppearance;
    if (needsFirstResponderDance) {
        [self resignFirstResponder];
    }
    _keyboardAppearance = keyboardAppearance;
    if (needsFirstResponderDance) {
        [self becomeFirstResponder];
    }
    if (keyboardAppearance == UIKeyboardAppearanceLight) {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleBlack;
    } else {
        self.scrollbarView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    }
}

#pragma mark Keyboard Input

// implementing these makes a keyboard pop up when this view is first responder

- (void)insertText:(NSString *)text {
    self.markedText = nil;

    if (self.controlKey.highlighted)
        self.controlKey.selected = YES;
    if (self.controlKey.selected) {
        if (!self.controlKey.highlighted)
            self.controlKey.selected = NO;
        if (text.length == 1)
            return [self insertControlChar:[text characterAtIndex:0]];
    }

    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@"\r"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self.terminal sendInput:data];
}

- (void)insertControlChar:(char)ch {
    if (strchr(controlKeys, ch) != NULL) {
        if (ch == ' ') ch = '\0';
        if (ch == '2') ch = '@';
        if (ch == '6') ch = '^';
        if (ch != '\0')
            ch = toupper(ch) ^ 0x40;
        [self.terminal sendInput:[NSData dataWithBytes:&ch length:1]];
    }
}

- (void)deleteBackward {
    [self insertText:@"\x7f"];
}

- (BOOL)hasText {
    return YES; // it's always ok to send a "delete"
}

#pragma mark IME Input and Selection

- (void)setMarkedText:(nullable NSString *)markedText selectedRange:(NSRange)selectedRange {
    self.markedText = markedText;
}

- (void)unmarkText {
    [self insertText:self.markedText];
}

- (UITextRange *)markedTextRange {
    if (self.markedText != nil)
        return self.markedRange;
    return nil;
}

// The only reason to have this selected range is to prevent the "speak selection" context action from failing to get the current selection and falling back on calling copy:. It doesn't even have to work, it seems...

- (UITextRange *)selectedTextRange {
    return self.selectedRange;
}

- (NSString *)textInRange:(UITextRange *)range {
    if (range == self.markedRange)
        return self.markedText;
    if (range == self.selectedRange)
        return @"";
    return nil;
}

- (id)insertDictationResultPlaceholder {
    return @"";
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsertResult {
}

#pragma mark Keyboard Actions

- (void)paste:(id)sender {
    NSString *string = UIPasteboard.generalPasteboard.string;
    if (string) {
        [self insertText:string];
    }
}

- (void)copy:(id)sender {
    [self.terminal.webView evaluateJavaScript:@"exports.copy()" completionHandler:nil];
}

- (void)clearScrollback:(UIKeyCommand *)command {
    [self.terminal.webView evaluateJavaScript:@"exports.clearScrollback()" completionHandler:nil];
}

#pragma mark Floating cursor

- (void)updateFloatingCursorSensitivity {
    [self.terminal.webView evaluateJavaScript:@"exports.getCharacterSize()" completionHandler:^(NSArray *charSizeRaw, NSError *error) {
        if (error != nil) {
            NSLog(@"error getting character size: %@", error);
            return;
        }
        CGSize charSize = CGSizeMake([charSizeRaw[0] doubleValue], [charSizeRaw[1] doubleValue]);
        double sensitivity = 0.5;
        self.floatingCursorSensitivity = CGSizeMake(charSize.width / sensitivity, charSize.height / sensitivity);
    }];
}

- (struct rowcol)rowcolFromPoint:(CGPoint)point {
    CGSize sensitivity = self.actualFloatingCursorSensitivity;
    return (struct rowcol) {
        .row = (int) (-point.y / sensitivity.height),
        .col = (int) (point.x / sensitivity.width),
    };
}

- (void)beginFloatingCursorAtPoint:(CGPoint)point {
    self.actualFloatingCursorSensitivity = self.floatingCursorSensitivity;
    self.floatingCursor = [self rowcolFromPoint:point];
}

- (void)updateFloatingCursorAtPoint:(CGPoint)point {
    struct rowcol newPos = [self rowcolFromPoint:point];
    int rowDiff = newPos.row - self.floatingCursor.row;
    int colDiff = newPos.col - self.floatingCursor.col;
    NSMutableString *arrows = [NSMutableString string];
    for (int i = 0; i < abs(rowDiff); i++) {
        [arrows appendString:[self.terminal arrow:rowDiff > 0 ? 'A': 'B']];
    }
    for (int i = 0; i < abs(colDiff); i++) {
        [arrows appendString:[self.terminal arrow:colDiff > 0 ? 'C': 'D']];
    }
    [self insertText:arrows];
    self.floatingCursor = newPos;
}

- (void)endFloatingCursor {
    self.floatingCursor = (struct rowcol) {};
}

#pragma mark Keyboard Traits

- (UITextSmartDashesType)smartDashesType API_AVAILABLE(ios(11)) {
    return UITextSmartDashesTypeNo;
}
- (UITextSmartQuotesType)smartQuotesType API_AVAILABLE(ios(11)) {
    return UITextSmartQuotesTypeNo;
}
- (UITextSmartInsertDeleteType)smartInsertDeleteType API_AVAILABLE(ios(11)) {
    return UITextSmartInsertDeleteTypeNo;
}
- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}
- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}
// Apparently required on iOS 15+: https://stackoverflow.com/a/72359764
- (UITextSpellCheckingType)spellCheckingType {
    return UITextSpellCheckingTypeNo;
}

#pragma mark Hardware Keyboard

- (void)handleKeyCommand:(UIKeyCommand *)command {
    NSString *key = command.input;
    if (command.modifierFlags == 0) {
        if ([key isEqualToString:@"`"] && UserPreferences.shared.backtickMapEscape)
            key = UIKeyInputEscape;
        if ([key isEqualToString:UIKeyInputEscape])
            key = @"\x1b";
        else if ([key isEqualToString:UIKeyInputUpArrow])
            key = [self.terminal arrow:'A'];
        else if ([key isEqualToString:UIKeyInputDownArrow])
            key = [self.terminal arrow:'B'];
        else if ([key isEqualToString:UIKeyInputLeftArrow])
            key = [self.terminal arrow:'D'];
        else if ([key isEqualToString:UIKeyInputRightArrow])
            key = [self.terminal arrow:'C'];
        [self insertText:key];
    } else if (command.modifierFlags & UIKeyModifierShift) {
        [self insertText:[key uppercaseString]];
    } else if (command.modifierFlags & UIKeyModifierAlternate) {
        [self insertText:[@"\x1b" stringByAppendingString:key]];
    } else if (command.modifierFlags & UIKeyModifierAlphaShift) {
        [self handleCapsLockWithCommand:command];
    } else if (command.modifierFlags & UIKeyModifierControl || command.modifierFlags & UIKeyModifierAlphaShift) {
        if (key.length == 0)
            return;
        if ([key isEqualToString:@"2"])
            key = @"@";
        else if ([key isEqualToString:@"6"])
            key = @"^";
        else if ([key isEqualToString:@"-"])
            key = @"_";
        [self insertControlChar:[key characterAtIndex:0]];
    }
}

static const char *alphabet = "abcdefghijklmnopqrstuvwxyz";
static const char *controlKeys = "abcdefghijklmnopqrstuvwxyz@^26-=[]\\ ";
static const char *metaKeys = "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./";

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (_keyCommands != nil)
        return _keyCommands;
    _keyCommands = [NSMutableArray new];
    [self addKeys:controlKeys withModifiers:UIKeyModifierControl];
    for (NSString *specialKey in @[UIKeyInputEscape, UIKeyInputUpArrow, UIKeyInputDownArrow,
                                   UIKeyInputLeftArrow, UIKeyInputRightArrow, @"\t"]) {
        [self addKey:specialKey withModifiers:0];
    }
    if (UserPreferences.shared.capsLockMapping != CapsLockMapNone) {
        if (@available(iOS 13, *)); else {
            [self addKeys:controlKeys withModifiers:UIKeyModifierAlphaShift];
            [self addKeys:alphabet withModifiers:0];
            [self addKeys:alphabet withModifiers:UIKeyModifierShift];
            [self addKey:@"" withModifiers:UIKeyModifierAlphaShift]; // otherwise tap of caps lock can switch layouts
        }
    }
    if (UserPreferences.shared.optionMapping == OptionMapEsc) {
        [self addKeys:metaKeys withModifiers:UIKeyModifierAlternate];
    }
    if (UserPreferences.shared.backtickMapEscape) {
        [self addKey:@"`" withModifiers:0];
    }
    [_keyCommands addObject:[UIKeyCommand keyCommandWithInput:@"k"
                                                modifierFlags:UIKeyModifierCommand|UIKeyModifierShift
                                                       action:@selector(clearScrollback:)
                                         discoverabilityTitle:@"Clear Scrollback"]];
    return _keyCommands;
}

- (void)addKeys:(const char *)keys withModifiers:(UIKeyModifierFlags)modifiers {
    for (size_t i = 0; keys[i] != '\0'; i++) {
        [self addKey:[NSString stringWithFormat:@"%c", keys[i]] withModifiers:modifiers];
    }
}

- (void)addKey:(NSString *)key withModifiers:(UIKeyModifierFlags)modifiers {
    UIKeyCommand *command = [UIKeyCommand keyCommandWithInput:key
                                                modifierFlags:modifiers
                                                       action:@selector(handleKeyCommand:)];
    if (@available(iOS 15, *)) {
        command.wantsPriorityOverSystemBehavior = YES;
    }
    [_keyCommands addObject:command];
}

- (void)keyCommandTriggered:(UIKeyCommand *)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleKeyCommand:sender];
    });
}

- (void)handleCapsLockWithCommand:(UIKeyCommand *)command {
    CapsLockMapping target = UserPreferences.shared.capsLockMapping;
    NSString *newInput = command.input ? command.input : @"";
    UIKeyModifierFlags flags = command.modifierFlags;
    flags ^= UIKeyModifierAlphaShift;
    if(target == CapsLockMapEscape) {
        newInput = UIKeyInputEscape;
    } else if(target == CapsLockMapControl) {
        if([newInput length] == 0) {
            return;
        }
        flags |= UIKeyModifierControl;
    } else {
        return;
    }

    UIKeyCommand *newCommand = [UIKeyCommand keyCommandWithInput:newInput
                                                   modifierFlags:flags
                                                          action:@selector(keyCommandTriggered:)];
    [self handleKeyCommand:newCommand];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if (@available(iOS 13.4, *)) {
        UIKey *key = presses.anyObject.key;
        if (UserPreferences.shared.overrideControlSpace &&
            key.keyCode == UIKeyboardHIDUsageKeyboardSpacebar &&
            key.modifierFlags & UIKeyModifierControl) {
            return [self insertControlChar:' '];
        }
    }
    return [super pressesBegan:presses withEvent:event];
}

#pragma mark UITextInput stubs

#if 0
#define LogStub() NSLog(@"%s", __func__)
#else
#define LogStub()
#endif

- (NSWritingDirection)baseWritingDirectionForPosition:(nonnull UITextPosition *)position inDirection:(UITextStorageDirection)direction { LogStub(); return NSWritingDirectionLeftToRight; }
- (void)setBaseWritingDirection:(NSWritingDirection)writingDirection forRange:(nonnull UITextRange *)range { LogStub(); }
- (UITextPosition *)beginningOfDocument { LogStub(); return nil; }
- (CGRect)caretRectForPosition:(nonnull UITextPosition *)position { LogStub(); return CGRectZero; }
- (nullable UITextRange *)characterRangeAtPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextRange *)characterRangeByExtendingPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point { LogStub(); return nil; }
- (nullable UITextPosition *)closestPositionToPoint:(CGPoint)point withinRange:(nonnull UITextRange *)range { LogStub(); return nil; }
- (NSComparisonResult)comparePosition:(nonnull UITextPosition *)position toPosition:(nonnull UITextPosition *)other { LogStub(); return NSOrderedSame; }
- (UITextPosition *)endOfDocument { LogStub(); return nil; }
- (CGRect)firstRectForRange:(nonnull UITextRange *)range { LogStub(); return CGRectZero; }
- (NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); return nil; }
- (void)setMarkedTextStyle:(NSDictionary<NSAttributedStringKey,id> *)markedTextStyle { LogStub(); }
- (NSInteger)offsetFromPosition:(nonnull UITextPosition *)from toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return 0; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position inDirection:(UITextLayoutDirection)direction offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionFromPosition:(nonnull UITextPosition *)position offset:(NSInteger)offset { LogStub(); return nil; }
- (nullable UITextPosition *)positionWithinRange:(nonnull UITextRange *)range farthestInDirection:(UITextLayoutDirection)direction { LogStub(); return nil; }
- (void)replaceRange:(nonnull UITextRange *)range withText:(nonnull NSString *)text { LogStub(); }
- (void)setSelectedTextRange:(UITextRange *)selectedTextRange { LogStub(); }
- (nonnull NSArray<UITextSelectionRect *> *)selectionRectsForRange:(nonnull UITextRange *)range { LogStub(); return @[]; }
- (nullable UITextRange *)textRangeFromPosition:(nonnull UITextPosition *)fromPosition toPosition:(nonnull UITextPosition *)toPosition { LogStub(); return nil; }

// conforming to UITextInput makes this view default to being an accessibility element, which blocks selecting anything in it
- (BOOL)isAccessibilityElement { return NO; }

@end
