//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"
#import "AppDelegate.h"

TerminalViewController *currentTerminalViewController = NULL;

@interface SceneDelegate ()

@property NSString *terminalUUID;
@property (strong, nonatomic) UIViewController *desktopRoot;
@property (strong, nonatomic) TerminalViewController *classicTerminal;
@property (strong, nonatomic) UIViewController *fullscreenTerminal;
- (void)showDesktopWithCompletion:(void (^)(void))completion;
- (BOOL)showFullscreenTerminal:(UIViewController *)controller;

@end

static NSString *const TerminalUUID = @"TerminalUUID";

// Implemented in Swift (app/Desktop/DesktopBridge.swift) and looked up at runtime,
// because this file is also compiled into targets that don't link DesktopKit.
@protocol ISHDesktopBridge
+ (BOOL)isEnabled;
+ (UIViewController *)makeRootViewController;
@optional
+ (UIViewController *)makeRootViewControllerWithSwitchToTerminal:(BOOL (^)(UIViewController *))switchToTerminal
                                                 switchToDesktop:(void (^)(void))switchToDesktop
                                                adoptingTerminal:(UIViewController *)terminal;
+ (void)releaseTerminal:(UIViewController *)controller;
+ (BOOL)openURL:(NSURL *)url;
@end

static Class<ISHDesktopBridge> DesktopBridgeIfEnabled(void) {
    Class bridge = NSClassFromString(@"DesktopBridge");
    if (![bridge respondsToSelector:@selector(isEnabled)] || ![bridge respondsToSelector:@selector(makeRootViewController)])
        return nil;
    Class<ISHDesktopBridge> desktop = bridge;
    return [desktop isEnabled] ? desktop : nil;
}

static Class<ISHDesktopBridge> AvailableDesktopBridge(void) {
    Class bridge = NSClassFromString(@"DesktopBridge");
    return [bridge respondsToSelector:@selector(makeRootViewControllerWithSwitchToTerminal:switchToDesktop:adoptingTerminal:)] ? bridge : nil;
}

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
        return;
    }

    Class<ISHDesktopBridge> desktop = DesktopBridgeIfEnabled();
    if (desktop != nil) {
        [self switchToDesktop];
        [self openURLContexts:connectionOptions.URLContexts];
        return;
    }

    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if (![vc isKindOfClass:TerminalViewController.class])
        return;
    self.classicTerminal = vc;
    vc.sceneSession = session;
    if (session.stateRestorationActivity == nil) {
        [vc startNewSession];
    } else {
        self.terminalUUID = session.stateRestorationActivity.userInfo[TerminalUUID];
        [vc reconnectSessionFromTerminalUUID:
         [[NSUUID alloc] initWithUUIDString:self.terminalUUID]];
    }
    [self openURLContexts:connectionOptions.URLContexts];
}

- (void)switchToDesktop {
    [self showDesktopWithCompletion:nil];
}

- (void)showDesktopWithCompletion:(void (^)(void))completion {
    Class<ISHDesktopBridge> desktop = AvailableDesktopBridge();
    if (desktop == nil) return;
    if (!self.desktopRoot) {
        __weak SceneDelegate *weakSelf = self;
        TerminalViewController *adopted = self.classicTerminal;
        if (adopted) {
            [self.window endEditing:YES];
            [adopted adoptAsDesktopTerminal];
            if (currentTerminalViewController == adopted) currentTerminalViewController = nil;
            self.classicTerminal = nil;
        }
        self.desktopRoot = [desktop makeRootViewControllerWithSwitchToTerminal:^BOOL(UIViewController *controller) {
            return [weakSelf showFullscreenTerminal:controller];
        } switchToDesktop:^{
            [weakSelf switchToDesktop];
        } adoptingTerminal:adopted];
    }
    if (self.window.rootViewController == self.desktopRoot) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"desktop.enabled"];
        if (completion) completion();
        return;
    }
    void (^show)(void) = ^{
        if (currentTerminalViewController == self.classicTerminal)
            currentTerminalViewController = nil;
        if (self.fullscreenTerminal) {
            [desktop releaseTerminal:self.fullscreenTerminal];
            self.fullscreenTerminal = nil;
        }
        [self.window endEditing:YES];
        self.window.rootViewController = self.desktopRoot;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"desktop.enabled"];
        if (completion) completion();
    };
    UIViewController *outgoing = self.window.rootViewController;
    if (outgoing.presentedViewController)
        [outgoing dismissViewControllerAnimated:NO completion:show];
    else
        show();
}

- (BOOL)showFullscreenTerminal:(UIViewController *)controller {
    if (!controller || !self.desktopRoot || self.window.rootViewController != self.desktopRoot) return NO;
    [self.window endEditing:YES];
    self.fullscreenTerminal = controller;
    self.window.rootViewController = controller;
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"desktop.enabled"];
    return YES;
}

/// linpad:// links go to the desktop, which asks before acting on them.
- (void)openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    if (contexts.count == 0 || [NSUserDefaults.standardUserDefaults boolForKey:@"recovery"])
        return;
    Class<ISHDesktopBridge> desktop = AvailableDesktopBridge();
    if (desktop == nil || ![(Class) desktop respondsToSelector:@selector(openURL:)])
        return;
    BOOL accepted = NO;
    for (UIOpenURLContext *context in contexts)
        accepted = [desktop openURL:context.URL] || accepted;
    if (accepted)
        [self switchToDesktop];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    [self openURLContexts:URLContexts];
}

- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    NSUserActivity *activity = [[NSUserActivity alloc] initWithActivityType:@"app.ish.scene"];
    TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
    if ([vc isKindOfClass:TerminalViewController.class]) {
        self.terminalUUID = vc.sessionTerminalUUID.UUIDString;
        if (self.terminalUUID != nil) {
            [activity addUserInfoEntriesFromDictionary:@{TerminalUUID: self.terminalUUID}];
        }
    }
    return activity;
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;
    if (![terminalViewController isKindOfClass:TerminalViewController.class])
        return;
    currentTerminalViewController = terminalViewController;
}

- (void)sceneWillResignActive:(UIScene *)scene {
    TerminalViewController *terminalViewController = (TerminalViewController *) self.window.rootViewController;
    if (![terminalViewController isKindOfClass:TerminalViewController.class])
        return;

    if (currentTerminalViewController == terminalViewController) {
        currentTerminalViewController = NULL;
    }
}

@end
