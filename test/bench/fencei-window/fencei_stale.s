# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------
# File: fencei_stale.s
#
# FENCE.I staleness window (make bench-fencei-window, see test/bench/README.md).
# Reconstructed from the development log of 2026-08-17 (see results/fencei-
# window/2026-08-17_15b0b85); everything after this header is the reconstruction.
# fencei_stale.s
#
# NEGATIVE CONTROL for FENCE.I (Zifencei).
#
# Self-modifying code WITHOUT fence.i: a `sw` patches an instruction that sits
# only a few slots ahead in the straight-line fall-through path.  If the core
# had no pipeline (or an infinitely fast one) the patched instruction would
# always execute NEW.  On a real 5-stage pipeline the instructions that are
# already in flight when the store commits still hold the OLD encoding.
#
# This test measures the exact staleness window by sweeping the distance
# between the patching `sw` and the patched instruction: sw+4, +8, +12, +16,
# +20.  Every gap is filled with plain `nop`s only -- no branches, no jumps,
# no loads -- because ANY taken jump would flush the pipeline and mask the
# staleness we are trying to observe.
#
# MEASURED RESULT on this core:
#     sw+4, sw+8, sw+12  -> OLD executes (stale)
#     sw+16, sw+20       -> NEW executes (fresh)
# i.e. the staleness window is exactly 3 instruction slots.  That matches the
# pipeline geometry: while the store sits in Memory, Execute holds sw+4,
# Decode holds sw+8, and the BRAM read for sw+12 is in flight in that very
# cycle (wishbone_ram runs on ~clk, so the port-B write and the port-A fetch
# land on the same edge and the fetch sees the pre-write word).  sw+16 is the
# first word read strictly after the write, so it comes back fresh.
#
# CAVEAT for real hardware: the sw+12 slot is a genuine same-address,
# same-edge, dual-port read/write collision in the Basys3 block RAM.  Verilator
# resolves it deterministically to "read old"; a real BRAM leaves cross-port
# collision data undefined.  So sw+4 and sw+8 are stale by construction (they
# are already sitting in pipeline registers), while sw+12 is stale in
# simulation and merely undefined on silicon.  Either way it is NOT fresh, so
# fence.i is required.
#
# Case F8 repeats the sw+8 experiment with the single filler `nop` replaced by
# `fence.i`.  Identical distance, identical everything else -- the only
# difference is the instruction in the gap.  That is the controlled comparison
# that proves FENCE.I is doing real work.
#
# Case S12 repeats the sw+12 experiment with the gap filled by two loads from
# the test peripheral's stalling register instead of two nops.  It rules out
# the "the store stalls the pipe, so fetch catches up" confound.
#
# Marker convention at every patch site:
#     OLD encoding = `addi a0, zero, 1`  = 0x00100513   -> a0 == 1 -> STALE
#     NEW encoding = `addi a0, zero, 2`  = 0x00200513   -> a0 == 2 -> FRESH
# a0 is cleared to 0 before each case, so a0 == 0 would mean "site never ran".
#
# Register allocation:
#     x1  (ra):  return address for puts/report
#     x5  (t0):  scratch (clobbered by the assert macros and by puts)
#     x6  (t1):  constant 1 (fail signal)
#     x28 (t3):  test peripheral, byte address 0x480000
#     x17 (a7):  UART TX buffer, byte address 0x210000
#     x10 (a0):  patch-site marker
#     x11 (a1):  string pointer
#     x12 (a2):  value handed to `report`
#     x14 (a4):  address of the patch site
#     x15 (a5):  NEW instruction encoding to store
#     x8  (s0):  result, distance sw+4
#     x9  (s1):  result, distance sw+8
#     x18 (s2):  result, distance sw+12
#     x19 (s3):  result, distance sw+16
#     x20 (s4):  result, distance sw+20
#     x22 (s6):  result, distance sw+8 WITH fence.i in the gap
#     x23 (s7):  result, distance sw+12 with two pipeline-stalling loads in gap
#     x21 (s5):  saved ra inside `report`
#     x30 (t5):  scratch
#     x31 (t6):  scratch
#
# Test-peripheral protocol (same as ops.s / bpred.s):
#     sw zero, 0(t3) = pass, sw t1, 0(t3) = fail, sw 2, 0(t3) = halt sim.
# Per project convention the FIRST assert deliberately fails, so a healthy run
# ends with "All tests passed! (# Errors: 1 = initial test)".

# Characterised results, filled in from the measured run (1 = OLD/stale,
# 2 = NEW/fresh).  These turn the experiment into a regression lock.
.equ RESULT_D04, 1
.equ RESULT_D08, 1
.equ RESULT_D12, 1
.equ RESULT_D16, 2
.equ RESULT_D20, 2

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

.macro assert_value reg:req, value:req
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

.section .text
.option norelax
.global __reset

__reset:

# ------------------------------------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------------------------------------
init:
    addi t1, zero, 1                # t1 = 1 (fail constant)
    lui  t3, %hi(0x480000)
    addi t3, t3, %lo(0x480000)      # t3 = test peripheral
    lui  a7, %hi(0x210000)
    addi a7, a7, %lo(0x210000)      # a7 = UART TX buffer
    addi s0, zero, 0
    addi s1, zero, 0
    addi s2, zero, 0
    addi s3, zero, 0
    addi s4, zero, 0
    addi s6, zero, 0
    addi s7, zero, 0
    flush_pipeline

# Deliberate initial failure -- proves the assert macro and the test harness work.
initial_check:
    addi t5, zero, 0
    assert_value t5, 1              # EXPECTED FAIL (the "initial test")

# ------------------------------------------------------------------------------------------------
# CASE D = 4 : patched instruction is the instruction immediately after the sw
# ------------------------------------------------------------------------------------------------
case04:
    lui  a4, %hi(patch04)
    addi a4, a4, %lo(patch04)       # a4 = &patch04
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)    # a5 = encoding of `addi a0, zero, 2`
    addi a0, zero, 0                # clear marker
    flush_pipeline                  # drain: no stalls between sw and patch site
    sw   a5, 0(a4)                  # <<< patching store, this PC is "sw"
patch04:
    addi a0, zero, 1                # sw+4  (OLD = 1, NEW = 2)
    addi s0, a0, 0                  # capture
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE D = 8 : one nop between the store and the patched instruction
# ------------------------------------------------------------------------------------------------
case08:
    lui  a4, %hi(patch08)
    addi a4, a4, %lo(patch08)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    nop                             # sw+4
patch08:
    addi a0, zero, 1                # sw+8
    addi s1, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE D = 12
# ------------------------------------------------------------------------------------------------
case12:
    lui  a4, %hi(patch12)
    addi a4, a4, %lo(patch12)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    nop                             # sw+4
    nop                             # sw+8
patch12:
    addi a0, zero, 1                # sw+12
    addi s2, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE D = 16
# ------------------------------------------------------------------------------------------------
case16:
    lui  a4, %hi(patch16)
    addi a4, a4, %lo(patch16)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    nop                             # sw+4
    nop                             # sw+8
    nop                             # sw+12
patch16:
    addi a0, zero, 1                # sw+16
    addi s3, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE D = 20
# ------------------------------------------------------------------------------------------------
case20:
    lui  a4, %hi(patch20)
    addi a4, a4, %lo(patch20)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    nop                             # sw+4
    nop                             # sw+8
    nop                             # sw+12
    nop                             # sw+16
patch20:
    addi a0, zero, 1                # sw+20
    addi s4, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE F8 : identical to case08, but the single filler instruction is fence.i
#           instead of nop.  This is the controlled comparison.
# ------------------------------------------------------------------------------------------------
caseF8:
    lui  a4, %hi(patchF8)
    addi a4, a4, %lo(patchF8)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    fence.i                         # sw+4   (the only difference vs case08)
patchF8:
    addi a0, zero, 1                # sw+8
    addi s6, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# CASE S12 : distance sw+12 again, but the gap is filled with two loads from the
#            test peripheral's "stall acknowledge" register (offset 3), each of
#            which holds the Wishbone bus -- and therefore the whole pipeline --
#            for extra cycles (measured with mcycle: two nops between two
#            `csrr mcycle` cost 3 cycles, the same pair of stalling loads cost
#            6 -- so 3 real stall cycles are injected into the gap; two normal
#            RAM loads cost 3, confirming ordinary loads/stores never stall).
#            This is the confound check: if a stalled pipeline let Fetch "catch
#            up" and re-read the patched word, sw+12 would come out FRESH here
#            even though it is STALE in case12.  Fetch holds its PC *and* its
#            instruction register on STALL (fetch_stage.sv), so the prediction
#            is that stalling changes nothing.
# ------------------------------------------------------------------------------------------------
caseS12:
    lui  a4, %hi(patchS12)
    addi a4, a4, %lo(patchS12)
    lui  a5, %hi(0x00200513)
    addi a5, a5, %lo(0x00200513)
    addi a0, zero, 0
    flush_pipeline
    sw   a5, 0(a4)                  # <<< sw
    lw   t2, 12(t3)                 # sw+4   stalls 3 cycles
    lw   t2, 12(t3)                 # sw+8   stalls 3 cycles
patchS12:
    addi a0, zero, 1                # sw+12
    addi s7, a0, 0
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# Read the patched words back out of memory.  This proves the stores really did
# land in instruction memory (so "OLD executed" means stale fetch, not a failed
# store).
# ------------------------------------------------------------------------------------------------
readback:
    lui  a4, %hi(patch04)
    addi a4, a4, %lo(patch04)
    lw   t6, 0(a4)                  # t6 = word now sitting at patch04
    flush_pipeline

# ------------------------------------------------------------------------------------------------
# Report
# ------------------------------------------------------------------------------------------------
report_all:
    lui  a1, %hi(str_hdr)
    addi a1, a1, %lo(str_hdr)
    jal  ra, puts

    lui  a1, %hi(str_d04)
    addi a1, a1, %lo(str_d04)
    addi a2, s0, 0
    jal  ra, report

    lui  a1, %hi(str_d08)
    addi a1, a1, %lo(str_d08)
    addi a2, s1, 0
    jal  ra, report

    lui  a1, %hi(str_d12)
    addi a1, a1, %lo(str_d12)
    addi a2, s2, 0
    jal  ra, report

    lui  a1, %hi(str_d16)
    addi a1, a1, %lo(str_d16)
    addi a2, s3, 0
    jal  ra, report

    lui  a1, %hi(str_d20)
    addi a1, a1, %lo(str_d20)
    addi a2, s4, 0
    jal  ra, report

    lui  a1, %hi(str_df8)
    addi a1, a1, %lo(str_df8)
    addi a2, s6, 0
    jal  ra, report

    lui  a1, %hi(str_ds12)
    addi a1, a1, %lo(str_ds12)
    addi a2, s7, 0
    jal  ra, report

# ------------------------------------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------------------------------------
checks:
    # 1. The store really reached instruction memory.
    assert_value t6, 0x00200513

    # 2. Every patch site actually executed (marker != 0).
    sltu t5, zero, s0
    assert_value t5, 1
    sltu t5, zero, s1
    assert_value t5, 1
    sltu t5, zero, s2
    assert_value t5, 1
    sltu t5, zero, s3
    assert_value t5, 1
    sltu t5, zero, s4
    assert_value t5, 1
    sltu t5, zero, s6
    assert_value t5, 1
    sltu t5, zero, s7
    assert_value t5, 1

    # 3. Characterised staleness window (values locked in from the measured run).
    assert_value s0, RESULT_D04
    assert_value s1, RESULT_D08
    assert_value s2, RESULT_D12
    assert_value s3, RESULT_D16
    assert_value s4, RESULT_D20

    # 4. fence.i control: same distance as case08 but must observe the NEW word.
    assert_value s6, 2

    # 5. Stall confound control: sw+12 with 6 cycles of pipeline stall in the
    #    gap must match plain case12.
    assert_value s7, RESULT_D12

done:
    halt
halt_loop:
    j halt_loop

# ------------------------------------------------------------------------------------------------
# Subroutines (only reached after every measurement is finished, so the jumps
# here cannot perturb any of the results above).
# ------------------------------------------------------------------------------------------------

# puts: a1 = NUL-terminated string, prints via UART. Clobbers t0, a1.
puts:
    lbu  t0, 0(a1)
    beq  t0, zero, puts_end
    sb   t0, 0(a7)
    addi a1, a1, 1
    j    puts
puts_end:
    jalr zero, 0(ra)

# report: a1 = label string, a2 = observed marker. Clobbers t0, t5, a1, s5.
report:
    addi s5, ra, 0
    jal  ra, puts
    addi t5, zero, 2
    beq  a2, t5, report_new
    addi t5, zero, 1
    beq  a2, t5, report_old
    lui  a1, %hi(str_bad)
    addi a1, a1, %lo(str_bad)
    j    report_print
report_old:
    lui  a1, %hi(str_old)
    addi a1, a1, %lo(str_old)
    j    report_print
report_new:
    lui  a1, %hi(str_new)
    addi a1, a1, %lo(str_new)
report_print:
    jal  ra, puts
    jalr zero, 0(s5)

# ------------------------------------------------------------------------------------------------
.section .rodata
str_hdr: .asciz "\n--- fence.i negative control: instruction patched at sw+D, no fence.i ---\n"
str_d04: .asciz "  sw+4  (0 nops in gap) : "
str_d08: .asciz "  sw+8  (1 nop  in gap) : "
str_d12: .asciz "  sw+12 (2 nops in gap) : "
str_d16: .asciz "  sw+16 (3 nops in gap) : "
str_d20: .asciz "  sw+20 (4 nops in gap) : "
str_df8: .asciz "  sw+8  (fence.i in gap): "
str_ds12:.asciz "  sw+12 (2 stalling lw ) : "
str_old: .asciz "OLD (STALE)\n"
str_new: .asciz "NEW (fresh)\n"
str_bad: .asciz "?? site did not execute\n"
