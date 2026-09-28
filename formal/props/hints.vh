// =============================================================================
// hints.vh -- the lemma instances ("hints") of proof v2, written ONCE.
//   props/div_props.vh includes this file with  `define HINT(p) assume(p)
//   lemmas/hint_validity.v includes it with     `define HINT(p) assert(p) and
//   every signal the hints mention left FREE, which proves H5, H6, H7 valid.
//   H1 is a cross-cycle congruence instance; its validity rests on mul_result
//   being a combinational function of (instruction_in, rs1_data_in,
//   rs2_data_in) only, which lemmas/mul_result_cone.ys checks structurally.
//
// Derived wires are declared here too so that the proof and the validity
// check see the very same expressions.
// =============================================================================
`ifdef HINT_MUL
// H1 congruence of the RTL's own combinational multiplier across one clock:
//    mul_result depends only on (instruction_in, rs1_data_in, rs2_data_in),
//    so equal inputs in consecutive cycles give equal outputs.
always @(*) `HINT(!(instruction_in == f_p_insn && rs1_data_in == f_p_rs1 &&
                     rs2_data_in == f_p_rs2) || mul_result == f_q_mulres);
`endif

`ifdef HINT_VSTEP
// Arguments of the long-division step lemma: the previous cycle's prefix T,
// the dividend bit a that was about to be shifted in, and the divisor B.
wire [31:0] f_h_q  = f_q_T / f_q_B;                   // T / B
wire [31:0] f_h_r  = f_q_T % f_q_B;                   // T % B
wire [31:0] f_h_T2 = {f_q_T[30:0], f_q_a};            // 2T + a   (T < 2^31)
wire [32:0] f_h_sh = {f_h_r, f_q_a};                  // 2(T%B) + a, exact in 33 bits
wire [32:0] f_h_df = f_h_sh - {1'b0, f_q_B};
wire        f_h_tk = !f_h_df[32];                     // 2(T%B) + a >= B
wire [31:0] f_h_r2 = f_h_tk ? f_h_df[31:0] : f_h_sh[31:0];

`ifndef SKIP_H6
// H6 one step of long division (lemma V):  for all 32-bit T, B and 1-bit a
//    with B != 0 and T < 2^31:
//        (2T+a) / B == 2*(T/B) + [2(T%B)+a >= B]
//        (2T+a) % B == 2(T%B)+a - (that bit ? B : 0)
always @(*) `HINT(!(f_q_B != 32'd0 && !f_q_T[31])
                   || (f_h_T2 / f_q_B == {f_h_q[30:0], f_h_tk} && f_h_T2 % f_q_B == f_h_r2));
`endif

`ifndef SKIP_H7
// H7 congruence of unsigned '/' and '%':  equal arguments give equal results
//    (instantiated between the current prefix/divisor and the H6 arguments).
always @(*) `HINT(!(f_T == f_h_T2 && m_divisor == f_q_B)
                   || (f_T / m_divisor == f_h_T2 / f_q_B && f_T % m_divisor == f_h_T2 % f_q_B));
`endif

`ifndef SKIP_H8
// H8 congruence (hold case: prefix and divisor unchanged across the clock)
always @(*) `HINT(!(f_T == f_q_T && m_divisor == f_q_B)
                   || (f_T / m_divisor == f_h_q && f_T % m_divisor == f_h_r));
`endif

`ifndef SKIP_H9
// H9 zero dividend (load case):  0 / B == 0  and  0 % B == 0  for B != 0
always @(*) `HINT(!(f_T == 32'd0 && m_divisor != 32'd0)
                   || (f_T / m_divisor == 32'd0 && f_T % m_divisor == 32'd0));
`endif
`endif

`ifdef HINT_DIVFIN
// H5 congruence of unsigned '/' and '%' (same cycle), instantiated on the two
//    operand pairs the spec divides: the magnitudes (DIV/REM) and the raw
//    operands (DIVU/REMU). f_s_mag_a / f_s_mag_b are defined in div_props.vh
//    with the magnitude expression textually identical to spec.vh, so the
//    solver sees the very same term. The validity check treats them (like
//    every other argument) as FREE: a congruence formula valid for all values
//    of its arguments is valid for every instance.
`ifndef SKIP_H5A
// H5a: signed ops (DIV/REM) divide the magnitudes
always @(*) `HINT(!(f_T == f_s_mag_a && m_divisor == f_s_mag_b)
                   || (f_T / m_divisor == f_s_mag_a / f_s_mag_b && f_T % m_divisor == f_s_mag_a % f_s_mag_b));
`endif
`ifndef SKIP_H5B
// H5b: unsigned ops (DIVU/REMU) divide the raw operands
always @(*) `HINT(!(f_T == rs1_data_in && m_divisor == rs2_data_in)
                   || (f_T / m_divisor == rs1_data_in / rs2_data_in && f_T % m_divisor == rs1_data_in % rs2_data_in));
`endif
`endif
