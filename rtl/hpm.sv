// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// hpm.sv -- the counter unit of the hardware performance counters, instantiated in Writeback.
//
// Holds mhpmcounter3 .. mhpmcounter(2+N) (W bits each, read in two 32-bit halves),
// their selectors mhpmevent3 .. mhpmevent(2+N) and mcountinhibit (0x320); N =
// hpm_pkg::COUNTERS, W = hpm_pkg::WIDTH (defines/hpm.sv). mcycle, minstret and the
// branch predictor's counters 10-13 stay in Writeback; this unit gives them
// their inhibit bits.
//
// Counting classes. Every event reaches its counter at a fixed delay after its
// condition, so that events fall in program order relative to counter writes:
//   class A   ev_a: counted at the end of this cycle (the instruction in
//             Writeback, like minstret)
//   class B1  late.b1, late.ext, late.comb: computed by hpm_events from its
//             registered inputs, so already one cycle late; counted as they
//             arrive
//   class B2  trap_raw (Writeback's trap decision of this cycle) goes through
//             two registers here; late.b2 (one cycle late already) through one
//
// CSR access (the instruction in Writeback):
//   read   rdata is the addressed register's current value, 0 for any address
//          the unit does not implement (Writeback's default read arm)
//   write  csr_we is Writeback's write test (a retiring CSRRW or CSRRWI, or a
//          retiring CSRRS, CSRRC, CSRRSI or CSRRCI with a non-zero rs1 field) for
//          the address csr_addr; csr_wdata the value written. A counter first
//          takes its own increment of this cycle (with the carry into the high
//          half), then the written half takes the written value; the other half
//          keeps the incremented value. A selector keeps a written value only if
//          it is a code this build has, else it takes 0. mcountinhibit keeps only
//          its implemented bits. The inhibit bits used for counting in a cycle are
//          those before that cycle's write.
//
// Reset: counters, inhibit and delay registers 0; selectors 0, or their preset
// in a simulator built with HADES_HPM_PRESET.
// ---------------------------------------------------------------------------------------------

module hpm #(
    parameter int N = hpm_pkg::COUNTERS,  // programmable counters 3 .. 2+N, 0 to 7
    parameter int W = hpm_pkg::WIDTH      // their width, 32 to 64
) (
    input  logic        clk,
    input  logic        rst,

    // Events
    input  logic [20:1]  ev_a,       // class A, codes 1-20, of this cycle
    input  logic [26:21] trap_raw,   // trap events, codes 21-26, of this cycle (class B2)
    input  hpm_pkg::late_t   late,       // from hpm_events, one cycle late
    input  logic [31:0]  hpm_ext_present, // 1 for every memory-system bit the configuration drives

    // CSR access by the instruction in Writeback
    input  logic [11:0]  csr_addr,
    input  logic         csr_we,
    input  logic [31:0]  csr_wdata,
    output logic [31:0]  rdata,

    // Inhibit bits of the counters that live in Writeback
    output logic         inh_cy,     // mcycle
    output logic         inh_ir,     // minstret
    output logic [3:0]   inh_bp      // mhpmcounter10-13
);

    localparam int FIRST = 3;           // the first programmable counter
    localparam int LAST  = 2 + N;       // the last one (2 when N = 0: none)
    // The bits of mcountinhibit that can be written: CY, IR, the counters 3 .. 2+N and the predictor's
    // counters 10-13 (hpm_pkg::INHIBIT_MASK for this build's N; 0x0000_3FFD with N = 7)
    localparam bit [31:0] IMPL_MASK = 32'h0000_3C05 | (((32'd1 << N) - 32'd1) << 3);

    // =========================================================================
    // Registers
    // =========================================================================
    logic [W-1:0] cnt     [FIRST:9];    // mhpmcounter3-9 (only 3 .. LAST exist)
    logic [7:0]   sel     [FIRST:9];    // mhpmevent3-9[7:0]
    logic [31:0]  inhibit;              // mcountinhibit
    logic [26:21] trap_s1;              // trap events, first delay stage
    logic [26:21] trap_s2;              // trap events, second delay stage
    logic [46:32] pipe_s2;              // pipeline B2 events, second delay stage

    logic [63:0]  cnt_64   [FIRST:9];   // cnt, zero-extended
    logic [63:0]  cnt_next [FIRST:9];   // cnt's next value (below)

    assign inh_cy = inhibit[0];
    assign inh_ir = inhibit[2];
    assign inh_bp = inhibit[13:10];

    // =========================================================================
    // The events, indexed by code, as they reach the counters in this cycle
    // =========================================================================
    logic [255:0] ev;

    always_comb begin
        ev            = '0;
        ev[20:1]      = ev_a;
        ev[26:21]     = trap_s2;
        ev[46:32]     = pipe_s2;
        ev[49:47]     = late.b1;
        ev[159:128]   = late.ext & hpm_ext_present;
        ev[161:160]   = late.comb;
    end

    // =========================================================================
    // CSR address decode
    // =========================================================================
    // idx is the counter number the address names (3-9 for is_evt, is_lo and
    // is_hi; 11-13 for is_fixed); a counter above 2 + N reads 0.
    logic       is_inh, is_evt, is_lo, is_hi, is_fixed;
    logic [3:0] idx;

    always_comb begin
        is_inh   = csr_addr == hpm_pkg::MCOUNTINHIBIT;
        is_evt   = csr_addr >= 12'h323 && csr_addr <= 12'h329;
        is_lo    = csr_addr >= 12'hB03 && csr_addr <= 12'hB09;
        is_hi    = csr_addr >= 12'hB83 && csr_addr <= 12'hB89;
        is_fixed = csr_addr >= 12'h32B && csr_addr <= 12'h32D;  // mhpmevent11-13
        idx      = csr_addr[3:0];        // 3-9 in all three ranges, 0xB-0xD for is_fixed
    end

    // =========================================================================
    // Read
    // =========================================================================
    always_comb begin
        rdata = 32'b0;
        if (is_inh) begin
            rdata = inhibit;
        end else if (is_fixed) begin
            // mhpmevent11-13: the events of the predictor's counters 11-13,
            // BP_NT, BP_TN and BP_TT (read-only; mhpmevent10 is the predictor's
            // mode register, read in Writeback)
            rdata = {24'b0, hpm_pkg::EV_BP_NN + 8'(idx - 4'd10)};
        end else if ((is_evt || is_lo || is_hi) && 32'(idx) <= LAST) begin
            for (int n = FIRST; n <= 9; n++) begin
                if (n <= LAST && 4'(n) == idx) begin
                    if (is_evt)
                        rdata = {24'b0, sel[n]};
                    else if (is_lo)
                        rdata = cnt_64[n][31:0];
                    else
                        rdata = cnt_64[n][63:32];   // bits above W read 0
                end
            end
        end
    end

    // =========================================================================
    // Next values
    // =========================================================================
    // cnt_64: the counters zero-extended to 64 bits (bits above W are 0).
    // cnt_next: increment first (W bits, wrapping), then the written half.
    // (two blocks: the read path must not depend on the write data)
    always_comb begin
        for (int n = FIRST; n <= 9; n++)
            cnt_64[n] = 64'(cnt[n]);
    end

    always_comb begin
        for (int n = FIRST; n <= 9; n++) begin
            cnt_next[n] = cnt_64[n] + 64'(ev[sel[n]] && !inhibit[n]);
            if (csr_we && is_lo && idx == 4'(n))
                cnt_next[n][31:0] = csr_wdata;
            else if (csr_we && is_hi && idx == 4'(n) && W > 32)
                cnt_next[n][63:32] = csr_wdata;
        end
    end

    // =========================================================================
    // Update
    // =========================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            inhibit <= 32'b0;
            trap_s1 <= '0;
            trap_s2 <= '0;
            pipe_s2 <= '0;
            for (int n = FIRST; n <= 9; n++) begin
                cnt[n] <= '0;
                sel[n] <= (n <= LAST) ? hpm_pkg::PRESET_CODES[n - FIRST] : 8'd0;
            end
        end else begin
            trap_s1 <= trap_raw;
            trap_s2 <= trap_s1;
            pipe_s2 <= late.b2;

            if (csr_we && is_inh)
                inhibit <= csr_wdata & IMPL_MASK;

            for (int n = FIRST; n <= 9; n++) begin
                if (n <= LAST) begin
                    cnt[n] <= cnt_next[n][W-1:0];
                    if (csr_we && is_evt && idx == 4'(n))
                        sel[n] <= hpm_pkg::legal(csr_wdata, hpm_ext_present) ? csr_wdata[7:0] : 8'd0;
                end else begin
                    // counters above 2 + N do not exist: read-only 0
                    cnt[n] <= '0;
                    sel[n] <= 8'd0;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // Checks of the parameters at time 0, and of the preset against this build's
    // codes (its present mask) at the first clock edge.
    initial begin
        if (N < 0 || N > 7)
            $fatal(1, "hpm: HADES_HPM_COUNTERS=%0d: give 0 to 7 programmable counters", N);
        if (W < 32 || W > 64)
            $fatal(1, "hpm: HADES_HPM_WIDTH=%0d: give a counter width of 32 to 64 bits", W);
        if (hpm_pkg::PRESET < hpm_pkg::NO_PRESET || hpm_pkg::PRESET > hpm_pkg::I)
            $fatal(1, "hpm: HADES_HPM_PRESET: give one of the letters A to I");
        if (hpm_pkg::PRESET != hpm_pkg::NO_PRESET) begin
            @(posedge clk);
            for (int n = FIRST; n <= LAST; n++) begin
                if (!hpm_pkg::legal(32'(hpm_pkg::PRESET_CODES[n - FIRST]), hpm_ext_present))
                    $fatal(1, "hpm: the preset's code %0d for mhpmevent%0d is not in this build (the memory-system codes need an I-cache build)",
                           hpm_pkg::PRESET_CODES[n - FIRST], n);
            end
        end
    end
`endif

endmodule
