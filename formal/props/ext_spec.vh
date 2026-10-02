// =============================================================================
// ext_spec.vh -- result of the 28 Zbb, Zbs and Zicond instructions, written from
// the ratified specifications, NOT from rtl/execute_stage.sv:
//   RISC-V Bit-Manipulation ISA-extensions, version 1.0.0 (Zbb, Zbs; the
//     "Insn" pages and their Sail operation, for XLEN = 32), and
//   RISC-V Integer Conditional (Zicond) operations extension, version 1.0.
//
// f_spec_ext(id, rs1, rs2, shamt) is X[rd] for the instruction numbered id below,
// with X(rs1) = rs1 and X(rs2) = rs2. shamt is the instruction's shamt field
// (inst[24:20]); only the immediate forms read it, as the specification says
// (on RV32 their shamt[5] must be 0, so the field has five bits).
//
// The numbering is this file's own (the order of the specifications'
// instruction lists); harness/top_ext.v maps it to the decoder's payload of
// defines/op.sv, and scripts/ext_codes.py checks that map against op.sv.
//
//    0 andn    1 orn     2 xnor    3 clz     4 ctz     5 cpop    6 max
//    7 maxu    8 min     9 minu   10 sext.b 11 sext.h 12 zext.h 13 rol
//   14 ror    15 rori   16 orc.b  17 rev8   18 bclr   19 bclri  20 bext
//   21 bexti  22 binv   23 binvi  24 bset   25 bseti  26 czero.eqz
//   27 czero.nez
//
// The style follows the Sail operation of each instruction: the counts scan bit
// by bit (HighestSetBit, LowestSetBit, a counting loop), the rotates are the
// two-shift formula, orc.b and rev8 loop over bytes, the single-bit
// instructions build their mask as 1 << (rs2 & (XLEN - 1)), sign extension is
// a signed cast. spec_check/check_ext_spec.py cross-checks every function value
// against an independent Python model.
// =============================================================================

function [31:0] f_spec_ext;
    input [4:0]  id;
    input [31:0] rs1;
    input [31:0] rs2;
    input [4:0]  shamt;
    reg   [5:0]  sh;         // rotate amount, six bits wide so that XLEN - sh can be 32
    reg   [31:0] index;      // bit index of Zbs: rs2 & (XLEN - 1), or shamt
    reg   [31:0] r;
    integer      i, j, hsb, lsb, cnt;
    begin
        r     = 32'd0;
        sh    = (id == 5'd15) ? {1'b0, shamt} : {1'b0, rs2[4:0]};
        index = (id == 5'd19 || id == 5'd21 || id == 5'd23 || id == 5'd25)
                ? {27'd0, shamt} : (rs2 & 32'd31);
        // HighestSetBit and LowestSetBit of the specification (-1 and XLEN when
        // no bit is set), and the population count
        hsb = -1;
        for (i = 0; i < 32; i = i + 1) if (rs1[i]) hsb = i;
        lsb = 32;
        for (i = 31; i >= 0; i = i - 1) if (rs1[i]) lsb = i;
        cnt = 0;
        for (i = 0; i < 32; i = i + 1) if (rs1[i]) cnt = cnt + 1;
        case (id)
            5'd0:  r = rs1 & ~rs2;                                         // andn
            5'd1:  r = rs1 | ~rs2;                                         // orn
            5'd2:  r = ~(rs1 ^ rs2);                                       // xnor
            5'd3:  r = 31 - hsb;                                           // clz: XLEN - 1 - HighestSetBit
            5'd4:  r = lsb;                                                // ctz: LowestSetBit, XLEN if none
            5'd5:  r = cnt;                                                // cpop
            5'd6:  r = ($signed(rs1) < $signed(rs2)) ? rs2 : rs1;          // max
            5'd7:  r = (rs1 < rs2) ? rs2 : rs1;                            // maxu
            5'd8:  r = ($signed(rs1) < $signed(rs2)) ? rs1 : rs2;          // min
            5'd9:  r = (rs1 < rs2) ? rs1 : rs2;                            // minu
            5'd10: r = $signed(rs1[7:0]);                                  // sext.b: EXTS(rs1[7..0])
            5'd11: r = $signed(rs1[15:0]);                                 // sext.h: EXTS(rs1[15..0])
            5'd12: r = rs1[15:0];                                          // zext.h: EXTZ(rs1[15..0])
            5'd13: r = (rs1 << sh) | (rs1 >> (6'd32 - sh));                // rol
            5'd14,
            5'd15: r = (rs1 >> sh) | (rs1 << (6'd32 - sh));                // ror, rori
            5'd16: for (i = 0; i < 32; i = i + 8)                          // orc.b
                       r[i +: 8] = (rs1[i +: 8] == 8'd0) ? 8'h00 : 8'hFF;
            5'd17: begin                                                   // rev8
                       j = 31;
                       for (i = 0; i <= 24; i = i + 8) begin
                           r[i +: 8] = rs1[j - 7 +: 8];
                           j = j - 8;
                       end
                   end
            5'd18,
            5'd19: r = rs1 & ~(32'd1 << index);                            // bclr, bclri
            5'd20,
            5'd21: r = (rs1 >> index) & 32'd1;                             // bext, bexti
            5'd22,
            5'd23: r = rs1 ^ (32'd1 << index);                             // binv, binvi
            5'd24,
            5'd25: r = rs1 | (32'd1 << index);                             // bset, bseti
            5'd26: r = (rs2 == 32'd0) ? 32'd0 : rs1;                       // czero.eqz
            5'd27: r = (rs2 != 32'd0) ? 32'd0 : rs1;                       // czero.nez
            default: r = 32'd0;
        endcase
        f_spec_ext = r;
    end
endfunction
