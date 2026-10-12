// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// cache_ram.sv -- the array of a cache: DEPTH words of WIDTH bits, read within the cycle.
//
// The caches of rtl/cache keep their tags and data in instances of this module, so that an
// array of another style (for example one with a registered read, which a board's block RAM
// needs) can replace it without touching the caches' state machines.
//
//   Port A  a_adr selects the word; a_rdata is that word in the same cycle (asynchronous
//           read). When a_we is 1, a_wdata is written to the word at a_adr at the rising edge
//           of clk (one address for the read and the write: a single-ported array).
//   Port B  only with SNOOP_PORT = 1: a second, read-only port; b_rdata is the word at b_adr
//           in the same cycle. With SNOOP_PORT = 0, b_adr is not used and b_rdata is 0.
//
// No reset: the words keep their contents across a reset. In simulation the cache that owns
// the array fills it at time 0 (see rtl/cache/icache.sv).
// ---------------------------------------------------------------------------------------------

module cache_ram #(
    parameter int WIDTH      = 32,    // bits per word, at least 1
    parameter int DEPTH      = 2,     // words, a power of two, at least 2
    parameter bit SNOOP_PORT = 1'b0   // 1: the read-only port B exists
) (
    input  logic clk,

    input  logic [$clog2(DEPTH)-1:0] a_adr,
    output logic [WIDTH-1:0]         a_rdata,
    input  logic                     a_we,
    input  logic [WIDTH-1:0]         a_wdata,

    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [$clog2(DEPTH)-1:0] b_adr,     // not used without SNOOP_PORT
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [WIDTH-1:0]         b_rdata
);
    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (a_we)
            mem[a_adr] <= a_wdata;
    end

    assign a_rdata = mem[a_adr];

    if (SNOOP_PORT) begin : snoop_port
        assign b_rdata = mem[b_adr];
    end
    else begin : no_snoop_port
        assign b_rdata = '0;
    end

`ifndef SYNTHESIS
    // The parameters are checked before the first clock edge. (An elaboration-time $fatal
    // would only be a warning in builds with -Wno-fatal, which go on.)
    initial begin : parameter_check
        if (WIDTH < 1)
            $fatal(1, "cache_ram: WIDTH = %0d: the word width must be at least 1", WIDTH);
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "cache_ram: DEPTH = %0d: the number of words must be a power of two, at least 2", DEPTH);
    end
`endif

endmodule
