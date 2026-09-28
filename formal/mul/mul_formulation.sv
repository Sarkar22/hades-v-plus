// formal/mul/mul_formulation.sv -- the earlier multiplier FORMULATION experiment (sby/mul_formulation.sby).
// dut_mul is a HAND COPY of the 33x33 multiply of rtl/execute_stage.sv, NOT the RTL itself;
// The real-RTL multiplier proof is FINAL(mul) + MULREG + A1/A3a (see formal/README.md).
// Same experiment, but DUT and spec multipliers live in separate (non-flattened)
// modules so Yosys cannot merge them: the SMT solver must prove the equality.
module dut_mul (input [31:0] rs1, rs2, input a_s, b_s, input lo, output [31:0] y);
    wire signed [32:0] op_a = $signed({a_s & rs1[31], rs1});
    wire signed [32:0] op_b = $signed({b_s & rs2[31], rs2});
    wire signed [65:0] prod = op_a * op_b;
    assign y = lo ? prod[31:0] : prod[63:32];
endmodule
module spec_mul (input [31:0] rs1, rs2, input [1:0] op, output [31:0] y);
    wire [63:0] s_mul    = rs1 * rs2;
    wire [63:0] s_mulh   = ({{32{rs1[31]}}, rs1} * {{32{rs2[31]}}, rs2});
    wire [63:0] s_mulhsu = ({{32{rs1[31]}}, rs1} * {32'b0, rs2});
    wire [63:0] s_mulhu  = ({32'b0, rs1} * {32'b0, rs2});
    assign y = (op == 0) ? s_mul[31:0] : (op == 1) ? s_mulh[63:32] : (op == 2) ? s_mulhsu[63:32] : s_mulhu[63:32];
endmodule
module mul_eq (input [31:0] rs1, input [31:0] rs2);
`ifdef OP_MUL
    localparam [1:0] OP = 0;
`elsif OP_MULH
    localparam [1:0] OP = 1;
`elsif OP_MULHSU
    localparam [1:0] OP = 2;
`else
    localparam [1:0] OP = 3;
`endif
    wire [31:0] d, s;
    dut_mul  u_d (.rs1(rs1), .rs2(rs2), .a_s(OP != 3), .b_s(OP == 0 || OP == 1), .lo(OP == 0), .y(d));
    spec_mul u_s (.rs1(rs1), .rs2(rs2), .op(OP), .y(s));
    always @* assert (d == s);
endmodule
