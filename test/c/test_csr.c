#include "peripherals.h"

static void putc_u(char c) {
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}
static void put_hex(uint32_t v) {
    int i; for (i=28;i>=0;i-=4){uint8_t n=(v>>i)&0xF;putc_u(n<10?'0'+n:'a'+n-10);}
}

int main(void) {
    uint32_t v;

    /* Test 1: write 0x1234 to MSCRATCH, read it back */
    __asm__ volatile("csrw mscratch, %0" :: "r"(0x1234));
    __asm__ volatile("csrr %0, mscratch" : "=r"(v));
    put_hex(v); putc_u('\n');   /* Expected: 00001234 */

    /* Test 2: write 0xABCD to MSCRATCH, read it back */
    __asm__ volatile("csrw mscratch, %0" :: "r"(0xABCD));
    __asm__ volatile("csrr %0, mscratch" : "=r"(v));
    put_hex(v); putc_u('\n');   /* Expected: 0000abcd */

    /* Test 3: read MCYCLE */
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    put_hex(v); putc_u('\n');   /* Expected: non-zero */

    return 0;
}
