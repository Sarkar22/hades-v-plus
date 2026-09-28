// Formal cross-check of the two independent spec formulations in props/spec.vh:
//   f_spec_m   (RISC-V special cases first, then sign * unsigned floor on magnitudes)
//   f_spec_ref (special cases first, then Verilog's own signed '/' and '%')
// All inputs FREE; depth-1 BMC PASS = equal for every (op, a, b).
// One task per opcode (the op is a constant, so each query holds one formula).
module spec_equiv (input [31:0] a, input [31:0] b);
`include "spec.vh"
    wire [5:0] op = `SPEC_OP;
    always @(*) assert (f_spec_m(op, a, b) == f_spec_ref(op, a, b));
endmodule
