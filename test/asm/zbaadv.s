# Adversarial Zba semantics test (independent of the implementer's zba.s).
# Register allocation follows the project convention:
#     x0  (zero), x5 (t0) macro scratch, x6 (t1) = 1, x7 (t2) = test number,
#     x28 (t3) = test peripheral, x29 (t4) spare, x30/x31 (t5/t6) temporaries,
#     x21/x22 (s5/s6) reserved for the trap handler.

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

.macro interrupt delay=1
    lui  t0,     %hi(\delay)
    addi t0, t0, %lo(\delay)
    sw   t0, 4(t3)
.endm

.macro li32 reg:req, value:req
    lui  \reg,       %hi(\value)
    addi \reg, \reg, %lo(\value)
.endm

# Execute a hand-encoded word and require it to trap with mcause == cause.
.macro expect_trap enc:req, cause=2
    li32 t5, et_done_\@
    csrw mscratch, t5
    li32 t6, trap_var
    sw   zero, 0(t6)
    flush_pipeline
    .word \enc
et_done_\@:
    li32 t6, trap_var
    lw   t5, 0(t6)
    assert_value t5, \cause
.endm

.text
.option arch, +zba

.global __reset
__reset:
    beq zero, zero, test_init
    flush_pipeline
    beq zero, zero, __reset

# -------------------------------------------------------------------------
# Handlers
# -------------------------------------------------------------------------
# Any trap here is a bug: shout and stop.
unexpected_trap:
    addi t2, zero, 999
    fail
    halt
    beq zero, zero, unexpected_trap

# Records mcause and resumes at mscratch.
record_trap:
    csrr s5, mcause
    li32 s6, trap_var
    sw   s5, 0(s6)
    csrr s5, mscratch
    csrw mepc, s5
    mret
    flush_pipeline
    beq zero, zero, __reset

# Interrupt handler used by the interrupt-during-Zba test.
zba_irq_handler:
    csrr s5, mcause
    interrupt 0
    addi s7, zero, 1
    mret
    flush_pipeline
    beq zero, zero, __reset

# -------------------------------------------------------------------------
test_init:
    addi t1, zero, 1
    addi t2, zero, 0
    lui  t3, %hi(0x120000<<2)
    flush_pipeline
    addi t3, t3, %lo(0x120000<<2)
    li32 t5, unexpected_trap
    csrw mtvec, t5

test_fail:
    addi t2, zero, 1
    assert_value zero, 1

# =========================================================================
# 1. OPERAND ORDER  --  rd = (rs1 << N) + rs2, never (rs2 << N) + rs1
# =========================================================================
test_order_sh1add:
    addi t2, zero, 2
    flush_pipeline
    li32 a0, 1
    li32 a1, 0x100
    sh1add a2, a0, a1
    assert_value a2, 0x102          # swapped operands would give 0x201

test_order_sh2add:
    addi t2, zero, 3
    flush_pipeline
    li32 a0, 3
    li32 a1, 5
    sh2add a2, a0, a1
    assert_value a2, 17             # swapped would give 23

test_order_sh3add:
    addi t2, zero, 4
    flush_pipeline
    li32 a0, 0x10
    li32 a1, 1
    sh3add a2, a0, a1
    assert_value a2, 0x81           # swapped would give 0x18

test_order_wide:
    addi t2, zero, 5
    flush_pipeline
    li32 a0, 0x00010001
    li32 a1, 0x00000002
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    assert_value a2, 0x00020004     # swapped: 0x00010005
    assert_value a3, 0x00040006     # swapped: 0x00010009
    assert_value a4, 0x0008000A     # swapped: 0x00010011

# rd aliasing with the sources
test_alias:
    addi t2, zero, 6
    flush_pipeline
    li32 a0, 7
    sh1add a0, a0, a0
    assert_value a0, 21
    flush_pipeline
    li32 a0, 5
    li32 a1, 3
    sh2add a0, a0, a1
    assert_value a0, 23
    flush_pipeline
    li32 a0, 3
    li32 a1, 2
    sh3add a0, a1, a0
    assert_value a0, 19

# rd = x0 must be discarded
test_rd_zero:
    addi t2, zero, 7
    flush_pipeline
    li32 a0, 0x12345678
    li32 a1, 0x11111111
    sh1add zero, a0, a1
    sh2add zero, a0, a1
    sh3add zero, a0, a1
    flush_pipeline
    assert_value zero, 0

# x0 as source
test_rs_zero:
    addi t2, zero, 8
    flush_pipeline
    li32 a0, 0x12345678
    li32 a1, 0x11111111
    sh1add a2, zero, a1
    assert_value a2, 0x11111111
    sh2add a3, a0, zero
    assert_value a3, 0x48D159E0
    sh3add a4, zero, zero
    assert_value a4, 0

# =========================================================================
# 2. SHIFT TYPE  --  logical, top bits DISCARDED
# =========================================================================
test_shift_top_bit:
    addi t2, zero, 9
    flush_pipeline
    li32 a0, 0x80000000
    li32 a1, 0x12345678
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    assert_value a2, 0x12345678     # 0x80000000<<1 == 0, not 0x80000000
    assert_value a3, 0x12345678
    assert_value a4, 0x12345678

test_shift_c0000000:
    addi t2, zero, 10
    flush_pipeline
    li32 a0, 0xC0000000
    li32 a1, 1
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    assert_value a2, 0x80000001
    assert_value a3, 0x00000001
    assert_value a4, 0x00000001

test_shift_all_ones:
    addi t2, zero, 11
    flush_pipeline
    li32 a0, 0xFFFFFFFF
    sh1add a2, a0, zero
    sh2add a3, a0, zero
    sh3add a4, a0, zero
    assert_value a2, 0xFFFFFFFE     # not saturated to 0xFFFFFFFF
    assert_value a3, 0xFFFFFFFC
    assert_value a4, 0xFFFFFFF8

test_shift_not_arithmetic:
    addi t2, zero, 12
    flush_pipeline
    li32 a0, 0x80000001             # negative; sign bit must be shifted out
    sh1add a2, a0, zero
    sh2add a3, a0, zero
    sh3add a4, a0, zero
    assert_value a2, 0x00000002     # sign-preserving impl would give 0x80000002
    assert_value a3, 0x00000004
    assert_value a4, 0x00000008
    flush_pipeline
    li32 a0, 0x90000000
    sh1add a2, a0, zero
    sh2add a3, a0, zero
    sh3add a4, a0, zero
    assert_value a2, 0x20000000
    assert_value a3, 0x40000000
    assert_value a4, 0x80000000

# =========================================================================
# 3. WRAPPING mod 2^32, no trap, no flags
# =========================================================================
test_wrap:
    addi t2, zero, 13
    flush_pipeline
    li32 a0, 0x7FFFFFFF
    li32 a1, 2
    sh1add a2, a0, a1               # 0xFFFFFFFE + 2 -> 0
    assert_value a2, 0
    li32 a1, 4
    sh2add a3, a0, a1               # 0xFFFFFFFC + 4 -> 0
    assert_value a3, 0
    li32 a1, 8
    sh3add a4, a0, a1               # 0xFFFFFFF8 + 8 -> 0
    assert_value a4, 0

test_wrap_shift_overflows_first:
    addi t2, zero, 14
    flush_pipeline
    li32 a0, 0x40000000
    li32 a1, 0xDEADBEEF
    sh2add a2, a0, a1               # shift alone wraps to 0
    assert_value a2, 0xDEADBEEF
    flush_pipeline
    li32 a0, 0x60000000
    li32 a1, 5
    sh2add a3, a0, a1               # 0x180000000 -> 0x80000000, +5
    assert_value a3, 0x80000005

test_wrap_patterns:
    addi t2, zero, 15
    flush_pipeline
    li32 a0, 0xAAAAAAAA
    li32 a1, 0x55555555
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    assert_value a2, 0xAAAAAAA9
    assert_value a3, 0xFFFFFFFD
    assert_value a4, 0xAAAAAAA5

# mcause / mstatus must be untouched by an overflowing Zba
test_no_side_effects:
    addi t2, zero, 16
    flush_pipeline
    csrr s0, mcause
    csrr s1, mstatus
    flush_pipeline
    li32 a0, 0xFFFFFFFF
    li32 a1, 0xFFFFFFFF
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    flush_pipeline
    csrr s2, mcause
    csrr s3, mstatus
    assert_equal s0, s2
    assert_equal s1, s3
    assert_value a2, 0xFFFFFFFD
    assert_value a3, 0xFFFFFFFB
    assert_value a4, 0xFFFFFFF7

# =========================================================================
# 4. ENCODING HYGIENE
# =========================================================================
# 4a. ADD / SUB (funct3 000) unchanged, hand-encoded to bypass the assembler
test_add_sub_intact:
    addi t2, zero, 17
    flush_pipeline
    li32 a1, 100
    li32 a2, 7
    .word 0x00C58533                # add a0, a1, a2   (funct7 0000000, funct3 000)
    assert_value a0, 107
    .word 0x40C58533                # sub a0, a1, a2   (funct7 0100000, funct3 000)
    assert_value a0, 93

# 4b. funct7 0000000 with the Zba funct3 values must stay SLT / XOR / OR
test_same_funct3_funct7_zero:
    addi t2, zero, 18
    flush_pipeline
    li32 a1, 0xFFFFFFFB             # -5
    li32 a2, 3
    .word 0x00C5A533                # slt a0, a1, a2   (funct3 010)
    assert_value a0, 1
    .word 0x00C5C533                # xor a0, a1, a2   (funct3 100)
    assert_value a0, 0xFFFFFFF8
    .word 0x00C5E533                # or  a0, a1, a2   (funct3 110)
    assert_value a0, 0xFFFFFFFB
    flush_pipeline
    sltu a0, a1, a2
    assert_value a0, 0
    and  a0, a1, a2
    assert_value a0, 3

# 4c. shifts still work
test_shifts_intact:
    addi t2, zero, 19
    flush_pipeline
    li32 a1, 0xF0F0F0F0
    li32 a2, 4
    sll a0, a1, a2
    assert_value a0, 0x0F0F0F00
    srl a0, a1, a2
    assert_value a0, 0x0F0F0F0F
    sra a0, a1, a2
    assert_value a0, 0xFF0F0F0F

# 4d. OP-IMM must not be captured: funct7-looking bits are an immediate there
test_opimm_intact:
    addi t2, zero, 20
    flush_pipeline
    li32 a1, 5
    .word 0x20C5A513                # slti a0, a1, 524  (imm bits == Zba funct7|rs2)
    assert_value a0, 1
    flush_pipeline
    li32 a1, 1000
    .word 0x20C5A513
    assert_value a0, 0

# 4e. Non-Zba funct3 under funct7 0010000 must be ILLEGAL (mcause 2)
switch_to_record_trap:
    li32 t5, record_trap
    csrw mtvec, t5
    flush_pipeline

test_illegal_funct3_000:
    addi t2, zero, 21
    expect_trap 0x20C58533, 2
test_illegal_funct3_001:
    addi t2, zero, 22
    expect_trap 0x20C59533, 2
test_illegal_funct3_011:
    addi t2, zero, 23
    expect_trap 0x20C5B533, 2
test_illegal_funct3_101:
    addi t2, zero, 24
    expect_trap 0x20C5D533, 2
test_illegal_funct3_111:
    addi t2, zero, 25
    expect_trap 0x20C5F533, 2

# 4f. neighbouring funct7 values must stay ILLEGAL
test_illegal_neighbour_funct7:
    addi t2, zero, 26
    expect_trap 0x10C5A533, 2       # funct7 0001000
    expect_trap 0x30C5A533, 2       # funct7 0011000
    expect_trap 0x22C5A533, 2       # funct7 0010001
    expect_trap 0x60C5A533, 2       # funct7 0110000 (Zbs bset)
    expect_trap 0x28C5B533, 2       # funct7 0010100, funct3 011
    expect_trap 0x20059513, 2       # slli-shaped OP-IMM with funct7 0010000

# 4g. FENCE/SYSTEM opcodes untouched
test_other_opcodes:
    addi t2, zero, 27
    li32 t5, unexpected_trap
    csrw mtvec, t5
    flush_pipeline
    li32 a0, 0x5A5A5A5A
    fence
    fence.i
    assert_value a0, 0x5A5A5A5A

# =========================================================================
# 5. PIPELINE INTERACTION
# =========================================================================
# 5a. forwarding at distance 1, 2, 3 (Execute, Memory, Writeback)
test_fwd_dist1:
    addi t2, zero, 28
    flush_pipeline
    li32 a0, 1
    li32 a1, 2
    flush_pipeline
    sh1add a2, a0, a1               # 2 + 2 = 4
    sh1add a3, a2, a1               # 8 + 2 = 10
    assert_value a3, 10

test_fwd_dist2:
    addi t2, zero, 29
    flush_pipeline
    sh2add a2, a0, a1               # 4 + 2 = 6
    nop
    sh2add a3, a2, a1               # 24 + 2 = 26
    assert_value a3, 26

test_fwd_dist3:
    addi t2, zero, 30
    flush_pipeline
    sh3add a2, a0, a1               # 8 + 2 = 10
    nop
    nop
    sh3add a3, a2, a1               # 80 + 2 = 82
    assert_value a3, 82

test_fwd_into_rs2:
    addi t2, zero, 31
    flush_pipeline
    sh1add a2, a0, a1               # 2 + 2 = 4
    sh1add a3, a1, a2               # 4 + 4 = 8
    assert_value a3, 8
    flush_pipeline
    sh1add a4, a0, a1               # 4
    nop
    sh2add a5, a1, a4               # 8 + 4 = 12
    assert_value a5, 12
    flush_pipeline
    sh1add a6, a0, a1               # 4
    nop
    nop
    sh3add a7, a1, a6               # 16 + 4 = 20
    assert_value a7, 20

# both operands forwarded from different stages simultaneously
test_fwd_both:
    addi t2, zero, 32
    flush_pipeline
    li32 a0, 3
    li32 a1, 5
    flush_pipeline
    sh1add a2, a0, a1               # 6 + 5 = 11   (dist 3 from the sh2add below)
    nop
    sh2add a3, a0, a1               # 12 + 5 = 17  (dist 1)
    sh3add a4, a3, a2               # 17*8 + 11 = 147
    assert_value a4, 147

# 5b. Zba immediately before a taken branch
test_before_taken_branch:
    addi t2, zero, 33
    flush_pipeline
    li32 a0, 5
    li32 a1, 7
    flush_pipeline
    sh3add a2, a0, a1               # 40 + 7 = 47
    beq  zero, zero, btb_target
    fail
btb_target:
    assert_value a2, 47

# 5c. Zba as the branch target instruction
test_branch_target_is_zba:
    addi t2, zero, 34
    flush_pipeline
    beq  zero, zero, bt_zba
    fail
bt_zba:
    sh2add a3, a0, a1               # 20 + 7 = 27
    assert_value a3, 27

# 5d. Zba in the shadow of a taken branch must NOT execute
test_branch_shadow:
    addi t2, zero, 35
    flush_pipeline
    li32 a4, 0xABCDEF01
    flush_pipeline
    beq  zero, zero, shadow_done
    sh1add a4, a0, a1               # must be flushed
    sh2add a4, a0, a1               # must be flushed
shadow_done:
    assert_value a4, 0xABCDEF01

# 5e. Zba result feeding a branch comparison at distance 1
test_zba_feeds_branch:
    addi t2, zero, 36
    flush_pipeline
    li32 a5, 47
    flush_pipeline
    sh3add a2, a0, a1               # 47
    beq  a2, a5, zfb_ok
    fail
zfb_ok:
    flush_pipeline
    sh3add a2, a0, a1
    bne  a2, a5, zfb_bad
    beq  zero, zero, zfb_done
zfb_bad:
    fail
zfb_done:
    assert_value a2, 47

# 5f. Zba result as a load address (distance 1, 2 and 3)
test_zba_load_address:
    addi t2, zero, 37
    flush_pipeline
    li32 a0, myarr
    li32 a1, 3
    flush_pipeline
    sh2add a2, a1, a0               # &myarr[3]
    lw   a3, 0(a2)
    assert_value a3, 0xD4D4D4D4
    flush_pipeline
    sh2add a2, a1, a0
    nop
    lw   a3, 0(a2)
    assert_value a3, 0xD4D4D4D4
    flush_pipeline
    sh2add a2, a1, a0
    nop
    nop
    lw   a3, 0(a2)
    assert_value a3, 0xD4D4D4D4
    flush_pipeline
    li32 a1, 2
    sh3add a2, a1, a0               # &myarr[4]
    lw   a3, 0(a2)
    assert_value a3, 0xE5E5E5E5
    flush_pipeline
    li32 a1, 5
    sh1add a2, a1, a0               # myarr + 10 -> halfword 5
    lhu  a3, 0(a2)
    assert_value a3, 0x0000C3C3

# 5g. load-use: Zba consuming a loaded value (needs a stall)
test_load_use_into_zba:
    addi t2, zero, 38
    flush_pipeline
    li32 a0, myarr
    lw   a1, 0(a0)                  # 0xA1A1A1A1
    sh1add a2, a1, zero
    assert_value a2, 0x43434342
    flush_pipeline
    lw   a1, 4(a0)                  # 0xB2B2B2B2
    sh2add a2, zero, a1
    assert_value a2, 0xB2B2B2B2

# 5h. Zba result stored to memory and read back
test_zba_store:
    addi t2, zero, 39
    flush_pipeline
    li32 a0, 0x11111111
    li32 a1, 0x22222222
    li32 a2, scratch_var
    sh1add a3, a0, a1               # 0x22222222 + 0x22222222 = 0x44444444
    sw   a3, 0(a2)
    lw   a4, 0(a2)
    assert_value a4, 0x44444444

# 5i. Zba immediately before and after fence.i
test_zba_fence_i:
    addi t2, zero, 40
    flush_pipeline
    li32 a0, 5
    li32 a1, 7
    flush_pipeline
    sh2add a2, a0, a1               # 27
    fence.i
    assert_value a2, 27
    flush_pipeline
    sh2add a3, a0, a1               # 27
    fence.i
    sh1add a4, a3, a1               # 54 + 7 = 61
    assert_value a4, 61
    flush_pipeline
    fence.i
    sh3add a5, a0, a1               # 47
    assert_value a5, 47
    flush_pipeline
    sh1add a6, a0, a1               # 17
    fence
    sh2add a7, a6, a1               # 68 + 7 = 75
    assert_value a7, 75

# 5j. Zba feeding a JALR base register at distance 1
test_zba_jalr:
    addi t2, zero, 41
    flush_pipeline
    li32 a0, 0
    li32 a1, jalr_target
    flush_pipeline
    sh1add a2, a0, a1               # 0 + &jalr_target
    jalr zero, 0(a2)
    fail
jalr_target:
    nop

# 5k. Zba result forwarded into a CSR write and back
test_zba_csr:
    addi t2, zero, 42
    flush_pipeline
    li32 a0, 0x1000
    li32 a1, 0x234
    flush_pipeline
    sh2add a2, a0, a1               # 0x4000 + 0x234 = 0x4234
    csrw mscratch, a2
    csrr a3, mscratch
    assert_value a3, 0x4234

# =========================================================================
# 6. minstret / instret
# =========================================================================
test_minstret_single:
    addi t2, zero, 43
    flush_pipeline
    csrr s0, minstret
    nop
    csrr s1, minstret
    sub  s2, s1, s0                 # baseline: one nop
    flush_pipeline
    csrr s0, minstret
    sh2add a0, a1, a2
    csrr s1, minstret
    sub  s3, s1, s0                 # one sh2add
    flush_pipeline
    assert_equal s2, s3

test_minstret_block:
    addi t2, zero, 44
    flush_pipeline
    csrr s0, minstret
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    csrr s1, minstret
    sub  s2, s1, s0
    flush_pipeline
    csrr s0, minstret
    sh1add a0, a1, a2
    sh1add a0, a1, a2
    sh2add a0, a1, a2
    sh2add a0, a1, a2
    sh3add a0, a1, a2
    sh3add a0, a1, a2
    sh1add a0, a1, a2
    sh3add a0, a1, a2
    csrr s1, minstret
    sub  s3, s1, s0
    flush_pipeline
    assert_equal s2, s3

test_instret_alias:
    addi t2, zero, 45
    flush_pipeline
    csrr s0, instret
    sh1add a0, a1, a2
    csrr s1, instret
    sub  s2, s1, s0
    flush_pipeline
    csrr s0, instret
    nop
    csrr s1, instret
    sub  s3, s1, s0
    assert_equal s2, s3

# a flushed Zba must NOT retire
test_minstret_flushed:
    addi t2, zero, 46
    flush_pipeline
    csrr s0, minstret
    beq  zero, zero, msf1
    sh1add a0, a1, a2
msf1:
    csrr s1, minstret
    sub  s2, s1, s0
    flush_pipeline
    csrr s0, minstret
    beq  zero, zero, msf2
    nop
msf2:
    csrr s1, minstret
    sub  s3, s1, s0
    flush_pipeline
    assert_equal s2, s3

# absolute proof: N Zba instructions raise minstret by exactly N
test_minstret_absolute:
    addi t2, zero, 47
    flush_pipeline
    csrr s0, minstret
    csrr s1, minstret
    sub  s4, s1, s0                 # overhead of two adjacent reads, 0 filler
    flush_pipeline
    csrr s0, minstret
    sh1add a0, a1, a2
    sh2add a0, a1, a2
    sh3add a0, a1, a2
    sh1add a0, a1, a2
    sh2add a0, a1, a2
    sh3add a0, a1, a2
    csrr s1, minstret
    sub  s5, s1, s0
    sub  s6, s5, s4                 # must be exactly 6
    flush_pipeline
    assert_value s6, 6
    flush_pipeline
    csrr s0, instret
    csrr s1, instret
    sub  s4, s1, s0
    flush_pipeline
    csrr s0, instret
    sh3add a0, a1, a2
    sh3add a0, a1, a2
    sh3add a0, a1, a2
    csrr s1, instret
    sub  s5, s1, s0
    sub  s6, s5, s4                 # must be exactly 3
    flush_pipeline
    assert_value s6, 3

# Zba as the first instruction after a trap return
test_zba_after_mret:
    addi t2, zero, 48
    flush_pipeline
    li32 t5, record_trap
    csrw mtvec, t5
    li32 a0, 5
    li32 a1, 7
    li32 a2, 0
    li32 t5, zam_resume
    csrw mscratch, t5
    flush_pipeline
    .word 0x00000000                # illegal -> trap -> handler mrets here
zam_resume:
    sh3add a2, a0, a1
    assert_value a2, 47
    li32 t6, trap_var
    lw   t5, 0(t6)
    assert_value t5, 2
    li32 t5, unexpected_trap
    csrw mtvec, t5

# an external interrupt landing in the middle of a Zba chain
test_zba_interrupt:
    addi t2, zero, 49
    flush_pipeline
    li32 t6, zba_irq_handler
    csrw mtvec, t6
    slli t6, t1, 11
    csrs mie, t6
    slli t6, t1, 3
    csrs mstatus, t6
    li32 a0, 0x11111111
    li32 a1, 0x22222222
    addi s7, zero, 0
    flush_pipeline
    interrupt 2
    sh1add a2, a0, a1
    sh2add a3, a0, a1
    sh3add a4, a0, a1
    sh1add a5, a2, a3
    flush_pipeline
    flush_pipeline
    slli t6, t1, 3
    csrc mstatus, t6
    li32 t6, unexpected_trap
    csrw mtvec, t6
    flush_pipeline
    assert_value a2, 0x44444444
    assert_value a3, 0x66666666
    assert_value a4, 0xAAAAAAAA
    assert_value a5, 0xEEEEEEEE
    assert_value s7, 1

# =========================================================================
test_finish:
    addi t2, zero, 50
    flush_pipeline
    halt
    fail
    beq zero, zero, test_finish

    .align 4
trap_var:
    .word 0x0
scratch_var:
    .word 0x0
myarr:
    .word 0xA1A1A1A1
    .word 0xB2B2B2B2
    .word 0xC3C3C3C3
    .word 0xD4D4D4D4
    .word 0xE5E5E5E5
    .word 0xF6F6F6F6
    .word 0x07070707
    .word 0x18181818
