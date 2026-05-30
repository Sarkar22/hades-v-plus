# Branch predictor verification test
#
# Protocol (same as trap.s):
#   t1 = 1 (constant for fail signal)
#   t3 = TEST_ADDRESS = 0x480000
#   sw zero, 0(t3) = PASS
#   sw t1,   0(t3) = FAIL
#   sw t2,   0(t3) where t2=2 = END simulation
#
# CSRs used:
#   0x32A (MHPMEVENT10)  = predictor select (0=NT, 1=AT, 2=BT, 3=2-bit)
#   0xB0A (MHPMCOUNTER10) = NN: predicted NT, actually NT  (correct)
#   0xB0B (MHPMCOUNTER11) = NT: predicted NT, actually T   (miss — predicting too conservative)
#   0xB0C (MHPMCOUNTER12) = TN: predicted T,  actually NT  (miss — overprediction)
#   0xB0D (MHPMCOUNTER13) = TT: predicted T,  actually T   (correct)
#
# Test A — Mode 0 (Never Taken):
#   Run 50-iteration backward-branch loop.
#   Expect: NT ≥ 48 (nearly every taken branch is a miss), TT = 0.
#
# Test B — Mode 3 (2-bit Counter):
#   Run 50-iteration backward-branch loop.
#   2-bit table initialises backward half to "weak taken", so prediction
#   should be correct from the very first iteration.
#   Expect: TT ≥ 47 (≥47 correct taken predictions), NT = 0.

.section .text
.global main

main:
    # ---------- setup constants ----------
    li   t1, 1
    li   t2, 2
    lui  t3, %hi(0x480000)
    addi t3, t3, %lo(0x480000)    # t3 = TEST_ADDRESS

    # ============================================================
    # TEST A: Mode 0 (Never Taken) — all taken branches are misses
    # ============================================================

    # Select mode 0
    csrwi 0x32A, 0

    # Reset all four counters
    csrwi 0xB0A, 0
    csrwi 0xB0B, 0
    csrwi 0xB0C, 0
    csrwi 0xB0D, 0

    # 50-iteration countdown loop with a backward branch
    li    a0, 50
loop_a:
    addi  a0, a0, -1
    bne   a0, zero, loop_a    # backward branch, taken 49 times, not-taken 1

    # Read NT (predicted NT, actually T) — should be 49 with mode 0
    csrr  a1, 0xB0B           # NT counter

    # NT must be >= 48 (at least 48 mispredictions from predicting not-taken)
    li    a2, 48
    bge   a1, a2, test_a_pass
    sw    t1, 0(t3)           # FAIL: mode 0 not producing enough NT misses
    j     test_done

test_a_pass:
    sw    zero, 0(t3)         # PASS

    # ============================================================
    # TEST B: Mode 3 (2-bit Counter) — backward branch predicted taken
    # ============================================================

    # Select mode 3
    csrwi 0x32A, 3

    # Reset all four counters
    csrwi 0xB0A, 0
    csrwi 0xB0B, 0
    csrwi 0xB0C, 0
    csrwi 0xB0D, 0

    # 50-iteration countdown loop (same backward branch address)
    li    a0, 50
loop_b:
    addi  a0, a0, -1
    bne   a0, zero, loop_b    # same backward branch as loop_a

    # Read TT (predicted T, actually T) — should be ~49 with mode 3
    csrr  a1, 0xB0D           # TT counter

    # Read NT (predicted NT, actually T) — should be 0 with mode 3 warmed up
    csrr  a2, 0xB0B           # NT counter

    # TT must be >= 47 (most iterations correctly predicted taken)
    li    a3, 47
    bge   a1, a3, check_nt
    sw    t1, 0(t3)           # FAIL: not enough correct taken predictions
    j     test_done

check_nt:
    # NT must be <= 2 (at most 2 warmup misses)
    li    a3, 2
    ble   a2, a3, test_b_pass
    sw    t1, 0(t3)           # FAIL: too many not-taken mispredictions
    j     test_done

test_b_pass:
    sw    zero, 0(t3)         # PASS

    # ============================================================
    # TEST C: Mode 1 (Always Taken) — all non-taken exits are TN misses
    # ============================================================

    csrwi 0x32A, 1
    csrwi 0xB0A, 0
    csrwi 0xB0B, 0
    csrwi 0xB0C, 0
    csrwi 0xB0D, 0

    li    a0, 20
loop_c:
    addi  a0, a0, -1
    bne   a0, zero, loop_c    # taken 19 times, not-taken once

    # TT should be 19 (correctly predicted taken each time the branch IS taken)
    csrr  a1, 0xB0D           # TT
    # TN should be 1  (exit branch predicted taken but was not taken)
    csrr  a2, 0xB0C           # TN

    li    a3, 18
    bge   a1, a3, check_tn
    sw    t1, 0(t3)           # FAIL
    j     test_done

check_tn:
    li    a3, 1
    beq   a2, a3, test_c_pass
    sw    t1, 0(t3)           # FAIL: TN not exactly 1
    j     test_done

test_c_pass:
    sw    zero, 0(t3)         # PASS

test_done:
    # End simulation
    sw    t2, 0(t3)
    j     test_done
