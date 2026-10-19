// A macOS-only LLDB fixture. It simulates LinPad's TXM handshake, not iPad JIT.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static volatile long modeState;
static BOOL beganOn;

@interface AppDelegate : NSObject
+ (long)fastModeState;
+ (int)jitStatus;
+ (void)retryFastMode;
@end

@implementation AppDelegate
+ (long)fastModeState {
    return modeState;
}

+ (int)jitStatus {
    // Calling this before On would initialize LinPad's real JIT core. Fail the
    // fixture rather than allowing an accidental unconditional status probe.
    if (modeState != 2)
        _exit(96);
    puts("LINPAD_HOST_CORE_ON");
    fflush(stdout);
    return 1;
}

+ (void)retryFastMode {
    // In On mode this method must never run, even once.
    if (beganOn || modeState != 0)
        _exit(99);
    if (!NSThread.isMainThread)
        _exit(97);
    modeState = 1;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        register uint64_t address __asm__("x0") = 0;
        register uint64_t size __asm__("x1") = 32UL << 20;
        register uint64_t command __asm__("x16") = 1;
        __asm__ volatile("brk #0xf00d"
                         : "+r"(address)
                         : "r"(size), "r"(command)
                         : "memory");
        if (!address || address % 16384 || address + size > 0x1000000000ULL)
            _exit(98);
        for (uint64_t offset = 0; offset < size; offset += 16384) {
            if (*(const volatile unsigned char *)(uintptr_t)(address + offset) != 0x69)
                _exit(95);
        }
        command = 0;
        __asm__ volatile("brk #0xf00d" : : "r"(command) : "memory");
        modeState = 2;
        puts("LINPAD_HOST_PROTOCOL_ON");
        fflush(stdout);
    });
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        beganOn = argc == 2 && strcmp(argv[1], "on") == 0;
        modeState = beganOn ? 2 : 0;
        // Ensure the Foundation main-thread identity is initialized before attach.
        if (!NSThread.isMainThread)
            return 94;
        printf("LINPAD_HOST_READY state=%ld\n", modeState);
        fflush(stdout);
        for (;;)
            usleep(100000);
    }
}
