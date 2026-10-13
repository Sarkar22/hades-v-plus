// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// test_dcache.sv -- bench of the simulation-only memory system with both caches: the instruction
// cache, the write-through data cache and the memory-port arbiter (rtl/cache/icache.sv,
// rtl/cache/dcache.sv, rtl/cache/mem_arbiter.sv), compared in every cycle with a reference model.
//
// The device under test is one icache, one dcache and one mem_arbiter, wired as rtl/mcu.sv wires
// them in the cached simulators with a data cache: the fetch bus on the instruction cache's CPU
// port, the data bus (interconnect slave 0, the RAM window) on the data cache's CPU port, both
// caches' memory-side ports on the arbiter's two sides together with their continuation tags,
// and the instruction cache's snoop taken from the stores that slave 0 acknowledges. Around it the
// bench has a fetch driver, a data driver and a memory model. The reference model, module
// memsys_ref below, gets the same inputs (the fetch request, the data request, the memory's
// answer, reset) and computes every output of the three blocks from their documented behaviour
// (docs/CACHES.md) in one procedural step per cycle with explicit state; it was written without
// reading the RTL of the data cache.
//
// Compared in every cycle, reset cycles included (the first cycle, before any reset edge, apart):
// both CPU-side buses (ack, err, and the word with an answered load), both caches' memory-side
// requests (cyc, stb, the continuation tag, and with a request adr, we, sel, dat_mosi), the memory
// port's request (all of it, 0 when idle) and continuation tag, ack, err and dat_miso on both
// sides of the arbiter, and the twenty-one event outputs. Independently of the model the bench
// checks that every fetch and load answer equals memory at that address as it was at the start of
// the cycle, that the caches' refill reads never write, that exactly one memory write is answered
// per acknowledged store, with its byte enables and data, and no other write, the answer bounds
// (below), and the identities of the event counts (also against the bench's own count of
// answered loads and stores). The first discrepancy stops the run with the configuration, the
// cycle, the signal and both values.
//
// Answer bounds, computed from the memory's configured maximum latencies (RD read, WR write, B
// the beat latency in burst mode, else RD; n words per line; one line size for both caches):
// R = (RD + 1) + (n - 1) * (B + 1) is the length of a granted refill block.
//   (a) a request on the data bus is answered within R + max(R + 1, WR) cycles of its first cycle;
//   (b) an instruction-cache refill is granted within max(K_OLDER * (WR + 1), R + 1) cycles of its
//       first refill cycle, while the data driver behaves like the CPU (below);
//   (c) a granted instruction refill's last beat is answered within R cycles of its first granted
//       cycle;
//   (e) a data-cache refill is granted within R cycles of its first refill cycle;
//   (f) a granted data refill's last beat is answered within R cycles of its first granted cycle.
// The cycle in which an interval starts is its cycle 1; an interval that meets a reset is
// dropped. The R + 1 term of (b) is the coincident miss: the instruction fetch and the load that
// is in the Memory stage both miss in one cycle, neither cache requests in it, the data refill
// wins the free port and holds it for R cycles, and its second lookup, in which it does not
// request, frees the port in cycle R + 1. The bench builds that case on purpose and requires the
// grant in exactly that cycle.
//
// Stimulus, from a seeded generator: the fetch driver of the instruction-cache bench (sequential
// fetches, holds, jumps in any cycle to any line, cached lines, the line being refilled, both ends
// of the window and just outside it, out-of-window aliases, error loops, garbage in cycles
// without a request). The data driver issues loads and stores with the byte enables of sb, sh and
// sw at every offset and random data on the unselected lanes (and on the garbage of loads), held
// until answered, back to back or with gaps; addresses are biased to the lines the data cache
// holds, to lines it held before a reset or a refill invalidated them, to the line in refill, to
// lines one data-cache size apart, to lines the instruction cache holds and to the lines being
// fetched; between requests there are I/O-like intervals (cyc without stb, as slave 0 sees every
// I/O access) and garbage. The data driver works in two modes: like the CPU (one request at a
// time, the next in the cycle after the previous answer at the earliest; from an instruction
// miss up to that refill's grant at most K_OLDER = 3 requests, of which at most two begin after
// the miss cycle; a request first presented in the miss cycle is allowed), or freely, where a
// request that waits for a data refill may be replaced and the instruction refill may be starved
// (bound (b) is not checked then). Resets come at random cycles, more often in refills, store
// waits and second lookups, sometimes several cycles long; during a reset the memory model may
// change memory, so a line wrongly kept valid shows as wrong data. Directed sequences, started at
// random and counted as coverage: every byte-enable pattern on a store hit and on a store miss;
// a store miss and then a load of that line; a load miss and then a store to it; two lines one
// data-cache size apart used alternately; stores, load hits and load misses while an instruction
// refill holds the port; both misses in one cycle; an instruction miss during a data refill; K_OLDER
// back-to-back stores behind an instruction miss; a store that hits the instruction-cache line
// which a miss in the same cycle evicts; two hot loops one instruction-cache size apart.
//
// Configurations (instruction cache bytes, data cache bytes, line bytes): (16, 16, 8), (512, 512,
// 16), (8192, 4096, 16), (512, 512, 8), (512, 512, 32), (512, 512, 64), (512, 32, 16), each with a
// window of 8 lines and with the 32 KiB RAM window, each run through five memory profiles (latency
// 0; latency 2; random 1-8; random 1-64; DRAM-like: reads 8-24, writes 1-4, one cycle per further
// refill beat), with a reset between profiles; and the system configuration: (512, 512, 16) with
// the RAM window and the real memory wrapper (sim/slow_memory.sv, port "memory") and RAM
// (lib/wishbone/wishbone_ram.sv) behind the arbiter, configured by the wrapper's own run-time
// options (+mem_lat ...). The reference model is checked first against hand-computed cycles
// (module memsys_ref_selftest below). The end of the run prints one line per configuration and
// one of:
//     DCACHE BENCH: PASS (<configurations>, <cycles>, 0 mismatches)        exit status 0
//     DCACHE BENCH: FAIL (<reason>)                                        exit status 1
//     DCACHE BENCH: COMPARE OFF (<configurations>, <cycles>)               exit status 1
//
// Run-time options:
//   +seed=<n>             seed of the stimulus (default 1). The caches' random initial arrays
//                         follow +mem_seed, as in the system simulators.
//   +cycles=<n>           cycles per configuration and memory profile (default 1000000; the
//                         system configuration runs <n> cycles in all)
//   +only=<name>[,...]    run only the named configurations (the names of the result lines)
//   +cover=0              print the coverage counts without judging them (for short runs)
//   +compare=0            the bench's own checks (the comparison, the memory checks, the bounds,
//                         the identities) report nothing, so that only the assertions inside the
//                         caches and the arbiter can stop the run; it ends with COMPARE OFF
//   +compare=bounds       as +compare=0, but the answer bounds are still checked (so that a fault
//                         which breaks a bound, and which the comparison would see first, is
//                         shown by the bound's own message); it ends with COMPARE OFF as well
//   +selftest             run only the check of the reference model against hand-computed cycles
//                         (it also runs, before the configurations, in every other run)
//   +negative=<case>      inject one fault in configuration i512-d512-line16-ram; an assertion
//                         of the design must stop the run, otherwise the bench fails 32 cycles
//                         later. Cases: d-request-change (a store that waits for the port, behind
//                         an instruction refill, changes its request), d-refill-err (the memory
//                         answers a data-cache refill beat with err), d-store-err (the memory
//                         answers a store with err), d-out-of-window (a request with stb outside
//                         the window reaches the data cache), ack-err (the memory answers a data
//                         transfer with ack and err), spontaneous-answer (the memory answers in a
//                         cycle without a request)
//   +mem_lat=..., +mem_rd_lat=..., +mem_wr_lat=..., +mem_beat_lat=..., +mem_seed=...
//                         the memory wrapper of the system configuration (sim/slow_memory.sv)
// ---------------------------------------------------------------------------------------------

package dcache_bench_pkg;
    // The events, in the order of the comparison: the thirteen of the instruction cache and the
    // arbiter, then the eight of the data cache
    localparam int NEV = 21;
    localparam int E_IHIT = 0, E_IMISS = 1, E_IBEAT = 2, E_IFILL = 3, E_IABAND = 4,
                   E_SNOOP = 5, E_WAITI = 6, E_WAITD = 7, E_GRANTI = 8, E_GRANTD = 9,
                   E_PLOAD = 10, E_PSTORE = 11, E_IREFILL = 12,
                   E_DLOOKUP = 13, E_DLMISS = 14, E_DBEAT = 15, E_DFILL = 16, E_DSHIT = 17,
                   E_DSMISS = 18, E_DSWAIT = 19, E_DREFILL = 20;
endpackage

// =============================================================================================
// Reference model
// =============================================================================================

module memsys_ref #(
    parameter int unsigned IBYTES       = 512,
    parameter int unsigned DBYTES       = 512,
    parameter int unsigned LINE_BYTES   = 16,
    parameter bit   [31:0] WINDOW_START = 32'h0001_0000,
    parameter bit   [31:0] WINDOW_WORDS = 32'h0000_2000
) (
    input  logic        clk,
    input  logic        rst,

    // The fetch bus, as the CPU presents it
    input  logic        f_cyc,
    input  logic        f_stb,
    input  logic [31:0] f_adr,

    // The data bus (interconnect slave 0), as the CPU presents it
    input  logic        c_cyc,
    input  logic        c_stb,
    input  logic        c_we,
    input  logic [31:0] c_adr,
    input  logic  [3:0] c_sel,
    input  logic [31:0] c_dat,

    // The memory's answer on the single port
    input  logic        m_ack,
    input  logic        m_err,
    input  logic [31:0] m_dat,

    // Expected outputs in this cycle
    output logic        x_f_ack,        // fetch bus
    output logic        x_f_err,
    output logic [31:0] x_f_dat,        // meaningful with x_f_ack
    output logic        x_c_ack,        // data bus
    output logic        x_c_err,
    output logic [31:0] x_c_dat,        // meaningful with an answered load
    output logic        x_i_cyc,        // the instruction cache's refill request
    output logic        x_i_stb,
    output logic [31:0] x_i_adr,
    output logic        x_i_cont,
    output logic        x_dm_cyc,       // the data cache's request to the arbiter
    output logic        x_dm_stb,
    output logic [31:0] x_dm_adr,
    output logic        x_dm_we,
    output logic  [3:0] x_dm_sel,
    output logic [31:0] x_dm_dat,
    output logic        x_dm_cont,
    output logic        x_m_cyc,        // the memory port
    output logic        x_m_stb,
    output logic [31:0] x_m_adr,
    output logic        x_m_we,
    output logic  [3:0] x_m_sel,
    output logic [31:0] x_m_dat,
    output logic        x_m_cont,
    output logic        x_d_ack,        // the arbiter's data side (the data cache's memory port)
    output logic        x_d_err,
    output logic [31:0] x_d_dat,
    output logic        x_r_ack,        // the arbiter's refill side
    output logic        x_r_err,
    output logic [31:0] x_r_dat,
    // Events, in the order of dcache_bench_pkg
    output logic [dcache_bench_pkg::NEV-1:0] x_ev,

    // For the bench's stimulus and coverage
    output logic        o_irefill,      // the instruction cache is refilling in this cycle
    output logic        o_drefill,      // the data cache is refilling in this cycle
    output logic        o_gd,           // the data side of the arbiter is granted in this cycle
    output logic        o_gi,           // the instruction refill is granted in this cycle
    output logic        o_snoop,        // a store is acknowledged at slave 0 in this cycle
    output logic        o_dpresent,     // the data bus's address is in a valid line of the data cache
    output logic        o_store         // the data cache presents a store to the arbiter
);
    import dcache_bench_pkg::*;

    localparam int unsigned LW    = LINE_BYTES / 4;     // words per line
    localparam int unsigned O     = $clog2(LW);         // word-in-line bits
    localparam int unsigned ISETS = IBYTES / LINE_BYTES;
    localparam int unsigned II    = $clog2(ISETS);      // instruction cache index bits
    localparam int unsigned IT    = 30 - II - O;        // instruction cache tag bits
    localparam int unsigned DSETS = DBYTES / LINE_BYTES;
    localparam int unsigned DI    = $clog2(DSETS);      // data cache index bits
    localparam int unsigned DT    = 30 - DI - O;        // data cache tag bits

    localparam int OWNER_NONE = 0, OWNER_DATA = 1, OWNER_REFILL = 2;

    // ---- explicit state: the instruction cache ----
    bit               refilling;      // 0: lookup, 1: refill
    int unsigned      beat;           // the refill beat being requested, 0 .. LW-1
    bit   [29:0]      line;           // the refilled line: word address >> O
    bit   [ISETS-1:0] valid;
    bit   [IT-1:0]    tags  [ISETS];
    bit   [31:0]      words [ISETS*LW];
    // ---- the data cache ----
    bit               drefilling;
    int unsigned      dbeat;
    bit   [29:0]      dline;
    bit   [DSETS-1:0] dvalid;
    bit   [DT-1:0]    dtags  [DSETS];
    bit   [31:0]      dwords [DSETS*LW];
    // ---- the arbiter ----
    int               owner;          // who holds the memory port across cycles

    initial begin
        refilling  = 0;
        beat       = 0;
        line       = '0;
        valid      = '0;
        drefilling = 0;
        dbeat      = 0;
        dline      = '0;
        dvalid     = '0;
        owner      = OWNER_NONE;
        for (int k = 0; k < ISETS; k++) tags[k] = '0;
        for (int k = 0; k < ISETS * LW; k++) words[k] = '0;
        for (int k = 0; k < DSETS; k++) dtags[k] = '0;
        for (int k = 0; k < DSETS * LW; k++) dwords[k] = '0;
    end

    function automatic int unsigned set_of(bit [31:0] a);
        return int'((a >> O) & (ISETS - 1));
    endfunction
    function automatic bit [IT-1:0] tag_of(bit [31:0] a);
        return IT'(a >> (O + II));
    endfunction
    function automatic int unsigned dset_of(bit [31:0] a);
        return int'((a >> O) & (DSETS - 1));
    endfunction
    function automatic bit [DT-1:0] dtag_of(bit [31:0] a);
        return DT'(a >> (O + DI));
    endfunction
    function automatic bit [29:0] line_of(bit [31:0] a);
        return 30'(a[29:0] >> O);
    endfunction
    function automatic bit in_window(bit [31:0] a);
        return a >= WINDOW_START && a < WINDOW_START + WINDOW_WORDS;
    endfunction

    // ---- the step of one cycle: everything that does not depend on the memory's answer ----
    bit          req, inwin, hit, miss, d_req, i_req, port_free, gd, gi;
    bit          dreq, dpresent, dload_hit, dmiss, dstore;
    int unsigned s, w, ds, dw;

    always_comb begin
        // instruction cache
        req   = f_cyc && f_stb;
        inwin = in_window(f_adr);
        s     = set_of(f_adr);
        w     = int'(f_adr & (LW - 1));
        hit   = req && valid[s] && tags[s] == tag_of(f_adr) && f_adr[31:30] == 2'b00;

        x_f_ack = !refilling && hit;
        x_f_err = req && !inwin;
        x_f_dat = words[s * LW + w];
        miss    = !refilling && req && inwin && !hit;

        x_i_cyc  = refilling;
        x_i_stb  = refilling;
        x_i_adr  = {2'b00, line} << O | 32'(beat);
        x_i_cont = refilling && beat != 0;

        // data cache: requests only count with cyc && stb; a load that finds its line is answered
        // at once; a store is presented to the arbiter in its own cycle; a refill reads the line
        // from word 0 and holds the request until it is answered
        dreq      = c_cyc && c_stb;
        ds        = dset_of(c_adr);
        dw        = int'(c_adr & (LW - 1));
        dpresent  = dvalid[ds] && dtags[ds] == dtag_of(c_adr);
        dload_hit = !drefilling && dreq && !c_we && dpresent;
        dmiss     = !drefilling && dreq && !c_we && !dpresent;
        dstore    = !drefilling && dreq && c_we;

        x_dm_cyc  = drefilling || dstore;
        x_dm_stb  = drefilling || dstore;
        x_dm_adr  = drefilling ? ({2'b00, dline} << O | 32'(dbeat)) : dstore ? c_adr : 32'h0;
        x_dm_we   = !drefilling && dstore;
        x_dm_sel  = drefilling ? 4'b1111 : dstore ? c_sel : 4'b0000;
        x_dm_dat  = drefilling ? 32'h0 : dstore ? c_dat : 32'h0;
        x_dm_cont = drefilling && dbeat != 0;

        // arbiter: the data side first on a free port; a grant lasts its transfer or block
        d_req     = x_dm_cyc && x_dm_stb;
        i_req     = x_i_cyc && x_i_stb;
        port_free = owner == OWNER_NONE || (owner == OWNER_REFILL && !i_req);
        gd        = d_req && (owner == OWNER_DATA || port_free);
        gi        = i_req && (owner == OWNER_REFILL || (port_free && !d_req));

        x_m_cyc  = gd || gi;
        x_m_stb  = gd || gi;
        x_m_adr  = gd ? x_dm_adr : gi ? x_i_adr : 32'h0;
        x_m_we   = gd ? x_dm_we  : 1'b0;
        x_m_sel  = gd ? x_dm_sel : gi ? 4'b1111 : 4'b0000;
        x_m_dat  = gd ? x_dm_dat : 32'h0;
        x_m_cont = (gi && x_i_cont) || (gd && x_dm_cont);

        o_irefill  = refilling;
        o_drefill  = drefilling;
        o_gd       = gd;
        o_gi       = gi;
        o_dpresent = dpresent;
        o_store    = dstore;
    end

    // ---- the step of one cycle: everything that depends on the memory's answer ----
    bit          beat_answer, last_beat, snoop, snoop_hit, abandoned;
    bit          dbeat_answer, dlast_beat, st_accept;
    int unsigned ss;

    always_comb begin
        x_d_ack = gd && m_ack;
        x_d_err = gd && m_err;
        x_d_dat = gd ? m_dat : 32'h0;
        x_r_ack = gi && m_ack;
        x_r_err = gi && m_err;
        x_r_dat = gi ? m_dat : 32'h0;

        beat_answer = refilling && x_r_ack;
        last_beat   = beat_answer && beat == LW - 1;
        abandoned   = last_beat && !(req && inwin && line_of(f_adr) == line);

        dbeat_answer = drefilling && x_d_ack;
        dlast_beat   = dbeat_answer && dbeat == LW - 1;
        st_accept    = dstore && x_d_ack;

        // the data bus: a load hit, or a store accepted by the memory; never err
        x_c_ack = dload_hit || st_accept;
        x_c_err = 1'b0;
        x_c_dat = dwords[ds * LW + dw];

        // the instruction cache snoops the stores that slave 0 acknowledges
        snoop     = c_cyc && c_stb && c_we && x_c_ack;
        ss        = set_of(c_adr);
        snoop_hit = snoop && valid[ss] && tags[ss] == tag_of(c_adr);
        o_snoop   = snoop;

        x_ev[E_IHIT]    = x_f_ack;
        x_ev[E_IMISS]   = miss;
        x_ev[E_IBEAT]   = beat_answer;
        x_ev[E_IFILL]   = last_beat;
        x_ev[E_IABAND]  = abandoned;
        x_ev[E_SNOOP]   = snoop_hit;
        x_ev[E_WAITI]   = i_req && !gi;
        x_ev[E_WAITD]   = d_req && !gd;
        x_ev[E_GRANTI]  = gi;
        x_ev[E_GRANTD]  = gd;
        x_ev[E_PLOAD]   = gd && m_ack && !x_dm_we;
        x_ev[E_PSTORE]  = gd && m_ack && x_dm_we;
        x_ev[E_IREFILL] = refilling;
        x_ev[E_DLOOKUP] = x_c_ack && !c_we;
        x_ev[E_DLMISS]  = dmiss;
        x_ev[E_DBEAT]   = dbeat_answer;
        x_ev[E_DFILL]   = dlast_beat;
        x_ev[E_DSHIT]   = st_accept && dpresent;
        x_ev[E_DSMISS]  = st_accept && !dpresent;
        x_ev[E_DSWAIT]  = dreq && c_we && !x_c_ack;
        x_ev[E_DREFILL] = drefilling;
        if (rst) x_ev = '0;
    end

    // ---- the end of the cycle ----
    always @(posedge clk) begin
        if (rst) begin
            refilling  <= 0;
            beat       <= 0;
            valid      <= '0;
            drefilling <= 0;
            dbeat      <= 0;
            dvalid     <= '0;
            owner      <= OWNER_NONE;
        end
        else begin
            // instruction cache
            if (miss) begin
                valid[s]  <= 1'b0;
                line      <= line_of(f_adr);
                beat      <= 0;
                refilling <= 1;
            end
            if (beat_answer) begin
                words[set_of(x_i_adr) * LW + beat] <= m_dat;
                beat <= beat + 1;
                if (last_beat) begin
                    tags[set_of(x_i_adr)]  <= tag_of(x_i_adr);
                    valid[set_of(x_i_adr)] <= 1'b1;
                    refilling <= 0;
                    beat      <= 0;
                end
            end
            if (snoop_hit)
                valid[ss] <= 1'b0;
            // data cache: a load miss starts a refill; a store changes the lanes of a present line
            if (dmiss) begin
                dvalid[ds] <= 1'b0;
                dline      <= line_of(c_adr);
                dbeat      <= 0;
                drefilling <= 1;
            end
            if (dbeat_answer) begin
                dwords[dset_of(x_dm_adr) * LW + dbeat] <= m_dat;
                dbeat <= dbeat + 1;
                if (dlast_beat) begin
                    dtags[dset_of(x_dm_adr)]  <= dtag_of(x_dm_adr);
                    dvalid[dset_of(x_dm_adr)] <= 1'b1;
                    drefilling <= 0;
                    dbeat      <= 0;
                end
            end
            if (st_accept && dpresent)
                for (int k = 0; k < 4; k++)
                    if (c_sel[k])
                        dwords[ds * LW + dw][8*k +: 8] <= c_dat[8*k +: 8];
            // arbiter
            if (gd)
                owner <= (m_ack || m_err) ? OWNER_NONE : OWNER_DATA;
            else if (gi)
                owner <= OWNER_REFILL;
            else
                owner <= OWNER_NONE;
        end
    end
endmodule

// =============================================================================================
// The reference model against hand-computed cycles
// =============================================================================================
//
// A small instance of memsys_ref (instruction cache 32 bytes, data cache 32 bytes, 16-byte lines,
// a window of 16 words at word address 0x100) is driven through scripted cycles. The expected
// values were worked out by hand from docs/CACHES.md: cycle numbers in the comments count from
// the first cycle of each case. R is 4 cycles at latency 0.
//
// Both caches have two sets (index = word address bit 2) and the tag is the address shifted right
// by 3: line X = words 0x100-0x103 (set 0, tag 0x20), Y = 0x104-0x107 (set 1, tag 0x20), Z =
// 0x108-0x10B (set 0, tag 0x21, conflicts with X), W = 0x10C-0x10F (set 1, tag 0x21, conflicts
// with Y). The memory word at address a is 0xA000_0000 + a (the script feeds it as the memory's
// answer).

module memsys_ref_selftest (
    input  logic clk,
    output bit   done,
    output bit   failed,
    output int unsigned n_checks
);
    import dcache_bench_pkg::*;

    localparam bit [31:0] WS = 32'h100;
    localparam bit [31:0] WW = 32'h10;

    logic        rst;
    logic        f_cyc, f_stb;
    logic [31:0] f_adr;
    logic        c_cyc, c_stb, c_we;
    logic [31:0] c_adr, c_dat;
    logic  [3:0] c_sel;
    logic        m_ack, m_err;
    logic [31:0] m_dat;

    logic        x_f_ack, x_f_err, x_c_ack, x_c_err, x_i_cyc, x_i_stb, x_i_cont;
    logic        x_dm_cyc, x_dm_stb, x_dm_we, x_dm_cont, x_m_cyc, x_m_stb, x_m_we, x_m_cont;
    logic        x_d_ack, x_d_err, x_r_ack, x_r_err;
    logic [31:0] x_f_dat, x_c_dat, x_i_adr, x_dm_adr, x_dm_dat, x_m_adr, x_m_dat, x_d_dat, x_r_dat;
    logic  [3:0] x_dm_sel, x_m_sel;
    logic [NEV-1:0] x_ev;
    logic        o_irefill, o_drefill, o_gd, o_gi, o_snoop, o_dpresent, o_store;

    memsys_ref #(.IBYTES(32), .DBYTES(32), .LINE_BYTES(16), .WINDOW_START(WS), .WINDOW_WORDS(WW)) model (
        .clk, .rst, .f_cyc, .f_stb, .f_adr,
        .c_cyc, .c_stb, .c_we, .c_adr, .c_sel, .c_dat, .m_ack, .m_err, .m_dat,
        .x_f_ack, .x_f_err, .x_f_dat, .x_c_ack, .x_c_err, .x_c_dat,
        .x_i_cyc, .x_i_stb, .x_i_adr, .x_i_cont,
        .x_dm_cyc, .x_dm_stb, .x_dm_adr, .x_dm_we, .x_dm_sel, .x_dm_dat, .x_dm_cont,
        .x_m_cyc, .x_m_stb, .x_m_adr, .x_m_we, .x_m_sel, .x_m_dat, .x_m_cont,
        .x_d_ack, .x_d_err, .x_d_dat, .x_r_ack, .x_r_err, .x_r_dat, .x_ev,
        .o_irefill, .o_drefill, .o_gd, .o_gi, .o_snoop, .o_dpresent, .o_store
    );

    int  checks;
    int  case_no;
    string case_name;

    task automatic fail(string what);
        $display("DCACHE BENCH: model self-test: case %0d (%s): %s", case_no, case_name, what);
        failed = 1;
    endtask
    task automatic expect1(string what, logic [31:0] got, logic [31:0] want);
        checks++;
        if (got !== want) fail($sformatf("%s: model 0x%0x, hand-computed 0x%0x", what, got, want));
    endtask
    // The events expected in a cycle, as a list of bit numbers; all others must be 0
    task automatic expect_events(string what, int e0 = -1, int e1 = -1, int e2 = -1, int e3 = -1,
                                 int e4 = -1, int e5 = -1, int e6 = -1, int e7 = -1);
        logic [NEV-1:0] want;
        want = '0;
        if (e0 >= 0) want[e0] = 1;
        if (e1 >= 0) want[e1] = 1;
        if (e2 >= 0) want[e2] = 1;
        if (e3 >= 0) want[e3] = 1;
        if (e4 >= 0) want[e4] = 1;
        if (e5 >= 0) want[e5] = 1;
        if (e6 >= 0) want[e6] = 1;
        if (e7 >= 0) want[e7] = 1;
        expect1({what, ": events"}, 32'(x_ev), 32'(want));
    endtask

    // Inputs of a cycle, then the check, then the clock edge
    task automatic idle_inputs();
        rst = 0;
        f_cyc = 0; f_stb = 0; f_adr = 0;
        c_cyc = 0; c_stb = 0; c_we = 0; c_adr = 0; c_sel = 4'b1111; c_dat = 32'hDEAD_BEEF;
        m_ack = 0; m_err = 0; m_dat = 0;
    endtask
    task automatic load(logic [31:0] a);
        c_cyc = 1; c_stb = 1; c_we = 0; c_adr = a; c_sel = 4'b0100; c_dat = 32'h5555_5555;
    endtask
    task automatic store(logic [31:0] a, logic [3:0] sel, logic [31:0] d);
        c_cyc = 1; c_stb = 1; c_we = 1; c_adr = a; c_sel = sel; c_dat = d;
    endtask
    task automatic fetch(logic [31:0] a);
        f_cyc = 1; f_stb = 1; f_adr = a;
    endtask
    task automatic answer(logic [31:0] d);
        m_ack = 1; m_dat = d;
    endtask
    task automatic settle();
        #1;
    endtask
    task automatic edge_();
        @(posedge clk);
        #1;
    endtask

    function automatic logic [31:0] mem_word(logic [31:0] a);
        return 32'hA000_0000 + a;
    endfunction

    // A load miss at latency 0 (the table of the data-cache refill): returns after the second
    // lookup cycle. The caller has set up nothing else; the fetch bus is idle.
    task automatic dload_fill(logic [31:0] a);
        logic [31:0] base;
        base = a & ~32'h3;
        idle_inputs(); load(a); settle();
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); load(a); answer(mem_word(base + b)); settle();
            edge_();
        end
    endtask

    initial begin
        done = 0; failed = 0; checks = 0; case_no = 0; case_name = "";
        idle_inputs();
        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;

        // ---- case 1: a data load miss and its refill at latency 0, then the second lookup ----
        // t: load of word 0x102 (line X). Not present: no answer, no memory request, ev_load_miss.
        // t+1 .. t+4: REFILL, words 0x100 .. 0x103 requested with continuation 0,1,1,1, each
        //   answered in its own cycle, the port granted to the data side; ev_refill, ev_beat,
        //   ev_grant_d and ev_port_load in each, ev_fill in t+4; no answer to the CPU.
        // t+5: second lookup: the word is answered, 0xA000_0102; ev_lookup_hit.
        case_no = 1; case_name = "data load miss, refill, second lookup";
        idle_inputs(); load(32'h102); settle();
        expect1("t ack", x_c_ack, 0);
        expect1("t memory cyc", x_m_cyc, 0);
        expect1("t data-cache request", x_dm_cyc, 0);
        expect_events("t", E_DLMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); load(32'h102); answer(mem_word(32'h100 + b)); settle();
            expect1("refill ack", x_c_ack, 0);
            expect1("refill request adr", x_m_adr, 32'h100 + b);
            expect1("refill request we", x_m_we, 0);
            expect1("refill request sel", x_m_sel, 4'b1111);
            expect1("refill request data", x_m_dat, 0);
            expect1("refill continuation", x_m_cont, b != 0);
            expect1("refill granted to the data side", o_gd, 1);
            expect1("refill answer to the data cache", x_d_ack, 1);
            expect1("refill word", x_d_dat, mem_word(32'h100 + b));
            if (b == 3) expect_events("t+4", E_DREFILL, E_DBEAT, E_DFILL, E_GRANTD, E_PLOAD);
            else        expect_events("t+1..3", E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
            edge_();
        end
        idle_inputs(); load(32'h102); settle();
        expect1("t+5 ack", x_c_ack, 1);
        expect1("t+5 word", x_c_dat, mem_word(32'h102));
        expect1("t+5 memory cyc", x_m_cyc, 0);
        expect_events("t+5", E_DLOOKUP);
        edge_();

        // ---- case 2: store hits write the selected lanes only ----
        // Line X is present. sw-style store, sel = 0101, data 0x11223344 to word 0x102: lanes 0 and
        // 2 take 0x44 and 0x22. The store is presented to the memory unchanged in its own cycle
        // (granted, answered at latency 0): ack, ev_store_hit, ev_grant_d, ev_port_store, and the
        // instruction cache's snoop sees it. Next cycle a load of 0x102 returns
        // 0xA000_0102 with lanes 0 and 2 replaced: byte 0: 0x02 -> 0x44, byte 2: 0x00 -> 0x22,
        // bytes 1 and 3 stay 0x01 and 0xA0: 0xA022_0144.
        case_no = 2; case_name = "store hit writes the selected lanes";
        idle_inputs(); store(32'h102, 4'b0101, 32'h1122_3344); answer(32'h0); settle();
        expect1("store ack", x_c_ack, 1);
        expect1("store request cyc", x_dm_cyc, 1);
        expect1("store request adr", x_dm_adr, 32'h102);
        expect1("store request we", x_dm_we, 1);
        expect1("store request sel", x_dm_sel, 4'b0101);
        expect1("store request data", x_dm_dat, 32'h1122_3344);
        expect1("store continuation", x_dm_cont, 0);
        expect1("memory we", x_m_we, 1);
        expect1("memory sel", x_m_sel, 4'b0101);
        expect1("memory data", x_m_dat, 32'h1122_3344);
        expect_events("store hit", E_DSHIT, E_GRANTD, E_PSTORE);
        edge_();
        idle_inputs(); load(32'h102); settle();
        expect1("load after the store: ack", x_c_ack, 1);
        expect1("load after the store: word", x_c_dat, 32'hA022_0144);
        expect_events("load", E_DLOOKUP);
        edge_();

        // ---- case 3: a store miss changes nothing and allocates nothing ----
        // Store to word 0x105 (line Y, not present), sel 1111: presented and answered at latency 0,
        // ev_store_miss. The next cycle's load of 0x105 misses (ev_load_miss, no ack).
        case_no = 3; case_name = "store miss allocates nothing";
        idle_inputs(); store(32'h105, 4'b1111, 32'hCAFE_F00D); answer(32'h0); settle();
        expect1("store miss ack", x_c_ack, 1);
        expect_events("store miss", E_DSMISS, E_GRANTD, E_PSTORE);
        edge_();
        idle_inputs(); load(32'h105); settle();
        expect1("load after a store miss: ack", x_c_ack, 0);
        expect_events("load after a store miss", E_DLMISS);
        edge_();
        // finish the refill of line Y so that the next cases start from a known state: lines X
        // and Y both present, X holding 0xA022_0144 at word 0x102
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); load(32'h105); answer(mem_word(32'h104 + b)); settle();
            edge_();
        end
        idle_inputs(); load(32'h105); settle();
        expect1("second lookup after the store miss: word", x_c_dat, mem_word(32'h105));
        edge_();

        // ---- case 4: a store that waits (the port is busy) is a store wait in every cycle ----
        // Start an instruction refill (fetch of word 0x108, instruction line Z, absent) at latency
        // with the memory not answering: t0 fetch miss. t1.. the refill holds the port. A store to
        // word 0x100 (present) presented in t1 while the refill is granted: no ack, ev_store_wait,
        // ev_wait_d, and (since the refill block is not interrupted) the store waits until the
        // refill's second-lookup cycle. A load hit to word 0x104 is answered meanwhile.
        case_no = 4; case_name = "store waits behind an instruction refill, load hit meanwhile";
        idle_inputs(); fetch(32'h108); settle();
        expect1("fetch miss ack", x_f_ack, 0);
        expect_events("fetch miss", E_IMISS);
        edge_();
        // t1: refill beat 0 granted (no data request yet), memory answers
        idle_inputs(); fetch(32'h108); answer(mem_word(32'h108)); settle();
        expect1("refill beat 0 granted", o_gi, 1);
        expect1("refill beat 0 adr", x_m_adr, 32'h108);
        expect1("refill beat 0 continuation", x_m_cont, 0);
        expect_events("t1", E_IREFILL, E_IBEAT, E_GRANTI);
        edge_();
        // t2: refill beat 1; the CPU presents a store (present line X): it waits
        idle_inputs(); fetch(32'h108); store(32'h100, 4'b0010, 32'h0000_7700); answer(mem_word(32'h109)); settle();
        expect1("t2 store ack", x_c_ack, 0);
        expect1("t2 store request presented", x_dm_cyc, 1);
        expect1("t2 data side granted", o_gd, 0);
        expect1("t2 refill continuation", x_m_cont, 1);
        expect_events("t2", E_IREFILL, E_IBEAT, E_GRANTI, E_WAITD, E_DSWAIT);
        edge_();
        // t3: beat 2; a load is not possible (one request at a time), the store still waits
        idle_inputs(); fetch(32'h108); store(32'h100, 4'b0010, 32'h0000_7700); answer(mem_word(32'h10A)); settle();
        expect_events("t3", E_IREFILL, E_IBEAT, E_GRANTI, E_WAITD, E_DSWAIT);
        edge_();
        // t4: beat 3 (last): fill; the store still waits
        idle_inputs(); fetch(32'h108); store(32'h100, 4'b0010, 32'h0000_7700); answer(mem_word(32'h10B)); settle();
        expect_events("t4", E_IREFILL, E_IBEAT, E_IFILL, E_GRANTI, E_WAITD, E_DSWAIT);
        edge_();
        // t5: the instruction cache's second lookup (hit, fetch of 0x108), no request; the store is
        // granted at once (data side first) and answered: ack, store hit, and the snoop sees a
        // store to word 0x100, whose instruction line is absent (instruction lines X' and Z; X' =
        // 0x100 is not valid: no invalidation)
        idle_inputs(); fetch(32'h108); store(32'h100, 4'b0010, 32'h0000_7700); answer(32'h0); settle();
        expect1("t5 fetch ack", x_f_ack, 1);
        expect1("t5 fetch word", x_f_dat, mem_word(32'h108));
        expect1("t5 store ack", x_c_ack, 1);
        expect_events("t5", E_IHIT, E_DSHIT, E_GRANTD, E_PSTORE);
        edge_();

        // ---- case 5: the snoop: a store hit to a word of a valid instruction line invalidates it ----
        // The instruction line Z (words 0x108-0x10B) is valid. Store to word 0x109 (data line Z: set
        // 0, absent in the data cache, which holds X in set 0): a store miss, acknowledged: the snoop
        // finds the instruction line valid with an equal tag: ev_snoop_inval, and the next fetch
        // of 0x108 misses.
        case_no = 5; case_name = "snoop invalidates the stored line";
        idle_inputs(); store(32'h109, 4'b0001, 32'h0000_00AA); answer(32'h0); settle();
        expect_events("store to a fetched line", E_DSMISS, E_GRANTD, E_PSTORE, E_SNOOP);
        edge_();
        idle_inputs(); fetch(32'h108); settle();
        expect1("fetch after the snoop: ack", x_f_ack, 0);
        expect_events("fetch after the snoop", E_IMISS);
        edge_();
        // the refill runs to its end at latency 0 (4 cycles) so that the next case starts clean
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); fetch(32'h108); answer(mem_word(32'h108 + b)); settle();
            edge_();
        end
        idle_inputs(); fetch(32'h108); settle();
        edge_();

        // ---- case 6: both misses in one cycle (the table of the coincident miss) ----
        // t: fetch of 0x104 (instruction line Y, invalid) and a load of 0x10C (data line W, set 1:
        // the set holds Y, so this is a conflict miss). Neither cache requests in t (ev_miss,
        // ev_load_miss, no memory request).
        // t+1 .. t+4: both request; the data cache wins the free port for its 4 beats; the
        //   instruction refill waits (ev_wait_i). t+5: the data cache's second lookup (load
        //   answered, no request); the instruction refill is granted for its beat 0.
        case_no = 6; case_name = "both misses in one cycle";
        idle_inputs(); fetch(32'h104); load(32'h10C); settle();
        expect1("t memory cyc", x_m_cyc, 0);
        expect_events("t", E_IMISS, E_DLMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); fetch(32'h104); load(32'h10C); answer(mem_word(32'h10C + b)); settle();
            expect1("data refill wins: gd", o_gd, 1);
            expect1("data refill wins: gi", o_gi, 0);
            expect1("data refill adr", x_m_adr, 32'h10C + b);
            expect1("data refill continuation", x_m_cont, b != 0);
            if (b == 3) expect_events("t+4", E_IREFILL, E_WAITI, E_DREFILL, E_DBEAT, E_DFILL, E_GRANTD, E_PLOAD);
            else        expect_events("t+1..3", E_IREFILL, E_WAITI, E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
            edge_();
        end
        idle_inputs(); fetch(32'h104); load(32'h10C); answer(mem_word(32'h104)); settle();
        expect1("t+5 load answered", x_c_ack, 1);
        expect1("t+5 load word", x_c_dat, mem_word(32'h10C));
        expect1("t+5 data cache requests", x_dm_cyc, 0);
        expect1("t+5 instruction refill granted", o_gi, 1);
        expect1("t+5 instruction refill adr", x_m_adr, 32'h104);
        expect_events("t+5", E_IREFILL, E_IBEAT, E_GRANTI, E_DLOOKUP);
        edge_();
        // let the instruction refill end (3 more beats, last in the 4th cycle), then idle
        for (int b = 1; b < 4; b++) begin
            idle_inputs(); fetch(32'h104); answer(mem_word(32'h104 + b)); settle();
            edge_();
        end

        // ---- case 7: reset in the middle of a data refill ----
        // Load of word 0x108 (line Z, set 0: conflicts with the present line X). t: miss. t+1: beat
        // 0 answered. t+2: reset cycle (rst = 1): outputs follow the equations (the refill still
        // requests beat 1), events are all 0; after it the data cache is in LOOKUP with all lines
        // invalid, including line W (set 1), which was valid before: a load of 0x10C misses
        // (ev_load_miss, no answer, no memory request); its refill runs to the end and the second
        // lookup answers the word. Then the load of 0x100 (line X, set 0) misses as well and
        // starts its refill at word 0.
        case_no = 7; case_name = "reset drops a data refill and clears the valid bits";
        idle_inputs(); load(32'h108); settle();
        expect_events("t", E_DLMISS);
        edge_();
        idle_inputs(); load(32'h108); answer(mem_word(32'h108)); settle();
        edge_();
        idle_inputs(); load(32'h108); rst = 1; settle();
        expect1("reset cycle: refill still requests", x_dm_cyc, 1);
        expect1("reset cycle: refill beat 1 adr", x_m_adr, 32'h109);
        expect_events("reset cycle");
        edge_();
        idle_inputs(); load(32'h10C); settle();
        expect1("after the reset: line W is not valid", x_c_ack, 0);
        expect_events("after the reset", E_DLMISS);
        expect1("after the reset: no memory request", x_m_cyc, 0);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); load(32'h10C); answer(mem_word(32'h10C + b)); settle();
            expect1("refill of W: adr", x_m_adr, 32'h10C + b);
            edge_();
        end
        idle_inputs(); load(32'h10C); settle();
        expect1("second lookup after the reset: ack", x_c_ack, 1);
        expect1("second lookup after the reset: word", x_c_dat, mem_word(32'h10C));
        edge_();
        idle_inputs(); load(32'h100); settle();
        expect1("after the reset: line X is not valid", x_c_ack, 0);
        expect_events("load of X", E_DLMISS);
        expect1("load of X: no memory request", x_m_cyc, 0);
        edge_();
        idle_inputs(); load(32'h100); answer(mem_word(32'h100)); settle();
        expect1("refill restarts at word 0", x_m_adr, 32'h100);
        expect_events("restart", E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
        edge_();

        // ---- case 8: an I/O-like cycle (cyc without stb) and a stb without cyc do nothing ----
        case_no = 8; case_name = "cyc without stb is not a request";
        idle_inputs();
        // finish the refill of case 7 first (3 beats)
        for (int b = 1; b < 4; b++) begin
            idle_inputs(); load(32'h100); answer(mem_word(32'h100 + b)); settle();
            edge_();
        end
        idle_inputs(); load(32'h100); settle();          // second lookup: hit
        edge_();
        idle_inputs(); c_cyc = 1; c_stb = 0; c_adr = 32'h100; c_we = 1; settle();
        expect1("I/O-like: ack", x_c_ack, 0);
        expect1("I/O-like: request", x_dm_cyc, 0);
        expect_events("I/O-like");
        idle_inputs(); c_cyc = 0; c_stb = 1; c_adr = 32'h100; c_we = 0; settle();
        expect1("stb without cyc: ack", x_c_ack, 0);
        expect_events("stb without cyc");
        edge_();

        // ---- case 9: a load hit is answered while the instruction refill holds the port ----
        // Line X present. Fetch miss (instruction line Y: 0x104), then a load of 0x101 in the
        // first granted cycle: answered at once (ev_lookup_hit), the refill's beat still granted.
        case_no = 9; case_name = "load hit during an instruction refill";
        idle_inputs(); fetch(32'h104); settle();
        edge_();
        idle_inputs(); fetch(32'h104); load(32'h101); answer(mem_word(32'h104)); settle();
        expect1("load hit ack", x_c_ack, 1);
        expect1("load hit word", x_c_dat, mem_word(32'h101));
        expect1("refill granted", o_gi, 1);
        expect_events("load hit during a refill", E_IREFILL, E_IBEAT, E_GRANTI, E_DLOOKUP);
        edge_();
        for (int b = 1; b < 4; b++) begin
            idle_inputs(); fetch(32'h104); answer(mem_word(32'h104 + b)); settle();
            edge_();
        end

        // ---- case 10: a data load miss during an instruction refill waits for the port ----
        // Fetch miss on instruction line Z (0x108). In the refill's second cycle a load of word
        // 0x105 (data line Y, set 1, which holds line W: a conflict miss) misses (ev_load_miss); from the next
        // cycle its refill requests and waits for the instruction refill (ev_wait_d), which ends in
        // its 4th cycle; the data refill is granted in the cycle after that (the instruction
        // cache's second lookup).
        case_no = 10; case_name = "data load miss waits for an instruction refill";
        idle_inputs(); fetch(32'h108); settle();
        edge_();                                                    // t0: instruction miss
        idle_inputs(); fetch(32'h108); answer(mem_word(32'h108)); settle();
        edge_();                                                    // t1: beat 0
        idle_inputs(); fetch(32'h108); load(32'h105); answer(mem_word(32'h109)); settle();
        expect_events("t2", E_IREFILL, E_IBEAT, E_GRANTI, E_DLMISS);
        edge_();                                                    // t2: beat 1, load misses
        idle_inputs(); fetch(32'h108); load(32'h105); answer(mem_word(32'h10A)); settle();
        expect1("t3 data refill requests", x_dm_cyc, 1);
        expect1("t3 data refill waits", o_gd, 0);
        expect_events("t3", E_IREFILL, E_IBEAT, E_GRANTI, E_WAITD, E_DREFILL);
        edge_();                                                    // t3: beat 2
        idle_inputs(); fetch(32'h108); load(32'h105); answer(mem_word(32'h10B)); settle();
        expect_events("t4", E_IREFILL, E_IBEAT, E_IFILL, E_GRANTI, E_WAITD, E_DREFILL);
        edge_();                                                    // t4: beat 3, fill
        idle_inputs(); fetch(32'h108); load(32'h105); answer(mem_word(32'h104)); settle();
        expect1("t5 data refill granted", o_gd, 1);
        expect1("t5 data refill adr", x_m_adr, 32'h104);
        expect_events("t5", E_IHIT, E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);

        // ---- case 11: an instruction miss during a data refill waits for its second lookup ----
        // A reset cycle first (every line invalid, both caches idle). t: load of 0x104 (data line Y)
        // misses. t+1: beat 0 of the data refill. t+2: beat 1; the fetch of 0x108 misses in this
        // cycle (no request from the instruction cache yet). t+3, t+4: the data refill holds the
        // port for its beats 2 and 3 (data first, never interrupted) while the instruction refill
        // requests and waits (ev_wait_i). t+5: the data cache's second lookup (the load is
        // answered, no request); the instruction refill is granted for its beat 0.
        case_no = 11; case_name = "instruction miss during a data refill";
        idle_inputs(); rst = 1; settle();
        edge_();
        idle_inputs(); load(32'h104); settle();
        expect_events("t", E_DLMISS);
        edge_();
        idle_inputs(); load(32'h104); answer(mem_word(32'h104)); settle();
        expect_events("t+1", E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
        edge_();
        idle_inputs(); load(32'h104); fetch(32'h108); answer(mem_word(32'h105)); settle();
        expect1("t+2 data refill beat 1 adr", x_m_adr, 32'h105);
        expect1("t+2 continuation", x_m_cont, 1);
        expect_events("t+2", E_IMISS, E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
        edge_();
        idle_inputs(); load(32'h104); fetch(32'h108); answer(mem_word(32'h106)); settle();
        expect1("t+3 data refill keeps the port", o_gd, 1);
        expect1("t+3 instruction refill waits", o_gi, 0);
        expect_events("t+3", E_IREFILL, E_WAITI, E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
        edge_();
        idle_inputs(); load(32'h104); fetch(32'h108); answer(mem_word(32'h107)); settle();
        expect_events("t+4", E_IREFILL, E_WAITI, E_DREFILL, E_DBEAT, E_DFILL, E_GRANTD, E_PLOAD);
        edge_();
        idle_inputs(); load(32'h104); fetch(32'h108); answer(mem_word(32'h108)); settle();
        expect1("t+5 load answered", x_c_ack, 1);
        expect1("t+5 load word", x_c_dat, mem_word(32'h104));
        expect1("t+5 instruction refill granted", o_gi, 1);
        expect1("t+5 instruction refill adr", x_m_adr, 32'h108);
        expect1("t+5 instruction refill continuation", x_m_cont, 0);
        expect_events("t+5", E_IREFILL, E_IBEAT, E_GRANTI, E_DLOOKUP);
        edge_();

        // ---- case 12: a fetch hit and a store in one cycle, and the snoop ----
        // Finish the instruction refill of line Z (3 more beats). The data cache holds line Y
        // (set 1) and nothing in set 0. First a store to 0x105 (line Y: a store hit) in the cycle
        // in which the fetch of 0x109 hits (instruction line Z): the fetch gets the old word,
        // mem_word(0x109), and the snoop finds no instruction line Y: no invalidation. Then a
        // store to 0x109 (data line Z, absent: a store miss) in the cycle in which the fetch of
        // 0x108 hits: the snoop finds the instruction line valid with an equal tag (ev_snoop_inval)
        // and the next fetch of 0x108 misses.
        case_no = 12; case_name = "fetch hit and store in one cycle, snoop";
        for (int b = 1; b < 4; b++) begin
            idle_inputs(); fetch(32'h108); answer(mem_word(32'h108 + b)); settle();
            edge_();
        end
        idle_inputs(); fetch(32'h109); store(32'h105, 4'b1111, 32'h0123_4567); answer(32'h0); settle();
        expect1("fetch hit ack", x_f_ack, 1);
        expect1("fetch hit old word", x_f_dat, mem_word(32'h109));
        expect1("store hit ack", x_c_ack, 1);
        expect_events("store to another tag", E_IHIT, E_DSHIT, E_GRANTD, E_PSTORE);
        edge_();
        idle_inputs(); fetch(32'h108); store(32'h109, 4'b0001, 32'h0000_0099); answer(32'h0); settle();
        expect1("fetch hit ack", x_f_ack, 1);
        expect1("fetch hit word", x_f_dat, mem_word(32'h108));
        expect_events("store to the fetched line", E_IHIT, E_DSMISS, E_GRANTD, E_PSTORE, E_SNOOP);
        edge_();
        idle_inputs(); fetch(32'h108); settle();
        expect1("fetch after the snoop", x_f_ack, 0);
        expect_events("fetch after the snoop", E_IMISS);
        edge_();

        // ---- case 13: no hit under miss for fetches, and a load hit does not snoop ----
        // The instruction refill of line Z (started at the end of case 12) runs to its end and its
        // second lookup hits. Then line Y (0x104) is fetched in: miss, four beats, hit. A load of
        // 0x105 (a data hit: line Y, and the instruction cache holds line Y with an equal tag)
        // is answered without a snoop: the word is 0x01234567 (the store of case 12), and the next
        // fetch of 0x104 still hits. Then a fetch of 0x100 (instruction line X, set 0, which holds
        // Z) misses; in the refill's first cycle the fetch address changes to 0x104, a valid
        // line, and still nothing is answered (no hit under miss); at the last beat the presented
        // address is not in the refilled line: ev_abandoned.
        case_no = 13; case_name = "no hit under miss, load hit does not snoop";
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); fetch(32'h108); answer(mem_word(32'h108 + b)); settle();
            if (b == 3) expect_events("Z last beat", E_IREFILL, E_IBEAT, E_IFILL, E_GRANTI);
            else        expect_events("Z beat", E_IREFILL, E_IBEAT, E_GRANTI);
            edge_();
        end
        idle_inputs(); fetch(32'h108); settle();
        expect1("Z second lookup", x_f_ack, 1);
        expect_events("Z second lookup", E_IHIT);
        edge_();
        idle_inputs(); fetch(32'h104); settle();
        expect1("fetch of Y misses", x_f_ack, 0);
        expect_events("fetch of Y", E_IMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); fetch(32'h104); answer(mem_word(32'h104 + b)); settle();
            edge_();
        end
        idle_inputs(); fetch(32'h104); settle();
        expect1("Y second lookup", x_f_ack, 1);
        edge_();
        idle_inputs(); load(32'h105); settle();
        expect1("load hit of 0x105", x_c_ack, 1);
        expect1("load hit word", x_c_dat, 32'h0123_4567);
        expect_events("load hit, no snoop", E_DLOOKUP);
        edge_();
        idle_inputs(); fetch(32'h104); settle();
        expect1("Y still valid after the load hit", x_f_ack, 1);
        expect_events("fetch of Y", E_IHIT);
        edge_();
        idle_inputs(); fetch(32'h100); settle();
        expect1("fetch of X misses", x_f_ack, 0);
        expect_events("fetch of X", E_IMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); fetch(32'h104); answer(mem_word(32'h100 + b)); settle();
            expect1("no hit under miss", x_f_ack, 0);
            expect1("refill of X: adr", x_m_adr, 32'h100 + b);
            if (b == 3) expect_events("X last beat", E_IREFILL, E_IBEAT, E_IFILL, E_IABAND, E_GRANTI);
            else        expect_events("X beat", E_IREFILL, E_IBEAT, E_GRANTI);
            edge_();
        end
        idle_inputs(); fetch(32'h104); settle();
        expect1("Y second lookup after X", x_f_ack, 1);
        edge_();

        // ---- case 14: a request that changes while the data cache refills ----
        // (the free mode of the bench; the CPU itself never does this). Data set 0 is empty, set 1
        // holds line Y. A load of 0x100 misses. In the refill's first cycle the presented request
        // becomes a load of 0x105, a present line: nothing is answered (no hit under miss), and the
        // refill goes on with line X (its address does not follow the presented request). After the
        // last beat the second lookup answers the load of 0x105: 0x01234567.
        case_no = 14; case_name = "request changes during a data refill";
        idle_inputs(); load(32'h100); settle();
        expect_events("load of X", E_DLMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); load(32'h105); answer(mem_word(32'h100 + b)); settle();
            expect1("no hit under miss", x_c_ack, 0);
            expect1("refill of X: adr", x_m_adr, 32'h100 + b);
            if (b == 3) expect_events("refill last beat", E_DREFILL, E_DBEAT, E_DFILL, E_GRANTD, E_PLOAD);
            else        expect_events("refill beat", E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD);
            edge_();
        end
        idle_inputs(); load(32'h105); settle();
        expect1("second lookup of the changed request", x_c_ack, 1);
        expect1("second lookup word", x_c_dat, 32'h0123_4567);
        expect_events("second lookup", E_DLOOKUP);
        edge_();

        // ---- case 15: a store presented while the data cache refills waits ----
        // (also the free mode of the bench). A load of 0x108 (line Z, set 0: a conflict miss).
        // In the refill the presented request becomes a store to 0x105 (present line Y). The
        // store is not presented to the memory (the refill's reads are), not answered, and counts as
        // a store wait in every refill cycle (the event is "a store presented and not answered");
        // after the last beat it is presented, granted and answered at once: a store hit, which
        // the instruction cache, holding line Y since case 13, snoops.
        case_no = 15; case_name = "store presented during a data refill";
        idle_inputs(); load(32'h108); settle();
        expect_events("load of Z", E_DLMISS);
        edge_();
        for (int b = 0; b < 4; b++) begin
            idle_inputs(); store(32'h105, 4'b0001, 32'h0000_00AA); answer(mem_word(32'h108 + b)); settle();
            expect1("store waits", x_c_ack, 0);
            expect1("refill request, not the store", x_dm_we, 0);
            expect1("refill adr", x_m_adr, 32'h108 + b);
            if (b == 3) expect_events("last beat", E_DREFILL, E_DBEAT, E_DFILL, E_GRANTD, E_PLOAD, E_DSWAIT);
            else        expect_events("beat", E_DREFILL, E_DBEAT, E_GRANTD, E_PLOAD, E_DSWAIT);
            edge_();
        end
        idle_inputs(); store(32'h105, 4'b0001, 32'h0000_00AA); answer(32'h0); settle();
        expect1("store accepted after the refill", x_c_ack, 1);
        expect1("store presented to the memory", x_m_we, 1);
        expect_events("store hit and snoop (the instruction cache holds line Y)", E_DSHIT, E_GRANTD, E_PSTORE, E_SNOOP);
        edge_();

        n_checks = checks;
        done = 1;
    end
endmodule

// =============================================================================================
// One configuration: the design, its environment, the reference model and the checks
// =============================================================================================

module dcache_bench_env #(
    parameter string       NAME         = "",
    parameter int unsigned IBYTES       = 512,
    parameter int unsigned DBYTES       = 512,
    parameter int unsigned LINE_BYTES   = 16,
    parameter bit   [31:0] WINDOW_START = 32'h0001_0000,
    parameter bit   [31:0] WINDOW_WORDS = 32'h0000_2000,
    parameter bit          SYSTEM       = 0,   // 1: the real memory wrapper and RAM
    parameter int unsigned NUMBER       = 0    // separates the configurations' random sequences
) (
    input  logic    clk,
    output bit      done,           // the run of this configuration is over
    output bit      selected,       // this configuration runs (+only)
    output longint  cycles_run,
    output bit      coverage_short  // a coverage target was not met
);
    import dcache_bench_pkg::*;

    localparam int unsigned LW    = LINE_BYTES / 4;
    localparam int unsigned O     = $clog2(LW);
    localparam int unsigned ISETS = IBYTES / LINE_BYTES;
    localparam int unsigned II    = $clog2(ISETS);
    localparam int unsigned DSETS = DBYTES / LINE_BYTES;
    localparam int unsigned DI    = $clog2(DSETS);
    localparam bit   [31:0] WS    = WINDOW_START;
    localparam bit   [31:0] WW    = WINDOW_WORDS;
    localparam bit   [31:0] WEND  = WINDOW_START + WINDOW_WORDS;
    localparam int unsigned ICW   = IBYTES / 4;                // instruction cache size in words
    localparam int unsigned DCW   = DBYTES / 4;                // data cache size in words
    localparam int unsigned TOP   = $clog2(WEND) - 1;          // highest address bit inside the window
    localparam int          NPROF = SYSTEM ? 1 : 5;
    localparam int unsigned K_OLDER = 3;

    // ---------------------------------------------------------------------------------------
    // Run options
    // ---------------------------------------------------------------------------------------
    longint unsigned seg_cycles;     // cycles per memory profile
    longint unsigned total_cycles;
    bit              compare_on;
    bit              bounds_on;      // the answer bounds are checked (also with +compare=bounds)
    string           negative;
    bit              inject_here;
    int unsigned     seed;

    // Memory profiles of the memory model (the system configuration uses the wrapper's options)
    int          prof_rd_min [5] = '{0, 2, 1,  1,  8};
    int          prof_rd_max [5] = '{0, 2, 8, 64, 24};
    int          prof_wr_min [5] = '{0, 2, 1,  1,  1};
    int          prof_wr_max [5] = '{0, 2, 8, 64,  4};
    int          prof_beat   [5] = '{-1, -1, -1, -1, 0};
    string       prof_name   [5] = '{"latency 0", "latency 2", "latency 1-8", "latency 1-64",
                                     "DRAM-like reads 8-24 writes 1-4 bursts"};
    int          profile, profile_start;
    int          rd_min, rd_max, wr_min, wr_max, beat_lat;     // the profile in use
    int          sys_rd_max, sys_wr_max, sys_beat;             // the wrapper's, system only
    int unsigned cost_r, cost_wr1;                              // R and WR + 1 of the profile in use
    int unsigned bound_a, bound_b;                              // the bounds (a) and (b) of the profile

    function automatic bit name_listed(string list, string name);
        int start = 0;
        for (int k = 0; k <= list.len(); k++) begin
            if (k == list.len() || list.getc(k) == ",") begin
                if (k > start && list.substr(start, k - 1) == name) return 1;
                start = k + 1;
            end
        end
        return 0;
    endfunction

    initial begin
        string text;
        longint unsigned n;
        seed       = 1;
        n          = 1000000;
        compare_on = 1;
        bounds_on  = 1;
        negative   = "";
        selected   = 1;
        void'($value$plusargs("seed=%d", seed));
        if ($value$plusargs("cycles=%d", n) && n < 100)
            $fatal(1, "DCACHE BENCH: +cycles=%0d: give at least 100", n);
        seg_cycles = n;
        if ($test$plusargs("compare=0")) begin
            compare_on = 0;
            bounds_on  = 0;
        end
        if ($test$plusargs("compare=bounds")) compare_on = 0;
        if ($value$plusargs("negative=%s", text)) begin
            if (text != "d-request-change" && text != "d-refill-err" && text != "d-store-err" &&
                text != "d-out-of-window" && text != "ack-err" && text != "spontaneous-answer")
                $fatal(1, "DCACHE BENCH: +negative=%s: give d-request-change, d-refill-err, d-store-err, d-out-of-window, ack-err or spontaneous-answer", text);
            negative = text;
        end
        if ($value$plusargs("only=%s", text)) selected = name_listed(text, NAME);
        if ($test$plusargs("selftest")) selected = 0;
        inject_here   = negative != "" && NAME == "i512-d512-line16-ram";
        profile_start = inject_here ? 1 : 0;     // inject under latency 2 (requests that wait)
        total_cycles  = SYSTEM ? seg_cycles : seg_cycles * NPROF;
    end

    // ---------------------------------------------------------------------------------------
    // Buses, the design under test, the reference model
    // ---------------------------------------------------------------------------------------
    logic rst;

    wishbone_interface fetch_bus ();
    wishbone_interface data_bus ();         // interconnect slave 0: the CPU's RAM-window data port
    wishbone_interface icache_mem ();
    wishbone_interface dcache_mem ();
    wishbone_interface memory_port ();
    logic icache_mem_cont, dcache_mem_cont, memory_port_cont;

    logic snoop_store;
    assign snoop_store = data_bus.cyc && data_bus.stb && data_bus.we && data_bus.ack;

    logic ev_hit, ev_miss, ev_beat, ev_fill, ev_abandoned, ev_snoop_inval, ev_refill;
    logic ev_wait_i, ev_wait_d, ev_grant_i, ev_grant_d, ev_port_load, ev_port_store;
    logic ev_d_lookup_hit, ev_d_load_miss, ev_d_beat, ev_d_fill, ev_d_store_hit, ev_d_store_miss;
    logic ev_d_store_wait, ev_d_refill;
    logic [NEV-1:0] dut_ev;
    assign dut_ev = {ev_d_refill, ev_d_store_wait, ev_d_store_miss, ev_d_store_hit, ev_d_fill,
                     ev_d_beat, ev_d_load_miss, ev_d_lookup_hit,
                     ev_refill, ev_port_store, ev_port_load, ev_grant_d, ev_grant_i, ev_wait_d,
                     ev_wait_i, ev_snoop_inval, ev_abandoned, ev_fill, ev_beat, ev_miss, ev_hit};

    icache #(
        .BYTES        (IBYTES),
        .LINE_BYTES   (LINE_BYTES),
        .WINDOW_START (WINDOW_START),
        .WINDOW_WORDS (WINDOW_WORDS)
    ) icache (
        .clk            (clk),
        .rst            (rst),
        .cpu            (fetch_bus.slave),
        .mem            (icache_mem.master),
        .mem_cont       (icache_mem_cont),
        .snoop_store    (snoop_store),
        .snoop_adr      (data_bus.adr),
        .ev_hit         (ev_hit),
        .ev_miss        (ev_miss),
        .ev_beat        (ev_beat),
        .ev_fill        (ev_fill),
        .ev_abandoned   (ev_abandoned),
        .ev_snoop_inval (ev_snoop_inval),
        .ev_refill      (ev_refill)
    );

    dcache #(
        .BYTES        (DBYTES),
        .LINE_BYTES   (LINE_BYTES),
        .WINDOW_START (WINDOW_START),
        .WINDOW_WORDS (WINDOW_WORDS)
    ) dcache (
        .clk             (clk),
        .rst             (rst),
        .cpu             (data_bus.slave),
        .mem             (dcache_mem.master),
        .mem_cont        (dcache_mem_cont),
        .ev_lookup_hit   (ev_d_lookup_hit),
        .ev_load_miss    (ev_d_load_miss),
        .ev_beat         (ev_d_beat),
        .ev_fill         (ev_d_fill),
        .ev_store_hit    (ev_d_store_hit),
        .ev_store_miss   (ev_d_store_miss),
        .ev_store_wait   (ev_d_store_wait),
        .ev_refill       (ev_d_refill)
    );

    mem_arbiter mem_arbiter (
        .clk           (clk),
        .rst           (rst),
        .data          (dcache_mem.slave),
        .data_cont     (dcache_mem_cont),
        .irefill       (icache_mem.slave),
        .irefill_cont  (icache_mem_cont),
        .mem           (memory_port.master),
        .mem_cont      (memory_port_cont),
        .ev_wait_i     (ev_wait_i),
        .ev_wait_d     (ev_wait_d),
        .ev_grant_i    (ev_grant_i),
        .ev_grant_d    (ev_grant_d),
        .ev_port_load  (ev_port_load),
        .ev_port_store (ev_port_store)
    );

    logic        x_f_ack, x_f_err, x_c_ack, x_c_err, x_i_cyc, x_i_stb, x_i_cont;
    logic        x_dm_cyc, x_dm_stb, x_dm_we, x_dm_cont, x_m_cyc, x_m_stb, x_m_we, x_m_cont;
    logic        x_d_ack, x_d_err, x_r_ack, x_r_err;
    logic [31:0] x_f_dat, x_c_dat, x_i_adr, x_dm_adr, x_dm_dat, x_m_adr, x_m_dat, x_d_dat, x_r_dat;
    logic  [3:0] x_dm_sel, x_m_sel;
    logic [NEV-1:0] x_ev;
    logic        o_irefill, o_drefill, o_gd, o_gi, o_snoop, o_dpresent, o_store;

    memsys_ref #(
        .IBYTES       (IBYTES),
        .DBYTES       (DBYTES),
        .LINE_BYTES   (LINE_BYTES),
        .WINDOW_START (WINDOW_START),
        .WINDOW_WORDS (WINDOW_WORDS)
    ) model (
        .clk (clk), .rst (rst),
        .f_cyc (fetch_bus.cyc), .f_stb (fetch_bus.stb), .f_adr (fetch_bus.adr),
        .c_cyc (data_bus.cyc), .c_stb (data_bus.stb), .c_we (data_bus.we), .c_adr (data_bus.adr),
        .c_sel (data_bus.sel), .c_dat (data_bus.dat_mosi),
        .m_ack (memory_port.ack), .m_err (memory_port.err), .m_dat (memory_port.dat_miso),
        .x_f_ack, .x_f_err, .x_f_dat, .x_c_ack, .x_c_err, .x_c_dat,
        .x_i_cyc, .x_i_stb, .x_i_adr, .x_i_cont,
        .x_dm_cyc, .x_dm_stb, .x_dm_adr, .x_dm_we, .x_dm_sel, .x_dm_dat, .x_dm_cont,
        .x_m_cyc, .x_m_stb, .x_m_adr, .x_m_we, .x_m_sel, .x_m_dat, .x_m_cont,
        .x_d_ack, .x_d_err, .x_d_dat, .x_r_ack, .x_r_err, .x_r_dat, .x_ev,
        .o_irefill, .o_drefill, .o_gd, .o_gi, .o_snoop, .o_dpresent, .o_store
    );

    // ---------------------------------------------------------------------------------------
    // Memory: the bench's model of the window, which is also the reference for the checks
    // ---------------------------------------------------------------------------------------
    bit [31:0] mem [WINDOW_WORDS];     // the window's words, index = word address - WS

    // Words changed while the caches are held in reset (applied at the end of a reset cycle)
    bit [31:0] bd_idx [4];
    bit [31:0] bd_val [4];
    int        bd_n;

    // Memory model state (unused in the system configuration)
    bit          m_held, m_h_we, m_h_burst, m_in_block, m_last_we;
    bit   [31:0] m_h_adr, m_h_dat, m_last_adr;
    bit    [3:0] m_h_sel;
    int unsigned m_h_left, m_h_lat, m_pre_rd, m_pre_wr;
    // Fault injection of +negative (memory side)
    bit          inj_ack_err, inj_refill_err, inj_store_err, inj_spontaneous;

    // Combinational view of the memory's answer (both kinds of memory)
    bit          m_req, m_answer, m_burst, m_cur_burst, m_due;
    int unsigned m_cur_lat;

    generate
        if (!SYSTEM) begin : g_model
            bit          same, inwin, answer, ack, err;
            int unsigned lat_new, left;
            bit   [31:0] word;

            always_comb begin
                m_req   = memory_port.cyc && memory_port.stb;
                same    = m_held && memory_port.adr == m_h_adr && memory_port.sel == m_h_sel &&
                          memory_port.we == m_h_we && (!memory_port.we || memory_port.dat_mosi == m_h_dat);
                m_burst = beat_lat >= 0 && memory_port_cont && m_in_block && !memory_port.we &&
                          !m_last_we && memory_port.adr == m_last_adr + 1;
                lat_new = m_burst ? int'(beat_lat) : (memory_port.we ? m_pre_wr : m_pre_rd);
                left    = same ? m_h_left : lat_new;
                m_cur_lat   = same ? m_h_lat : lat_new;
                m_cur_burst = same ? m_h_burst : m_burst;
                m_due   = m_req && left == 0;              // the memory would answer, but for a reset
                answer  = m_req && left == 0 && !rst;      // nothing is answered in a reset cycle
                m_answer = answer;
                inwin   = memory_port.adr - WS < WW;
                word    = mem[inwin ? memory_port.adr - WS : 0];
                ack     = answer && inwin;
                err     = answer && !inwin;
                // faults of +negative
                if (inj_ack_err && answer && o_gd) begin ack = 1; err = 1; end
                if (inj_refill_err && answer && o_gd && o_drefill) begin ack = 0; err = 1; end
                if (inj_store_err && answer && o_gd && x_dm_we) begin ack = 0; err = 1; end
                if (inj_spontaneous && !m_req && !rst) ack = 1;
            end
            assign memory_port.ack      = ack;
            assign memory_port.err      = err;
            assign memory_port.dat_miso = (ack && !err && m_req && !memory_port.we) ? word : 32'h0;
        end
        else begin : g_system
            wishbone_interface ram_port ();
            wishbone_interface ram_idle ();
            logic clk_mem;
            assign clk_mem           = ~clk;
            assign ram_idle.cyc      = 1'b0;
            assign ram_idle.stb      = 1'b0;
            assign ram_idle.we       = 1'b0;
            assign ram_idle.adr      = 32'h0;
            assign ram_idle.sel      = 4'h0;
            assign ram_idle.dat_mosi = 32'h0;

            slow_memory #(
                .PORT  ("memory"),
                .INDEX (2)
            ) memory_delay (
                .clk        (clk),
                .rst        (rst),
                .master     (memory_port.slave),
                .memory     (ram_port.master),
                .block_cont (memory_port_cont)
            );

            wishbone_ram #(
                .ADDRESS (WINDOW_START),
                .SIZE    (WINDOW_WORDS)
            ) ram (
                .clk    (clk_mem),
                .rst    (rst),
                .port_a (ram_port.slave),
                .port_b (ram_idle.slave)
            );

            always_comb begin
                m_req       = memory_port.cyc && memory_port.stb;
                m_answer    = memory_port.ack || memory_port.err;
                m_burst     = 1'b0;
                m_cur_burst = 1'b0;
                m_cur_lat   = 0;
                m_due       = 1'b0;
            end

            // The RAM starts with the bench's memory (after its own initial block)
            initial begin
                #1;
                for (int k = 0; k < WINDOW_WORDS; k++) ram.memory[k] = mem[k];
                sys_rd_max = int'(memory_delay.rd_max);
                sys_wr_max = int'(memory_delay.wr_max);
                sys_beat   = memory_delay.beat_lat;
            end

            // Changes made while the caches are held in reset reach the RAM too
            always @(posedge clk)
                if (rst)
                    for (int k = 0; k < bd_n; k++) ram.memory[bd_idx[k]] <= bd_val[k];
        end
    endgenerate

    // ---------------------------------------------------------------------------------------
    // Random numbers (xorshift64), used only by the step below and the initial block
    // ---------------------------------------------------------------------------------------
    bit [63:0] rng;

    function automatic bit [31:0] rnd();
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        return rng[31:0] ^ rng[63:32];
    endfunction
    function automatic int unsigned below(int unsigned n);
        return (n == 0) ? 0 : rnd() % n;
    endfunction

    initial begin
        #0;
        rng = 64'h9E37_79B9_7F4A_7C15 ^ (64'(seed) << 20) ^ (64'(NUMBER + 1) * 64'hBF58_476D_1CE4_E5B9);
        if (rng == 0) rng = 1;
        for (int k = 0; k < WINDOW_WORDS; k++) mem[k] = rnd();
    end

    // ---------------------------------------------------------------------------------------
    // Address helpers
    // ---------------------------------------------------------------------------------------
    function automatic int unsigned iset_of(bit [31:0] a);
        return int'((a >> O) & (ISETS - 1));
    endfunction
    function automatic int unsigned dset_of(bit [31:0] a);
        return int'((a >> O) & (DSETS - 1));
    endfunction
    function automatic bit [29:0] line_of(bit [31:0] a);
        return 30'(a[29:0] >> O);
    endfunction
    function automatic bit in_window(bit [31:0] a);
        return a >= WS && a < WEND;
    endfunction
    // the in-window line address that the model holds in set s (valid or not)
    function automatic bit [31:0] model_iline_adr(int unsigned s);
        return (32'(model.tags[s]) << (O + II)) | (32'(s) << O);
    endfunction
    function automatic bit [31:0] model_dline_adr(int unsigned s);
        return (32'(model.dtags[s]) << (O + DI)) | (32'(s) << O);
    endfunction
    // the instruction cache holds the line of a (valid, equal tag)
    function automatic bit i_present(bit [31:0] a);
        return model.valid[iset_of(a)] && model_iline_adr(iset_of(a)) == (a & ~32'(LW - 1));
    endfunction
    function automatic bit d_present(bit [31:0] a);
        return model.dvalid[dset_of(a)] && model_dline_adr(dset_of(a)) == (a & ~32'(LW - 1));
    endfunction
    // a word of a line that the instruction cache holds, or 0 if it found none
    function automatic bit [31:0] cached_iword();
        for (int k = 0; k < 6; k++) begin
            int unsigned s = below(ISETS);
            if (model.valid[s]) return model_iline_adr(s) | below(LW);
        end
        return 0;
    endfunction
    // a word of a line that the data cache holds, or 0
    function automatic bit [31:0] cached_dword();
        for (int k = 0; k < 6; k++) begin
            int unsigned s = below(DSETS);
            if (model.dvalid[s]) return model_dline_adr(s) | below(LW);
        end
        return 0;
    endfunction
    // a word of a line that the data cache held and no longer holds (its tag is still there)
    function automatic bit [31:0] stale_dword();
        for (int k = 0; k < 6; k++) begin
            int unsigned s = below(DSETS);
            if (!model.dvalid[s] && in_window(model_dline_adr(s))) return model_dline_adr(s) | below(LW);
        end
        return 0;
    endfunction
    function automatic bit [31:0] window_word();
        return WS + below(WW);
    endfunction
    // a window word whose line the data cache does not hold, or 0
    function automatic bit [31:0] absent_dword();
        for (int k = 0; k < 12; k++) begin
            bit [31:0] a = window_word();
            if (!d_present(a)) return a;
        end
        return 0;
    endfunction
    function automatic bit [31:0] absent_iword();
        for (int k = 0; k < 12; k++) begin
            bit [31:0] a = window_word();
            if (!i_present(a)) return a;
        end
        return 0;
    endfunction
    // the out-of-window alias of address a whose bits above the window are cleared (or a itself)
    function automatic bit [31:0] alias_base(bit [31:0] a);
        return a & ((32'h1 << (TOP + 1)) - 1);
    endfunction

    // The data driver's request: a load or a store with the byte enables of lb/lh/lw and
    // sb/sh/sw and random data (the lanes a store does not select carry garbage, like the golden
    // CPU's rs2)
    typedef struct packed {
        bit [31:0] adr;
        bit        we;
        bit  [3:0] sel;
        bit [31:0] dat;
    } dreq_t;

    function automatic bit [3:0] store_sel();
        case (below(8))
            0, 1, 2: return 4'b1111;
            3:       return 4'b0011;
            4:       return 4'b1100;
            5, 6:    return 4'(1 << below(4));
            default: return 4'(rnd());
        endcase
    endfunction
    function automatic bit [3:0] load_sel();
        case (below(8))
            0, 1, 2: return 4'b1111;
            3:       return 4'b0011;
            4:       return 4'b1100;
            5, 6:    return 4'(1 << below(4));
            default: return 4'(rnd());
        endcase
    endfunction
    // data: a quarter of the words have a zero low byte (a fault keyed to the value would show)
    function automatic bit [31:0] data_word();
        bit [31:0] d = rnd();
        if (below(4) == 0) d[7:0] = 8'h00;
        if (below(16) == 0) d = 32'h0;
        return d;
    endfunction

    bit [31:0] last_da;              // the address of the data driver's previous request
    // the word an in-flight data refill or an instruction refill is working on, for the pick below

    function automatic dreq_t pick_request();
        dreq_t q;
        int    r;
        r = int'(below(100));
        q.adr = 0;
        if (r < 28)                       q.adr = cached_dword();
        else if (r < 38)                  q.adr = stale_dword();
        else if (r < 46 && model.drefilling) q.adr = (32'(model.dline) << O) | below(LW);
        else if (r < 60)                  q.adr = cached_iword();
        else if (r < 66 && in_window(fetch_bus.adr)) q.adr = (fetch_bus.adr & ~32'(LW - 1)) | below(LW);
        else if (r < 78 && last_da != 0) begin
            q.adr = (below(2) == 0) ? last_da + 32'(DCW) * (1 + below(3)) : last_da - 32'(DCW) * (1 + below(3));
            if (below(3) == 0) q.adr = (q.adr & ~32'(LW - 1)) | below(LW);
        end
        else if (r < 82)                  q.adr = (below(2) == 0) ? WS : WEND - 1;
        else if (r < 86)                  q.adr = last_da;
        if (q.adr == 0 || !in_window(q.adr)) q.adr = window_word();
        q.we  = below(100) < 45;
        q.sel = q.we ? store_sel() : load_sel();
        q.dat = data_word();
        return q;
    endfunction

    // ---------------------------------------------------------------------------------------
    // Coverage
    // ---------------------------------------------------------------------------------------
    localparam int NITEMS = 46;
    localparam int CV_REDIRECT_WAIT = 0, CV_SNOOP_REFILL_LINE = 1, CV_HIT_STORE_SAME_LINE = 2,
                   CV_STORE_SECOND_LOOKUP = 3, CV_CONSECUTIVE_STORES = 4, CV_STORE_EVICTED = 5,
                   CV_RESET_WAIT = 6, CV_MISS_AND_DATA = 7, CV_DATA_DURING_REFILL = 8,
                   CV_DATA_SECOND_LOOKUP = 9, CV_GRANT_AT_BOUND = 10, CV_CACHED_DURING_REFILL = 11,
                   CV_WINDOW_FIRST = 12, CV_WINDOW_LAST = 13, CV_BELOW_WINDOW = 14,
                   CV_ABOVE_WINDOW = 15, CV_ALIAS = 16, CV_HOT_LOOPS = 17, CV_ABANDONED = 18,
                   CV_BACK_TO_BACK_MISS = 19, CV_HIT_WHILE_DATA = 20, CV_LAT0 = 21, CV_LAT1 = 22,
                   CV_LAT8 = 23, CV_LAT64 = 24, CV_BURST = 25,
                   CV_DSTMISS_LOAD = 26, CV_DFILL_STORE = 27, CV_DCONFLICT = 28, CV_DALT = 29,
                   CV_BOTH_MISS = 30, CV_IMISS_IN_DREFILL = 31, CV_DMISS_IN_IREFILL = 32,
                   CV_DWINS = 33, CV_LOADHIT_IN_IREFILL = 34, CV_STORE_WAIT_IREFILL = 35,
                   CV_COINC = 36, CV_KO = 37, CV_DRESET_WAIT = 38, CV_DRESET_SECOND = 39,
                   CV_RESET_SW_UNGRANTED = 40, CV_RESET_SW_FIRST = 41, CV_RESET_SW_MID = 42,
                   CV_RESET_SW_LAST = 43, CV_A_EXACT = 44, CV_DLOAD_SECOND = 45;
    string cv_name [NITEMS] = '{
        "redirect while the instruction refill waits", "store to the instruction refill line before its grant",
        "fetch hit and store to its line in one cycle", "store to the filled instruction line in the second lookup",
        "stores to two cached instruction lines in consecutive cycles", "store to the line an instruction miss evicts, same cycle",
        "reset while the instruction refill waits", "instruction miss and data request in one cycle",
        "data request arriving during an instruction refill", "port transfer answered in the instruction second lookup",
        "instruction refill granted exactly at bound (b)", "lookup of a cached instruction line during a refill",
        "first word of the window", "last word of the window", "word just below the window",
        "word just above the window", "out-of-window alias of a cached instruction line",
        "switch between hot loops one instruction cache size apart", "abandoned instruction refill",
        "instruction miss in the second lookup", "instruction hit while a port transfer holds the port",
        "refill beat at latency 0", "refill beat at latency 1", "refill beat at latency 8",
        "refill beat at latency 64", "refill beat at the burst latency",
        "load miss right after a store miss to its line", "store hit right after a load miss filled its line",
        "load miss that evicts a valid data line", "two lines one data cache size apart, used alternately",
        "instruction miss and load miss in one cycle", "instruction miss during a data refill",
        "load miss during an instruction refill", "data refill granted over a waiting instruction refill",
        "load hit answered while an instruction refill holds the port",
        "store waiting behind an instruction refill",
        "coincident misses: instruction refill granted in cycle R + 1",
        "K_OLDER stores: instruction refill granted at K_OLDER * (WR + 1)",
        "reset while the data refill waits for the port", "reset in the data cache's second lookup",
        "reset while a store waits for the port", "reset in the first cycle of a granted store",
        "reset in a middle cycle of a granted store", "reset in the cycle a granted store would be answered",
        "load answered exactly at bound (a)", "load answered in the data cache's second lookup"};
    longint cv [NITEMS];
    bit     cv_na [NITEMS];
    longint cv_redirect_beat [LW];
    longint cv_reset_beat [LW];
    longint cv_dreset_beat [LW];
    longint cv_io_beat [LW];
    longint cv_sel_hit [16];
    longint cv_sel_miss [16];
    localparam int COVER_ITEM  = 20;
    localparam int COVER_EVENT = 1000;
    string ev_name [NEV] = '{"hit", "miss", "beat", "fill", "abandoned", "snoop_inval", "wait_i",
                             "wait_d", "grant_i", "grant_d", "port_load", "port_store", "refill",
                             "d_lookup_hit", "d_load_miss", "d_beat", "d_fill", "d_store_hit",
                             "d_store_miss", "d_store_wait", "d_refill"};
    longint dut_count [NEV];     // the design's event pulses over the run
    longint ref_count [NEV];     // the model's
    longint seg_count [NEV];     // the design's since the last reset
    longint seg_load_acks, seg_store_acks;   // the bench's own counts since the last reset

    // A window that can hold two loops of two lines one instruction cache size apart
    localparam bit HOT_LOOPS_FIT = WW >= ICW + 2 * LW;
    // Two window lines that share an instruction-cache set / a data-cache set
    localparam bit I_SET_SHARED = WW > ISETS * LW;
    localparam bit D_SET_SHARED = WW > DSETS * LW;

    bit ko_binds;        // in some profile K_OLDER * (WR + 1) >= R + 1
    bit a_load_ok;       // in some profile the load's worst case 2R + 1 is the bound (a)

    initial begin
        for (int k = 0; k < NITEMS; k++) begin cv[k] = 0; cv_na[k] = 0; end
        for (int k = 0; k < LW; k++) begin
            cv_redirect_beat[k] = 0; cv_reset_beat[k] = 0; cv_dreset_beat[k] = 0; cv_io_beat[k] = 0;
        end
        for (int k = 0; k < 16; k++) begin cv_sel_hit[k] = 0; cv_sel_miss[k] = 0; end
        for (int k = 0; k < NEV; k++) begin dut_count[k] = 0; ref_count[k] = 0; seg_count[k] = 0; end
        seg_load_acks = 0; seg_store_acks = 0;
        ko_binds = 0;
        a_load_ok = 0;
        for (int p = 0; p < 5; p++) begin
            int r1;
            int wr1;
            r1  = (prof_rd_max[p] + 1) + (LW - 1) * (((prof_beat[p] >= 0) ? prof_beat[p] : prof_rd_max[p]) + 1) + 1;
            wr1 = prof_wr_max[p] + 1;
            if (int'(K_OLDER) * wr1 >= r1) ko_binds = 1;
            if (prof_wr_max[p] <= r1) a_load_ok = 1;
        end
        if (!I_SET_SHARED) cv_na[CV_STORE_EVICTED] = 1;
        if (!HOT_LOOPS_FIT) cv_na[CV_HOT_LOOPS] = 1;
        if (!D_SET_SHARED) begin
            cv_na[CV_DCONFLICT] = 1;
            cv_na[CV_DALT]      = 1;
        end
        if (SYSTEM) begin
            // latency 0 and forced latencies are not available with the wrapper's profile
            cv_na[CV_STORE_SECOND_LOOKUP] = 1;
            cv_na[CV_CONSECUTIVE_STORES]  = 1;
            cv_na[CV_STORE_EVICTED]       = 1;
            cv_na[CV_DATA_SECOND_LOOKUP]  = 1;
            cv_na[CV_GRANT_AT_BOUND]      = 1;
            cv_na[CV_COINC]               = 1;
            cv_na[CV_KO]                  = 1;
            cv_na[CV_A_EXACT]             = 1;
            cv_na[CV_RESET_SW_FIRST]      = 1;
            cv_na[CV_RESET_SW_MID]        = 1;
            cv_na[CV_RESET_SW_LAST]       = 1;
            for (int k = CV_LAT0; k <= CV_BURST; k++) cv_na[k] = 1;
        end
        else begin
            if (!ko_binds)  cv_na[CV_KO] = 1;
            if (!a_load_ok) cv_na[CV_A_EXACT] = 1;
        end
    end

    // ---------------------------------------------------------------------------------------
    // Bench state
    // ---------------------------------------------------------------------------------------
    longint unsigned cycle;          // the cycle that ends at the next rising edge
    int              rst_more;       // further reset cycles to drive

    // fetch driver
    bit [31:0] f_pc;                 // the address the driver presents when it requests
    bit        f_prev_req;
    bit [31:0] f_prev_adr;
    bit        want_imiss_in_drefill;   // jump to an absent instruction line while a data refill runs

    // data driver
    bit        d_busy;               // a request is presented and not yet answered
    int        io_left;              // remaining cycles of an I/O-like interval
    bit        cpu_like;             // the data driver behaves like the CPU after a miss
    bit        waiting_grant;        // between a miss cycle and its refill's first grant
    int        older_left;           // requests that may still begin in that interval
    bit        d_prev_req;
    int        st_age;               // cycles the presented store has been presented (0: its first)
    bit        a_taint;              // the open request was replaced while the data cache refilled (free mode): bound (a) is not judged

    // the queue of a directed sequence of data requests
    bit [31:0] dq_adr [48];
    bit        dq_we  [48];
    bit  [3:0] dq_sel [48];
    bit [31:0] dq_dat [48];
    int        dq_n, dq_i;
    bit        dq_alt;               // the queue is the alternation of two conflicting lines

    // directed sequences
    int        ko_left;              // stores still to start back to back behind an instruction miss
    int        hl_switches;          // hot loops: 0 off, else the loop switches still to make
    bit [31:0] hl_base [2];
    int        hl_which, hl_iter;
    int        coinc_stage;          // 0 off, 1 launched (the misses are due), 2 confirmed
    bit        ko_stage;             // the stores behind an instruction miss are under way
    bit        hold_data;            // the data driver stays idle in this step (late load)
    int        late_stage;           // 0 off, 1 launched, 2 the load is on its way
    bit [31:0] late_da;
    bit        force_max, force_min; // latency draws at the profile's maximum / minimum

    // bounds
    longint unsigned b_data, b_grant, b_last, b_dgrant, b_dlast;   // interval counters, 0: none open
    bit              b_grant_on, refill_granted, b_dgrant_on, drefill_granted;
    longint unsigned last_a_wait;
    longint          max_data_wait [5], max_grant_wait [5], max_refill [5], max_dgrant_wait [5], max_drefill [5];
    int unsigned     prof_cost_r [5], prof_cost_wr1 [5], prof_bound_a [5], prof_bound_b [5];

    // coverage history
    bit        prev_fill;           // the instruction cache filled a line in the previous cycle
    bit [29:0] prev_fill_line;
    bit        prev_snoop_inval;
    bit [29:0] prev_snoop_line;
    bit        prev_dfill;          // the data cache filled a line in the previous cycle
    int        last_dkind;          // the previous completed data request: 0 none, 1 load after a miss,
                                    // 2 load hit, 3 store hit, 4 store miss
    bit [29:0] last_dline;

    // fault injection
    bit              injected;
    longint unsigned inject_cycle;

    longint mismatches;

    initial begin
        rst = 1;
        done = 0;
        cycle = 0;
        rst_more = 1;
        cycles_run = 0;
        coverage_short = 0;
        mismatches = 0;
        fetch_bus.cyc = 0; fetch_bus.stb = 0; fetch_bus.adr = 0; fetch_bus.we = 0;
        fetch_bus.sel = 0; fetch_bus.dat_mosi = 0;
        data_bus.cyc = 0; data_bus.stb = 0; data_bus.adr = 0; data_bus.we = 0;
        data_bus.sel = 0; data_bus.dat_mosi = 0;
        f_pc = WS; f_prev_req = 0; f_prev_adr = 0; want_imiss_in_drefill = 0;
        d_busy = 0; io_left = 0; cpu_like = 1; waiting_grant = 0; older_left = 0; d_prev_req = 0;
        st_age = 0; last_da = 0; a_taint = 0;
        dq_n = 0; dq_i = 0; dq_alt = 0;
        ko_left = 0; hl_switches = 0; hl_which = 0; hl_iter = 0;
        coinc_stage = 0; late_stage = 0; late_da = 0; ko_stage = 0; hold_data = 0;
        hl_base[0] = WS; hl_base[1] = WS;
        force_max = 0; force_min = 0;
        b_data = 0; b_grant = 0; b_last = 0; b_dgrant = 0; b_dlast = 0;
        b_grant_on = 0; refill_granted = 0; b_dgrant_on = 0; drefill_granted = 0; last_a_wait = 0;
        for (int k = 0; k < 5; k++) begin
            max_data_wait[k] = 0; max_grant_wait[k] = 0; max_refill[k] = 0;
            max_dgrant_wait[k] = 0; max_drefill[k] = 0;
            prof_cost_r[k] = 0; prof_cost_wr1[k] = 0; prof_bound_a[k] = 0; prof_bound_b[k] = 0;
        end
        prev_fill = 0; prev_fill_line = 0; prev_snoop_inval = 0; prev_snoop_line = 0;
        prev_dfill = 0; last_dkind = 0; last_dline = 0;
        injected = 0; inject_cycle = 0;
        bd_n = 0;
        for (int k = 0; k < 4; k++) begin bd_idx[k] = 0; bd_val[k] = 0; end
        m_held = 0; m_h_we = 0; m_h_burst = 0; m_in_block = 0; m_last_we = 0;
        m_h_adr = 0; m_h_dat = 0; m_last_adr = 0; m_h_sel = 0; m_h_left = 0; m_h_lat = 0;
        m_pre_rd = 0; m_pre_wr = 0;
        inj_ack_err = 0; inj_refill_err = 0; inj_store_err = 0; inj_spontaneous = 0;
        profile = 0;
        rd_min = 0; rd_max = 0; wr_min = 0; wr_max = 0; beat_lat = -1;
        sys_rd_max = 0; sys_wr_max = 0; sys_beat = -1;
        cost_r = LW; cost_wr1 = 1; bound_a = 2 * LW + 1; bound_b = LW + 1;
    end

    // ---------------------------------------------------------------------------------------
    // Reporting
    // ---------------------------------------------------------------------------------------
    function automatic string state_text();
        return $sformatf("model: instruction cache %s beat %0d line 0x%08x, data cache %s beat %0d line 0x%08x, owner %0d; profile %s; data driver %s",
                         model.refilling ? "refill" : "lookup", model.beat, 32'(model.line) << O,
                         model.drefilling ? "refill" : "lookup", model.dbeat, 32'(model.dline) << O,
                         model.owner,
                         SYSTEM ? "memory wrapper" : prof_name[profile],
                         cpu_like ? "CPU-like" : "free");
    endfunction

    task automatic fail(string what);
        mismatches++;
        $display("DCACHE BENCH: configuration %s (instruction cache %0d bytes, data cache %0d bytes, %0d-byte lines, window 0x%08x + 0x%0x words), seed %0d",
                 NAME, IBYTES, DBYTES, LINE_BYTES, WS, WW, seed);
        $display("DCACHE BENCH: cycle %0d: %s", cycle, what);
        $display("DCACHE BENCH: %s", state_text());
        $display("DCACHE BENCH: FAIL (configuration %s, cycle %0d: %s)", NAME, cycle, what);
        $fatal(1, "the data cache bench failed");
    endtask

    // compare one signal of the design with the model
    task automatic cmp(string signal, bit [31:0] dut, bit [31:0] expected);
        if (dut !== expected)
            fail($sformatf("%s: design 0x%0x, model 0x%0x", signal, dut, expected));
    endtask

    // ---------------------------------------------------------------------------------------
    // The comparison of one cycle
    // ---------------------------------------------------------------------------------------
    task automatic compare_cycle();
        // fetch bus
        cmp("fetch ack", fetch_bus.ack, x_f_ack);
        cmp("fetch err", fetch_bus.err, x_f_err);
        if (x_f_ack) cmp("fetch dat_miso", fetch_bus.dat_miso, x_f_dat);
        // data bus
        cmp("data bus ack", data_bus.ack, x_c_ack);
        cmp("data bus err", data_bus.err, x_c_err);
        if (x_c_ack && !data_bus.we) cmp("data bus dat_miso", data_bus.dat_miso, x_c_dat);
        // the instruction cache's refill request
        cmp("instruction refill cyc", icache_mem.cyc, x_i_cyc);
        cmp("instruction refill stb", icache_mem.stb, x_i_stb);
        cmp("instruction refill continuation tag", icache_mem_cont, x_i_cont);
        if (x_i_cyc && x_i_stb) begin
            cmp("instruction refill adr", icache_mem.adr, x_i_adr);
            cmp("instruction refill we", icache_mem.we, 0);
            cmp("instruction refill sel", icache_mem.sel, 4'b1111);
            cmp("instruction refill dat_mosi", icache_mem.dat_mosi, 0);
        end
        // the data cache's request
        cmp("data cache request cyc", dcache_mem.cyc, x_dm_cyc);
        cmp("data cache request stb", dcache_mem.stb, x_dm_stb);
        cmp("data cache continuation tag", dcache_mem_cont, x_dm_cont);
        if (x_dm_cyc && x_dm_stb) begin
            cmp("data cache request adr", dcache_mem.adr, x_dm_adr);
            cmp("data cache request we", dcache_mem.we, x_dm_we);
            cmp("data cache request sel", dcache_mem.sel, x_dm_sel);
            cmp("data cache request dat_mosi", dcache_mem.dat_mosi, x_dm_dat);
        end
        // the memory port
        cmp("memory cyc", memory_port.cyc, x_m_cyc);
        cmp("memory stb", memory_port.stb, x_m_stb);
        cmp("memory adr", memory_port.adr, x_m_adr);
        cmp("memory we", memory_port.we, x_m_we);
        cmp("memory sel", memory_port.sel, x_m_sel);
        cmp("memory dat_mosi", memory_port.dat_mosi, x_m_dat);
        cmp("memory continuation tag", memory_port_cont, x_m_cont);
        // the arbiter's two slave sides
        cmp("data side ack", dcache_mem.ack, x_d_ack);
        cmp("data side err", dcache_mem.err, x_d_err);
        cmp("data side dat_miso", dcache_mem.dat_miso, x_d_dat);
        cmp("refill side ack", icache_mem.ack, x_r_ack);
        cmp("refill side err", icache_mem.err, x_r_err);
        cmp("refill side dat_miso", icache_mem.dat_miso, x_r_dat);
        // events
        for (int k = 0; k < NEV; k++)
            cmp($sformatf("event %s", ev_name[k]), dut_ev[k], x_ev[k]);
    endtask

    // The checks that do not use the model's outputs (cycles with rst = 0)
    task automatic memory_checks();
        bit mw, ds;
        if (fetch_bus.ack) begin
            if (!in_window(fetch_bus.adr))
                fail($sformatf("fetch ack for address 0x%08x outside the window", fetch_bus.adr));
            else if (fetch_bus.dat_miso != mem[fetch_bus.adr - WS])
                fail($sformatf("fetch of 0x%08x answered 0x%08x, memory holds 0x%08x",
                               fetch_bus.adr, fetch_bus.dat_miso, mem[fetch_bus.adr - WS]));
        end
        if (data_bus.ack && data_bus.cyc && data_bus.stb && !data_bus.we) begin
            if (!in_window(data_bus.adr))
                fail($sformatf("load ack for address 0x%08x outside the window", data_bus.adr));
            else if (data_bus.dat_miso != mem[data_bus.adr - WS])
                fail($sformatf("load of 0x%08x answered 0x%08x, memory holds 0x%08x",
                               data_bus.adr, data_bus.dat_miso, mem[data_bus.adr - WS]));
        end
        if (icache_mem.cyc && icache_mem.stb &&
            (icache_mem.we || icache_mem.sel != 4'b1111 || icache_mem.dat_mosi != 0))
            fail($sformatf("the instruction cache's refill request writes: we %0b sel %04b dat_mosi 0x%08x",
                           icache_mem.we, icache_mem.sel, icache_mem.dat_mosi));
        if (dcache_mem.cyc && dcache_mem.stb) begin
            if (!dcache_mem.we && (dcache_mem.sel != 4'b1111 || dcache_mem.dat_mosi != 0))
                fail($sformatf("the data cache's read presents sel %04b dat_mosi 0x%08x",
                               dcache_mem.sel, dcache_mem.dat_mosi));
            if (dcache_mem.we && !(data_bus.cyc && data_bus.stb && data_bus.we &&
                                   dcache_mem.adr == data_bus.adr && dcache_mem.sel == data_bus.sel &&
                                   dcache_mem.dat_mosi == data_bus.dat_mosi))
                fail($sformatf("the data cache writes 0x%08x sel %04b data 0x%08x, which is not the CPU's store (0x%08x sel %04b data 0x%08x, request %0b%0b we %0b)",
                               dcache_mem.adr, dcache_mem.sel, dcache_mem.dat_mosi,
                               data_bus.adr, data_bus.sel, data_bus.dat_mosi,
                               data_bus.cyc, data_bus.stb, data_bus.we));
        end
        mw = memory_port.cyc && memory_port.stb && memory_port.we && memory_port.ack;
        ds = data_bus.cyc && data_bus.stb && data_bus.we && data_bus.ack;
        if (mw != ds)
            fail($sformatf("%0d memory write(s) answered against %0d acknowledged store(s)", mw, ds));
        else if (mw && (memory_port.adr != data_bus.adr || memory_port.sel != data_bus.sel ||
                        memory_port.dat_mosi != data_bus.dat_mosi))
            fail($sformatf("memory write 0x%08x sel %04b data 0x%08x differs from the store 0x%08x sel %04b data 0x%08x",
                           memory_port.adr, memory_port.sel, memory_port.dat_mosi,
                           data_bus.adr, data_bus.sel, data_bus.dat_mosi));
    endtask

    // The identities of the event counts since the last reset: inflight is 1 if a refill is in
    // flight after the counted cycles, with the beats it has had
    task automatic identities(longint i_inflight, longint i_beats, longint d_inflight, longint d_beats);
        if (seg_count[E_IMISS] != seg_count[E_IFILL] + i_inflight)
            fail($sformatf("event counts: %0d instruction misses, %0d fills, %0d refill in flight",
                           seg_count[E_IMISS], seg_count[E_IFILL], i_inflight));
        if (seg_count[E_IREFILL] != seg_count[E_WAITI] + seg_count[E_GRANTI])
            fail($sformatf("event counts: %0d instruction refill cycles, %0d waiting, %0d granted",
                           seg_count[E_IREFILL], seg_count[E_WAITI], seg_count[E_GRANTI]));
        if (seg_count[E_IBEAT] != LW * seg_count[E_IFILL] + i_beats)
            fail($sformatf("event counts: %0d instruction beats, %0d fills of %0d words, %0d beats in flight",
                           seg_count[E_IBEAT], seg_count[E_IFILL], LW, i_beats));
        if (seg_count[E_DLMISS] != seg_count[E_DFILL] + d_inflight)
            fail($sformatf("event counts: %0d load misses, %0d data fills, %0d data refill in flight",
                           seg_count[E_DLMISS], seg_count[E_DFILL], d_inflight));
        if (seg_count[E_DBEAT] != LW * seg_count[E_DFILL] + d_beats)
            fail($sformatf("event counts: %0d data beats, %0d fills of %0d words, %0d beats in flight",
                           seg_count[E_DBEAT], seg_count[E_DFILL], LW, d_beats));
        if (seg_count[E_PLOAD] != seg_count[E_DBEAT])
            fail($sformatf("event counts: %0d loads answered on the port, %0d data refill beats",
                           seg_count[E_PLOAD], seg_count[E_DBEAT]));
        if (seg_count[E_PSTORE] != seg_count[E_DSHIT] + seg_count[E_DSMISS])
            fail($sformatf("event counts: %0d stores answered on the port, %0d store hits + %0d store misses",
                           seg_count[E_PSTORE], seg_count[E_DSHIT], seg_count[E_DSMISS]));
        if (seg_count[E_DLOOKUP] != seg_load_acks)
            fail($sformatf("event counts: %0d lookup hits, %0d loads answered on the data bus",
                           seg_count[E_DLOOKUP], seg_load_acks));
        if (seg_count[E_DSHIT] + seg_count[E_DSMISS] != seg_store_acks)
            fail($sformatf("event counts: %0d store hits + %0d store misses, %0d stores acknowledged on the data bus",
                           seg_count[E_DSHIT], seg_count[E_DSMISS], seg_store_acks));
    endtask

    // ---------------------------------------------------------------------------------------
    // The step at the end of every cycle
    // ---------------------------------------------------------------------------------------
    always @(posedge clk) begin : step
        bit        checking, bchecking, reset_now, next_rst, d_req, f_req, d_done, new_seg;
        bit        fill_now, snoop_now, inval_now, dfill_now, scenario_fetch, scenario_data, quiet;
        bit        d_ack_now, d_load_ack, d_store_ack;
        bit [31:0] next_f_adr, a, sd_adr, sd_dat;
        bit  [3:0] sd_sel;
        bit        sd_we;
        int        r;

        reset_now = rst;
        f_req     = fetch_bus.cyc && fetch_bus.stb;
        d_req     = data_bus.cyc && data_bus.stb;
        fill_now  = x_ev[E_IFILL];
        dfill_now = x_ev[E_DFILL];
        snoop_now = o_snoop;
        inval_now = x_ev[E_SNOOP];
        d_ack_now   = data_bus.ack || data_bus.err;
        d_load_ack  = d_req && data_bus.ack && !data_bus.we;
        d_store_ack = d_req && data_bus.ack && data_bus.we;
        checking  = compare_on && !(inject_here && injected) && !done;
        bchecking = bounds_on && !(inject_here && injected) && !done;

        if (!selected) begin
            done <= 1;
            rst  <= 1;
        end
        else if (!done) begin
            // ---- fault injection detected on the memory side in this cycle ----
            if (inject_here && !injected && !reset_now &&
                ((negative == "ack-err" && memory_port.ack && memory_port.err) ||
                 (negative == "d-refill-err" && memory_port.err && o_gd && o_drefill) ||
                 (negative == "d-store-err" && memory_port.err && o_gd && x_dm_we) ||
                 (negative == "spontaneous-answer" && memory_port.ack &&
                  !(memory_port.cyc && memory_port.stb)))) begin
                injected = 1;
                inject_cycle = cycle;
                checking = 0;
                bchecking = 0;
                inj_ack_err <= 0; inj_refill_err <= 0; inj_store_err <= 0; inj_spontaneous <= 0;
                $display("DCACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                         NAME, negative, cycle);
            end
            if (inject_here && injected && cycle >= inject_cycle + 32) begin
                $display("DCACHE BENCH: FAIL (negative case %s: injected in cycle %0d of configuration %s, nothing stopped the run within 32 cycles)",
                         negative, inject_cycle, NAME);
                $fatal(1, "the data cache bench failed");
            end

            // ---- compare and check the cycle that ends now ----
            if (checking && cycle >= 1) compare_cycle();
            if (checking && !reset_now) memory_checks();

            // ---- event counts and their identities ----
            for (int k = 0; k < NEV; k++) begin
                dut_count[k] += dut_ev[k];
                ref_count[k] += x_ev[k];
            end
            if (reset_now) begin
                // the counts end with the previous cycle; the state is the one after it
                if (checking && cycle != 0)
                    identities(model.refilling, model.refilling ? model.beat : 0,
                               model.drefilling, model.drefilling ? model.dbeat : 0);
                for (int k = 0; k < NEV; k++) seg_count[k] = 0;
                seg_load_acks = 0; seg_store_acks = 0;
            end
            else begin
                for (int k = 0; k < NEV; k++) seg_count[k] += dut_ev[k];
                seg_load_acks  += d_load_ack;
                seg_store_acks += d_store_ack;
                if (cycle + 1 == total_cycles) begin
                    // the last cycle: counted, and the state is the one after its edge
                    if (checking)
                        identities(x_ev[E_IMISS] || (model.refilling && !x_ev[E_IFILL]),
                                   (model.refilling && !x_ev[E_IFILL]) ? model.beat + x_ev[E_IBEAT] : 0,
                                   x_ev[E_DLMISS] || (model.drefilling && !x_ev[E_DFILL]),
                                   (model.drefilling && !x_ev[E_DFILL]) ? model.dbeat + x_ev[E_DBEAT] : 0);
                    for (int k = 0; k < NEV; k++) seg_count[k] = 0;
                    seg_load_acks = 0; seg_store_acks = 0;
                end
            end

            // ---- bounds ----
            if (reset_now) begin
                b_data = 0; b_grant = 0; b_last = 0; b_dgrant = 0; b_dlast = 0;
                b_grant_on = 0; refill_granted = 0; b_dgrant_on = 0; drefill_granted = 0;
                coinc_stage = 0; late_stage = 0; ko_stage = 0;
            end
            else begin
                // (a) a data bus request is answered within R + max(R + 1, WR) cycles
                if (d_req) begin
                    b_data++;
                    if (d_ack_now) begin
                        if (!a_taint && longint'(b_data) > max_data_wait[profile]) max_data_wait[profile] = b_data;
                        last_a_wait = b_data;
                        b_data = 0;
                        a_taint = 0;
                    end
                    else if (b_data >= bound_a && bchecking && !a_taint)
                        fail($sformatf("data request 0x%08x not answered within %0d cycles (R %0d, WR %0d)",
                                       data_bus.adr, bound_a, cost_r, cost_wr1 - 1));
                end
                else begin b_data = 0; a_taint = 0; end
                // measured on the design's own event outputs: ev_miss, ev_refill (a refill
                // cycle), ev_grant_i (the refill holds the port), ev_fill (its last beat)
                // (b) an instruction refill is granted within max(K_OLDER * (WR + 1), R + 1)
                // cycles (CPU-like data side only)
                if (ev_refill && b_grant_on) begin
                    b_grant++;
                    if (ev_grant_i) begin
                        if (longint'(b_grant) > max_grant_wait[profile]) max_grant_wait[profile] = b_grant;
                        if (b_grant == bound_b) cv[CV_GRANT_AT_BOUND]++;
                        if (coinc_stage == 2) begin
                            if (!SYSTEM && bchecking && b_grant != cost_r + 1)
                                fail($sformatf("coincident instruction and load misses: the instruction refill was granted in cycle %0d of its interval, expected R + 1 = %0d",
                                               b_grant, cost_r + 1));
                            if (b_grant == cost_r + 1) cv[CV_COINC]++;
                        end
                        else if (ko_stage && ko_binds && !SYSTEM && b_grant == K_OLDER * cost_wr1)
                            cv[CV_KO]++;
                        coinc_stage = 0;
                        ko_stage = 0;
                        b_grant_on = 0;
                    end
                    else if (b_grant >= bound_b && bchecking)
                        fail($sformatf("instruction refill of line 0x%08x not granted within %0d cycles (%0d older requests of WR + 1 = %0d, or R + 1 = %0d)",
                                       32'(model.line) << O, bound_b, K_OLDER, cost_wr1, cost_r + 1));
                end
                // (c) a granted instruction refill's last beat is answered within R cycles
                if (ev_refill && ev_grant_i && !refill_granted) begin
                    refill_granted = 1;
                    b_last = 0;
                end
                if (ev_refill && refill_granted) begin
                    b_last++;
                    if (ev_fill) begin
                        if (longint'(b_last) > max_refill[profile]) max_refill[profile] = b_last;
                        refill_granted = 0;
                    end
                    else if (b_last >= cost_r && bchecking)
                        fail($sformatf("instruction refill of line 0x%08x: last beat not answered within R = %0d cycles of its grant",
                                       32'(model.line) << O, cost_r));
                end
                if (ev_miss) begin           // a miss: the refill interval starts next cycle
                    b_grant_on     = cpu_like;
                    b_grant        = 0;
                    refill_granted = 0;
                end
                // (e) a data refill is granted within R cycles of its first refill cycle
                if (ev_d_refill && b_dgrant_on) begin
                    b_dgrant++;
                    if (ev_grant_d) begin
                        if (longint'(b_dgrant) > max_dgrant_wait[profile]) max_dgrant_wait[profile] = b_dgrant;
                        b_dgrant_on = 0;
                    end
                    else if (b_dgrant >= cost_r && bchecking)
                        fail($sformatf("data refill of line 0x%08x not granted within R = %0d cycles",
                                       32'(model.dline) << O, cost_r));
                end
                // (f) a granted data refill's last beat is answered within R cycles
                if (ev_d_refill && ev_grant_d && !drefill_granted) begin
                    drefill_granted = 1;
                    b_dlast = 0;
                end
                if (ev_d_refill && drefill_granted) begin
                    b_dlast++;
                    if (ev_d_fill) begin
                        if (longint'(b_dlast) > max_drefill[profile]) max_drefill[profile] = b_dlast;
                        drefill_granted = 0;
                    end
                    else if (b_dlast >= cost_r && bchecking)
                        fail($sformatf("data refill of line 0x%08x: last beat not answered within R = %0d cycles of its grant",
                                       32'(model.dline) << O, cost_r));
                end
                if (ev_d_load_miss) begin    // a load miss: the refill interval starts next cycle
                    b_dgrant_on     = 1;
                    b_dgrant        = 0;
                    drefill_granted = 0;
                end
                // the bound (a) of a load met exactly by the late load of the directed sequence
                if (late_stage == 2 && d_load_ack) begin
                    if (!SYSTEM && last_a_wait == longint'(cost_r + cost_r + 1) && a_load_ok &&
                        prof_wr_max[profile] <= int'(cost_r) + 1)
                        cv[CV_A_EXACT]++;
                    late_stage = 0;
                end
            end

            // ---- coverage ----
            if (reset_now) begin
                if (cycle >= 2 && model.refilling) begin
                    if (o_gi) cv_reset_beat[model.beat]++;
                    else      cv[CV_RESET_WAIT]++;
                end
                if (cycle >= 2 && model.drefilling) begin
                    if (o_gd) cv_dreset_beat[model.dbeat]++;
                    else      cv[CV_DRESET_WAIT]++;
                end
                if (cycle >= 2 && prev_dfill) cv[CV_DRESET_SECOND]++;
                if (cycle >= 2 && d_req && data_bus.we && !model.drefilling && !d_ack_now) begin
                    if (!o_gd) cv[CV_RESET_SW_UNGRANTED]++;
                    else if (st_age == 0) cv[CV_RESET_SW_FIRST]++;
                    else if (m_due) cv[CV_RESET_SW_LAST]++;
                    else cv[CV_RESET_SW_MID]++;
                end
            end
            else begin
                if (model.refilling) begin
                    if (f_req && f_prev_req && fetch_bus.adr != f_prev_adr) begin
                        if (o_gi) cv_redirect_beat[model.beat]++;
                        else      cv[CV_REDIRECT_WAIT]++;
                    end
                    if (o_gi && data_bus.cyc && !data_bus.stb) cv_io_beat[model.beat]++;
                    if (snoop_now && !refill_granted && line_of(data_bus.adr) == model.line)
                        cv[CV_SNOOP_REFILL_LINE]++;
                    if (d_req && !d_prev_req) cv[CV_DATA_DURING_REFILL]++;
                    if (f_req && i_present(fetch_bus.adr) && fetch_bus.adr[31:30] == 0)
                        cv[CV_CACHED_DURING_REFILL]++;
                end
                if (x_f_ack && snoop_now && line_of(fetch_bus.adr) == line_of(data_bus.adr))
                    cv[CV_HIT_STORE_SAME_LINE]++;
                if (prev_fill && snoop_now && line_of(data_bus.adr) == prev_fill_line)
                    cv[CV_STORE_SECOND_LOOKUP]++;
                if (prev_fill && o_gd && x_d_ack) cv[CV_DATA_SECOND_LOOKUP]++;
                if (prev_fill && x_ev[E_IMISS]) cv[CV_BACK_TO_BACK_MISS]++;
                if (inval_now && prev_snoop_inval && line_of(data_bus.adr) != prev_snoop_line)
                    cv[CV_CONSECUTIVE_STORES]++;
                if (x_ev[E_IMISS] && inval_now && iset_of(data_bus.adr) == iset_of(fetch_bus.adr))
                    cv[CV_STORE_EVICTED]++;
                if (x_ev[E_IMISS] && d_req) cv[CV_MISS_AND_DATA]++;
                if (x_ev[E_IABAND]) cv[CV_ABANDONED]++;
                if (x_ev[E_IHIT] && o_gd) cv[CV_HIT_WHILE_DATA]++;
                if (f_req) begin
                    if (fetch_bus.adr == WS)        cv[CV_WINDOW_FIRST]++;
                    if (fetch_bus.adr == WEND - 1)  cv[CV_WINDOW_LAST]++;
                    if (fetch_bus.adr == WS - 1)    cv[CV_BELOW_WINDOW]++;
                    if (fetch_bus.adr == WEND)      cv[CV_ABOVE_WINDOW]++;
                    a = alias_base(fetch_bus.adr);
                    if (!model.refilling && a != fetch_bus.adr && in_window(a) && i_present(a))
                        cv[CV_ALIAS]++;
                end
                if (memory_port.ack && !SYSTEM && (o_gi || (o_gd && o_drefill))) begin
                    if (m_cur_burst)          cv[CV_BURST]++;
                    else if (m_cur_lat == 0)  cv[CV_LAT0]++;
                    else if (m_cur_lat == 1)  cv[CV_LAT1]++;
                    else if (m_cur_lat == 8)  cv[CV_LAT8]++;
                    else if (m_cur_lat == 64) cv[CV_LAT64]++;
                end
                // the data cache
                if (x_ev[E_DSHIT]) cv_sel_hit[data_bus.sel]++;
                if (x_ev[E_DSMISS]) cv_sel_miss[data_bus.sel]++;
                if (x_ev[E_DLMISS]) begin
                    if (last_dkind == 4 && last_dline == line_of(data_bus.adr)) cv[CV_DSTMISS_LOAD]++;
                    if (model.dvalid[dset_of(data_bus.adr)] && !o_dpresent) cv[CV_DCONFLICT]++;
                    if (x_ev[E_IMISS]) cv[CV_BOTH_MISS]++;
                    if (model.refilling) cv[CV_DMISS_IN_IREFILL]++;
                end
                if (x_ev[E_IMISS] && model.drefilling) cv[CV_IMISS_IN_DREFILL]++;
                if (o_gd && o_drefill && model.refilling) cv[CV_DWINS]++;
                if (x_ev[E_DLOOKUP] && o_gi) cv[CV_LOADHIT_IN_IREFILL]++;
                if (x_ev[E_DSWAIT] && o_gi && !o_gd) cv[CV_STORE_WAIT_IREFILL]++;
                if (x_ev[E_DLOOKUP] && prev_dfill) cv[CV_DLOAD_SECOND]++;
                if (x_ev[E_DSHIT] && last_dkind == 1 && last_dline == line_of(data_bus.adr))
                    cv[CV_DFILL_STORE]++;
                // the previous completed data request, for the sequences above
                if (x_ev[E_DLOOKUP]) begin
                    last_dkind = prev_dfill ? 1 : 2;
                    last_dline = line_of(data_bus.adr);
                end
                else if (x_ev[E_DSHIT]) begin
                    last_dkind = 3;
                    last_dline = line_of(data_bus.adr);
                end
                else if (x_ev[E_DSMISS]) begin
                    last_dkind = 4;
                    last_dline = line_of(data_bus.adr);
                end
            end
            if (reset_now) last_dkind = 0;
            if (d_req && data_bus.we && !d_ack_now && !reset_now) st_age++;
            else st_age = 0;
            prev_fill        = !reset_now && fill_now;
            prev_fill_line   = model.line;
            prev_dfill       = !reset_now && dfill_now;
            prev_snoop_inval = !reset_now && inval_now;
            prev_snoop_line  = line_of(data_bus.adr);
            f_prev_req       = f_req && !reset_now;
            f_prev_adr       = fetch_bus.adr;
            d_prev_req       = d_req && !reset_now;

            // ---- memory: writes answered on the port, and changes during a reset ----
            if (!reset_now && memory_port.cyc && memory_port.stb && memory_port.we &&
                memory_port.ack && !memory_port.err && in_window(memory_port.adr)) begin
                bit [31:0] old_w, new_w;
                old_w = mem[memory_port.adr - WS];
                new_w = old_w;
                for (int b = 0; b < 4; b++)
                    if (memory_port.sel[b]) new_w[8*b +: 8] = memory_port.dat_mosi[8*b +: 8];
                mem[memory_port.adr - WS] <= new_w;
            end
            if (reset_now)
                for (int k = 0; k < bd_n; k++) mem[bd_idx[k]] <= bd_val[k];

            // ---- memory model state (the system configuration has the wrapper instead) ----
            if (!SYSTEM) begin
                if (reset_now) begin
                    m_held     <= 0;
                    m_in_block <= 0;
                end
                else begin
                    bit same_req;
                    same_req = m_req && m_held && memory_port.adr == m_h_adr &&
                               memory_port.sel == m_h_sel && memory_port.we == m_h_we &&
                               (!memory_port.we || memory_port.dat_mosi == m_h_dat);
                    m_held <= m_req && !m_answer;
                    if (m_req && !same_req) begin
                        m_h_adr   <= memory_port.adr;
                        m_h_sel   <= memory_port.sel;
                        m_h_we    <= memory_port.we;
                        m_h_dat   <= memory_port.dat_mosi;
                        m_h_lat   <= m_cur_lat;
                        m_h_burst <= m_cur_burst;
                    end
                    if (m_req && !m_answer)
                        m_h_left <= (same_req ? m_h_left : m_cur_lat) - 1;
                    if (m_answer) begin
                        m_in_block <= memory_port.cyc;
                        m_last_adr <= memory_port.adr;
                        m_last_we  <= memory_port.we;
                    end
                    else if (!memory_port.cyc)
                        m_in_block <= 0;
                end
            end

            // ===================================================================================
            // The next cycle
            // ===================================================================================
            cycles_run <= cycles_run + 1;
            if (cycle + 1 == total_cycles) begin
                done <= 1;
                rst  <= 1;
                fetch_bus.cyc <= 0; fetch_bus.stb <= 0;
                data_bus.cyc  <= 0; data_bus.stb  <= 0;
                cycle <= cycle + 1;
            end
            else begin
                // ---- reset and memory profile ----
                new_seg  = !SYSTEM && (cycle + 1) % seg_cycles == 0;
                next_rst = 0;
                if (cycle + 1 < 2) next_rst = 1;
                else if (new_seg) next_rst = 1;
                else if (rst_more > 0) begin next_rst = 1; rst_more--; end
                else if (cycle >= 2 && !(inject_here && cycle < 2000)) begin
                    // about one reset per eight refills, one per few request waits, more in the
                    // second lookup of a data refill, rarely otherwise
                    int unsigned odds;
                    bit need_ibeat, need_dbeat, need_sw;
                    // Resets are boosted where a coverage item still needs them and relaxed
                    // after: a cache that is reset every few refills never warms up
                    need_ibeat = !cv_na[CV_RESET_WAIT] && cv[CV_RESET_WAIT] < (COVER_ITEM + 10);
                    need_dbeat = cv[CV_DRESET_WAIT] < (COVER_ITEM + 10);
                    need_sw    = cv[CV_RESET_SW_UNGRANTED] < (COVER_ITEM + 10);
                    for (int k = 0; k < LW; k++) begin
                        if (cv_reset_beat[k] < (COVER_ITEM + 10))  need_ibeat = 1;
                        if (cv_dreset_beat[k] < (COVER_ITEM + 10)) need_dbeat = 1;
                    end
                    if (!SYSTEM && (cv[CV_RESET_SW_FIRST] < (COVER_ITEM + 10) || cv[CV_RESET_SW_MID] < (COVER_ITEM + 10) ||
                                    cv[CV_RESET_SW_LAST] < (COVER_ITEM + 10)))
                        need_sw = 1;
                    odds = 4000;
                    if (model.refilling)  odds = (odds < (need_ibeat ? 8 : 80) * cost_r) ? odds : (need_ibeat ? 8 : 80) * cost_r;
                    if (model.drefilling) odds = (odds < (need_dbeat ? 8 : 80) * cost_r) ? odds : (need_dbeat ? 8 : 80) * cost_r;
                    if (d_req && !d_ack_now)
                        odds = (odds < 16 * (cost_r + cost_wr1)) ? odds : 16 * (cost_r + cost_wr1);
                    if (d_req && data_bus.we && !d_ack_now && !model.drefilling) begin
                        int unsigned o2;
                        o2 = (need_sw ? 6 : 60) * (cost_wr1 + 2);
                        odds = (odds < o2) ? odds : o2;
                        if (st_age == 0 && !SYSTEM && cv[CV_RESET_SW_FIRST] < (COVER_ITEM + 10))
                            odds = (odds < 16) ? odds : 16;
                    end
                    if (dfill_now && cv[CV_DRESET_SECOND] < (COVER_ITEM + 10)) odds = 14;
                    if (below(odds) == 0) begin
                        next_rst = 1;
                        rst_more = (below(8) == 0) ? int'(below(4)) + 1 : 0;
                    end
                end
                if (cycle == 0 || new_seg) begin
                    profile = SYSTEM ? 0 : int'((((cycle + 1) / seg_cycles) + profile_start) % NPROF);
                    if (SYSTEM) begin
                        rd_min = 0; rd_max = sys_rd_max; wr_min = 0; wr_max = sys_wr_max; beat_lat = sys_beat;
                    end
                    else begin
                        rd_min = prof_rd_min[profile]; rd_max = prof_rd_max[profile];
                        wr_min = prof_wr_min[profile]; wr_max = prof_wr_max[profile];
                        beat_lat = prof_beat[profile];
                    end
                    cost_wr1 = int'(wr_max + 1);
                    cost_r   = int'((rd_max + 1) + (LW - 1) * (((beat_lat >= 0) ? beat_lat : rd_max) + 1));
                    bound_a  = cost_r + (((cost_r + 1) > wr_max) ? (cost_r + 1) : wr_max);
                    bound_b  = ((K_OLDER * cost_wr1) > (cost_r + 1)) ? (K_OLDER * cost_wr1) : (cost_r + 1);
                    prof_cost_r[profile] = cost_r;
                    prof_cost_wr1[profile] = cost_wr1;
                    prof_bound_a[profile] = bound_a;
                    prof_bound_b[profile] = bound_b;
                end
                rst <= next_rst;
                // memory changes during the next cycle if it is a reset cycle
                bd_n <= 0;
                if (next_rst && below(2) == 0) begin
                    int n;
                    n = 1 + int'(below(4));
                    for (int k = 0; k < n; k++) begin
                        bit [31:0] wa;
                        wa = cached_dword();
                        if (wa == 0 || !in_window(wa)) wa = (below(2) == 0) ? cached_iword() : 0;
                        if (wa == 0 || !in_window(wa)) wa = window_word();
                        bd_idx[k] <= wa - WS;
                        bd_val[k] <= rnd();
                    end
                    bd_n <= n;
                end

                // ---- the data driver's mode, and the window from a miss to its refill's grant ----
                if (reset_now) begin
                    waiting_grant = 0;
                    ko_left = 0;
                    hl_switches = 0;
                    dq_n = 0; dq_i = 0; dq_alt = 0;
                    want_imiss_in_drefill = 0;
                end
                else if (x_ev[E_IMISS]) begin
                    waiting_grant = 1;
                    older_left    = K_OLDER - 1;
                end
                else if (o_gi) waiting_grant = 0;
                if (!waiting_grant && !model.refilling && !model.drefilling && ko_left == 0 &&
                    coinc_stage == 0 && late_stage == 0 && below(500) == 0)
                    cpu_like = below(4) != 0;

                // ---- directed sequences ----
                scenario_fetch = 0;
                scenario_data  = 0;
                force_max      = ko_left > 0 || coinc_stage != 0 || late_stage != 0;
                force_min      = 0;
                hold_data      = 0;
                next_f_adr     = f_pc;
                sd_adr = 0; sd_dat = 0; sd_sel = 0; sd_we = 0;
                d_done = d_busy && d_ack_now;
                // the coincident misses must be there in the cycle after the launch
                if (coinc_stage == 1) begin
                    if (x_ev[E_IMISS] && x_ev[E_DLMISS] && !reset_now) coinc_stage = 2;
                    else coinc_stage = 0;
                end
                // the late load: started in the cycle after the instruction miss
                if (late_stage == 1) begin
                    if (x_ev[E_IMISS] && !reset_now && !d_busy) begin
                        scenario_data = 1; sd_adr = late_da; sd_we = 0; sd_sel = load_sel(); sd_dat = rnd();
                        late_stage = 2;
                    end
                    else late_stage = 0;
                end
                // a sequence may start when both caches are in lookup and idle and no request is open
                quiet = !next_rst && !reset_now && (!d_busy || d_done) && !injected && ko_left == 0 &&
                        hl_switches == 0 && coinc_stage == 0 && late_stage == 0 && dq_i >= dq_n &&
                        !scenario_data;
                if (dq_alt && dq_i >= dq_n) begin
                    dq_alt = 0;
                    cv[CV_DALT]++;
                end
                if (quiet && below(30) == 0) begin
                    // the weights favour the cases that need an exact alignment of the two caches
                    case (below(30))
                        0, 1, 2, 3: r = 0;
                        4, 5:       r = 1;
                        6, 7, 12:   r = 2;
                        8, 9, 10, 11: r = 3;
                        13, 14, 15, 16, 17: r = 4;
                        18, 19:     r = 5;
                        20, 21:     r = 6;
                        22:         r = 7;
                        23:         r = 8;
                        24, 25:     r = 9;
                        26:         r = 10;
                        27, 28:     r = 11;
                        default:    r = 12;
                    endcase
                    if (r == 0 && I_SET_SHARED && !model.refilling && !x_ev[E_IMISS]) begin
                        // a store to a cached instruction line in the cycle in which a miss evicts it
                        bit [31:0] la, xa;
                        la = cached_iword();
                        if (la != 0 && !model.drefilling && !x_ev[E_DLMISS]) begin
                            xa = la + 32'(ISETS * LW) * (1 + below(4));
                            if (!in_window(xa)) xa = la - 32'(ISETS * LW) * (1 + below(4));
                            if (in_window(xa)) begin
                                scenario_fetch = 1; next_f_adr = xa;
                                scenario_data  = 1; sd_adr = la; sd_we = 1; sd_sel = 4'b1111;
                                sd_dat = rnd();
                                force_min = 1;
                            end
                        end
                    end
                    else if (r == 1 && !model.refilling && !x_ev[E_IMISS] && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // K_OLDER stores from the miss cycle on, back to back
                        bit [31:0] xa;
                        xa = absent_iword();
                        if (xa != 0) begin
                            scenario_fetch = 1; next_f_adr = xa;
                            ko_left   = K_OLDER;
                            ko_stage  = 1;
                            cpu_like  = 1;
                            force_max = 1;
                        end
                    end
                    else if (r == 2 && HOT_LOOPS_FIT && !model.refilling && !x_ev[E_IMISS]) begin
                        // two loops of two lines, one instruction cache size apart
                        bit [31:0] base;
                        base = WS + below(WW - ICW - 2 * LW + 1);
                        base = base & ~32'(LW - 1);
                        if (base < WS) base = WS;
                        hl_base[0] = base;
                        hl_base[1] = base + ICW;
                        hl_which = 0;
                        hl_iter  = 0;
                        hl_switches = 3;
                        scenario_fetch = 1; next_f_adr = base;
                    end
                    else if ((r == 3 || r == 4) && !model.refilling && !x_ev[E_IMISS] &&
                             !model.drefilling && !x_ev[E_DLMISS]) begin
                        // both caches miss in one cycle (r == 3), or the load misses in the cycle after
                        // the instruction miss (r == 4): the worst cases of bounds (b) and (a)
                        bit [31:0] xa, da;
                        xa = absent_iword();
                        da = absent_dword();
                        if (xa != 0 && da != 0) begin
                            scenario_fetch = 1; next_f_adr = xa;
                            cpu_like = 1;
                            if (r == 3) begin
                                scenario_data = 1; sd_adr = da; sd_we = 0; sd_sel = load_sel(); sd_dat = rnd();
                                coinc_stage = 1;
                            end
                            else begin
                                late_stage = 1; late_da = da;
                            end
                            force_max = 1;
                        end
                    end
                    else if (r == 5 && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // every byte-enable pattern on a store hit: load the line (which fills it if
                        // it is absent), then a store to it and a load of it back for each pattern
                        bit [31:0] x;
                        x = cached_dword();
                        if (x == 0) x = window_word();
                        dq_n = 0; dq_i = 0;
                        dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        for (int p = 0; p < 16; p++) begin
                            dq_adr[dq_n] = x; dq_we[dq_n] = 1; dq_sel[dq_n] = 4'(p); dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        end
                    end
                    else if (r == 6 && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // every byte-enable pattern on a store miss, then the load that misses and the
                        // load that hits, and a store to the filled line
                        bit [31:0] x;
                        x = absent_dword();
                        if (x != 0) begin
                            dq_n = 0; dq_i = 0;
                            for (int p = 0; p < 16; p++) begin
                                dq_adr[dq_n] = x; dq_we[dq_n] = 1; dq_sel[dq_n] = 4'(p); dq_dat[dq_n] = data_word(); dq_n++;
                            end
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel(); dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        end
                    end
                    else if (r == 7 && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // a store miss and then a load of that line (misses: nothing is allocated)
                        bit [31:0] x;
                        x = absent_dword();
                        if (x != 0) begin
                            dq_n = 0; dq_i = 0;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel(); dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = x ^ 32'(below(LW)); dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        end
                    end
                    else if (r == 8 && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // a load miss and then a store to its line (hits), and a load of it
                        bit [31:0] x;
                        x = absent_dword();
                        if (x != 0) begin
                            dq_n = 0; dq_i = 0;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                            dq_adr[dq_n] = (x & ~32'(LW - 1)) | below(LW); dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel();
                            dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        end
                    end
                    else if (r == 9 && D_SET_SHARED && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // two lines one data cache size apart, used alternately: loads, stores, loads
                        bit [31:0] x, y;
                        x = window_word();
                        y = x + 32'(DCW) * (1 + below(3));
                        if (!in_window(y)) y = x - 32'(DCW) * (1 + below(3));
                        if (in_window(y)) begin
                            dq_n = 0; dq_i = 0;
                            for (int k = 0; k < 8; k++) begin
                                bit [31:0] z;
                                z = (k % 2 == 0) ? x : y;
                                z = (z & ~32'(LW - 1)) | below(LW);
                                dq_adr[dq_n] = z; dq_we[dq_n] = (k % 4 == 3); dq_sel[dq_n] = (k % 4 == 3) ? store_sel() : load_sel();
                                dq_dat[dq_n] = data_word(); dq_n++;
                            end
                            dq_alt = 1;
                        end
                    end
                    else if (r == 10 && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // an instruction miss while a data refill runs: start a load miss, the fetch
                        // driver jumps to an absent instruction line when the refill is in progress
                        bit [31:0] x;
                        x = absent_dword();
                        if (x != 0) begin
                            dq_n = 0; dq_i = 0;
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                            want_imiss_in_drefill = 1;
                        end
                    end
                    else if (r == 12) begin
                        // two stores to two different lines the instruction cache holds, back to back
                        bit [31:0] a1, a2;
                        a1 = cached_iword();
                        a2 = cached_iword();
                        if (a1 != 0 && a2 != 0 && line_of(a1) != line_of(a2) && in_window(a1) && in_window(a2)) begin
                            dq_n = 0; dq_i = 0;
                            dq_adr[dq_n] = a1; dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel(); dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = a2; dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel(); dq_dat[dq_n] = data_word(); dq_n++;
                            dq_adr[dq_n] = a1; dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel(); dq_dat[dq_n] = data_word(); dq_n++;
                        end
                    end
                    else if (r == 11 && model.refilling && !model.drefilling && !x_ev[E_DLMISS]) begin
                        // stores, load hits and load misses while an instruction refill holds the port
                        bit [31:0] x, h;
                        x = absent_dword();
                        h = cached_dword();
                        dq_n = 0; dq_i = 0;
                        dq_adr[dq_n] = (h != 0) ? h : window_word(); dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel();
                        dq_dat[dq_n] = rnd(); dq_n++;
                        dq_adr[dq_n] = (h != 0) ? h : window_word(); dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel();
                        dq_dat[dq_n] = data_word(); dq_n++;
                        if (x != 0) begin
                            dq_adr[dq_n] = x; dq_we[dq_n] = 0; dq_sel[dq_n] = load_sel(); dq_dat[dq_n] = rnd(); dq_n++;
                        end
                        dq_adr[dq_n] = (h != 0) ? h : window_word(); dq_we[dq_n] = 1; dq_sel[dq_n] = store_sel();
                        dq_dat[dq_n] = data_word(); dq_n++;
                    end
                end
                // an instruction miss during a data refill, as asked above
                if (late_stage == 1 && !scenario_data) hold_data = 1;
                if (want_imiss_in_drefill && !scenario_fetch && model.drefilling && !x_ev[E_DFILL] &&
                    !model.refilling && !x_ev[E_IMISS] && !reset_now && !next_rst) begin
                    bit [31:0] xa;
                    xa = absent_iword();
                    if (xa != 0) begin
                        scenario_fetch = 1; next_f_adr = xa;
                        want_imiss_in_drefill = 0;
                    end
                end

                // ---- fetch driver ----
                if (scenario_fetch) begin
                    f_pc <= next_f_adr;
                    fetch_bus.cyc <= 1; fetch_bus.stb <= 1; fetch_bus.adr <= next_f_adr;
                    fetch_bus.we <= 0; fetch_bus.sel <= 4'b1111; fetch_bus.dat_mosi <= rnd();
                end
                else if (hl_switches > 0 && !reset_now) begin
                    bit [31:0] pc;
                    pc = f_pc;
                    if (f_req && fetch_bus.ack) begin
                        if (pc == hl_base[hl_which] + 2 * LW - 1) begin
                            pc = hl_base[hl_which];
                            hl_iter++;
                            if (hl_iter == 3) begin
                                hl_iter  = 0;
                                hl_which = 1 - hl_which;
                                pc       = hl_base[hl_which];
                                hl_switches--;
                                cv[CV_HOT_LOOPS]++;
                            end
                        end
                        else pc = pc + 1;
                    end
                    f_pc <= pc;
                    fetch_bus.cyc <= 1; fetch_bus.stb <= 1; fetch_bus.adr <= pc;
                    fetch_bus.we <= 0; fetch_bus.sel <= 4'b1111; fetch_bus.dat_mosi <= rnd();
                end
                else begin
                    bit [31:0] pc;
                    bit        jump, idle;
                    bit [31:0] ga;
                    pc   = f_pc;
                    jump = 0;
                    idle = 0;
                    if (below(100) < 4) idle = 1;
                    else if (!f_req) jump = below(100) < 30;
                    else if (fetch_bus.ack) begin
                        r = int'(below(100));
                        if (r < 88) pc = pc + 1;
                        else if (r >= 94) jump = 1;
                    end
                    else if (fetch_bus.err) jump = below(100) < 25;
                    else if (model.refilling) jump = below(100) < 20;
                    else jump = below(100) < 3;
                    if (jump) begin
                        r = int'(below(100));
                        if (r < 30) pc = window_word();
                        else if (r < 50) begin
                            pc = cached_iword();
                            if (pc == 0) pc = window_word();
                        end
                        else if (r < 58) pc = model.refilling ? ((32'(model.line) << O) | below(LW)) : window_word();
                        else if (r < 66) pc = (pc & ~32'(LW - 1)) + ((below(2) == 0) ? 32'(LW) : -32'(LW)) + below(LW);
                        else if (r < 76) begin
                            case (below(6))
                                0: pc = WS;
                                1: pc = WEND - 1;
                                2: pc = WS - 1;
                                3: pc = WEND;
                                4: pc = WS - 1 - below(4);
                                default: pc = WEND + below(4);
                            endcase
                        end
                        else if (r < 82) begin
                            pc = cached_iword();
                            if (pc == 0) pc = window_word();
                            pc = pc ^ (32'h1 << (TOP + 1 + below(31 - TOP)));
                        end
                        else if (r < 86) pc = rnd();
                        else begin
                            pc = (below(2) == 0) ? pc + ICW : pc - ICW;
                            if (!in_window(pc)) pc = window_word();
                        end
                    end
                    f_pc <= pc;
                    if (idle) begin
                        r = int'(below(3));
                        fetch_bus.cyc <= r == 1;
                        fetch_bus.stb <= r == 2;
                        // Garbage that can matter: a uniformly random word address is almost never
                        // inside the window, so half of the cycles present a word of a cached line
                        // or of the window (a hit is possible, and must stay unanswered), or the
                        // address of the last request
                        case (below(8))
                            0, 1:    ga = cached_iword();      // 0 if no line is valid
                            2:       ga = window_word();
                            3:       ga = pc;
                            default: ga = rnd();
                        endcase
                        if (ga == 0) ga = rnd();
                        fetch_bus.adr <= ga;
                        fetch_bus.we  <= rnd() % 2 == 0;
                        fetch_bus.sel <= 4'(rnd());
                        fetch_bus.dat_mosi <= rnd();
                    end
                    else begin
                        fetch_bus.cyc <= 1; fetch_bus.stb <= 1; fetch_bus.adr <= pc;
                        fetch_bus.we <= 0; fetch_bus.sel <= 4'b1111; fetch_bus.dat_mosi <= rnd();
                    end
                end
                if (hl_switches > 0 && reset_now) hl_switches = 0;

                // ---- data driver ----
                if (reset_now) begin
                    // the CPU drops its request in reset and presents none in the next cycle
                    d_busy <= 0;
                    io_left = 0;
                    data_bus.cyc <= 0; data_bus.stb <= 0;
                    data_bus.adr <= rnd(); data_bus.we <= 0; data_bus.sel <= 0;
                end
                else if (d_busy && !d_done) begin
                    // held until answered. Exceptions: +negative=d-request-change changes a store
                    // that waits for the port once, and a request that waits for a data refill may
                    // be replaced in the free mode (the data cache is busy with its refill, the
                    // CPU never does this)
                    if (inject_here && negative == "d-request-change" && !injected && !o_gd &&
                        data_bus.we && !model.drefilling && cycle >= 20 && !next_rst) begin
                        bit [31:0] na;
                        na = window_word();
                        if (na == data_bus.adr) na = (na + 1 < WEND) ? na + 1 : WS;
                        data_bus.adr <= na;
                        injected = 1; inject_cycle = cycle + 1;
                        $display("DCACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                                 NAME, negative, cycle + 1);
                    end
                    else if (!cpu_like && !injected && dq_i >= dq_n && ko_left == 0 && !next_rst &&
                             (model.drefilling || x_ev[E_DLMISS]) && !data_bus.we && below(100) < 30) begin
                        dreq_t q;
                        q = pick_request();
                        if (below(2) == 0) begin
                            // a load of a present line, which a faulty cache answers in its refill
                            a = cached_dword();
                            if (a != 0) begin q.adr = a; q.we = 0; q.sel = load_sel(); end
                        end
                        data_bus.adr <= q.adr; data_bus.we <= q.we; data_bus.sel <= q.sel;
                        data_bus.dat_mosi <= q.dat;
                        last_da = q.adr;
                        b_data = 0;
                        a_taint = 1;
                    end
                end
                else begin
                    bit allowed, start;
                    allowed = !(cpu_like && waiting_grant && older_left == 0);
                    start   = 0;
                    data_bus.cyc <= 0;       // idle unless one of the choices below drives it
                    data_bus.stb <= 0;
                    if (hold_data) start = 0;
                    else if (scenario_data) start = 1;
                    else if (dq_i < dq_n) start = allowed;
                    else if (ko_left > 0) start = allowed;
                    else if (io_left > 0) begin
                        io_left--;
                        data_bus.cyc <= 1; data_bus.stb <= 0;
                        data_bus.adr <= (below(2) == 0) ? rnd() : 32'h0008_0000 + below(32'h1_0000);
                        data_bus.we <= rnd() % 2 == 0; data_bus.sel <= 4'(rnd());
                        data_bus.dat_mosi <= rnd();
                    end
                    else begin
                        r = int'(below(100));
                        if (r < 35) start = allowed;
                        else if (r < 70) begin
                            // garbage: no request, but an address that can matter and any mix of
                            // cyc and stb except both (a request)
                            case (below(3))
                                0: begin data_bus.cyc <= 0; data_bus.stb <= 0; end
                                1: begin data_bus.cyc <= 1; data_bus.stb <= 0; end
                                default: begin data_bus.cyc <= 0; data_bus.stb <= 1; end
                            endcase
                            case (below(4))
                                0:       a = cached_dword();
                                1:       a = window_word();
                                2:       a = last_da;
                                default: a = rnd();
                            endcase
                            if (a == 0) a = rnd();
                            data_bus.adr <= a;
                            data_bus.we <= rnd() % 2 == 0; data_bus.sel <= 4'(rnd());
                            data_bus.dat_mosi <= rnd();
                        end
                        else begin
                            io_left = int'(below(8));
                            data_bus.cyc <= 1; data_bus.stb <= 0;
                            data_bus.adr <= 32'h0008_0000 + below(32'h1_0000);
                            data_bus.we <= rnd() % 2 == 0; data_bus.sel <= 4'(rnd());
                            data_bus.dat_mosi <= rnd();
                        end
                        if (!start && r < 35) begin
                            data_bus.cyc <= 0; data_bus.stb <= 0;
                        end
                    end
                    // +negative=d-out-of-window: one request with stb outside the window
                    if (!start && inject_here && negative == "d-out-of-window" && !injected &&
                        cycle >= 20 && !next_rst && (!d_busy || d_done)) begin
                        data_bus.cyc <= 1; data_bus.stb <= 1;
                        data_bus.adr <= (below(2) == 0) ? WEND + below(8) : WS - 1 - below(8);
                        data_bus.we <= rnd() % 2 == 0; data_bus.sel <= 4'b1111;
                        data_bus.dat_mosi <= rnd();
                        injected = 1; inject_cycle = cycle + 1;
                        $display("DCACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                                 NAME, negative, cycle + 1);
                    end
                    if (start) begin
                        bit [31:0] da, dd;
                        bit        we;
                        bit  [3:0] sel;
                        dd = rnd();
                        if (scenario_data) begin
                            da = sd_adr; we = sd_we; sel = sd_sel; dd = sd_dat;
                        end
                        else if (dq_i < dq_n) begin
                            da = dq_adr[dq_i]; we = dq_we[dq_i]; sel = dq_sel[dq_i]; dd = dq_dat[dq_i];
                            dq_i++;
                        end
                        else if (ko_left > 0) begin
                            // the stores behind an instruction miss: any window word
                            da = (below(2) == 0) ? cached_dword() : 0;
                            if (da == 0 || !in_window(da)) da = window_word();
                            we = 1;
                            sel = store_sel();
                            dd = data_word();
                        end
                        else begin
                            dreq_t q;
                            q = pick_request();
                            da = q.adr; we = q.we; sel = q.sel; dd = q.dat;
                        end
                        if (ko_left > 0 && !scenario_data) ko_left--;
                        if (waiting_grant && !scenario_data) older_left--;
                        // a reset in the first cycle of a store that waits for the memory is decided
                        // here, one cycle before it: the reset is the store's first cycle
                        if (we && !SYSTEM && !next_rst && !injected && cycle >= 2 &&
                            cv[CV_RESET_SW_FIRST] < (COVER_ITEM + 10) && below(12) == 0) begin
                            next_rst = 1;
                            rst <= 1;
                        end
                        last_da = da;
                        st_age = 0;
                        d_busy <= 1;
                        data_bus.cyc <= 1; data_bus.stb <= 1; data_bus.adr <= da;
                        data_bus.we <= we; data_bus.sel <= sel; data_bus.dat_mosi <= dd;
                    end
                    else d_busy <= 0;
                end

                // ---- memory model: latency draws for a transfer that starts next cycle ----
                if (!SYSTEM) begin
                    // drawn from the profile's range, its two ends more often (one in eight each)
                    r = int'(below(8));
                    m_pre_rd <= (force_max || r == 0) ? rd_max : (force_min || r == 1) ? rd_min :
                                rd_min + int'(below(rd_max - rd_min + 1));
                    r = int'(below(8));
                    m_pre_wr <= (force_max || r == 0) ? wr_max : (force_min || r == 1) ? wr_min :
                                wr_min + int'(below(wr_max - wr_min + 1));
                    if (inject_here && !injected && cycle >= 20) begin
                        inj_ack_err     <= negative == "ack-err";
                        inj_refill_err  <= negative == "d-refill-err";
                        inj_store_err   <= negative == "d-store-err";
                        inj_spontaneous <= negative == "spontaneous-answer";
                    end
                end
                cycle <= cycle + 1;
            end
        end
    end

    // ---------------------------------------------------------------------------------------
    // The result line of this configuration (called by the top module at the end)
    // ---------------------------------------------------------------------------------------
    function automatic void report();
        string text, short_list, verdict, wrapper;
        if (!selected) begin
            $display("DCACHE BENCH: configuration %s: not selected", NAME);
            return;
        end
        short_list = "";
        if (compare_on) begin
            for (int k = 0; k < NEV; k++)
                if (dut_count[k] != ref_count[k])
                    short_list = {short_list, $sformatf(" event %s counted %0d by the design, %0d by the model;",
                                                        ev_name[k], dut_count[k], ref_count[k])};
        end
        if (short_list != "") begin
            $display("DCACHE BENCH: FAIL (configuration %s: event counts differ:%s)", NAME, short_list);
            $fatal(1, "the data cache bench failed");
        end
        for (int k = 0; k < NEV; k++)
            if (ref_count[k] < COVER_EVENT)
                short_list = {short_list, $sformatf(" event %s %0d;", ev_name[k], ref_count[k])};
        for (int k = 0; k < NITEMS; k++)
            if (!cv_na[k] && cv[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" %s %0d;", cv_name[k], cv[k])};
        for (int k = 0; k < LW; k++) begin
            if (cv_redirect_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" redirect at instruction beat %0d %0d;", k, cv_redirect_beat[k])};
            if (cv_reset_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" reset at instruction beat %0d %0d;", k, cv_reset_beat[k])};
            if (cv_dreset_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" reset at data beat %0d %0d;", k, cv_dreset_beat[k])};
            if (cv_io_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" I/O-like data cycle at instruction beat %0d %0d;", k, cv_io_beat[k])};
        end
        for (int k = 0; k < 16; k++) begin
            if (cv_sel_hit[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" store hit with sel %04b %0d;", k, cv_sel_hit[k])};
            if (cv_sel_miss[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" store miss with sel %04b %0d;", k, cv_sel_miss[k])};
        end
        coverage_short = short_list != "";
        text = "";
        for (int k = 0; k < NEV; k++) text = {text, $sformatf(" %s=%0d", ev_name[k], ref_count[k])};
        text = {text, "; longest waits against their bounds (data answer (a), instruction refill grant (b), granted instruction refill (c), data refill grant (e), granted data refill (f)):"};
        for (int p = 0; p < NPROF; p++)
            text = {text, $sformatf(" %s %0d/%0d %0d/%0d %0d/%0d %0d/%0d %0d/%0d;",
                                    SYSTEM ? "memory wrapper" : prof_name[p],
                                    max_data_wait[p], prof_bound_a[p],
                                    max_grant_wait[p], prof_bound_b[p],
                                    max_refill[p], prof_cost_r[p],
                                    max_dgrant_wait[p], prof_cost_r[p],
                                    max_drefill[p], prof_cost_r[p])};
        if (coverage_short) verdict = "short:";
        else                verdict = "met";
        if (!SYSTEM)
            wrapper = "profiles latency 0, latency 2, latency 1-8, latency 1-64, DRAM-like";
        else if (sys_beat < 0)
            wrapper = $sformatf("memory wrapper: read latency up to %0d, write latency up to %0d, bursts off",
                                sys_rd_max, sys_wr_max);
        else
            wrapper = $sformatf("memory wrapper: read latency up to %0d, write latency up to %0d, burst beats %0d",
                                sys_rd_max, sys_wr_max, sys_beat);
        text = {text, " coverage:"};
        for (int k = 0; k < NITEMS; k++)
            text = {text, $sformatf(" %0d%s", cv[k], cv_na[k] ? "(n/a)" : "")};
        $display("DCACHE BENCH: configuration %s: instruction cache %0d bytes, data cache %0d bytes, %0d-byte lines, window 0x%08x + 0x%0x words, %0d cycles, %s; events%s; coverage %s%s",
                 NAME, IBYTES, DBYTES, LINE_BYTES, WS, WW, cycles_run, wrapper, text, verdict, short_list);
    endfunction
endmodule

// =============================================================================================
// Top: all configurations in one run
// =============================================================================================

module test_dcache;
    logic clk;
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    localparam int N = 15;
    bit     done [N];
    bit     sel [N];
    longint cyc [N];
    bit     short_cov [N];

    localparam bit [31:0] RAM_START = 32'h0001_0000;   // the RAM window of the model configurations
    localparam bit [31:0] RAM_WORDS = 32'h0000_2000;   // 32 KiB

    bit          st_done, st_failed;
    int unsigned st_checks;
    memsys_ref_selftest selftest (.clk, .done(st_done), .failed(st_failed), .n_checks(st_checks));

    //                       name                          I bytes  D bytes  line  window
    dcache_bench_env #(.NAME("i16-d16-line8-small"),    .IBYTES(16),   .DBYTES(16),   .LINE_BYTES(8),  .WINDOW_START(RAM_START + 3 * 2),  .WINDOW_WORDS(8 * 2),  .NUMBER(0))  c0  (.clk, .done(done[0]),  .selected(sel[0]),  .cycles_run(cyc[0]),  .coverage_short(short_cov[0]));
    dcache_bench_env #(.NAME("i16-d16-line8-ram"),      .IBYTES(16),   .DBYTES(16),   .LINE_BYTES(8),  .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(1))  c1  (.clk, .done(done[1]),  .selected(sel[1]),  .cycles_run(cyc[1]),  .coverage_short(short_cov[1]));
    dcache_bench_env #(.NAME("i512-d512-line16-small"), .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(16), .WINDOW_START(RAM_START + 3 * 4),  .WINDOW_WORDS(8 * 4),  .NUMBER(2))  c2  (.clk, .done(done[2]),  .selected(sel[2]),  .cycles_run(cyc[2]),  .coverage_short(short_cov[2]));
    dcache_bench_env #(.NAME("i512-d512-line16-ram"),   .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(16), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(3))  c3  (.clk, .done(done[3]),  .selected(sel[3]),  .cycles_run(cyc[3]),  .coverage_short(short_cov[3]));
    dcache_bench_env #(.NAME("i8192-d4096-line16-small"), .IBYTES(8192), .DBYTES(4096), .LINE_BYTES(16), .WINDOW_START(RAM_START + 3 * 4), .WINDOW_WORDS(8 * 4),  .NUMBER(4))  c4  (.clk, .done(done[4]),  .selected(sel[4]),  .cycles_run(cyc[4]),  .coverage_short(short_cov[4]));
    dcache_bench_env #(.NAME("i8192-d4096-line16-ram"), .IBYTES(8192), .DBYTES(4096), .LINE_BYTES(16), .WINDOW_START(RAM_START),         .WINDOW_WORDS(RAM_WORDS), .NUMBER(5))  c5  (.clk, .done(done[5]),  .selected(sel[5]),  .cycles_run(cyc[5]),  .coverage_short(short_cov[5]));
    dcache_bench_env #(.NAME("i512-d512-line8-small"),  .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(8),  .WINDOW_START(RAM_START + 3 * 2),  .WINDOW_WORDS(8 * 2),  .NUMBER(6))  c6  (.clk, .done(done[6]),  .selected(sel[6]),  .cycles_run(cyc[6]),  .coverage_short(short_cov[6]));
    dcache_bench_env #(.NAME("i512-d512-line8-ram"),    .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(8),  .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(7))  c7  (.clk, .done(done[7]),  .selected(sel[7]),  .cycles_run(cyc[7]),  .coverage_short(short_cov[7]));
    dcache_bench_env #(.NAME("i512-d512-line32-small"), .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(32), .WINDOW_START(RAM_START + 3 * 8),  .WINDOW_WORDS(8 * 8),  .NUMBER(8))  c8  (.clk, .done(done[8]),  .selected(sel[8]),  .cycles_run(cyc[8]),  .coverage_short(short_cov[8]));
    dcache_bench_env #(.NAME("i512-d512-line32-ram"),   .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(32), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(9))  c9  (.clk, .done(done[9]),  .selected(sel[9]),  .cycles_run(cyc[9]),  .coverage_short(short_cov[9]));
    dcache_bench_env #(.NAME("i512-d512-line64-small"), .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(64), .WINDOW_START(RAM_START + 3 * 16), .WINDOW_WORDS(8 * 16), .NUMBER(10)) c10 (.clk, .done(done[10]), .selected(sel[10]), .cycles_run(cyc[10]), .coverage_short(short_cov[10]));
    dcache_bench_env #(.NAME("i512-d512-line64-ram"),   .IBYTES(512),  .DBYTES(512),  .LINE_BYTES(64), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(11)) c11 (.clk, .done(done[11]), .selected(sel[11]), .cycles_run(cyc[11]), .coverage_short(short_cov[11]));
    dcache_bench_env #(.NAME("i512-d32-line16-small"),  .IBYTES(512),  .DBYTES(32),   .LINE_BYTES(16), .WINDOW_START(RAM_START + 3 * 4),  .WINDOW_WORDS(8 * 4),  .NUMBER(12)) c12 (.clk, .done(done[12]), .selected(sel[12]), .cycles_run(cyc[12]), .coverage_short(short_cov[12]));
    dcache_bench_env #(.NAME("i512-d32-line16-ram"),    .IBYTES(512),  .DBYTES(32),   .LINE_BYTES(16), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(13)) c13 (.clk, .done(done[13]), .selected(sel[13]), .cycles_run(cyc[13]), .coverage_short(short_cov[13]));
    // the system configuration: the real memory wrapper and RAM, in the RAM window of the simulators
    dcache_bench_env #(.NAME("system-i512-d512-line16"), .IBYTES(512), .DBYTES(512),  .LINE_BYTES(16), .WINDOW_START(constants::MEMORY_START), .WINDOW_WORDS(constants::MEMORY_SIZE), .SYSTEM(1), .NUMBER(14)) c14 (.clk, .done(done[14]), .selected(sel[14]), .cycles_run(cyc[14]), .coverage_short(short_cov[14]));

    initial begin
        bit     all_done, compare_on, cover_on, short_any;
        longint total;
        int     configs;
        compare_on = !$test$plusargs("compare=0") && !$test$plusargs("compare=bounds");
        cover_on   = !$test$plusargs("cover=0");
        do begin
            @(posedge clk);
            #1;
            all_done = st_done;
            for (int k = 0; k < N; k++) all_done = all_done && done[k];
        end while (!all_done);
        if (st_failed) begin
            $display("DCACHE BENCH: FAIL (the reference model disagrees with the hand-computed cycles, see above)");
            $fatal(1, "the data cache bench failed");
        end
        $display("DCACHE BENCH: reference model self-test passed (%0d hand-computed values)", st_checks);
        if ($test$plusargs("selftest")) begin
            $display("DCACHE BENCH: MODEL SELF-TEST PASS (%0d hand-computed values)", st_checks);
            $finish;
        end
        else begin
            c0.report();  c1.report();  c2.report();  c3.report();  c4.report();
            c5.report();  c6.report();  c7.report();  c8.report();  c9.report();
            c10.report(); c11.report(); c12.report(); c13.report(); c14.report();
            #1;                 // the reports set the configurations' coverage_short outputs
            total = 0;
            configs = 0;
            short_any = 0;
            for (int k = 0; k < N; k++) begin
                if (sel[k]) configs++;
                total += cyc[k];
                short_any = short_any || short_cov[k];
            end
            if (configs == 0) begin
                $display("DCACHE BENCH: FAIL (+only selected no configuration)");
                $fatal(1, "the data cache bench failed");
            end
            if ($test$plusargs("negative=")) begin
                if (!c3.injected)
                    $display("DCACHE BENCH: FAIL (negative case %s: the fault found no cycle to be injected in configuration i512-d512-line16-ram)",
                             c3.negative);
                else
                    $display("DCACHE BENCH: FAIL (negative case %s: the run ended and no assertion of the design stopped it)",
                             c3.negative);
                $fatal(1, "the data cache bench failed");
            end
            if (!compare_on) begin
                $display("DCACHE BENCH: COMPARE OFF (%0d configurations, %0d cycles)", configs, total);
                $fatal(1, "the data cache bench ran with +compare=0 or +compare=bounds: no verdict");
            end
            if (short_any && cover_on) begin
                $display("DCACHE BENCH: FAIL (coverage targets not met, see the configuration lines)");
                $fatal(1, "the data cache bench failed");
            end
            $display("DCACHE BENCH: PASS (%0d configurations, %0d cycles, 0 mismatches)", configs, total);
            $finish;
        end
    end
endmodule
