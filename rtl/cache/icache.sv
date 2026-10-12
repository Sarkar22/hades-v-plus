// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// icache.sv -- a direct-mapped instruction cache between the CPU's fetch bus and the memory.
//
// Simulation only: rtl/mcu.sv instantiates it when the simulator is verilated with
// +define+HADES_ICACHE_BYTES (make ICACHE=<bytes>, see make help). Synthesis reads rtl/*.sv,
// not this directory. docs/CACHES.md describes the design and how it is checked.
//
// Address split of a word address a (the bus adr: a byte address shifted right by 2):
//   word in the line a[O-1:0], index (set) a[O+I-1:O], tag a[29:O+I]
// with O = log2(LINE_BYTES / 4), I = log2(BYTES / LINE_BYTES) and T = 30 - I - O tag bits.
// The tag array stores the full tag; a hit also requires a[31:30] == 0, so the whole word
// address is compared.
//
// Lookup (state LOOKUP), on the address presented in the cycle, never on a latched one:
//   - a fetch (cyc && stb) whose line is valid with an equal tag is answered (ack) in the
//     same cycle with the data array's word, which reaches dat_miso without any logic;
//   - a fetch outside the cacheable window [WINDOW_START, WINDOW_START + WINDOW_WORDS) is
//     answered with err, in every state; it never gets ack and never starts a refill;
//   - any other fetch inside the window misses: no answer, and at the end of the cycle its
//     line's valid bit is cleared and the refill of its line starts.
//   A cycle without cyc && stb is not looked up and changes nothing.
// Refill (state REFILL): one Wishbone block of LINE_WORDS reads on the memory port, from word
// 0 of the line, cyc held from the first refill cycle through the cycle of the last beat. Each
// answered beat is written into the data array; with the last one the tag is written, the line
// becomes valid and the state returns to LOOKUP. In REFILL nothing is acknowledged (no hit
// under a miss), whatever the CPU presents, and address changes of the CPU do not affect the
// refill. The first LOOKUP cycle after the last beat looks up whatever address is presented
// then. mem_cont tags beats 1 to LINE_WORDS - 1 as continuing the block (sim/slow_memory.sv
// gives only those a burst latency). An err from the memory to a refill is impossible (the
// window is line-aligned and inside the RAM) and stops the simulation.
// Snooping: at the end of a cycle in which a store is acknowledged at the RAM's port of the
// data-bus interconnect (snoop_store, snoop_adr), the line holding the store's address is
// invalidated if it is valid with an equal tag, whatever bytes the store writes. Every store
// to the RAM passes that port, so a valid line never differs from the RAM; FENCE.I stays the
// pipeline flush it is without a cache.
// Reset clears every valid bit and returns to LOOKUP with beat 0; a refill in progress is
// dropped. The arrays keep their contents; in simulation they start with seeded random
// contents (tags of lines inside the window, random data), so that a line used without being
// valid gives wrong words.
// Events (ev_*): outputs only, 1 exactly in the cycles in which the event happens and 0 in
// cycles with rst = 1; nothing in this module reads them. rtl/mcu.sv names them cache_ev_*.
// ---------------------------------------------------------------------------------------------

module icache #(
    parameter int unsigned BYTES        = 512,                        // a power of two, at least two lines
    parameter int unsigned LINE_BYTES   = 16,                         // 8, 16, 32 or 64
    parameter bit   [31:0] WINDOW_START = constants::MEMORY_START,    // word address, line-aligned
    parameter bit   [31:0] WINDOW_WORDS = constants::MEMORY_SIZE      // words, a multiple of a line
) (
    input  logic clk,
    input  logic rst,

    wishbone_interface.slave  cpu,              // the CPU's fetch bus
    wishbone_interface.master mem,              // the refill port, to the memory arbiter
    output logic              mem_cont,         // the refill beat continues the block (beat 1 and later)

    input  logic              snoop_store,      // a store is acknowledged at the RAM's interconnect port
    input  logic       [31:0] snoop_adr,        // ... its word address

    output logic              ev_hit,           // a fetch acknowledged from the arrays
    output logic              ev_miss,          // a fetch inside the window misses: a refill starts
    output logic              ev_beat,          // a refill beat answered
    output logic              ev_fill,          // the last beat answered: the line becomes valid
    output logic              ev_abandoned,     // ... and the CPU presents no address of that line
    output logic              ev_snoop_inval,   // a store invalidates a valid line
    output logic              ev_refill         // a cycle of a refill, waiting for the port or granted
);
    // --------------------------------------------------------------------------------------------
    // |                                      Configuration                                       |
    // --------------------------------------------------------------------------------------------

    // Derived values. The guards keep the module elaborating for illegal parameters, so that
    // the checks at the end of the file can name them; they do not change legal ones.
    localparam int unsigned LINE_WORDS = (LINE_BYTES >= 8) ? LINE_BYTES / 4 : 2;
    localparam int unsigned O          = $clog2(LINE_WORDS);                  // word bits
    localparam int unsigned SETS       = (LINE_BYTES >= 8 && BYTES >= 2 * LINE_BYTES) ?
                                         BYTES / LINE_BYTES : 2;
    localparam int unsigned I          = $clog2(SETS);                        // index bits
    localparam int          T          = 30 - int'(I) - int'(O);              // tag bits
    localparam int unsigned TAG_BITS   = (T >= 1) ? T : 1;
    localparam int unsigned TAG_LSB    = 30 - TAG_BITS;                       // O + I
    localparam bit   [31:0] WINDOW_END = WINDOW_START + WINDOW_WORDS;
    localparam logic [O-1:0] LAST_BEAT = O'(LINE_WORDS - 1);

    // --------------------------------------------------------------------------------------------
    // |                                          State                                           |
    // --------------------------------------------------------------------------------------------

    // The two states, as named constants (sim/top.sv and the formal harness compare with them)
    localparam logic LOOKUP = 1'b0;
    localparam logic REFILL = 1'b1;

    logic            state;
    logic    [O-1:0] beat;          // the refill beat requested, 0 .. LINE_WORDS - 1
    logic   [29-O:0] refill_line;   // word address bits [29:O] of the line being refilled
    logic [SETS-1:0] valid;         // one flip-flop per line

    // --------------------------------------------------------------------------------------------
    // |                                     Lookup and arrays                                    |
    // --------------------------------------------------------------------------------------------

    logic                req, inwin, hit, miss;
    logic        [I-1:0] cpu_index;
    logic [TAG_BITS-1:0] cpu_tag;
    logic        [I-1:0] refill_index;
    logic [TAG_BITS-1:0] refill_tag;
    logic                last_beat_cycle;   // REFILL, requesting the last beat
    logic                beat_answered;     // REFILL, the requested beat is answered
    logic                fill;              // ... and it is the last one

    assign req          = cpu.cyc && cpu.stb;
    assign inwin        = cpu.adr >= WINDOW_START && cpu.adr < WINDOW_END;
    assign cpu_index    = cpu.adr[O+I-1:O];
    assign cpu_tag      = cpu.adr[29:TAG_LSB];
    assign refill_index = refill_line[I-1:0];
    assign refill_tag   = refill_line[29-O:TAG_LSB-O];

    assign last_beat_cycle = state == REFILL && beat == LAST_BEAT;
    assign beat_answered   = state == REFILL && mem.ack;
    assign fill            = beat_answered && beat == LAST_BEAT;

    // Tag array: port A reads the tag of the presented address, except while the last beat of a
    // refill is requested: then it addresses the refilled set, whose tag is written with the
    // last beat. Port B reads the tag of the snooped store's set.
    logic [TAG_BITS-1:0] tag_a_rdata, tag_b_rdata;

    cache_ram #(
        .WIDTH(TAG_BITS),
        .DEPTH(SETS),
        .SNOOP_PORT(1'b1)
    ) tag_ram (
        .clk(clk),
        .a_adr(last_beat_cycle ? refill_index : cpu_index),
        .a_rdata(tag_a_rdata),
        .a_we(fill && !rst),
        .a_wdata(refill_tag),
        .b_adr(snoop_adr[O+I-1:O]),
        .b_rdata(tag_b_rdata)
    );

    // Data array: the presented address's word in LOOKUP, the refill beat's word in REFILL
    // (one address for the lookup and the refill); its read data is the fetch answer's data.
    logic [31:0] data_b_rdata;

    cache_ram #(
        .WIDTH(32),
        .DEPTH(SETS * LINE_WORDS),
        .SNOOP_PORT(1'b0)
    ) data_ram (
        .clk(clk),
        .a_adr(state == REFILL ? {refill_index, beat} : cpu.adr[O+I-1:0]),
        .a_rdata(cpu.dat_miso),
        .a_we(beat_answered && !rst),
        .a_wdata(mem.dat_miso),
        .b_adr('0),
        .b_rdata(data_b_rdata)
    );

    // A hit of the presented address (used in LOOKUP only; while the last beat of a refill is
    // requested the tag port addresses the refilled set instead)
    assign hit  = req && valid[cpu_index] && tag_a_rdata == cpu_tag && cpu.adr[31:30] == 2'b00;
    assign miss = state == LOOKUP && req && inwin && !hit;

    // --------------------------------------------------------------------------------------------
    // |                                         CPU port                                         |
    // --------------------------------------------------------------------------------------------

    assign cpu.ack = state == LOOKUP && hit;
    assign cpu.err = req && !inwin;
    // cpu.dat_miso: the data array's read data (above)

    // --------------------------------------------------------------------------------------------
    // |                                        Refill port                                       |
    // --------------------------------------------------------------------------------------------

    assign mem.cyc      = state == REFILL;
    assign mem.stb      = state == REFILL;
    assign mem.adr      = {2'b00, refill_line, beat};
    assign mem.we       = 1'b0;
    assign mem.sel      = 4'b1111;
    assign mem.dat_mosi = 32'h0;
    assign mem_cont     = state == REFILL && beat != '0;

    // --------------------------------------------------------------------------------------------
    // |                                          Snoop                                           |
    // --------------------------------------------------------------------------------------------

    logic         [I-1:0] snoop_index;
    logic                 snoop_inval;

    assign snoop_index = snoop_adr[O+I-1:O];
    assign snoop_inval = snoop_store && valid[snoop_index] && tag_b_rdata == snoop_adr[29:TAG_LSB];

    // --------------------------------------------------------------------------------------------
    // |                                     State transitions                                    |
    // --------------------------------------------------------------------------------------------

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= LOOKUP;
            beat  <= '0;
            valid <= '0;
        end
        else begin
            if (miss) begin
                valid[cpu_index] <= 1'b0;
                refill_line      <= cpu.adr[29:O];
                beat             <= '0;
                state            <= REFILL;
            end
            if (beat_answered) begin
                if (beat == LAST_BEAT) begin
                    valid[refill_index] <= 1'b1;
                    beat                <= '0;
                    state               <= LOOKUP;
                end
                else begin
                    beat <= beat + 1'b1;
                end
            end
            if (snoop_inval)
                valid[snoop_index] <= 1'b0;
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                          Events                                          |
    // --------------------------------------------------------------------------------------------

    assign ev_hit         = !rst && cpu.ack;
    assign ev_miss        = !rst && miss;
    assign ev_beat        = !rst && beat_answered;
    assign ev_fill        = !rst && fill;
    assign ev_abandoned   = !rst && fill && !(req && inwin && cpu.adr[29:O] == refill_line);
    assign ev_snoop_inval = !rst && snoop_inval;
    assign ev_refill      = !rst && state == REFILL;

    // The read-only port of the data array is not used; nor are the bits of the snooped
    // address outside the index and the tag, or the fetch port's write data
    logic unused;
    assign unused = ^{data_b_rdata, snoop_adr[31:30], snoop_adr[O-1:0], cpu.dat_mosi};

`ifndef SYNTHESIS
    // --------------------------------------------------------------------------------------------
    // |                         Simulation: parameter checks, initial arrays                     |
    // --------------------------------------------------------------------------------------------

`ifdef HADES_MEM_SEED
    localparam int unsigned DEFAULT_SEED = `HADES_MEM_SEED;
`else
    localparam int unsigned DEFAULT_SEED = 1;
`endif

    function automatic bit [31:0] next_random(bit [31:0] x);   // xorshift32
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        return x;
    endfunction

    // At time 0, before the first clock edge: the parameter checks (an elaboration-time $fatal
    // would only be a warning in builds with -Wno-fatal, which go on), then the arrays' initial
    // contents. Each set gets the tag of a line of the window that maps to it, chosen at random
    // (a random tag if no line of the window maps to it), each data word a random value. The
    // generator is seeded with +mem_seed (default HADES_MEM_SEED, as sim/slow_memory.sv) mixed
    // with a constant of its own, so its sequence differs from the memory's latencies.
    initial begin : parameters_and_initial_arrays
        int unsigned seed;
        bit   [31:0] z, rng, pick;
        longint      first_line, end_line, first, count, line;

        if (!(LINE_BYTES inside {8, 16, 32, 64}))
            $fatal(1, "icache: LINE_BYTES = %0d: the line size must be 8, 16, 32 or 64 bytes", LINE_BYTES);
        if (BYTES == 0 || (BYTES & (BYTES - 1)) != 0 || longint'(BYTES) < 2 * longint'(LINE_BYTES))
            $fatal(1, "icache: BYTES = %0d: the size must be a power of two of at least two lines (%0d bytes with LINE_BYTES = %0d)",
                   BYTES, 2 * LINE_BYTES, LINE_BYTES);
        if (T < 1)
            $fatal(1, "icache: BYTES = %0d with LINE_BYTES = %0d leaves %0d tag bits: the tag, word address bits [29:%0d], must have at least 1 bit",
                   BYTES, LINE_BYTES, T, int'(I) + int'(O));
        if (WINDOW_START % LINE_WORDS != 0)
            $fatal(1, "icache: WINDOW_START = 0x%08x: the window must start at a line boundary (a word address that is a multiple of %0d)",
                   WINDOW_START, LINE_WORDS);
        if (WINDOW_WORDS == 0 || WINDOW_WORDS % LINE_WORDS != 0)
            $fatal(1, "icache: WINDOW_WORDS = 0x%08x: the window size must be above 0 and a multiple of %0d words (a whole number of lines)",
                   WINDOW_WORDS, LINE_WORDS);
        if (longint'(WINDOW_START) + longint'(WINDOW_WORDS) > 64'h4000_0000)
            $fatal(1, "icache: WINDOW_START = 0x%08x, WINDOW_WORDS = 0x%08x: the window must end at or below word address 2**30",
                   WINDOW_START, WINDOW_WORDS);

        seed = DEFAULT_SEED;
        void'($value$plusargs("mem_seed=%d", seed));
        z = seed ^ 32'h1CAC_4E5D;
        z = (z ^ (z >> 16)) * 32'h7FEB_352D;
        z = (z ^ (z >> 15)) * 32'h846C_A68B;
        z = z ^ (z >> 16);
        rng = (z == 0) ? 32'h1 : z;

        first_line = longint'(WINDOW_START) >> O;                        // the window's lines
        end_line   = (longint'(WINDOW_START) + longint'(WINDOW_WORDS)) >> O;
        for (int unsigned set = 0; set < SETS; set++) begin
            first = first_line + ((longint'(set) - first_line % longint'(SETS) + longint'(SETS)) % longint'(SETS));
            count = (first < end_line) ? (end_line - 1 - first) / longint'(SETS) + 1 : 0;
            rng   = next_random(rng);
            if (count > 0) begin
                pick = rng % 32'(count);
                line = first + longint'(pick) * longint'(SETS);
                tag_ram.mem[set] = TAG_BITS'(line >> I);
            end
            else begin
                tag_ram.mem[set] = TAG_BITS'(rng);
            end
        end
        for (int unsigned word = 0; word < SETS * LINE_WORDS; word++) begin
            rng = next_random(rng);
            data_ram.mem[word] = rng;
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                           Simulation: run-time checks of the ports                       |
    // --------------------------------------------------------------------------------------------

    // Sampled at the rising edge (the values at the end of the cycle), not in cycles with
    // rst = 1. The cycle is counted as sim/top.sv counts it.
    longint unsigned sim_cycle;

    always @(posedge clk) begin
        sim_cycle <= sim_cycle + 1;
        if (!rst) begin
            if (req && (cpu.we || cpu.sel != 4'b1111))
                $fatal(1, "icache: the fetch port presents we=%0d sel=%04b at cycle %0d, address 0x%08x (a fetch reads a whole word)",
                       cpu.we, cpu.sel, sim_cycle, cpu.adr << 2);
            if (cpu.ack && cpu.err)
                $fatal(1, "icache: ack and err together on the fetch port at cycle %0d, address 0x%08x",
                       sim_cycle, cpu.adr << 2);
            if ((cpu.ack || cpu.err) && !req)
                $fatal(1, "icache: an answer without cyc && stb on the fetch port at cycle %0d (ack=%0d err=%0d), address 0x%08x",
                       sim_cycle, cpu.ack, cpu.err, cpu.adr << 2);
            if (mem.ack && mem.err)
                $fatal(1, "icache: ack and err together on the refill port at cycle %0d, address 0x%08x",
                       sim_cycle, mem.adr << 2);
            if (mem.err)
                $fatal(1, "icache: the memory answered err to the refill of address 0x%08x at cycle %0d (a refill reads inside the RAM window only)",
                       mem.adr << 2, sim_cycle);
        end
    end
`endif

endmodule
