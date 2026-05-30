#include "peripherals.h"

/* HaDes-V is bare-metal (-nostdlib), so stdio.h / printf do not exist.
   To send text, write bytes one at a time to the UART TX register.    */

static void uart_putchar(char c) {
    /* Wait until TX FIFO is not full */
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putchar(*s++);
}

int main(void) {
    uart_puts("Hello, World!\n");
    uart_puts("Hello Hades!\n");
    uart_puts("This is Emon!\n");
    return 0;
}
