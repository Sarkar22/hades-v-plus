// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// test_hpm.sv -- unit bench of the performance-counter unit (rtl/hpm.sv), compared in every cycle
// with a reference model of the counter unit that lives in this file.
//
// The device under test is one `hpm` module, driven as Writeback drives it: an event vector, the
// CSR address, the write strobe and the write value, the reset, and the constant mask of the
// memory-system events that a configuration has. The reference model (class HpmRef below) was
// written from the documented behaviour of the counters (docs/EXTENSIONS.md) alone (the CSR rules, the three counting classes and
// their delays, the event-code table, the half-write rule), without reading the unit's code. It
// gets the same inputs as the unit and keeps its state in plain variables, one procedural step
// per clock edge.
//
// What the model says (the unit's input side; "cycle t" is a cycle whose inputs are as stated):
//   - Class A (codes 1-20) and class B1 (47-49, 128-161): an event that is 1 in cycle t is
//     counted at the edge that ends cycle t, so a read in cycle t + 1 sees it.
//   - Class B2, pipeline events (32-46): counted at the end of cycle t + 1 (one register inside
//     the unit; the unit's input is already one cycle late). Trap events (21-26): counted at the
//     end of cycle t + 2 (two registers). The selector acts on the delayed event, so an event that
//     is in a delay register when a selector changes is counted under the new selector.
//   - Counter n (3 .. 2 + N): step = event(selector) and not inhibit bit n; the counter takes the
//     step (modulo 2^W, with the carry across the two 32-bit halves), then a write replaces the
//     half it names and the other half keeps the stepped value (the half-write rule).
//   - Selectors (0x323 ..): WARL. A written value is kept if bits 31:8 are 0 and the code is one
//     this build has (1-26 and 32-49 always; 128 + k if bit k of the present mask is 1; 160 if
//     bit 0; 161 if bit 1), else the selector becomes 0. mcountinhibit (0x320) is WARL to the
//     implemented bits (CY, IR, 3 .. 2 + N, 10-13); TM is read-only 0.
//   - Reads (combinational on the address): 0x320 the inhibit register; 0x323 .. the selectors;
//     0x32B, 0x32C, 0x32D the constants 18, 19, 20; 0xB03 .. the low halves; 0xB83 .. the high
//     halves (bits W-1:32, zero-extended); every other address 0. Counters above 2 + N read 0 and
//     ignore writes.
//   - Reset (synchronous, held for at least one edge): counters, selectors, inhibit and the delay
//     registers are 0.
//
// Before the unit is compared, the bench checks its own model with hand-computed cases (module
// test_hpm, task model_self_test): the numbers there were worked out on paper from the rules above,
// not produced by the model. A failing self-test stops the run at time 0.
//
// Compared every cycle after the first reset edge (cycles in which rst = 1 apart, because a unit
// may reset asynchronously): the read value of the address that cycle presents, and the three
// inhibit outputs (inh_cy, inh_ir, inh_bp). The registers themselves (counters, selectors,
// inhibit) are not ports of the unit: the stimulus therefore reads the state back in a way that
// makes every counter, selector and the inhibit register visible, as follows. Every write is
// followed by reads of what it changed; one "focus" counter is read in many cycles; each phase
// ends with a read of every address that holds state or a constant; and the directed sequences
// read after every step. If the unit's counter array, selector array and inhibit register have
// the names cnt, sel and inhibit (rtl/hpm.sv), that compare of all of them in every cycle is on; the macros
// HPM_PROBE_* below name them, and `+define+HPM_NOPROBE` turns it off.
//
// Stimulus, from a seeded generator: random CSR reads and writes at every address in 0x300-0x33F,
// 0xB00-0xB1F and 0xB80-0xB9F and, rarely, anywhere in the 12-bit space; random event vectors
// (several densities, bursts, garbage on bits that no selector can pick), with the selected
// events made frequent; random inhibit and selector values (legal, illegal, 256, 0xFFFF_FFFF);
// random resets; and, in each phase, a constant present mask. Directed sequences at the start of
// every phase: every code 0-255 and the values 256, 0x1FF, 0xFFFF_FFFF, 0x8000_0080 into every
// selector, every single inhibit bit, a read (even phases) or a write and a read (odd phases) of
// every one of the 4096 CSR addresses, and for every counter and for one code of each counting
// class the carry, the wrap from 2^W - 1, a write in the same cycle as an event, a high write
// that loses the carry, the mask of the high half, the inhibit, and single-cycle event pulses
// around a selector write. The bench counts every case it is meant to reach (coverage lines) and
// fails if a case was not reached.
//
// Configurations (N counters, W bits): N in {0, 1, 7} x W in {32, 48, 64}, and (7, 33), (3, 40),
// (2, 63). Each configuration runs eight phases; the phases use the present masks 0, the mask of
// the I-cache build (bits 0-11), and two random masks within bits 0-11. With +maskhi=1 the random
// masks are 32 bits wide, which also makes codes 140-159 legal: the unit's rule (a code is kept when its bit
// of the present mask is set) says so, but those codes are reserved, so this is off by default.
//
// The end of the run prints the self-test line, one line per configuration and one of:
//     HPM BENCH: PASS (<configurations>, <cycles>, 0 mismatches)        exit status 0
//     HPM BENCH: FAIL (<reason>)                                        exit status 1
//
// Run-time options:
//   +seed=<n>       seed of the stimulus (default 1)
//   +cycles=<n>     random cycles per phase (default 20000; the directed sequences come on top)
//   +maskhi=1       random present masks use all 32 bits (default: bits 0-11 only)
//   +rstev=1        drive random events also in cycles with rst = 1 (default: 0 in those cycles,
//                   as the unit's contract promises)
//   +cover=0        print the coverage counts without judging them (for short runs)
//   +only=<k>       run only configuration number k (0-11)
//
// Build (the generic bench rule of the Makefile does it; the unit is found in rtl/):
//     make test/sv/test_hpm [SIM_ARGS='+seed=2 +cycles=50000']
// ---------------------------------------------------------------------------------------------

package hpm_bench_pkg;

    // How an event of a code reaches the unit.
    localparam int CL_NONE = 0;   // not an event code
    localparam int CL_A    = 1;   // class A: counted at the end of the cycle it is 1
    localparam int CL_B1   = 2;   // class B1: the same at the unit's input (already one cycle late)
    localparam int CL_B2   = 3;   // class B2, pipeline event: one register inside the unit
    localparam int CL_TRAP = 4;   // class B2, trap event: two registers inside the unit

    function automatic int code_class(int c);
        if (c >= 1   && c <= 20)  return CL_A;
        if (c >= 21  && c <= 26)  return CL_TRAP;
        if (c >= 32  && c <= 46)  return CL_B2;
        if (c >= 47  && c <= 49)  return CL_B1;
        if (c >= 128 && c <= 159) return CL_B1;
        if (c == 160 || c == 161) return CL_B1;
        return CL_NONE;
    endfunction

    // An event code a build with the given present mask has (and so a selector may hold).
    function automatic bit code_legal(int c, bit [31:0] pres);
        if (c >= 1   && c <= 26)  return 1'b1;
        if (c >= 32  && c <= 49)  return 1'b1;
        if (c >= 128 && c <= 159) return pres[c - 128];
        if (c == 160)             return pres[0];
        if (c == 161)             return pres[1];
        return 1'b0;
    endfunction

    // A value written to a selector is kept only as a legal code in bits 7:0 with bits 31:8 = 0.
    function automatic bit selector_value_legal(bit [31:0] v, bit [31:0] pres);
        return (v[31:8] == 24'd0) && code_legal(int'(v[7:0]), pres);
    endfunction

    function automatic bit [63:0] width_mask(int w);
        if (w >= 64) return 64'hFFFF_FFFF_FFFF_FFFF;
        return (64'd1 << w) - 64'd1;
    endfunction

    // The writable bits of mcountinhibit: CY, IR, the n programmable counters (bits 3 ..), and
    // the four predictor counters (10-13).
    function automatic bit [31:0] inhibit_mask(int n);
        bit [31:0] m = 32'h0000_3C05;
        for (int i = 0; i < n; i++) m[3 + i] = 1'b1;
        return m;
    endfunction

    // A small deterministic generator (xorshift64*), so that a seed gives the same run everywhere.
    class Rng;
        bit [63:0] s;
        function new(bit [63:0] seed);
            s = seed * 64'h9E37_79B9_7F4A_7C15 + 64'h0123_4567_89AB_CDEF;
            if (s == 64'd0) s = 64'd1;
            repeat (4) void'(u64());
        endfunction
        function bit [63:0] u64();
            s = s ^ (s >> 12);
            s = s ^ (s << 25);
            s = s ^ (s >> 27);
            return s * 64'h2545_F491_4F6C_DD1D;
        endfunction
        function bit [31:0] u32();
            bit [63:0] x = u64();
            return x[63:32];
        endfunction
        function int range(int lo, int hi);      // inclusive
            bit [31:0] x = u32();
            return lo + int'(x % 32'(hi - lo + 1));
        endfunction
        function bit chance(int num, int den);
            return range(0, den - 1) < num;
        endfunction
    endclass

    // The reference model of the counter unit.
    class HpmRef;
        int          n, w;
        bit [63:0]   cnt   [7];
        bit [7:0]    sel   [7];
        bit [31:0]   inh;
        bit [255:0]  pipe1;            // pipeline events of the previous cycle (class B2)
        bit [255:0]  trap1, trap2;     // trap events of one and of two cycles ago
        bit [31:0]   pres;             // present mask used by cyc() (the self-test)

        // what the stimulus reached (coverage)
        longint cv_count, cv_blocked, cv_carry, cv_wrap, cv_wr_ev, cv_wr_carry_kept, cv_wr_carry_lost;
        longint cv_sel_ok, cv_sel_rej, cv_sel_inflight, cv_inh_wr, cv_hi_ign, cv_rst;
        longint cv_cls [5];

        function new(int n_, int w_);
            n = n_; w = w_; pres = 32'd0;
            cv_count = 0; cv_blocked = 0; cv_carry = 0; cv_wrap = 0; cv_wr_ev = 0;
            cv_wr_carry_kept = 0; cv_wr_carry_lost = 0; cv_sel_ok = 0; cv_sel_rej = 0;
            cv_sel_inflight = 0; cv_inh_wr = 0; cv_hi_ign = 0; cv_rst = 0;
            for (int i = 0; i < 5; i++) cv_cls[i] = 0;
            clear();
        endfunction

        function void clear();
            for (int i = 0; i < 7; i++) begin cnt[i] = 64'd0; sel[i] = 8'd0; end
            inh = 32'd0; pipe1 = 256'd0; trap1 = 256'd0; trap2 = 256'd0;
        endfunction

        // The value a read of address a returns now (before this cycle's edge).
        function bit [31:0] read(bit [11:0] a);
            int ai = int'(a);
            if (ai == 'h320) return inh;
            if (ai >= 'h323 && ai < 'h323 + n) return {24'd0, sel[ai - 'h323]};
            if (ai == 'h32B) return 32'd18;
            if (ai == 'h32C) return 32'd19;
            if (ai == 'h32D) return 32'd20;
            if (ai >= 'hB03 && ai < 'hB03 + n) return cnt[ai - 'hB03][31:0];
            if (ai >= 'hB83 && ai < 'hB83 + n) return cnt[ai - 'hB83][63:32];
            return 32'd0;
        endfunction

        // One clock edge. ev: bit c is the condition of event code c at the port of its class.
        function void step(bit rst, bit [255:0] ev, bit [11:0] a, bit we, bit [31:0] wd,
                           bit [31:0] pr);
            int         ai = int'(a);
            bit [63:0]  mw = width_mask(w);
            bit [255:0] cur;
            bit [63:0]  old, nxt;
            bit [7:0]   code;
            bit         stp, ev_sel;
            bit [7:0]   nsel;
            if (rst) begin
                clear();
                cv_rst++;
                return;
            end
            // the events that act in this cycle, by class
            cur = 256'd0;
            for (int c = 1; c < 256; c++) begin
                case (code_class(c))
                    CL_A, CL_B1: cur[c] = ev[c];
                    CL_B2:       cur[c] = pipe1[c];
                    CL_TRAP:     cur[c] = trap2[c];
                    default:     cur[c] = 1'b0;
                endcase
            end
            for (int i = 0; i < n; i++) begin
                code   = sel[i];
                ev_sel = (code != 8'd0) && cur[code];
                stp    = ev_sel && !inh[3 + i];
                old    = cnt[i];
                nxt    = (old + (stp ? 64'd1 : 64'd0)) & mw;
                if (ev_sel && inh[3 + i]) cv_blocked++;
                if (stp) begin
                    cv_count++;
                    cv_cls[code_class(int'(code))]++;
                    if (w > 32 && old[31:0] == 32'hFFFF_FFFF) cv_carry++;
                    if (old == mw) cv_wrap++;
                end
                if (we && ai == 'hB03 + i) begin
                    nxt = (nxt & ~64'hFFFF_FFFF) | {32'd0, wd};
                    if (stp) begin
                        cv_wr_ev++;
                        if (w > 32 && old[31:0] == 32'hFFFF_FFFF) cv_wr_carry_kept++;
                    end
                end else if (we && ai == 'hB83 + i) begin
                    if (w > 32) begin
                        nxt = (nxt & 64'hFFFF_FFFF) | (({32'd0, wd} << 32) & mw);
                        if (stp) begin
                            cv_wr_ev++;
                            if (old[31:0] == 32'hFFFF_FFFF) cv_wr_carry_lost++;
                        end
                    end else begin
                        cv_hi_ign++;
                    end
                end
                cnt[i] = nxt;
            end
            // selector and inhibit writes act after the counters used the old values
            if (we && ai == 'h320) begin
                inh = wd & inhibit_mask(n);
                cv_inh_wr++;
            end
            for (int i = 0; i < n; i++) begin
                if (we && ai == 'h323 + i) begin
                    nsel = selector_value_legal(wd, pr) ? wd[7:0] : 8'd0;
                    if (nsel != 8'd0) begin
                        cv_sel_ok++;
                        if (pipe1[nsel] || trap1[nsel] || trap2[nsel]) cv_sel_inflight++;
                    end else if (wd != 32'd0) begin
                        cv_sel_rej++;
                    end
                    sel[i] = nsel;
                end
            end
            trap2 = trap1;
            trap1 = ev;
            pipe1 = ev;
        endfunction

        // One cycle for the self-test, with the model's own present mask.
        function void cyc(bit [255:0] ev, bit [11:0] a, bit we, bit [31:0] wd);
            step(1'b0, ev, a, we, wd, pres);
        endfunction
        function void rst_cyc();
            step(1'b1, 256'd0, 12'd0, 1'b0, 32'd0, pres);
        endfunction
    endclass

endpackage


// The unit under test, wired the way the bench drives it. This is the only place that knows the
// unit's module name (macro HPM_UNIT), port names and widths: if they differ, change them here.
//   ev[c] is the condition of event code c as it arrives at the port of its class; the bench
//   drives the whole vector to every port, so bits that no selector can pick carry garbage.
//   ev_a: class A, bit c = code c (21-31 never act). The class B1 events and the B2 pipeline events
//   (both already one cycle late) go in one struct, code-indexed. trap_raw: bit k = code 21 + k.
// The unit's module name; give +define+HPM_UNIT=<name> if it differs.
`ifndef HPM_UNIT
    `define HPM_UNIT hpm
`endif

module hpm_dut_wrap #(
    parameter int N = 7,
    parameter int W = 48
) (
    input  logic          clk,
    input  logic          rst,
    input  logic [255:0]  ev,
    input  logic [11:0]   addr,
    input  logic          we,
    input  logic [31:0]   wdata,
    input  logic [31:0]   present,
    output logic [31:0]   rdata,
    output logic          inh_cy,
    output logic          inh_ir,
    output logic [3:0]    inh_bp
);
    // The unit takes its late events as one struct (hpm_pkg::late_t), every field indexed by event
    // code; ev_a covers codes 1 to 20, trap_raw codes 21 to 26.
    hpm_pkg::late_t late;
    always_comb begin
        late.comb = ev[161:160];
        late.ext  = ev[159:128];
        late.b1   = ev[49:47];
        late.b2   = ev[46:32];
    end

    `HPM_UNIT #(.N(N), .W(W)) u (
        .clk(clk), .rst(rst),
        .ev_a(ev[20:1]),
        .trap_raw(ev[26:21]),
        .late(late),
        .csr_addr(addr), .csr_we(we), .csr_wdata(wdata),
        .hpm_ext_present(present),
        .rdata(rdata),
        .inh_cy(inh_cy), .inh_ir(inh_ir), .inh_bp(inh_bp)
    );
endmodule


// One configuration: the unit with N counters of W bits, a stimulus generator, the model and the
// comparison.
module hpm_unit_check #(
    parameter int N  = 7,
    parameter int W  = 48,
    parameter int ID = 0
) (
    input  logic            clk,
    output logic            done,
    output logic            bad,
    output logic            covbad,
    output longint unsigned cycles_o
);
    import hpm_bench_pkg::*;

`ifndef HPM_NOPROBE
    `ifndef HPM_PROBE
        `define HPM_PROBE
    `endif
`endif
`ifdef HPM_PROBE
    // Direct comparison of the unit's registers (counter i is the unit's counter i + 3).
    `ifndef HPM_PROBE_CNT
        `define HPM_PROBE_CNT(i) dut.u.cnt[(i) + 3]
    `endif
    `ifndef HPM_PROBE_SEL
        `define HPM_PROBE_SEL(i) dut.u.sel[(i) + 3]
    `endif
    `ifndef HPM_PROBE_INH
        `define HPM_PROBE_INH dut.u.inhibit
    `endif
`endif

    localparam int NPH = 8;

    // ---- signals to the unit ----
    logic          rst;
    logic [11:0]   addr;
    logic          we;
    logic [31:0]   wdata;
    logic [255:0]  ev;
    logic [31:0]   present;
    logic [31:0]   d_rdata;
    logic          d_inh_cy, d_inh_ir;
    logic [3:0]    d_inh_bp;

    hpm_dut_wrap #(.N(N), .W(W)) dut (
        .clk(clk), .rst(rst), .ev(ev), .addr(addr), .we(we), .wdata(wdata), .present(present),
        .rdata(d_rdata), .inh_cy(d_inh_cy), .inh_ir(d_inh_ir), .inh_bp(d_inh_bp)
    );

    // ---- the cycle script ----
    typedef struct {
        bit          rst;
        bit          setp;      // load a new present mask in this cycle
        bit [31:0]   pres;
        bit [11:0]   a;
        bit          we;
        bit [31:0]   wd;
        int          evm;       // 0 random events, 1 none, 2 all ones, 3 only the selected codes
    } cyc_t;

    cyc_t        q [$];
    HpmRef       model;
    Rng          rng;

    bit          started, seen_rst, finished;
    int          phase_idx, rand_left;
    bit          scan_done;
    bit [31:0]   phase_mask;
    int          legal_list [$];
    int          base_dk, hot_dk;
    int          burst_left;
    bit          burst_ones;
    int          focus, focus_left;
    int          obs_left;
    bit [11:0]   obs_addr;
    longint unsigned cyc_no;
    int          phase_cycles;
    bit          maskhi, rstev, cover_on;
    bit [63:0]   seed;

    // ------------------------------------------------------------------ helpers
    function automatic void qpush(bit rst_, bit [11:0] a_, bit we_, bit [31:0] wd_, int evm_);
        cyc_t c;
        c.rst = rst_; c.setp = 1'b0; c.pres = 32'd0; c.a = a_; c.we = we_; c.wd = wd_; c.evm = evm_;
        q.push_back(c);
    endfunction

    function automatic void qwr(bit [11:0] a_, bit [31:0] wd_, int evm_);
        qpush(1'b0, a_, 1'b1, wd_, evm_);
    endfunction

    function automatic void qrd(bit [11:0] a_, int evm_);
        qpush(1'b0, a_, 1'b0, 32'd0, evm_);
    endfunction

    function automatic bit [255:0] rnd256(int dk);
        bit [255:0] r;
        bit [255:0] x, y, z;
        for (int i = 0; i < 4; i++) begin
            x[64*i +: 64] = rng.u64();
            y[64*i +: 64] = rng.u64();
            z[64*i +: 64] = rng.u64();
        end
        case (dk)
            0:       r = 256'd0;
            1:       r = x & y & z;          // 1/8
            2:       r = x & y;              // 1/4
            3:       r = x;                  // 1/2
            4:       r = x | y;              // 3/4
            5:       r = x | y | z;          // 7/8
            default: r = ~256'd0;
        endcase
        return r;
    endfunction

    function automatic bit [255:0] selected_mask();
        bit [255:0] m = 256'd0;
        for (int i = 0; i < N; i++) if (model.sel[i] != 8'd0) m[model.sel[i]] = 1'b1;
        return m;
    endfunction

    function automatic bit [255:0] gen_events();
        bit [255:0] base, hot, r;
        base = rnd256(base_dk);
        hot  = selected_mask();
        if (burst_left == 0 && rng.chance(1, 24)) begin
            burst_left = rng.range(4, 40);
            burst_ones = rng.chance(1, 2);
        end
        if (burst_left > 0) begin
            burst_left--;
            if (burst_ones) r = base | hot;
            else            r = base & ~hot;
        end else begin
            r = base | (hot & rnd256(hot_dk));
        end
        return r;
    endfunction

    function automatic bit [31:0] pick_mask(int ph);
        case (ph % 4)
            0:       return 32'd0;
            1:       return 32'h0000_0FFF;
            default: begin
                bit [31:0] r = rng.u32();
                return maskhi ? r : (r & 32'h0000_0FFF);
            end
        endcase
    endfunction

    function automatic void make_legal_list(bit [31:0] pres);
        legal_list.delete();
        for (int c = 1; c < 256; c++) if (code_legal(c, pres)) legal_list.push_back(c);
    endfunction

    function automatic bit [31:0] pick_selval();
        int r = rng.range(0, 99);
        if (r < 62) return 32'(legal_list[rng.range(0, legal_list.size() - 1)]);
        if (r < 72) return 32'd0;
        if (r < 84) return 32'(rng.range(0, 255));
        case (rng.range(0, 5))
            0:       return 32'h0000_0100 | 32'(rng.range(0, 255));
            1:       return 32'hFFFF_FFFF;
            2:       return 32'h8000_0000 | 32'(rng.range(0, 255));
            3:       return 32'h0100_0000 | 32'(rng.range(0, 255));
            4:       return 32'(rng.range(256, 4096));
            default: return 32'(rng.range(0, 255)) | (32'd1 << rng.range(8, 31));
        endcase
    endfunction

    function automatic bit [31:0] pick_lo(int idx);
        case (rng.range(0, 7))
            0:       return 32'(rng.range(0, 15));
            1:       return 32'hFFFF_FFFF - 32'(rng.range(0, 5));
            2:       return rng.u32();
            3:       return rng.chance(1, 2) ? 32'h7FFF_FFFF : 32'h8000_0000;
            4:       return (idx < N) ? model.cnt[idx][31:0] : 32'd0;
            5:       return 32'hFFFF_FFFF;
            6:       return 32'hFFFF_FFFF - 32'(rng.range(0, 40));
            default: return 32'd0;
        endcase
    endfunction

    function automatic bit [31:0] pick_hi(int idx);
        bit [63:0] hm = width_mask(W) >> 32;
        case (rng.range(0, 6))
            0:       return rng.u32();
            1:       return 32'(hm) - 32'(rng.range(0, 2));
            2:       return 32'(rng.range(0, 1));
            3:       return 32'hFFFF_FFFF;
            4:       return 32'(hm) + 32'd1;
            5:       return (idx < N) ? model.cnt[idx][63:32] : 32'd0;
            default: return 32'(rng.range(0, 255));
        endcase
    endfunction

    function automatic bit [31:0] pick_inh();
        case (rng.range(0, 7))
            0:       return 32'hFFFF_FFFF;
            1, 6, 7: return 32'd0;
            2:       return 32'd1 << rng.range(0, 31);
            3:       return rng.u32() & 32'h0000_3FFF;
            4:       return ~(32'd1 << rng.range(0, 13));
            default: return rng.u32();
        endcase
    endfunction

    // ------------------------------------------------------------------ one random cycle
    function automatic void gen_random();
        cyc_t c;
        int   r, i;
        c.rst = 1'b0; c.setp = 1'b0; c.pres = 32'd0; c.evm = 0;
        c.a = 12'd0; c.we = 1'b0; c.wd = 32'd0;
        if (focus_left <= 0) begin focus = rng.range(0, (N > 0) ? N - 1 : 0); focus_left = rng.range(30, 200); end
        focus_left--;
        r = rng.range(0, 99);
        if (rng.chance(1, 300)) begin
            // a reset of one to four cycles
            c.rst = 1'b1;
            c.a = 12'(rng.range(0, 4095)); c.we = rng.chance(1, 2); c.wd = rng.u32();
            q.push_back(c);
            for (int k = rng.range(0, 3); k > 0; k--) qpush(1'b1, 12'd0, 1'b0, 32'd0, 0);
            obs_left = 0;
            return;
        end
        if (obs_left > 0 && r < 55) begin
            obs_left--;
            c.a = obs_addr;
            if (rng.chance(1, 3) && N > 0) c.a = (c.a >= 12'hB83 && c.a <= 12'hB89) ? c.a - 12'h80 : c.a + 12'h80;
            if (c.a < 12'h320 || (c.a > 12'h329 && c.a < 12'hB03) || c.a > 12'hB89) c.a = obs_addr;
        end else if (r < 13) begin
            c.a = 12'h320; c.we = rng.chance(6, 10); c.wd = pick_inh();
            if (c.we) begin obs_left = 2; obs_addr = c.a; end
        end else if (r < 30) begin
            i = rng.chance(85, 100) ? rng.range(0, (N > 0) ? N - 1 : 0) : rng.range(0, 22);
            c.a = 12'h323 + 12'(i); c.we = rng.chance(6, 10); c.wd = pick_selval();
            if (c.we) begin obs_left = 3; obs_addr = (i < N && rng.chance(1, 2)) ? 12'hB03 + 12'(i) : c.a; end
        end else if (r < 72) begin
            i = rng.chance(85, 100) ? rng.range(0, (N > 0) ? N - 1 : 0) : rng.range(0, 22);
            if (rng.chance(40, 100)) begin
                c.a = 12'hB83 + 12'(i); c.we = rng.chance(25, 100); c.wd = c.we ? pick_hi(i) : 32'd0;
            end else begin
                c.a = 12'hB03 + 12'(i); c.we = rng.chance(25, 100); c.wd = c.we ? pick_lo(i) : 32'd0;
            end
            if (c.we) begin obs_left = 4; obs_addr = (i < N) ? 12'hB03 + 12'(i) : c.a; end
        end else if (r < 82) begin
            case (rng.range(0, 6))
                0:       c.a = 12'h32A + 12'(rng.range(0, 3));
                1:       c.a = 12'hB0A + 12'(rng.range(0, 3));
                2:       c.a = rng.chance(1, 2) ? 12'hB00 : 12'hB02;
                3:       c.a = rng.chance(1, 2) ? 12'hB80 : 12'hB82;
                4:       c.a = 12'h300 + 12'(rng.range(0, 63));
                5:       c.a = 12'hB00 + 12'(rng.range(0, 31));
                default: c.a = 12'hB80 + 12'(rng.range(0, 31));
            endcase
            c.we = rng.chance(4, 10); c.wd = rng.u32();
            if (c.we) begin obs_left = 2; obs_addr = c.a; end
        end else if (r < 85) begin
            c.a = 12'(rng.range(0, 4095)); c.we = rng.chance(1, 2); c.wd = rng.u32();
        end else begin
            // the focus counter, read in many cycles so that a counter is seen in consecutive cycles
            c.a = (rng.chance(1, 2) ? 12'hB03 : 12'hB83) + 12'(focus);
        end
        q.push_back(c);
    endfunction

    // ------------------------------------------------------------------ directed sequences
    function automatic void push_scan();
        qrd(12'h320, 1);
        for (int i = 0; i < 7; i++) begin
            qrd(12'h323 + 12'(i), 1); qrd(12'hB03 + 12'(i), 1); qrd(12'hB83 + 12'(i), 1);
        end
        for (int i = 0; i < 4; i++) begin
            qrd(12'h32A + 12'(i), 1); qrd(12'hB0A + 12'(i), 1); qrd(12'hB8A + 12'(i), 1);
        end
        qrd(12'hB00, 1); qrd(12'hB02, 1); qrd(12'hB80, 1); qrd(12'hB82, 1);
        qrd(12'h321, 1); qrd(12'h322, 1); qrd(12'h32E, 1); qrd(12'h33F, 1); qrd(12'h300, 1);
        qrd(12'hB1F, 1); qrd(12'hB9F, 1);
        qrd(12'h320, 1);
    endfunction

    // The selectors, the inhibit register: every value, written and read back.
    function automatic void push_sel_inh();
        int special [5] = '{256, 32'h1FF, 32'hFFFF_FFFF, 32'h8000_0080, 32'h0000_8001};
        for (int i = 0; i < 7; i++) begin
            for (int v = 0; v < 256; v++) begin qwr(12'h323 + 12'(i), 32'(v), 0); qrd(12'h323 + 12'(i), 0); end
            for (int k = 0; k < 5; k++)   begin qwr(12'h323 + 12'(i), 32'(special[k]), 0); qrd(12'h323 + 12'(i), 0); end
            qwr(12'h323 + 12'(i), 32'd0, 0);
        end
        qwr(12'h320, 32'hFFFF_FFFF, 0); qrd(12'h320, 0);
        qwr(12'h320, 32'd0, 0);         qrd(12'h320, 0);
        for (int b = 0; b < 32; b++) begin
            qwr(12'h320, 32'd1 << b, 0); qrd(12'h320, 0);
            qwr(12'h320, ~(32'd1 << b), 0); qrd(12'h320, 0);
        end
        qwr(12'h320, 32'd0, 0);
        // the constants and the addresses the unit does not implement: writes change nothing
        for (int k = 0; k < 4; k++) begin
            qwr(12'h32A + 12'(k), 32'hFFFF_FFFF, 0); qrd(12'h32A + 12'(k), 0);
            qwr(12'hB0A + 12'(k), 32'hFFFF_FFFF, 0); qrd(12'hB0A + 12'(k), 0);
            qwr(12'hB8A + 12'(k), 32'hFFFF_FFFF, 0); qrd(12'hB8A + 12'(k), 0);
        end
        qwr(12'hB00, 32'h1234_5678, 0); qrd(12'hB00, 0); qwr(12'hB02, 32'h1234_5678, 0); qrd(12'hB02, 0);
        qwr(12'hB80, 32'h1234_5678, 0); qrd(12'hB80, 0); qwr(12'hB82, 32'h1234_5678, 0); qrd(12'hB82, 0);
    endfunction

    // For counter i: carry, wrap, write beside an event, lost carry, mask of the high half, the
    // inhibit, and pulses around a selector write, for one code of each counting class.
    function automatic void push_counter(int i, int code);
        bit [11:0]  al = 12'hB03 + 12'(i);
        bit [11:0]  ah = 12'hB83 + 12'(i);
        bit [11:0]  as_ = 12'h323 + 12'(i);
        bit [31:0]  hm = 32'(width_mask(W) >> 32);
        qwr(12'h320, 32'd0, 1);
        qwr(as_, 32'(code), 1);
        // carry from the low half into the high half
        qwr(ah, 32'd0, 1); qwr(al, 32'hFFFF_FFFE, 1);
        for (int k = 0; k < 6; k++) qrd(al, 2);
        qrd(ah, 2); qrd(ah, 1); qrd(al, 1); qrd(ah, 1);
        // a low write in the cycle in which the low half carries
        qwr(al, 32'hFFFF_FFFF, 1); qrd(al, 1);
        for (int k = 0; k < 4; k++) qwr(al, 32'd7, 2);
        qrd(al, 1); qrd(ah, 1);
        qwr(al, 32'hFFFF_FFFF, 1); qwr(al, 32'h8000_0000, 2); qrd(al, 1); qrd(ah, 1);
        // a high write in the cycle in which the low half carries: the carry is lost
        qwr(al, 32'hFFFF_FFFF, 1); qwr(ah, 32'd5, 2); qrd(al, 1); qrd(ah, 1);
        qwr(al, 32'hFFFF_FFFF, 1); qwr(ah, 32'hFFFF_FFFF, 2); qrd(al, 1); qrd(ah, 1);
        // wrap from 2^W - 1
        qwr(ah, 32'hFFFF_FFFF, 1); qwr(al, 32'hFFFF_FFFF, 1);
        qrd(al, 2); qrd(al, 1); qrd(ah, 1); qrd(al, 1);
        qwr(ah, hm, 1); qwr(al, 32'hFFFF_FFFF, 1); qwr(al, 32'd3, 2); qrd(al, 1); qrd(ah, 1);
        qwr(ah, hm, 1); qwr(al, 32'hFFFF_FFFF, 1); qwr(ah, 32'd0, 2); qrd(al, 1); qrd(ah, 1);
        // the mask of the high half
        qwr(ah, 32'hFFFF_FFFF, 1); qrd(ah, 1); qwr(ah, 32'h8000_0000, 1); qrd(ah, 1);
        qwr(ah, 32'h0000_0001, 1); qrd(ah, 1); qwr(ah, 32'd0, 1); qrd(ah, 1);
        // inhibit: the other counters' bits do not matter
        qwr(al, 32'd0, 1);
        qwr(12'h320, 32'd1 << (3 + i), 2); qrd(al, 2); qrd(al, 2); qwr(12'h320, 32'd0, 2); qrd(al, 1); qrd(al, 1);
        qwr(12'h320, ~(32'd1 << (3 + i)), 2); qrd(al, 2); qrd(al, 2); qwr(12'h320, 32'd0, 1); qrd(al, 1);
        // single-cycle pulses; a selector written in the pulse's cycle and in the cycle after
        for (int rep = 0; rep < 3; rep++) begin
            qwr(as_, 32'd0, 1); qwr(al, 32'd0, 1); qwr(ah, 32'd0, 1);
            qwr(as_, 32'(code), 2);
            for (int k = 0; k < 5; k++) qrd(al, 1);
            qwr(as_, 32'd0, 1); qrd(al, 1);
            qpush(1'b0, as_, 1'b0, 32'd0, 2); qwr(as_, 32'(code), 1);
            for (int k = 0; k < 5; k++) qrd(al, 1);
            qwr(as_, 32'd0, 1); qwr(al, 32'd0, 1);
            qpush(1'b0, al, 1'b0, 32'd0, 2); qwr(as_, 32'(code), 1);
            qrd(al, 1); qrd(al, 1); qrd(al, 1); qrd(al, 1);
            qwr(as_, 32'd0, 2); qwr(as_, 32'(code), 1); qwr(as_, 32'(code), 2);
            for (int k = 0; k < 5; k++) qrd(al, 1);
        end
        // a pulse and a write of the counter in the same cycle, in the next, and one later
        qwr(as_, 32'(code), 1);
        qwr(al, 32'd9, 2); qrd(al, 1); qrd(al, 1); qrd(al, 1); qrd(al, 1);
        qwr(al, 32'd9, 1); qwr(al, 32'd20, 2); qrd(al, 1); qrd(al, 1); qrd(al, 1); qrd(al, 1);
        qwr(al, 32'd30, 1); qrd(al, 2); qwr(al, 32'd40, 1); qrd(al, 1); qrd(al, 1); qrd(al, 1); qrd(al, 1);
        qwr(as_, 32'd0, 1);
    endfunction

    // A reset right behind a trap pulse, with the selector written in the reset's neighbours.
    function automatic void push_reset_cases();
        int cl [4] = '{1, 21, 32, 47};
        for (int k = 0; k < 4; k++) begin
            qwr(12'h323, 32'(cl[k]), 1);
            qpush(1'b0, 12'hB03, 1'b0, 32'd0, 2);
            qpush(1'b1, 12'hB03, 1'b0, 32'd0, 2);
            qwr(12'h323, 32'(cl[k]), 1);
            qrd(12'hB03, 1); qrd(12'hB03, 1); qrd(12'hB03, 1); qrd(12'hB03, 1);
            qwr(12'h323, 32'(cl[k]), 2);
            qpush(1'b1, 12'h323, 1'b0, 32'd0, 2);
            qrd(12'h323, 1); qrd(12'hB03, 1); qrd(12'hB03, 1); qrd(12'hB03, 1);
        end
    endfunction

    function automatic void start_phase(int ph);
        cyc_t c;
        phase_mask = pick_mask(ph);
        make_legal_list(phase_mask);
        case (ph % 8)
            0: begin base_dk = 3; hot_dk = 3; end
            1: begin base_dk = 1; hot_dk = 3; end
            2: begin base_dk = 4; hot_dk = 2; end
            3: begin base_dk = 2; hot_dk = 4; end
            4: begin base_dk = 3; hot_dk = 5; end
            5: begin base_dk = 0; hot_dk = 4; end
            6: begin base_dk = 5; hot_dk = 3; end
            default: begin base_dk = 2; hot_dk = 6; end
        endcase
        // three reset cycles; the new present mask is loaded in the first of them
        c.rst = 1'b1; c.setp = 1'b1; c.pres = phase_mask; c.a = 12'd0; c.we = 1'b0; c.wd = 32'd0; c.evm = 1;
        q.push_back(c);
        qpush(1'b1, 12'd0, 1'b0, 32'd0, 1);
        qpush(1'b1, 12'd0, 1'b0, 32'd0, 1);
        qrd(12'h320, 1);
        push_scan();
        push_sel_inh();
        // every address of the 12-bit space: read in the even phases, written (and read) in the odd
        for (int a = 0; a < 4096; a++) begin
            if (ph % 2 == 0) begin
                qrd(12'(a), 0);
            end else begin
                qwr(12'(a), rng.u32(), 0); qrd(12'(a), 0);
            end
        end
        for (int i = 0; i < 7; i++) begin
            int cl [4] = '{1, 21, 32, 47};
            // counters above N are written and read too (they must stay 0)
            for (int k = 0; k < ((i < N) ? 4 : 1); k++) push_counter(i, cl[k]);
        end
        push_reset_cases();
        rand_left = phase_cycles;
        scan_done = 1'b0;
        burst_left = 0; focus_left = 0; obs_left = 0;
    endfunction

    // ------------------------------------------------------------------ driving one cycle
    task automatic apply(cyc_t c);
        bit [255:0] e;
        rst = c.rst; addr = c.a; we = c.we; wdata = c.wd;
        if (c.setp) present = c.pres;
        case (c.evm)
            0:       e = gen_events();
            1:       e = 256'd0;
            2:       e = ~256'd0;
            default: e = selected_mask();
        endcase
        if (c.rst && !rstev) e = 256'd0;
        ev = e;
    endtask

    task automatic fail(string what);
        if (!bad) begin
            bad = 1'b1;
            $display("HPM BENCH: MISMATCH (N=%0d W=%0d, phase %0d, cycle %0d, present 0x%08x): %s",
                     N, W, phase_idx, cyc_no, present, what);
            $display("HPM BENCH:   inputs: rst=%0b addr=0x%03x we=%0b wdata=0x%08x ev[63:0]=0x%016x ev[191:128]=0x%016x",
                     rst, addr, we, wdata, ev[63:0], ev[191:128]);
        end
    endtask

    task automatic check();
        bit [31:0] exp;
        if (!seen_rst || rst || bad) return;
        exp = model.read(addr);
        if (d_rdata !== exp)
            fail($sformatf("read of 0x%03x: model 0x%08x, unit 0x%08x", addr, exp, d_rdata));
        if (d_inh_cy !== model.inh[0])
            fail($sformatf("inh_cy: model %0b, unit %0b", model.inh[0], d_inh_cy));
        if (d_inh_ir !== model.inh[2])
            fail($sformatf("inh_ir: model %0b, unit %0b", model.inh[2], d_inh_ir));
        if (d_inh_bp !== model.inh[13:10])
            fail($sformatf("inh_bp: model 0x%0x, unit 0x%0x", model.inh[13:10], d_inh_bp));
`ifdef HPM_PROBE
        for (int i = 0; i < N; i++) begin
            bit [63:0] pc = 64'(`HPM_PROBE_CNT(i));
            bit [63:0] ps = 64'(`HPM_PROBE_SEL(i));
            if (pc !== model.cnt[i]) fail($sformatf("counter %0d: model 0x%016x, unit 0x%016x", i, model.cnt[i], pc));
            if (ps[7:0] !== model.sel[i]) fail($sformatf("selector %0d: model 0x%02x, unit 0x%02x", i, model.sel[i], ps[7:0]));
        end
        if (32'(`HPM_PROBE_INH) !== model.inh) fail($sformatf("inhibit: model 0x%08x, unit 0x%08x", model.inh, 32'(`HPM_PROBE_INH)));
`endif
    endtask

    always @(posedge clk) begin
        if (started && !finished) model.step(rst, ev, addr, we, wdata, present);
    end

    function automatic string cov_line();
        return $sformatf("count %0d blocked %0d carry %0d wrap %0d write+event %0d keptcarry %0d lostcarry %0d sel ok/rej/inflight %0d/%0d/%0d inh writes %0d hi-ignored %0d resets %0d; classes A/B1/B2/trap %0d/%0d/%0d/%0d",
                         model.cv_count, model.cv_blocked, model.cv_carry, model.cv_wrap, model.cv_wr_ev,
                         model.cv_wr_carry_kept, model.cv_wr_carry_lost, model.cv_sel_ok, model.cv_sel_rej,
                         model.cv_sel_inflight, model.cv_inh_wr, model.cv_hi_ign, model.cv_rst,
                         model.cv_cls[CL_A], model.cv_cls[CL_B1], model.cv_cls[CL_B2], model.cv_cls[CL_TRAP]);
    endfunction

    // every case the stimulus is meant to reach was reached
    function automatic string cov_missing();
        string s = "";
        if (N > 0) begin
            if (model.cv_count < 100)      s = {s, " count"};
            if (model.cv_blocked < 10)     s = {s, " blocked"};
            if (model.cv_wrap < 3)         s = {s, " wrap"};
            if (model.cv_wr_ev < 10)       s = {s, " write+event"};
            if (model.cv_sel_ok < 100)     s = {s, " selector-ok"};
            if (model.cv_sel_rej < 10)     s = {s, " selector-rejected"};
            if (model.cv_sel_inflight < 3) s = {s, " selector-with-event-in-flight"};
            if (model.cv_cls[CL_A] < 10)    s = {s, " class-A"};
            if (model.cv_cls[CL_B1] < 10)   s = {s, " class-B1"};
            if (model.cv_cls[CL_B2] < 10)   s = {s, " class-B2"};
            if (model.cv_cls[CL_TRAP] < 10) s = {s, " class-trap"};
            if (W > 32) begin
                if (model.cv_carry < 10)           s = {s, " carry"};
                if (model.cv_wr_carry_kept < 3)    s = {s, " write-with-carry"};
                if (model.cv_wr_carry_lost < 3)    s = {s, " high-write-loses-carry"};
            end else begin
                if (model.cv_hi_ign < 3)           s = {s, " high-write-ignored"};
            end
        end
        if (model.cv_inh_wr < 10) s = {s, " inhibit-write"};
        if (model.cv_rst < 3)     s = {s, " reset"};
        return s;
    endfunction

    // ------------------------------------------------------------------ the run
    initial begin : run
        cyc_t c;
        string missing;
        done = 1'b0; bad = 1'b0; covbad = 1'b0; cycles_o = 64'd0;
        started = 1'b0; seen_rst = 1'b0; finished = 1'b0;
        phase_idx = 0; rand_left = 0; scan_done = 1'b0; cyc_no = 0;
        rst = 1'b1; addr = 12'd0; we = 1'b0; wdata = 32'd0; ev = 256'd0; present = 32'd0;
        base_dk = 3; hot_dk = 3; burst_left = 0; burst_ones = 1'b0; focus = 0; focus_left = 0;
        obs_left = 0; obs_addr = 12'd0;
        phase_cycles = 20000; seed = 64'd1; maskhi = 1'b0; rstev = 1'b0; cover_on = 1'b1;
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("cycles=%d", phase_cycles));
        maskhi   = $test$plusargs("maskhi=1");
        rstev    = $test$plusargs("rstev=1");
        cover_on = !$test$plusargs("cover=0");
        begin
            int only_k;
            if ($value$plusargs("only=%d", only_k) && only_k != ID) begin
                done = 1'b1;
                disable run;
            end
        end
        model = new(N, W);
        rng   = new(seed * 64'd1000003 + 64'(ID) * 64'd7919 + 64'd17);
        start_phase(0);
        while (!finished && !bad) begin
            @(negedge clk);
            if (started && rst) seen_rst = 1'b1;     // an edge with rst = 1 has gone by
            if (q.size() == 0) begin
                if (rand_left > 0) begin
                    gen_random();
                    rand_left--;
                end else if (!scan_done) begin
                    push_scan();
                    scan_done = 1'b1;
                end else begin
                    phase_idx++;
                    if (phase_idx >= NPH) finished = 1'b1;
                    else start_phase(phase_idx);
                end
            end
            if (q.size() > 0) begin
                c = q.pop_front();
                apply(c);
                started = 1'b1;
                cyc_no++;
                #1;
                check();
            end
        end
        // let the last edge go by, then judge
        @(negedge clk);
        cycles_o = cyc_no;
        missing = cov_missing();
        if (!bad) begin
            $display("HPM BENCH: N=%0d W=%0d: ok, %0d cycles; %s", N, W, cyc_no, cov_line());
            if (missing != "") begin
                $display("HPM BENCH: N=%0d W=%0d: cases not reached:%s", N, W, missing);
                covbad = cover_on;
            end
        end
        done = 1'b1;
    end
endmodule


module test_hpm;
    import hpm_bench_pkg::*;

    localparam int NCFG = 12;

    logic clk;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic int cfg_n(int k);
        case (k)
            0, 1, 2:  return 0;
            3, 4, 5:  return 1;
            6, 7, 8:  return 7;
            9:        return 7;
            10:       return 3;
            default:  return 2;
        endcase
    endfunction
    function automatic int cfg_w(int k);
        case (k)
            9:        return 33;
            10:       return 40;
            11:       return 63;
            default:  begin
                case (k % 3)
                    0: return 32;
                    1: return 48;
                    default: return 64;
                endcase
            end
        endcase
    endfunction

    logic [NCFG-1:0]    done, bad, covbad;
    longint unsigned    cycles [NCFG];

    for (genvar g = 0; g < NCFG; g++) begin : cfg
        hpm_unit_check #(.N(cfg_n(g)), .W(cfg_w(g)), .ID(g)) u (
            .clk(clk), .done(done[g]), .bad(bad[g]), .covbad(covbad[g]), .cycles_o(cycles[g])
        );
    end

    // ---- the model's own check, with numbers worked out by hand ----
    int st_checks = 0;

    task automatic expect32(string what, bit [31:0] got, bit [31:0] exp);
        st_checks++;
        if (got !== exp) begin
            $display("HPM MODEL SELF-TEST: FAIL (%s: the model gives 0x%08x, the hand-computed value is 0x%08x)", what, got, exp);
            $fatal(1, "the model of the counter unit disagrees with a hand-computed case");
        end
    endtask

    function automatic bit [255:0] ONE(int c);
        bit [255:0] x = 256'd1;
        return x << c;
    endfunction

    task automatic model_self_test();
        HpmRef m, m0, m1, m3, mw32, mw64, mw33, mw40;
        bit [255:0] z = 256'd0;

        // ---- reset values and the constant reads (N = 7, W = 48, I-cache mask) ----
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        expect32("reset: mcountinhibit", m.read(12'h320), 32'h0);
        for (int i = 0; i < 7; i++) begin
            expect32("reset: selector", m.read(12'h323 + 12'(i)), 32'h0);
            expect32("reset: counter low", m.read(12'hB03 + 12'(i)), 32'h0);
            expect32("reset: counter high", m.read(12'hB83 + 12'(i)), 32'h0);
        end
        expect32("mhpmevent11", m.read(12'h32B), 32'd18);
        expect32("mhpmevent12", m.read(12'h32C), 32'd19);
        expect32("mhpmevent13", m.read(12'h32D), 32'd20);
        expect32("0x32A is not the unit's", m.read(12'h32A), 32'h0);
        expect32("0xB0A is not the unit's", m.read(12'hB0A), 32'h0);
        expect32("mcycle is not the unit's", m.read(12'hB00), 32'h0);
        expect32("minstreth is not the unit's", m.read(12'hB82), 32'h0);
        expect32("0x321", m.read(12'h321), 32'h0);
        expect32("0x330", m.read(12'h330), 32'h0);
        expect32("0xB0D", m.read(12'hB0D), 32'h0);
        expect32("0xB8A", m.read(12'hB8A), 32'h0);
        m.cyc(z, 12'h32B, 1'b1, 32'd5);
        expect32("a write to a constant selector", m.read(12'h32B), 32'd18);

        // ---- mcountinhibit: the writable mask, per N ----
        m.cyc(z, 12'h320, 1'b1, 32'hFFFF_FFFF);
        expect32("inhibit mask N=7", m.read(12'h320), 32'h0000_3FFD);
        m.cyc(z, 12'h320, 1'b1, 32'h0000_0002);
        expect32("inhibit: TM is read-only 0", m.read(12'h320), 32'h0);
        m.cyc(z, 12'h320, 1'b1, 32'h0000_0004);
        expect32("inhibit: IR", m.read(12'h320), 32'h4);
        m.cyc(z, 12'h320, 1'b1, 32'h0000_4000);
        expect32("inhibit: bit 14 is read-only 0", m.read(12'h320), 32'h0);
        m0 = new(0, 48); m0.rst_cyc();
        m0.cyc(z, 12'h320, 1'b1, 32'hFFFF_FFFF);
        expect32("inhibit mask N=0", m0.read(12'h320), 32'h0000_3C05);
        m1 = new(1, 48); m1.rst_cyc();
        m1.cyc(z, 12'h320, 1'b1, 32'hFFFF_FFFF);
        expect32("inhibit mask N=1", m1.read(12'h320), 32'h0000_3C0D);
        m3 = new(3, 48); m3.rst_cyc();
        m3.cyc(z, 12'h320, 1'b1, 32'hFFFF_FFFF);
        expect32("inhibit mask N=3", m3.read(12'h320), 32'h0000_3C3D);
        m.cyc(z, 12'h320, 1'b1, 32'h0000_0C0D);
        expect32("inhibit outputs CY", m.inh[0] ? 32'd1 : 32'd0, 32'd1);
        expect32("inhibit outputs IR", m.inh[2] ? 32'd1 : 32'd0, 32'd1);
        expect32("inhibit outputs bp", 32'(m.inh[13:10]), 32'h3);
        m.cyc(z, 12'h320, 1'b1, 32'h0);

        // ---- selector WARL, I-cache mask: counter 0 ----
        begin
            int wr [18] = '{1, 26, 27, 31, 32, 49, 50, 127, 128, 139, 140, 159, 160, 161, 162, 255, 256, 0};
            int ex [18] = '{1, 26,  0,  0, 32, 49,  0,   0, 128, 139,   0,   0, 160, 161,   0,   0,   0, 0};
            for (int k = 0; k < 18; k++) begin
                m.cyc(z, 12'h323, 1'b1, 32'(wr[k]));
                expect32($sformatf("selector WARL, write %0d", wr[k]), m.read(12'h323), 32'(ex[k]));
            end
            m.cyc(z, 12'h323, 1'b1, 32'h0000_0101);
            expect32("selector: 0x101", m.read(12'h323), 32'h0);
            m.cyc(z, 12'h323, 1'b1, 32'h8000_0001);
            expect32("selector: 0x80000001", m.read(12'h323), 32'h0);
            m.cyc(z, 12'h323, 1'b1, 32'hFFFF_FFFF);
            expect32("selector: all ones", m.read(12'h323), 32'h0);
        end
        // the present mask decides the cache codes
        m0 = new(1, 48); m0.pres = 32'h0; m0.rst_cyc();
        m0.cyc(z, 12'h323, 1'b1, 32'd128); expect32("mask 0: 128", m0.read(12'h323), 32'd0);
        m0.cyc(z, 12'h323, 1'b1, 32'd160); expect32("mask 0: 160", m0.read(12'h323), 32'd0);
        m0.cyc(z, 12'h323, 1'b1, 32'd161); expect32("mask 0: 161", m0.read(12'h323), 32'd0);
        m0.cyc(z, 12'h323, 1'b1, 32'd1);   expect32("mask 0: 1", m0.read(12'h323), 32'd1);
        m0.cyc(z, 12'h323, 1'b1, 32'd49);  expect32("mask 0: 49", m0.read(12'h323), 32'd49);
        m0 = new(1, 48); m0.pres = 32'h2; m0.rst_cyc();
        m0.cyc(z, 12'h323, 1'b1, 32'd129); expect32("mask 2: 129", m0.read(12'h323), 32'd129);
        m0.cyc(z, 12'h323, 1'b1, 32'd128); expect32("mask 2: 128", m0.read(12'h323), 32'd0);
        m0.cyc(z, 12'h323, 1'b1, 32'd160); expect32("mask 2: 160", m0.read(12'h323), 32'd0);
        m0.cyc(z, 12'h323, 1'b1, 32'd161); expect32("mask 2: 161", m0.read(12'h323), 32'd161);
        m0 = new(1, 48); m0.pres = 32'h1; m0.rst_cyc();
        m0.cyc(z, 12'h323, 1'b1, 32'd160); expect32("mask 1: 160", m0.read(12'h323), 32'd160);
        m0.cyc(z, 12'h323, 1'b1, 32'd161); expect32("mask 1: 161", m0.read(12'h323), 32'd0);
        m0 = new(1, 48); m0.pres = 32'h8000_1000; m0.rst_cyc();
        m0.cyc(z, 12'h323, 1'b1, 32'd140); expect32("mask bit 12: 140", m0.read(12'h323), 32'd140);
        m0.cyc(z, 12'h323, 1'b1, 32'd159); expect32("mask bit 31: 159", m0.read(12'h323), 32'd159);
        m0.cyc(z, 12'h323, 1'b1, 32'd141); expect32("mask bit 13 absent: 141", m0.read(12'h323), 32'd0);

        // ---- class A: select CYCLE (1) on counter 0; the selector takes effect one edge later.
        //      (From here an expectation is the state after the cycle, which a read in the next
        //      cycle sees.) ----
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        m.cyc(ONE(1), 12'h323, 1'b1, 32'd1);          // selector written; the old selector is 0
        expect32("A: the cycle of the selector write counts nothing", m.read(12'hB03), 32'd0);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("A: counted at the end of the cycle in which it is 1", m.read(12'hB03), 32'd1);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("A: after two counts", m.read(12'hB03), 32'd2);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("A: no event, no count", m.read(12'hB03), 32'd2);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("A: no event, no count (again)", m.read(12'hB03), 32'd2);

        // ---- class B1 counts at the end of the cycle in which it is 1; B2 one cycle, and a trap
        //      event two cycles, after that ----
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd47);              // counter 0: FETCH_DELIVER (B1)
        m.cyc(z, 12'h324, 1'b1, 32'd32);              // counter 1: FETCH_WAIT (B2)
        m.cyc(z, 12'h325, 1'b1, 32'd21);              // counter 2: EXCEPTION (trap)
        m.cyc(ONE(47) | ONE(32) | ONE(21), 12'h300, 1'b0, 32'd0);   // the pulse, cycle t
        expect32("t: B1 counted", m.read(12'hB03), 32'd1);
        expect32("t: B2 pipeline event not yet", m.read(12'hB04), 32'd0);
        expect32("t: trap event not yet", m.read(12'hB05), 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);               // cycle t + 1
        expect32("t+1: B1 stays", m.read(12'hB03), 32'd1);
        expect32("t+1: B2 pipeline event counted", m.read(12'hB04), 32'd1);
        expect32("t+1: trap event not yet", m.read(12'hB05), 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);               // cycle t + 2
        expect32("t+2: trap event counted", m.read(12'hB05), 32'd1);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("t+3: nothing more (B1)", m.read(12'hB03), 32'd1);
        expect32("t+3: nothing more (B2)", m.read(12'hB04), 32'd1);
        expect32("t+3: nothing more (trap)", m.read(12'hB05), 32'd1);

        // ---- the bits of an event vector that belong to another class do not act ----
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd21);              // a trap code
        m.cyc(z, 12'h324, 1'b1, 32'd32);              // a pipeline code
        m.cyc(ONE(21) | ONE(32), 12'h300, 1'b0, 32'd0);
        expect32("trap code is not counted at t", m.read(12'hB03), 32'd0);
        expect32("pipeline code is not counted at t", m.read(12'hB04), 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("trap code is not counted at t+1", m.read(12'hB03), 32'd0);
        expect32("pipeline code counted at t+1", m.read(12'hB04), 32'd1);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("trap code counted at t+2", m.read(12'hB03), 32'd1);
        expect32("pipeline code counted once", m.read(12'hB04), 32'd1);
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd1);               // class A code 1; bits 21-26 and 32-46 are garbage for it
        m.cyc(ONE(21) | ONE(26) | ONE(32) | ONE(46) | ONE(47) | ONE(128) | ONE(200), 12'h300, 1'b0, 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("class A code ignores other bits", m.read(12'hB03), 32'd0);

        // ---- write beats the increment; the next event counts on top of the written value ----
        m = new(7, 48); m.pres = 32'h0000_0FFF; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd1);
        for (int k = 0; k < 5; k++) m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("5 counts", m.read(12'hB03), 32'd5);
        m.cyc(ONE(1), 12'hB03, 1'b1, 32'd100);        // event and write in one cycle
        expect32("write beats the increment of the same cycle", m.read(12'hB03), 32'd100);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("event after the write", m.read(12'hB03), 32'd101);

        // ---- the half-write rule and the carry ----
        m.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFF);
        expect32("lo set", m.read(12'hB03), 32'hFFFF_FFFF);
        expect32("hi still 0", m.read(12'hB83), 32'h0);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);          // carry
        expect32("carry: lo", m.read(12'hB03), 32'h0);
        expect32("carry: hi", m.read(12'hB83), 32'h1);
        m.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFF);
        m.cyc(ONE(1), 12'hB03, 1'b1, 32'd7);          // low write in the carry cycle: carry kept in hi
        expect32("low write beside a carry: lo", m.read(12'hB03), 32'd7);
        expect32("low write beside a carry: hi", m.read(12'hB83), 32'd2);
        m.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFF);
        m.cyc(ONE(1), 12'hB83, 1'b1, 32'd5);          // high write in the carry cycle: lo keeps the step
        expect32("high write beside a carry: lo", m.read(12'hB03), 32'h0);
        expect32("high write beside a carry: hi", m.read(12'hB83), 32'd5);

        // ---- width: the high half is masked to W - 32 bits, and the counter wraps at 2^W ----
        m.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFF);
        expect32("W=48: high half mask", m.read(12'hB83), 32'h0000_FFFF);
        m.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFF);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("W=48: wrap lo", m.read(12'hB03), 32'h0);
        expect32("W=48: wrap hi", m.read(12'hB83), 32'h0);
        mw32 = new(7, 32); mw32.pres = 32'h0; mw32.rst_cyc();
        mw32.cyc(z, 12'h323, 1'b1, 32'd1);
        mw32.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFF);
        expect32("W=32: high write ignored", mw32.read(12'hB83), 32'h0);
        mw32.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFF);
        mw32.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("W=32: wrap", mw32.read(12'hB03), 32'h0);
        expect32("W=32: high reads 0", mw32.read(12'hB83), 32'h0);
        mw64 = new(7, 64); mw64.pres = 32'h0; mw64.rst_cyc();
        mw64.cyc(z, 12'h323, 1'b1, 32'd1);
        mw64.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFF);
        expect32("W=64: high write", mw64.read(12'hB83), 32'hFFFF_FFFF);
        mw64.cyc(z, 12'hB03, 1'b1, 32'hFFFF_FFFE);
        mw64.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("W=64: lo before the wrap", mw64.read(12'hB03), 32'hFFFF_FFFF);
        mw64.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("W=64: wrap lo", mw64.read(12'hB03), 32'h0);
        expect32("W=64: wrap hi", mw64.read(12'hB83), 32'h0);
        mw33 = new(1, 33); mw33.pres = 32'h0; mw33.rst_cyc();
        mw33.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFE);
        expect32("W=33: one high bit, 0xFFFFFFFE keeps bit 0", mw33.read(12'hB83), 32'h0);
        mw33.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFF);
        expect32("W=33: one high bit", mw33.read(12'hB83), 32'h1);
        mw40 = new(1, 40); mw40.pres = 32'h0; mw40.rst_cyc();
        mw40.cyc(z, 12'hB83, 1'b1, 32'hFFFF_FFFF);
        expect32("W=40: eight high bits", mw40.read(12'hB83), 32'h0000_00FF);

        // ---- inhibit stops exactly the counter whose bit is set, from the cycle after the write ----
        m = new(7, 48); m.pres = 32'h0; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd1);               // counter 0 (bit 3)
        m.cyc(z, 12'h324, 1'b1, 32'd1);               // counter 1 (bit 4)
        for (int k = 0; k < 3; k++) m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        m.cyc(ONE(1), 12'h320, 1'b1, 32'h0000_0008);  // the write cycle still counts
        for (int k = 0; k < 2; k++) m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("inhibit: counter 0 frozen at 4", m.read(12'hB03), 32'd4);
        expect32("inhibit: counter 1 goes on", m.read(12'hB04), 32'd6);
        m.cyc(ONE(1), 12'h320, 1'b1, 32'd0);          // released: counts from the next cycle
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        expect32("inhibit released: counter 0 at 5", m.read(12'hB03), 32'd5);
        m.cyc(ONE(1), 12'h320, 1'b1, 32'h0000_0010);
        m.cyc(ONE(1), 12'h320, 1'b1, 32'h0000_0000);
        expect32("inhibit set for one cycle: the write cycle counts, the next does not", m.read(12'hB04), 32'd9);

        // ---- a selector written beside an event that is in a delay register ----
        m = new(7, 48); m.pres = 32'h0; m.rst_cyc();
        m.cyc(ONE(32), 12'h323, 1'b1, 32'd32);        // event and selector write in one cycle
        m.cyc(z, 12'h300, 1'b0, 32'd0);               // the event is counted under the new selector
        expect32("selector then delayed event: counted", m.read(12'hB03), 32'd1);
        m = new(7, 48); m.pres = 32'h0; m.rst_cyc();
        m.cyc(ONE(32), 12'h300, 1'b0, 32'd0);
        m.cyc(z, 12'h323, 1'b1, 32'd32);              // one cycle too late: the event is gone
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("selector one cycle late: not counted", m.read(12'hB03), 32'd0);
        m = new(7, 48); m.pres = 32'h0; m.rst_cyc();
        m.cyc(ONE(21), 12'h300, 1'b0, 32'd0);         // trap pulse in cycle t
        m.cyc(z, 12'h323, 1'b1, 32'd21);              // selector written in t+1, effective t+2
        m.cyc(z, 12'h300, 1'b0, 32'd0);               // t+2: counted under the new selector
        expect32("trap in flight when the selector is written", m.read(12'hB03), 32'd1);

        // ---- reset ----
        m = new(7, 48); m.pres = 32'h0; m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd1);
        m.cyc(ONE(1), 12'h320, 1'b1, 32'h8);
        m.cyc(ONE(1), 12'h300, 1'b0, 32'd0);
        m.rst_cyc();
        expect32("reset: selector", m.read(12'h323), 32'd0);
        expect32("reset: inhibit", m.read(12'h320), 32'd0);
        expect32("reset: counter", m.read(12'hB03), 32'd0);
        m.cyc(ONE(21), 12'h300, 1'b0, 32'd0);         // a trap pulse, then the reset
        m.rst_cyc();
        m.cyc(z, 12'h323, 1'b1, 32'd21);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        m.cyc(z, 12'h300, 1'b0, 32'd0);
        expect32("a trap pulse before a reset is not counted after it", m.read(12'hB03), 32'd0);

        // ---- counters above N: read 0, writes ignored ----
        m3 = new(3, 48); m3.pres = 32'h0; m3.rst_cyc();
        m3.cyc(z, 12'hB06, 1'b1, 32'd5);
        expect32("N=3: counter 3 (0xB06) reads 0", m3.read(12'hB06), 32'd0);
        m3.cyc(z, 12'h326, 1'b1, 32'd1);
        expect32("N=3: selector 3 (0x326) reads 0", m3.read(12'h326), 32'd0);
        m3.cyc(z, 12'hB86, 1'b1, 32'd5);
        expect32("N=3: counter 3 high reads 0", m3.read(12'hB86), 32'd0);
        m3.cyc(z, 12'h325, 1'b1, 32'd1);
        expect32("N=3: selector 2 exists", m3.read(12'h325), 32'd1);
        m1 = new(0, 48); m1.pres = 32'h0; m1.rst_cyc();
        m1.cyc(z, 12'h323, 1'b1, 32'd1);
        expect32("N=0: selector 0 reads 0", m1.read(12'h323), 32'd0);
        expect32("N=0: constants stay", m1.read(12'h32C), 32'd19);

        $display("HPM MODEL SELF-TEST: PASS (%0d hand-computed checks)", st_checks);
    endtask

    // ---- the run ----
    longint unsigned total;
    int              ran;
    initial begin : main
        model_self_test();
        wait (&done || |bad);
        total = 0; ran = 0;
        for (int k = 0; k < NCFG; k++) begin total += cycles[k]; if (cycles[k] != 0) ran++; end
        if (|bad) begin
            $display("HPM BENCH: FAIL (a mismatch between the unit and the model, see above)");
            $fatal(1, "the counter-unit bench failed");
        end
        if (|covbad) begin
            $display("HPM BENCH: FAIL (coverage targets not met, see the configuration lines)");
            $fatal(1, "the counter-unit bench failed");
        end
        $display("HPM BENCH: PASS (%0d configurations, %0d cycles, 0 mismatches)", ran, total);
        $finish;
    end

    // a watchdog, in case the stimulus never ends
    initial begin : watchdog
        forever begin
            #(64'd1_000_000_000_000);
            $display("HPM BENCH: FAIL (watchdog: the run did not end)");
            $fatal(1, "the counter-unit bench failed");
        end
    end
endmodule
