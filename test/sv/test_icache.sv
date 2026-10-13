// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// test_icache.sv -- bench of the simulation-only instruction cache and the memory-port arbiter
// (rtl/cache/icache.sv, rtl/cache/mem_arbiter.sv), compared in every cycle with a reference model.
//
// The device under test is one icache and one mem_arbiter, wired as rtl/mcu.sv wires them in the
// cached simulators: the fetch bus on the cache's CPU port, the cache's refill port on the
// arbiter's refill side, interconnect slave 0 (the RAM window of the data bus) on the arbiter's
// data side, and the snoop taken from the stores that the arbiter's data side acknowledges.
// Around it the bench has a fetch driver, a data-side driver and a memory model. The reference
// model, module icache_ref below, gets the same inputs (fetch requests, data requests, the
// memory's answers, reset) and computes every output of the pair from the cache's documented
// behaviour (docs/CACHES.md) in one procedural step per cycle with explicit state; it was written
// without reading the RTL.
//
// Compared in every cycle, reset cycles included (the first cycle, before any reset edge, apart):
// the fetch answer (ack, err, and the word with ack), the cache's refill request, the memory
// port's request (cyc, stb, and adr, we, sel, dat_mosi, the continuation tag with a request; all
// of them 0 when the port is idle), ack, err and dat_miso on both sides of the arbiter, and the
// thirteen event outputs. Independently of the model the bench checks that every fetch and load
// answer equals memory at that address as it was at the start of the cycle, that the cache never
// writes, that exactly one memory write is answered per answered data store, the answer bounds
// (below), and the identities of the event counts. The first discrepancy stops the run with the
// configuration, the cycle, the signal and both values.
//
// Answer bounds, computed from the memory's configured maximum latencies (RD read, WR write, B the
// beat latency in burst mode, else RD; n words per line): D = max(RD, WR) + 1 cycles for a data
// transfer, R = (RD + 1) + (n - 1) * (B + 1) for a refill block. A data request is answered within
// R + D cycles of its first cycle; a granted refill's last beat within R cycles of its first
// granted cycle; and, while the data driver behaves like the CPU (below), a refill is granted
// within K_OLDER * D cycles of its first refill cycle. The cycle in which an interval starts is
// its cycle 1; an interval that meets a reset is dropped.
//
// Stimulus, from a seeded generator: sequential fetches, held addresses, jumps in any cycle (to
// any line, cached lines, the line being refilled, both ends of the window and just outside it,
// out-of-window aliases of cached lines that differ only in an address bit above the window),
// error loops, and garbage on the fetch bus in cycles without a request. Loads and stores with
// the byte enables of sb, sh and sw and random data on the unselected lanes, held until
// answered, back to back or with gaps, and I/O-like intervals (cyc without stb, as slave 0 sees
// every I/O access). The data driver works in two modes: like the CPU, where at most K_OLDER = 3
// data transfers hold the port from a miss cycle up to that refill's first grant and at most two
// of them begin after the miss cycle (the instructions older than a missing fetch); or freely,
// where it may keep a refill waiting. Resets at random cycles, more often during refills and
// waits, sometimes several cycles long; during a reset the memory model may change memory, so a
// line wrongly kept valid shows as wrong data. Directed sequences add the rare cases (a store
// that hits the line which a miss in the same cycle evicts, three data transfers of the longest
// duration from a miss cycle on, two hot loops one cache size apart), and the bench counts every
// case it is meant to reach.
//
// Configurations (cache bytes, line bytes): (16, 8), (512, 16), (8192, 16), (512, 8), (512, 32),
// (512, 64), (128, 64), each with a window of 8 lines and with the 32 KiB RAM window, each run
// through five memory profiles (latency 0; latency 2; random 1-8; random 1-64; DRAM-like: reads
// 8-24, writes 1-4, one cycle per further refill beat), with a reset between profiles; and the
// system configuration: (512, 16) with the RAM window and the real memory wrapper
// (sim/slow_memory.sv, port "memory") and RAM (lib/wishbone/wishbone_ram.sv) behind the arbiter,
// configured by the wrapper's own run-time options (+mem_lat ...). The end of the run prints one
// line per configuration and one of:
//     ICACHE BENCH: PASS (<configurations>, <cycles>, 0 mismatches)        exit status 0
//     ICACHE BENCH: FAIL (<reason>)                                        exit status 1
//     ICACHE BENCH: COMPARE OFF (<configurations>, <cycles>)               exit status 1
//
// Run-time options:
//   +seed=<n>             seed of the stimulus (default 1). The cache's random initial arrays
//                         follow +mem_seed, as in the system simulators.
//   +cycles=<n>           cycles per configuration and memory profile (default 1000000; the
//                         system configuration runs <n> cycles in all)
//   +only=<name>[,...]    run only the named configurations (the names of the result lines)
//   +cover=0              print the coverage counts without judging them (for short runs)
//   +compare=0            the bench's own checks (the comparison, the memory checks, the bounds,
//                         the identities) report nothing, so that only the assertions inside the
//                         cache and the arbiter can stop the run; it ends with COMPARE OFF
//   +compare=bounds       as +compare=0, but the answer bounds are still checked (so that a fault
//                         which breaks a bound, and which the comparison would see first, is
//                         shown by the bound's own message); it ends with COMPARE OFF as well
//   +negative=<case>      inject one fault in configuration icache512-line16-ram; an assertion of
//                         the design must stop the run, otherwise the bench fails 32 cycles
//                         later. Cases: fetch-write (the fetch bus presents we = 1),
//                         request-change (a granted data request changes before its answer),
//                         ack-err (the memory answers a data transfer with ack and err),
//                         refill-err (the memory answers a refill beat with err),
//                         spontaneous-answer (the memory answers in a cycle without a request)
//   +mem_lat=..., +mem_rd_lat=..., +mem_wr_lat=..., +mem_beat_lat=..., +mem_seed=...
//                         the memory wrapper of the system configuration (sim/slow_memory.sv)
// ---------------------------------------------------------------------------------------------

// =============================================================================================
// Reference model
// =============================================================================================

module icache_ref #(
    parameter int unsigned BYTES        = 512,
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

    // Interconnect slave 0, as the data bus presents it
    input  logic        d_cyc,
    input  logic        d_stb,
    input  logic        d_we,
    input  logic [31:0] d_adr,
    input  logic  [3:0] d_sel,
    input  logic [31:0] d_dat,

    // The memory's answer on the single port
    input  logic        m_ack,
    input  logic        m_err,
    input  logic [31:0] m_dat,

    // Expected outputs in this cycle
    output logic        x_f_ack,        // fetch bus
    output logic        x_f_err,
    output logic [31:0] x_f_dat,        // meaningful with x_f_ack
    output logic        x_i_cyc,        // the cache's refill request
    output logic        x_i_stb,
    output logic [31:0] x_i_adr,
    output logic        x_i_cont,
    output logic        x_m_cyc,        // the memory port
    output logic        x_m_stb,
    output logic [31:0] x_m_adr,
    output logic        x_m_we,
    output logic  [3:0] x_m_sel,
    output logic [31:0] x_m_dat,
    output logic        x_m_cont,
    output logic        x_d_ack,        // the arbiter's data side
    output logic        x_d_err,
    output logic [31:0] x_d_dat,
    output logic        x_r_ack,        // the arbiter's refill side
    output logic        x_r_err,
    output logic [31:0] x_r_dat,
    // Events, in this order: hit, miss, beat, fill, abandoned, snoop invalidation, refill waits
    // for the port, data side waits for the port, port used by a refill, port used by a data
    // transfer, load answered on the port, store answered on the port, refill cycle
    output logic [12:0] x_ev,

    // For the bench's stimulus and coverage
    output logic        o_refill,       // the cache is refilling in this cycle
    output logic        o_gd,           // the data side is granted in this cycle
    output logic        o_gi,           // the refill is granted in this cycle
    output logic        o_snoop         // a store is acknowledged at slave 0 in this cycle
);
    localparam int unsigned LW   = LINE_BYTES / 4;      // words per line
    localparam int unsigned O    = $clog2(LW);          // word-in-line bits
    localparam int unsigned SETS = BYTES / LINE_BYTES;
    localparam int unsigned I    = $clog2(SETS);        // index bits
    localparam int unsigned T    = 30 - I - O;          // tag bits

    localparam int OWNER_NONE = 0, OWNER_DATA = 1, OWNER_REFILL = 2;

    // ---- explicit state ----
    bit              refilling;       // 0: lookup, 1: refill
    int unsigned     beat;            // the refill beat being requested, 0 .. LW-1
    bit   [29:0]     line;            // the refilled line: word address >> O
    bit   [SETS-1:0] valid;
    bit   [T-1:0]    tags  [SETS];
    bit   [31:0]     words [SETS*LW];
    int              owner;           // who holds the memory port across cycles

    initial begin
        refilling = 0;
        beat      = 0;
        line      = '0;
        valid     = '0;
        owner     = OWNER_NONE;
        for (int k = 0; k < SETS; k++) tags[k] = '0;
        for (int k = 0; k < SETS * LW; k++) words[k] = '0;
    end

    function automatic int unsigned set_of(bit [31:0] a);
        return int'((a >> O) & (SETS - 1));
    endfunction
    function automatic bit [T-1:0] tag_of(bit [31:0] a);
        return T'(a >> (O + I));
    endfunction
    function automatic bit [29:0] line_of(bit [31:0] a);
        return 30'(a[29:0] >> O);
    endfunction
    function automatic bit in_window(bit [31:0] a);
        return a >= WINDOW_START && a < WINDOW_START + WINDOW_WORDS;
    endfunction

    // ---- the step of one cycle: everything that does not depend on the memory's answer ----
    bit          req, inwin, hit, miss, d_req, i_req, port_free, gd, gi;
    int unsigned s, w;

    always_comb begin
        req   = f_cyc && f_stb;
        inwin = in_window(f_adr);
        s     = set_of(f_adr);
        w     = int'(f_adr & (LW - 1));
        hit   = req && valid[s] && tags[s] == tag_of(f_adr) && f_adr[31:30] == 2'b00;

        // fetch bus: a hit only while looking up; err for every request outside the window
        x_f_ack = !refilling && hit;
        x_f_err = req && !inwin;
        x_f_dat = words[s * LW + w];
        miss    = !refilling && req && inwin && !hit;

        // refill request: one word per cycle until it is answered
        x_i_cyc  = refilling;
        x_i_stb  = refilling;
        x_i_adr  = {2'b00, line} << O | 32'(beat);
        x_i_cont = refilling && beat != 0;

        // arbiter: the data side first on a free port; a grant lasts its transfer or block
        d_req     = d_cyc && d_stb;
        i_req     = x_i_cyc && x_i_stb;
        port_free = owner == OWNER_NONE || (owner == OWNER_REFILL && !i_req);
        gd        = d_req && (owner == OWNER_DATA || port_free);
        gi        = i_req && (owner == OWNER_REFILL || (port_free && !d_req));

        x_m_cyc  = gd ? 1'b1  : gi ? 1'b1     : 1'b0;
        x_m_stb  = gd ? 1'b1  : gi ? 1'b1     : 1'b0;
        x_m_adr  = gd ? d_adr : gi ? x_i_adr  : 32'h0;
        x_m_we   = gd ? d_we  : 1'b0;
        x_m_sel  = gd ? d_sel : gi ? 4'b1111  : 4'b0000;
        x_m_dat  = gd ? d_dat : 32'h0;
        x_m_cont = gi && x_i_cont;

        o_refill = refilling;
        o_gd     = gd;
        o_gi     = gi;
    end

    // ---- the step of one cycle: everything that depends on the memory's answer ----
    bit          beat_answer, last_beat, snoop, snoop_hit, abandoned;
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

        snoop     = d_cyc && d_stb && d_we && x_d_ack;
        ss        = set_of(d_adr);
        snoop_hit = snoop && valid[ss] && tags[ss] == tag_of(d_adr);
        o_snoop   = snoop;

        x_ev[0]  = x_f_ack;                    // hit
        x_ev[1]  = miss;                       // miss
        x_ev[2]  = beat_answer;                // beat
        x_ev[3]  = last_beat;                  // fill
        x_ev[4]  = abandoned;                  // abandoned refill
        x_ev[5]  = snoop_hit;                  // snoop invalidation
        x_ev[6]  = i_req && !gi;               // refill waits for the port
        x_ev[7]  = d_req && !gd;               // data side waits for the port
        x_ev[8]  = gi;                         // port used by a refill
        x_ev[9]  = gd;                         // port used by a data transfer
        x_ev[10] = gd && m_ack && !d_we;       // load answered on the port
        x_ev[11] = gd && m_ack && d_we;        // store answered on the port
        x_ev[12] = refilling;                  // refill cycle
        if (rst) x_ev = '0;
    end

    // ---- the end of the cycle ----
    always @(posedge clk) begin
        if (rst) begin
            refilling <= 0;
            beat      <= 0;
            valid     <= '0;
            owner     <= OWNER_NONE;
        end
        else begin
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
// One configuration: the design, its environment, the reference model and the checks
// =============================================================================================

module icache_bench_env #(
    parameter string       NAME         = "",
    parameter int unsigned BYTES        = 512,
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
    localparam int unsigned LW    = LINE_BYTES / 4;
    localparam int unsigned O     = $clog2(LW);
    localparam int unsigned SETS  = BYTES / LINE_BYTES;
    localparam int unsigned I     = $clog2(SETS);
    localparam bit   [31:0] WS    = WINDOW_START;
    localparam bit   [31:0] WW    = WINDOW_WORDS;
    localparam bit   [31:0] WEND  = WINDOW_START + WINDOW_WORDS;
    localparam int unsigned CW    = BYTES / 4;                 // cache size in words
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
    int unsigned cost_d, cost_r;                                // D and R of the profile in use

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
            $fatal(1, "ICACHE BENCH: +cycles=%0d: give at least 100", n);
        seg_cycles = n;
        if ($test$plusargs("compare=0")) begin
            compare_on = 0;
            bounds_on  = 0;
        end
        if ($test$plusargs("compare=bounds")) compare_on = 0;
        if ($value$plusargs("negative=%s", text)) begin
            if (text != "fetch-write" && text != "request-change" && text != "ack-err" &&
                text != "refill-err" && text != "spontaneous-answer")
                $fatal(1, "ICACHE BENCH: +negative=%s: give fetch-write, request-change, ack-err, refill-err or spontaneous-answer", text);
            negative = text;
        end
        if ($value$plusargs("only=%s", text)) selected = name_listed(text, NAME);
        inject_here   = negative != "" && NAME == "icache512-line16-ram";
        profile_start = inject_here ? 1 : 0;     // inject under latency 2 (requests that wait)
        total_cycles  = SYSTEM ? seg_cycles : seg_cycles * NPROF;
    end

    // ---------------------------------------------------------------------------------------
    // Buses, the design under test, the reference model
    // ---------------------------------------------------------------------------------------
    logic rst;

    wishbone_interface fetch_bus ();
    wishbone_interface data_bus ();
    wishbone_interface icache_mem ();
    wishbone_interface memory_port ();
    logic icache_mem_cont, memory_port_cont;

    logic snoop_store;
    assign snoop_store = data_bus.cyc && data_bus.stb && data_bus.we && data_bus.ack;

    logic ev_hit, ev_miss, ev_beat, ev_fill, ev_abandoned, ev_snoop_inval, ev_refill;
    logic ev_wait_i, ev_wait_d, ev_grant_i, ev_grant_d, ev_port_load, ev_port_store;
    logic [12:0] dut_ev;
    assign dut_ev = {ev_refill, ev_port_store, ev_port_load, ev_grant_d, ev_grant_i, ev_wait_d,
                     ev_wait_i, ev_snoop_inval, ev_abandoned, ev_fill, ev_beat, ev_miss, ev_hit};

    icache #(
        .BYTES        (BYTES),
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

    mem_arbiter mem_arbiter (
        .clk           (clk),
        .rst           (rst),
        .data          (data_bus.slave),
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

    logic        x_f_ack, x_f_err, x_i_cyc, x_i_stb, x_i_cont, x_m_cyc, x_m_stb, x_m_we, x_m_cont;
    logic        x_d_ack, x_d_err, x_r_ack, x_r_err;
    logic [31:0] x_f_dat, x_i_adr, x_m_adr, x_m_dat, x_d_dat, x_r_dat;
    logic  [3:0] x_m_sel;
    logic [12:0] x_ev;
    logic        o_refill, o_gd, o_gi, o_snoop;

    icache_ref #(
        .BYTES        (BYTES),
        .LINE_BYTES   (LINE_BYTES),
        .WINDOW_START (WINDOW_START),
        .WINDOW_WORDS (WINDOW_WORDS)
    ) model (
        .clk (clk), .rst (rst),
        .f_cyc (fetch_bus.cyc), .f_stb (fetch_bus.stb), .f_adr (fetch_bus.adr),
        .d_cyc (data_bus.cyc), .d_stb (data_bus.stb), .d_we (data_bus.we), .d_adr (data_bus.adr),
        .d_sel (data_bus.sel), .d_dat (data_bus.dat_mosi),
        .m_ack (memory_port.ack), .m_err (memory_port.err), .m_dat (memory_port.dat_miso),
        .x_f_ack, .x_f_err, .x_f_dat, .x_i_cyc, .x_i_stb, .x_i_adr, .x_i_cont,
        .x_m_cyc, .x_m_stb, .x_m_adr, .x_m_we, .x_m_sel, .x_m_dat, .x_m_cont,
        .x_d_ack, .x_d_err, .x_d_dat, .x_r_ack, .x_r_err, .x_r_dat, .x_ev,
        .o_refill, .o_gd, .o_gi, .o_snoop
    );

    // ---------------------------------------------------------------------------------------
    // Memory: the bench's model of the window, which is also the reference for the checks
    // ---------------------------------------------------------------------------------------
    bit [31:0] mem [WINDOW_WORDS];     // the window's words, index = word address - WS

    // Words changed while the cache is held in reset (applied at the end of a reset cycle)
    bit [31:0] bd_idx [4];
    bit [31:0] bd_val [4];
    int        bd_n;

    // Memory model state (unused in the system configuration)
    bit          m_held, m_h_we, m_h_burst, m_in_block, m_last_we;
    bit   [31:0] m_h_adr, m_h_dat, m_last_adr;
    bit    [3:0] m_h_sel;
    int unsigned m_h_left, m_h_lat, m_pre_rd, m_pre_wr;
    // Fault injection of +negative (memory side)
    bit          inj_ack_err, inj_refill_err, inj_spontaneous;

    // Combinational view of the memory's answer (both kinds of memory)
    bit          m_req, m_answer, m_burst, m_cur_burst;
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
                answer  = m_req && left == 0 && !rst;      // nothing is answered in a reset cycle
                m_answer = answer;
                inwin   = memory_port.adr - WS < WW;
                word    = mem[inwin ? memory_port.adr - WS : 0];
                ack     = answer && inwin;
                err     = answer && !inwin;
                // faults of +negative
                if (inj_ack_err && answer && o_gd) begin ack = 1; err = 1; end
                if (inj_refill_err && answer && o_gi) begin ack = 0; err = 1; end
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
            end

            // The RAM starts with the bench's memory (after its own initial block)
            initial begin
                #1;
                for (int k = 0; k < WINDOW_WORDS; k++) ram.memory[k] = mem[k];
                sys_rd_max = int'(memory_delay.rd_max);
                sys_wr_max = int'(memory_delay.wr_max);
                sys_beat   = memory_delay.beat_lat;
            end

            // Changes made while the cache is held in reset reach the RAM too
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
    function automatic int unsigned set_of(bit [31:0] a);
        return int'((a >> O) & (SETS - 1));
    endfunction
    function automatic bit [29:0] line_of(bit [31:0] a);
        return 30'(a[29:0] >> O);
    endfunction
    function automatic bit in_window(bit [31:0] a);
        return a >= WS && a < WEND;
    endfunction
    // the in-window line address held by the model in set s (valid or not)
    function automatic bit [31:0] model_line_adr(int unsigned s);
        return (32'(model.tags[s]) << (O + I)) | (32'(s) << O);
    endfunction
    // a word of a line that the model holds valid, or 0 if it found none
    function automatic bit [31:0] cached_word();
        for (int k = 0; k < 6; k++) begin
            int unsigned s = below(SETS);
            if (model.valid[s]) return model_line_adr(s) | below(LW);
        end
        return 0;
    endfunction
    function automatic bit [31:0] window_word();
        return WS + below(WW);
    endfunction
    // the out-of-window alias of address a whose bits above the window are cleared (or a itself)
    function automatic bit [31:0] alias_base(bit [31:0] a);
        return a & ((32'h1 << (TOP + 1)) - 1);
    endfunction

    // ---------------------------------------------------------------------------------------
    // Coverage
    // ---------------------------------------------------------------------------------------
    localparam int NITEMS = 26;
    localparam int CV_REDIRECT_WAIT = 0, CV_SNOOP_REFILL_LINE = 1, CV_HIT_STORE_SAME_LINE = 2,
                   CV_STORE_SECOND_LOOKUP = 3, CV_CONSECUTIVE_STORES = 4, CV_STORE_EVICTED = 5,
                   CV_RESET_WAIT = 6, CV_MISS_AND_DATA = 7, CV_DATA_DURING_REFILL = 8,
                   CV_DATA_SECOND_LOOKUP = 9, CV_GRANT_AT_BOUND = 10, CV_CACHED_DURING_REFILL = 11,
                   CV_WINDOW_FIRST = 12, CV_WINDOW_LAST = 13, CV_BELOW_WINDOW = 14,
                   CV_ABOVE_WINDOW = 15, CV_ALIAS = 16, CV_HOT_LOOPS = 17, CV_ABANDONED = 18,
                   CV_BACK_TO_BACK_MISS = 19, CV_HIT_WHILE_DATA = 20, CV_LAT0 = 21, CV_LAT1 = 22,
                   CV_LAT8 = 23, CV_LAT64 = 24, CV_BURST = 25;
    string cv_name [NITEMS] = '{
        "redirect while the refill waits", "store to the refill line before its grant",
        "hit and store to its line in one cycle", "store to the filled line in the second lookup",
        "stores to two cached lines in consecutive cycles", "store to the line a miss evicts, same cycle",
        "reset while the refill waits", "miss and data request in one cycle",
        "data request arriving during a refill", "data transfer answered in the second lookup",
        "refill granted exactly at its bound", "lookup of a cached line during a refill",
        "first word of the window", "last word of the window", "word just below the window",
        "word just above the window", "out-of-window alias of a cached line",
        "switch between hot loops one cache size apart", "abandoned refill",
        "miss in the second lookup", "hit while a data transfer holds the port",
        "refill beat at latency 0", "refill beat at latency 1", "refill beat at latency 8",
        "refill beat at latency 64", "refill beat at the burst latency"};
    longint cv [NITEMS];
    bit     cv_na [NITEMS];
    longint cv_redirect_beat [LW];
    longint cv_reset_beat [LW];
    longint cv_io_beat [LW];
    localparam int COVER_ITEM  = 20;
    localparam int COVER_EVENT = 1000;
    string ev_name [13] = '{"hit", "miss", "beat", "fill", "abandoned", "snoop_inval", "wait_i",
                            "wait_d", "grant_i", "grant_d", "port_load", "port_store", "refill"};
    longint dut_count [13];      // the design's event pulses over the run
    longint ref_count [13];      // the model's
    longint seg_count [13];      // the design's since the last reset

    // A window that can hold two loops of two lines one cache size apart
    localparam bit HOT_LOOPS_FIT = WW >= CW + 2 * LW;
    // Two window lines that share a set
    localparam bit SET_SHARED = WW > SETS * LW;

    initial begin
        for (int k = 0; k < NITEMS; k++) begin cv[k] = 0; cv_na[k] = 0; end
        for (int k = 0; k < LW; k++) begin
            cv_redirect_beat[k] = 0; cv_reset_beat[k] = 0; cv_io_beat[k] = 0;
        end
        for (int k = 0; k < 13; k++) begin dut_count[k] = 0; ref_count[k] = 0; seg_count[k] = 0; end
        if (!SET_SHARED) cv_na[CV_STORE_EVICTED] = 1;
        if (!HOT_LOOPS_FIT) cv_na[CV_HOT_LOOPS] = 1;
        if (SYSTEM) begin
            // latency 0 and forced latencies are not available with the wrapper's profile
            cv_na[CV_STORE_SECOND_LOOKUP] = 1;
            cv_na[CV_CONSECUTIVE_STORES]  = 1;
            cv_na[CV_STORE_EVICTED]       = 1;
            cv_na[CV_DATA_SECOND_LOOKUP]  = 1;
            cv_na[CV_GRANT_AT_BOUND]      = 1;
            for (int k = CV_LAT0; k <= CV_BURST; k++) cv_na[k] = 1;
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

    // data driver
    bit        d_busy;               // a request is presented and not yet answered
    int        io_left;              // remaining cycles of an I/O-like interval
    bit        cpu_like;             // the data driver behaves like the CPU after a miss
    bit        waiting_grant;        // between a miss cycle and its refill's first grant
    int        older_left;           // transfers that may still begin in that interval
    bit        d_prev_req;

    // directed sequences
    int        ko_left;              // longest data transfers still to start back to back
    bit        ko_we;
    int        hl_switches;          // hot loops: 0 off, else the loop switches still to make
    bit [31:0] hl_base [2];
    int        hl_which, hl_iter;
    bit        force_max, force_min; // latency draws at the profile's maximum / minimum

    // bounds
    longint unsigned b_data, b_grant, b_last;   // interval counters, 0: none open
    bit              b_grant_on, refill_granted;
    longint          max_data_wait [5], max_grant_wait [5], max_refill [5];   // per profile
    int unsigned     prof_cost_r [5], prof_cost_d [5];

    // coverage history
    bit        prev_fill;
    bit [29:0] prev_fill_line;
    bit        prev_snoop_inval;
    bit [29:0] prev_snoop_line;

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
        f_pc = WS; f_prev_req = 0; f_prev_adr = 0;
        d_busy = 0; io_left = 0; cpu_like = 1; waiting_grant = 0; older_left = 0; d_prev_req = 0;
        ko_left = 0; ko_we = 0; hl_switches = 0; hl_which = 0; hl_iter = 0;
        hl_base[0] = WS; hl_base[1] = WS;
        force_max = 0; force_min = 0;
        b_data = 0; b_grant = 0; b_last = 0; b_grant_on = 0; refill_granted = 0;
        for (int k = 0; k < 5; k++) begin
            max_data_wait[k] = 0; max_grant_wait[k] = 0; max_refill[k] = 0;
            prof_cost_r[k] = 0; prof_cost_d[k] = 0;
        end
        prev_fill = 0; prev_fill_line = 0; prev_snoop_inval = 0; prev_snoop_line = 0;
        injected = 0; inject_cycle = 0;
        bd_n = 0;
        for (int k = 0; k < 4; k++) begin bd_idx[k] = 0; bd_val[k] = 0; end
        m_held = 0; m_h_we = 0; m_h_burst = 0; m_in_block = 0; m_last_we = 0;
        m_h_adr = 0; m_h_dat = 0; m_last_adr = 0; m_h_sel = 0; m_h_left = 0; m_h_lat = 0;
        m_pre_rd = 0; m_pre_wr = 0;
        inj_ack_err = 0; inj_refill_err = 0; inj_spontaneous = 0;
        profile = 0;
        rd_min = 0; rd_max = 0; wr_min = 0; wr_max = 0; beat_lat = -1;
        sys_rd_max = 0; sys_wr_max = 0; sys_beat = -1;
        cost_d = 1; cost_r = LW;
    end

    // ---------------------------------------------------------------------------------------
    // Reporting
    // ---------------------------------------------------------------------------------------
    function automatic string state_text();
        return $sformatf("model: %s beat %0d line 0x%08x owner %0d; profile %s; data driver %s",
                         model.refilling ? "refill" : "lookup", model.beat,
                         32'(model.line) << O, model.owner,
                         SYSTEM ? "memory wrapper" : prof_name[profile],
                         cpu_like ? "CPU-like" : "free");
    endfunction

    task automatic fail(string what);
        mismatches++;
        $display("ICACHE BENCH: configuration %s (cache %0d bytes, %0d-byte lines, window 0x%08x + 0x%0x words), seed %0d",
                 NAME, BYTES, LINE_BYTES, WS, WW, seed);
        $display("ICACHE BENCH: cycle %0d: %s", cycle, what);
        $display("ICACHE BENCH: %s", state_text());
        $display("ICACHE BENCH: FAIL (configuration %s, cycle %0d: %s)", NAME, cycle, what);
        $fatal(1, "the I-cache bench failed");
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
        // the cache's refill request
        cmp("refill cyc", icache_mem.cyc, x_i_cyc);
        cmp("refill stb", icache_mem.stb, x_i_stb);
        cmp("refill continuation tag", icache_mem_cont, x_i_cont);
        if (x_i_cyc && x_i_stb) begin
            cmp("refill adr", icache_mem.adr, x_i_adr);
            cmp("refill we", icache_mem.we, 0);
            cmp("refill sel", icache_mem.sel, 4'b1111);
            cmp("refill dat_mosi", icache_mem.dat_mosi, 0);
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
        cmp("data ack", data_bus.ack, x_d_ack);
        cmp("data err", data_bus.err, x_d_err);
        cmp("data dat_miso", data_bus.dat_miso, x_d_dat);
        cmp("refill-side ack", icache_mem.ack, x_r_ack);
        cmp("refill-side err", icache_mem.err, x_r_err);
        cmp("refill-side dat_miso", icache_mem.dat_miso, x_r_dat);
        // events
        for (int k = 0; k < 13; k++)
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
        if (data_bus.ack && data_bus.cyc && data_bus.stb && !data_bus.we && in_window(data_bus.adr) &&
            data_bus.dat_miso != mem[data_bus.adr - WS])
            fail($sformatf("load of 0x%08x answered 0x%08x, memory holds 0x%08x",
                           data_bus.adr, data_bus.dat_miso, mem[data_bus.adr - WS]));
        if (icache_mem.cyc && icache_mem.stb &&
            (icache_mem.we || icache_mem.sel != 4'b1111 || icache_mem.dat_mosi != 0))
            fail($sformatf("the cache's refill request writes: we %0b sel %04b dat_mosi 0x%08x",
                           icache_mem.we, icache_mem.sel, icache_mem.dat_mosi));
        mw = memory_port.cyc && memory_port.stb && memory_port.we && memory_port.ack;
        ds = data_bus.cyc && data_bus.stb && data_bus.we && data_bus.ack;
        if (mw != ds)
            fail($sformatf("%0d memory write(s) answered against %0d answered data store(s)", mw, ds));
        else if (mw && (memory_port.adr != data_bus.adr || memory_port.sel != data_bus.sel ||
                        memory_port.dat_mosi != data_bus.dat_mosi))
            fail($sformatf("memory write 0x%08x sel %04b data 0x%08x differs from the data store 0x%08x sel %04b data 0x%08x",
                           memory_port.adr, memory_port.sel, memory_port.dat_mosi,
                           data_bus.adr, data_bus.sel, data_bus.dat_mosi));
    endtask

    // ---------------------------------------------------------------------------------------
    // The step at the end of every cycle
    // ---------------------------------------------------------------------------------------
    always @(posedge clk) begin : step
        bit        checking, bchecking, reset_now, next_rst, d_req, f_req, d_done, new_seg;
        bit        fill_now, snoop_now, inval_now, scenario_fetch, scenario_data;
        bit [31:0] next_f_adr, a, sd_adr, sd_dat;
        bit  [3:0] sd_sel;
        bit        sd_we;
        int        r;

        reset_now = rst;
        f_req     = fetch_bus.cyc && fetch_bus.stb;
        d_req     = data_bus.cyc && data_bus.stb;
        fill_now  = x_ev[3];
        snoop_now = o_snoop;
        inval_now = x_ev[5];
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
                 (negative == "refill-err" && memory_port.err && o_gi) ||
                 (negative == "spontaneous-answer" && memory_port.ack &&
                  !(memory_port.cyc && memory_port.stb)))) begin
                injected = 1;
                inject_cycle = cycle;
                checking = 0;
                bchecking = 0;
                inj_ack_err <= 0; inj_refill_err <= 0; inj_spontaneous <= 0;
                $display("ICACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                         NAME, negative, cycle);
            end
            if (inject_here && injected && cycle >= inject_cycle + 32) begin
                $display("ICACHE BENCH: FAIL (negative case %s: injected in cycle %0d of configuration %s, nothing stopped the run within 32 cycles)",
                         negative, inject_cycle, NAME);
                $fatal(1, "the I-cache bench failed");
            end

            // ---- compare and check the cycle that ends now ----
            if (checking && cycle >= 1) compare_cycle();
            if (checking && !reset_now) memory_checks();

            // ---- event counts and their identities ----
            for (int k = 0; k < 13; k++) begin
                dut_count[k] += dut_ev[k];
                ref_count[k] += x_ev[k];
            end
            if (reset_now || cycle + 1 == total_cycles) begin
                // a reset cycle or the last cycle: check the counts since the last reset
                if (checking && !(reset_now && cycle == 0)) begin
                    longint inflight, inflight_beats;
                    if (reset_now) begin
                        // the counts end with the previous cycle; the state is the one after it
                        inflight       = model.refilling;
                        inflight_beats = model.refilling ? model.beat : 0;
                    end
                    else begin
                        // the last cycle: count it, and take the state after its edge
                        for (int k = 0; k < 13; k++) seg_count[k] += dut_ev[k];
                        inflight       = x_ev[1] || (model.refilling && !x_ev[3]);
                        inflight_beats = (model.refilling && !x_ev[3]) ? model.beat + x_ev[2] : 0;
                    end
                    if (seg_count[1] != seg_count[3] + inflight)
                        fail($sformatf("event counts: %0d misses, %0d fills, %0d refill in flight",
                                       seg_count[1], seg_count[3], inflight));
                    if (seg_count[12] != seg_count[6] + seg_count[8])
                        fail($sformatf("event counts: %0d refill cycles, %0d waiting, %0d granted",
                                       seg_count[12], seg_count[6], seg_count[8]));
                    if (seg_count[2] != LW * seg_count[3] + inflight_beats)
                        fail($sformatf("event counts: %0d beats, %0d fills of %0d words, %0d beats in flight",
                                       seg_count[2], seg_count[3], LW, inflight_beats));
                end
                for (int k = 0; k < 13; k++) seg_count[k] = 0;
            end
            else begin
                for (int k = 0; k < 13; k++) seg_count[k] += dut_ev[k];
            end

            // ---- bounds ----
            if (reset_now) begin
                b_data = 0; b_grant = 0; b_last = 0; b_grant_on = 0; refill_granted = 0;
            end
            else begin
                // a data request is answered within R + D cycles
                if (d_req) begin
                    b_data++;
                    if (data_bus.ack || data_bus.err) begin
                        if (longint'(b_data) > max_data_wait[profile]) max_data_wait[profile] = b_data;
                        b_data = 0;
                    end
                    else if (b_data >= cost_r + cost_d && bchecking)
                        fail($sformatf("data request 0x%08x not answered within %0d cycles (R %0d + D %0d)",
                                       data_bus.adr, cost_r + cost_d, cost_r, cost_d));
                end
                else b_data = 0;
                // measured on the design's own event outputs: ev_miss, ev_refill (a refill
                // cycle), ev_grant_i (the refill holds the port), ev_fill (its last beat)
                // a refill is granted within K_OLDER * D cycles (CPU-like data side only)
                if (ev_refill && b_grant_on) begin
                    b_grant++;
                    if (ev_grant_i) begin
                        if (longint'(b_grant) > max_grant_wait[profile]) max_grant_wait[profile] = b_grant;
                        if (b_grant == K_OLDER * cost_d) cv[CV_GRANT_AT_BOUND]++;
                        b_grant_on = 0;
                    end
                    else if (b_grant >= K_OLDER * cost_d && bchecking)
                        fail($sformatf("refill of line 0x%08x not granted within %0d cycles (%0d older transfers of D %0d)",
                                       32'(model.line) << O, K_OLDER * cost_d, K_OLDER, cost_d));
                end
                // a granted refill's last beat is answered within R cycles
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
                        fail($sformatf("refill of line 0x%08x: last beat not answered within R = %0d cycles of its grant",
                                       32'(model.line) << O, cost_r));
                end
                if (ev_miss) begin           // a miss: the refill interval starts next cycle
                    b_grant_on     = cpu_like;
                    b_grant        = 0;
                    refill_granted = 0;
                end
            end

            // ---- coverage ----
            if (reset_now) begin
                if (cycle >= 2 && model.refilling) begin
                    if (o_gi) cv_reset_beat[model.beat]++;
                    else      cv[CV_RESET_WAIT]++;
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
                    if (f_req && model.valid[set_of(fetch_bus.adr)] && fetch_bus.adr[31:30] == 0 &&
                        model_line_adr(set_of(fetch_bus.adr)) == (fetch_bus.adr & ~32'(LW - 1)))
                        cv[CV_CACHED_DURING_REFILL]++;
                end
                if (x_f_ack && snoop_now && line_of(fetch_bus.adr) == line_of(data_bus.adr))
                    cv[CV_HIT_STORE_SAME_LINE]++;
                if (prev_fill && snoop_now && line_of(data_bus.adr) == prev_fill_line)
                    cv[CV_STORE_SECOND_LOOKUP]++;
                if (prev_fill && o_gd && x_d_ack) cv[CV_DATA_SECOND_LOOKUP]++;
                if (prev_fill && x_ev[1]) cv[CV_BACK_TO_BACK_MISS]++;
                if (inval_now && prev_snoop_inval && line_of(data_bus.adr) != prev_snoop_line)
                    cv[CV_CONSECUTIVE_STORES]++;
                if (x_ev[1] && inval_now && set_of(data_bus.adr) == set_of(fetch_bus.adr))
                    cv[CV_STORE_EVICTED]++;
                if (x_ev[1] && d_req) cv[CV_MISS_AND_DATA]++;
                if (x_ev[4]) cv[CV_ABANDONED]++;
                if (x_ev[0] && o_gd) cv[CV_HIT_WHILE_DATA]++;
                if (f_req) begin
                    if (fetch_bus.adr == WS)        cv[CV_WINDOW_FIRST]++;
                    if (fetch_bus.adr == WEND - 1)  cv[CV_WINDOW_LAST]++;
                    if (fetch_bus.adr == WS - 1)    cv[CV_BELOW_WINDOW]++;
                    if (fetch_bus.adr == WEND)      cv[CV_ABOVE_WINDOW]++;
                    a = alias_base(fetch_bus.adr);
                    if (!model.refilling && a != fetch_bus.adr && in_window(a) &&
                        model.valid[set_of(a)] && model_line_adr(set_of(a)) == (a & ~32'(LW - 1)))
                        cv[CV_ALIAS]++;
                end
                if (o_gi && memory_port.ack && !SYSTEM) begin
                    if (m_cur_burst)          cv[CV_BURST]++;
                    else if (m_cur_lat == 0)  cv[CV_LAT0]++;
                    else if (m_cur_lat == 1)  cv[CV_LAT1]++;
                    else if (m_cur_lat == 8)  cv[CV_LAT8]++;
                    else if (m_cur_lat == 64) cv[CV_LAT64]++;
                end
            end
            prev_fill        = !reset_now && fill_now;
            prev_fill_line   = model.line;
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
                    // about one reset per eight refills, one per few data waits, rarely otherwise
                    int unsigned odds;
                    odds = model.refilling ? 8 * cost_r :
                           (d_req && !(data_bus.ack || data_bus.err)) ? 4 * (cost_r + cost_d) : 4000;
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
                    cost_d = int'(((rd_max > wr_max) ? rd_max : wr_max) + 1);
                    cost_r = int'((rd_max + 1) + (LW - 1) * (((beat_lat >= 0) ? beat_lat : rd_max) + 1));
                    prof_cost_r[profile] = cost_r;
                    prof_cost_d[profile] = cost_d;
                end
                rst <= next_rst;
                // memory changes during the next cycle if it is a reset cycle
                bd_n <= 0;
                if (next_rst && below(2) == 0) begin
                    int n;
                    n = 1 + int'(below(4));
                    for (int k = 0; k < n; k++) begin
                        bit [31:0] wa;
                        wa = cached_word();
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
                end
                else if (x_ev[1]) begin
                    waiting_grant = 1;
                    older_left    = K_OLDER - 1;
                end
                else if (o_gi) waiting_grant = 0;
                if (!waiting_grant && !model.refilling && ko_left == 0 && below(500) == 0)
                    cpu_like = below(4) != 0;

                // ---- directed sequences ----
                scenario_fetch = 0;
                scenario_data  = 0;
                force_max      = ko_left > 0;
                force_min      = 0;
                next_f_adr     = f_pc;
                sd_adr = 0; sd_dat = 0; sd_sel = 0; sd_we = 0;
                d_done = d_busy && (data_bus.ack || data_bus.err);
                if (!next_rst && !reset_now && ko_left == 0 && hl_switches == 0 && !model.refilling &&
                    !x_ev[1] && (!d_busy || d_done) && !injected && below(150) == 0) begin
                    r = int'(below(3));
                    if (r == 0 && SET_SHARED) begin
                        // a store to a cached line in the cycle in which a miss evicts it
                        bit [31:0] la, xa;
                        la = cached_word();
                        if (la != 0) begin
                            xa = la + 32'(SETS * LW) * (1 + below(4));
                            if (!in_window(xa)) xa = la - 32'(SETS * LW) * (1 + below(4));
                            if (in_window(xa)) begin
                                scenario_fetch = 1; next_f_adr = xa;
                                scenario_data  = 1; sd_adr = la; sd_we = 1; sd_sel = 4'b1111;
                                sd_dat = rnd();
                                force_min = 1;
                            end
                        end
                    end
                    else if (r == 1) begin
                        // the longest data transfers from the miss cycle on, back to back
                        bit [31:0] xa;
                        xa = window_word();
                        if (!(model.valid[set_of(xa)] &&
                              model_line_adr(set_of(xa)) == (xa & ~32'(LW - 1)))) begin
                            scenario_fetch = 1; next_f_adr = xa;
                            ko_left   = K_OLDER;
                            ko_we     = wr_max > rd_max;
                            cpu_like  = 1;
                            force_max = 1;
                        end
                    end
                    else if (r == 2 && HOT_LOOPS_FIT) begin
                        // two loops of two lines, one cache size apart
                        bit [31:0] base;
                        base = WS + below(WW - CW - 2 * LW + 1);
                        base = base & ~32'(LW - 1);
                        if (base < WS) base = WS;
                        hl_base[0] = base;
                        hl_base[1] = base + CW;
                        hl_which = 0;
                        hl_iter  = 0;
                        hl_switches = 3;
                        scenario_fetch = 1; next_f_adr = base;
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
                            pc = cached_word();
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
                            pc = cached_word();
                            if (pc == 0) pc = window_word();
                            pc = pc ^ (32'h1 << (TOP + 1 + below(31 - TOP)));
                        end
                        else if (r < 86) pc = rnd();
                        else begin
                            pc = (below(2) == 0) ? pc + CW : pc - CW;
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
                            0, 1:    ga = cached_word();       // 0 if no line is valid
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
                // +negative=fetch-write: one request with we = 1
                if (inject_here && negative == "fetch-write" && !injected && cycle >= 20 &&
                    !next_rst && !reset_now) begin
                    fetch_bus.cyc <= 1; fetch_bus.stb <= 1; fetch_bus.we <= 1;
                    fetch_bus.adr <= window_word();
                    injected = 1; inject_cycle = cycle + 1;
                    $display("ICACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                             NAME, negative, cycle + 1);
                end

                // ---- data driver ----
                if (reset_now) begin
                    // the CPU drops its request in reset and presents none in the next cycle
                    d_busy <= 0;
                    io_left = 0;
                    data_bus.cyc <= 0; data_bus.stb <= 0;
                    data_bus.adr <= rnd(); data_bus.we <= 0; data_bus.sel <= 0;
                end
                else if (d_busy && !d_done) begin
                    // held until answered; +negative=request-change changes it once
                    if (inject_here && negative == "request-change" && !injected && o_gd &&
                        cycle >= 20 && !next_rst) begin
                        bit [31:0] na;
                        na = window_word();
                        if (na == data_bus.adr) na = (na + 1 < WEND) ? na + 1 : WS;
                        data_bus.adr <= na;
                        injected = 1; inject_cycle = cycle + 1;
                        $display("ICACHE BENCH: configuration %s: negative case %s injected in cycle %0d",
                                 NAME, negative, cycle + 1);
                    end
                end
                else begin
                    bit allowed, start;
                    allowed = !(cpu_like && waiting_grant && older_left == 0);
                    start   = 0;
                    data_bus.cyc <= 0;       // idle unless one of the choices below drives it
                    data_bus.stb <= 0;
                    if (scenario_data) start = 1;
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
                            data_bus.cyc <= 0; data_bus.stb <= 0; data_bus.adr <= rnd();
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
                    if (start) begin
                        bit [31:0] da, dd;
                        bit        we;
                        bit  [3:0] sel;
                        dd = rnd();
                        if (scenario_data) begin
                            da = sd_adr; we = sd_we; sel = sd_sel; dd = sd_dat;
                        end
                        else begin
                            r = int'(below(100));
                            da = 0;
                            if (r < 40) da = cached_word();
                            else if (r < 55 && model.refilling) da = (32'(model.line) << O) | below(LW);
                            else if (r < 70 && in_window(fetch_bus.adr)) da = (fetch_bus.adr & ~32'(LW - 1)) | below(LW);
                            if (da == 0 || !in_window(da)) da = window_word();
                            we = ko_left > 0 ? ko_we : below(2) == 0;
                            case (below(3))
                                0: sel = 4'b1111;
                                1: sel = (below(2) == 0) ? 4'b0011 : 4'b1100;
                                default: sel = 4'(1 << below(4));
                            endcase
                        end
                        if (ko_left > 0) ko_left--;
                        if (waiting_grant && !scenario_data) older_left--;
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
                        inj_refill_err  <= negative == "refill-err";
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
            $display("ICACHE BENCH: configuration %s: not selected", NAME);
            return;
        end
        short_list = "";
        if (compare_on) begin
            for (int k = 0; k < 13; k++)
                if (dut_count[k] != ref_count[k])
                    short_list = {short_list, $sformatf(" event %s counted %0d by the design, %0d by the model;",
                                                        ev_name[k], dut_count[k], ref_count[k])};
        end
        if (short_list != "") begin
            $display("ICACHE BENCH: FAIL (configuration %s: event counts differ:%s)", NAME, short_list);
            $fatal(1, "the I-cache bench failed");
        end
        for (int k = 0; k < 13; k++)
            if (ref_count[k] < COVER_EVENT)
                short_list = {short_list, $sformatf(" event %s %0d;", ev_name[k], ref_count[k])};
        for (int k = 0; k < NITEMS; k++)
            if (!cv_na[k] && cv[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" %s %0d;", cv_name[k], cv[k])};
        for (int k = 0; k < LW; k++) begin
            if (cv_redirect_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" redirect at beat %0d %0d;", k, cv_redirect_beat[k])};
            if (cv_reset_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" reset at beat %0d %0d;", k, cv_reset_beat[k])};
            if (cv_io_beat[k] < COVER_ITEM)
                short_list = {short_list, $sformatf(" I/O-like data cycle at beat %0d %0d;", k, cv_io_beat[k])};
        end
        coverage_short = short_list != "";
        text = "";
        for (int k = 0; k < 13; k++) text = {text, $sformatf(" %s=%0d", ev_name[k], ref_count[k])};
        text = {text, "; longest waits against their bounds (data answer, refill grant, granted refill):"};
        for (int p = 0; p < NPROF; p++)
            text = {text, $sformatf(" %s %0d/%0d %0d/%0d %0d/%0d;",
                                    SYSTEM ? "memory wrapper" : prof_name[p],
                                    max_data_wait[p], prof_cost_r[p] + prof_cost_d[p],
                                    max_grant_wait[p], K_OLDER * prof_cost_d[p],
                                    max_refill[p], prof_cost_r[p])};
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
        $display("ICACHE BENCH: configuration %s: cache %0d bytes, %0d-byte lines, window 0x%08x + 0x%0x words, %0d cycles, %s; events%s coverage %s%s",
                 NAME, BYTES, LINE_BYTES, WS, WW, cycles_run, wrapper, text, verdict, short_list);
    endfunction
endmodule

// =============================================================================================
// Top: all configurations in one run
// =============================================================================================

module test_icache;
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

    icache_bench_env #(.NAME("icache16-line8-small"),    .BYTES(16),   .LINE_BYTES(8),  .WINDOW_START(RAM_START + 3 * 2),  .WINDOW_WORDS(8 * 2),  .NUMBER(0))  c0  (.clk, .done(done[0]),  .selected(sel[0]),  .cycles_run(cyc[0]),  .coverage_short(short_cov[0]));
    icache_bench_env #(.NAME("icache16-line8-ram"),      .BYTES(16),   .LINE_BYTES(8),  .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(1))  c1  (.clk, .done(done[1]),  .selected(sel[1]),  .cycles_run(cyc[1]),  .coverage_short(short_cov[1]));
    icache_bench_env #(.NAME("icache512-line16-small"),  .BYTES(512),  .LINE_BYTES(16), .WINDOW_START(RAM_START + 3 * 4),  .WINDOW_WORDS(8 * 4),  .NUMBER(2))  c2  (.clk, .done(done[2]),  .selected(sel[2]),  .cycles_run(cyc[2]),  .coverage_short(short_cov[2]));
    icache_bench_env #(.NAME("icache512-line16-ram"),    .BYTES(512),  .LINE_BYTES(16), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(3))  c3  (.clk, .done(done[3]),  .selected(sel[3]),  .cycles_run(cyc[3]),  .coverage_short(short_cov[3]));
    icache_bench_env #(.NAME("icache8192-line16-small"), .BYTES(8192), .LINE_BYTES(16), .WINDOW_START(RAM_START + 3 * 4),  .WINDOW_WORDS(8 * 4),  .NUMBER(4))  c4  (.clk, .done(done[4]),  .selected(sel[4]),  .cycles_run(cyc[4]),  .coverage_short(short_cov[4]));
    icache_bench_env #(.NAME("icache8192-line16-ram"),   .BYTES(8192), .LINE_BYTES(16), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(5))  c5  (.clk, .done(done[5]),  .selected(sel[5]),  .cycles_run(cyc[5]),  .coverage_short(short_cov[5]));
    icache_bench_env #(.NAME("icache512-line8-small"),   .BYTES(512),  .LINE_BYTES(8),  .WINDOW_START(RAM_START + 3 * 2),  .WINDOW_WORDS(8 * 2),  .NUMBER(6))  c6  (.clk, .done(done[6]),  .selected(sel[6]),  .cycles_run(cyc[6]),  .coverage_short(short_cov[6]));
    icache_bench_env #(.NAME("icache512-line8-ram"),     .BYTES(512),  .LINE_BYTES(8),  .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(7))  c7  (.clk, .done(done[7]),  .selected(sel[7]),  .cycles_run(cyc[7]),  .coverage_short(short_cov[7]));
    icache_bench_env #(.NAME("icache512-line32-small"),  .BYTES(512),  .LINE_BYTES(32), .WINDOW_START(RAM_START + 3 * 8),  .WINDOW_WORDS(8 * 8),  .NUMBER(8))  c8  (.clk, .done(done[8]),  .selected(sel[8]),  .cycles_run(cyc[8]),  .coverage_short(short_cov[8]));
    icache_bench_env #(.NAME("icache512-line32-ram"),    .BYTES(512),  .LINE_BYTES(32), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(9))  c9  (.clk, .done(done[9]),  .selected(sel[9]),  .cycles_run(cyc[9]),  .coverage_short(short_cov[9]));
    icache_bench_env #(.NAME("icache512-line64-small"),  .BYTES(512),  .LINE_BYTES(64), .WINDOW_START(RAM_START + 3 * 16), .WINDOW_WORDS(8 * 16), .NUMBER(10)) c10 (.clk, .done(done[10]), .selected(sel[10]), .cycles_run(cyc[10]), .coverage_short(short_cov[10]));
    icache_bench_env #(.NAME("icache512-line64-ram"),    .BYTES(512),  .LINE_BYTES(64), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(11)) c11 (.clk, .done(done[11]), .selected(sel[11]), .cycles_run(cyc[11]), .coverage_short(short_cov[11]));
    icache_bench_env #(.NAME("icache128-line64-small"),  .BYTES(128),  .LINE_BYTES(64), .WINDOW_START(RAM_START + 3 * 16), .WINDOW_WORDS(8 * 16), .NUMBER(12)) c12 (.clk, .done(done[12]), .selected(sel[12]), .cycles_run(cyc[12]), .coverage_short(short_cov[12]));
    icache_bench_env #(.NAME("icache128-line64-ram"),    .BYTES(128),  .LINE_BYTES(64), .WINDOW_START(RAM_START),          .WINDOW_WORDS(RAM_WORDS), .NUMBER(13)) c13 (.clk, .done(done[13]), .selected(sel[13]), .cycles_run(cyc[13]), .coverage_short(short_cov[13]));
    // the system configuration: the real memory wrapper and RAM, in the RAM window of the simulators
    icache_bench_env #(.NAME("system-icache512-line16"), .BYTES(512),  .LINE_BYTES(16), .WINDOW_START(constants::MEMORY_START), .WINDOW_WORDS(constants::MEMORY_SIZE), .SYSTEM(1), .NUMBER(14)) c14 (.clk, .done(done[14]), .selected(sel[14]), .cycles_run(cyc[14]), .coverage_short(short_cov[14]));

    initial begin
        bit     all_done, compare_on, cover_on, short_any;
        longint total;
        int     configs;
        compare_on = !$test$plusargs("compare=0") && !$test$plusargs("compare=bounds");
        cover_on   = !$test$plusargs("cover=0");
        do begin
            @(posedge clk);
            #1;
            all_done = 1;
            for (int k = 0; k < N; k++) all_done = all_done && done[k];
        end while (!all_done);
        c0.report();  c1.report();  c2.report();  c3.report();  c4.report();
        c5.report();  c6.report();  c7.report();  c8.report();  c9.report();
        c10.report(); c11.report(); c12.report(); c13.report(); c14.report();
        total = 0;
        configs = 0;
        short_any = 0;
        for (int k = 0; k < N; k++) begin
            if (sel[k]) configs++;
            total += cyc[k];
            short_any = short_any || short_cov[k];
        end
        if (configs == 0) begin
            $display("ICACHE BENCH: FAIL (+only selected no configuration)");
            $fatal(1, "the I-cache bench failed");
        end
        if ($test$plusargs("negative=")) begin
            if (!c3.injected)
                $display("ICACHE BENCH: FAIL (negative case %s: the fault found no cycle to be injected in configuration icache512-line16-ram)",
                         c3.negative);
            else
                $display("ICACHE BENCH: FAIL (negative case %s: the run ended and no assertion of the design stopped it)",
                         c3.negative);
            $fatal(1, "the I-cache bench failed");
        end
        if (!compare_on) begin
            $display("ICACHE BENCH: COMPARE OFF (%0d configurations, %0d cycles)", configs, total);
            $fatal(1, "the I-cache bench ran with +compare=0 or +compare=bounds: no verdict");
        end
        if (short_any && cover_on) begin
            $display("ICACHE BENCH: FAIL (coverage targets not met, see the configuration lines)");
            $fatal(1, "the I-cache bench failed");
        end
        $display("ICACHE BENCH: PASS (%0d configurations, %0d cycles, 0 mismatches)", configs, total);
        $finish;
    end
endmodule
