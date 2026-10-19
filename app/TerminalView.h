//
//  TerminalView.h
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

enum OverrideAppearance {
    OverrideAppearanceNone,
    OverrideAppearanceLight,
    OverrideAppearanceDark,
};

@interface TerminalView : UIView <UITextInput, WKScriptMessageHandler, UIScrollViewDelegate>

@property IBInspectable (nonatomic) BOOL canBecomeFirstResponder;

@property (nonatomic) CGFloat overrideFontSize;
@property (readonly) CGFloat effectiveFontSize;
@property (nonatomic) enum OverrideAppearance overrideAppearance;

@property (nonatomic) UIKeyboardAppearance keyboardAppearance;

@property (weak) IBOutlet UIInputView *inputAccessoryView;
@property (weak) IBOutlet UIButton *controlKey;

@property (nonatomic) Terminal *terminal;

// Internal numeric-only diagnostic hooks; absent Info opt-in makes them no-ops.
- (BOOL)numericViewportTraceEnabled;
- (void)traceKeyboardEvent:(NSUInteger)event screenFrame:(CGRect)screenFrame localFrame:(CGRect)localFrame padding:(CGFloat)padding controllerView:(UIView *)controllerView;

@end
