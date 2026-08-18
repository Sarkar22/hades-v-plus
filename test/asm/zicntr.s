# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: zicntr.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | Zicntr extension test (CYCLE/TIME/INSTRET + high halves).                                    |
# | If everything runs correctly, the first register of the peripheral test module               |
# | should always be zero, except during the first test, which checks the assert macro itself.   |
# | Note: This condition is necessary, but not sufficient to prove coreectness.                  |
# |                                                                                              |
# | What is checked:                                                                             |
# |     1. CYCLE   (0xC00) is the very same counter as MCYCLE   (0xB00), and it advances.        |
# |     2. INSTRET (0xC02) is the very same counter as MINSTRET (0xB02), and it advances.        |
# |     3. TIME    (0xC01) advances and is a true shadow of the memory-mapped mtime, i.e. it     |
# |        follows a value written to mtime through the timer's Wishbone registers.              |
# |     4. CYCLEH/TIMEH/INSTRETH read the upper halves.                                          |
# |     5. Every WRITING form of every one of the six CSRs raises illegal-instruction, while     |
# |        every zero-source (pure read) form does not.                                          |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x29 (t4):   constant address of trap_count                                               |
# |     x30 (t5):   temporary register                                                           |
# |     x31 (t6):   temporary register                                                           |
# |     x9  (s1):   temporary register (counter samples)                                         |
# |     x18 (s2):   temporary register (counter samples)                                         |
# |     x19 (s3):   temporary register (counter samples)                                         |
# |     x21 (s5):   temporary register for interrupt                                             |
# |     x22 (s6):   temporary register for interrupt                                             |
# |                                                                                              |
# ------------------------------------------------------------------------------------------------

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

.macro interrupt delay=1
    lui  t0,     %hi(\delay)
    addi t0, t0, %lo(\delay)
    sw   t0, 4(t3)
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

# Extra macro for this test: fail unless the register is non-zero.
# sltu gives 1 when the value is non-zero, xori turns that into the 0 the
# test peripheral expects for "pass".
.macro assert_nonzero reg:req
    sltu t0, zero, \reg
    xori t0, t0, 1
    sw   t0, 0(t3)
.endm

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

# ------------------------------------------------------------------------------------------------
# |                            CSR access-form helper macros                                     |
# ------------------------------------------------------------------------------------------------
# The six Zicntr CSRs live at addresses whose bits [11:10] are 2'b11, which is the
# RISC-V encoding for "read-only". Every form that would WRITE must therefore raise
# an illegal-instruction exception, and every form that only READS must not.
#
# WRITING forms (6 per CSR) — all must trap:
#   csrrw / csrrwi              write unconditionally, no matter what rd is
#   csrrs / csrrc   with rs1!=x0   write (the rs1 *field*, not its value, decides)
#   csrrsi / csrrci with uimm!=0   write
.macro zicntr_write_forms csrname:req
    csrrw  x0, \csrname, x0
    csrrwi x0, \csrname, 0
    csrrs  t5, \csrname, t1
    csrrc  t5, \csrname, t1
    csrrsi t5, \csrname, 1
    csrrci t5, \csrname, 1
.endm

# READING forms (4 per CSR) — none may trap:
#   csrrs / csrrc   with rs1==x0   pure read, no write side effect
#   csrrsi / csrrci with uimm==0   pure read, no write side effect
.macro zicntr_read_forms csrname:req
    csrrs  t5, \csrname, x0
    csrrc  t5, \csrname, x0
    csrrsi t5, \csrname, 0
    csrrci t5, \csrname, 0
.endm

.global __reset
__reset:
    beq  zero, zero, test_init
    # jump to reset if this code snipped reached
    flush_pipeline
    beq  zero, zero, __reset

# ------------------------------------------------------------------------------------------------
# |                            Helperfunctions and Interrupt-handlers!                           |
# ------------------------------------------------------------------------------------------------

# Illegal-instruction handler.
# Every trap this test provokes must be an illegal-instruction trap (mcause = 2).
# The handler counts the traps in trap_count and resumes at mepc+4, i.e. it simply
# skips the offending instruction — which lets a long run of trapping instructions
# be executed back to back without setting up a resume address for each of them.
irq_handler_illegal:
    # the cause must be "illegal instruction"
    csrr s5, mcause
    assert_value s5, 2
    # count this trap
    lw   s6, 0(t4)
    addi s6, s6, 1
    sw   s6, 0(t4)
    # skip the offending instruction and return
    csrr s5, mepc
    addi s5, s5, 4
    csrw mepc, s5
    mret
    # jump to reset if this code snipped reached
    flush_pipeline
    beq  zero, zero, __reset

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
test_init:
    addi t1, zero, 1              # t1 = 1
    addi t2, zero, 0              # t2 = test case number
    lui  t3, %hi(0x120000<<2)     # t3 = peripheral test address
    lui  t4, %hi(trap_count)      # t4 = trap counter address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)
    addi t4, t4, %lo(trap_count)

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# CYCLE advances, and is the SAME counter as MCYCLE
test_cycle:
    addi t2, zero, 2
    flush_pipeline
    # (a) CYCLE advances over time
    csrr s1, cycle
    flush_pipeline
    csrr s2, cycle
    sub  s3, s2, s1
    assert_nonzero s3
    # (b) MCYCLE advances over time
    flush_pipeline
    csrr s1, mcycle
    flush_pipeline
    csrr s2, mcycle
    sub  s3, s2, s1
    assert_nonzero s3

test_cycle_is_mcycle:
    addi t2, zero, 3
    # Two adjacent reads must be the same distance apart no matter which of the
    # two names is used. If CYCLE were a separate counter offset by k, the
    # MCYCLE->CYCLE delta would be (baseline + k) and CYCLE->MCYCLE would be
    # (baseline - k); requiring all three to be equal forces k = 0.
    flush_pipeline
    csrr t5, mcycle
    csrr t6, mcycle
    sub  s1, t6, t5               # baseline delta
    flush_pipeline
    csrr t5, mcycle
    csrr t6, cycle
    sub  s2, t6, t5
    flush_pipeline
    csrr t5, cycle
    csrr t6, mcycle
    sub  s3, t6, t5
    flush_pipeline
    assert_equal s1, s2
    assert_equal s1, s3
    # Strongest proof: MCYCLE is writable, CYCLE is not — write a marker through
    # MCYCLE and read it back through CYCLE. Only the top 20 bits are compared so
    # the handful of cycles between the write and the read cannot matter.
    lui  t5,     %hi(0x12345000)
    addi t5, t5, %lo(0x12345000)
    csrw mcycle, t5
    csrr t6, cycle
    srli t6, t6, 12
    assert_value t6, 0x12345

# -----------------------------------------------
# INSTRET advances, and is the SAME counter as MINSTRET
test_instret:
    addi t2, zero, 4
    flush_pipeline
    # (a) INSTRET advances as instructions retire
    csrr s1, instret
    flush_pipeline
    csrr s2, instret
    sub  s3, s2, s1
    assert_nonzero s3
    # (b) MINSTRET advances as instructions retire
    flush_pipeline
    csrr s1, minstret
    flush_pipeline
    csrr s2, minstret
    sub  s3, s2, s1
    assert_nonzero s3

test_instret_is_minstret:
    addi t2, zero, 5
    flush_pipeline
    csrr t5, minstret
    csrr t6, minstret
    sub  s1, t6, t5               # baseline delta
    flush_pipeline
    csrr t5, minstret
    csrr t6, instret
    sub  s2, t6, t5
    flush_pipeline
    csrr t5, instret
    csrr t6, minstret
    sub  s3, t6, t5
    flush_pipeline
    assert_equal s1, s2
    assert_equal s1, s3
    # write a marker through MINSTRET, read it back through INSTRET
    lui  t5,     %hi(0x23456000)
    addi t5, t5, %lo(0x23456000)
    csrw minstret, t5
    csrr t6, instret
    srli t6, t6, 12
    assert_value t6, 0x23456

# -----------------------------------------------
# TIME advances and shadows the memory-mapped mtime
test_time:
    addi t2, zero, 6
    flush_pipeline
    csrr s1, time
    flush_pipeline
    csrr s2, time
    sub  s3, s2, s1
    assert_nonzero s3

test_time_shadows_mtime:
    addi t2, zero, 7
    # The spec defines TIME as a read-only shadow of the memory-mapped mtime, so
    # a value stored into mtime through the timer's Wishbone registers must become
    # visible through the CSR. This is exactly what an internal, core-private
    # wall-clock counter would NOT be able to do.
    lui  t6,     %hi((0x85000+1)<<2)   # MTIME - address
    addi t6, t6, %lo((0x85000+1)<<2)   # MTIME - address
    lui  t5,     %hi(0x54321000)
    addi t5, t5, %lo(0x54321000)
    addi s1, zero, 7
    sw   s1, 4(t6)                     # mtimeh = 7
    sw   t5, 0(t6)                     # mtime  = 0x54321000
    flush_pipeline
    flush_pipeline
    csrr s2, time
    srli s2, s2, 12
    assert_value s2, 0x54321
    csrr s3, timeh
    assert_value s3, 7

# -----------------------------------------------
# The high halves read the upper 32 bits
test_high_halves:
    addi t2, zero, 8
    flush_pipeline
    # MCYCLEH is writable, CYCLEH must show the same upper half
    addi t5, zero, 0x2A
    csrw mcycleh, t5
    csrr t6, cycleh
    assert_value t6, 0x2A
    csrr s1, mcycleh
    assert_equal s1, t6
    # same for MINSTRETH / INSTRETH
    flush_pipeline
    addi t5, zero, 0x35
    csrw minstreth, t5
    csrr t6, instreth
    assert_value t6, 0x35
    csrr s1, minstreth
    assert_equal s1, t6
    # TIMEH still holds the 7 written into mtimeh above
    flush_pipeline
    csrr s2, timeh
    assert_value s2, 7

# -----------------------------------------------
# All six CSRs are read-only: every writing form traps, every read form does not
test_readonly_traps:
    addi t2, zero, 9
    # install the illegal-instruction handler
    lui  t5,     %hi(irq_handler_illegal)
    addi t5, t5, %lo(irq_handler_illegal)
    csrw mtvec, t5
    # clear the trap counter
    sw   zero, 0(t4)
    flush_pipeline
    # 6 CSRs x 6 writing forms = 36 illegal instructions
    zicntr_write_forms cycle
    zicntr_write_forms time
    zicntr_write_forms instret
    zicntr_write_forms cycleh
    zicntr_write_forms timeh
    zicntr_write_forms instreth
    flush_pipeline
    lw   t5, 0(t4)
    assert_value t5, 36

test_readonly_reads_ok:
    addi t2, zero, 10
    # clear the trap counter again
    sw   zero, 0(t4)
    flush_pipeline
    # 6 CSRs x 4 zero-source forms = 24 perfectly legal reads
    zicntr_read_forms cycle
    zicntr_read_forms time
    zicntr_read_forms instret
    zicntr_read_forms cycleh
    zicntr_read_forms timeh
    zicntr_read_forms instreth
    flush_pipeline
    lw   t5, 0(t4)
    assert_value t5, 0

# -----------------------------------------------
# A trapping write must leave the shadowed counter alone.
# MCYCLEH/MINSTRETH still carry the markers written in test_high_halves; the 36
# illegal writes above must not have disturbed them.
test_no_write_side_effect:
    addi t2, zero, 11
    flush_pipeline
    csrr t5, mcycleh
    assert_value t5, 0x2A
    csrr t5, minstreth
    assert_value t5, 0x35
    csrr t5, cycleh
    assert_value t5, 0x2A
    csrr t5, instreth
    assert_value t5, 0x35

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 12
    halt
    fail

    .align 4
var:
    .word 0xcafebabe
trap_count:
    .word 0x00000000
