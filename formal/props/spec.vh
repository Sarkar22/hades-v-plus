// =============================================================================
// spec.vh -- RISC-V "M" extension result, written from the unprivileged ISA
// manual (RV32M chapter), NOT from rtl/execute_stage.sv.
//
// Opcode numbering is the frozen op::t enum of defines/op.sv:
//   53 MUL  54 MULH  55 MULHSU  56 MULHU  57 DIV  58 DIVU  59 REM  60 REMU
//
// Division semantics (ISA manual, "Division Operations" + Table "Semantics for
// division by zero and division overflow"):
//   DIVU/REMU : unsigned floor quotient / remainder.
//   DIV/REM   : signed, quotient rounded toward zero, remainder has the sign
//               of the dividend  (so a == q*b + r,  |r| < |b|).
//   x / 0     : DIV -> -1, DIVU -> 2^32-1, REM/REMU -> dividend.
//   -2^31/-1  : DIV -> -2^31, REM -> 0            (signed ops only).
//
// Two independent formulations are provided:
//   f_spec_m   : truncating division written as sign * floor(|a|/|b|), i.e. the
//                SMT-LIB definition of bvsdiv/bvsrem, with the RISC-V special
//                cases stated explicitly FIRST (SMT-LIB's bvsdiv(-5,0) = 1 is
//                NOT the RISC-V answer, so the zero case must never reach '/').
//   f_spec_ref : the same using Verilog's own signed '/' and '%' operators
//                (IEEE 1364: integer division truncates toward zero, '%' takes
//                the sign of the first operand).
// lemmas/spec_equiv.v (sby/spec_equiv.sby) checks f_spec_m == f_spec_ref for
// all inputs per opcode (see README for which solver closed which opcode), and
// spec_check/ cross-checks both against Python on corners + 1e6 random vectors.
// Only f_spec_m is used by the proofs.
// =============================================================================

function [31:0] f_spec_m;
    input [5:0]  op;
    input [31:0] a;
    input [31:0] b;
    reg   [63:0] p_ss, p_su, p_uu;
    reg   [31:0] mag_a, mag_b, uq, ur;
    begin
        // products, exact in 64 bits (operands extended per signedness)
        p_ss = {{32{a[31]}}, a} * {{32{b[31]}}, b};
        p_su = {{32{a[31]}}, a} * {32'd0, b};
        p_uu = {32'd0, a} * {32'd0, b};
        // magnitudes for the signed divide (|-2^31| = 2^31 fits in 32 unsigned bits)
        mag_a = a[31] ? (32'd0 - a) : a;
        mag_b = b[31] ? (32'd0 - b) : b;
        uq = mag_a / mag_b;
        ur = mag_a % mag_b;
        case (op)
            6'd53: f_spec_m = p_ss[31:0];            // MUL    (low half, any signedness)
            6'd54: f_spec_m = p_ss[63:32];           // MULH   signed   x signed
            6'd55: f_spec_m = p_su[63:32];           // MULHSU signed   x unsigned
            6'd56: f_spec_m = p_uu[63:32];           // MULHU  unsigned x unsigned
            6'd57: f_spec_m = (b == 32'd0)                            ? 32'hFFFF_FFFF :
                              (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'h8000_0000 :
                              ((a[31] ^ b[31]) ? (32'd0 - uq) : uq);           // DIV
            6'd58: f_spec_m = (b == 32'd0) ? 32'hFFFF_FFFF : (a / b);          // DIVU
            6'd59: f_spec_m = (b == 32'd0)                            ? a :
                              (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'd0 :
                              (a[31] ? (32'd0 - ur) : ur);                     // REM
            6'd60: f_spec_m = (b == 32'd0) ? a : (a % b);                      // REMU
            default: f_spec_m = 32'd0;
        endcase
    end
endfunction

function [31:0] f_spec_ref;
    input [5:0]  op;
    input [31:0] a;
    input [31:0] b;
    reg signed [31:0] sa, sb, sq, sr;
    reg        [63:0] p_ss, p_su, p_uu;
    begin
        sa = a; sb = b;
        sq = sa / sb;        // signed '/' : truncates toward zero
        sr = sa % sb;        // signed '%' : sign of the dividend
        p_ss = {{32{a[31]}}, a} * {{32{b[31]}}, b};
        p_su = {{32{a[31]}}, a} * {32'd0, b};
        p_uu = {32'd0, a} * {32'd0, b};
        case (op)
            6'd53: f_spec_ref = p_ss[31:0];
            6'd54: f_spec_ref = p_ss[63:32];
            6'd55: f_spec_ref = p_su[63:32];
            6'd56: f_spec_ref = p_uu[63:32];
            6'd57: f_spec_ref = (b == 32'd0) ? 32'hFFFF_FFFF :
                                (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'h8000_0000 : sq;
            6'd58: f_spec_ref = (b == 32'd0) ? 32'hFFFF_FFFF : (a / b);
            6'd59: f_spec_ref = (b == 32'd0) ? a :
                                (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) ? 32'd0 : sr;
            6'd60: f_spec_ref = (b == 32'd0) ? a : (a % b);
            default: f_spec_ref = 32'd0;
        endcase
    end
endfunction
