#import <Foundation/Foundation.h>

// Ordinary builds return nil for the disabled numeric trace coordinator. Keep
// that behavior here while testing the unmodified production scroll methods.
@class TerminalView, WKScriptMessage;
@interface LPViewportTrace : NSObject
+ (instancetype)enabledCoordinator;
- (void)receive:(WKScriptMessage *)message owner:(TerminalView *)owner;
- (void)recordOwner:(TerminalView *)owner event:(NSUInteger)event markJS:(BOOL)mark;
@end
@implementation LPViewportTrace
+ (instancetype)enabledCoordinator { return nil; }
- (void)receive:(WKScriptMessage *)message owner:(TerminalView *)owner {}
- (void)recordOwner:(TerminalView *)owner event:(NSUInteger)event markJS:(BOOL)mark {}
@end

// Tiny scroll-view doubles provide only the synchronous delegate behavior under
// test. The included bridge and frame-compensation methods are production code.
typedef NSPoint CGPoint;
typedef NSSize CGSize;
typedef NSRect CGRect;
#define CGPointMake NSMakePoint
#define CGSizeMake NSMakeSize

@class UIScrollView;
@protocol UIScrollViewDelegate <NSObject>
- (void)scrollViewDidScroll:(UIScrollView *)scrollView;
@end

@interface FakeView : NSObject
@property CGRect frame;
@end
@implementation FakeView
@end

@interface UIScrollView : NSObject
@property (nonatomic) CGPoint contentOffset;
@property (nonatomic) CGSize contentSize;
@property CGFloat viewportHeight;
@property (weak) id<UIScrollViewDelegate> delegate;
@property (copy) void (^beforeOffsetNotification)(void);
@property (copy) void (^beforeSizeClamp)(void);
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated;
@end
@implementation UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    _contentOffset = offset;
    if (self.beforeOffsetNotification) self.beforeOffsetNotification();
    [self.delegate scrollViewDidScroll:self];
}
- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    self.contentOffset = offset;
}
- (void)setContentSize:(CGSize)size {
    _contentSize = size;
    if (self.beforeSizeClamp) self.beforeSizeClamp();
    CGFloat maximum = MAX(0, size.height - self.viewportHeight);
    if (self.contentOffset.y > maximum)
        self.contentOffset = CGPointMake(self.contentOffset.x, maximum);
}
@end

@interface ScrollbarView : UIScrollView
@property FakeView *contentView;
@property CGPoint contentViewOrigin;
@end
@implementation ScrollbarView
@end

@interface ScrollbarViewDelegate : NSObject <UIScrollViewDelegate>
@property (weak) id<UIScrollViewDelegate> innerDelegate;
@end
@implementation ScrollbarViewDelegate
#include "scrollbar-scroll-method.inc"
@end

@interface FakeWebView : NSObject
@property CGFloat domOffset;
@property NSMutableArray<NSNumber *> *writes;
- (void)evaluateJavaScript:(NSString *)script completionHandler:(id)completion;
@end
@implementation FakeWebView
- (instancetype)init {
    if ((self = [super init])) _writes = [NSMutableArray new];
    return self;
}
- (void)evaluateJavaScript:(NSString *)script completionHandler:(id)completion {
    NSString *prefix = @"exports.newScrollTop(";
    NSCAssert([script hasPrefix:prefix] && [script hasSuffix:@")"], @"unexpected script");
    self.domOffset = [[script substringFromIndex:prefix.length] doubleValue];
    [self.writes addObject:@(self.domOffset)];
}
@end

@interface FakeTerminal : NSObject
@property FakeWebView *webView;
@end
@implementation FakeTerminal
@end

@interface WKUserContentController : NSObject
@end
@implementation WKUserContentController
@end
@interface WKScriptMessage : NSObject
@property NSString *name;
@property id body;
@end
@implementation WKScriptMessage
@end
@interface UIApplication : NSObject
+ (void)openURL:(id)url;
@end
@implementation UIApplication
+ (void)openURL:(id)url {}
@end

@interface TerminalView : NSObject <UIScrollViewDelegate>
@property ScrollbarView *scrollbarView;
@property FakeTerminal *terminal;
@property BOOL terminalFocused;
@property NSUInteger webScrollUpdateDepth;
- (BOOL)isFirstResponder;
- (BOOL)becomeFirstResponder;
- (void)reloadInputViews;
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message;
@end
@implementation TerminalView
- (BOOL)isFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (void)reloadInputViews {}
#if TEST_LEGACY_SCROLL_ECHO
#include "terminal-scroll-sync-legacy-methods.inc"
#else
#include "terminal-scroll-sync-methods.inc"
#endif
@end

static void Check(BOOL value, NSString *message) {
    if (!value) {
        fprintf(stderr, "%s\n", message.UTF8String);
        exit(1);
    }
}

static void SendWeb(TerminalView *view, NSString *name, CGFloat number) {
    WKScriptMessage *message = [WKScriptMessage new];
    message.name = name;
    message.body = @(number);
    [view userContentController:nil didReceiveScriptMessage:message];
}

static void CheckPinned(TerminalView *view) {
    ScrollbarView *scroll = view.scrollbarView;
    Check(scroll.contentView.frame.origin.x == scroll.contentOffset.x + scroll.contentViewOrigin.x,
          @"outer delegate must pin the WebView horizontally");
    Check(scroll.contentView.frame.origin.y == scroll.contentOffset.y + scroll.contentViewOrigin.y,
          @"outer delegate must pin the WebView vertically");
}

static TerminalView *MakeView(ScrollbarViewDelegate **outer) {
    TerminalView *view = [TerminalView new];
    view.terminal = [FakeTerminal new];
    view.terminal.webView = [FakeWebView new];
    view.scrollbarView = [ScrollbarView new];
    view.scrollbarView.viewportHeight = 100;
    view.scrollbarView.contentSize = CGSizeMake(0, 1000);
    view.scrollbarView.contentView = [FakeView new];
    view.scrollbarView.contentViewOrigin = CGPointMake(7, 11);
    view.scrollbarView.contentView.frame = NSMakeRect(7, 11, 320, 100);
    *outer = [ScrollbarViewDelegate new];
    (*outer).innerDelegate = view;
    view.scrollbarView.delegate = *outer;
    return view;
}

int main(void) {
    @autoreleasepool {
        ScrollbarViewDelegate *outer;
        TerminalView *view = MakeView(&outer);
        FakeWebView *web = view.terminal.webView;

        // JS already reached B while its earlier A/B messages waited for native.
        web.domOffset = 200;
        SendWeb(view, @"newScrollTop", 100);
        CheckPinned(view);
        SendWeb(view, @"newScrollTop", 200);
        CheckPinned(view);
#if TEST_LEGACY_SCROLL_ECHO
        Check([web.writes isEqualToArray:@[@100, @200]], @"negative control must replay stale A then B");
#else
        Check(web.writes.count == 0, @"web A/B packets must not echo into DOM already at B");
#endif
        Check(web.domOffset == 200, @"DOM must finish at B");
        Check(view.webScrollUpdateDepth == 0, @"web offset guard must finish balanced");

        // A Web-originated height shrink may synchronously clamp native offset.
        [web.writes removeAllObjects];
        web.domOffset = 70;
        SendWeb(view, @"newScrollHeight", 150);
        CheckPinned(view);
#if TEST_LEGACY_SCROLL_ECHO
        Check([web.writes isEqualToArray:@[@50]], @"negative control must echo the height clamp");
        Check(web.domOffset == 50, @"negative control should overwrite the newer DOM position");
#else
        Check(web.writes.count == 0, @"height clamp must not echo into DOM");
        Check(web.domOffset == 70, @"height clamp must preserve the newer DOM position");
#endif
        Check(view.webScrollUpdateDepth == 0, @"web height guard must finish balanced");

        // Reentrant Web updates must not clear the enclosing update's guard.
        [web.writes removeAllObjects];
        __weak TerminalView *weakView = view;
        view.scrollbarView.beforeSizeClamp = ^{
            TerminalView *strongView = weakView;
            Check(strongView.webScrollUpdateDepth == 1, @"outer height guard should be active");
            SendWeb(strongView, @"newScrollTop", 30);
            Check(strongView.webScrollUpdateDepth == 1, @"nested update must retain outer guard");
            [strongView.scrollbarView.delegate scrollViewDidScroll:strongView.scrollbarView];
        };
        SendWeb(view, @"newScrollHeight", 200);
        view.scrollbarView.beforeSizeClamp = nil;
        CheckPinned(view);
#if !TEST_LEGACY_SCROLL_ECHO
        Check(web.writes.count == 0, @"nested updates must remain silent");
#endif
        Check(view.webScrollUpdateDepth == 0, @"nested guards must finish balanced");

        // Both guards must unwind when the nested mutation raises an exception.
        view.scrollbarView.beforeSizeClamp = ^{ SendWeb(weakView, @"newScrollTop", 40); };
        view.scrollbarView.beforeOffsetNotification = ^{
            @throw [NSException exceptionWithName:@"SyntheticScrollError" reason:nil userInfo:nil];
        };
        BOOL caught = NO;
        @try { SendWeb(view, @"newScrollHeight", 300); }
        @catch (NSException *exception) { caught = [exception.name isEqualToString:@"SyntheticScrollError"]; }
        view.scrollbarView.beforeSizeClamp = nil;
        view.scrollbarView.beforeOffsetNotification = nil;
        Check(caught, @"test must exercise the exception path");
        Check(view.webScrollUpdateDepth == 0, @"exception must unwind all web guards");

        // Native drags/deceleration/accessibility still forward after cleanup.
        [web.writes removeAllObjects];
        view.scrollbarView.contentOffset = CGPointMake(3, 75);
        CheckPinned(view);
        Check([web.writes isEqualToArray:@[@75]], @"native offset C must still reach JavaScript");
        Check(web.domOffset == 75, @"native offset must update DOM");

        // Matching Web packets are a no-op and must not leave a guard behind.
        [web.writes removeAllObjects];
        SendWeb(view, @"newScrollTop", 75);
        Check(web.writes.count == 0 && view.webScrollUpdateDepth == 0, @"equal offset should remain a no-op");
        puts(TEST_LEGACY_SCROLL_ECHO ?
             "PASS: stale-scroll negative control reproduced A/B echo" :
             "PASS: production native scroll sync, frame pinning, nested guards and cleanup");
    }
    return 0;
}
