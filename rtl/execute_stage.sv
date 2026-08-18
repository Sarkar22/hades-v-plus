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
    // Priority: JUMP from Memory > STALL from Memory > self-detected jump > READY.
    //
    // jump_address_backwards_out: always the computed jump_target when not
    // passing through from Memory. This is available for Decode/Fetch even
    // when no jump occurs (they ignore it unless backwards status = JUMP).

    always_comb begin
        if (status_backwards_in == JUMP) begin
            // Memory/Writeback issued JUMP — pass through
            status_backwards_out       = JUMP;
            jump_address_backwards_out = jump_address_backwards_in;

        end else if (status_backwards_in == STALL) begin
            // Memory is stalling — propagate backward
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
            rd_data_reg_out              <= rd_data;
            source_data_reg_out          <= source_data;
            program_counter_reg_out      <= program_counter_in;
            next_program_counter_reg_out <= next_pc;
            instruction_reg_out          <= instruction_in;
            status_forwards_out          <= BUBBLE;

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
