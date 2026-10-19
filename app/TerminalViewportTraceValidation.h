// Strict numeric-only boundary shared by the optional viewport recorder and host tests.
#ifndef TERMINAL_VIEWPORT_TRACE_VALIDATION_H
#define TERMINAL_VIEWPORT_TRACE_VALIDATION_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

static inline BOOL LPTraceNumber(id value) {
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        isfinite([value doubleValue]);
}
static inline BOOL LPTraceInteger(id value, double minimum, double maximumExclusive) {
    return LPTraceNumber(value) && [value doubleValue] >= minimum &&
        [value doubleValue] < maximumExclusive && floor([value doubleValue]) == [value doubleValue];
}
static inline BOOL LPTraceExactKeys(NSDictionary *value, NSArray<NSString *> *keys) {
    return [value isKindOfClass:NSDictionary.class] && value.count == keys.count &&
        [[NSSet setWithArray:value.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}
static inline BOOL LPTraceNullableNumber(id value) {
    return value == NSNull.null || LPTraceNumber(value);
}
static inline BOOL LPTraceArmValid(id value, NSNumber *build) {
    return LPTraceExactKeys(value, @[@"schema", @"requestId", @"build"]) &&
        LPTraceInteger(value[@"schema"], 1, 2) &&
        LPTraceInteger(value[@"requestId"], 1, 9007199254740992.0) &&
        LPTraceInteger(value[@"build"], 1, 9007199254740992.0) &&
        [value[@"build"] isEqualToNumber:build];
}
static inline BOOL LPTraceNumericArray(id value, NSUInteger count) {
    if (![value isKindOfClass:NSArray.class] || [value count] != count) return NO;
    for (id number in value) if (!LPTraceNullableNumber(number)) return NO;
    return YES;
}
static inline BOOL LPTraceRowValid(NSDictionary *row) {
    if (![row isKindOfClass:NSDictionary.class] || !LPTraceInteger(row[@"source"], 0, 2) ||
        !LPTraceInteger(row[@"seq"], 1, 9007199254740992.0) || !LPTraceNumber(row[@"t"]) || [row[@"t"] doubleValue] < 0) return NO;
    if ([row[@"source"] integerValue] == 1) {
        return LPTraceExactKeys(row, @[@"source", @"seq", @"event", @"t", @"jsTime", @"jsSeq", @"x", @"y", @"mark", @"v"]) &&
            LPTraceInteger(row[@"event"], 1, 13) && LPTraceNumber(row[@"jsTime"]) && [row[@"jsTime"] doubleValue] >= 0 &&
            LPTraceInteger(row[@"jsSeq"], 1, 9007199254740992.0) && LPTraceNullableNumber(row[@"x"]) && LPTraceNullableNumber(row[@"y"]) &&
            LPTraceInteger(row[@"mark"], 0, 9007199254740992.0) && LPTraceNumericArray(row[@"v"], 39);
    }
    NSArray *pairs = @[@"wkOffset", @"wkSize", @"outerOffset", @"outerSize"];
    NSArray *quads = @[@"wkInset", @"wkAdjusted", @"wkBounds", @"outerBounds", @"wkRect", @"wkPresentation", @"viewRect", @"viewPresentation", @"controllerRect", @"controllerPresentation", @"windowBounds", @"screenBounds", @"safeArea", @"keyboardEnd", @"keyboardLocal"];
    NSMutableArray *keys = [@[@"source", @"seq", @"event", @"t", @"wkZoom", @"depth", @"firstResponder", @"padding"] mutableCopy];
    [keys addObjectsFromArray:pairs]; [keys addObjectsFromArray:quads];
    if (!LPTraceExactKeys(row, keys) || !LPTraceInteger(row[@"event"], 100, 127) ||
        !(([row[@"event"] integerValue] >= 100 && [row[@"event"] integerValue] <= 110) ||
          ([row[@"event"] integerValue] >= 120 && [row[@"event"] integerValue] <= 126)) ||
        !LPTraceNullableNumber(row[@"wkZoom"]) || !LPTraceInteger(row[@"depth"], 0, 9007199254740992.0) ||
        !LPTraceInteger(row[@"firstResponder"], 0, 2) || !LPTraceNullableNumber(row[@"padding"])) return NO;
    for (NSString *key in pairs) if (!LPTraceNumericArray(row[key], 2)) return NO;
    for (NSString *key in quads) if (!LPTraceNumericArray(row[key], 4)) return NO;
    return YES;
}
static inline BOOL LPTraceBudgetAllows(NSUInteger count, NSUInteger bytes, NSUInteger rowBytes) {
    return count < 512 && bytes <= 1048576 - 4096 && rowBytes < 1048576 - 4096 - bytes;
}
static inline BOOL LPTraceMessageValid(id value) {
    if (!LPTraceExactKeys(value, @[@"kind", @"requestId", @"seq", @"event", @"t", @"x", @"y", @"mark", @"v"]) ||
        !LPTraceInteger(value[@"kind"], 1, 3) ||
        !LPTraceInteger(value[@"requestId"], 0, 9007199254740992.0) ||
        !LPTraceInteger(value[@"seq"], 1, 9007199254740992.0) ||
        !LPTraceInteger(value[@"event"], 1, 13) || !LPTraceNumber(value[@"t"]) ||
        [value[@"t"] doubleValue] < 0 || !LPTraceNullableNumber(value[@"x"]) ||
        !LPTraceNullableNumber(value[@"y"]) || !LPTraceInteger(value[@"mark"], 0, 9007199254740992.0) ||
        ![value[@"v"] isKindOfClass:NSArray.class] || [value[@"v"] count] != 39) return NO;
    for (id number in value[@"v"]) if (!LPTraceNullableNumber(number)) return NO;
    NSInteger event = [value[@"event"] integerValue];
    if ((event == 10) != ([value[@"mark"] doubleValue] > 0)) return NO;
    if ([value[@"kind"] integerValue] == 1)
        return event == 1 && [value[@"requestId"] doubleValue] == 0 &&
            LPTraceNumber(value[@"x"]) && LPTraceNumber(value[@"y"]);
    return event >= 2 && [value[@"requestId"] doubleValue] > 0;
}
#endif
