/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl, Charles Manning
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: branch_predictor.sv
 *
 * Branch predictor submodule for the Fetch stage.
 * Implements four selectable algorithms selected by bp_control_in[1:0]:
 *   0 = Predict Never Taken  (standard HaDes-V default behaviour)
 *   1 = Predict Always Taken
 *   2 = Predict Backward Taken (negative offset → taken)
 *   3 = 2-bit Saturating Counter Array (32 entries, bimodal predictor)
 *
 * For aligned branches (branch_offset[1:0]==2'b00) only. Misaligned branches
 * are never predicted taken so the normal FETCH_MISALIGNED path is preserved.
 */

module branch_predictor (
    input  logic clk,
    input  logic rst,

    // Instruction currently on the fetch bus (combinational — valid when wb.ack)
    input  logic [31:0] instruction_bits,
    // PC of that instruction
    input  logic [31:0] program_counter,

    // Algorithm select: written via CSRRW MHPMEVENT10 from software
    input  logic [31:0] bp_control_in,

    // Feedback from Execute: was the branch actually taken?
    input  bpredict::bp_data_t bp_feedback_in,

    // Prediction for the current instruction
    output bpredict::bp_data_t bp_prediction_out,
    // Sign-extended branch offset (used by Fetch to adjust PC)
    output logic [31:0]        bp_branch_offset
);

    // =========================================================================
    // Part 1: Parse instruction — identify Bxxx and compute branch offset
    // =========================================================================
    // B-type opcode = 7'b1100011 (bits [6:0])
    // Branch offset reconstruction (sign-extended B-type immediate):
    //   imm[12]   = instruction[31]
    //   imm[11]   = instruction[7]
    //   imm[10:5] = instruction[30:25]
    //   imm[4:1]  = instruction[11:8]
    //   imm[0]    = 0

    logic        is_branch;
    logic [31:0] branch_offset;
    logic        is_aligned_branch;

    assign is_branch = (instruction_bits[6:0] == 7'b1100011);
    assign branch_offset = {{19{instruction_bits[31]}},
                            instruction_bits[31],
                            instruction_bits[7],
                            instruction_bits[30:25],
                            instruction_bits[11:8],
                            1'b0};
    // Only predict taken for aligned targets — misaligned branches fall through
    // to the normal FETCH_MISALIGNED exception path unchanged.
    assign is_aligned_branch = is_branch && (branch_offset[1:0] == 2'b00);

    // =========================================================================
    // Part 2: Static predictors (combinational)
    // =========================================================================

    // Predictor 0: Never Taken — identical to unmodified HaDes-V behaviour.
    logic predict_never_taken;
    assign predict_never_taken = 1'b0;

    // Predictor 1: Always Taken.
    logic predict_always_taken;
    assign predict_always_taken = is_aligned_branch;

    // Predictor 2: Backward Taken.
    // Backward branches (negative offset, bit 31 = 1) predict taken.
    // Forward branches predict not taken.
    logic predict_backward_taken;
    assign predict_backward_taken = is_aligned_branch && branch_offset[31];

    // =========================================================================
    // Part 3: Adaptive predictor — 2-bit saturating counter array (32 entries)
    // =========================================================================
    // Index: {sign_of_offset[1 bit], PC[5:2][4 bits]} = 5 bits → 32 entries.
    // First 16 entries initialised to Weak Not Taken (2'b01).
    // Last 16 entries initialised to Weak Taken (2'b10).
    // This starting condition mirrors the Backward Taken heuristic.
    //
    // Counter states:
    //   2'b00 = Strong Not Taken
    //   2'b01 = Weak Not Taken
    //   2'b10 = Weak Taken
    //   2'b11 = Strong Taken

    logic [1:0] counter_store [0:31];
    logic [4:0] index;
    logic [1:0] current_counter;

    assign index           = {branch_offset[31], program_counter[5:2]};
    assign current_counter = counter_store[index];

    logic predict_2bit_taken;
    assign predict_2bit_taken = is_aligned_branch && current_counter[1];

    // Update logic (combinational, latched in the always_ff below)
    logic [4:0] update_index;
    logic [1:0] counter_old;
    logic [1:0] counter_upd_taken;
    logic [1:0] counter_upd_not_taken;
    logic [1:0] counter_updated;

    assign update_index        = bp_feedback_in.index;
    assign counter_old         = counter_store[update_index];
    assign counter_upd_taken     = (counter_old == 2'b11) ? 2'b11 : (counter_old + 2'b01);
    assign counter_upd_not_taken = (counter_old == 2'b00) ? 2'b00 : (counter_old - 2'b01);
    assign counter_updated     = bp_feedback_in.was_taken ? counter_upd_taken : counter_upd_not_taken;

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 16; i = i + 1) begin
                counter_store[i]      <= 2'b01;  // weak not taken
                counter_store[i + 16] <= 2'b10;  // weak taken
            end
        end else if (bp_feedback_in.valid) begin
            counter_store[update_index] <= counter_updated;
        end
    end

    // =========================================================================
    // Part 4: Final MUX — select active predictor
    // =========================================================================

    logic predicted_taken;

    always_comb begin
        case (bp_control_in[1:0])
            2'b00:   predicted_taken = predict_never_taken;
            2'b01:   predicted_taken = predict_always_taken;
            2'b10:   predicted_taken = predict_backward_taken;
            2'b11:   predicted_taken = predict_2bit_taken;
            default: predicted_taken = predict_never_taken;
        endcase
    end

    // =========================================================================
    // Part 5: Outputs
    // =========================================================================

    assign bp_prediction_out.valid          = is_aligned_branch;
    assign bp_prediction_out.predicted_taken = predicted_taken;
    assign bp_prediction_out.was_taken      = 1'b0;  // filled in by Execute
    assign bp_prediction_out.index          = index;
    assign bp_branch_offset                 = branch_offset;

endmodule
