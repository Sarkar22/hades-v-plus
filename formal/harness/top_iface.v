// =============================================================================
// top_iface.v -- formal top for the PORT-LEVEL properties A1 and A3a.
//
// Same top as harness/top.v (the real execute_stage, every input free; the
// environment E0-E2 lives in props/div_props.vh inside the dut), plus
// properties that look ONLY at the module's ports. Nothing here is gated by an
// RTL-internal signal (is_m_div, is_m_mul, m_active, m_stall, ...), so an M
// instruction that the RTL misclassifies, or a VALID hand-off to Memory while
// the M unit is still busy, is caught. (FINAL's F1/F2/F3 in div_props.vh are
// gated by the RTL's own decode and say nothing about the stall cycles; an
// independent audit showed three real-bug mutants that pass them. A1 and A3a
// close that gap; the mutation campaign in run.sh re-checks it.)
//
// Encodings (defines/pipeline_status.sv, defines/op.sv):
//   forwards  VALID = 0, BUBBLE = 1        backwards READY = 0, STALL = 1, JUMP = 2
//   M opcodes 53 MUL 54 MULH 55 MULHSU 56 MULHU 57 DIV 58 DIVU 59 REM 60 REMU
//
//   A1  (result): if in cycle t (no reset) a VALID instruction whose opcode
//       FIELD is IFACE_OP leaves Execute -- Memory READY and Execute not
//       answering STALL -- then in t+1 rd_data_reg_out == spec(op, rs1, rs2)
//       and status_forwards_out == VALID.
//   A3a (hand-off): if Execute's output registers are loaded (Memory READY, no
//       reset) while an IFACE_OP instruction is in Execute and the result is
//       presented to Memory as VALID, then that instruction really left
//       Execute in that cycle (so A1 applies to it).
//   A1 and A3a together give A3: every VALID hand-off of an M instruction made
//       in a Memory-READY cycle carries the ISA result.
//   IFACE_COVER: non-vacuity -- every M opcode can leave Execute with a
//       non-special operand pair.
// Macros: IFACE (elaborate the properties), IFACE_OP=<n> (opcode, required
// with IFACE), IFACE_A1, IFACE_A3A, IFACE_COVER.
// =============================================================================
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

    reg a_init = 1'b1;
    always @(posedge clk) a_init <= 1'b0;

    wire [5:0] a_op    = instruction_in[64:59];
    // the instruction leaves Execute in this cycle
    wire       a_leave = !rst && (status_forwards_in == 4'd0) && (status_backwards_in == 2'd0)
                         && (status_backwards_out != 2'd1);

`ifdef IFACE
`include "spec.vh"
    wire       a_cls   = (a_op == `IFACE_OP);

    reg        a_leave_q = 1'b0;
    reg        a_upd_q   = 1'b0;
    reg [31:0] a_spec_q;
    always @(posedge clk) begin
        a_leave_q <= a_leave && a_cls;
        a_upd_q   <= !rst && (status_backwards_in == 2'd0) && a_cls;
        a_spec_q  <= f_spec_m(a_op, rs1_data_in, rs2_data_in);
    end

    always @(*) if (!a_init) begin
`ifdef IFACE_A1
        assert(!a_leave_q || (rd_data_reg_out == a_spec_q && status_forwards_out == 4'd0));  // A1
`endif
`ifdef IFACE_A3A
        assert(!(a_upd_q && status_forwards_out == 4'd0) || a_leave_q);                       // A3a
`endif
    end
`endif

`ifdef IFACE_COVER
    genvar gi;
    for (gi = 53; gi <= 60; gi = gi + 1) begin : g_cov
        always @(*) if (!a_init) cover(a_leave && a_op == gi && rs2_data_in != 32'd0
                                       && !(rs1_data_in == 32'h80000000 && rs2_data_in == 32'hffffffff)
                                       && rs1_data_in[31] && rs2_data_in > 32'd3);
    end
`endif
endmodule
