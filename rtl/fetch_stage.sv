/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: fetch_stage.sv
 */



module fetch_stage (
    input logic clk,
    input logic rst,

    // Memory interface
    wishbone_interface.master wb,

    //  Output data
    output logic [31:0] instruction_reg_out,
    output logic [31:0] program_counter_reg_out,

    // Pipeline control
    output pipeline_status::forwards_t  status_forwards_out,
    input  pipeline_status::backwards_t status_backwards_in,
    input  logic [31:0] jump_address_backwards_in
);

    // -------------------------------------------------------------------------
    // Package imports — go INSIDE the module, not above it.
    // 'import' is not a file path. It makes names from a package usable without
    // the package:: prefix. e.g. RESET_ADDRESS instead of constants::RESET_ADDRESS
    // -------------------------------------------------------------------------
    import constants::*;          // gives us: RESET_ADDRESS, NOP
    import pipeline_status::*;    // gives us: VALID, BUBBLE, FETCH_FAULT, READY, STALL, JUMP

    // -------------------------------------------------------------------------
    // Program Counter register
    // The PC is the BYTE address of the instruction we are currently fetching.
    // It lives in a register — it only changes on a rising clock edge.
    // -------------------------------------------------------------------------
    logic [31:0] pc;

    // =========================================================================
    // PART 1: Wishbone bus drive signals (combinational — no clock needed)
    // =========================================================================
    // The wishbone_interface.master port is a named bundle of wires.
    // As MASTER we DRIVE:  cyc, stb, adr, sel, we, dat_mosi
    // As MASTER we READ:   ack, err, dat_miso
    //
    // These are 'assign' statements — they update every time their inputs change,
    // with no clock required. Think of them as always-connected wires.

    // we = Write Enable. 0 = READ. We only ever read instructions here.
    assign wb.we = 1'b0;

    // sel = byte select. Which of the 4 bytes in the word do we want?
    // 4'b1111 = all 4 bytes (we always want the full 32-bit instruction).
    assign wb.sel = 4'b1111;

    // dat_mosi = data we send TO the slave. Unused for reads, so drive zeros.
    assign wb.dat_mosi = '0;

    // adr = WORD address. RAM indexes by word (32 bits = 4 bytes), not by byte.
    // The PC is a byte address, so we divide by 4 by shifting right 2 bits.
    //   Example: PC = 0x40000  →  adr = 0x40000 >> 2 = 0x10000
    assign wb.adr = pc >> 2;

    // cyc = "I am currently in a Wishbone bus cycle"
    // We ALWAYS keep cyc=1. During STALL, the PC doesn't change, so we keep
    // requesting the SAME address from RAM. The async RAM holds the data stable
    // as long as cyc/stb are high — we just choose not to capture it (outputs
    // hold their value in the STALL branch of always_ff below).
    // Dropping cyc during STALL would be wrong: it would terminate an in-progress
    // wishbone transaction before the data has been consumed.
    assign wb.cyc = 1'b1;

    // stb = "this specific cycle has a valid request on the bus"
    // Tied to cyc — we always have a request active.
    assign wb.stb = 1'b1;

    // =========================================================================
    // PART 2: PC update (sequential — runs on every rising clock edge)
    // =========================================================================
    // status_backwards_in comes FROM Decode and tells us what to do next.
    // It is COMBINATIONAL (no register delay inside Decode) so we can read it
    // this cycle to decide what PC should be on the NEXT clock edge.
    always_ff @(posedge clk) begin
        if (rst) begin
            // On reset, load the address of the very first instruction in RAM.
            // RESET_ADDRESS = MEMORY_START << 2 = 0x40000  (from constants package)
            pc <= RESET_ADDRESS;

        end else begin
            case (status_backwards_in)

                // JUMP: a branch/jump instruction resolved in Execute or Writeback.
                // Decode passes the target address back to us.
                // → Load the jump target so next cycle we fetch from there.
                JUMP: pc <= jump_address_backwards_in;

                // STALL: Decode is busy and cannot accept a new instruction.
                // → Hold the PC exactly as-is. Do not advance.
                // (Assigning pc <= pc is explicit but redundant — registers hold
                //  their value automatically if not assigned in a clocked block.)
                STALL: pc <= pc;

                // READY: Decode accepted the last instruction, wants a new one.
                // → If the RAM acknowledged (ack=1): instruction received, move to next.
                // → If the RAM hasn't responded yet (ack=0): wait, hold the PC.
                // With the ASYNC RAM used here, ack always arrives the same cycle
                // that cyc/stb are asserted, so we almost always take pc + 4.
                READY: pc <= wb.ack ? pc + 4 : pc;

                // Catch-all for safety (shouldn't be reachable with a 2-bit enum).
                default: pc <= pc;

            endcase
        end
    end

    // =========================================================================
    // PART 3: Output register update (sequential — runs on every rising clock edge)
    // =========================================================================
    // These three outputs are what Decode reads. They are REGISTERED — they hold
    // their value until we explicitly update them.
    //
    // status_forwards_out tells Decode what to do with the data we are giving it:
    //   VALID        = "here is a real instruction, please process it"
    //   BUBBLE       = "ignore everything on the output, nothing valid here"
    //   FETCH_FAULT  = "I tried to fetch but the bus returned an error"
    always_ff @(posedge clk) begin
        if (rst) begin
            // Nothing has been fetched yet — tell Decode to ignore the outputs.
            instruction_reg_out     <= NOP;           // safe dummy value
            program_counter_reg_out <= RESET_ADDRESS;
            status_forwards_out     <= BUBBLE;

        end else begin
            case (status_backwards_in)

                // STALL: Decode is still working on the instruction we already gave it.
                // → Do absolutely nothing. Leave all three output registers unchanged.
                // An empty begin/end is valid — registers hold their value by default.
                STALL: begin
                    // intentionally empty — hold outputs
                end

                // JUMP: the instruction currently on our output belongs to the OLD
                // (wrong) path. Decode must throw it away.
                // → Output BUBBLE so Decode ignores this cycle's data.
                // The PC has already been set to jump_address above, so next cycle
                // we will fetch the correct instruction and output VALID.
                JUMP: begin
                    status_forwards_out <= BUBBLE;
                end

                // READY: Decode wants a new instruction and the bus is active.
                READY: begin
                    if (wb.ack) begin
                        // The RAM responded successfully.
                        // dat_miso holds the full 32-bit instruction word.
                        // We also pass the PC of THIS instruction (before the +4)
                        // so later stages know where the instruction came from.
                        instruction_reg_out     <= wb.dat_miso;
                        program_counter_reg_out <= pc;
                        status_forwards_out     <= VALID;

                    end else if (wb.err) begin
                        // The RAM signalled an error (e.g. address out of range).
                        // We cannot provide a valid instruction.
                        // FETCH_FAULT propagates forward so the exception handler
                        // can see which address caused the problem.
                        program_counter_reg_out <= pc;
                        status_forwards_out     <= FETCH_FAULT;

                    end else begin
                        // No ack and no err yet — the RAM is taking more than one
                        // cycle to respond (synchronous slave case).
                        // Insert a BUBBLE to hold the pipeline until data arrives.
                        // With the async RAM this branch is never taken in practice,
                        // but we handle it for correctness.
                        status_forwards_out <= BUBBLE;
                    end
                end

                // Safety default.
                default: status_forwards_out <= BUBBLE;

            endcase
        end
    end

endmodule
