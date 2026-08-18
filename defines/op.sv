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
        REMU
    } t;
endpackage

/*verilator lint_on UNUSED*/
