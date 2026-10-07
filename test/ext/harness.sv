// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// test/ext/harness.sv -- the real instruction_decoder in front of the real execute_stage, for
// the vector check of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions
// (test/ext/harness.cpp drives it).
//
// The decoder turns the instruction word into instruction::t (op::EXT and its payload) exactly
// as in the core, and Execute computes the result from the register values given here. The
// result is read where the pipeline reads it: the forwarding output of Execute, which is
// combinational from the current inputs, so every vector needs one evaluation and no clock.
// Execute always sees a VALID instruction and a READY Memory stage.
// ---------------------------------------------------------------------------------------------
module harness (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] instr,        // the instruction word
    input  logic [31:0] rs1_value,    // value of the register rs1 names
    input  logic [31:0] rs2_value,    // value of the register rs2 names
    output logic [31:0] rd_value,     // forwarding_out.data
    output logic        rd_valid,     // forwarding_out.data_valid
    output logic [4:0]  rd_address,   // forwarding_out.address
    output logic        ready         // status_backwards_out == READY
);
    import pipeline_status::*;

    instruction::t      decoded;
    forwarding::t       fwd;
    backwards_t         back;
    bpredict::bp_data_t bp_feedback;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]   source_data, rd_data, pc_out, next_pc_out, jump_out;
    instruction::t instr_out;
    forwards_t     status_out;
    /* verilator lint_on UNUSEDSIGNAL */

    instruction_decoder decoder (
        .instruction_in (instr),
        .instruction_out(decoded)
    );

    execute_stage execute (
        .clk                         (clk),
        .rst                         (rst),
        .rs1_data_in                 (rs1_value),
        .rs2_data_in                 (rs2_value),
        .instruction_in              (decoded),
        .program_counter_in          (32'h0004_0000),
        .source_data_reg_out         (source_data),
        .rd_data_reg_out             (rd_data),
        .instruction_reg_out         (instr_out),
        .program_counter_reg_out     (pc_out),
        .next_program_counter_reg_out(next_pc_out),
        .forwarding_out              (fwd),
        .bp_prediction_in            ('0),
        .bp_feedback_out             (bp_feedback),
        .status_forwards_in          (VALID),
        .status_forwards_out         (status_out),
        .status_backwards_in         (READY),
        .status_backwards_out        (back),
        .jump_address_backwards_in   (32'b0),
        .jump_address_backwards_out  (jump_out)
    );

    assign rd_value   = fwd.data;
    assign rd_valid   = fwd.data_valid;
    assign rd_address = fwd.address;
    assign ready      = (back == READY);

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_bp;
    assign unused_bp = ^bp_feedback;
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
