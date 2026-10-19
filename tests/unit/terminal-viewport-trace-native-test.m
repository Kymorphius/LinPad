#import "TerminalViewportTraceValidation.h"
#include <assert.h>
static NSMutableDictionary *message(void) {
    NSMutableArray *values = [NSMutableArray new];
    for (int index = 0; index < 39; index++) [values addObject:index % 2 ? NSNull.null : @(index)];
    return [@{@"kind": @1, @"requestId": @0, @"seq": @1, @"event": @1, @"t": @0.2, @"x": @1, @"y": @2, @"mark": @0, @"v": values} mutableCopy];
}
int main(void) { @autoreleasepool {
    NSDictionary *valid = @{@"schema": @1, @"requestId": @123, @"build": @4448};
    assert(LPTraceArmValid(valid, @4448));
    assert(!LPTraceArmValid(valid, @4447));
    assert(!LPTraceArmValid(@{@"schema": @1, @"requestId": @YES, @"build": @4448}, @4448));
    assert(!LPTraceArmValid(@{@"schema": @1, @"requestId": @9007199254740992ULL, @"build": @4448}, @4448));
    assert(!LPTraceArmValid(@{@"schema": @1, @"requestId": @1.5, @"build": @4448}, @4448));
    assert(!LPTraceArmValid(@{@"schema": @1, @"requestId": @1, @"build": @4448, @"text": @"private"}, @4448));
    assert(!LPTraceArmValid(@"text", @4448));
    assert(!LPTraceArmValid(NSNull.null, @4448));
    NSMutableDictionary *sample = message();
    assert(LPTraceMessageValid(sample));
    NSMutableDictionary *kindThree = [sample mutableCopy]; kindThree[@"kind"] = @3;
    assert(!LPTraceMessageValid(kindThree));
    for (NSString *key in @[@"kind", @"requestId", @"seq", @"event", @"t", @"x", @"y", @"mark"]) {
        NSMutableDictionary *copy = [sample mutableCopy]; copy[key] = @YES;
        assert(!LPTraceMessageValid(copy)); copy[key] = @"private"; assert(!LPTraceMessageValid(copy));
    }
    NSMutableDictionary *bad = [sample mutableCopy]; bad[@"extra"] = @0; assert(!LPTraceMessageValid(bad));
    for (id wrong in @[@[], @[@1], @"text", NSNull.null]) { bad = [sample mutableCopy]; bad[@"v"] = wrong; assert(!LPTraceMessageValid(bad)); }
    for (id wrong in @[@YES, @"private", @[@1], @(NAN), @(INFINITY)]) {
        NSMutableArray *values = [sample[@"v"] mutableCopy]; values[38] = wrong; bad = [sample mutableCopy]; bad[@"v"] = values; assert(!LPTraceMessageValid(bad));
    }
    sample[@"kind"] = @2; sample[@"requestId"] = @123; sample[@"event"] = @10; sample[@"mark"] = @120;
    assert(LPTraceMessageValid(sample));
    sample[@"mark"] = @0; assert(!LPTraceMessageValid(sample));
    sample[@"event"] = @4; assert(LPTraceMessageValid(sample));
    sample[@"requestId"] = @0; assert(!LPTraceMessageValid(sample));
    NSDictionary *row = @{@"source": @1, @"seq": @1, @"event": @4, @"t": @0.1, @"jsTime": @123, @"jsSeq": @1, @"x": NSNull.null, @"y": NSNull.null, @"mark": @0, @"v": message()[@"v"]};
    assert(LPTraceRowValid(row));
    bad = [row mutableCopy]; bad[@"text"] = @"private"; assert(!LPTraceRowValid(bad));
    bad = [row mutableCopy]; bad[@"v"] = @[@"private"]; assert(!LPTraceRowValid(bad));
    NSMutableDictionary *nativeRow = [@{@"source": @0, @"seq": @1, @"event": @120, @"t": @0.1, @"wkZoom": @1, @"depth": @0, @"firstResponder": @1, @"padding": NSNull.null} mutableCopy];
    for (NSString *key in @[@"wkOffset", @"wkSize", @"outerOffset", @"outerSize"]) nativeRow[key] = @[@0, @1];
    for (NSString *key in @[@"wkInset", @"wkAdjusted", @"wkBounds", @"outerBounds", @"wkRect", @"wkPresentation", @"viewRect", @"viewPresentation", @"controllerRect", @"controllerPresentation", @"windowBounds", @"screenBounds", @"safeArea", @"keyboardEnd", @"keyboardLocal"]) nativeRow[key] = @[@0, @1, @2, NSNull.null];
    assert(LPTraceRowValid(nativeRow));
    nativeRow[@"event"] = @111; assert(!LPTraceRowValid(nativeRow)); nativeRow[@"event"] = @120;
    nativeRow[@"wkRect"] = @[@0, @1, @2, @"private"]; assert(!LPTraceRowValid(nativeRow));
    assert(LPTraceBudgetAllows(511, 0, 100));
    assert(!LPTraceBudgetAllows(512, 0, 100));
    assert(LPTraceBudgetAllows(0, 1048576 - 4096 - 101, 100));
    assert(!LPTraceBudgetAllows(0, 1048576 - 4096 - 100, 100));
    assert(!LPTraceBudgetAllows(0, NSUIntegerMax, NSUIntegerMax));
    puts("PASS: exact numeric arm/message/row schemas and hard row/file budgets reject malformed or private payloads");
} }
