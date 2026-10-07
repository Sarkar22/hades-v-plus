/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: op.sv
 */



/*verilator lint_off UNUSED*/

package op;
    typedef enum logic [5:0] {
        LUI,
        AUIPC,
        JAL,
        JALR,
        BEQ,
        BNE,
        BLT,
        BGE,
        BLTU,
        BGEU,
        LB,
        LH,
        LW,
        LBU,
        LHU,
        SB,
        SH,
        SW,
        ADDI,
        SLTI,
        SLTIU,
        XORI,
        ORI,
        ANDI,
        SLLI,
        SRLI,
        SRAI,
        ADD,
        SUB,
        SLL,
        SLT,
        SLTU,
        XOR,
        SRL,
        SRA,
        OR,
        AND,
        FENCE,
        FENCE_I,
        ECALL,
        EBREAK,
        CSRRW,
        CSRRS,
        CSRRC,
        CSRRWI,
        CSRRSI,
        CSRRCI,
        MRET,
        WFI,
        ILLEGAL,

        // Zba (address generation): rd = (rs1 << N) + rs2, N = 1, 2, 3.
        //
        // These sit AFTER ILLEGAL, which looks like a mistake until you know why.
        // op::t is the first field of instruction::t, and that struct is a 65-bit
        // port on every pipeline stage — including the frozen ref/*.so golden
        // models, which were compiled against the ORIGINAL numbering and cannot be
        // regenerated. Inserting before ILLEGAL would renumber it from 49 to 52,
        // and every DUT-vs-REF bench that hands the reference an op::ILLEGAL
        // (test_execute_compare's special_ops list does exactly that) would be
        // feeding it a code it has never heard of. Appending leaves codes 0..49
        // bit-identical and claims only the previously unused 50, 51, 52 — 53 of
        // 64 codes now in use, so the enum stays 6 bits wide and the struct stays
        // at 65 bits.
        SH1ADD,
        SH2ADD,
        SH3ADD,

        // M (integer multiply / divide), opcode 0110011, funct7 = 0000001.
        //
        // Appended for exactly the reason spelled out above the Zba block: op::t
        // numbering is positional and baked into the frozen ref/*.so models via
        // the 65-bit instruction::t port.  Codes 0..52 stay bit-identical and
        // these eight claim 53..60 -- 61 of 64 codes in use, so the enum is
        // still 6 bits and instruction::t is still 65 bits.  Three codes remain.
        //
        // The order here is deliberately funct3 order (000..111), so a decoder
        // or execute-stage arm can be read against the ISA table line by line.
        MUL,
        MULH,
        MULHSU,
        MULHU,
        DIV,
        DIVU,
        REM,
        REMU,

        // Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh: ONE op for all 45 instructions.
        //
        // Appended for the same reason as the Zba and M blocks above, but here even
        // appending one op per instruction is impossible: only 61, 62 and 63 were
        // left. So the 45 instructions share the single code 61, and the decoder
        // says which of them it is through the immediate field (ext_payload_t
        // below). R-type instructions never used that field, so the sub-operation
        // reaches Execute in a field that already exists, without a new port and
        // without touching the 65-bit instruction::t that the frozen models see.
        // 62 of 64 codes in use; 62 and 63 remain.
        EXT
    } t;

    // Sub-operation of op::EXT: {crypto, group[2:0], variant[1:0]}.
    //
    // The crypto bit picks one of two halves of the unit in Execute, the three
    // group bits one of eight result groups inside the half, and the two variant
    // bits pick inside the group, so a group that shares hardware (one
    // comparator for min/max, one rotator for rol/ror/bext, one zero test for
    // both czero forms) reads its variant bits directly.
    //   crypto = 0: Zbb, Zbs and Zicond (the codes of the first 28 instructions,
    //   which were 5 bits wide; widening kept every value)
    //     0 LOGIC      andn, orn, xnor
    //     1 COUNT      clz, ctz, cpop
    //     2 MINMAX     min, minu, max, maxu      variant[0] = unsigned, variant[1] = max
    //     3 EXTEND     sext.b, sext.h, zext.h
    //     4 ROTATE     rol, ror (and rori)
    //     5 BYTE       orc.b, rev8
    //     6 BIT        bclr, bext, binv, bset (and their immediate forms)
    //     7 CZERO      czero.eqz, czero.nez      variant[0] = nez
    //   crypto = 1: Zbkb, Zbkx and Zknh (the forms Zbb does not already have)
    //     0 PACK       pack, packh
    //     1 PERM       brev8, zip, unzip
    //     2 XPERM      xperm4, xperm8
    //     3 SHA256     sig0, sig1, sum0, sum1    variant[1] = sum
    //     4 SHA512SIG  sig0h, sig0l, sig1h, sig1l
    //                                            variant[1] = sig1, variant[0] = low half
    //     5 SHA512SUM  sum0r, sum1r
    // Codes not listed are reserved: the decoder never produces them.
    typedef enum logic [5:0] {
        EXT_ANDN        = 6'b0_000_00, EXT_ORN         = 6'b0_000_01, EXT_XNOR        = 6'b0_000_10,
        EXT_CLZ         = 6'b0_001_00, EXT_CTZ         = 6'b0_001_01, EXT_CPOP        = 6'b0_001_10,
        EXT_MIN         = 6'b0_010_00, EXT_MINU        = 6'b0_010_01,
        EXT_MAX         = 6'b0_010_10, EXT_MAXU        = 6'b0_010_11,
        EXT_SEXT_B      = 6'b0_011_00, EXT_SEXT_H      = 6'b0_011_01, EXT_ZEXT_H      = 6'b0_011_10,
        EXT_ROL         = 6'b0_100_00, EXT_ROR         = 6'b0_100_01,
        EXT_ORC_B       = 6'b0_101_00, EXT_REV8        = 6'b0_101_01,
        EXT_BCLR        = 6'b0_110_00, EXT_BEXT        = 6'b0_110_01,
        EXT_BINV        = 6'b0_110_10, EXT_BSET        = 6'b0_110_11,
        EXT_CZERO_EQZ   = 6'b0_111_00, EXT_CZERO_NEZ   = 6'b0_111_01,

        EXT_PACK        = 6'b1_000_00, EXT_PACKH       = 6'b1_000_01,
        EXT_BREV8       = 6'b1_001_00, EXT_ZIP         = 6'b1_001_01, EXT_UNZIP       = 6'b1_001_10,
        EXT_XPERM4      = 6'b1_010_00, EXT_XPERM8      = 6'b1_010_01,
        EXT_SHA256SIG0  = 6'b1_011_00, EXT_SHA256SIG1  = 6'b1_011_01,
        EXT_SHA256SUM0  = 6'b1_011_10, EXT_SHA256SUM1  = 6'b1_011_11,
        EXT_SHA512SIG0H = 6'b1_100_00, EXT_SHA512SIG0L = 6'b1_100_01,
        EXT_SHA512SIG1H = 6'b1_100_10, EXT_SHA512SIG1L = 6'b1_100_11,
        EXT_SHA512SUM0R = 6'b1_101_00, EXT_SHA512SUM1R = 6'b1_101_01
    } ext_t;

    // instruction::t.immediate of an op::EXT instruction.
    //
    // The decoder builds all 32 bits from scratch for an EXT word; it never ORs
    // anything into an I-type immediate. The immediate forms (rori, bclri, bexti,
    // binvi, bseti) share the code of their register form and set use_imm, and
    // their shift amount sits in [4:0], where an I-type immediate keeps it too.
    // The payload is canonical (shamt is 0 unless use_imm, [31:12] always 0), so a
    // test can require exact equality. sel[5] took bit 11, which the first layout
    // kept free for it, so the payload of every Zbb, Zbs and Zicond instruction is
    // the same 32-bit value as before.
    typedef struct packed {
        logic [19:0] zero;     // [31:12] always 0
        ext_t        sel;      // [11:6]  sub-operation; [11] selects the crypto half
        logic        use_imm;  // [5]     operand B is shamt rather than rs2
        logic [4:0]  shamt;    // [4:0]   inst[24:20] when use_imm, else 0
    } ext_payload_t;           // $bits = 32
endpackage

/*verilator lint_on UNUSED*/
