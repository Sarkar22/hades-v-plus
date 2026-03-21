/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: instruction_decoder.sv
 */

// =============================================================================
// WHAT THIS MODULE DOES
// =============================================================================
// Takes a raw 32-bit RISC-V instruction word and breaks it into structured
// fields stored in the instruction::t struct. This is purely COMBINATIONAL —
// no clock, no registers, just wires doing bit extraction and lookup.
//
// The output struct (instruction::t) has these fields:
//   .op           — which operation to perform (op::ADD, op::BEQ, etc.)
//   .rd_address   — destination register number  (bits [11:7])
//   .rs1_address  — source register 1 number     (bits [19:15])
//   .rs2_address  — source register 2 number     (bits [24:20])
//   .csr          — CSR register address          (bits [31:20])
//   .immediate    — sign-extended immediate value (format depends on instruction)
//
// HOW CSR WORKS (quick explanation):
//   CSR = Control and Status Register. These are special registers built into
//   the CPU core itself (not the 32 general-purpose registers). Examples:
//     MSTATUS — machine status (interrupt enable bits, etc.)
//     MEPC    — machine exception PC (where to return after a trap)
//     MTVEC   — machine trap vector (where to jump on interrupt/exception)
//   CSR instructions (CSRRW, CSRRS, CSRRC, etc.) read/write these registers.
//   In a CSR instruction, bits [31:20] of the instruction encode WHICH CSR
//   register to access. That 12-bit value is stored in .csr and passed all
//   the way to the Writeback stage, which is the only stage that touches CSRs.
//   For non-CSR instructions, .csr is set but never used downstream.
// =============================================================================

module instruction_decoder (
    input  logic [31:0]   instruction_in,
    output instruction::t instruction_out
);

    // Import package names so we can write e.g. ADDI instead of op::ADDI
    import op::*;
    import csr::*;

    // =========================================================================
    // Step 1: Extract raw bit fields
    // =========================================================================
    // Every RISC-V instruction encodes its fields at fixed bit positions.
    // We give them names here for readability — these are just wires, not regs.

    logic [6:0] opcode; assign opcode = instruction_in[6:0];   // instruction type
    logic [2:0] funct3; assign funct3 = instruction_in[14:12]; // sub-operation
    logic [6:0] funct7; assign funct7 = instruction_in[31:25]; // sub-operation (R-type)

    // =========================================================================
    // Step 2: Assign fixed-position fields directly
    // =========================================================================
    // These bit positions are the same for ALL instruction formats.

    // rd  = destination register (where the result goes). Bits [11:7].
    assign instruction_out.rd_address  = instruction_in[11:7];

    // rs1 = source register 1 (first operand). Bits [19:15].
    assign instruction_out.rs1_address = instruction_in[19:15];

    // rs2 = source register 2 (second operand). Bits [24:20].
    assign instruction_out.rs2_address = instruction_in[24:20];

    // csr = CSR register address for CSR instructions. Bits [31:20].
    // csr::t'(...) is a cast — we tell SystemVerilog "treat these 12 bits
    // as a csr::t enum value". For non-CSR instructions this field is ignored.
    assign instruction_out.csr = csr::t'(instruction_in[31:20]);

    // =========================================================================
    // Step 3: Immediate value — format depends on instruction type
    // =========================================================================
    // RISC-V has 6 instruction formats, each with different immediate encoding.
    // The opcode tells us which format to use.
    //
    // WHY IS IMMEDIATE SO WEIRD?
    //   The bit scrambling (e.g. B-type) was done intentionally in RISC-V ISA
    //   design to maximize overlap of rs1/rs2/rd positions across formats, which
    //   simplifies hardware. We just un-scramble it here.
    //
    // SIGN EXTENSION:
    //   {N{bit}} replicates 'bit' N times. {20{instruction_in[31]}} fills the
    //   upper 20 bits with the sign bit (bit 31), extending the sign correctly.

    always_comb begin
        case (opcode)

            // ------------------------------------------------------------------
            // I-type: imm[11:0] = inst[31:20], sign-extended to 32 bits
            // Used by: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, JALR
            //          LB, LH, LW, LBU, LHU (load instructions)
            //          SLLI, SRLI, SRAI (shift immediates — only lower 5 bits used)
            // ------------------------------------------------------------------
            7'b0010011,  // Integer immediate: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
            7'b0000011,  // Loads: LB, LH, LW, LBU, LHU
            7'b1100111:  // JALR
                instruction_out.immediate = { {20{instruction_in[31]}}, instruction_in[31:20] };

            // ------------------------------------------------------------------
            // S-type: imm[11:5] = inst[31:25], imm[4:0] = inst[11:7], sign-extended
            // Used by: SB, SH, SW (store instructions)
            // Note: rd bits are reused to hold the lower immediate bits here
            // ------------------------------------------------------------------
            7'b0100011:  // Stores: SB, SH, SW
                instruction_out.immediate = { {20{instruction_in[31]}}, instruction_in[31:25], instruction_in[11:7] };

            // ------------------------------------------------------------------
            // B-type: branch offset, always even (LSB hardwired to 0)
            // imm = {sign, inst[7], inst[30:25], inst[11:8], 1'b0}, sign-extended
            // Used by: BEQ, BNE, BLT, BGE, BLTU, BGEU
            // ------------------------------------------------------------------
            7'b1100011:  // Branches: BEQ, BNE, BLT, BGE, BLTU, BGEU
                instruction_out.immediate = { {19{instruction_in[31]}}, instruction_in[31], instruction_in[7], instruction_in[30:25], instruction_in[11:8], 1'b0 };

            // ------------------------------------------------------------------
            // U-type: upper 20 bits, lower 12 bits zeroed
            // imm = {inst[31:12], 12'b0}
            // Used by: LUI (Load Upper Immediate), AUIPC (Add Upper Immediate to PC)
            // ------------------------------------------------------------------
            7'b0110111,  // LUI
            7'b0010111:  // AUIPC
                instruction_out.immediate = { instruction_in[31:12], 12'b0 };

            // ------------------------------------------------------------------
            // J-type: jump offset, always even (LSB hardwired to 0)
            // imm = {sign, inst[19:12], inst[20], inst[30:21], 1'b0}, sign-extended
            // Used by: JAL
            // ------------------------------------------------------------------
            7'b1101111:  // JAL
                instruction_out.immediate = { {11{instruction_in[31]}}, instruction_in[31], instruction_in[19:12], instruction_in[20], instruction_in[30:21], 1'b0 };

            // ------------------------------------------------------------------
            // CSR instructions (opcode = 1110011):
            //   CSRRW/CSRRS/CSRRC   — rs1 holds the write value, imm unused → 0
            //   CSRRWI/CSRRSI/CSRRCI — "zimm" = zero-extended bits [19:15]
            //                          (the rs1 field is reused as a 5-bit immediate)
            // We set immediate = zero-extended rs1_address for all CSR instructions.
            // For CSRRW/CSRRS/CSRRC the immediate is ignored by Writeback anyway.
            // ------------------------------------------------------------------
            7'b1110011:  // System: ECALL, EBREAK, MRET, WFI, CSR*
                instruction_out.immediate = { 27'b0, instruction_in[19:15] };

            // ------------------------------------------------------------------
            // FENCE / FENCE.I — no meaningful immediate
            // ------------------------------------------------------------------
            7'b0001111:
                instruction_out.immediate = 32'b0;

            // ------------------------------------------------------------------
            // Default: set immediate to 0 for any unrecognized opcode
            // ------------------------------------------------------------------
            default:
                instruction_out.immediate = 32'b0;

        endcase
    end

    // =========================================================================
    // Step 4: Op lookup — opcode + funct3 + funct7 → op::t enum
    // =========================================================================
    // This is a pure lookup table. We match the bit patterns from the ISA table
    // in Appendix A of the PDF and assign the corresponding op enum value.
    // Any unrecognized combination → op::ILLEGAL (will cause an exception).

    always_comb begin
        // Safe default — overridden in every valid case below
        instruction_out.op = ILLEGAL;

        case (opcode)

            // U-type — opcode alone determines the instruction
            7'b0110111: instruction_out.op = LUI;
            7'b0010111: instruction_out.op = AUIPC;

            // J-type
            7'b1101111: instruction_out.op = JAL;

            // JALR — I-type, funct3=000
            7'b1100111: instruction_out.op = (funct3 == 3'b000) ? JALR : ILLEGAL;

            // B-type branches — funct3 selects which comparison
            7'b1100011: begin
                case (funct3)
                    3'b000: instruction_out.op = BEQ;
                    3'b001: instruction_out.op = BNE;
                    3'b100: instruction_out.op = BLT;
                    3'b101: instruction_out.op = BGE;
                    3'b110: instruction_out.op = BLTU;
                    3'b111: instruction_out.op = BGEU;
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // Load instructions (I-type) — funct3 selects width and signedness
            7'b0000011: begin
                case (funct3)
                    3'b000: instruction_out.op = LB;
                    3'b001: instruction_out.op = LH;
                    3'b010: instruction_out.op = LW;
                    3'b100: instruction_out.op = LBU;
                    3'b101: instruction_out.op = LHU;
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // Store instructions (S-type) — funct3 selects width
            7'b0100011: begin
                case (funct3)
                    3'b000: instruction_out.op = SB;
                    3'b001: instruction_out.op = SH;
                    3'b010: instruction_out.op = SW;
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // Integer immediate (I-type) — ADDI, SLTI, etc.
            // Shifts (SLLI, SRLI, SRAI) also live here but need funct7 to distinguish
            7'b0010011: begin
                case (funct3)
                    3'b000: instruction_out.op = ADDI;
                    3'b010: instruction_out.op = SLTI;
                    3'b011: instruction_out.op = SLTIU;
                    3'b100: instruction_out.op = XORI;
                    3'b110: instruction_out.op = ORI;
                    3'b111: instruction_out.op = ANDI;
                    // Shifts: funct7 bit 5 distinguishes arithmetic from logical
                    3'b001: instruction_out.op = (funct7 == 7'b0000000) ? SLLI : ILLEGAL;
                    3'b101: begin
                        case (funct7)
                            7'b0000000: instruction_out.op = SRLI;
                            7'b0100000: instruction_out.op = SRAI;
                            default:    instruction_out.op = ILLEGAL;
                        endcase
                    end
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // Integer register-register (R-type) — funct3 + funct7 select operation
            7'b0110011: begin
                case ({funct7, funct3})  // concatenate both to match in one case
                    {7'b0000000, 3'b000}: instruction_out.op = ADD;
                    {7'b0100000, 3'b000}: instruction_out.op = SUB;
                    {7'b0000000, 3'b001}: instruction_out.op = SLL;
                    {7'b0000000, 3'b010}: instruction_out.op = SLT;
                    {7'b0000000, 3'b011}: instruction_out.op = SLTU;
                    {7'b0000000, 3'b100}: instruction_out.op = XOR;
                    {7'b0000000, 3'b101}: instruction_out.op = SRL;
                    {7'b0100000, 3'b101}: instruction_out.op = SRA;
                    {7'b0000000, 3'b110}: instruction_out.op = OR;
                    {7'b0000000, 3'b111}: instruction_out.op = AND;
                    default:              instruction_out.op = ILLEGAL;
                endcase
            end

            // FENCE / FENCE.I — funct3 distinguishes them
            7'b0001111: begin
                case (funct3)
                    3'b000: instruction_out.op = FENCE;
                    3'b001: instruction_out.op = FENCE_I;
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // System instructions: ECALL, EBREAK, MRET, WFI, CSR*
            // funct3=000 → privileged instructions (ECALL, EBREAK, MRET, WFI)
            // funct3≠000 → CSR instructions
            7'b1110011: begin
                case (funct3)
                    3'b000: begin
                        // Distinguish by the full upper 25 bits (inst[31:7])
                        case (instruction_in[31:7])
                            // ECALL:  all zero except opcode
                            25'b0000000_00000_00000_000_00000: instruction_out.op = ECALL;
                            // EBREAK: bit 20 set
                            25'b0000000_00001_00000_000_00000: instruction_out.op = EBREAK;
                            // MRET:   inst[31:20] = 001100000010
                            25'b0011000_00010_00000_000_00000: instruction_out.op = MRET;
                            // WFI:    inst[31:20] = 000100000101
                            25'b0001000_00101_00000_000_00000: instruction_out.op = WFI;
                            default: instruction_out.op = ILLEGAL;
                        endcase
                    end
                    // CSR instructions — funct3 selects the operation type
                    3'b001: instruction_out.op = CSRRW;
                    3'b010: instruction_out.op = CSRRS;
                    3'b011: instruction_out.op = CSRRC;
                    3'b101: instruction_out.op = CSRRWI;
                    3'b110: instruction_out.op = CSRRSI;
                    3'b111: instruction_out.op = CSRRCI;
                    default: instruction_out.op = ILLEGAL;
                endcase
            end

            // Any opcode not listed above is illegal
            default: instruction_out.op = ILLEGAL;

        endcase
    end

endmodule
