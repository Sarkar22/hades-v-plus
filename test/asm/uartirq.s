# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: uartirq.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | UART TRANSMIT INTERRUPT ENABLE WRITTEN BY BYTE STORES (regression for the TX_IE fix in       |
# | lib/wishbone/wishbone_uart.sv).                                                              |
# |                                                                                              |
# | In the bus cycle of a write to a status byte the UART drives its interrupt line with the     |
# | enable bit being written (write-through), so a store that clears an enable masks the         |
# | interrupt from that very cycle on. The TX_IE write-through was keyed on the RX status byte   |
# | (sel[2]) instead of the TX status byte (sel[3]). Only the line in that one cycle was wrong   |
# | (the registers were right), and only for byte stores: a halfword store to the status half    |
# | or a word store selects both bytes. In the cycle of a byte store                             |
# |   - to the TX status byte the line used the OLD TX_IE,                                       |
# |   - to the RX status byte TX_IE was replaced by bit 25 of the bus data.                      |
# | This core drives 0 on the byte lanes a store does not select. With the transmit buffer       |
# | empty, a byte store to the RX status byte therefore dropped the line for that cycle when     |
# | TX_IE = 1, and a byte store setting TX_IE raised it one cycle late: the interrupt was taken  |
# | one instruction later, never lost. A byte store CLEARING TX_IE in the very cycle the         |
# | transmit buffer becomes empty raised the line for that cycle (old TX_IE = 1, buffer now      |
# | empty). This core takes an interrupt that is pending in the first cycle of a store's bus     |
# | access after that store has retired, so the handler found TX_IE = 0 and no other source:     |
# | a spurious interrupt.                                                                        |
# |                                                                                              |
# | The bug is visible only to a CPU that acts on the line in the first cycle of a store's       |
# | UART access, the only cycle in which the write-through is active. This core does. The        |
# | golden CPU does not: in a two-cycle bus access it ignores the line in the first cycle and    |
# | acts on it in the second, when the enable registers already hold the written value. On       |
# | the golden CPU this test passes with and without the fix.                                    |
# |                                                                                              |
# | 1  TX_IE is set and cleared by byte stores to the TX status byte (read back, MIE = 0).       |
# | 2  Setting TX_IE while the transmit buffer is empty raises the interrupt: taken exactly      |
# |    once, and the handler sees TX_IE and TX_EMPTY.                                            |
# | 3  Byte stores to the RX status byte set RX_IE with the receive buffer empty, TX empty and   |
# |    TX_IE = 0: no interrupt. With rs2 = -1 and 0x202, bus bit 25 is 1 on a memory stage       |
# |    that drives the other bytes of rs2 there (as the golden CPU does) or replicates the       |
# |    byte. This core drives 0 there, so check 3 passed before the fix too; it covers the RX    |
# |    half of the fix for such a memory stage.                                                  |
# | 4  Halfword stores to the status half with TX_IE = 0, TX empty and the receive buffer        |
# |    empty: no interrupt, and the status reads back as written. The first sets RX_IE only,     |
# |    the second every bit except TX_IE (RX_IE and both error flags; the full and empty flags   |
# |    ignore writes). A write-through that took TX_IE from the wrong bit of the bus data (for   |
# |    example bit 17, RX_IE, instead of bit 25) would raise the line in the store's first bus   |
# |    cycle, and this core would take an interrupt without a source. Checks 1-3 and 5 cannot    |
# |    see that slip: they write one status byte at a time, and the handler writes both          |
# |    enables with the same value. Check 4 passes with and without the fix.                     |
# | 5  The race: a character is being sent and a second one waits in the buffer, TX_IE = 1,      |
# |    then `sb zero, 3(uart)` clears TX_IE. Its position is swept in 1-cycle steps across       |
# |    the cycle in which the buffer becomes empty. Verdict per position, printed on the UART:   |
# |      '.'  no interrupt (TX_IE cleared in time)   'r'  one interrupt, its source present      |
# |      'S'  an interrupt without a source          'D'  the handler entered twice              |
# |    Passes when there is no 'S' and no 'D', and both '.' and 'r' occur, i.e. the sweep        |
# |    crossed the boundary cycle. Before the fix exactly one position (the boundary) was 'S'.   |
# |                                                                                              |
# | The interrupt handler counts an interrupt as having a source if (TX_EMPTY and TX_IE) or      |
# | (RX_FULL and RX_IE) is set when it reads the status bytes, then clears both enables with     |
# | a halfword store (both bytes) and returns. Any other mcause fails the test.                  |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   test peripheral address                                                      |
# |     s10:        UART address                                                                 |
# |     s3, s4, s7: interrupt entries, entries without a source, status seen (handler)           |
# |     s1:         character to send   s5: bad positions   s6: position                         |
# |     s8, s9:     positions with no interrupt / with one real interrupt                        |
# |     t5, t6:     handler only                                                                 |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

.equ UART,       0x210000
.equ NSLED,      168          # nops in the sled
.equ DFIRST,     142          # first and last position (nops executed before the store);
.equ DLAST,      166          # the boundary is at 154 on this core
.equ IDLE_LOOPS, 100          # wait until both characters of a position have been sent

.macro pass
    sw zero, 0(t3)
.endm

.macro fail
    sw t1, 0(t3)
.endm

.macro halt
    addi t0, zero, 2
    sw   t0, 0(t3)
.endm

.macro assert_equal r1:req, r2:req
    sub  t0, \r1, \r2
    sltu t0, zero, t0
    sw   t0, 0(t3)
.endm

.macro assert_value reg:req, value: req
    lui  t0,     %hi(\value)
    addi t0, t0, %lo(\value)
    assert_equal t0, \reg
.endm

.section .text.__reset
.globl __reset
__reset:
    lui  t3, 0x120
    slli t3, t3, 2        # test peripheral 0x480000
    addi t1, zero, 1
    fail                  # initial test: deliberate fail (proves the fail path works)
    li   s10, UART
    la   t4, handler
    csrw mtvec, t4
    csrci mstatus, 8
    sh   zero, 2(s10)     # TX_IE = RX_IE = 0
    li   t4, 0x800
    csrw mie, t4          # MEIE: the UART drives the machine external interrupt

# ---- 1: TX_IE set and cleared by byte stores to the TX status byte (MIE = 0) ----------------
    addi t2, zero, 1
    li   a0, 0x02
    sb   a0, 3(s10)       # TX_IE = 1
    lbu  a1, 3(s10)
    andi a1, a1, 0x06
    assert_value a1, 0x06 # TX_IE = 1, TX_EMPTY = 1 (transmitter idle)
    sb   zero, 3(s10)     # TX_IE = 0
    lbu  a1, 3(s10)
    andi a1, a1, 0x02
    assert_value a1, 0

# ---- 2: setting TX_IE with the buffer empty raises the interrupt (MIE = 1) -------------------
    addi t2, zero, 2
    li   s3, 0
    li   s4, 0
    li   s7, 0
    csrsi mstatus, 8
    .rept 8
    nop
    .endr
    sb   a0, 3(s10)       # TX_IE = 1, buffer empty
    .rept 20
    nop
    .endr
    csrci mstatus, 8
    assert_value s3, 1    # taken once
    assert_value s4, 0    # with its source
    andi a1, s7, 0x600
    assert_value a1, 0x600 # the handler saw TX_IE and TX_EMPTY

# ---- 3: byte stores to the RX status byte leave the TX interrupt alone -----------------------
    addi t2, zero, 3
    li   s3, 0
    li   s4, 0
    csrsi mstatus, 8
    .rept 8
    nop
    .endr
    li   a0, -1
    sb   a0, 2(s10)       # RX status = 0xff: RX_IE = 1, receive buffer empty
    .rept 20
    nop
    .endr
    lbu  a1, 2(s10)
    andi a1, a1, 0x02
    sb   zero, 2(s10)
    .rept 8
    nop
    .endr
    li   a0, 0x202
    sb   a0, 2(s10)       # RX status = 0x02: RX_IE = 1
    .rept 20
    nop
    .endr
    lbu  a2, 2(s10)
    andi a2, a2, 0x02
    sb   zero, 2(s10)
    .rept 8
    nop
    .endr
    csrci mstatus, 8
    assert_value s3, 0    # no interrupt
    assert_value a1, 0x02 # RX_IE was written
    assert_value a2, 0x02

# ---- 4: halfword stores with TX_IE = 0 and other bits set leave the TX interrupt alone -------
    addi t2, zero, 4
    li   s3, 0
    li   s4, 0
    csrsi mstatus, 8
    .rept 8
    nop
    .endr
    li   a0, 0x0002
    sh   a0, 2(s10)       # RX status = 0x02 (RX_IE = 1), TX status = 0x00 (TX_IE = 0)
    .rept 20
    nop
    .endr
    lhu  a1, 2(s10)
    andi a1, a1, 0x606    # TX_EMPTY, TX_IE, RX_FULL, RX_IE
    sh   zero, 2(s10)
    .rept 8
    nop
    .endr
    li   a0, 0xfdff
    sh   a0, 2(s10)       # every bit but TX_IE: RX_IE = 1 and both error flags = 1
    .rept 20
    nop
    .endr
    lhu  a2, 2(s10)       # (reading the status clears the error flags)
    andi a2, a2, 0x707    # TX_EMPTY, TX_IE, TX_ERR, RX_FULL, RX_IE, RX_ERR
    sh   zero, 2(s10)
    .rept 8
    nop
    .endr
    csrci mstatus, 8
    assert_value s3, 0    # no interrupt
    assert_value a1, 0x402 # TX_EMPTY = 1, TX_IE = 0, RX_FULL = 0, RX_IE = 1
    assert_value a2, 0x503 # the same, and TX_ERR = RX_ERR = 1

# ---- 5: sb clearing TX_IE, swept across the cycle the transmit buffer becomes empty --------
    addi t2, zero, 5
    li   s5, 0
    li   s8, 0
    li   s9, 0
    li   s6, DFIRST
    li   s1, '['          # the first position sends '[', each later one the previous verdict
    csrsi mstatus, 8
pos:
    li   a0, IDLE_LOOPS   # transmitter idle: the previous position's characters are out
1:  addi a0, a0, -1
    bnez a0, 1b
    li   s3, 0
    li   s4, 0
    la   a3, sled_end
    slli a0, s6, 2
    sub  a3, a3, a0       # enter the sled s6 nops before its end
    li   a0, ' '
    li   a1, 0x02
    sb   s1, 0(s10)       # first character: sent at once
    nop
    nop
    nop
    sb   a0, 0(s10)       # second character: the buffer is full until the first one is out
    sb   a1, 3(s10)       # TX_IE = 1 (buffer full: no interrupt yet)
    jalr zero, 0(a3)
sled:
    .rept NSLED
    nop
    .endr
sled_end:
    sb   zero, 3(s10)     # TX_IE = 0
    .rept 30
    nop
    .endr
    li   s1, '.'
    beqz s3, 3f           # no interrupt
    li   s1, 'S'
    bnez s4, 2f           # an interrupt without a source
    li   s1, 'D'
    li   a0, 1
    bne  s3, a0, 2f       # entered more than once
    li   s1, 'r'
    addi s9, s9, 1
    j    4f
2:  addi s5, s5, 1
    j    4f
3:  addi s8, s8, 1
4:  addi s6, s6, 1
    li   a0, DLAST
    ble  s6, a0, pos
    csrci mstatus, 8
    mv   a0, s1
    jal  putc
    li   a0, ']'
    jal  putc
    li   a0, '\n'
    jal  putc
    assert_value s5, 0    # no interrupt without a source, none taken twice
    sltu a0, zero, s8
    assert_value a0, 1    # positions before the boundary ...
    sltu a0, zero, s9
    assert_value a0, 1    # ... and after it: the sweep crossed it

    halt
    fail

putc:                     # a0 = character (clobbers a1)
    lbu  a1, 3(s10)
    andi a1, a1, 4
    beqz a1, putc
    sb   a0, 0(s10)
    ret

.align 4
handler:
    csrr t5, mcause
    li   t6, 0x8000000B   # machine external interrupt: nothing else is expected
    bne  t5, t6, h_bad
    addi s3, s3, 1
    lhu  s7, 2(s10)       # RX status (bits 7:0), TX status (bits 15:8)
    srli t6, s7, 1
    and  t6, t6, s7
    andi t6, t6, 0x202    # bit 9: TX_EMPTY and TX_IE, bit 1: RX_FULL and RX_IE
    bnez t6, 5f
    addi s4, s4, 1        # no source
5:  sh   zero, 2(s10)     # TX_IE = RX_IE = 0
    mret
h_bad:
    fail
    halt
