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

    // Pipeline control — forwards direction (Fetch → Decode → Execute)
    input  pipeline_status::forwards_t  status_forwards_in,   // from Fetch
    output pipeline_status::forwards_t  status_forwards_out,  // to Execute

    // Pipeline control — backwards direction (Execute → Decode → Fetch)
    input  pipeline_status::backwards_t status_backwards_in,   // from Execute
    output pipeline_status::backwards_t status_backwards_out,  // to Fetch

    // Jump address passthrough (Execute → Decode → Fetch)
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out
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

    // Helper function: does a forwarding signal match a given register address?
    // Match only if: forwarding address equals register address AND address != 0
    // (address=0 means "no forwarding" — x0 is always 0 anyway)
    function automatic logic fwd_match(forwarding::t fwd, logic [4:0] reg_addr);
        return (fwd.address == reg_addr) && (reg_addr != 5'b0);
    endfunction

    // Detect load-use hazard: Execute has our register but data isn't ready yet.
    // Example: lw t1, 0(t2) followed immediately by add t3, t1, ...
    // Execute sets data_valid=0 (load result comes from Memory next cycle).
    logic load_use_hazard;
    assign load_use_hazard = (
        (fwd_match(exe_forwarding_in, decoded.rs1_address) && !exe_forwarding_in.data_valid) ||
        (fwd_match(exe_forwarding_in, decoded.rs2_address) && !exe_forwarding_in.data_valid)
    ) && (status_forwards_in == VALID);

    // Detect CSR-use hazard: Memory stage has our register but data still isn't ready.
    // Example: csrr t1, mscratch followed by addi t2, t1, ...
    // CSR reads resolve in Writeback (not Memory), so Memory also has data_valid=0.
    // A regular lw in Memory has data_valid=1, so it never triggers this.
    //
    // IMPORTANT: Only stall if Execute does NOT already provide a valid result for
    // the same register. If exe has data_valid=1 for the same register (exe is newer),
    // we use exe's value — no stall needed.
    logic csr_use_hazard;
    assign csr_use_hazard = (
        (fwd_match(mem_forwarding_in, decoded.rs1_address) && !mem_forwarding_in.data_valid
            && !(fwd_match(exe_forwarding_in, decoded.rs1_address) && exe_forwarding_in.data_valid)) ||
        (fwd_match(mem_forwarding_in, decoded.rs2_address) && !mem_forwarding_in.data_valid
            && !(fwd_match(exe_forwarding_in, decoded.rs2_address) && exe_forwarding_in.data_valid))
    ) && (status_forwards_in == VALID);

    // Combined: any hazard that requires inserting a pipeline bubble
    logic pipeline_hazard;
    assign pipeline_hazard = load_use_hazard || csr_use_hazard;

    // Select rs1 value: Execute > Memory > Writeback > Register File
    logic [31:0] rs1_data;
    always_comb begin
        if (fwd_match(exe_forwarding_in, decoded.rs1_address) && exe_forwarding_in.data_valid)
            rs1_data = exe_forwarding_in.data;
        else if (fwd_match(mem_forwarding_in, decoded.rs1_address) && mem_forwarding_in.data_valid)
            rs1_data = mem_forwarding_in.data;
        else if (fwd_match(wb_forwarding_in, decoded.rs1_address) && wb_forwarding_in.data_valid)
            rs1_data = wb_forwarding_in.data;
        else
            rs1_data = rf_rs1_data; // use register file value
    end

    // Select rs2 value: same priority as rs1
    logic [31:0] rs2_data;
    always_comb begin
        if (fwd_match(exe_forwarding_in, decoded.rs2_address) && exe_forwarding_in.data_valid)
            rs2_data = exe_forwarding_in.data;
        else if (fwd_match(mem_forwarding_in, decoded.rs2_address) && mem_forwarding_in.data_valid)
            rs2_data = mem_forwarding_in.data;
        else if (fwd_match(wb_forwarding_in, decoded.rs2_address) && wb_forwarding_in.data_valid)
            rs2_data = wb_forwarding_in.data;
        else
            rs2_data = rf_rs2_data;
    end

    // =========================================================================
    // Part 4a: Backwards status (to Fetch) — COMBINATIONAL, no clock delay
    // =========================================================================
    // The PDF says backwards status must be purely combinational — it must
    // propagate without any clock delay so Fetch can react in the same cycle.
    //
    // Rules (later stage takes priority — PDF Section 6.1.2):
    //   - If Execute says JUMP  → pass JUMP to Fetch
    //   - If Execute says STALL → pass STALL to Fetch
    //   - If load-use hazard    → send STALL to Fetch (we're inserting a bubble)
    //   - Otherwise             → send READY to Fetch

    always_comb begin
        jump_address_backwards_out = jump_address_backwards_in; // always pass through

        if (status_backwards_in == JUMP)
            status_backwards_out = JUMP;
        else if (status_backwards_in == STALL)
            status_backwards_out = STALL;
        else if (pipeline_hazard)
            status_backwards_out = STALL; // hold Fetch, we need one more cycle
        else
            status_backwards_out = READY;
    end

    // =========================================================================
    // Part 4b: Output registers (to Execute) — SEQUENTIAL, updated on clock edge
    // =========================================================================
    // These outputs are what Execute reads. They are registered — they hold
    // their value until explicitly updated.
    //
    // Rules:
    //   - rst            → output NOP/BUBBLE, reset everything
    //   - STALL from Exe → hold all outputs (Execute is still busy)
    //   - JUMP from Exe  → output BUBBLE (throw away current instruction)
    //   - load-use stall → output BUBBLE (don't give Execute the stalled instruction)
    //   - Normal (READY) → register decoded instruction, forwarded rs1/rs2, PC, status

    always_ff @(posedge clk) begin
        if (rst) begin
            rs1_data_reg_out       <= 32'b0;
            rs2_data_reg_out       <= 32'b0;
            program_counter_reg_out <= 32'b0;
            instruction_reg_out    <= instruction::NOP;
            status_forwards_out    <= BUBBLE;

        end else if (status_backwards_in == STALL) begin
            // Execute is stalled — hold everything, do not update outputs
            // (empty block — registers hold their value automatically)

        end else if (status_backwards_in == JUMP || pipeline_hazard) begin
            // JUMP: throw away whatever instruction we have, it's on the wrong path
            // load-use: insert a bubble so Execute gets a NOP while we wait
            status_forwards_out    <= BUBBLE;
            instruction_reg_out    <= instruction::NOP;
            // (rs1/rs2/PC don't matter when status is BUBBLE — Execute ignores them)

        end else begin
            // Normal operation: register everything for Execute
            rs1_data_reg_out        <= rs1_data;
            rs2_data_reg_out        <= rs2_data;
            program_counter_reg_out <= program_counter_in;
            instruction_reg_out     <= decoded;

            // Determine the outgoing status:
            //   - FETCH errors (FETCH_FAULT, FETCH_MISALIGNED) propagate as-is
            //   - BUBBLE from Fetch propagates as-is
            //   - VALID from Fetch: check the decoded instruction
            //       ILLEGAL op  → ILLEGAL_INSTRUCTION (catches bad opcode, funct, or CSR addr)
            //       ECALL       → ECALL  (Writeback handles the trap)
            //       EBREAK      → EBREAK (Writeback handles the trap)
            //       anything else → VALID
            if (status_forwards_in != VALID)
                status_forwards_out <= status_forwards_in;
            else
                case (decoded.op)
                    op::ILLEGAL: status_forwards_out <= ILLEGAL_INSTRUCTION;
                    op::ECALL:   status_forwards_out <= pipeline_status::ECALL;
                    op::EBREAK:  status_forwards_out <= pipeline_status::EBREAK;
                    default:     status_forwards_out <= VALID;
                endcase
        end
    end

endmodule
