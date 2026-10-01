/* SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: mcost.c
 *
 * M-unit cycle cost (make bench-mcost, see test/bench/README.md): each of the
 * eight M instructions and three early-out cases, 512 times, timed with mcycle.
 * Recovered from the development log of 2026-08-18; everything after this
 * header is the program exactly as it was first run.
 */
/* mcost.c -- isolated marginal cost of one M instruction.
 * Times a loop of 8 identical instructions against the same loop with 8 ADDs,
 * so loop overhead, fetch and the branch cancel out. rv32im only (inline asm).
 */
#include "peripherals.h"
static void putc_u(char c){while(!(*UART_TX_STATUS_ADDRESS&(1<<UART_TX_STATUS_IDX_EMPTY)));*UART_BUFFER_ADDRESS=(uint8_t)c;}
static void puts_u(const char*s){while(*s)putc_u(*s++);}
static void put_hex(uint32_t v){int i;for(i=28;i>=0;i-=4){uint8_t n=(v>>i)&0xF;putc_u(n<10?'0'+n:'a'+n-10);}}
static uint32_t rdcycle(void){uint32_t x;__asm__ volatile("csrr %0,0xB00":"=r"(x));return x;}
#define N 64
#define TIME8(NAME, INSN)                                                     \
    do {                                                                      \
        uint32_t t0,t1,n=N; volatile uint32_t o=0;                            \
        t0=rdcycle();                                                         \
        __asm__ volatile(".option push\n\t.option arch, +m\n\t"               \
            "1:\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"          \
                     INSN "\n\t" INSN "\n\t" INSN "\n\t" INSN "\n\t"          \
            "addi %[n], %[n], -1\n\t"                                         \
            "bnez %[n], 1b\n\t.option pop"                                    \
            : [n]"+r"(n), [o]"+r"(o) : [a]"r"(a), [b]"r"(b));                 \
        t1=rdcycle();                                                         \
        puts_u(NAME); putc_u(' '); put_hex(t1-t0); putc_u('\n');              \
    } while (0)
int main(void){
    volatile uint32_t va=0xDEADBEEFu, vb=0x0000000Du;
    uint32_t a=va,b=vb;
    TIME8("base-add", "add    %[o], %[a], %[b]");
    TIME8("mul     ", "mul    %[o], %[a], %[b]");
    TIME8("mulh    ", "mulh   %[o], %[a], %[b]");
    TIME8("mulhsu  ", "mulhsu %[o], %[a], %[b]");
    TIME8("mulhu   ", "mulhu  %[o], %[a], %[b]");
    TIME8("div     ", "div    %[o], %[a], %[b]");
    TIME8("divu    ", "divu   %[o], %[a], %[b]");
    TIME8("rem     ", "rem    %[o], %[a], %[b]");
    TIME8("remu    ", "remu   %[o], %[a], %[b]");
    { volatile uint32_t z=0; uint32_t zz=z; b=zz;
      TIME8("div-by-0", "div    %[o], %[a], %[b]");
      TIME8("remu-by-0","remu   %[o], %[a], %[b]"); }
    { volatile uint32_t mn=0x80000000u, m1=0xFFFFFFFFu; a=mn; b=m1;
      TIME8("div-ovf ", "div    %[o], %[a], %[b]"); }
    *TEST_ADDRESS=2; return 0;
}
