// =============================================================================
// ext_spec.vh -- result of the 45 Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh
// instructions, written from the ratified specifications, NOT from
// rtl/execute_stage.sv:
//   RISC-V Bit-Manipulation ISA-extensions, version 1.0.0 (Zbb, Zbs; the
//     "Insn" pages and their Sail operation, for XLEN = 32),
//   RISC-V Integer Conditional (Zicond) operations extension, version 1.0, and
//   RISC-V Cryptography Extensions Volume I: Scalar & Entropy Source
//     Instructions, version 1.0.1 (Zbkb, Zbkx, Zknh; the instruction pages and
//     their Sail operation, for XLEN = 32).
//
// f_spec_ext(id, rs1, rs2, shamt) is X[rd] for the instruction numbered id below,
// with X(rs1) = rs1 and X(rs2) = rs2. shamt is the instruction's shamt field
// (inst[24:20]); only the immediate forms read it, as the specification says
// (on RV32 their shamt[5] must be 0, so the field has five bits). The
// one-operand forms read rs1 only.
//
// The numbering is this file's own (the order of the specifications'
// instruction lists); harness/top_ext.v maps it to the decoder's payload of
// defines/op.sv, and scripts/ext_codes.py checks that map against op.sv.
//
//    0 andn    1 orn     2 xnor    3 clz     4 ctz     5 cpop    6 max
//    7 maxu    8 min     9 minu   10 sext.b 11 sext.h 12 zext.h 13 rol
//   14 ror    15 rori   16 orc.b  17 rev8   18 bclr   19 bclri  20 bext
//   21 bexti  22 binv   23 binvi  24 bset   25 bseti  26 czero.eqz
//   27 czero.nez        28 pack   29 packh  30 brev8  31 zip    32 unzip
//   33 xperm4 34 xperm8 35 sha256sig0       36 sha256sig1       37 sha256sum0
//   38 sha256sum1       39 sha512sig0h      40 sha512sig0l      41 sha512sig1h
//   42 sha512sig1l      43 sha512sum0r      44 sha512sum1r
//
// The style follows the Sail operation of each instruction: the counts scan bit
// by bit (HighestSetBit, LowestSetBit, a counting loop), the rotates are the
// two-shift formula, orc.b and rev8 loop over bytes, the single-bit
// instructions build their mask as 1 << (rs2 & (XLEN - 1)), sign extension is
// a signed cast. For the cryptography instructions: pack and packh concatenate
// hi_half @ lo_half; brev8 reverses the bits of each byte in a loop over bytes;
// zip and unzip are the Sail loops over i = 0 .. XLEN/2 - 1; xperm4 and xperm8
// look up (lut >> (idx @ 0b00))[3..0] and (lut >> (idx @ 0b000))[7..0], which
// gives zero for an index past the end of rs1; the sha256 functions use ror32, written as
// two shifts; the sha512 functions are the Sail shift expressions verbatim.
// spec_check/check_ext_spec.py cross-checks every function value against an
// independent Python model.
// =============================================================================

// ror32 of the Sail code: a 32-bit rotation right by a constant n (0 < n < 32),
// written as two shifts.
function [31:0] f_ror32;
    input [31:0] x;
    input integer n;
    begin
        f_ror32 = (x >> n) | (x << (32 - n));
    end
endfunction

function [31:0] f_spec_ext;
    input [5:0]  id;
    input [31:0] rs1;
    input [31:0] rs2;
    input [4:0]  shamt;
    reg   [5:0]  sh;         // rotate amount, six bits wide so that XLEN - sh can be 32
    reg   [31:0] index;      // bit index of Zbs: rs2 & (XLEN - 1), or shamt
    reg   [31:0] r;
    reg   [3:0]  idx4;       // xperm4: index element of rs2
    reg   [7:0]  idx8;       // xperm8: index element of rs2
    integer      i, j, hsb, lsb, cnt;
    begin
        r     = 32'd0;
        sh    = (id == 6'd15) ? {1'b0, shamt} : {1'b0, rs2[4:0]};
        index = (id == 6'd19 || id == 6'd21 || id == 6'd23 || id == 6'd25)
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
            6'd0:  r = rs1 & ~rs2;                                         // andn
            6'd1:  r = rs1 | ~rs2;                                         // orn
            6'd2:  r = ~(rs1 ^ rs2);                                       // xnor
            6'd3:  r = 31 - hsb;                                           // clz: XLEN - 1 - HighestSetBit
            6'd4:  r = lsb;                                                // ctz: LowestSetBit, XLEN if none
            6'd5:  r = cnt;                                                // cpop
            6'd6:  r = ($signed(rs1) < $signed(rs2)) ? rs2 : rs1;          // max
            6'd7:  r = (rs1 < rs2) ? rs2 : rs1;                            // maxu
            6'd8:  r = ($signed(rs1) < $signed(rs2)) ? rs1 : rs2;          // min
            6'd9:  r = (rs1 < rs2) ? rs1 : rs2;                            // minu
            6'd10: r = $signed(rs1[7:0]);                                  // sext.b: EXTS(rs1[7..0])
            6'd11: r = $signed(rs1[15:0]);                                 // sext.h: EXTS(rs1[15..0])
            6'd12: r = rs1[15:0];                                          // zext.h: EXTZ(rs1[15..0])
            6'd13: r = (rs1 << sh) | (rs1 >> (6'd32 - sh));                // rol
            6'd14,
            6'd15: r = (rs1 >> sh) | (rs1 << (6'd32 - sh));                // ror, rori
            6'd16: for (i = 0; i < 32; i = i + 8)                          // orc.b
                       r[i +: 8] = (rs1[i +: 8] == 8'd0) ? 8'h00 : 8'hFF;
            6'd17: begin                                                   // rev8
                       j = 31;
                       for (i = 0; i <= 24; i = i + 8) begin
                           r[i +: 8] = rs1[j - 7 +: 8];
                           j = j - 8;
                       end
                   end
            6'd18,
            6'd19: r = rs1 & ~(32'd1 << index);                            // bclr, bclri
            6'd20,
            6'd21: r = (rs1 >> index) & 32'd1;                             // bext, bexti
            6'd22,
            6'd23: r = rs1 ^ (32'd1 << index);                             // binv, binvi
            6'd24,
            6'd25: r = rs1 | (32'd1 << index);                             // bset, bseti
            6'd26: r = (rs2 == 32'd0) ? 32'd0 : rs1;                       // czero.eqz
            6'd27: r = (rs2 != 32'd0) ? 32'd0 : rs1;                       // czero.nez
            // ---- Zbkb (pack, packh, brev8, zip, unzip) ----
            6'd28: r = {rs2[15:0], rs1[15:0]};                             // pack: hi_half @ lo_half
            6'd29: r = {16'd0, rs2[7:0], rs1[7:0]};                        // packh: EXTZ(hi_half @ lo_half)
            6'd30: for (i = 0; i < 32; i = i + 8)                          // brev8: reverse_bits_in_byte
                       for (j = 0; j < 8; j = j + 1)
                           r[i + j] = rs1[i + 7 - j];
            6'd31: for (i = 0; i < 16; i = i + 1) begin                    // zip
                       r[2 * i]     = rs1[i];
                       r[2 * i + 1] = rs1[i + 16];
                   end
            6'd32: for (i = 0; i < 16; i = i + 1) begin                    // unzip
                       r[i]      = rs1[2 * i];
                       r[i + 16] = rs1[2 * i + 1];
                   end
            // ---- Zbkx (xperm4, xperm8): rs1 is the table, rs2 the indices ----
            6'd33: for (i = 0; i < 32; i = i + 4) begin                    // xperm4
                       idx4 = rs2[i +: 4];
                       r[i +: 4] = (rs1 >> {idx4, 2'b00}) & 32'hF;         // (lut >> (idx @ 0b00))[3..0]
                   end
            6'd34: for (i = 0; i < 32; i = i + 8) begin                    // xperm8
                       idx8 = rs2[i +: 8];
                       r[i +: 8] = (rs1 >> {idx8, 3'b000}) & 32'hFF;       // (lut >> (idx @ 0b000))[7..0]
                   end
            // ---- Zknh, SHA-256 (rs1 only) ----
            6'd35: r = f_ror32(rs1, 7) ^ f_ror32(rs1, 18) ^ (rs1 >> 3);    // sha256sig0
            6'd36: r = f_ror32(rs1, 17) ^ f_ror32(rs1, 19) ^ (rs1 >> 10);  // sha256sig1
            6'd37: r = f_ror32(rs1, 2) ^ f_ror32(rs1, 13) ^ f_ror32(rs1, 22);  // sha256sum0
            6'd38: r = f_ror32(rs1, 6) ^ f_ror32(rs1, 11) ^ f_ror32(rs1, 25);  // sha256sum1
            // ---- Zknh, SHA-512 on RV32 (the Sail expressions, X(rs1) = rs1, X(rs2) = rs2) ----
            6'd39: r = (rs1 >> 1) ^ (rs1 >> 7) ^ (rs1 >> 8)                // sha512sig0h
                       ^ (rs2 << 31) ^ (rs2 << 24);
            6'd40: r = (rs1 >> 1) ^ (rs1 >> 7) ^ (rs1 >> 8)                // sha512sig0l
                       ^ (rs2 << 31) ^ (rs2 << 25) ^ (rs2 << 24);
            6'd41: r = (rs1 << 3) ^ (rs1 >> 6) ^ (rs1 >> 19)               // sha512sig1h
                       ^ (rs2 >> 29) ^ (rs2 << 13);
            6'd42: r = (rs1 << 3) ^ (rs1 >> 6) ^ (rs1 >> 19)               // sha512sig1l
                       ^ (rs2 >> 29) ^ (rs2 << 26) ^ (rs2 << 13);
            6'd43: r = (rs1 << 25) ^ (rs1 << 30) ^ (rs1 >> 28)             // sha512sum0r
                       ^ (rs2 >> 7) ^ (rs2 >> 2) ^ (rs2 << 4);
            6'd44: r = (rs1 << 23) ^ (rs1 >> 14) ^ (rs1 >> 18)             // sha512sum1r
                       ^ (rs2 >> 9) ^ (rs2 << 18) ^ (rs2 << 14);
            default: r = 32'd0;
        endcase
        f_spec_ext = r;
    end
endfunction
