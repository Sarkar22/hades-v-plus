/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: constants.sv
 */



/*verilator lint_off UNUSED*/

`ifndef HADES_MEMORY_SIZE_WORDS
`define HADES_MEMORY_SIZE_WORDS 32'h0000_2000
`endif

package constants;
    // --------------------------------------------------------------------------------------------
    // |                                   Wishbone Constants                                     |
    // --------------------------------------------------------------------------------------------
    localparam bit [31:0] MEMORY_START = 32'h0001_0000;
    // RAM size in 32-bit words (default 0x2000 = 32 KiB, the Basys3 build).
    // Simulation-only override for large programs: verilate with
    // +define+HADES_MEMORY_SIZE_WORDS=<words>. The window [MEMORY_START,
    // MEMORY_START + size) must stay below LEDS_START, i.e. at most 0x7_0000
    // words (1.75 MiB); wishbone_interconnect stops the simulation otherwise.
    localparam bit [31:0] MEMORY_SIZE  = `HADES_MEMORY_SIZE_WORDS;

    localparam bit [31:0] LEDS_START = 32'h0008_0000;
    localparam bit [31:0] LEDS_SIZE  = 32'h0000_0001;

    localparam bit [31:0] BUTTONS_START = 32'h0008_1000;
    localparam bit [31:0] BUTTONS_SIZE  = 32'h0000_0001;

    localparam bit [31:0] SWITCHES_START = 32'h0008_2000;
    localparam bit [31:0] SWITCHES_SIZE  = 32'h0000_0001;

    localparam bit [31:0] SEGMENTS_START = 32'h0008_3000;
    localparam bit [31:0] SEGMENTS_SIZE  = 32'h0000_0001;

    localparam bit [31:0] UART_START = 32'h0008_4000;
    localparam bit [31:0] UART_SIZE  = 32'h0000_0001;

    localparam bit [31:0] TIMER_START = 32'h0008_5000;
    localparam bit [31:0] TIMER_SIZE  = 32'h0000_0005;

    localparam bit [31:0] VGA_START = 32'h0009_0000;
    localparam bit [31:0] VGA_SIZE  = 32'h0000_9600; // 640 * 480 pixel with 4 bit color depth

    localparam bit [31:0] TEST_START = 32'h0012_0000;
    localparam bit [31:0] TEST_SIZE  = 32'h0000_0005;

    // --------------------------------------------------------------------------------------------
    // |                                    Address Constants                                     |
    // --------------------------------------------------------------------------------------------
    localparam bit [31:0] RESET_ADDRESS = MEMORY_START << 2;

    // --------------------------------------------------------------------------------------------
    // |                                  Instruction Constants                                   |
    // --------------------------------------------------------------------------------------------
    localparam bit [31:0] NOP = 32'h00000013;

endpackage

/*verilator lint_on UNUSED*/
