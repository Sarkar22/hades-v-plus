#include "peripherals.h"

/*
 * Branch predictor benchmark.
 * Uses the proven pattern: csrr → sw → lw → call (no long delay).
 *
 * CSRs:
 *   MHPMEVENT10  0x32A  algorithm select (0=never taken, 3=2-bit counter)
 *   MHPMCOUNTER10 0xB0A  NN: predict NT, actually NT  (correct)
 *   MHPMCOUNTER11 0xB0B  NT: predict NT, actually T   (miss)
 *   MHPMCOUNTER12 0xB0C  TN: predict T,  actually NT  (miss)
 *   MHPMCOUNTER13 0xB0D  TT: predict T,  actually T   (correct)
 *   MCYCLE        0xB00  cycle counter
 */

#define LOOP_N 100

static void putc_u(char c) {
    while (!(*UART_TX_STATUS_ADDRESS & (1 << UART_TX_STATUS_IDX_EMPTY)));
    *UART_BUFFER_ADDRESS = (uint8_t)c;
}
static void uart_puts(const char *s) { while (*s) putc_u(*s++); }
static void put_hex(uint32_t v) {
    int i; for (i=28;i>=0;i-=4){uint8_t n=(v>>i)&0xF; putc_u(n<10?'0'+n:'a'+n-10);}
}

static inline void write_bp_mode(uint32_t m) {
    __asm__ volatile("csrw 0x32A, %0" :: "r"(m));
}
static inline void reset_counters(void) {
    __asm__ volatile("csrwi 0xB0A, 0");
    __asm__ volatile("csrwi 0xB0B, 0");
    __asm__ volatile("csrwi 0xB0C, 0");
    __asm__ volatile("csrwi 0xB0D, 0");
}
static inline uint32_t read_csr_mcycle(void)    { uint32_t v; __asm__ volatile("csrr %0,0xB00":"=r"(v)); return v; }
static inline uint32_t read_csr_nn(void)        { uint32_t v; __asm__ volatile("csrr %0,0xB0A":"=r"(v)); return v; }
static inline uint32_t read_csr_nt(void)        { uint32_t v; __asm__ volatile("csrr %0,0xB0B":"=r"(v)); return v; }
static inline uint32_t read_csr_tn(void)        { uint32_t v; __asm__ volatile("csrr %0,0xB0C":"=r"(v)); return v; }
static inline uint32_t read_csr_tt(void)        { uint32_t v; __asm__ volatile("csrr %0,0xB0D":"=r"(v)); return v; }

/* Tight backward-branch loop taken LOOP_N-1 times, exits once. */
static void run_loop(void) {
    uint32_t sum = 0, i;
    for (i = LOOP_N; i > 0; i--)
        sum += i;
    (void)sum;
}

/* Print one result line using the "read → print immediately" pattern. */
static void print_mode(const char *tag, uint32_t cyc) {
    uart_puts(tag);
    uart_puts("cyc="); put_hex(cyc); putc_u(' ');
    uart_puts("NN=");  put_hex(read_csr_nn()); putc_u(' ');
    uart_puts("NT=");  put_hex(read_csr_nt()); putc_u(' ');
    uart_puts("TN=");  put_hex(read_csr_tn()); putc_u(' ');
    uart_puts("TT=");  put_hex(read_csr_tt()); putc_u('\n');
}

int main(void) {
    uint32_t t0, t1;

    uart_puts("BP benchmark N=100\n");

    /* --- Mode 0: Never Taken (baseline = original HaDes-V) --- */
    write_bp_mode(0);
    reset_counters();
    t0 = read_csr_mcycle();   /* read start */
    run_loop();
    t1 = read_csr_mcycle();   /* read end */
    print_mode("M0: ", t1 - t0);

    /* --- Mode 3: 2-bit Counter (adaptive bimodal) --- */
    write_bp_mode(3);
    reset_counters();
    t0 = read_csr_mcycle();
    run_loop();
    t1 = read_csr_mcycle();
    print_mode("M3: ", t1 - t0);

    return 0;
}
