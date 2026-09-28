// Formal top: the real execute_stage with EVERY input left free (a top-level
// input of the formal model takes an arbitrary value in every cycle). All
// restrictions on inputs are the assumptions of props/div_props.vh section 0.
module top (
    input         clk,
    input         rst,
    input  [31:0] rs1_data_in,
    input  [31:0] rs2_data_in,
    input  [64:0] instruction_in,
    input  [31:0] program_counter_in,
    input  [7:0]  bp_prediction_in,
    input  [3:0]  status_forwards_in,
    input  [1:0]  status_backwards_in,
    input  [31:0] jump_address_backwards_in
);
    wire [31:0] source_data_reg_out, rd_data_reg_out, program_counter_reg_out;
    wire [31:0] next_program_counter_reg_out, jump_address_backwards_out;
    wire [64:0] instruction_reg_out;
    wire [37:0] forwarding_out;
    wire [7:0]  bp_feedback_out;
    wire [3:0]  status_forwards_out;
    wire [1:0]  status_backwards_out;
    execute_stage dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in), .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in), .program_counter_in(program_counter_in),
        .source_data_reg_out(source_data_reg_out), .rd_data_reg_out(rd_data_reg_out),
        .instruction_reg_out(instruction_reg_out),
        .program_counter_reg_out(program_counter_reg_out),
        .next_program_counter_reg_out(next_program_counter_reg_out),
        .forwarding_out(forwarding_out),
        .bp_prediction_in(bp_prediction_in), .bp_feedback_out(bp_feedback_out),
        .status_forwards_in(status_forwards_in), .status_forwards_out(status_forwards_out),
        .status_backwards_in(status_backwards_in), .status_backwards_out(status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(jump_address_backwards_out));
endmodule
