// Simulation wrapper: exposes the two formal spec functions for cross-checking.
module spec_top(input [5:0] op, input [31:0] a, input [31:0] b,
                output [31:0] y_m, output [31:0] y_ref);
`include "spec.vh"
    assign y_m   = f_spec_m(op, a, b);
    assign y_ref = f_spec_ref(op, a, b);
endmodule
