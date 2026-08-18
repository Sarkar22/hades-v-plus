# Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
# Embedded Architectures & Systems Group, Graz University of Technology
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: fencei.s
#
# ------------------------------------------------------------------------------------------------
# |                                                                                              |
# | FENCE.I / self-modifying-code test.                                                          |
# |                                                                                              |
# | This SoC has ONE shared BRAM for instructions and data (rtl/mcu.sv instantiates a single      |
# | wishbone_ram: port_a = fetch bus, port_b = data bus slave 0), and the linker script           |
# | std/hades-v.ld places everything in a single RAM(rwx) region at 0x40000. Therefore .text is   |
# | writable: a store can rewrite an instruction word.                                            |
# |                                                                                              |
# | Each test below:                                                                             |
# |   1. stores a NEW instruction encoding over an upcoming instruction word,                    |
# |   2. executes FENCE.I,                                                                       |
# |   3. falls through into the patched word and asserts the NEW behaviour is observed,          |
# |   4. reads the patched word back with lw and asserts the encoding really changed             |
# |      (this separates "the store never landed" from "fetch was stale").                       |
# |                                                                                              |
# | Register allocation:                                                                         |
# |     x0  (zero): hardwired 0                                                                  |
# |     x5  (t0):   reserved for macro use                                                       |
# |     x6  (t1):   constant 1                                                                   |
# |     x7  (t2):   test case number                                                             |
# |     x28 (t3):   constant 0x120000<<2 (test peripheral address)                               |
# |     x30 (t5):   address of the instruction word being patched                                |
# |     x31 (t6):   new instruction encoding                                                     |
# |     x10 (a0):   result written by the patched instruction                                    |
# |     x11 (a1):   instruction word read back from memory                                       |
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

.macro flush_pipeline
    nop
    nop
    nop
    nop
    nop
.endm

# Keep instruction distances deterministic: no linker relaxation of %hi/%lo pairs.
.option norelax

# ------------------------------------------------------------------------------------------------
# |                                          Test entry!                                         |
# ------------------------------------------------------------------------------------------------
.global __reset
__reset:

test_init:
    addi t1, zero, 1              # t1 = 1
    addi t2, zero, 0              # t2 = test case number
    lui  t3, %hi(0x120000<<2)     # t3 = peripheral test address
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)

# -----------------------------------------------
# Deliberate first failure: proves the assert macro
# and the test peripheral actually work.
test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# -----------------------------------------------
# Test 2: NEAR patch.
# The patched word sits 2 instructions after the store and immediately after
# FENCE.I, i.e. deep inside the in-flight pipeline window. Without FENCE.I the
# already-fetched original word would execute.
#   original: addi a0, zero, 11   (0x00b00513)
#   patched : addi a0, zero, 22   (0x01600513)
test_patch_near:
    addi t2, zero, 2
    flush_pipeline
    addi a0, zero, 0              # clear result
    lui  t5, %hi(near_slot)
    addi t5, t5, %lo(near_slot)   # t5 = &near_slot
    lui  t6, %hi(0x01600513)
    addi t6, t6, %lo(0x01600513)  # t6 = encoding of 'addi a0, zero, 22'
    sw   t6, 0(t5)                # self-modify
    fence.i                       # make the store visible to instruction fetch
near_slot:
    addi a0, zero, 11             # ORIGINAL encoding; must run as 'addi a0, zero, 22'
    assert_value a0, 22           # NEW behaviour observed?

    lw   a1, 0(t5)                # read the instruction word back
    assert_value a1, 0x01600513   # the store really landed in memory

# -----------------------------------------------
# Test 3: FAR patch (> 8 instructions ahead, beyond the pipeline window).
# Sanity check: FENCE.I must not break the ordinary case either.
#   original: addi a0, zero, 12   (0x00c00513)
#   patched : addi a0, zero, 33   (0x02100513)
test_patch_far:
    addi t2, zero, 3
    flush_pipeline
    addi a0, zero, 0              # clear result
    lui  t5, %hi(far_slot)
    addi t5, t5, %lo(far_slot)    # t5 = &far_slot
    lui  t6, %hi(0x02100513)
    addi t6, t6, %lo(0x02100513)  # t6 = encoding of 'addi a0, zero, 33'
    sw   t6, 0(t5)                # self-modify
    fence.i
    nop                           #  1
    nop                           #  2
    nop                           #  3
    nop                           #  4
    nop                           #  5
    nop                           #  6
    nop                           #  7
    nop                           #  8
    nop                           #  9
    nop                           # 10
    nop                           # 11
    nop                           # 12
far_slot:
    addi a0, zero, 12             # ORIGINAL encoding; must run as 'addi a0, zero, 33'
    assert_value a0, 33

    lw   a1, 0(t5)
    assert_value a1, 0x02100513

# -----------------------------------------------
# Test 4: patched CONTROL FLOW.
# Patch a nop into 'jal zero, +8'. If instruction fetch really sees the new
# word, the jump skips 'addi a0, zero, 55' and a0 stays 0.
#   original: nop                 (0x00000013)
#   patched : jal zero, +8        (0x0080006f)
test_patch_branch:
    addi t2, zero, 4
    flush_pipeline
    addi a0, zero, 0              # clear result
    lui  t5, %hi(branch_slot)
    addi t5, t5, %lo(branch_slot) # t5 = &branch_slot
    lui  t6, %hi(0x0080006f)
    addi t6, t6, %lo(0x0080006f)  # t6 = encoding of 'jal zero, +8'
    sw   t6, 0(t5)                # self-modify
    fence.i
branch_slot:
    nop                           # ORIGINAL encoding; must run as 'jal zero, +8'
    addi a0, zero, 55             # must be SKIPPED by the patched jump
    assert_value a0, 0            # a0 untouched => the jump was really fetched

    lw   a1, 0(t5)
    assert_value a1, 0x0080006f

# ------------------------------------------------------------------------------------------------
# |                                          Test done!                                          |
# ------------------------------------------------------------------------------------------------
test_finish:
    addi t2, zero, 5
    halt
    fail
