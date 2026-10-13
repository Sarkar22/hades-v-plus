// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// dcache.sv -- a direct-mapped, write-through data cache without write-allocate, as the RAM's
// port (slave 0) of the data-bus interconnect.
//
// Simulation only: rtl/mcu.sv instantiates it when the simulator is verilated with
// +define+HADES_DCACHE_BYTES (make DCACHE=<bytes>, which needs ICACHE=<bytes> as well, see make
// help). Synthesis reads rtl/*.sv, not this directory. docs/CACHES.md describes the design.
//
// Address split of a word address a (the bus adr: a byte address shifted right by 2), as in
// rtl/cache/icache.sv:
//   word in the line a[O-1:0], index (set) a[O+I-1:O], tag a[29:O+I]
// with O = log2(LINE_BYTES / 4), I = log2(BYTES / LINE_BYTES) and T = 30 - I - O tag bits.
// The tag array stores the full tag. present: the presented address's set is valid and holds
// its tag.
//
// The interconnect raises stb at this port only for addresses inside the RAM window; during an
// I/O access it sees cyc without stb, and then does nothing. The window is the RAM's (checked
// at time 0 by rtl/mcu.sv); a request outside it is impossible and stops the simulation.
//
// Loads (state LOOKUP, cyc && stb && !we), on the address presented in the cycle:
//   - if the line is present, ack in the same cycle with the word of the four data lanes, which
//     reach dat_miso without any logic; sel is ignored (the Memory stage selects the bytes);
//   - otherwise (a miss) no answer and no memory request in that cycle; at its end the set's
//     valid bit is cleared and the refill of the line starts.
// Refill (state REFILL): one Wishbone block of LINE_WORDS reads on the memory port, from word
// 0 of the line, cyc held through the block. Each answered beat is written into all four lanes;
// with the last one the tag is written, the line becomes valid and the state returns to LOOKUP.
// In REFILL nothing is acknowledged, whatever is presented. The first LOOKUP cycle after the
// last beat looks up the presented request again: the CPU still holds its load, so it hits.
// mem_cont tags beats 1 to LINE_WORDS - 1 as continuing the block.
// Stores (state LOOKUP, cyc && stb && we): presented on the memory port in the same cycle,
// unchanged (address, sel, data). The cycle in which the memory answers is the store-accept
// cycle (st_accept): the CPU gets ack, and if the line is present the lanes that sel selects
// take the store's bytes at the end of that cycle; other lanes, the tag and the valid bits do not
// change. A store to a line that is not present changes nothing here (no write-allocate). Every
// effect of a completed store depends on st_accept alone.
// The memory never answers err (the window is line-aligned and inside the RAM); an err stops the
// simulation, and so does a memory-side request that changes before its answer.
// Reset clears every valid bit and returns to LOOKUP with beat 0; a refill or a store in progress
// is dropped. The arrays keep their contents; in simulation they start with seeded random
// contents (tags of lines inside the window, random data), so that a line used without being
// valid gives wrong words.
// Events (ev_*): outputs only, 1 exactly in the cycles in which the event happens and 0 in
// cycles with rst = 1; nothing in this module reads them. rtl/mcu.sv names them cache_ev_d_*.
// ---------------------------------------------------------------------------------------------

module dcache #(
    parameter int unsigned BYTES        = 512,                        // a power of two, at least two lines
    parameter int unsigned LINE_BYTES   = 16,                         // 8, 16, 32 or 64
    parameter bit   [31:0] WINDOW_START = constants::MEMORY_START,    // word address, line-aligned
    parameter bit   [31:0] WINDOW_WORDS = constants::MEMORY_SIZE      // words, a multiple of a line
) (
    input  logic clk,
    input  logic rst,

    wishbone_interface.slave  cpu,              // the RAM's port of the data-bus interconnect
    wishbone_interface.master mem,              // refill reads and store writes, to the memory arbiter
    output logic              mem_cont,         // the refill beat continues the block (beat 1 and later)

    output logic              ev_lookup_hit,    // a load answered from the arrays (also at a second lookup)
    output logic              ev_load_miss,     // a load misses: a refill starts
    output logic              ev_beat,          // a refill beat answered
    output logic              ev_fill,          // the last beat answered: the line becomes valid
    output logic              ev_store_hit,     // a store accepted, its line present
    output logic              ev_store_miss,    // a store accepted, its line not present
    output logic              ev_store_wait,    // a cycle in which a store waits for its answer
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
    localparam logic [O-1:0] LAST_BEAT = O'(LINE_WORDS - 1);

    // --------------------------------------------------------------------------------------------
    // |                                          State                                           |
    // --------------------------------------------------------------------------------------------

    // The states, as named constants (sim/top.sv and the formal harness compare with them). The
    // register has room for two more states (2'd2 and 2'd3 are not used and not decoded).
    localparam logic [1:0] LOOKUP = 2'd0;
    localparam logic [1:0] REFILL = 2'd1;

    logic      [1:0] state;
    logic    [O-1:0] beat;          // the refill beat requested, 0 .. LINE_WORDS - 1
    logic   [29-O:0] refill_line;   // word address bits [29:O] of the line being refilled
    logic [SETS-1:0] valid;         // one flip-flop per line

    // --------------------------------------------------------------------------------------------
    // |                                     Lookup and arrays                                    |
    // --------------------------------------------------------------------------------------------

    logic                req;               // a request of the CPU (cyc && stb)
    logic                present;           // its line is valid with an equal tag (meaningful in LOOKUP)
    logic                load_hit, load_miss;
    logic                st_accept;         // the store is answered by the memory: it completes
    logic        [I-1:0] cpu_index;
    logic [TAG_BITS-1:0] cpu_tag;
    logic        [I-1:0] refill_index;
    logic [TAG_BITS-1:0] refill_tag;
    logic                last_beat_cycle;   // REFILL, requesting the last beat
    logic                beat_answered;     // REFILL, the requested beat is answered
    logic                fill;              // ... and it is the last one

    assign req          = cpu.cyc && cpu.stb;
    assign cpu_index    = cpu.adr[O+I-1:O];
    assign cpu_tag      = cpu.adr[29:TAG_LSB];
    assign refill_index = refill_line[I-1:0];
    assign refill_tag   = refill_line[29-O:TAG_LSB-O];

    assign last_beat_cycle = state == REFILL && beat == LAST_BEAT;
    assign beat_answered   = state == REFILL && mem.ack;
    assign fill            = beat_answered && beat == LAST_BEAT;

    // Tag array: port A reads the tag of the presented address, except while the last beat of a
    // refill is requested: then it addresses the refilled set, whose tag is written with the
    // last beat. No second port.
    logic [TAG_BITS-1:0] tag_a_rdata, tag_b_rdata;

    cache_ram #(
        .WIDTH(TAG_BITS),
        .DEPTH(SETS),
        .SNOOP_PORT(1'b0)
    ) tag_ram (
        .clk(clk),
        .a_adr(last_beat_cycle ? refill_index : cpu_index),
        .a_rdata(tag_a_rdata),
        .a_we(fill && !rst),
        .a_wdata(refill_tag),
        .b_adr('0),
        .b_rdata(tag_b_rdata)
    );

    assign present   = valid[cpu_index] && tag_a_rdata == cpu_tag;
    assign load_hit  = state == LOOKUP && req && !cpu.we && present;
    assign load_miss = state == LOOKUP && req && !cpu.we && !present;
    assign st_accept = state == LOOKUP && req && cpu.we && mem.ack;

    // Data array: four lanes of 8 bits, lane k holding bits 8k+7:8k of every word, each with its
    // own write enable. One address for the lookup and the refill: the presented address's word
    // in LOOKUP, the refill beat's word in REFILL. A refill beat writes all four lanes; a store
    // to a present line writes the lanes its sel selects, in its st_accept cycle.
    logic [3:0] lane_b_rdata;

    for (genvar k = 0; k < 4; k++) begin : lane
        logic [7:0] b_rdata;

        cache_ram #(
            .WIDTH(8),
            .DEPTH(SETS * LINE_WORDS),
            .SNOOP_PORT(1'b0)
        ) data_ram (
            .clk(clk),
            .a_adr(state == REFILL ? {refill_index, beat} : {cpu_index, cpu.adr[O-1:0]}),
            .a_rdata(cpu.dat_miso[8*k +: 8]),
            .a_we((beat_answered || (st_accept && present && cpu.sel[k])) && !rst),
            .a_wdata(state == REFILL ? mem.dat_miso[8*k +: 8] : cpu.dat_mosi[8*k +: 8]),
            .b_adr('0),
            .b_rdata(b_rdata)
        );

        assign lane_b_rdata[k] = ^b_rdata;
    end

    // --------------------------------------------------------------------------------------------
    // |                                         CPU port                                         |
    // --------------------------------------------------------------------------------------------

    assign cpu.ack = load_hit || st_accept;
    assign cpu.err = 1'b0;
    // cpu.dat_miso: the four lanes' read data (above)

    // --------------------------------------------------------------------------------------------
    // |                                       Memory port                                        |
    // --------------------------------------------------------------------------------------------

    // REFILL: the refill beat; LOOKUP: a store, unchanged, in the cycle it is presented; else idle
    logic store_req;
    assign store_req = state == LOOKUP && req && cpu.we;

    assign mem.cyc      = state == REFILL || store_req;
    assign mem.stb      = state == REFILL || store_req;
    assign mem.adr      = state == REFILL ? {2'b00, refill_line, beat} : store_req ? cpu.adr      : 32'h0;
    assign mem.we       = store_req;
    assign mem.sel      = state == REFILL ? 4'b1111                    : store_req ? cpu.sel      : 4'h0;
    assign mem.dat_mosi = store_req ? cpu.dat_mosi : 32'h0;
    assign mem_cont     = state == REFILL && beat != '0;

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
            if (load_miss) begin
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
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                          Events                                          |
    // --------------------------------------------------------------------------------------------

    assign ev_lookup_hit = !rst && cpu.ack && !cpu.we;
    assign ev_load_miss  = !rst && load_miss;
    assign ev_beat       = !rst && beat_answered;
    assign ev_fill       = !rst && fill;
    assign ev_store_hit  = !rst && st_accept && present;
    assign ev_store_miss = !rst && st_accept && !present;
    assign ev_store_wait = !rst && req && cpu.we && !cpu.ack;
    assign ev_refill     = !rst && state == REFILL;

    // The second ports of the arrays are not used; the memory port's err is read only by the
    // simulation checks
    logic unused;
    assign unused = ^{tag_b_rdata, lane_b_rdata, mem.err};

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
    // with a constant of its own, unequal to the I-cache's, so its sequence differs from the
    // memory's latencies and from the I-cache's contents.
    initial begin : parameters_and_initial_arrays
        int unsigned seed;
        bit   [31:0] z, rng, pick;
        longint      first_line, end_line, first, count, line;

        if (!(LINE_BYTES inside {8, 16, 32, 64}))
            $fatal(1, "dcache: LINE_BYTES = %0d: the line size must be 8, 16, 32 or 64 bytes", LINE_BYTES);
        if (BYTES == 0 || (BYTES & (BYTES - 1)) != 0 || longint'(BYTES) < 2 * longint'(LINE_BYTES))
            $fatal(1, "dcache: BYTES = %0d: the size must be a power of two of at least two lines (%0d bytes with LINE_BYTES = %0d)",
                   BYTES, 2 * LINE_BYTES, LINE_BYTES);
        if (T < 1)
            $fatal(1, "dcache: BYTES = %0d with LINE_BYTES = %0d leaves %0d tag bits: the tag, word address bits [29:%0d], must have at least 1 bit",
                   BYTES, LINE_BYTES, T, int'(I) + int'(O));
        if (WINDOW_START % LINE_WORDS != 0)
            $fatal(1, "dcache: WINDOW_START = 0x%08x: the window must start at a line boundary (a word address that is a multiple of %0d)",
                   WINDOW_START, LINE_WORDS);
        if (WINDOW_WORDS == 0 || WINDOW_WORDS % LINE_WORDS != 0)
            $fatal(1, "dcache: WINDOW_WORDS = 0x%08x: the window size must be above 0 and a multiple of %0d words (a whole number of lines)",
                   WINDOW_WORDS, LINE_WORDS);
        if (longint'(WINDOW_START) + longint'(WINDOW_WORDS) > 64'h4000_0000)
            $fatal(1, "dcache: WINDOW_START = 0x%08x, WINDOW_WORDS = 0x%08x: the window must end at or below word address 2**30",
                   WINDOW_START, WINDOW_WORDS);

        seed = DEFAULT_SEED;
        void'($value$plusargs("mem_seed=%d", seed));
        z = seed ^ 32'hD5CA_C3E1;
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
            lane[0].data_ram.mem[word] = rng[7:0];
            lane[1].data_ram.mem[word] = rng[15:8];
            lane[2].data_ram.mem[word] = rng[23:16];
            lane[3].data_ram.mem[word] = rng[31:24];
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                           Simulation: run-time checks of the ports                       |
    // --------------------------------------------------------------------------------------------

    // Sampled at the rising edge (the values at the end of the cycle), not in cycles with
    // rst = 1, and their history is cleared by a reset. The cycle is counted as sim/top.sv
    // counts it.
    localparam bit [31:0] WINDOW_END = WINDOW_START + WINDOW_WORDS;

    longint unsigned sim_cycle;

    // The memory-side request that was not answered, which must be presented again unchanged
    logic        m_held;
    logic [31:0] m_held_adr, m_held_dat;
    logic  [3:0] m_held_sel;
    logic        m_held_we;

    always @(posedge clk) begin
        sim_cycle <= sim_cycle + 1;
        if (rst) begin
            m_held <= 1'b0;
        end
        else begin
            if (cpu.ack && cpu.err)
                $fatal(1, "dcache: ack and err together on the CPU port at cycle %0d, address 0x%08x",
                       sim_cycle, cpu.adr << 2);
            if ((cpu.ack || cpu.err) && !req)
                $fatal(1, "dcache: an answer without cyc && stb on the CPU port at cycle %0d (ack=%0d err=%0d), address 0x%08x",
                       sim_cycle, cpu.ack, cpu.err, cpu.adr << 2);
            if (cpu.err)
                $fatal(1, "dcache: err on the CPU port at cycle %0d, address 0x%08x (the D-cache never answers err)",
                       sim_cycle, cpu.adr << 2);
            if (cpu.ack && state == REFILL)
                $fatal(1, "dcache: an answer in REFILL at cycle %0d, address 0x%08x (nothing is answered during a refill)",
                       sim_cycle, cpu.adr << 2);
            if (req && !(cpu.adr >= WINDOW_START && cpu.adr < WINDOW_END))
                $fatal(1, "dcache: a request for address 0x%08x outside the window 0x%08x-0x%08x at cycle %0d (the interconnect raises stb at slave 0 only inside the RAM window)",
                       cpu.adr << 2, WINDOW_START << 2, (WINDOW_END << 2) - 1, sim_cycle);
            if (mem.ack && mem.err)
                $fatal(1, "dcache: ack and err together on the memory port at cycle %0d, address 0x%08x",
                       sim_cycle, mem.adr << 2);
            if (mem.err && mem.we)
                $fatal(1, "dcache: the memory answered err to the store of address 0x%08x at cycle %0d (the D-cache reads and writes inside the RAM window only)",
                       mem.adr << 2, sim_cycle);
            if (mem.err && !mem.we)
                $fatal(1, "dcache: the memory answered err to the refill of address 0x%08x at cycle %0d (the D-cache reads and writes inside the RAM window only)",
                       mem.adr << 2, sim_cycle);
            if (m_held && !(mem.cyc && mem.stb && mem.adr == m_held_adr && mem.sel == m_held_sel &&
                            mem.we == m_held_we && (!m_held_we || mem.dat_mosi == m_held_dat)))
                $fatal(1, "dcache: the memory-side request (address 0x%08x sel=%04b we=%0d data 0x%08x) changed before its answer, at cycle %0d",
                       m_held_adr << 2, m_held_sel, m_held_we, m_held_dat, sim_cycle);

            m_held     <= mem.cyc && mem.stb && !mem.ack && !mem.err;
            m_held_adr <= mem.adr;
            m_held_sel <= mem.sel;
            m_held_we  <= mem.we;
            m_held_dat <= mem.dat_mosi;
        end
    end
`endif

endmodule
