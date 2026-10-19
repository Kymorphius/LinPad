// Shared Apple Silicon / freestanding Linux AArch64 branch semantics fixture.
// All conditional branch targets below are deliberately visible to the JIT;
// the C harness is only an oracle and driver, compiled without optimization.
#ifdef __APPLE__
#define SYM(name) _##name
#else
#define SYM(name) name
#endif

.text
.p2align 2

.macro FUNCTION name
    .globl SYM(\name)
SYM(\name):
.endm

// Record a bit when a forward conditional is NOT taken. ORR preserves NZCV,
// so every B.cond observes the one initial subtraction.
.macro CONDITION cond, bit
    b.\cond 1f
    orr x2, x2, #(1 << \bit)
1:
.endm

FUNCTION fb_conditions
    mov x2, #0
    cmp x0, x1
    CONDITION eq, 0
    CONDITION ne, 1
    CONDITION cs, 2
    CONDITION cc, 3
    CONDITION mi, 4
    CONDITION pl, 5
    CONDITION vs, 6
    CONDITION vc, 7
    CONDITION hi, 8
    CONDITION ls, 9
    CONDITION ge, 10
    CONDITION lt, 11
    CONDITION gt, 12
    CONDITION le, 13
    mov x0, x2
    ret

.macro COMPARE reg, bit
    cbz x\reg, 1f
    orr x2, x2, #(1 << \bit)
1:
    cbnz x\reg, 1f
    orr x2, x2, #(1 << (\bit + 1))
1:
    cbz w\reg, 1f
    orr x2, x2, #(1 << (\bit + 2))
1:
    cbnz w\reg, 1f
    orr x2, x2, #(1 << (\bit + 3))
1:
.endm

FUNCTION fb_compare
    mov x11, x0
    mov x12, x0
    mov x13, x0
    mov x14, x0
    mov x15, x0
    mov x2, #0
    COMPARE 11, 0
    COMPARE 12, 4
    COMPARE 13, 8
    COMPARE 14, 12
    COMPARE 15, 16
    mov x0, x2
    ret

.macro BITPAIR reg, input_bit, output_bit
    tbz \reg, #\input_bit, 1f
    orr x2, x2, #(1 << \output_bit)
1:
    tbnz \reg, #\input_bit, 1f
    orr x2, x2, #(1 << (\output_bit + 1))
1:
.endm
.macro TESTBITS reg, bit
    BITPAIR w\reg, 0, \bit
    BITPAIR w\reg, 31, (\bit + 2)
    BITPAIR x\reg, 32, (\bit + 4)
    BITPAIR x\reg, 63, (\bit + 6)
.endm

FUNCTION fb_testbit
    mov x11, x0
    mov x12, x0
    mov x13, x0
    mov x14, x0
    mov x15, x0
    mov x2, #0
    TESTBITS 11, 0
    TESTBITS 12, 8
    TESTBITS 13, 16
    TESTBITS 14, 24
    TESTBITS 15, 32
    mov x0, x2
    ret

FUNCTION fb_nested
    mov x11, x0
    mov x12, #1
    cmp x11, #5
    b.ge 3f
    cbz w11, 2f
    add x12, x12, #2
    tbnz x11, #1, 1f
    add x12, x12, #4
1:
    add x12, x12, #8
    b 4f
2:
    mov x12, #3
    b 4f
3:
    mov x12, #16
    tbz x11, #2, 4f
    add x12, x12, #32
4:
    mov x0, x12
    ret

// NZCV must survive both load/store TLB paths between forward conditionals.
// x11-x15 are spilled guest registers, including the memory base and results.
FUNCTION fb_flags_mem
    mov x13, x1
    cmp x0, #0
    b.lt 2f
    ldr x11, [x13]
    str x11, [x13, #8]
    b.eq 1f
    add x11, x11, #1
    cbz x11, 1f
    add x11, x11, #2
1:
    mov x0, x11
    ret
2:
    ldr x14, [x13]
    str x14, [x13, #8]
    b.ge 3f
    add x14, x14, #4
3:
    mov x0, x14
    ret

FUNCTION fb_backedges
    mov x11, x0
    mov x12, #0
    cbz x11, 3f
1:
    tbz x11, #0, 2f
    add x12, x12, x11
    b 4f
2:
    add x12, x12, #3
4:
    subs x11, x11, #1
    b.ne 1b
3:
    mov x11, x0
    cbz x11, 6f
5:
    add x12, x12, #1
    sub x11, x11, #1
    cbnz x11, 5b
6:
    mov x11, #1
7:
    add x12, x12, #1
    lsl x11, x11, #1
    tbz x11, #8, 7b
    mov x11, #255
8:
    add x12, x12, #1
    lsr x11, x11, #1
    tbnz x11, #0, 8b
    mov x11, x0
9:
    cbz x11, 10f
    add x12, x12, #1
    sub x11, x11, #1
    b 9b
10:
    mov x0, x12
    ret

// Self-target conditionals are deliberately untaken; a wrongly taken one is
// bounded by the external runner timeout. AL/NV retain unconditional semantics.
FUNCTION fb_self_always
    mov x11, #0
    cmp x11, #1
1:
    b.eq 1b
2:
    cbnz x11, 2b
3:
    tbnz x11, #1, 3b
    mov x11, #1
4:
    tbz x11, #0, 4b
    b.al 5f
    mov x11, #99
5:
    b.nv 6f
    mov x11, #98
6:
    mov x0, x11
    ret

FUNCTION fb_interior
    cmp x0, #0
    b.ne 2f
FUNCTION fb_interior_entry
    add x0, x0, #7
    tbz x0, #0, 2f
    add x0, x0, #11
2:
    mov x11, #0x55
    eor x0, x0, x11
    ret

// Force a forward conditional in the final 8 bytes of a 4 KiB guest page;
// untaken translation must stop at the fetch boundary before continuing.
.p2align 12
    .space 4088
FUNCTION fb_page_edge
    cmp x0, #0
    b.ne 1f
    add x0, x0, #7
    add x0, x0, #11
1:
    add x0, x0, #13
    ret

// More than MAX_INSNS guest instructions on the untaken linear path.
.p2align 12
FUNCTION fb_long_path
    mov x11, #0
    .rept 224
        cbnz x0, 1f
        add x11, x11, #1
1:
    .endr
    mov x0, x11
    ret

#ifndef __APPLE__
    .globl _start
_start:
    bl forward_branches_main
    mov x8, #93
    svc #0
    .section .note.GNU-stack,"",@progbits
#endif
