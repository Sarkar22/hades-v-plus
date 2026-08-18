/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: m_extension.c
 *
 * M extension, differential test against the compiler's software routines.
 *
 * The frozen reference models in ref/ predate the M extension and can only call
 * every M encoding illegal, so there is no golden RTL to diff against. What
 * there IS, on this very core, is a completely independent implementation of
 * the same arithmetic: the libgcc routines __mulsi3 / __muldi3 / __divsi3 /
 * __modsi3 / __udivsi3 / __umodsi3 that GCC emits for plain C operators when
 * targeting rv32i. They are pure RV32I software, written by someone else, and
 * they run through the same pipeline.
 *
 * So each operand pair is computed twice — once by a single hardware M
 * instruction and once by the software routine — and the two must agree.
 *
 * The two inputs where C itself has no answer (division by zero and
 * INT_MIN / -1 are undefined behaviour in C, and libgcc is free to do anything)
 * are excluded from the differential comparison and checked against the
 * architecturally mandated constants instead.
 *
 * The hardware instructions are reached through inline asm wrapped in
 * .option push / .option arch, +m / .option pop, so the M extension is enabled
 * for exactly those instructions and nothing else. That keeps the Makefile free
 * of -march, the same guarantee test/asm/zba.s and test/asm/mul.s preserve.
 */

#include "peripherals.h"

/* ------------------------------------------------------------------ */
/* Minimal UART output. Printing is by far the most expensive thing    */
/* this program can do (one character is ~150 core cycles at this      */
/* baud rate), so the output is kept to a short summary.               */
/* ------------------------------------------------------------------ */
static void putc_u(char c) {
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}
static void puts_u(const char *s) { while (*s) putc_u(*s++); }
static void put_hex(uint32_t v) {
    int i; for (i = 28; i >= 0; i -= 4) { uint8_t n = (v >> i) & 0xF; putc_u(n < 10 ? '0' + n : 'a' + n - 10); }
}
static void put_dec(uint32_t v) {
    char buf[12]; int i = 0;
    if (v == 0) { putc_u('0'); return; }
    while (v) { buf[i++] = '0' + (char)(v % 10); v /= 10; }
    while (i) putc_u(buf[--i]);
}

/* ------------------------------------------------------------------ */
/* Hardware M instructions, one instruction each.                      */
/* ------------------------------------------------------------------ */
#define HW_OP(name, mnemonic)                                              \
    static uint32_t name(uint32_t a, uint32_t b) {                         \
        uint32_t r;                                                        \
        __asm__ volatile(".option push\n\t"                                \
                         ".option arch, +m\n\t"                            \
                         mnemonic " %0, %1, %2\n\t"                        \
                         ".option pop"                                     \
                         : "=r"(r) : "r"(a), "r"(b));                      \
        return r;                                                          \
    }

HW_OP(hw_mul,    "mul")
HW_OP(hw_mulh,   "mulh")
HW_OP(hw_mulhsu, "mulhsu")
HW_OP(hw_mulhu,  "mulhu")
HW_OP(hw_div,    "div")
HW_OP(hw_divu,   "divu")
HW_OP(hw_rem,    "rem")
HW_OP(hw_remu,   "remu")

/* ------------------------------------------------------------------ */
/* Software oracle: plain C, compiled as rv32i, i.e. libgcc calls.     */
/* ------------------------------------------------------------------ */
static uint32_t sw_mul(uint32_t a, uint32_t b)    { return a * b; }
static uint32_t sw_mulh(uint32_t a, uint32_t b)   { return (uint32_t)(((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32); }
static uint32_t sw_mulhsu(uint32_t a, uint32_t b) { return (uint32_t)(((int64_t)(int32_t)a * (int64_t)(uint32_t)b) >> 32); }
static uint32_t sw_mulhu(uint32_t a, uint32_t b)  { return (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32); }
static uint32_t sw_div(uint32_t a, uint32_t b)    { return (uint32_t)((int32_t)a / (int32_t)b); }
static uint32_t sw_divu(uint32_t a, uint32_t b)   { return a / b; }
static uint32_t sw_rem(uint32_t a, uint32_t b)    { return (uint32_t)((int32_t)a % (int32_t)b); }
static uint32_t sw_remu(uint32_t a, uint32_t b)   { return a % b; }

/* volatile so nothing here is constant-folded at compile time — the point is
   to run both implementations on the core, not to have GCC evaluate either. */
/* Seven operands, i.e. 49 pairs. The list is short on purpose: the software
   oracle is genuinely slow (a 64-bit __muldi3 plus a __divsi3 dwarf the ~34
   cycles the hardware needs) and sim/top.sv gives the whole program a
   100000-cycle budget. Breadth of operands is the assembly tests' job; this
   test exists for the independent oracle, so it spends its budget on the
   values where the two implementations are most likely to disagree: zero, the
   two signs of seven, INT_MIN and all-ones. INT_MAX and the wide bit patterns
   are left to test/asm/mul.s and test/asm/div.s, which can afford hundreds of
   cases because they do not pay for a software oracle. */
static volatile uint32_t operands[] = {
    0x00000000u,   /* the divide-by-zero divisor, and a zero dividend        */
    0x00000007u,   /* +7: gives a non-trivial quotient AND remainder         */
    0x80000000u,   /* INT_MIN: the overflow dividend, and abs(x) == x        */
    0xFFFFFFF9u,   /* -7: the negative quadrants of truncating division      */
    0xFFFFFFFFu    /* -1 signed / UINT_MAX unsigned: the overflow divisor    */
};
#define N_OPERANDS (sizeof(operands) / sizeof(operands[0]))

static uint32_t checks;
static uint32_t errors;

static void expect(uint32_t got, uint32_t want, const char *what, uint32_t a, uint32_t b) {
    checks++;
    if (got != want) {
        errors++;
        puts_u("FAIL ");
        puts_u(what);
        putc_u(' '); put_hex(a);
        putc_u(' '); put_hex(b);
        puts_u(" hw="); put_hex(got);
        puts_u(" sw="); put_hex(want);
        putc_u('\n');
    }
}

int main(void) {
    uint32_t i, j, a, b;

    for (i = 0; i < N_OPERANDS; i++) {
        for (j = 0; j < N_OPERANDS; j++) {
            a = operands[i];
            b = operands[j];

            /* Multiplies are total functions — always comparable. */
            expect(hw_mul(a, b),    sw_mul(a, b),    "mul",    a, b);
            expect(hw_mulh(a, b),   sw_mulh(a, b),   "mulh",   a, b);
            expect(hw_mulhsu(a, b), sw_mulhsu(a, b), "mulhsu", a, b);
            expect(hw_mulhu(a, b),  sw_mulhu(a, b),  "mulhu",  a, b);

            if (b == 0) {
                /* C says nothing here; RISC-V does. */
                expect(hw_div(a, b),  0xFFFFFFFFu, "div/0",  a, b);
                expect(hw_divu(a, b), 0xFFFFFFFFu, "divu/0", a, b);
                expect(hw_rem(a, b),  a,           "rem/0",  a, b);
                expect(hw_remu(a, b), a,           "remu/0", a, b);
                continue;
            }

            /* Unsigned division is total for b != 0. */
            expect(hw_divu(a, b), sw_divu(a, b), "divu", a, b);
            expect(hw_remu(a, b), sw_remu(a, b), "remu", a, b);

            if (a == 0x80000000u && b == 0xFFFFFFFFu) {
                /* Signed overflow: UB in C, mandated in RISC-V. */
                expect(hw_div(a, b), 0x80000000u, "div-ovf", a, b);
                expect(hw_rem(a, b), 0x00000000u, "rem-ovf", a, b);
                continue;
            }

            expect(hw_div(a, b), sw_div(a, b), "div", a, b);
            expect(hw_rem(a, b), sw_rem(a, b), "rem", a, b);
        }
    }

    puts_u("M-EXT checks="); put_dec(checks);
    puts_u(" errors=");      put_dec(errors);
    putc_u('\n');
    puts_u(errors ? "M-EXT FAIL\n" : "M-EXT PASS\n");

    *TEST_ADDRESS = 2;   /* halt the simulation */
    return 0;
}
