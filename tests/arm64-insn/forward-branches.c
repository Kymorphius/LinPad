// Exact-oracle driver for forward-branches.S. Linux needs no libc or guest
// compiler; the same assembly is also built and run natively on Apple Silicon.
// See forward-branches.sh for bounded baseline/candidate execution.
#ifdef __APPLE__
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <unistd.h>
#endif

typedef __UINT64_TYPE__ u64;
typedef __UINT32_TYPE__ u32;
typedef __INT64_TYPE__ s64;
typedef __SIZE_TYPE__ usize;

extern u64 fb_conditions(u64, u64);
extern u64 fb_compare(u64);
extern u64 fb_testbit(u64);
extern u64 fb_nested(u64);
extern u64 fb_flags_mem(u64, u64 *);
extern u64 fb_backedges(u64);
extern u64 fb_self_always(void);
extern u64 fb_interior(u64);
extern u64 fb_interior_entry(u64);
extern u64 fb_page_edge(u64);
extern u64 fb_long_path(u64);

#ifndef __APPLE__
static s64 syscall6(u64 number, u64 a, u64 b, u64 c, u64 d, u64 e, u64 f) {
    register u64 x0 __asm__("x0") = a;
    register u64 x1 __asm__("x1") = b;
    register u64 x2 __asm__("x2") = c;
    register u64 x3 __asm__("x3") = d;
    register u64 x4 __asm__("x4") = e;
    register u64 x5 __asm__("x5") = f;
    register u64 x8 __asm__("x8") = number;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3),
                     "r"(x4), "r"(x5), "r"(x8) : "memory", "cc");
    return (s64) x0;
}
#endif

static void output(const char *text) {
    usize length = 0;
    while (text[length])
        length++;
    while (length) {
#ifdef __APPLE__
        s64 done = write(1, text, length);
#else
        s64 done = syscall6(64, 1, (u64) text, length, 0, 0, 0);
#endif
        if (done <= 0)
            return;
        text += done;
        length -= (usize) done;
    }
}

static void hex(u64 value) {
    char text[19];
    text[0] = '0'; text[1] = 'x'; text[18] = 0;
    const char *digits = "0123456789abcdef";
    for (unsigned i = 0; i < 16; i++)
        text[17 - i] = digits[(value >> (i * 4)) & 15];
    output(text);
}

static int expect(const char *name, u64 got, u64 wanted) {
    if (got == wanted)
        return 0;
    output(name); output(" FAIL got="); hex(got);
    output(" expected="); hex(wanted); output("\n");
    return 1;
}

static void passed(const char *name) {
    output(name); output(" ok\n");
}

static u64 condition_oracle(u64 x, u64 y) {
    u64 result = x - y;
    unsigned n = result >> 63, z = result == 0, c = x >= y;
    unsigned v = ((x ^ y) & (x ^ result)) >> 63;
    unsigned truth = z | ((!z) << 1) | (c << 2) | ((!c) << 3) |
        (n << 4) | ((!n) << 5) | (v << 6) | ((!v) << 7) |
        ((c && !z) << 8) | ((!c || z) << 9) | ((n == v) << 10) |
        ((n != v) << 11) | ((!z && n == v) << 12) | ((z || n != v) << 13);
    return (~truth) & 0x3fff;
}

static u64 compare_oracle(u64 x) {
    u64 nibble = (x != 0) | ((u64) (x == 0) << 1) |
        ((u64) ((u32) x != 0) << 2) | ((u64) ((u32) x == 0) << 3);
    return nibble * 0x11111;
}

static u64 testbit_oracle(u64 x) {
    static const unsigned bits[] = {0, 31, 32, 63};
    u64 byte = 0;
    for (unsigned i = 0; i < 4; i++) {
        u64 bit = (x >> bits[i]) & 1;
        byte |= bit << (i * 2);
        byte |= (!bit) << (i * 2 + 1);
    }
    return byte * 0x0101010101ull;
}

static u64 nested_oracle(u64 x) {
    if ((s64) x >= 5)
        return 16 + ((x & 4) ? 32 : 0);
    if ((u32) x == 0)
        return 3;
    return 11 + ((x & 2) ? 0 : 4);
}

static u64 backedge_oracle(u64 n) {
    u64 result = 16 + 2 * n;
    for (u64 i = 1; i <= n; i++)
        result += (i & 1) ? i : 3;
    return result;
}

// Keep the RW PT_LOAD file-backed: the standalone guest loader cannot load a
// BSS-only segment. Every tested scratch cell is overwritten before use.
static u64 scratch[4][512] __attribute__((aligned(4096))) = {{1}};

// Every publication changes an instruction that can now be inside a larger
// fallthrough block, then calls both the original and an interior guest entry.
static int invalidation(void) {
    usize size = 4096;
#ifdef __APPLE__
    u32 *code = mmap(0, size, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (code == MAP_FAILED)
        return expect("invalidation mmap", 0, 1);
#else
    s64 mapping = syscall6(222, 0, size, 7, 0x22, (u64) -1, 0);
    if (mapping < 0 && mapping >= -4095)
        return expect("invalidation mmap", (u64) mapping, 0);
    u32 *code = (u32 *) (u64) mapping;
#endif
    int failed = 0;
    for (u64 value = 1; value <= 64; value++) {
#ifdef __APPLE__
        pthread_jit_write_protect_np(0);
#endif
        code[0] = 0xf100001f;                         // cmp x0, #0
        code[1] = 0x54000081;                         // b.ne code[5]
        code[2] = 0xd280000b | ((u32) value << 5);     // movz x11, #value
        code[3] = 0xb400004b;                         // cbz x11, code[5]
        code[4] = 0x91000560;                         // add x0, x11, #1
        code[5] = 0xd65f03c0;                         // ret
#ifdef __APPLE__
        pthread_jit_write_protect_np(1);
        sys_icache_invalidate(code, 6 * sizeof(*code));
#else
        // AArch64 cache-maintenance sequence, no compiler-rt dependency.
        __asm__ volatile("dc cvau, %0\n\tdsb ish\n\tic ivau, %0\n\tdsb ish\n\tisb"
                         : : "r"(code) : "memory");
#endif
        u64 (*entry)(u64) = (u64 (*)(u64)) code;
        u64 (*interior)(u64) = (u64 (*)(u64)) (code + 2);
        for (unsigned warm = 0; warm < 64; warm++) {
            failed |= expect("invalidation entry", entry(0), value + 1);
            failed |= expect("invalidation interior", interior(0), value + 1);
            failed |= expect("invalidation taken", entry(9), 9);
            if (failed)
                break;
        }
        if (failed)
            break;
    }
#ifdef __APPLE__
    munmap(code, size);
#else
    syscall6(215, (u64) code, size, 0, 0, 0, 0);
#endif
    return failed;
}

int forward_branches_main(void) {
    static const u64 values[] = {0, 1, 2, 3, 4, 5, 7, 8, 31, 257,
        0x100000000ull, 0x8000000000000000ull, 0xffffffffffffffffull};
    static const u64 pairs[][2] = {{0, 0}, {0, 1}, {1, 0}, {9, 9},
        {0x8000000000000000ull, 1}, {0x7fffffffffffffffull, 0xffffffffffffffffull},
        {0xffffffffffffffffull, 0x8000000000000000ull}};
    unsigned total = sizeof(values) / sizeof(values[0]);
    int failed = 0;
    for (unsigned warm = 0; warm < 64; warm++) {
        for (unsigned i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++)
            failed |= expect("B.cond", fb_conditions(pairs[i][0], pairs[i][1]),
                             condition_oracle(pairs[i][0], pairs[i][1]));
        for (unsigned i = 0; i < total; i++) {
            u64 value = values[i];
            failed |= expect("CBZ/CBNZ spilled32/64", fb_compare(value), compare_oracle(value));
            failed |= expect("TBZ/TBNZ spilled32/64", fb_testbit(value), testbit_oracle(value));
            failed |= expect("nested", fb_nested(value), nested_oracle(value));
            failed |= expect("page boundary", fb_page_edge(value), value ? value + 13 : 31);
            failed |= expect("instruction limit", fb_long_path(value), value ? 0 : 224);
        }
        for (unsigned i = 0; i < 4; i++) {
            scratch[i][0] = i == 3 ? (u64) -1 : 41;
            u64 flag = i == 0 ? 0 : (i == 1 ? 1 : (u64) -1);
            if (i == 3)
                flag = 1;
            u64 wanted = (s64) flag < 0 ? scratch[i][0] + 4 : scratch[i][0];
            if ((s64) flag > 0) {
                wanted++;
                if (wanted)
                    wanted += 2;
            }
            failed |= expect("flags around memory", fb_flags_mem(flag, scratch[i]), wanted);
            failed |= expect("memory side effect", scratch[i][1], scratch[i][0]);
        }
        static const u64 counts[] = {0, 1, 2, 7, 32, 257};
        for (unsigned i = 0; i < sizeof(counts) / sizeof(counts[0]); i++)
            failed |= expect("backedges", fb_backedges(counts[i]), backedge_oracle(counts[i]));
        failed |= expect("self/AL/NV", fb_self_always(), 1);
        // Interleave overlapping guest entry points after warming the outer one.
        failed |= expect("outer entry untaken", fb_interior(0), 18 ^ 0x55);
        failed |= expect("interior odd", fb_interior_entry(0), 18 ^ 0x55);
        failed |= expect("interior even", fb_interior_entry(1), 8 ^ 0x55);
        failed |= expect("outer entry taken", fb_interior(3), 3 ^ 0x55);
        if (failed)
            return 1;
    }
    passed("conditional families, spilled registers, nested paths");
    passed("NZCV across memory and TLB paths");
    passed("backward/self/unconditional branches");
    passed("4 KiB fetch boundary and instruction limit");
    passed("overlapping interior entry points");
    if (invalidation())
        return 1;
    passed("fallthrough and interior code invalidation");
    output("forward-branches: all passed\n");
    return 0;
}

#ifdef __APPLE__
int main(void) {
    return forward_branches_main();
}
#endif
