/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: cpu.sv
 */



module cpu (
    input logic clk,
    input logic rst,

    wishbone_interface.master memory_fetch_port,
    wishbone_interface.master memory_mem_port,

    input logic external_interrupt_in,
    input logic timer_interrupt_in,

    // Live 64-bit mtime from the platform timer (wishbone_timer.mtime_out).
    // Only consumer is the Writeback stage, which exposes it as the Zicntr
    // TIME/TIMEH CSRs. Same clock domain as `clk`, so it is used directly.
    input logic [63:0] mtime_in
);

    // =========================================================================
    // Inter-stage data signals
    //   Naming: <signal>_<stage_abbreviation>
    //   _f = from Fetch, _d = from Decode, _e = from Execute, _m = from Memory
    // =========================================================================

    // Fetch → Decode
    logic [31:0]   inst_f;   // instruction word
    logic [31:0]   pc_f;     // program counter

    // Decode → Execute
    logic [31:0]   rs1_d;    // source register 1 data
    logic [31:0]   rs2_d;    // source register 2 data
    logic [31:0]   pc_d;     // program counter
    instruction::t inst_d;   // decoded instruction struct

    // Execute → Memory
    logic [31:0]   src_data_e;  // source data (for stores / CSR)
    logic [31:0]   rd_data_e;   // destination register data
    instruction::t inst_e;
    logic [31:0]   pc_e;
    logic [31:0]   next_pc_e;   // address of next instruction

    // Memory → Writeback
    logic [31:0]   src_data_m;
    logic [31:0]   rd_data_m;
    instruction::t inst_m;
    logic [31:0]   pc_m;
    logic [31:0]   next_pc_m;

    // =========================================================================
    // Forwarding signals  (later stage → Decode forwarding unit)
    //   Naming: fwd_<stage_abbreviation>
    // =========================================================================

    forwarding::t fwd_e;   // forwarding result from Execute
    forwarding::t fwd_m;   // forwarding result from Memory
    forwarding::t fwd_wb;  // forwarding result from Writeback

    // =========================================================================
    // Branch prediction signals
    // =========================================================================

    bpredict::bp_data_t bp_pred_f;    // Fetch    → Decode  (prediction for fetched inst)
    bpredict::bp_data_t bp_pred_d;    // Decode   → Execute (prediction travelling with inst)
    bpredict::bp_data_t bp_feedback;  // Execute  → Fetch + Writeback (actual branch outcome)
    logic [31:0]        bp_control;   // Writeback → Fetch  (algorithm select CSR)

    // =========================================================================
    // Pipeline control signals
    //   fwd_status_<stage>  = forwards status OUT of that stage
    //   bwd_status_<stage>  = backwards status OUT of that stage (goes backwards)
    //   jump_addr_<stage>   = jump address OUT of that stage (goes backwards)
    // =========================================================================

    pipeline_status::forwards_t  fwd_status_f;   // Fetch    → Decode
    pipeline_status::forwards_t  fwd_status_d;   // Decode   → Execute
    pipeline_status::forwards_t  fwd_status_e;   // Execute  → Memory
    pipeline_status::forwards_t  fwd_status_m;   // Memory   → Writeback

    pipeline_status::backwards_t bwd_status_d;   // Decode   → Fetch
    pipeline_status::backwards_t bwd_status_e;   // Execute  → Decode
    pipeline_status::backwards_t bwd_status_m;   // Memory   → Execute
    pipeline_status::backwards_t bwd_status_wb;  // Writeback→ Memory

    logic [31:0] jump_addr_d;   // Decode   → Fetch
    logic [31:0] jump_addr_e;   // Execute  → Decode
    logic [31:0] jump_addr_m;   // Memory   → Execute
    logic [31:0] jump_addr_wb;  // Writeback→ Memory

    // =========================================================================
    // Stage instantiations
    // =========================================================================

    // --- Fetch Stage ----------------------------------------------------------
    // Reads instructions from RAM via the fetch Wishbone port.
    // memory_fetch_port is already wishbone_interface.master, pass it directly.
    fetch_stage i_fetch (
        .clk                      (clk),
        .rst                      (rst),
        .wb                       (memory_fetch_port),
        .instruction_reg_out      (inst_f),
        .program_counter_reg_out  (pc_f),
        .status_forwards_out      (fwd_status_f),
        .status_backwards_in      (bwd_status_d),
        .jump_address_backwards_in(jump_addr_d),
        .bp_feedback_in           (bp_feedback),
        .bp_control_in            (bp_control),
        .bp_prediction_reg_out    (bp_pred_f)
    );

    // --- Decode Stage ---------------------------------------------------------
    // Reads the register file, applies forwarding, and decodes the instruction.
    decode_stage i_decode (
        .clk                       (clk),
        .rst                       (rst),
        .instruction_in            (inst_f),
        .program_counter_in        (pc_f),
        .exe_forwarding_in         (fwd_e),
        .mem_forwarding_in         (fwd_m),
        .wb_forwarding_in          (fwd_wb),
        .rs1_data_reg_out          (rs1_d),
        .rs2_data_reg_out          (rs2_d),
        .program_counter_reg_out   (pc_d),
        .instruction_reg_out       (inst_d),
        .bp_prediction_reg_out     (bp_pred_d),
        .status_forwards_in        (fwd_status_f),
        .status_forwards_out       (fwd_status_d),
        .status_backwards_in       (bwd_status_e),
        .status_backwards_out      (bwd_status_d),
        .jump_address_backwards_in (jump_addr_e),
        .jump_address_backwards_out(jump_addr_d),
        .bp_prediction_in          (bp_pred_f)
    );

    // --- Execute Stage --------------------------------------------------------
    // ALU operations, branch resolution, jump target computation.
    execute_stage i_execute (
        .clk                          (clk),
        .rst                          (rst),
        .rs1_data_in                  (rs1_d),
        .rs2_data_in                  (rs2_d),
        .instruction_in               (inst_d),
        .program_counter_in           (pc_d),
        .source_data_reg_out          (src_data_e),
        .rd_data_reg_out              (rd_data_e),
        .instruction_reg_out          (inst_e),
        .program_counter_reg_out      (pc_e),
        .next_program_counter_reg_out (next_pc_e),
        .forwarding_out               (fwd_e),
        .bp_prediction_in             (bp_pred_d),
        .bp_feedback_out              (bp_feedback),
        .status_forwards_in           (fwd_status_d),
        .status_forwards_out          (fwd_status_e),
        .status_backwards_in          (bwd_status_m),
        .status_backwards_out         (bwd_status_e),
        .jump_address_backwards_in    (jump_addr_m),
        .jump_address_backwards_out   (jump_addr_e)
    );

    // --- Memory Stage ---------------------------------------------------------
    // Load / store operations via the data Wishbone port.
    memory_stage i_memory (
        .clk                          (clk),
        .rst                          (rst),
        .wb                           (memory_mem_port),
        .source_data_in               (src_data_e),
        .rd_data_in                   (rd_data_e),
        .instruction_in               (inst_e),
        .program_counter_in           (pc_e),
        .next_program_counter_in      (next_pc_e),
        .source_data_reg_out          (src_data_m),
        .rd_data_reg_out              (rd_data_m),
        .instruction_reg_out          (inst_m),
        .program_counter_reg_out      (pc_m),
        .next_program_counter_reg_out (next_pc_m),
        .forwarding_out               (fwd_m),
        .status_forwards_in           (fwd_status_e),
        .status_forwards_out          (fwd_status_m),
        .status_backwards_in          (bwd_status_wb),
        .status_backwards_out         (bwd_status_m),
        .jump_address_backwards_in    (jump_addr_wb),
        .jump_address_backwards_out   (jump_addr_m)
    );

    // --- Writeback Stage ------------------------------------------------------
    // Writes results to the register file, handles CSRs, interrupts, exceptions.
    writeback_stage i_writeback (
        .clk                       (clk),
        .rst                       (rst),
        .source_data_in            (src_data_m),
        .rd_data_in                (rd_data_m),
        .instruction_in            (inst_m),
        .program_counter_in        (pc_m),
        .next_program_counter_in   (next_pc_m),
        .external_interrupt_in     (external_interrupt_in),
        .timer_interrupt_in        (timer_interrupt_in),
        .mtime_in                  (mtime_in),
        .bp_feedback_in            (bp_feedback),
        .bp_control_out            (bp_control),
        .forwarding_out            (fwd_wb),
        .status_forwards_in        (fwd_status_m),
        .status_backwards_out      (bwd_status_wb),
        .jump_address_backwards_out(jump_addr_wb)
    );

endmodule
