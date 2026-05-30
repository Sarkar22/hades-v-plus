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
    input  logic [31:0] jump_address_backwards_in,

    // Branch prediction
    input  bpredict::bp_data_t bp_feedback_in,   // from Execute: actual outcome
    input  logic [31:0]        bp_control_in,    // from Writeback: algorithm select
    output bpredict::bp_data_t bp_prediction_reg_out  // to Decode: prediction for fetched inst
);

    import constants::*;
    import pipeline_status::*;

    logic [31:0] pc;

    // -------------------------------------------------------------------------
    // Branch predictor instantiation
    // -------------------------------------------------------------------------
    bpredict::bp_data_t bp_prediction;
    logic [31:0]        bp_branch_offset;

    branch_predictor i_branch_predictor (
        .clk              (clk),
        .rst              (rst),
        .instruction_bits (wb.dat_miso),
        .program_counter  (pc),
        .bp_control_in    (bp_control_in),
        .bp_feedback_in   (bp_feedback_in),
        .bp_prediction_out(bp_prediction),
        .bp_branch_offset (bp_branch_offset)
    );

    // =========================================================================
    // PART 1: Wishbone bus drive signals (combinational)
    // =========================================================================
    assign wb.we      = 1'b0;
    assign wb.sel     = 4'b1111;
    assign wb.dat_mosi = '0;
    assign wb.adr     = pc >> 2;
    assign wb.cyc     = 1'b1;
    assign wb.stb     = 1'b1;

    // =========================================================================
    // PART 2: PC update (sequential)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= RESET_ADDRESS;
        end else begin
            case (status_backwards_in)
                JUMP:  pc <= jump_address_backwards_in;
                STALL: pc <= pc;
                // When predicted taken: speculatively jump to branch target.
                // With mode 0 (never taken): predicted_taken=0 → always pc+4.
                READY: begin
                    if (wb.ack) begin
                        if (bp_prediction.predicted_taken)
                            pc <= pc + bp_branch_offset;
                        else
                            pc <= pc + 4;
                    end else
                        pc <= pc;
                end
                default: pc <= pc;
            endcase
        end
    end

    // =========================================================================
    // PART 3: Output register update (sequential)
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            instruction_reg_out     <= NOP;
            program_counter_reg_out <= RESET_ADDRESS;
            status_forwards_out     <= BUBBLE;
            bp_prediction_reg_out   <= '0;
        end else begin
            case (status_backwards_in)
                STALL: begin
                    // hold all outputs
                end
                JUMP: begin
                    status_forwards_out   <= BUBBLE;
                    bp_prediction_reg_out <= '0;
                end
                READY: begin
                    if (wb.ack) begin
                        instruction_reg_out     <= wb.dat_miso;
                        program_counter_reg_out <= pc;
                        status_forwards_out     <= VALID;
                        bp_prediction_reg_out   <= bp_prediction;
                    end else if (wb.err) begin
                        program_counter_reg_out <= pc;
                        status_forwards_out     <= FETCH_FAULT;
                        bp_prediction_reg_out   <= '0;
                    end else begin
                        status_forwards_out   <= BUBBLE;
                        bp_prediction_reg_out <= '0;
                    end
                end
                default: begin
                    status_forwards_out   <= BUBBLE;
                    bp_prediction_reg_out <= '0;
                end
            endcase
        end
    end

endmodule
