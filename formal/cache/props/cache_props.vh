// SPDX-License-Identifier: MIT
// =============================================================================================
// cache_props.vh -- properties and covers of the I-cache and the memory arbiter.
//
// formal/cache/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of a harness (harness/cache_top.sv, icache_top.sv or arbiter_top.sv). sv2v puts
// the modules under proof inside that module (their interface ports make it inline them), so
// their internal names are visible here as icache.<name> and mem_arbiter.<name>; the harness
// gives the views f_v_*, the grants f_gd and f_gi as the arbiter's rules define them from its
// owner, the grants f_ag_d and f_ag_i that the design actually gives (its grant events; 0 in reset
// cycles), the stores answered at slave 0 (f_st_ans, f_st_adr) and the environment's signals. The words of the tag and data arrays are read
// through the wires <instance>.f_obs_words (observe_ram.vh.in).
// Nothing here drives a signal of the design: it declares observer state, assertions and covers.
//
// Harness macros (set by the .sby files): FH_ICACHE, the I-cache is in the model; FH_ARBITER,
// the arbiter is in the model; FH_FULL, both, connected as in the system. Each property is
// asserted only when its macro CHECK_<name> is set, so that a failing task names one property.
// In a harness with only one of the two modules a property checks that module's share (the
// decomposed harness of the fallback ladder). COVERS turns on the covers (full harness only).
//
// Every property is checked from the cycle after the first one (the first cycle is a reset from
// a free state). Unless a property says otherwise, it is also checked in later reset cycles: in
// a reset cycle the design's outputs follow the same rules, from the state before the reset.
//
// FSIM (with FORMAL): the same checks in the random simulation of the fallback ladder's last step
// (scripts/sim.sh, Verilator): they are sampled at the rising edge of clk, the arrays are read by
// hierarchical reference, and the tracked address and word get random first values.
// =============================================================================================
`ifdef FORMAL
`ifdef FSIM
`define F_AT @(posedge clk)
`else
`define F_AT @(*)
`endif

    wire f_check = !f_first;

`ifdef FSIM
    // the tracked address: mostly inside the window, sometimes a small address outside it, an
    // address with a high bit set or a random one; the tracked word: random
    initial begin
        case ($urandom % 8)
            0:       f_adr = $urandom;
            1:       f_adr = ($urandom % 48) | (32'd1 << (6 + $urandom % 26));
            2:       f_adr = $urandom % 48;
            default: f_adr = F_WINDOW_START + $urandom % F_WINDOW_WORDS;
        endcase
        f_word = $urandom;
    end
`endif

    localparam F_BOUND_DATA   = F_R + F_D;          // a data request is answered by this cycle
    localparam F_BOUND_GRANT  = F_KOLDER * F_D;     // a refill is granted by this cycle (CPU data)
    localparam F_BOUND_REFILL = F_R;                // a granted refill ends by this cycle

`ifdef FH_ICACHE
    // ---- the arrays, the tracked line and the tracked word's slot ----
`ifdef FSIM
    wire [32*F_SETS*F_LINE_WORDS-1:0] f_data_words = icache.data_ram.f_obs_words;
    wire [F_T*F_SETS-1:0]             f_tag_words  = icache.tag_ram.f_obs_words;
`else
    (* hierconn *) wire [32*F_SETS*F_LINE_WORDS-1:0] \icache.data_ram.f_obs_words ;
    (* hierconn *) wire [F_T*F_SETS-1:0]             \icache.tag_ram.f_obs_words ;
    wire [32*F_SETS*F_LINE_WORDS-1:0] f_data_words = \icache.data_ram.f_obs_words ;
    wire [F_T*F_SETS-1:0]             f_tag_words  = \icache.tag_ram.f_obs_words ;
`endif

    wire [F_I-1:0]     f_t_index = f_adr[F_O+F_I-1:F_O];
    wire [F_T-1:0]     f_t_tag   = f_adr[29:F_O+F_I];
    wire [F_I+F_O-1:0] f_t_slot  = f_adr[F_O+F_I-1:0];
    wire [31:0]        f_t_cached_word = f_data_words[32*f_t_slot +: 32];
    wire [F_T-1:0]     f_t_cached_tag  = f_tag_words[F_T*f_t_index +: F_T];
    // the line holding the tracked address is valid with that address's tag
    wire f_t_line_valid = f_adr[31:30] == 2'b00 && f_v_valid[f_t_index] && f_t_cached_tag == f_t_tag;

    // a store to the tracked address has been answered at slave 0 in an earlier cycle (from the
    // data side itself, f_st_*, not from the snoop connection under proof)
    reg f_stored;
    always @(posedge clk)
        f_stored <= !f_first && (f_stored || (f_st_ans && f_st_adr == f_adr));
`endif

    // ---- the refill block ----
    wire f_ireq     = refill.cyc && refill.stb;                 // the I-side requests
    wire f_last_ack = f_v_refill && refill.ack && f_v_last;     // a refill's last beat is answered
    // the current refill was granted in an earlier cycle and its last beat is not yet answered,
    // with no reset since
    reg f_blk;
    always @(posedge clk) f_blk <= !rst && f_v_refill && (f_blk || f_ag_i) && !f_last_ack;
    // from the refill's first grant through the cycle of its last beat
    wire f_in_blk = !rst && f_v_refill && (f_blk || f_ag_i);

    // ---- interval counters of the bounded response (an interval's first cycle is its cycle 1;
    //      a reset cycle abandons the interval) ----
    // a refill's wait for its first grant, from its first refill cycle
    reg  [7:0] f_iwait_q;
    wire [7:0] f_iwait = (!rst && f_v_refill && !f_blk) ? f_iwait_q + 8'd1 : 8'd0;
    // a granted refill, from its first granted cycle
    reg  [7:0] f_icnt_q;
    wire [7:0] f_icnt  = f_in_blk ? f_icnt_q + 8'd1 : 8'd0;
    always @(posedge clk) begin
        f_iwait_q <= f_ag_i ? 8'd0 : f_iwait;
        f_icnt_q  <= f_last_ack ? 8'd0 : f_icnt;
    end

    // ---- the I-side's request of the previous cycle, unanswered and without a reset ----
    reg        f_iq_open, f_iq_we, f_iq_cont;
    reg [3:0]  f_iq_sel;
    reg [31:0] f_iq_adr, f_iq_dat;
    always @(posedge clk) begin
        f_iq_open <= !rst && f_ireq && !refill.ack && !refill.err;
        f_iq_we   <= refill.we;
        f_iq_sel  <= refill.sel;
        f_iq_adr  <= refill.adr;
        f_iq_dat  <= refill.dat_mosi;
        f_iq_cont <= refill_cont;
    end

`ifdef FH_ARBITER
    // a data request, from the first cycle in which it is presented
    reg  [7:0] f_dwait_q;
    wire [7:0] f_dwait = (!rst && dbus.cyc && dbus.stb) ? (d_hold ? f_dwait_q + 8'd1 : 8'd1) : 8'd0;
    always @(posedge clk) f_dwait_q <= (dbus.ack || dbus.err) ? 8'd0 : f_dwait;

    // the previous cycle granted a data transfer that it did not answer (no reset)
    reg f_dg_open;
    always @(posedge clk) f_dg_open <= !rst && f_ag_d && !mbus.ack && !mbus.err;

    // answered data stores and answered memory writes; memory's tracked word after a store
    wire f_dstore_ans = dbus.cyc && dbus.stb && dbus.we && dbus.ack;
    wire f_mwrite_ans = mbus.cyc && mbus.stb && mbus.we && mbus.ack;
    reg        f_upd_check;
    reg [31:0] f_upd_word;
    always @(posedge clk) begin
        f_upd_check <= !f_first && f_dstore_ans && dbus.adr == f_adr;
        f_upd_word  <= f_merge(f_word, dbus.dat_mosi, dbus.sel);
    end
`endif

    // =========================================================================================
    // Properties
    // =========================================================================================

`ifdef CHECK_FETCH_DATA
    // A fetch ack delivers memory's word of the presented address as it was at the start of the
    // cycle (for the tracked address).
    always `F_AT if (f_check && fetch.ack && fetch.adr == f_adr) assert(fetch.dat_miso == f_word);
`endif

`ifdef CHECK_LINE_DATA
    // If the line holding the tracked address is valid with its tag, its cached word equals
    // memory's word.
    always `F_AT if (f_check && f_t_line_valid) assert(f_t_cached_word == f_word);
`endif

`ifdef CHECK_WINDOW
    // err exactly for requests outside the window; no ack outside the window.
    always `F_AT if (f_check) begin
        assert(fetch.err == (fetch.cyc && fetch.stb && !f_inwin(fetch.adr)));
        if (fetch.ack) assert(f_inwin(fetch.adr));
    end
`endif

`ifdef CHECK_ACK_ERR
    // Never ack and err together on any port.
    always `F_AT if (f_check) begin
`ifdef FH_ICACHE
        assert(!(fetch.ack && fetch.err));
`endif
`ifdef FH_ARBITER
        assert(!(dbus.ack && dbus.err));
        assert(!(refill.ack && refill.err));
`endif
    end
`endif

`ifdef CHECK_ANSWER_REQ
    // ack and err only with cyc and stb: the I-cache's CPU port and both slave sides of the
    // arbiter.
    always `F_AT if (f_check) begin
`ifdef FH_ICACHE
        if (fetch.ack || fetch.err) assert(fetch.cyc && fetch.stb);
`endif
`ifdef FH_ARBITER
        if (dbus.ack || dbus.err) assert(dbus.cyc && dbus.stb);
        if (refill.ack || refill.err) assert(refill.cyc && refill.stb);
`endif
    end
`endif

`ifdef CHECK_GRANT_ROUTE
    // At most one side granted; the memory port carries exactly the granted side's request (and
    // the continuation tag only for the I-side) and is all zeros when idle; answers go only to the
    // granted side, the other side sees ack = err = 0 and dat_miso = 0. The arbiter's grant events
    // are these grants (0 in reset cycles).
    always `F_AT if (f_check) begin
        assert(!(f_gd && f_gi));
        assert(e_grant_d == (f_gd && !rst));
        assert(e_grant_i == (f_gi && !rst));
        if (f_gd) begin
            assert(mbus.cyc == dbus.cyc && mbus.stb == dbus.stb && mbus.adr == dbus.adr &&
                   mbus.we == dbus.we && mbus.sel == dbus.sel && mbus.dat_mosi == dbus.dat_mosi);
        end else if (f_gi) begin
            assert(mbus.cyc == refill.cyc && mbus.stb == refill.stb && mbus.adr == refill.adr &&
                   mbus.we == refill.we && mbus.sel == refill.sel &&
                   mbus.dat_mosi == refill.dat_mosi);
        end else begin
            assert(!mbus.cyc && !mbus.stb && mbus.adr == 32'd0 && !mbus.we && mbus.sel == 4'd0 &&
                   mbus.dat_mosi == 32'd0);
        end
        assert(mbus_cont == (f_gi && refill_cont));
        assert(dbus.ack == (f_gd && mbus.ack));
        assert(dbus.err == (f_gd && mbus.err));
        assert(dbus.dat_miso == (f_gd ? mbus.dat_miso : 32'd0));
        assert(refill.ack == (f_gi && mbus.ack));
        assert(refill.err == (f_gi && mbus.err));
        assert(refill.dat_miso == (f_gi ? mbus.dat_miso : 32'd0));
    end
`endif

`ifdef CHECK_REFILL_NO_WRITE
    // No memory write from a refill's first grant through its last beat, unless a reset comes in
    // between.
    always `F_AT if (f_check && f_in_blk) assert(!(mbus.cyc && mbus.stb && mbus.we));
`endif

`ifdef CHECK_GRANT_KEPT
    // A granted refill keeps the grant in every cycle until its last beat; a granted data
    // transfer until its answer; unless a reset comes in between.
    always `F_AT if (f_check && !rst) begin
        if (f_blk && f_v_refill) assert(f_ag_i);
        if (f_dg_open) assert(f_ag_d);
    end
`endif

`ifdef CHECK_BOUND
    // Bounded response: a data request is answered by cycle F_R + F_D of its interval at the
    // latest; a granted refill's last beat is answered by cycle F_R of its first grant.
    always `F_AT if (f_check) begin
`ifdef FH_ARBITER
        assert(f_dwait <= F_BOUND_DATA);
        if (f_dwait == F_BOUND_DATA) assert(dbus.ack || dbus.err);
`endif
        assert(f_icnt <= F_BOUND_REFILL);
        if (f_icnt == F_BOUND_REFILL) assert(f_last_ack);
    end
`endif

`ifdef CHECK_BOUND_CPU
    // Bounded response with the data side of FCACHE_CPU_DATA: a refill is granted by cycle
    // F_KOLDER * F_D of its wait at the latest, counted from its first refill cycle.
    always `F_AT if (f_check) begin
        assert(f_iwait <= F_BOUND_GRANT);
        if (f_iwait == F_BOUND_GRANT) assert(f_ag_i);
    end
`endif

`ifdef CHECK_RESET_STATE
    // In the cycle after a reset cycle: no valid bit set, the I-cache in LOOKUP with beat 0, its
    // refill request idle, and the arbiter's owner NONE (the data side may request).
    always `F_AT if (f_check && f_past_rst) begin
`ifdef FH_ICACHE
        assert(f_v_valid == '0);
        assert(f_v_lookup);
        assert(f_v_beat0);
        assert(!refill.cyc && !refill.stb && !refill_cont);
`endif
`ifdef FH_ARBITER
        assert(f_v_own_none);
`endif
    end
`endif

`ifdef CHECK_STORE_FETCH
    // After a store to the tracked address is answered, no later fetch ack of that address returns
    // any value other than memory's.
    always `F_AT if (f_check && f_stored && fetch.ack && fetch.adr == f_adr)
        assert(fetch.dat_miso == f_word);
`endif

`ifdef CHECK_REFILL_WINDOW
    // Every refill beat address lies inside the window.
    always `F_AT if (f_check && f_ireq) assert(f_inwin(refill.adr));
`endif

`ifdef CHECK_REFILL_STABLE
    // The I-cache's memory-side request does not change until it is answered, unless a reset
    // comes in between.
    always `F_AT if (f_check && !rst && f_iq_open)
        assert(f_ireq && refill.adr == f_iq_adr && refill.we == f_iq_we && refill.sel == f_iq_sel &&
               refill.dat_mosi == f_iq_dat && refill_cont == f_iq_cont);
`endif

`ifdef CHECK_STORE_ONCE
    // A data store answered on the data side has updated memory at that edge, and exactly one
    // memory write is answered per answered data store: in the same cycle, with the store's
    // address, sel and data.
    always `F_AT if (f_check) begin
        assert(f_mwrite_ans == f_dstore_ans);
        if (f_dstore_ans)
            assert(mbus.adr == dbus.adr && mbus.sel == dbus.sel && mbus.dat_mosi == dbus.dat_mosi);
        if (f_upd_check) assert(f_word == f_upd_word);
    end
`endif

`ifdef INDUCTION
    // =========================================================================================
    // Helper invariants for the k-induction attempt on the I-cache alone (harness/icache_top.sv):
    // asserted, and so proved, together with the properties they support.
    // =========================================================================================
    wire [F_I-1:0] f_r_index = f_v_refill_line[F_I-1:0];
    wire [31:0]    f_r_first = {2'b00, f_v_refill_line, {F_O{1'b0}}};
    always `F_AT if (f_check) begin
        // exactly one of the two states; beat 0 outside a refill
        assert(f_v_lookup != f_v_refill);
        if (f_v_lookup) assert(f_v_beat0);
        if (f_v_refill) begin
            // the line being refilled lies in the window, and its set's valid bit is clear
            assert(f_inwin(f_r_first));
            assert(!f_v_valid[f_r_index]);
            // after its first beat the refill holds the port, so no store can come in between
            if (!f_v_beat0) assert(f_v_port_held);
        end
        // the words of the tracked line that the current refill has already written are memory's
        if (f_v_refill && f_adr[31:30] == 2'b00 && f_v_refill_line == f_adr[29:F_O] &&
            f_v_beat > f_adr[F_O-1:0])
            assert(f_t_cached_word == f_word);
    end
    // every valid line holds the tag of a line inside the window
    genvar f_h;
    generate
        for (f_h = 0; f_h < F_SETS; f_h = f_h + 1) begin : f_valid_tag
            wire [F_I-1:0] f_h_index = f_h;
            always `F_AT if (f_check && f_v_valid[f_h])
                assert(f_inwin({2'b00, f_tag_words[F_T*f_h +: F_T], f_h_index, {F_O{1'b0}}}));
        end
    endgenerate
`endif

    // =========================================================================================
    // Covers (full harness): each must be reached
    // =========================================================================================
`ifdef COVERS
`ifdef FH_FULL
    wire [F_I-1:0] f_fill_index = f_v_refill_line[F_I-1:0];
    wire [F_I-1:0] f_snoop_index = f_snoop_adr[F_O+F_I-1:F_O];
    reg [F_SETS-1:0] f_c_filled;            // sets filled since the last reset
    reg              f_c_after_fill;        // the previous cycle answered a refill's last beat
    reg              f_c_prev_refill_req;   // the previous cycle was a refill cycle with a fetch
    reg [31:0]       f_c_prev_fetch_adr;
    always @(posedge clk) begin
        f_c_filled          <= rst ? {F_SETS{1'b0}}
                                   : (f_c_filled | (f_last_ack ? (1 << f_fill_index) : 0));
        f_c_after_fill      <= !rst && f_last_ack;
        f_c_prev_refill_req <= !rst && f_v_refill && fetch.cyc && fetch.stb;
        f_c_prev_fetch_adr  <= fetch.adr;
    end
    always `F_AT if (f_check && !rst) begin
        // a refill completes; a second refill completes in the other set
        cover(f_last_ack);
        cover(&f_c_filled);
        // a snoop invalidates a valid line
        cover(f_snoop_store && f_snoop_adr[31:30] == 2'b00 && f_v_valid[f_snoop_index] &&
              f_tag_words[F_T*f_snoop_index +: F_T] == f_snoop_adr[29:F_O+F_I]);
        // a redirect during a refill
        cover(f_v_refill && f_c_prev_refill_req && fetch.cyc && fetch.stb &&
              fetch.adr != f_c_prev_fetch_adr);
        // a data request waits behind a refill
        cover(dbus.cyc && dbus.stb && !f_gd && f_gi);
        // a data side with cyc and without stb during a refill beat
        cover(dbus.cyc && !dbus.stb && f_gi && refill.ack);
        // a data transfer granted and answered in the second-lookup cycle
        cover(f_c_after_fill && f_gd && dbus.ack);
        // a hit in the cycle after a fill
        cover(f_c_after_fill && fetch.ack);
        // a store in the second-lookup cycle to the line just filled
        cover(f_c_after_fill && f_st_ans && f_st_adr[29:F_O] == f_v_refill_line);
        // a hit while the data side holds the port
        cover(fetch.ack && f_v_own_data);
        // an err during a refill
        cover(fetch.err && f_v_refill);
        // the triggers of the properties
        cover(fetch.ack && fetch.adr == f_adr);                     // tracked word fetched
        cover(f_t_line_valid);                                      // tracked line valid
        cover(f_stored && fetch.ack && fetch.adr == f_adr);         // ... after a store to it
        cover(f_in_blk && dbus.cyc && dbus.stb && dbus.we);         // a store waits for a refill
        cover(f_dwait == F_BOUND_DATA - 1 && dbus.ack);             // the longest data wait
        cover(f_icnt == F_BOUND_REFILL && f_last_ack);              // the longest refill
        cover(f_iq_open && f_ireq);                                 // a refill beat waits
        cover(f_dstore_ans && dbus.adr == f_adr);                   // a store to the tracked word
        cover(f_ireq && !f_gi);                                     // a refill waits for the port
    end
    // resets: during a refill, and while it requests its last beat
    always `F_AT if (f_check && rst) begin
        cover(f_v_refill);
        cover(f_v_refill && f_v_last && f_ireq);
    end
    // with the CPU-like data side: F_KOLDER back-to-back data transfers of F_D cycles between a
    // miss and its refill's first grant, the first granted in the miss cycle; the refill is granted
    // in the last cycle that the bound allows
    generate if (F_CPU_DATA) begin : f_cover_cpu
        always `F_AT if (f_check && !rst) cover(f_iwait == F_BOUND_GRANT && f_ag_i);
    end endgenerate
`endif
`endif

`endif
