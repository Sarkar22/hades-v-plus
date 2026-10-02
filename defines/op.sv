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

        // Zbb, Zbs and Zicond: ONE op for all 28 instructions.
        //
        // Appended for the same reason as the Zba and M blocks above, but here even
        // appending one op per instruction is impossible: only 61, 62 and 63 were
        // left. So the 28 instructions share the single code 61, and the decoder
        // says which of them it is through the immediate field (ext_payload_t
        // below). R-type instructions never used that field, so the sub-operation
        // reaches Execute in a field that already exists, without a new port and
        // without touching the 65-bit instruction::t that the frozen models see.
        // 62 of 64 codes in use; 62 and 63 remain.
        EXT
    } t;

    // Sub-operation of op::EXT: {group[2:0], variant[1:0]}.
    //
    // The three group bits pick one of eight result groups in Execute, and the
    // two variant bits pick inside the group, so a group that shares hardware
    // (one comparator for min/max, one rotator for rol/ror/bext, one zero test
    // for both czero forms) reads its variant bits directly:
    //   0 LOGIC   andn, orn, xnor
    //   1 COUNT   clz, ctz, cpop
    //   2 MINMAX  min, minu, max, maxu   variant[0] = unsigned, variant[1] = max
    //   3 EXTEND  sext.b, sext.h, zext.h
    //   4 ROTATE  rol, ror (and rori)
    //   5 BYTE    orc.b, rev8
    //   6 BIT     bclr, bext, binv, bset (and their immediate forms)
    //   7 CZERO   czero.eqz, czero.nez   variant[0] = nez
    // Codes not listed are reserved: the decoder never produces them.
    typedef enum logic [4:0] {
        EXT_ANDN      = 5'b000_00, EXT_ORN    = 5'b000_01, EXT_XNOR   = 5'b000_10,
        EXT_CLZ       = 5'b001_00, EXT_CTZ    = 5'b001_01, EXT_CPOP   = 5'b001_10,
        EXT_MIN       = 5'b010_00, EXT_MINU   = 5'b010_01, EXT_MAX    = 5'b010_10, EXT_MAXU = 5'b010_11,
        EXT_SEXT_B    = 5'b011_00, EXT_SEXT_H = 5'b011_01, EXT_ZEXT_H = 5'b011_10,
        EXT_ROL       = 5'b100_00, EXT_ROR    = 5'b100_01,
        EXT_ORC_B     = 5'b101_00, EXT_REV8   = 5'b101_01,
        EXT_BCLR      = 5'b110_00, EXT_BEXT   = 5'b110_01, EXT_BINV   = 5'b110_10, EXT_BSET = 5'b110_11,
        EXT_CZERO_EQZ = 5'b111_00, EXT_CZERO_NEZ = 5'b111_01
    } ext_t;

    // instruction::t.immediate of an op::EXT instruction.
    //
    // The decoder builds all 32 bits from scratch for an EXT word; it never ORs
    // anything into an I-type immediate. The immediate forms (rori, bclri, bexti,
    // binvi, bseti) share the code of their register form and set use_imm, and
    // their shift amount sits in [4:0], where an I-type immediate keeps it too.
    // The payload is canonical (shamt is 0 unless use_imm, [31:11] always 0), so a
    // test can require exact equality.
    typedef struct packed {
        logic [20:0] zero;     // [31:11] always 0 (room to widen sel later)
        ext_t        sel;      // [10:6]  sub-operation
        logic        use_imm;  // [5]     operand B is shamt rather than rs2
        logic [4:0]  shamt;    // [4:0]   inst[24:20] when use_imm, else 0
    } ext_payload_t;           // $bits = 32
endpackage

/*verilator lint_on UNUSED*/
