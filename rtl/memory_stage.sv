/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: memory_stage.sv
 */

// =============================================================================
// WHAT THIS MODULE DOES
// =============================================================================
// The Memory Stage sits between Execute and Writeback. It has five jobs:
//
//  1. LOAD: For LB/LH/LW/LBU/LHU, read data from memory via the Wishbone
//     bus. The memory address comes from rd_data_in (Execute's ALU result:
//     rs1 + immediate). After reading, sign-extend or zero-extend the data
//     based on the instruction type.
//
//  2. STORE: For SB/SH/SW, write data to memory via Wishbone. The address
//     comes from rd_data_in, the data from source_data_in (rs2 from Execute).
//     Place the data on the correct byte lanes.
//
//  3. ALIGNMENT CHECK: Verify that load/store addresses are naturally aligned.
//     LW/SW need addr[1:0]==00, LH/LHU/SH need addr[0]==0.
//     Misalignment → LOAD_MISALIGNED or STORE_MISALIGNED (no bus transaction).
//
//  4. FORWARDING: Expose the rd result so Decode can bypass the register file.
//     For loads, data_valid=1 (the loaded data is now available).
//     For CSR instructions, data_valid=0 (CSR value comes from Writeback).
//
//  5. PIPELINE CONTROL: Stall the pipeline backward while waiting for a
//     Wishbone response. Pass through JUMP from Writeback. Register all
//     outputs on the clock edge.
//
// KEY: This stage stalls until the Wishbone transaction completes.
//      Reads and writes may have side effects and cannot be aborted.
// =============================================================================

module memory_stage (
    input logic clk,
    input logic rst,

    // Memory interface
    wishbone_interface.master wb,

    // Inputs
    input logic [31:0]   source_data_in,
    input logic [31:0]   rd_data_in,
    input instruction::t instruction_in,
    input logic [31:0]   program_counter_in,
    input logic [31:0]   next_program_counter_in,

    // Outputs
    output logic [31:0]   source_data_reg_out,
    output logic [31:0]   rd_data_reg_out,
    output instruction::t instruction_reg_out,
    output logic [31:0]   program_counter_reg_out,
    output logic [31:0]   next_program_counter_reg_out,
    output forwarding::t  forwarding_out,

    // Pipeline control
    input  pipeline_status::forwards_t  status_forwards_in,
    output pipeline_status::forwards_t  status_forwards_out,
    input  pipeline_status::backwards_t status_backwards_in,
    output pipeline_status::backwards_t status_backwards_out,
    input  logic [31:0] jump_address_backwards_in,
    output logic [31:0] jump_address_backwards_out
);

    import pipeline_status::*;
    import op::*;

    // =========================================================================
    // Part 1: Classify instruction
    // =========================================================================
    logic is_load, is_store;

    always_comb begin
        case (instruction_in.op)
            LB, LH, LW, LBU, LHU: is_load = 1'b1;
            default:                is_load = 1'b0;
        endcase
        case (instruction_in.op)
            SB, SH, SW: is_store = 1'b1;
            default:     is_store = 1'b0;
        endcase
    end

    // Memory address = rd_data_in (ALU result from Execute: rs1 + immediate)
    logic [31:0] mem_addr;
    assign mem_addr = rd_data_in;

    // =========================================================================
    // Part 2: Alignment checking
    // =========================================================================
    // LW/SW: address must be 4-byte aligned (addr[1:0] == 00)
    // LH/LHU/SH: address must be 2-byte aligned (addr[0] == 0)
    // LB/LBU/SB: no alignment requirement
    logic misaligned;

    always_comb begin
        case (instruction_in.op)
            LW, SW:       misaligned = (mem_addr[1:0] != 2'b00);
            LH, LHU, SH: misaligned = (mem_addr[0] != 1'b0);
            default:      misaligned = 1'b0;
        endcase
    end

    // =========================================================================
    // Part 3: Byte select based on size and address alignment
    // =========================================================================
    // sel[i] = 1 means byte i is involved in this transaction.
    //   Word:  sel = 1111 (all 4 bytes)
    //   Half:  sel = 0011 (low half) or 1100 (high half)
    //   Byte:  sel = 0001 / 0010 / 0100 / 1000 depending on addr[1:0]
    logic [3:0] byte_sel;

    always_comb begin
        case (instruction_in.op)
            LW, SW: byte_sel = 4'b1111;

            LH, LHU, SH: begin
                case (mem_addr[1])
                    1'b0: byte_sel = 4'b0011;
                    1'b1: byte_sel = 4'b1100;
                endcase
            end

            LB, LBU, SB: begin
                case (mem_addr[1:0])
                    2'b00: byte_sel = 4'b0001;
                    2'b01: byte_sel = 4'b0010;
                    2'b10: byte_sel = 4'b0100;
                    2'b11: byte_sel = 4'b1000;
                endcase
            end

            default: byte_sel = 4'b0000;
        endcase
    end

    // =========================================================================
    // Part 4: Store data placement on correct byte lanes
    // =========================================================================
    // source_data_in holds rs2 (the data to store). We shift it to the correct
    // position within the 32-bit word based on the address and store size.
    logic [31:0] store_data;

    always_comb begin
        case (instruction_in.op)
            SW: store_data = source_data_in;

            SH: begin
                case (mem_addr[1])
                    1'b0: store_data = {16'b0, source_data_in[15:0]};
                    1'b1: store_data = {source_data_in[15:0], 16'b0};
                endcase
            end

            SB: begin
                case (mem_addr[1:0])
                    2'b00: store_data = {24'b0, source_data_in[7:0]};
                    2'b01: store_data = {16'b0, source_data_in[7:0], 8'b0};
                    2'b10: store_data = {8'b0, source_data_in[7:0], 16'b0};
                    2'b11: store_data = {source_data_in[7:0], 24'b0};
                endcase
            end

            default: store_data = 32'b0;
        endcase
    end

    // =========================================================================
    // Part 5: Wishbone bus control
    // =========================================================================
    // The bus is active when:
    //   - The instruction is a load or store
    //   - The forward status is VALID (not BUBBLE/exception)
    //   - The address is aligned (misaligned → error, no bus transaction)
    //   - WB is not sending JUMP (which flushes this instruction)
    //   - OR we have a pending multi-cycle transaction that hasn't completed
    //
    // With the async RAM used in this project, ack arrives in the same cycle
    // as cyc/stb assertion. The wb_pending register handles synchronous slaves
    // where ack takes multiple cycles.

    logic wb_pending; // registered: 1 = ongoing bus transaction from a previous cycle

    // Should we start a NEW bus transaction this cycle?
    logic want_bus;
    assign want_bus = (is_load || is_store)
                      && (status_forwards_in == VALID)
                      && !misaligned
                      && !wb_pending;

    // The bus is active (driving cyc/stb) when starting a new transaction
    // OR continuing a pending one. Don't start new transactions if WB sent JUMP.
    logic bus_active;
    assign bus_active = (want_bus && (status_backwards_in != JUMP)) || wb_pending;

    // Bus completed this cycle (ack or err received)
    logic bus_done;
    assign bus_done = bus_active && (wb.ack || wb.err);

    // Memory stage needs to stall the pipeline (bus active but no response yet)
    logic mem_stall;
    assign mem_stall = bus_active && !wb.ack && !wb.err;

    // Drive Wishbone signals (combinational)
    assign wb.cyc      = bus_active;
    assign wb.stb      = bus_active;
    assign wb.adr      = mem_addr >> 2;   // byte address → word address
    assign wb.sel      = byte_sel;
    assign wb.we       = is_store & bus_active;
    assign wb.dat_mosi = store_data;

    // Track multi-cycle transactions (sequential)
    always_ff @(posedge clk) begin
        if (rst)
            wb_pending <= 1'b0;
        else if (bus_done)
            wb_pending <= 1'b0;
        else if (bus_active && !bus_done)
            wb_pending <= 1'b1;
    end

    // =========================================================================
    // Part 6: Load data extraction and sign extension
    // =========================================================================
    // After the bus responds (ack), extract the correct bytes from dat_miso
    // based on address alignment and instruction type.
    //   LB:  sign-extend byte
    //   LBU: zero-extend byte
    //   LH:  sign-extend halfword
    //   LHU: zero-extend halfword
    //   LW:  full word (no extension needed)
    logic [31:0] loaded_data;

    always_comb begin
        case (instruction_in.op)
            LW: loaded_data = wb.dat_miso;

            LH: begin
                case (mem_addr[1])
                    1'b0: loaded_data = {{16{wb.dat_miso[15]}}, wb.dat_miso[15:0]};
                    1'b1: loaded_data = {{16{wb.dat_miso[31]}}, wb.dat_miso[31:16]};
                endcase
            end

            LHU: begin
                case (mem_addr[1])
                    1'b0: loaded_data = {16'b0, wb.dat_miso[15:0]};
                    1'b1: loaded_data = {16'b0, wb.dat_miso[31:16]};
                endcase
            end

            LB: begin
                case (mem_addr[1:0])
                    2'b00: loaded_data = {{24{wb.dat_miso[7]}},  wb.dat_miso[7:0]};
                    2'b01: loaded_data = {{24{wb.dat_miso[15]}}, wb.dat_miso[15:8]};
                    2'b10: loaded_data = {{24{wb.dat_miso[23]}}, wb.dat_miso[23:16]};
                    2'b11: loaded_data = {{24{wb.dat_miso[31]}}, wb.dat_miso[31:24]};
                endcase
            end

            LBU: begin
                case (mem_addr[1:0])
                    2'b00: loaded_data = {24'b0, wb.dat_miso[7:0]};
                    2'b01: loaded_data = {24'b0, wb.dat_miso[15:8]};
                    2'b10: loaded_data = {24'b0, wb.dat_miso[23:16]};
                    2'b11: loaded_data = {24'b0, wb.dat_miso[31:24]};
                endcase
            end

            default: loaded_data = 32'b0;
        endcase
    end

    // =========================================================================
    // Part 7: Result selection
    // =========================================================================
    // rd_data_next: for loads, the extracted memory data; for everything else,
    //              passthrough of rd_data_in (ALU result from Execute).
    logic [31:0] rd_data_next;

    always_comb begin
        if (is_load)
            rd_data_next = loaded_data;  // always extract from dat_miso for loads
        else
            rd_data_next = rd_data_in;   // passthrough (ALU result from Execute)
    end

    // Determine the forwards status for this instruction
    pipeline_status::forwards_t status_next;

    always_comb begin
        if (status_forwards_in != VALID)
            status_next = status_forwards_in;    // pass through BUBBLE / prior exception
        else if (is_load && misaligned)
            status_next = LOAD_MISALIGNED;
        else if (is_store && misaligned)
            status_next = STORE_MISALIGNED;
        else if (is_load && bus_done && wb.err)
            status_next = LOAD_FAULT;
        else if (is_store && bus_done && wb.err)
            status_next = STORE_FAULT;
        else
            status_next = VALID;
    end

    // =========================================================================
    // Part 8: Pipeline control — backwards direction (combinational)
    // =========================================================================
    // Priority:
    //   1. Memory stall (waiting for bus) — freeze the entire pipeline
    //   2. JUMP from Writeback — pass through to Execute/Decode/Fetch
    //   3. Normal — pass through Writeback's status (always READY per spec)
    //
    // Note: Writeback never sends STALL (per guide: "This stage must never
    // stall to ensure no ongoing memory operations are interrupted").

    always_comb begin
        if (mem_stall) begin
            // Memory is busy with a Wishbone transaction — stall everything
            status_backwards_out       = STALL;
            jump_address_backwards_out = jump_address_backwards_in;

        end else if (status_backwards_in == JUMP) begin
            // Writeback issued JUMP — pass through to flush earlier stages
            status_backwards_out       = JUMP;
            jump_address_backwards_out = jump_address_backwards_in;

        end else begin
            // Normal operation — pipeline flows freely
            status_backwards_out       = status_backwards_in;
            jump_address_backwards_out = jump_address_backwards_in;
        end
    end

    // =========================================================================
    // Part 9: Forwarding output (combinational from current computation)
    // =========================================================================
    // Exposes the current instruction's rd result so Decode can forward it.
    //
    // data:       rd_data_next (loaded data for loads, ALU result for others)
    // address:    rd_address (suppressed for stores/branches/non-VALID)
    // data_valid: 1 for most instructions; 0 for CSR (result from Writeback)
    //             and non-VALID status (BUBBLE/exceptions).
    //             Loads have dv=1 here because the data IS now available.

    always_comb begin
        forwarding_out.data = rd_data_next;

        // Suppress forwarding address for non-VALID status and stores/branches
        if (status_forwards_in != VALID)
            forwarding_out.address = 5'b0;
        else case (instruction_in.op)
            SB, SH, SW,
            BEQ, BNE, BLT, BGE, BLTU, BGEU:
                forwarding_out.address = 5'b0;
            default:
                forwarding_out.address = instruction_in.rd_address;
        endcase

        // data_valid: 0 for CSR, non-VALID status, and misaligned exceptions
        // Use status_next which captures both incoming non-VALID and local errors
        if (status_next != VALID)
            forwarding_out.data_valid = 1'b0;
        else case (instruction_in.op)
            CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI:
                forwarding_out.data_valid = 1'b0;
            default:
                forwarding_out.data_valid = 1'b1;
        endcase
    end

    // =========================================================================
    // Part 10: Output registers — updated on clock edge
    // =========================================================================
    // Rules:
    //   rst             → NOP / BUBBLE / RESET_ADDRESS
    //   mem_stall       → hold all outputs (waiting for bus)
    //   STALL from WB   → hold (shouldn't happen per spec)
    //   JUMP from WB    → insert BUBBLE (instruction flushed)
    //   Normal          → register computed values

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_data_reg_out              <= 32'b0;
            source_data_reg_out          <= 32'b0;
            instruction_reg_out          <= instruction::NOP;
            program_counter_reg_out      <= constants::RESET_ADDRESS;
            next_program_counter_reg_out <= constants::RESET_ADDRESS;
            status_forwards_out          <= BUBBLE;

        end else if (mem_stall) begin
            // Waiting for Wishbone response — hold all registered outputs
            // BUT tell writeback this instruction isn't ready yet (BUBBLE)
            // so writeback doesn't try to commit an incomplete transaction
            status_forwards_out <= BUBBLE;

        end else if (status_backwards_in == STALL) begin
            // WB is stalling — hold all registered outputs

        end else if (status_backwards_in == JUMP) begin
            // WB issued JUMP — current instruction is from the wrong path.
            // Update data for register consistency; squash to BUBBLE.
            rd_data_reg_out              <= rd_data_next;
            source_data_reg_out          <= source_data_in;
            instruction_reg_out          <= instruction_in;
            program_counter_reg_out      <= program_counter_in;
            next_program_counter_reg_out <= next_program_counter_in;
            status_forwards_out          <= BUBBLE;

        end else begin
            // Normal operation — register computed values
            rd_data_reg_out              <= rd_data_next;
            source_data_reg_out          <= source_data_in;
            instruction_reg_out          <= instruction_in;
            program_counter_reg_out      <= program_counter_in;
            next_program_counter_reg_out <= next_program_counter_in;
            status_forwards_out          <= status_next;
        end
    end

endmodule
