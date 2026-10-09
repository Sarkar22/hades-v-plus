// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// slow_memory.sv -- simulation-only wait states for one port of the RAM.
//
// rtl/mcu.sv puts one in front of each port of wishbone_ram (port A: the fetch bus, port B:
// slave 0 of the data-bus interconnect) when the simulator is verilated with
// +define+HADES_SLOW_MEM, as `make MEM_LAT=...` does (see `make help`). It turns the
// single-cycle RAM into a memory with a latency, so that the CPU's bus ports, and any
// caches between them and the RAM, can be tested against a slow memory. The standard
// simulators and synthesis do not contain it (Vivado does not read sim/).
//
// What it does:
//   - Each transfer (cyc && stb) is held back from the RAM for its latency L: for L cycles
//     the RAM sees stb low, answers nothing, and the master waits. In the next cycle the
//     transfer is passed through and the RAM answers it as it always does. A transfer of
//     latency L takes L + 1 cycles instead of 1. With latency 0 stb goes straight through
//     and the port behaves exactly as without this module.
//   - A transfer starts in a cycle in which the master presents a request that is not the
//     one held from the previous cycle: after an answer, after a cycle without a request,
//     or when the request changes while it is held (the fetch stage changes its address on
//     a jump without waiting for an answer). Its latency is drawn then. The RAM reads the
//     request of the cycle in which it answers, so an answer always belongs to the request
//     presented in that cycle.
//   - Latencies are drawn from [RD_MIN, RD_MAX] for reads and from [WR_MIN, WR_MAX] for
//     writes by a 32-bit xorshift generator (a linear feedback generator), seeded at time 0;
//     each port gets its own sequence.
//   - The request "held" is its address, sel, we and, for a write, the data; Wishbone leaves
//     dat_mosi undefined during a read, so a read whose dat_mosi changes is the same read.
//   - Burst mode (off unless a beat latency is set): a further transfer to the next word,
//     in the same direction, while cyc has stayed high since the previous transfer was
//     answered, costs the beat latency instead. The fetch port holds cyc high all the time,
//     so with burst mode on every sequential fetch counts as a beat. On the data port an
//     access to another slave of the interconnect (cyc high, an address outside the RAM
//     window, so stb stays low here) ends the block.
//   - A reset drops a transfer that is being held.
//   - Every other request signal goes to the RAM unchanged, and the RAM's answer (ack, err,
//     dat_miso) goes to the master unchanged; this module adds no combinational path from
//     the answer to the request. Addresses outside the RAM window are delayed too: the RAM
//     answers them with err.
//
// Configuration: the defaults are compiled in (+define+HADES_MEM_RD_LAT_MIN=<n> ...
// HADES_MEM_RD_LAT_MAX, HADES_MEM_WR_LAT_MIN, HADES_MEM_WR_LAT_MAX, HADES_MEM_BEAT_LAT
// (-1: off), HADES_MEM_SEED; all latencies default to 0), so that simulators started by
// scripts that pass no options of their own still run with a slow memory. Run-time options
// override them:
//   +mem_lat=MIN[:MAX]      latency of reads and writes, in cycles (0 <= MIN <= MAX <= 1023)
//   +mem_rd_lat=MIN[:MAX]   latency of reads (after +mem_lat)
//   +mem_wr_lat=MIN[:MAX]   latency of writes (after +mem_lat)
//   +mem_beat_lat=N         burst mode: latency of a further beat to the next word
//   +mem_seed=N             seed of the latency generator
//   +mem_only=fetch|data    the latencies apply to that port only; the other one behaves as
//                           the standard RAM (latency 0, bursts off). Compiled in with
//                           +define+HADES_MEM_ONLY_FETCH or +define+HADES_MEM_ONLY_DATA.
// Each instance prints its configuration at time 0. On the data port a transfer must be
// answered within 255 cycles: the interconnect ends a longer one with err
// (lib/wishbone/wishbone_interconnect.sv), and sim/top.sv stops the simulation when that
// happens to a RAM access. So the data port refuses a read, write or beat latency above 254.
// ---------------------------------------------------------------------------------------------

`ifndef HADES_MEM_RD_LAT_MIN
`define HADES_MEM_RD_LAT_MIN 0
`endif
`ifndef HADES_MEM_RD_LAT_MAX
`define HADES_MEM_RD_LAT_MAX `HADES_MEM_RD_LAT_MIN
`endif
`ifndef HADES_MEM_WR_LAT_MIN
`define HADES_MEM_WR_LAT_MIN 0
`endif
`ifndef HADES_MEM_WR_LAT_MAX
`define HADES_MEM_WR_LAT_MAX `HADES_MEM_WR_LAT_MIN
`endif
`ifndef HADES_MEM_BEAT_LAT
`define HADES_MEM_BEAT_LAT -1
`endif
`ifndef HADES_MEM_SEED
`define HADES_MEM_SEED 1
`endif
`ifdef HADES_MEM_ONLY_FETCH
`define HADES_MEM_ONLY "fetch"
`elsif HADES_MEM_ONLY_DATA
`define HADES_MEM_ONLY "data"
`else
`define HADES_MEM_ONLY ""
`endif

module slow_memory #(
    parameter string PORT  = "data",   // name of the port in messages
    parameter int    INDEX = 0         // gives every port its own latency sequence
) (
    input logic clk,
    input logic rst,

    wishbone_interface.slave  master,  // the bus, as the CPU side drives it
    wishbone_interface.master memory   // the RAM port
);
    localparam int MAX_LATENCY      = 1023;
    localparam int DATA_MAX_LATENCY = 254;    // the interconnect's limit, see above

    // The RAM window (word addresses), as rtl/mcu.sv places the RAM
    localparam bit [31:0] RAM_START = constants::MEMORY_START;
    localparam bit [31:0] RAM_WORDS = constants::MEMORY_SIZE;

    // --------------------------------------------------------------------------------------------
    // |                                      Configuration                                       |
    // --------------------------------------------------------------------------------------------

    int unsigned rd_min, rd_max, wr_min, wr_max;
    int          beat_lat;                  // -1: burst mode off
    int unsigned seed;
    bit   [31:0] rng;                       // xorshift32 state, never 0

    function automatic bit [31:0] xorshift32(bit [31:0] x);
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        return x;
    endfunction

    // "N" or "MIN:MAX" (decimal) -> lo, hi; stops the simulation on anything else.
    // (Parsed by hand: Verilator's $sscanf returns -1 for "N" as well as for "x".)
    function automatic void parse_latency(input string option, input string text,
                                          inout int unsigned lo, inout int unsigned hi);
        int  colon, digits;
        bit  ok;
        colon  = -1;
        digits = 0;
        ok     = 1;
        for (int i = 0; i < text.len(); i++) begin
            if (text.getc(i) == ":" && colon < 0) begin
                ok     = ok && digits > 0;
                colon  = i;
                digits = 0;
            end
            else if (text.getc(i) >= "0" && text.getc(i) <= "9" && digits < 4) begin
                digits++;
            end
            else begin
                ok = 0;
            end
        end
        ok = ok && digits > 0;
        if (ok) begin
            lo = (colon < 0) ? text.atoi() : text.substr(0, colon - 1).atoi();
            hi = (colon < 0) ? lo : text.substr(colon + 1, text.len() - 1).atoi();
        end
        if (!ok || lo > hi || hi > MAX_LATENCY)
            $fatal(1, "slow_memory: +%s=%s: give N or MIN:MAX with 0 <= MIN <= MAX <= %0d",
                   option, text, MAX_LATENCY);
    endfunction

    function automatic string range_text(int unsigned lo, int unsigned hi);
        return (lo == hi) ? $sformatf("%0d", lo) : $sformatf("%0d..%0d", lo, hi);
    endfunction

    initial begin
        string text;
        bit [31:0] z;

        rd_min   = `HADES_MEM_RD_LAT_MIN;
        rd_max   = `HADES_MEM_RD_LAT_MAX;
        wr_min   = `HADES_MEM_WR_LAT_MIN;
        wr_max   = `HADES_MEM_WR_LAT_MAX;
        beat_lat = `HADES_MEM_BEAT_LAT;
        seed     = `HADES_MEM_SEED;
        if (rd_min > rd_max || rd_max > MAX_LATENCY || wr_min > wr_max || wr_max > MAX_LATENCY ||
            beat_lat < -1 || beat_lat > MAX_LATENCY)
            $fatal(1, "slow_memory: compiled-in latencies out of range (0 <= MIN <= MAX <= %0d)", MAX_LATENCY);

        if ($value$plusargs("mem_lat=%s", text)) begin
            parse_latency("mem_lat", text, rd_min, rd_max);
            wr_min = rd_min;
            wr_max = rd_max;
        end
        if ($value$plusargs("mem_rd_lat=%s", text)) parse_latency("mem_rd_lat", text, rd_min, rd_max);
        if ($value$plusargs("mem_wr_lat=%s", text)) parse_latency("mem_wr_lat", text, wr_min, wr_max);
        if ($value$plusargs("mem_beat_lat=%s", text)) begin
            int unsigned b0, b1;
            parse_latency("mem_beat_lat", text, b0, b1);
            if (b0 != b1)
                $fatal(1, "slow_memory: +mem_beat_lat=%s: give one number", text);
            beat_lat = int'(b0);
        end
        void'($value$plusargs("mem_seed=%d", seed));
        text = `HADES_MEM_ONLY;
        void'($value$plusargs("mem_only=%s", text));
        if (text != "" && text != "fetch" && text != "data")
            $fatal(1, "slow_memory: +mem_only=%s: give fetch or data", text);
        if (text != "" && text != PORT) begin
            rd_min   = 0;
            rd_max   = 0;
            wr_min   = 0;
            wr_max   = 0;
            beat_lat = -1;
        end
        if (PORT == "data" && (rd_max > DATA_MAX_LATENCY || wr_max > DATA_MAX_LATENCY ||
                               beat_lat > DATA_MAX_LATENCY))
            $fatal(1, "slow_memory: data port: read latency %s, write latency %s, burst beats %s: at most %0d cycles on the data port (the interconnect ends a data access after 255 cycles without an answer)",
                   range_text(rd_min, rd_max), range_text(wr_min, wr_max),
                   (beat_lat < 0) ? "off" : $sformatf("%0d", beat_lat), DATA_MAX_LATENCY);

        // Starting state: the seed and the port number, mixed (a zero state would stay zero)
        z = seed + 32'h9E37_79B9 * (INDEX + 1);
        z = (z ^ (z >> 16)) * 32'h85EB_CA6B;
        z = (z ^ (z >> 13)) * 32'hC2B2_AE35;
        z = z ^ (z >> 16);
        rng = (z == 0) ? 32'h1 : z;

        $display("SLOW MEMORY %-5s port: read latency %s, write latency %s, burst beats %s, seed %0d",
                 PORT, range_text(rd_min, rd_max), range_text(wr_min, wr_max),
                 (beat_lat < 0) ? "off" : $sformatf("%0d", beat_lat), seed);
    end

    // --------------------------------------------------------------------------------------------
    // |                                     Wait-state logic                                     |
    // --------------------------------------------------------------------------------------------

    // The transfer being held, and how many more cycles it is held
    logic        held;
    logic [31:0] held_adr, held_dat;
    logic  [3:0] held_sel;
    logic        held_we;
    int unsigned held_left;

    // Burst mode: the last transfer answered while cyc stayed high since
    logic        in_block;
    logic [31:0] last_adr;
    logic        last_we;

    logic        request, other, same, beat, pass;
    int unsigned latency, left;

    always_comb begin
        request = master.cyc && master.stb;
        other   = master.cyc && !master.stb && master.adr - RAM_START >= RAM_WORDS;
        same    = held && master.adr == held_adr && master.sel == held_sel &&
                  master.we == held_we && (!master.we || master.dat_mosi == held_dat);
        beat    = beat_lat >= 0 && in_block && master.adr == last_adr + 1 && master.we == last_we;
        if (beat)
            latency = int'(beat_lat);
        else if (master.we)
            latency = wr_min + rng % (wr_max - wr_min + 1);
        else
            latency = rd_min + rng % (rd_max - rd_min + 1);
        left = same ? held_left : latency;
        pass = request && left == 0;
    end

    assign memory.cyc      = master.cyc;
    assign memory.stb      = master.stb && left == 0;
    assign memory.adr      = master.adr;
    assign memory.sel      = master.sel;
    assign memory.we       = master.we;
    assign memory.dat_mosi = master.dat_mosi;

    assign master.ack      = memory.ack;
    assign master.err      = memory.err;
    assign master.dat_miso = memory.dat_miso;

    // (not always_ff: the generator state is also written by the initial block above)
    always @(posedge clk) begin
        if (rst) begin
            held     <= 0;
            in_block <= 0;
        end
        else begin
            held <= request && !pass;
            if (request && !same) begin     // a new transfer: its latency was drawn now
                held_adr <= master.adr;
                held_sel <= master.sel;
                held_we  <= master.we;
                held_dat <= master.dat_mosi;
                rng      <= xorshift32(rng);
            end
            if (request && !pass)
                held_left <= left - 1;
            if (pass) begin
                in_block <= master.cyc;
                last_adr <= master.adr;
                last_we  <= master.we;
            end
            else if (!master.cyc || other) begin
                in_block <= 0;
            end
        end
    end

endmodule
