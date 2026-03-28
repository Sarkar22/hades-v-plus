/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: writeback_stage.sv
 */

// =============================================================================
// WHAT THIS MODULE DOES
// =============================================================================
// The Writeback Stage is the last pipeline stage. It handles:
//  - CSR register management (read/write/modify)
//  - Exception handling (trap to MTVEC on error status)
//  - Interrupt handling (trap to MTVEC when enabled and pending)
//  - MRET (return from trap), FENCE.I (flush icache)
//  - Forwarding the final rd value to Decode
//
// IMPORTANT TIMING:
//  - Exception/MRET/FENCE.I → combinational JUMP (immediate)
//  - Interrupt → sequential JUMP (detected at posedge, visible after posedge)
//  - Forwarding → combinational (reads current CSR state)
//  - When int_jump_reg fires (sequential JUMP), the stale instruction arriving
//    that cycle is suppressed: CSR writes, MRET, trap effects, and minstret
//    are all gated by !int_jump_reg.
//  - This stage NEVER stalls.
// =============================================================================

module writeback_stage (
    input logic clk,
    input logic rst,

    // Inputs
    input logic [31:0]   source_data_in,
    input logic [31:0]   rd_data_in,
    input instruction::t instruction_in,
    input logic [31:0]   program_counter_in,
    input logic [31:0]   next_program_counter_in,

    // Interrupt signals
    input logic external_interrupt_in,
    input logic timer_interrupt_in,

    // Outputs
    output forwarding::t forwarding_out,

    // Pipeline control
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::backwards_t status_backwards_out,
    output logic [31:0] jump_address_backwards_out
);

    import pipeline_status::*;
    import op::*;

    // =========================================================================
    // Part 1: CSR Register File
    // =========================================================================

    // MSTATUS: only MPIE (bit 7) and MIE (bit 3)
    logic mstatus_mpie, mstatus_mie;

    // MTVEC: trap vector (lowest 2 bits forced to 0)
    logic [31:0] mtvec;

    // MIE: MEIE (bit 11), MTIE (bit 7)
    logic mie_meie, mie_mtie;

    // MIP: registered from interrupt inputs (latched on posedge for CSR reads)
    logic mip_meip_reg, mip_mtip_reg;

    // MEPC, MCAUSE, MSCRATCH
    logic [31:0] mepc, mcause, mscratch;

    // MCYCLE/MCYCLEH: 64-bit cycle counter (counts every cycle including reset)
    logic [63:0] mcycle;

    // MINSTRET/MINSTRETH: 64-bit retired-instruction counter
    logic [63:0] minstret;

    // =========================================================================
    // Part 2: Classify instruction (raw status — for combo outputs)
    // =========================================================================

    logic is_valid, is_bubble, is_exception;
    logic is_csr_op, is_csr_read_op, is_mret, is_fence_i, is_fence;

    assign is_valid  = (status_forwards_in == VALID);
    assign is_bubble = (status_forwards_in == BUBBLE);

    always_comb begin
        case (status_forwards_in)
            VALID, BUBBLE: is_exception = 1'b0;
            default:       is_exception = 1'b1;
        endcase
    end

    // All CSR operations (for write enable)
    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI: is_csr_op = 1'b1;
            default: is_csr_op = 1'b0;
        endcase
    end

    // CSR ops that read the CSR and forward the value to rd:
    //   CSRRW/CSRRS/CSRRC/CSRRSI/CSRRCI: writeback reads CSR internally.
    //   CSRRWI: forward rd_data_in (CSR read handled by earlier pipeline stage).
    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRS, CSRRC, CSRRSI, CSRRCI: is_csr_read_op = 1'b1;
            default: is_csr_read_op = 1'b0;
        endcase
    end

    assign is_mret    = is_valid && (instruction_in.op == MRET);
    assign is_fence_i = is_valid && (instruction_in.op == FENCE_I);
    assign is_fence   = is_valid && (instruction_in.op == FENCE);

    // =========================================================================
    // Part 3: CSR Read — current value of addressed CSR
    // =========================================================================
    // MIP uses REGISTERED interrupt inputs (latched on previous posedge).
    // MCYCLE/MCYCLEH and MINSTRET/MINSTRETH forward the post-increment value:
    // the counter increments at posedge, so the value visible to the retiring
    // instruction must include that increment ("increment first, then write").

    logic [63:0] mcycle_read;
    logic [63:0] minstret_read;
    assign mcycle_read   = mcycle + 64'd1;
    assign minstret_read = minstret + (is_valid ? 64'd1 : 64'd0);

    logic [31:0] csr_read_val;

    always_comb begin
        case (instruction_in.csr)
            csr::MSTATUS:   csr_read_val = {24'b0, mstatus_mpie, 3'b0, mstatus_mie, 3'b0};
            csr::MTVEC:     csr_read_val = mtvec;
            csr::MIE:       csr_read_val = {20'b0, mie_meie, 3'b0, mie_mtie, 7'b0};
            csr::MIP:       csr_read_val = {20'b0, mip_meip_reg, 3'b0, mip_mtip_reg, 7'b0};
            csr::MEPC:      csr_read_val = mepc;
            csr::MCAUSE:    csr_read_val = mcause;
            csr::MSCRATCH:  csr_read_val = mscratch;
            csr::MCYCLE:    csr_read_val = mcycle_read[31:0];
            csr::MCYCLEH:   csr_read_val = mcycle_read[63:32];
            csr::MINSTRET:  csr_read_val = minstret_read[31:0];
            csr::MINSTRETH: csr_read_val = minstret_read[63:32];
            default:        csr_read_val = 32'b0;
        endcase
    end

    // =========================================================================
    // Part 4: CSR Write Value
    // =========================================================================
    // source_data_in is used for ALL CSR variants. The decode/execute stages
    // set source_data_in = rs1 for register variants and
    // source_data_in = zero_extend(uimm) for immediate variants.

    logic [31:0] csr_write_val;

    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRWI: csr_write_val = source_data_in;
            CSRRS, CSRRSI: csr_write_val = csr_read_val | source_data_in;
            CSRRC, CSRRCI: csr_write_val = csr_read_val & ~source_data_in;
            default:       csr_write_val = csr_read_val;
        endcase
    end

    // =========================================================================
    // Part 5: Effective interrupt enable flags (for interrupt detection)
    // =========================================================================
    // Note 14: "If any of the flags are changed by the current instruction,
    // the updated values must be used." Used for interrupt detection at posedge.
    // Gated by !int_jump_reg: when a sequential interrupt JUMP is pending,
    // the stale instruction's CSR effects do not apply to flag computation.

    logic int_jump_reg;         // registered: interrupt JUMP pending
    logic [31:0] int_addr_reg;  // registered: interrupt jump address

    logic mie_eff, meie_eff, mtie_eff, mpie_eff;

    always_comb begin
        mie_eff  = mstatus_mie;
        meie_eff = mie_meie;
        mtie_eff = mie_mtie;
        mpie_eff = mstatus_mpie;

        if (!int_jump_reg && is_valid && is_csr_op) begin
            case (instruction_in.csr)
                csr::MSTATUS: begin
                    mie_eff  = csr_write_val[3];
                    mpie_eff = csr_write_val[7];
                end
                csr::MIE: begin
                    meie_eff = csr_write_val[11];
                    mtie_eff = csr_write_val[7];
                end
                default: ;
            endcase
        end

        if (!int_jump_reg && is_mret) begin
            mie_eff  = mpie_eff;
            mpie_eff = 1'b1;
        end
    end

    // =========================================================================
    // Part 6: Interrupt detection
    // =========================================================================
    // Uses LIVE interrupt inputs (not registered) and EFFECTIVE enable flags.
    // Interrupt fires when instruction completes (VALID or ERROR, not BUBBLE).
    // Gated by !int_jump_reg to prevent re-detection during stale cycle.

    logic ext_int_pending, timer_int_pending;
    logic is_interrupt, is_trap;

    assign ext_int_pending   = external_interrupt_in && meie_eff && mie_eff;
    assign timer_int_pending = timer_interrupt_in && mtie_eff && mie_eff;
    assign is_interrupt = !int_jump_reg && !is_bubble && (ext_int_pending || timer_int_pending);
    assign is_trap = is_exception || is_interrupt;

    // =========================================================================
    // Part 7: MCAUSE and MEPC for trap
    // =========================================================================

    logic [31:0] trap_cause;

    always_comb begin
        if (is_interrupt) begin
            if (ext_int_pending)
                trap_cause = 32'h8000000B;
            else
                trap_cause = 32'h80000007;
        end else begin
            case (status_forwards_in)
                FETCH_MISALIGNED:         trap_cause = 32'd0;
                FETCH_FAULT:              trap_cause = 32'd1;
                ILLEGAL_INSTRUCTION:      trap_cause = 32'd2;
                pipeline_status::EBREAK:  trap_cause = 32'd3;
                LOAD_MISALIGNED:          trap_cause = 32'd4;
                LOAD_FAULT:               trap_cause = 32'd5;
                STORE_MISALIGNED:         trap_cause = 32'd6;
                STORE_FAULT:              trap_cause = 32'd7;
                pipeline_status::ECALL:   trap_cause = 32'd11;
                default:                  trap_cause = 32'd0;
            endcase
        end
    end

    logic [31:0] trap_mepc;

    always_comb begin
        if (is_interrupt && is_mret)
            trap_mepc = mepc;
        else if (is_interrupt)
            trap_mepc = next_program_counter_in;
        else
            trap_mepc = program_counter_in;
    end

    // =========================================================================
    // Part 8: Registered interrupt JUMP detection
    // =========================================================================
    // Interrupts generate JUMP sequentially (visible after posedge).
    // Exceptions/MRET/FENCE.I generate JUMP combinationally (immediate).

    always_ff @(posedge clk) begin
        if (rst) begin
            int_jump_reg <= 1'b0;
            int_addr_reg <= 32'b0;
        end else begin
            // Suppress int_jump_reg only when CSR write enables interrupt:
            // that case is handled combinationally in Part 9.
            // MRET+interrupt: int_jump_reg IS set so REG check (after posedge)
            // shows JUMP to mtvec via int_jump_reg.
            int_jump_reg <= is_interrupt
                            && !(is_csr_op && (instruction_in.csr == csr::MSTATUS
                                               || instruction_in.csr == csr::MIE));
            int_addr_reg <= mtvec;
        end
    end

    // =========================================================================
    // Part 9: Pipeline backwards control (COMBINATIONAL with seq interrupt)
    // =========================================================================
    // Priority: int_jump_reg > exception > MRET > FENCE.I > READY
    // int_jump_reg has highest priority because it represents a pipeline control
    // decision from the previous posedge. The stale instruction's combinational
    // signals (exception/MRET/FENCE.I) should not override it.

    always_comb begin
        if (int_jump_reg) begin
            // Interrupt detected at previous posedge — sequential JUMP
            status_backwards_out       = JUMP;
            jump_address_backwards_out = int_addr_reg;
        end else if (is_exception) begin
            status_backwards_out       = JUMP;
            jump_address_backwards_out = mtvec;
        end else if (is_interrupt && is_csr_op && (instruction_in.csr == csr::MSTATUS
                                                    || instruction_in.csr == csr::MIE)) begin
            // CSR write enables interrupt same cycle → combinational JUMP to mtvec
            status_backwards_out       = JUMP;
            jump_address_backwards_out = mtvec;
        end else if (is_mret) begin
            // MRET always jumps to mepc (even if interrupt is pending).
            // When interrupt is also pending, MRET effects restore MIE=1, and
            // the interrupt will fire again when the instruction at mepc retires.
            status_backwards_out       = JUMP;
            jump_address_backwards_out = mepc;
        end else if (is_fence_i) begin
            status_backwards_out       = JUMP;
            jump_address_backwards_out = next_program_counter_in;
        end else begin
            status_backwards_out       = READY;
            jump_address_backwards_out = 32'b0;
        end
    end

    // =========================================================================
    // Part 10: Forwarding output (COMBINATIONAL — raw status, no suppression)
    // =========================================================================
    // CSR ops: forward csr_read_val (old CSR value before any write).
    // Non-CSR: forward rd_data_in (ALU/memory result).

    always_comb begin
        if (is_valid) begin
            // All CSR ops forward the old CSR value (csr_read_val).
            // Non-CSR ops forward rd_data_in (ALU/memory result).
            if (is_csr_op)
                forwarding_out.data = csr_read_val;
            else
                forwarding_out.data = rd_data_in;

            forwarding_out.address = instruction_in.rd_address;

            // data_valid = 0 for FENCE and FENCE.I (no register write)
            if (is_fence_i || is_fence)
                forwarding_out.data_valid = 1'b0;
            else
                forwarding_out.data_valid = 1'b1;
        end else begin
            forwarding_out.data       = rd_data_in;
            forwarding_out.address    = 5'b0;
            forwarding_out.data_valid = 1'b0;
        end
    end

    // =========================================================================
    // Part 11: Counter write suppression helpers
    // =========================================================================
    // Only CSRRW/CSRRWI explicitly write counters and suppress auto-increment.
    // CSRRS/CSRRC with source=0 are "reads" and must NOT suppress auto-increment.

    logic is_csr_explicit_write_op;

    always_comb begin
        case (instruction_in.op)
            CSRRW, CSRRWI: is_csr_explicit_write_op = 1'b1;
            default:       is_csr_explicit_write_op = 1'b0;
        endcase
    end

    logic csr_writes_mcycle_lo, csr_writes_mcycle_hi;
    logic csr_writes_minstret_lo, csr_writes_minstret_hi;

    assign csr_writes_mcycle_lo   = is_valid && is_csr_explicit_write_op && (instruction_in.csr == csr::MCYCLE);
    assign csr_writes_mcycle_hi   = is_valid && is_csr_explicit_write_op && (instruction_in.csr == csr::MCYCLEH);
    assign csr_writes_minstret_lo = is_valid && is_csr_explicit_write_op && (instruction_in.csr == csr::MINSTRET);
    assign csr_writes_minstret_hi = is_valid && is_csr_explicit_write_op && (instruction_in.csr == csr::MINSTRETH);

    // =========================================================================
    // Part 12: CSR Register Updates (SEQUENTIAL — posedge clk)
    // =========================================================================
    // When int_jump_reg=1, the instruction is stale (from before the interrupt
    // flush). All state-modifying effects are suppressed: CSR writes, MRET,
    // trap handling, and minstret increment. MCYCLE always counts.

    // MCYCLE counts every cycle including reset — use initial for startup value
    initial begin
        mcycle   = 64'b0;
        minstret = 64'b0;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus_mpie <= 1'b0;
            mstatus_mie  <= 1'b0;
            mtvec        <= 32'b0;
            mie_meie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mip_meip_reg <= 1'b0;
            mip_mtip_reg <= 1'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
            mscratch     <= 32'b0;
            minstret     <= 64'b0;

            // MCYCLE always counts, even during reset
            mcycle <= mcycle + 64'd1;
        end else begin
            // ---- Latch MIP from live interrupt inputs (always) ----
            mip_meip_reg <= external_interrupt_in;
            mip_mtip_reg <= timer_interrupt_in;

            // ---- MCYCLE: auto-increment unless written ----
            if (!int_jump_reg && csr_writes_mcycle_lo)
                mcycle <= {mcycle[63:32], csr_write_val};
            else if (!int_jump_reg && csr_writes_mcycle_hi)
                mcycle <= {csr_write_val, mcycle[31:0]};
            else
                mcycle <= mcycle + 64'd1;

            // ---- MINSTRET: increment on valid instruction unless written ----
            if (!int_jump_reg && csr_writes_minstret_lo)
                minstret <= {minstret[63:32], csr_write_val};
            else if (!int_jump_reg && csr_writes_minstret_hi)
                minstret <= {csr_write_val, minstret[31:0]};
            else if (is_valid)
                minstret <= minstret + 64'd1;  // NOT gated: REF counts stale instructions too

            // ---- CSR writes by instruction (suppressed during stale cycle) ----
            if (!int_jump_reg && is_valid && is_csr_op) begin
                case (instruction_in.csr)
                    csr::MSTATUS: begin
                        mstatus_mie  <= csr_write_val[3];
                        mstatus_mpie <= csr_write_val[7];
                    end
                    csr::MTVEC:    mtvec    <= {csr_write_val[31:2], 2'b00};
                    csr::MIE: begin
                        mie_meie <= csr_write_val[11];
                        mie_mtie <= csr_write_val[7];
                    end
                    csr::MEPC:     mepc     <= {csr_write_val[31:2], 2'b00};
                    csr::MCAUSE:   mcause   <= csr_write_val;
                    csr::MSCRATCH: mscratch <= csr_write_val;
                    default: ;
                endcase
            end

            // ---- MRET effects on MSTATUS (suppressed during stale cycle) ----
            if (!int_jump_reg && is_mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end

            // ---- Trap effects (highest priority, suppressed during stale) ----
            if (!int_jump_reg && is_trap) begin
                mcause       <= trap_cause;
                mepc         <= {trap_mepc[31:2], 2'b00};
                mstatus_mpie <= mie_eff;
                mstatus_mie  <= 1'b0;
            end
        end
    end

endmodule
