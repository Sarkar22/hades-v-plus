// Validity of the hints H5, H6, H7 (props/hints.vh) as formulas: every signal
// they mention is a FREE input here, and each hint -- the very same text the
// proof assumes, including its derived wires -- is ASSERTED. A PASS of a
// depth-1 BMC means the formula holds for ALL values of those signals, i.e.
// assuming it in the proof removes no behaviour of the design.
module hint_validity (
    input  [31:0] f_T, f_q_T, f_q_B, m_divisor, rs1_data_in, rs2_data_in,
    input  [31:0] f_s_mag_a, f_s_mag_b,   // H5 arguments (defined in div_props.vh), free here
    input         f_q_a
);
`ifdef BSPLIT
// Exhaustive case split for the H6 validity check (sby/h6_split.sby): case k
// restricts the divisor argument to bit-length k+1, i.e. 2^k <= f_q_B < 2^(k+1)
// (k = 31: f_q_B >= 2^31); case BZERO is f_q_B == 0. The 33 cases cover every
// 32-bit value, so H6 valid in every case <=> H6 valid.
`ifdef BZERO
always @(*) assume(f_q_B == 32'd0);
`else
always @(*) assume(f_q_B >= (32'd1 << `BSPLIT) && (`BSPLIT == 31 || f_q_B < (32'd1 << (`BSPLIT + 1))));
`endif
`endif
`define HINT(p) assert(p)
`include "hints.vh"
endmodule
