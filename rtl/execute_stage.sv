/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: execute_stage.sv
 */

// =============================================================================

// WHAT THIS MODULE DOES
// =============================================================================
// The Execute Stage sits between Decode and Memory. It has five jobs:
//
//  1. ALU: Compute arithmetic/logic results based on the decoded op.
//          Operand 1 = rs1 (or PC for AUIPC).
//          Operand 2 = rs2 (R-type) or immediate (I/S/U-type).
//          The ALU is NOT used for jump/branch targets (separate adder).
//
//  2. BRANCH COMPARISON: For branch instructions (BEQ, BNE, BLT, BGE,
//     BLTU, BGEU), compare rs1 and rs2 to decide if the branch is taken.
//
//  3. JUMP / BRANCH RESOLUTION: If a branch is taken or the instruction
//     is JAL/JALR, send JUMP backward to Decode/Fetch and provide the
//     target address (PC+imm for branches/JAL, rs1+imm for JALR).
//
//  4. FORWARDING OUTPUT: Combinational from current cycle's computation.
//     Exposes rd_data and rd_address so Decode's forwarding unit can
//     bypass the register file for data hazards.
//     data_valid = 0 for loads (result from Memory) and CSR (from WB).
//
//  5. PIPELINE CONTROL: Handle STALL/JUMP from Memory (backwards) and
//     register all outputs on the clock edge.
//
// KEY OUTPUTS:
//   rd_data_reg_out     = ALU result for ALU ops; PC+4 for JAL/JALR;
//                         {31'b0, branch_taken} for branches.
//   source_data_reg_out = rs2 for most ops; rs1 for CSR register ops;
//                         immediate for CSR immediate ops.
//   next_program_counter_reg_out = jump_target when jump detected, else PC+4.
// =============================================================================

module execute_stage (
    input logic clk,
    input logic rst,

    // Data inputs from Decode Stage
    input logic [31:0]   rs1_data_in,
    input logic [31:0]   rs2_data_in,
    input instruction::t instruction_in,
    input logic [31:0]   program_counter_in,

    // Registered outputs to Memory Stage
    output logic [31:0]   source_data_reg_out,
    output logic [31:0]   rd_data_reg_out,
    output instruction::t instruction_reg_out,
    output logic [31:0]   program_counter_reg_out,
    output logic [31:0]   next_program_counter_reg_out,

    // Forwarding output to Decode Stage (combinational, from current cycle)
    output forwarding::t  forwarding_out,

    // Branch prediction: prediction from Decode, feedback back to Fetch
    input  bpredict::bp_data_t bp_prediction_in,
    output bpredict::bp_data_t bp_feedback_out,

    // Pipeline control — forwards direction (Decode → Execute → Memory)
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::forwards_t  status_forwards_out,

    // Pipeline control — backwards direction (Memory → Execute → Decode)
    input  pipeline_status::backwards_t status_backwards_in,
    output pipeline_status::backwards_t status_backwards_out,

    // Jump address passthrough (Memory → Execute → Decode)
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out
);

    import pipeline_status::*;
    import op::*;

    // =========================================================================
    // Part 1: ALU operand and operation selection
    // =========================================================================
    // Maps op::t to a 4-bit ALU selector plus operand muxes.
    //
    // alu_sel encoding (standard RV32I ALU, plus the three Zba codes):
    //   0000 = ADD        0100 = SLTU       1000 = OR                  1100 = SH2ADD
    //   0001 = SUB        0101 = XOR        1001 = AND                 1101 = SH3ADD
    //   0010 = SLL        0110 = SRL        1010 = LUI (passthrough)
    //   0011 = SLT        0111 = SRA        1011 = SH1ADD
    // 1110 and 1111 remain free.
    //
    // alu_in1: rs1 for most ops, PC for AUIPC only.
    // alu_in2: rs2 for R-type, immediate for I/S/U-type.
    // Note: branches and JAL/JALR do NOT use the ALU for target computation
    //       — the jump target is computed by a separate adder (Part 3b).

    logic [31:0] alu_in1;
    logic [31:0] alu_in2;
    logic [3:0]  alu_sel;

    always_comb begin
        // Safe defaults — overridden per instruction below
        alu_in1 = rs1_data_in;
        alu_in2 = rs2_data_in;
        alu_sel = 4'b0000; // ADD

        case (instruction_in.op)

            // ----- R-type: register × register -----
            ADD:  begin alu_sel = 4'b0000; end
            SUB:  begin alu_sel = 4'b0001; end
            SLL:  begin alu_sel = 4'b0010; end
            SLT:  begin alu_sel = 4'b0011; end
            SLTU: begin alu_sel = 4'b0100; end
            XOR:  begin alu_sel = 4'b0101; end
            SRL:  begin alu_sel = 4'b0110; end
            SRA:  begin alu_sel = 4'b0111; end
            OR:   begin alu_sel = 4'b1000; end
            AND:  begin alu_sel = 4'b1001; end

            // ----- Zba: rd = (rs1 << N) + rs2 -----
            // Both operands are registers, exactly like the R-type group above,
            // so the defaults (alu_in1 = rs1, alu_in2 = rs2) are already right
            // and only the selector changes. The shift amount is not an operand;
            // it is baked into the ALU arm that each selector picks.
            SH1ADD: begin alu_sel = 4'b1011; end
            SH2ADD: begin alu_sel = 4'b1100; end
            SH3ADD: begin alu_sel = 4'b1101; end

            // ----- I-type: register × immediate -----
            ADDI:  begin alu_sel = 4'b0000; alu_in2 = instruction_in.immediate; end
            SLTI:  begin alu_sel = 4'b0011; alu_in2 = instruction_in.immediate; end
            SLTIU: begin alu_sel = 4'b0100; alu_in2 = instruction_in.immediate; end
            XORI:  begin alu_sel = 4'b0101; alu_in2 = instruction_in.immediate; end
            ORI:   begin alu_sel = 4'b1000; alu_in2 = instruction_in.immediate; end
            ANDI:  begin alu_sel = 4'b1001; alu_in2 = instruction_in.immediate; end
            SLLI:  begin alu_sel = 4'b0010; alu_in2 = instruction_in.immediate; end
            SRLI:  begin alu_sel = 4'b0110; alu_in2 = instruction_in.immediate; end
            SRAI:  begin alu_sel = 4'b0111; alu_in2 = instruction_in.immediate; end

            // ----- Loads / Stores: address = rs1 + immediate -----
            LB, LH, LW, LBU, LHU,
            SB, SH, SW: begin
                alu_sel = 4'b0000;
                alu_in2 = instruction_in.immediate;
            end

            // ----- LUI: pass immediate through (upper 20 bits) -----
            LUI: begin
                alu_sel = 4'b1010;
                alu_in2 = instruction_in.immediate;
            end

            // ----- AUIPC: PC + immediate -----
            AUIPC: begin
                alu_sel = 4'b0000;
                alu_in1 = program_counter_in;
                alu_in2 = instruction_in.immediate;
            end

            // ----- M extension: the ALU is not involved -----
            // All eight M ops take their operands straight from rs1/rs2 in Part 2b
            // and their result is muxed into rd_data in Part 4, so the ALU output
            // is simply discarded for them. They are listed explicitly
            // rather than left to `default` so that a reader auditing "which ops
            // reach which unit" can see every op class named exactly once.
            MUL, MULH, MULHSU, MULHU,
            DIV, DIVU, REM, REMU: begin
                alu_sel = 4'b0000;
            end

            // ----- JAL, JALR, Branches: ALU unused for target (separate adder) -----
            // Keep defaults (rs1 + rs2 with ADD). rd_data is set separately.
            default: begin
                alu_sel = 4'b0000;
            end
        endcase
    end

    // =========================================================================
    // Part 2: ALU computation
    // =========================================================================
    // Purely combinational arithmetic / logic unit.

    logic [31:0] alu_result;

    always_comb begin
        case (alu_sel)
            4'b0000: alu_result = $signed(alu_in1) + $signed(alu_in2);                // ADD
            4'b0001: alu_result = $signed(alu_in1) - $signed(alu_in2);                // SUB
            4'b0010: alu_result = alu_in1 << alu_in2[4:0];                            // SLL
            4'b0011: alu_result = ($signed(alu_in1) < $signed(alu_in2)) ? 32'd1 : 32'd0; // SLT
            4'b0100: alu_result = (alu_in1 < alu_in2) ? 32'd1 : 32'd0;               // SLTU
            4'b0101: alu_result = alu_in1 ^ alu_in2;                                  // XOR
            4'b0110: alu_result = alu_in1 >> alu_in2[4:0];                            // SRL
            4'b0111: alu_result = $signed(alu_in1) >>> alu_in2[4:0];                  // SRA
            4'b1000: alu_result = alu_in1 | alu_in2;                                  // OR
            4'b1001: alu_result = alu_in1 & alu_in2;                                  // AND
            4'b1010: alu_result = alu_in2;                                             // LUI passthrough

            // Zba: shift rs1 left by a fixed 1/2/3 and add rs2.
            // The shift is LOGICAL over the full 32 bits — whatever is pushed past
            // bit 31 is dropped, never sign-extended, so a negative rs1 loses its
            // sign bit exactly like any other bit. The add then wraps modulo 2^32;
            // there is no overflow trap and no flag to set.
            // Three fixed shifts rather than one shift by a variable amount: the
            // amount stays a compile-time constant, which is pure wiring into the
            // adder, whereas a variable amount would ask synthesis for a second
            // barrel shifter beside the one SLL/SRL/SRA already share.
            4'b1011: alu_result = (alu_in1 << 1) + alu_in2;                            // SH1ADD
            4'b1100: alu_result = (alu_in1 << 2) + alu_in2;                            // SH2ADD
            4'b1101: alu_result = (alu_in1 << 3) + alu_in2;                            // SH3ADD

            default: alu_result = 32'b0;
        endcase
    end

    // =========================================================================
    // Part 2b: M extension — multiply and divide unit
    // =========================================================================
    // DESIGN DECISION 1 — the M results do NOT go through `alu_sel`.
    //
    // alu_sel is a 4-bit local with codes 0000..1101 taken and only 1110/1111
    // free, so eight M results would have forced it to 5 bits. Widening it is
    // safe with respect to the frozen models (it is local to this module, not a
    // struct field or a port), so the choice was made on other grounds:
    //
    //   * Half of the M results are not combinational at all. DIV/DIVU/REM/REMU
    //     come out of the sequential FSM below, and a sequential result cannot be
    //     an arm of the `always_comb` case that computes alu_result. Splitting the
    //     family across two mechanisms would be worse than keeping it whole.
    //   * Leaving the ALU's case statement at exactly 14 arms keeps its
    //     synthesised structure identical to today's. With routed WNS at
    //     +0.221 ns there is no margin to spend perturbing a block that is
    //     already on (or near) the critical path for no functional gain.
    //   * The cost is one extra 2:1 mux level on rd_data (Part 4), which is
    //     cheaper than six extra arms inside the ALU mux would have been.
    //
    // So: `m_result` is a second result bus that meets the ALU result at the
    // rd_data mux, and alu_sel stays 4 bits with 1110/1111 still free.
    //
    // DESIGN DECISION 2 — the multiply is REGISTERED (2 cycles), not combinational.
    //
    // A 32x32->64 multiply on this part is an array of DSP48E1 tiles (each 25x18
    // signed), so a 33x33 product needs four of them plus an adder tree. Run with
    // no internal pipeline register that array is one of the slowest things that
    // can be put in a datapath; on an xc7a35t -1 it is comfortably the deepest
    // combinational block in this core. It would land on the path
    //
    //     decode output regs -> multiplier -> rd_data mux -> forwarding_out
    //                        -> decode's forwarding mux -> decode output regs
    //
    // which is a single 20 ns clock period. The routed design closes today with
    // WNS = +0.221 ns, i.e. about 1% of the period in hand, so there is no room
    // to absorb a new block of that depth and no honest way to claim it would
    // fit. Registering the product instead puts a flop directly on the
    // multiplier output, which is exactly the shape Vivado needs to pull the
    // register into the DSP48E1's own P register — the difference between a DSP
    // running at roughly a hundred MHz and one running at several hundred.
    //
    // The price is one stall cycle per multiply. Since the divider needs the
    // execute-side stall generator anyway (Part 5b), the multiply costs no extra
    // machinery at all — it is simply the shortest possible M operation, 2 cycles
    // against the divider's 34.
    //
    // Reverting to a single-cycle multiply, should synthesis later show room for
    // it, is two edits: drive `m_result` from `mul_result` instead of `m_mul_reg`
    // for the multiply case, and drop the MUL arm of the FSM so `m_ready` is
    // asserted immediately. Nothing else in the stage depends on the latency.

    logic is_m_mul;   // MUL / MULH / MULHSU / MULHU
    logic is_m_div;   // DIV / DIVU / REM  / REMU
    logic is_m;       // any M-extension op

    always_comb begin
        case (instruction_in.op)
            MUL, MULH, MULHSU, MULHU: is_m_mul = 1'b1;
            default:                  is_m_mul = 1'b0;
        endcase
        case (instruction_in.op)
            DIV, DIVU, REM, REMU: is_m_div = 1'b1;
            default:              is_m_div = 1'b0;
        endcase
    end

    assign is_m = is_m_mul || is_m_div;

    // The M unit only runs for a real instruction. A BUBBLE, or an instruction
    // that already carries an exception from an earlier stage, must neither start
    // it nor stall on it — otherwise a flushed divide would hold the pipeline.
    logic m_active;
    assign m_active = is_m && (status_forwards_in == VALID);

    // -------------------------------------------------------------------------
    // Part 2b-1: One 33x33 signed multiplier serves all four MUL* forms
    // -------------------------------------------------------------------------
    // The four forms differ only in how the 32-bit operands are extended to 33
    // bits before a single signed multiply:
    //
    //   MUL    (f3 000): low 32 bits of the product. The low half is identical
    //                    for every signedness combination, so this reuses the
    //                    signed/signed extension rather than paying for a mux.
    //   MULH   (f3 001): rs1 signed,   rs2 signed   -> product[63:32]
    //   MULHSU (f3 010): rs1 SIGNED,   rs2 UNSIGNED -> product[63:32]
    //   MULHU  (f3 011): rs1 unsigned, rs2 unsigned -> product[63:32]
    //
    // MULHSU is the form that is usually got wrong: it is NOT "multiply and then
    // fix up the sign", and it is NOT symmetric — swapping the operands changes
    // the answer. Sign-extending rs1 to 33 bits while zero-extending rs2 to 33
    // bits and doing ONE signed 33x33 multiply gives the exact 66-bit product,
    // whose bits [63:32] are the required high half with no correction term.
    //
    // 33x33 rather than 64x64: the product is exact in 66 bits, and 33x33 is
    // what an Artix-7 DSP48E1 array actually wants (25x18 signed tiles).

    logic mul_a_signed;
    logic mul_b_signed;

    always_comb begin
        case (instruction_in.op)
            MULHU:   begin mul_a_signed = 1'b0; mul_b_signed = 1'b0; end
            MULHSU:  begin mul_a_signed = 1'b1; mul_b_signed = 1'b0; end
            default: begin mul_a_signed = 1'b1; mul_b_signed = 1'b1; end // MUL, MULH
        endcase
    end

    logic signed [32:0] mul_op_a;
    logic signed [32:0] mul_op_b;
    // 66 bits is the full self-determined width of a 33x33 signed product. Only
    // [63:0] can ever be significant for the operand ranges this unit sees, but
    // carrying the full width means the correctness of the low 64 bits needs no
    // argument about when a 64-bit signed container would overflow (it does, for
    // MULHU of 0xFFFFFFFF x 0xFFFFFFFF). The top two bits are then genuinely dead.
    /* verilator lint_off UNUSEDSIGNAL */
    logic signed [65:0] mul_product;
    /* verilator lint_on UNUSEDSIGNAL */

    assign mul_op_a    = $signed({mul_a_signed & rs1_data_in[31], rs1_data_in});
    assign mul_op_b    = $signed({mul_b_signed & rs2_data_in[31], rs2_data_in});
    assign mul_product = mul_op_a * mul_op_b;

    logic [31:0] mul_result;
    assign mul_result = (instruction_in.op == MUL) ? mul_product[31:0]
                                                   : mul_product[63:32];

    // -------------------------------------------------------------------------
    // Part 2b-2: Divider — operand preparation and the mandated special results
    // -------------------------------------------------------------------------
    // DESIGN DECISION 3 — RESTORING division, one quotient bit per cycle, on
    // magnitudes, with the signs applied to the operands going in and to the
    // results coming out.
    //
    // Restoring rather than non-restoring: the two cost the same number of
    // iterations, and restoring needs no final correction step for a negative
    // partial remainder. Its inner loop is one 33-bit subtract whose borrow bit
    // IS the quotient bit, and a 2:1 mux that keeps the difference when it did
    // not borrow. Non-restoring would trade that mux for an add/subtract
    // selected by the previous bit, plus a fix-up pass at the end — more control
    // for no fewer cycles.
    //
    // Magnitudes rather than a signed divider: RISC-V rounds division toward
    // zero, which is exactly what an unsigned divide on magnitudes plus a sign
    // fix-up gives. The remainder then takes the sign of the DIVIDEND, not of
    // the divisor, which is why `m_rem_neg` tracks only rs1's sign. (-7/2 = -3
    // remainder -1; 7/-2 = -3 remainder +1.)
    //
    // Note that abs() of 0x80000000 is 0x80000000, which read as an UNSIGNED
    // 32-bit number is 2^31 — the correct magnitude. Two's complement negation
    // of the most negative value being itself is normally a hazard; here it is
    // exactly the behaviour the magnitude path needs, with no special case.

    logic div_is_signed;      // DIV / REM  (DIVU / REMU are unsigned)
    logic div_wants_quotient; // DIV / DIVU (REM / REMU want the remainder)

    always_comb begin
        case (instruction_in.op)
            DIV, REM: div_is_signed = 1'b1;
            default:  div_is_signed = 1'b0;
        endcase
        case (instruction_in.op)
            DIV, DIVU: div_wants_quotient = 1'b1;
            default:   div_wants_quotient = 1'b0;
        endcase
    end

    // ---- The two mandated special cases -------------------------------------
    // RISC-V NEVER traps on a divide. Both of these produce a defined value, and
    // both are handled as a combinational EARLY-OUT that skips the iteration
    // entirely: the answers do not depend on the quotient bits, so paying 32
    // cycles for them would be pure waste, and — for REM/REMU by zero — the
    // iterative core would produce the wrong answer anyway (it would leave a
    // shifted partial remainder in m_rem, not rs1).
    //
    //   rs2 == 0:                  DIV  -> -1 (0xFFFFFFFF)   REM  -> rs1
    //                              DIVU -> 0xFFFFFFFF        REMU -> rs1
    //   rs1 == -2^31 && rs2 == -1: DIV  -> 0x80000000        REM  -> 0
    //                              (DIVU/REMU cannot overflow, so the overflow
    //                               early-out is gated on div_is_signed)
    //
    // The overflow case would in fact come out right through the iterative path
    // too — |−2^31| / |−1| = 2^31 = 0x80000000, and the quotient sign is
    // 1 XOR 1 = 0 so it is not negated — but stating it as an early-out puts the
    // architecturally mandated constant in the RTL where it can be read off and
    // audited, instead of leaving it as an emergent property of the datapath.

    logic div_by_zero;
    logic div_overflow;
    logic m_early;                 // result available combinationally, no stall

    assign div_by_zero  = is_m_div && (rs2_data_in == 32'h0000_0000);
    assign div_overflow = is_m_div && div_is_signed
                          && (rs1_data_in == 32'h8000_0000)
                          && (rs2_data_in == 32'hFFFF_FFFF);
    assign m_early      = div_by_zero || div_overflow;

    logic [31:0] m_early_result;

    always_comb begin
        if (div_by_zero)
            m_early_result = div_wants_quotient ? 32'hFFFF_FFFF : rs1_data_in;
        else
            m_early_result = div_wants_quotient ? 32'h8000_0000 : 32'h0000_0000;
    end

    // ---- Operand magnitudes and result signs --------------------------------
    logic        div_dividend_neg;
    logic        div_divisor_neg;
    logic [31:0] div_dividend_mag;
    logic [31:0] div_divisor_mag;

    assign div_dividend_neg = div_is_signed && rs1_data_in[31];
    assign div_divisor_neg  = div_is_signed && rs2_data_in[31];
    assign div_dividend_mag = div_dividend_neg ? (~rs1_data_in + 32'd1) : rs1_data_in;
    assign div_divisor_mag  = div_divisor_neg  ? (~rs2_data_in + 32'd1) : rs2_data_in;

    // -------------------------------------------------------------------------
    // Part 2b-3: The M unit state machine
    // -------------------------------------------------------------------------
    // States:
    //   M_IDLE  — nothing in flight. An active M op that is not an early-out
    //             starts here: the multiply latches its product and goes
    //             straight to M_READY, the divide loads its registers and goes
    //             to M_RUN with a 32-iteration counter.
    //   M_RUN   — one restoring-division step per clock. On the step that takes
    //             the counter to zero the registers already hold the final
    //             magnitude quotient and remainder, so the state advances
    //             directly to M_READY; there is no separate fix-up state
    //             because the sign correction is combinational (Part 2b-4).
    //   M_READY — the result for the instruction currently in Execute is
    //             available. Execute stops stalling and retires it.
    //
    // The FSM is DRIVEN BY, not independent of, the pipeline control:
    //   * JUMP from Memory/Writeback resets it unconditionally — see Part 5b for
    //     why abandoning is the only correct response and why it cannot hang.
    //   * STALL from Memory does NOT freeze it. Decode holds its output
    //     registers while anything downstream stalls, so rs1/rs2/instruction are
    //     bit-stable, and iterating during a memory stall is free progress. A
    //     divide that finishes mid-stall simply parks in M_READY.
    //   * Any cycle in which the instruction actually leaves Execute returns the
    //     FSM to M_IDLE, so back-to-back M ops each start from a clean state.

    localparam logic [1:0] M_IDLE  = 2'd0;
    localparam logic [1:0] M_RUN   = 2'd1;
    localparam logic [1:0] M_READY = 2'd2;

    logic [1:0]  m_state;
    logic [5:0]  m_count;      // remaining iterations, 32 -> 0
    logic [31:0] m_rem;        // partial remainder (magnitude)
    logic [31:0] m_quo;        // dividend shifting out / quotient shifting in
    logic [31:0] m_divisor;    // divisor magnitude, latched at load
    logic        m_quo_neg;    // negate the quotient at the end?
    logic        m_rem_neg;    // negate the remainder at the end?
    logic [31:0] m_mul_reg;    // registered multiply result

    // One restoring-division step, computed combinationally from the registers.
    // {m_rem, m_quo} is one 64-bit shift register: the dividend shifts out of the
    // top of m_quo into the bottom of m_rem while the quotient bits shift into
    // the bottom of m_quo behind it. After 32 steps m_quo holds the quotient and
    // m_rem the remainder, both as magnitudes.
    //
    // 33 bits are needed for the shifted remainder: before the subtract it can be
    // as large as 2*(divisor-1)+1 = 2*divisor-1. The borrow out of the 33-bit
    // subtract is the inverted quotient bit, so no separate comparator is built.
    logic [32:0] div_shifted;
    logic [32:0] div_diff;
    logic        div_step_take;

    assign div_shifted   = {m_rem, m_quo[31]};
    assign div_diff      = div_shifted - {1'b0, m_divisor};
    assign div_step_take = !div_diff[32];   // no borrow => shifted >= divisor

    logic [31:0] div_rem_next;
    logic [31:0] div_quo_next;

    // Both assignments are safe at 32 bits: if the subtract was taken the result
    // is below the divisor, and if it was not, div_shifted was itself below the
    // divisor, so bit 32 is zero either way.
    assign div_rem_next = div_step_take ? div_diff[31:0] : div_shifted[31:0];
    assign div_quo_next = {m_quo[30:0], div_step_take};

    always_ff @(posedge clk) begin
        if (rst) begin
            m_state   <= M_IDLE;
            m_count   <= 6'd0;
            m_rem     <= 32'b0;
            m_quo     <= 32'b0;
            m_divisor <= 32'b0;
            m_quo_neg <= 1'b0;
            m_rem_neg <= 1'b0;
            m_mul_reg <= 32'b0;

        end else if (status_backwards_in == JUMP) begin
            // Flushed from behind: the instruction in Execute is on the wrong
            // path or is being pre-empted by a trap. Abandon whatever is running
            // — including a result already sitting in M_READY, which belongs to
            // an instruction that is now being squashed to a BUBBLE.
            m_state <= M_IDLE;

        end else if ((status_backwards_in == STALL) || m_stall) begin
            // The instruction is staying in Execute for at least one more cycle,
            // either because Memory is stalled or because we are stalling on it
            // ourselves. Either way its operands are held, so run the unit.
            case (m_state)
                M_IDLE: begin
                    if (m_active && !m_early) begin
                        if (is_m_mul) begin
                            m_mul_reg <= mul_result;
                            m_state   <= M_READY;
                        end else begin
                            m_rem     <= 32'b0;
                            m_quo     <= div_dividend_mag;
                            m_divisor <= div_divisor_mag;
                            m_quo_neg <= div_dividend_neg ^ div_divisor_neg;
                            m_rem_neg <= div_dividend_neg;
                            m_count   <= 6'd32;
                            m_state   <= M_RUN;
                        end
                    end
                end

                M_RUN: begin
                    m_rem   <= div_rem_next;
                    m_quo   <= div_quo_next;
                    m_count <= m_count - 6'd1;
                    if (m_count == 6'd1)
                        m_state <= M_READY;
                end

                M_READY: begin
                    // Result is ready but the instruction cannot leave yet
                    // (Memory is stalling). Park until it can.
                end

                default: m_state <= M_IDLE;
            endcase

        end else begin
            // The instruction leaves Execute this cycle (or there is no M op at
            // all). Either way the unit is free again next cycle.
            m_state <= M_IDLE;
        end
    end

    // -------------------------------------------------------------------------
    // Part 2b-4: Result selection and the ready/stall signals
    // -------------------------------------------------------------------------
    logic [31:0] div_raw;
    logic        div_neg;
    logic [31:0] div_result;

    assign div_raw    = div_wants_quotient ? m_quo     : m_rem;
    assign div_neg    = div_wants_quotient ? m_quo_neg : m_rem_neg;
    assign div_result = div_neg ? (~div_raw + 32'd1) : div_raw;

    logic [31:0] m_result;

    always_comb begin
        if (m_early)
            m_result = m_early_result;
        else if (is_m_mul)
            m_result = m_mul_reg;
        else
            m_result = div_result;
    end

    // m_ready: is `m_result` the correct answer for the instruction currently in
    // Execute? True immediately for an early-out, otherwise only in M_READY.
    // m_stall: Execute has an M op it cannot retire yet. This is the ONLY new
    // reason Execute can stall, and it is the signal Part 5b turns into a
    // backwards STALL.
    logic m_ready;
    logic m_stall;

    assign m_ready = m_early || (m_state == M_READY);
    assign m_stall = m_active && !m_ready;

    // =========================================================================
    // Part 3a: Branch comparison
    // =========================================================================
    // Compares rs1 and rs2 for branch instructions.

    logic branch_taken;

    always_comb begin
        case (instruction_in.op)
            BEQ:     branch_taken = (rs1_data_in == rs2_data_in);
            BNE:     branch_taken = (rs1_data_in != rs2_data_in);
            BLT:     branch_taken = ($signed(rs1_data_in) <  $signed(rs2_data_in));
            BGE:     branch_taken = ($signed(rs1_data_in) >= $signed(rs2_data_in));
            BLTU:    branch_taken = (rs1_data_in <  rs2_data_in);
            BGEU:    branch_taken = (rs1_data_in >= rs2_data_in);
            default: branch_taken = 1'b0;
        endcase
    end

    // =========================================================================
    // Part 3b: Jump target computation (separate from ALU)
    // =========================================================================
    // JALR: (rs1 + immediate) & ~1  (RISC-V spec: clear LSB of target)
    // Everything else: PC + immediate
    // This is always computed; the backwards pipeline control decides whether
    // to actually use it as the jump address.

    logic [31:0] jump_target;

    always_comb begin
        if (instruction_in.op == JALR)
            jump_target = (rs1_data_in + instruction_in.immediate) & 32'hFFFFFFFE;
        else
            jump_target = program_counter_in + instruction_in.immediate;
    end

    // =========================================================================
    // Part 4: Result selection (combinational)
    // =========================================================================
    // rd_data:      ALU result for ALU ops / loads / stores / LUI / AUIPC;
    //               PC+4 for JAL/JALR (return address);
    //               {31'b0, branch_taken} for branches.
    // source_data:  rs1 for CSR register ops; immediate for CSR-imm; rs2 otherwise.
    // next_pc:      jump_target when jump detected, else PC+4.
    // jump_detected: branch taken or unconditional jump, only for VALID instructions.

    logic [31:0] rd_data;
    logic [31:0] source_data;
    logic [31:0] pc_plus_4;
    logic        is_branch;
    logic        is_jump;
    logic        is_mispredicted_branch;
    logic        jump_detected;
    logic [31:0] corrected_address;
    logic [31:0] next_pc;

    assign pc_plus_4 = program_counter_in + 32'd4;

    // Is this a branch or jump instruction?
    always_comb begin
        case (instruction_in.op)
            BEQ, BNE, BLT, BGE, BLTU, BGEU: is_branch = 1'b1;
            default:                          is_branch = 1'b0;
        endcase
        case (instruction_in.op)
            JAL, JALR: is_jump = 1'b1;
            default:   is_jump = 1'b0;
        endcase
    end

    // rd_data: what gets written to rd (and forwarded)
    //   JAL/JALR: return address (PC+4)
    //   Branches: comparison result (0 or 1)
    //   CSR:      0 (actual CSR read value comes from Writeback)
    //   Others:   ALU result
    logic is_csr;
    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI: is_csr = 1'b1;
            default: is_csr = 1'b0;
        endcase
    end

    always_comb begin
        if (is_jump)
            rd_data = pc_plus_4;
        else if (is_branch)
            rd_data = {31'b0, branch_taken};
        else if (is_csr)
            rd_data = 32'b0;
        else if (is_m)
            rd_data = m_result;
        else
            rd_data = alu_result;
    end

    // source_data carries the "side-effect operand":
    //   CSR reg  → rs1 (value to write to CSR)
    //   CSR imm  → immediate (zero-extended zimm)
    //   Others   → rs2 (data for stores; unused for most other ops)
    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRS, CSRRC:    source_data = rs1_data_in;
            CSRRWI, CSRRSI, CSRRCI: source_data = instruction_in.immediate;
            default:                 source_data = rs2_data_in;
        endcase
    end

    // Misprediction: branch actual outcome differs from what the predictor assumed.
    // A correctly-predicted branch requires no pipeline flush — Fetch already went
    // to the right address speculatively.
    assign is_mispredicted_branch = is_branch
                                    && (branch_taken != bp_prediction_in.predicted_taken)
                                    && (status_forwards_in == VALID);

    // Jump detected: unconditional jumps always flush; branches only flush on misprediction.
    // NOTE: with predicted_taken=0 (mode 0 / never taken), is_mispredicted_branch reduces
    // to (is_branch && branch_taken && VALID), identical to the original formulation.
    assign jump_detected = (is_mispredicted_branch || is_jump)
                           && (status_forwards_in == VALID);

    // Corrected address: where we should have gone when prediction was wrong.
    assign corrected_address = branch_taken ? jump_target : pc_plus_4;

    // Next PC: mispredicted branch → corrected address; JAL/JALR → target; else PC+4.
    assign next_pc = is_mispredicted_branch ? corrected_address :
                     is_jump                ? jump_target        :
                                              pc_plus_4;


    // =========================================================================
    // Part 5: Pipeline control — backwards direction (combinational)
    // =========================================================================
    // Priority: JUMP from Memory > STALL from Memory > OUR OWN STALL >
    //           self-detected jump > READY.
    //
    // jump_address_backwards_out: always the computed jump_target when not
    // passing through from Memory. This is available for Decode/Fetch even
    // when no jump occurs (they ignore it unless backwards status = JUMP).
    //
    // ---- Part 5b: why the new arm sits exactly here --------------------------
    // Until the M extension, Execute never stalled on its own behalf; this block
    // only relayed Memory's STALL/JUMP. The divider changes that, and the order
    // of the four arms is the whole of the arbitration:
    //
    //  1. JUMP from behind wins over everything. It means Writeback is taking a
    //     trap, an interrupt, an MRET or a FENCE.I, or Memory is relaying one,
    //     and the instruction sitting in Execute is being squashed. A divide in
    //     flight belongs to that squashed instruction, so it is ABANDONED, not
    //     completed (Part 2b-3 resets the FSM on the same condition). Continuing
    //     to assert STALL here instead would be the classic hang: Decode and
    //     Fetch would never see the JUMP, the pipeline would never redirect, and
    //     the core would sit in the divide forever. Discarding a finished result
    //     is likewise correct — the flushed instruction is re-fetched and the
    //     divide re-run when MRET returns to mepc.
    //
    //  2. STALL from Memory wins over our own stall, because it is not a choice:
    //     Memory has a Wishbone transaction in progress that cannot be aborted.
    //     Relaying it produces the same backwards signal our own stall would
    //     have produced anyway, so the two are indistinguishable upstream and
    //     the divider simply keeps iterating underneath (see Part 2b-3).
    //
    //  3. Our own stall. Decode already honours a STALL from Execute — it holds
    //     its output registers and relays the STALL to Fetch, which freezes the
    //     PC — so no upstream change was needed to add this arm.
    //
    //  4. Self-detected jump, unchanged. This can never coincide with an M stall:
    //     `jump_detected` requires is_branch or is_jump, and no M op is either.
    //     The arms are therefore mutually exclusive and the relative order of 3
    //     and 4 is not load-bearing; 3 is placed first only for readability.

    always_comb begin
        if (status_backwards_in == JUMP) begin
            // Memory/Writeback issued JUMP — pass through
            status_backwards_out       = JUMP;
            jump_address_backwards_out = jump_address_backwards_in;

        end else if (status_backwards_in == STALL) begin
            // Memory is stalling — propagate backward
            status_backwards_out       = STALL;
            jump_address_backwards_out = jump_target;

        end else if (m_stall) begin
            // The M unit needs more cycles for the instruction in Execute.
            status_backwards_out       = STALL;
            jump_address_backwards_out = jump_target;

        end else if (jump_detected) begin
            // Execute detected a misprediction or JAL/JALR — flush behind us
            status_backwards_out       = JUMP;
            jump_address_backwards_out = next_pc;

        end else begin
            // Normal operation — pipeline flows freely
            // jump_address always carries the computed target (ignored upstream)
            status_backwards_out       = READY;
            jump_address_backwards_out = jump_target;
        end
    end

    // =========================================================================
    // Part 6: Forwarding output (combinational from current cycle)
    // =========================================================================
    // Exposes the current instruction's result so Decode can forward it
    // to a dependent instruction instead of reading a stale register file value.
    //
    // data:       the current cycle's rd result (combinational).
    // address:    rd_address from instruction_in (no suppression — the decoder
    //             already sets rd_address=0 for instructions that don't write rd).
    // data_valid: 0 for loads (result from Memory) and CSR (from Writeback),
    //             and for non-VALID status (BUBBLE/exceptions).
    //             data_valid=0 causes Decode to stall on address match.

    always_comb begin
        forwarding_out.data = rd_data;

        // Suppress forwarding address when instruction is not VALID
        // (BUBBLE / exception — no register write will occur)
        if (status_forwards_in != VALID)
            forwarding_out.address = 5'b0;
        else
            forwarding_out.address = instruction_in.rd_address;

        // data_valid = 0 when:
        //   - data not ready (loads: from Memory, CSR: from Writeback)
        //   - system instructions that don't produce register results
        //   - misaligned jump (instruction will trap, result is invalid)
        //   - status is not VALID (BUBBLE / exception from Decode)
        if (misaligned_jump)
            forwarding_out.data_valid = 1'b0;
        else case (instruction_in.op)
            LB, LH, LW, LBU, LHU,
            CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI,
            FENCE, FENCE_I:
                forwarding_out.data_valid = 1'b0;
            // M ops: the result is only real once the unit says so. While the
            // divider is iterating, `m_result` is a partial remainder, so
            // data_valid must be 0 — same contract a load already uses. In
            // practice Decode is held by our STALL and never samples it, but a
            // forwarding output that advertises garbage as valid is a trap for
            // the next person, and Decode's forwarding mux does read `.data` on
            // an address match regardless of data_valid.
            MUL, MULH, MULHSU, MULHU,
            DIV, DIVU, REM, REMU:
                forwarding_out.data_valid = m_ready && (status_forwards_in == VALID);
            default:
                forwarding_out.data_valid = (status_forwards_in == VALID);
        endcase
    end

    // =========================================================================
    // Part 6b: Branch prediction feedback (combinational)
    // =========================================================================
    // Tells the branch predictor in Fetch the actual branch outcome so it can
    // update its 2-bit counter table. Gated by !STALL so the counter updates
    // exactly once per branch (not repeatedly during a multi-cycle stall).

    assign bp_feedback_out.valid          = is_branch
                                            && (status_forwards_in == VALID)
                                            && (status_backwards_in != STALL);
    assign bp_feedback_out.was_taken      = branch_taken;
    assign bp_feedback_out.predicted_taken = bp_prediction_in.predicted_taken;
    assign bp_feedback_out.index          = bp_prediction_in.index;

    // =========================================================================
    // Part 7: Output registers — updated on clock edge
    // =========================================================================
    // Rules (same pattern as decode_stage):
    //   rst            → NOP / BUBBLE, zero everything
    //   STALL from Mem → hold all outputs (registers retain value)
    //   JUMP from Mem  → insert BUBBLE (current instruction is from wrong path)
    //                    but still update data values for register consistency
    //   m_stall        → hold all outputs, but hand Memory a BUBBLE so it does
    //                    not re-execute the instruction we already sent it
    //   Normal / self-jump → register computed values

    // Misalignment detection for jump targets (use next_pc which reflects corrected address)
    logic misaligned_jump;
    assign misaligned_jump = jump_detected && (next_pc[1:0] != 2'b00);

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_data_reg_out              <= 32'b0;
            source_data_reg_out          <= 32'b0;
            instruction_reg_out          <= instruction::NOP;
            program_counter_reg_out      <= constants::RESET_ADDRESS;
            next_program_counter_reg_out <= constants::RESET_ADDRESS;
            status_forwards_out          <= BUBBLE;

        end else if (status_backwards_in == STALL) begin
            // Memory is stalling — hold all registered outputs unchanged

        end else if (status_backwards_in == JUMP) begin
            // Memory/Writeback issued JUMP — our instruction is from the wrong path.
            // Update data for register consistency; squash to NOP/BUBBLE.
            // This arm is deliberately ABOVE the m_stall arm: a flush outranks an
            // unfinished divide, and taking it is what lets the FSM go back to
            // M_IDLE (Part 2b-3) instead of stalling forever behind a dead
            // instruction. rd_data here is the divider's partial state, which is
            // harmless precisely because the status is forced to BUBBLE.
            rd_data_reg_out              <= rd_data;
            source_data_reg_out          <= source_data;
            program_counter_reg_out      <= program_counter_in;
            next_program_counter_reg_out <= next_pc;
            instruction_reg_out          <= instruction_in;
            status_forwards_out          <= BUBBLE;

        end else if (m_stall) begin
            // The M unit is still working. Hold every data register — the
            // instruction has not produced a result yet — but tell Memory BUBBLE
            // so it treats the (unchanged) instruction it already consumed last
            // cycle as nothing at all. This is memory_stage's own mem_stall
            // pattern: hold the data, forward a BUBBLE. Without the BUBBLE,
            // Memory would see the previous instruction re-presented as VALID
            // every cycle of the stall and would re-run its bus transaction.
            status_forwards_out <= BUBBLE;

        end else begin
            // Normal operation (including self-detected jump — the instruction
            // itself is valid and proceeds to Memory; only Decode/Fetch are flushed).
            rd_data_reg_out              <= rd_data;
            source_data_reg_out          <= source_data;
            instruction_reg_out          <= instruction_in;
            program_counter_reg_out      <= program_counter_in;
            next_program_counter_reg_out <= next_pc;
            if (misaligned_jump)
                status_forwards_out      <= FETCH_MISALIGNED;
            else
                status_forwards_out      <= status_forwards_in;
        end
    end

endmodule
