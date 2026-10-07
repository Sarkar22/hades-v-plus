// Simulation wrapper: exposes the formal reference function of props/ext_spec.vh
// for cross-checking against check_ext_spec.py.
module ext_spec_top(input [5:0] id, input [31:0] rs1, input [31:0] rs2, input [4:0] shamt,
                    output [31:0] y);
`include "ext_spec.vh"
    assign y = f_spec_ext(id, rs1, rs2, shamt);
endmodule
