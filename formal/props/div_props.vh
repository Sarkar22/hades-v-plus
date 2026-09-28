// =============================================================================
// div_props.vh -- formal environment, strengthening invariants and end-to-end
// properties for the M unit of the REAL rtl/execute_stage.sv   (proof v2)
//
// scripts/gen.sh inserts  `include "div_props.vh"  as the last line inside
// module execute_stage of the sv2v output (the only change made to the RTL
// text), so every internal RTL signal is visible here by name. Nothing in this
// file drives an RTL signal: it only declares f_* observer signals and ghost
// registers, assumptions on the module INPUTS, and assertions.
//
// Proof runs select what each property group does with macros:
//     ASSERT_<G>  -> the group is proven in this run
//     ASSUME_<G>  -> the group is assumed (it was proven by an EARLIER run)
//     (neither)   -> the group is ignored
// Dependency order (acyclic):   CTRL -> DIVF -> FINAL(div)
//                               CTRL -> MULREG -> FINAL(mul)
// =============================================================================
`ifdef FORMAL

`include "spec.vh"

`ifdef ASSERT_CTRL
  `define P_CTRL(p) assert(p)
`elsif ASSUME_CTRL
  `define P_CTRL(p) assume(p)
`else
  `define P_CTRL(p)
`endif
`ifdef ASSERT_DIVF
  `define P_DIVF(p) assert(p)
`elsif ASSUME_DIVF
  `define P_DIVF(p) assume(p)
`else
  `define P_DIVF(p)
`endif
`ifdef ASSERT_MULREG
  `define P_MULREG(p) assert(p)
`elsif ASSUME_MULREG
  `define P_MULREG(p) assume(p)
`else
  `define P_MULREG(p)
`endif
`ifdef ASSERT_FINAL
  `define P_FINAL(p) assert(p)
`else
  `define P_FINAL(p)
`endif

// -----------------------------------------------------------------------------
// 0. Environment (always ASSUMED; these are the only restrictions on inputs)
// -----------------------------------------------------------------------------
// f_init is 1 only in the very first cycle of a base-case trace. In an
// induction trace it is unconstrained in the first step and 0 afterwards.
reg f_init = 1'b1;
always @(posedge clk) f_init <= 1'b0;

// E0: the unit starts from reset (base case only; rst is otherwise FREE, i.e.
//     a reset may arrive at any cycle).
always @(*) if (f_init) assume(rst);

// E1: Memory only ever drives the three defined backwards_t values
//     (memory_stage.sv: STALL, JUMP, or Writeback's READY/JUMP passed through).
always @(*) assume(status_backwards_in != 2'd3);

// E2: Decode's contract (decode_stage.sv, output register block: "STALL from
//     Exe -> hold all outputs"; status_forwards_out is that held register):
//     while Execute drives STALL backwards, every input of this module that
//     comes from Decode is unchanged in the next cycle. Otherwise (READY /
//     JUMP / after a reset) the inputs are completely free.
reg        f_hold = 1'b0;
reg [64:0] f_p_insn;
reg [31:0] f_p_rs1, f_p_rs2, f_p_pc;
reg [3:0]  f_p_sf;
reg [7:0]  f_p_bp;
always @(posedge clk) begin
    f_hold   <= !rst && (status_backwards_out == 2'd1);
    f_p_insn <= instruction_in;
    f_p_rs1  <= rs1_data_in;
    f_p_rs2  <= rs2_data_in;
    f_p_pc   <= program_counter_in;
    f_p_sf   <= status_forwards_in;
    f_p_bp   <= bp_prediction_in;
end
always @(*) if (f_hold) begin
    assume(instruction_in     == f_p_insn);
    assume(rs1_data_in        == f_p_rs1);
    assume(rs2_data_in        == f_p_rs2);
    assume(program_counter_in == f_p_pc);
    assume(status_forwards_in == f_p_sf);
    assume(bp_prediction_in   == f_p_bp);
end

// -----------------------------------------------------------------------------
// 1. Observers and ghost state (no influence on the design)
// -----------------------------------------------------------------------------
wire [5:0] f_op  = instruction_in[64:59];
wire       f_chk = !f_init;                 // properties are checked after reset

// The FSM "works" in a cycle iff it takes the (STALL || m_stall) branch.
wire f_adv  = !rst && (status_backwards_in != 2'd2) &&
              ((status_backwards_in == 2'd1) || m_stall);
wire f_load = f_adv && (m_state == 2'd0) && m_active && !m_early && is_m_div;
wire f_step = f_adv && (m_state == 2'd1);

// n = number of restoring steps already performed while in M_RUN (0..31)
wire [5:0] f_n = 6'd32 - m_count;

// Ghost T: the dividend-magnitude bits consumed so far (the "prefix"), i.e. the
//          bit that leaves the top of m_quo on each step is shifted into T.
// Ghost X: the quotient bits produced so far (the bit entering m_quo).
reg [31:0] f_T, f_X;
always @(posedge clk) begin
    if (f_load) begin
        f_T <= 32'd0;
        f_X <= 32'd0;
    end else if (f_step) begin
        f_T <= {f_T[30:0], m_quo[31]};
        f_X <= {f_X[30:0], div_step_take};
    end
end

// Consecutive cycles in which the M unit itself holds the pipeline (m_stall),
// restarted by a reset or by a flush from downstream.
reg [6:0] f_stall_run = 7'd0;
always @(posedge clk)
    if (rst || status_backwards_in == 2'd2 || !m_stall) f_stall_run <= 7'd0;
    else if (f_stall_run != 7'h7f)                       f_stall_run <= f_stall_run + 7'd1;

wire f_run     = (m_state == 2'd1);
wire f_rdy     = (m_state == 2'd2);
wire f_divbusy = (f_run || f_rdy) && is_m_div;    // divider holds a (partial) result

// -----------------------------------------------------------------------------
// 2. Group CTRL: control + linear datapath invariants (no '*', '/' or '%')
// -----------------------------------------------------------------------------
always @(*) if (f_chk) begin
    // FSM encoding and consistency with the (held) instruction
    `P_CTRL(m_state != 2'd3);
    `P_CTRL(m_state == 2'd0 || (m_active && !m_early));
    `P_CTRL(!f_run || is_m_div);
    `P_CTRL(!f_run || (m_count >= 6'd1 && m_count <= 6'd32));
    `P_CTRL(!(f_rdy && is_m_div) || m_count == 6'd0);
    // latched operands / signs equal those of the instruction in Execute
    `P_CTRL(!f_divbusy || m_divisor == div_divisor_mag);
    `P_CTRL(!f_divbusy || m_divisor != 32'd0);
    `P_CTRL(!f_divbusy || m_quo_neg == (div_dividend_neg ^ div_divisor_neg));
    `P_CTRL(!f_divbusy || m_rem_neg == div_dividend_neg);
    // restoring-division shape invariants, n = f_n steps done
    `P_CTRL(!f_divbusy || m_rem < m_divisor);                               // partial remainder < divisor
    `P_CTRL(!f_divbusy || m_rem <= f_T);                                    // remainder <= prefix
    `P_CTRL(!f_run || (m_quo >> f_n) == ((div_dividend_mag << f_n) >> f_n));// unconsumed dividend bits
    `P_CTRL(!f_run || f_T == (div_dividend_mag >> (6'd32 - f_n)));          // consumed prefix
    `P_CTRL(!f_run || f_X == (m_quo & ((32'd1 << f_n) - 32'd1)));          // quotient bits so far
    `P_CTRL(!f_run || (f_T >> f_n) == 32'd0);                               // prefix has n bits
    `P_CTRL(!f_run || (f_X >> f_n) == 32'd0);                               // quotient has n bits
    `P_CTRL(!(f_rdy && is_m_div) || f_T == div_dividend_mag);
    `P_CTRL(!(f_rdy && is_m_div) || f_X == m_quo);
    // consequence: bit 32 of the 33-bit shifted remainder is never set (the
    // RTL's 33-bit subtract is sufficient but wider than necessary)
    `P_CTRL(!f_run || !div_shifted[32]);
    // the M unit never stalls anything but a VALID M instruction
    `P_CTRL(!m_stall || (is_m && status_forwards_in == 4'd0));
    // bounded stall: the unit never holds the pipeline for more than 33 cycles
    `P_CTRL(f_stall_run <= 7'd33);
    `P_CTRL(!(m_state == 2'd0) || f_stall_run == 7'd0);
    `P_CTRL(!f_run || f_stall_run == 7'd33 - {1'b0, m_count});
end

// -----------------------------------------------------------------------------
// 3. Group DIVF: the partial quotient/remainder ARE the quotient/remainder of
//    the consumed prefix (division form; no multiplication anywhere)
//        X == T / B   and   R == T % B          (B = m_divisor != 0)
//    At M_READY, T == |dividend| (CTRL), so m_quo == |a| / |b|, m_rem == |a| % |b|.
// -----------------------------------------------------------------------------
always @(*) if (f_chk) begin
    `P_DIVF(!f_divbusy || f_X  == f_T / m_divisor);
    `P_DIVF(!f_divbusy || m_rem == f_T % m_divisor);
end

// -----------------------------------------------------------------------------
// 3b. Group MULREG: a parked multiply result is the product of the held operands
// -----------------------------------------------------------------------------
always @(*) if (f_chk) begin
    `P_MULREG(!(f_rdy && is_m_mul) || m_mul_reg == mul_result);
end

// The M instruction leaves Execute towards Memory in this cycle.
wire f_retire = !rst && (status_backwards_in == 2'd0) && m_active && !m_stall;

`ifdef ASSERT_FINAL
// -----------------------------------------------------------------------------
// 4. Group FINAL: end-to-end results against the ISA spec (spec.vh)
//    (only elaborated in the runs that prove it, to keep other queries small)
// -----------------------------------------------------------------------------
wire [31:0] f_spec = f_spec_m(f_op, rs1_data_in, rs2_data_in);

// Which op classes this run checks.
// FINAL_OP=<n> restricts the checked class to the single opcode n (a proof by
// cases over the opcode; the union of the per-opcode runs covers the class).
`ifdef FINAL_OP
wire f_cls = (f_op == `FINAL_OP) && (is_m_div || is_m_mul);
`elsif FINAL_DIV_ONLY
wire f_cls = is_m_div;
`elsif FINAL_MUL_ONLY
wire f_cls = is_m_mul;
`else
wire f_cls = is_m_div || is_m_mul;
`endif

reg        f_ret_q  = 1'b0;
reg [31:0] f_spec_q;
reg        f_cls_q;
always @(posedge clk) begin
    f_ret_q  <= f_retire;
    f_spec_q <= f_spec;
    f_cls_q  <= f_cls;
end

// FSEL_F1 / FSEL_F2 / FSEL_F3 select a single property (default: all three).
`ifndef FSEL_F1
`ifndef FSEL_F2
`ifndef FSEL_F3
  `define FSEL_F1
  `define FSEL_F2
  `define FSEL_F3
`endif
`endif
`endif
always @(*) if (f_chk) begin
`ifdef FSEL_F1
    // F1: the value Execute registers for Memory/Writeback is the ISA result
    `P_FINAL(!(f_retire && f_cls) || rd_data == f_spec);
`endif
`ifdef FSEL_F2
    // F2: whenever the forwarding bus advertises an M result as valid, it is right
    `P_FINAL(!(forwarding_out[37] && m_active && f_cls) || forwarding_out[36:5] == f_spec);
`endif
`ifdef FSEL_F3
    // F3: the registered output one cycle after retirement
    `P_FINAL(!(f_ret_q && f_cls_q) || (rd_data_reg_out == f_spec_q && status_forwards_out == 4'd0));
`endif
end
`endif

`ifdef HINT_MUL
  `define HINTS_ANY
`endif
`ifdef HINT_VSTEP
  `define HINTS_ANY
`endif
`ifdef HINT_DIVFIN
  `define HINTS_ANY
`endif
`ifdef HINTS_ANY
// -----------------------------------------------------------------------------
// 5. Lemma instances ("hints").  Every one is a VALID formula -- true for all
//    values of the signals it mentions -- so assuming it removes no behaviour
//    of the design; it only hands the solver a fact it cannot derive quickly by
//    bit-blasting. Machine proofs of validity: lemmas/ (see README).
//
//    The f_q_* registers below latch a value EVERY cycle, unconditionally, so in
//    any state reached by at least one transition f_q_x == (x one cycle ago).
//    (In the first state of an induction trace they are free ghosts; the hints
//    are valid for all values of their arguments, so they then only relate free
//    ghost values and never restrict an RTL register or input.)
// -----------------------------------------------------------------------------
`ifdef HINT_DIVFIN
// arguments of H5: |rs1|, |rs2| written exactly as in spec.vh
wire [31:0] f_s_mag_a = rs1_data_in[31] ? (32'd0 - rs1_data_in) : rs1_data_in;
wire [31:0] f_s_mag_b = rs2_data_in[31] ? (32'd0 - rs2_data_in) : rs2_data_in;
`endif
reg [31:0] f_q_mulres, f_q_T, f_q_B;
reg        f_q_a;
always @(posedge clk) begin
    f_q_mulres <= mul_result;
    f_q_T      <= f_T;
    f_q_a      <= m_quo[31];
    f_q_B      <= m_divisor;
end

`define HINT(p) assume(p)
`include "hints.vh"
`endif

`ifdef COVER
// -----------------------------------------------------------------------------
// 6. Non-vacuity: interesting behaviours are reachable under the environment
// -----------------------------------------------------------------------------
always @(*) if (f_chk) begin
    cover(f_retire && f_op == 6'd57 && !m_early && rs1_data_in[31] && !rs2_data_in[31]
          && rs2_data_in > 32'd3);                                     // C1 a real DIV retires
    cover(f_retire && f_op == 6'd60 && !m_early && rs2_data_in > 32'd1000); // C2 a real REMU retires
    cover(f_rdy && is_m_div && status_backwards_in == 2'd1);           // C3 parked in READY by a Memory stall
    cover(f_run && m_count == 6'd10 && status_backwards_in == 2'd2);   // C4 flushed mid-divide
    cover(f_retire && f_op == 6'd55 && rs1_data_in[31]);               // C5 a MULHSU retires
    cover(f_retire && f_op == 6'd58 && !m_early && rs2_data_in[31] && m_rem[31]); // C6 DIVU, big divisor, rem >= 2^31
end
`endif

`endif // FORMAL
