/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: decode_stage.sv
 */

// =============================================================================
// WHAT THIS MODULE DOES
// =============================================================================
// The Decode Stage sits between Fetch and Execute. It has four jobs:
//
//  1. DECODE: Run the raw 32-bit instruction through instruction_decoder to get
//             a structured instruction::t (op, rd, rs1, rs2, imm, csr).
//
//  2. READ REGISTERS: Look up rs1 and rs2 values from the register file.
//
//  3. FORWARDING UNIT: A later stage may have already computed a newer value
//     for rs1 or rs2 that hasn't been written to the register file yet.
//     In that case, use the forwarded value instead of the register file value.
//     Priority: Execute > Memory > Writeback (most recent wins).
//     Special case: if Execute is forwarding but data_valid=0, the data isn't
//     ready yet (load-use hazard) — we must STALL for one cycle.
//
//  4. PIPELINE CONTROL: Handle STALL/JUMP/BUBBLE signals in both directions,
//     and register all outputs on the clock edge.
//
// REGISTER FILE WRITE PORT:
//   The Writeback stage sends its result as wb_forwarding_in. We connect the
//   register file write port directly to that signal — Writeback and Decode
//   share the register file, but only Decode instantiates it.
// =============================================================================

module decode_stage (
    input logic clk,
    input logic rst,

    // Data inputs from Fetch Stage
    input logic [31:0]  instruction_in,
    input logic [31:0]  program_counter_in,

    // Forwarding inputs from later stages
    // Each carries: address (which register), data (the value), data_valid (is it ready?)
    input forwarding::t exe_forwarding_in,  // from Execute  — highest priority
    input forwarding::t mem_forwarding_in,  // from Memory
    input forwarding::t wb_forwarding_in,   // from Writeback — lowest priority

    // Registered outputs to Execute Stage
    output logic [31:0]   rs1_data_reg_out,       // rs1 value (possibly forwarded)
    output logic [31:0]   rs2_data_reg_out,        // rs2 value (possibly forwarded)
    output logic [31:0]   program_counter_reg_out,
    output instruction::t instruction_reg_out,
    output bpredict::bp_data_t bp_prediction_reg_out,  // branch prediction for this instruction

    // Pipeline control — forwards direction (Fetch → Decode → Execute)
    input  pipeline_status::forwards_t  status_forwards_in,   // from Fetch
    output pipeline_status::forwards_t  status_forwards_out,  // to Execute

    // Pipeline control — backwards direction (Execute → Decode → Fetch)
    input  pipeline_status::backwards_t status_backwards_in,   // from Execute
    output pipeline_status::backwards_t status_backwards_out,  // to Fetch

    // Jump address passthrough (Execute → Decode → Fetch)
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out,

    // Branch prediction passthrough (Fetch → Decode → Execute)
    input  bpredict::bp_data_t bp_prediction_in
);

    import pipeline_status::*;
    import instruction::*;

    // =========================================================================
    // Part 1: Instantiate instruction_decoder
    // =========================================================================
    // This is a pure combinational module — it has no clock.
    // It takes instruction_in and produces a decoded instruction struct.
    // We use a local wire to hold its output before registering it.

    instruction::t decoded; // combinational output of the decoder

    instruction_decoder decoder (
        .instruction_in  (instruction_in),
        .instruction_out (decoded)
    );

    // In RISC-V, rs1 and rs2 are always at the same bit positions regardless of format.
    // Read them directly from instruction_in to avoid any sub-module update delay.
    logic [4:0] rs1_addr; assign rs1_addr = instruction_in[19:15];
    logic [4:0] rs2_addr; assign rs2_addr = instruction_in[24:20];

    // =========================================================================
    // Part 2: Instantiate register_file
    // =========================================================================
    // Read ports are combinational (async) — we get data immediately.
    // Write port is clocked — Writeback writes here via wb_forwarding_in.
    //
    // Why connect write port to wb_forwarding?
    //   Writeback is the stage that knows the final result to write to a register.
    //   It sends that result as wb_forwarding_in. We use the same signal for:
    //   (a) writing to the register file (permanent storage)
    //   (b) forwarding to the current instruction (if rs1/rs2 match)

    logic [31:0] rf_rs1_data; // register file output for rs1 (before forwarding)
    logic [31:0] rf_rs2_data; // register file output for rs2 (before forwarding)

    register_file regfile (
        .clk           (clk),
        .rst           (rst),
        // Read ports: feed in decoded register addresses, get data back
        .read_address1 (decoded.rs1_address),
        .read_data1    (rf_rs1_data),
        .read_address2 (decoded.rs2_address),
        .read_data2    (rf_rs2_data),
        // Write port: connected to Writeback's forwarding output
        .write_address (wb_forwarding_in.address),
        .write_data    (wb_forwarding_in.data),
        .write_enable  (wb_forwarding_in.data_valid)
    );

    // =========================================================================
    // Part 3: Forwarding Unit
    // =========================================================================
    // Checks if any later stage has a more up-to-date value for rs1 or rs2.
    //
    // HOW FORWARDING WORKS:
    //   Each stage outputs a forwarding::t struct with:
    //     .address    — which register does this result go to? (0 = no forwarding)
    //     .data       — the result value
    //     .data_valid — is the data actually ready this cycle?
    //
    //   We check Execute first (most recent), then Memory, then Writeback.
    //   If a match is found AND data is valid → use forwarded data.
    //   If address = 0 → ignore (x0 is always 0, no forwarding needed).
    //
    // LOAD-USE HAZARD:
    //   If Execute is forwarding for our rs1 or rs2 but data_valid=0, the load
    //   result won't be available until the Memory stage next cycle.
    //   We must insert a bubble (STALL for one cycle).

    // Hazard detection and forwarding selection — all in one always_comb block.
    // Inlined to avoid Verilator sensitivity issues with function calls on packed structs.
    //
    // LOAD-USE HAZARD: Execute has data_valid=0 for rs1 or rs2 → stall 1 cycle.
    // CSR-USE HAZARD:  Memory has data_valid=0 for rs1 or rs2 AND Execute doesn't
    //                  already provide a valid (newer) result for the same register.
    // FORWARDING: Execute > Memory > Writeback > Register File (most recent wins).

    logic load_use_hazard;
    logic csr_use_hazard;
    logic wb_use_hazard;
    logic pipeline_hazard;
    logic [31:0] rs1_data;
    logic [31:0] rs2_data;

    // Internal register for status_forwards_out.
    // status_forwards_out is driven combinationally but behaves like a register:
    //   - immediately outputs BUBBLE on JUMP or pipeline_hazard (hazard override)
    //   - returns the last registered value for all other cases (STALL hold + normal)
    // This matches the reference's combo_update behaviour.
    pipeline_status::forwards_t status_forwards_out_reg;

    // =========================================================================
    // Part 3+4a: Hazard detection, forwarding, backwards+forwards status — comb.
    // =========================================================================
    always_comb begin
        // --- Load-use hazard: Execute has data_valid=0 for rs1 or rs2 ---
        load_use_hazard =
            (((exe_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0) && !exe_forwarding_in.data_valid) ||
             ((exe_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0) && !exe_forwarding_in.data_valid))
            && (status_forwards_in == VALID);

        // --- CSR-use hazard: Memory has data_valid=0, and Execute doesn't override ---
        csr_use_hazard =
            ((((mem_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0) && !mem_forwarding_in.data_valid)
                && !((exe_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0) && exe_forwarding_in.data_valid)) ||
             (((mem_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0) && !mem_forwarding_in.data_valid)
                && !((exe_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0) && exe_forwarding_in.data_valid)))
            && (status_forwards_in == VALID);

        // --- WB-use hazard: Writeback has data_valid=0, and neither Execute nor Memory overrides ---
        wb_use_hazard =
            ((((wb_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0) && !wb_forwarding_in.data_valid)
                && !((exe_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0))
                && !((mem_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0))) ||
             (((wb_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0) && !wb_forwarding_in.data_valid)
                && !((exe_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0))
                && !((mem_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0))))
            && (status_forwards_in == VALID);

        pipeline_hazard = load_use_hazard || csr_use_hazard || wb_use_hazard;

        // --- rs1 forwarding: Execute > Memory > Writeback > Register File ---
        // Execute and Memory are checked WITHOUT a data_valid guard: they always
        // hold the most-recent result for that register.  data_valid=0 means the
        // value isn't ready yet (hazard detected above → Execute gets BUBBLE and
        // ignores the stale value); we still record it here for consistency with
        // the reference implementation.
        if ((exe_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0))
            rs1_data = exe_forwarding_in.data;
        else if ((mem_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0))
            rs1_data = mem_forwarding_in.data;
        else if ((wb_forwarding_in.address == rs1_addr) && (rs1_addr != 5'b0))
            rs1_data = wb_forwarding_in.data;
        else
            rs1_data = rf_rs1_data;

        // --- rs2 forwarding: same priority ---
        if ((exe_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0))
            rs2_data = exe_forwarding_in.data;
        else if ((mem_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0))
            rs2_data = mem_forwarding_in.data;
        else if ((wb_forwarding_in.address == rs2_addr) && (rs2_addr != 5'b0))
            rs2_data = wb_forwarding_in.data;
        else
            rs2_data = rf_rs2_data;

        // --- Backwards status: pass through or override with STALL for hazard ---
        // Do NOT propagate STALL backwards when there is no real instruction in
        // Decode (status_forwards_in == BUBBLE) — Fetch can keep running.
        jump_address_backwards_out = jump_address_backwards_in;
        if (status_backwards_in == JUMP)
            status_backwards_out = JUMP;
        else if (status_backwards_in == STALL && status_forwards_in != BUBBLE)
            status_backwards_out = STALL;
        else if (pipeline_hazard)
            status_backwards_out = STALL;
        else
            status_backwards_out = READY;

        // --- Forwards status: purely registered (no combinational override) ---
        // status_forwards_out always reflects status_forwards_out_reg, which is
        // updated on the clock edge (BUBBLE on reset/hazard/JUMP, VALID otherwise).
        // Execute samples this at the clock edge, so a same-cycle preview is not
        // needed — this matches the reference implementation.
        status_forwards_out = status_forwards_out_reg;
    end

    // =========================================================================
    // Part 4b: Output registers (to Execute) — SEQUENTIAL, updated on clock edge
    // =========================================================================
    // Rules:
    //   - rst            → output NOP/BUBBLE, reset everything
    //   - STALL from Exe → hold all outputs (registers retain value)
    //   - JUMP from Exe  → output BUBBLE (throw away current instruction)
    //   - load-use stall → output BUBBLE (don't give Execute the stalled instruction)
    //   - Normal (READY) → register decoded instruction, forwarded rs1/rs2, PC, status

    always_ff @(posedge clk) begin
        if (rst) begin
            rs1_data_reg_out        <= 32'b0;
            rs2_data_reg_out        <= 32'b0;
            program_counter_reg_out <= 32'b0;
            instruction_reg_out     <= instruction::NOP;
            bp_prediction_reg_out   <= '0;
            status_forwards_out_reg <= BUBBLE;

        end else begin
            if (status_backwards_in == STALL) begin
                // Execute is stalled — hold all outputs (registers retain value)

            end else if (status_backwards_in == JUMP || pipeline_hazard) begin
                // JUMP: throw away current instruction; load-use: insert bubble.
                rs1_data_reg_out        <= rs1_data;
                rs2_data_reg_out        <= rs2_data;
                program_counter_reg_out <= program_counter_in;
                instruction_reg_out     <= instruction::NOP;
                bp_prediction_reg_out   <= '0;  // no prediction for flushed instruction
                status_forwards_out_reg <= BUBBLE;

            end else begin
                // Normal operation: register everything for Execute
                rs1_data_reg_out        <= rs1_data;
                rs2_data_reg_out        <= rs2_data;
                program_counter_reg_out <= program_counter_in;
                instruction_reg_out     <= decoded;
                bp_prediction_reg_out   <= bp_prediction_in;
                if (status_forwards_in != VALID)
                    status_forwards_out_reg <= status_forwards_in;
                else
                    case (decoded.op)
                        op::ILLEGAL: status_forwards_out_reg <= ILLEGAL_INSTRUCTION;
                        op::ECALL:   status_forwards_out_reg <= pipeline_status::ECALL;
                        op::EBREAK:  status_forwards_out_reg <= pipeline_status::EBREAK;
                        default:     status_forwards_out_reg <= VALID;
                    endcase
            end
        end
    end

endmodule
