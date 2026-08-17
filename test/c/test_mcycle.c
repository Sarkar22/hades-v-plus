#include "peripherals.h"

static void putc_u(char c) {
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}

static void put_hex(uint32_t v) {
    int i;
    for (i = 28; i >= 0; i -= 4) {
        uint8_t n = (v >> i) & 0xF;
        putc_u(n < 10 ? '0' + n : 'a' + n - 10);
    }
}

int main(void) {
    uint32_t a, b, c;

    /* Read 1: immediately at start of main */
    __asm__ volatile("csrr %0, 0xB00" : "=r"(a));

    /* Read 2: after a few NOPs */
    __asm__ volatile("nop\nnop\nnop\nnop\nnop\n");
    __asm__ volatile("csrr %0, 0xB00" : "=r"(b));

    /* Read 3: after UART output */
    putc_u('X');
    __asm__ volatile("csrr %0, 0xB00" : "=r"(c));

    put_hex(a); putc_u(' ');
    put_hex(b); putc_u(' ');
    put_hex(c); putc_u('\n');

    /* Expected: a < b < c, all non-zero (except a might be very small) */
    /* b - a should be ~5 (5 NOPs + stall cycles)                       */
    /* c - b should be ~150 (UART TX time) + a few cycles               */

    return 0;
}
