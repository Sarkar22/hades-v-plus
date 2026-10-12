// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// env_common.svh -- reset, the tracked address and the tracked word of every I-cache harness.
// Included inside a harness module that has the inputs clk and in_rst.
// ---------------------------------------------------------------------------------------------
    // The first cycle is a reset; in every later cycle a reset is a free choice.
    logic f_first = 1'b1;
    always_ff @(posedge clk) f_first <= 1'b0;
    wire  rst = in_rst || f_first;
    logic f_past_rst;                       // rst in the previous cycle
    always_ff @(posedge clk) f_past_rst <= rst;

    // The tracked address: a free word address that never changes (its first value is free).
    // f_word is memory's word at that address as it is at the start of the cycle; its first value
    // is free as well. The memory model reads and writes it.
    logic [31:0] f_adr;
    always_ff @(posedge clk) f_adr <= f_adr;
    logic [31:0] f_word;

    function automatic logic [31:0] f_merge(input logic [31:0] old, input logic [31:0] wdata,
                                            input logic [3:0] sel);
        f_merge = {sel[3] ? wdata[31:24] : old[31:24], sel[2] ? wdata[23:16] : old[23:16],
                   sel[1] ? wdata[15:8]  : old[15:8],  sel[0] ? wdata[7:0]   : old[7:0]};
    endfunction

    function automatic logic f_inwin(input logic [31:0] a);
        f_inwin = a >= F_WINDOW_START && a < F_WINDOW_START + F_WINDOW_WORDS;
    endfunction
