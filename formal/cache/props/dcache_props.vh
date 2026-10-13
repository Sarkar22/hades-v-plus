// SPDX-License-Identifier: MIT
// =============================================================================================
// dcache_props.vh -- properties, covers and induction helpers of the memory system with both
// caches: the D-cache, the I-cache with the D-cache's stores, the arbiter with D-refill blocks,
// and the tiny memory (formal/cache/README.md, section 10).
//
// formal/cache/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of a harness: harness/memsys_top.sv (both caches, the arbiter and the memory),
// dcache_top.sv (the D-cache alone) or arbiter_id_top.sv (the arbiter alone). sv2v puts the
// modules under proof inside that module, so their internal names are visible here as
// icache.<name>, dcache.<name> and mem_arbiter.<name>; the harness gives the views f_v_* (the
// I-cache), f_vd_* (the D-cache), the arbiter's owner, the grants f_gd and f_gi as the arbiter's
// rules define them, the grants f_ag_d and f_ag_i that the design gives (its grant events, 0 in
// reset cycles; the abstract port's grant in dcache_top.sv), and the environment's signals. The
// tag array and the four data lanes of the D-cache are read through the wires
// dcache.tag_ram.f_obs_words and dcache.lane[k].data_ram.f_obs_words (observe_ram.vh.in).
// Nothing here drives a signal of the design.
//
// Harness macros (set by the .sby files): FH_DCACHE, the D-cache is in the model; FH_ICACHE, the
// I-cache is; FH_ARBITER, the arbiter is; FH_FULL, all three connected as in the system. Each
// property is asserted only when its macro CHECK_<NAME> is set, so that a failing task names one
// property. In a harness with only some of the modules a property checks their share (the
// decomposed harness of the fallback ladder). COVERS turns on the covers (full harness only);
// INDUCTION the helper invariants of the k-induction attempt (the D-cache alone).
//
// Every property is checked from the cycle after the first one (the first cycle is a reset from
// a free state). Unless a property says otherwise, it is also checked in later reset cycles, in
// which the design's outputs follow the same rules, from the state before the reset.
//
// FSIM (with FORMAL): the same checks in the random simulation of the fallback ladder's last step
// (scripts/sim.sh, Verilator): sampled at the rising edge of clk, the arrays read by hierarchical
// reference, random first values of the tracked address and word.
// =============================================================================================
`ifdef FORMAL
`ifdef FSIM
`define F_AT @(posedge clk)
`else
`define F_AT @(*)
`endif

    wire f_check = !f_first;

`ifdef FSIM
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

    // the tracked address's set, tag and slot (both caches have the same sizes)
    wire [F_I-1:0]     f_t_index = f_adr[F_O+F_I-1:F_O];
    wire [F_T-1:0]     f_t_tag   = f_adr[29:F_O+F_I];
    wire [F_I+F_O-1:0] f_t_slot  = f_adr[F_O+F_I-1:0];

    // =========================================================================================
    // The D-cache side: requests, answers and the D-refill block
    // =========================================================================================
    wire f_dreq      = dmem.cyc && dmem.stb;                         // the D-cache requests
    wire f_dmw_ans   = dmem.cyc && dmem.stb && dmem.we && dmem.ack;  // a write answered there
    wire f_dlast_ack = f_vd_refill && dmem.ack && f_vd_last;         // a D-refill's last beat answered
    // the current D-refill was granted in an earlier cycle and its last beat is not yet answered,
    // with no reset since
    reg f_dblk;
    always @(posedge clk) f_dblk <= !rst && f_vd_refill && (f_dblk || f_ag_d) && !f_dlast_ack;
    // from the D-refill's first grant through the cycle of its last beat
    wire f_din_blk = !rst && f_vd_refill && (f_dblk || f_ag_d);
    // a D-refill's wait for its first grant, from its first refill cycle (bound (e)); a granted
    // D-refill, from its first granted cycle (bound (f))
    reg  [7:0] f_dgw_q, f_dcnt_q;
    wire [7:0] f_dgw  = (!rst && f_vd_refill && !f_dblk) ? f_dgw_q + 8'd1 : 8'd0;
    wire [7:0] f_dcnt = f_din_blk ? f_dcnt_q + 8'd1 : 8'd0;
    always @(posedge clk) begin
        f_dgw_q  <= f_ag_d ? 8'd0 : f_dgw;
        f_dcnt_q <= f_dlast_ack ? 8'd0 : f_dcnt;
    end

`ifdef FH_DCACHE
    // ---- the CPU port ----
    wire f_dst_ack = dcpu.cyc && dcpu.stb && dcpu.we && dcpu.ack;    // a store acknowledged
    wire f_dld_ack = dcpu.cyc && dcpu.stb && !dcpu.we && dcpu.ack;   // a load acknowledged

    // ---- the arrays: the tag array and the four 8-bit lanes ----
    localparam int unsigned F_DW = 8 * F_SETS * F_LINE_WORDS;        // bits of one lane's array
`ifdef FSIM
    wire [F_DW-1:0]       f_dl0 = dcache.lane[0].data_ram.f_obs_words;
    wire [F_DW-1:0]       f_dl1 = dcache.lane[1].data_ram.f_obs_words;
    wire [F_DW-1:0]       f_dl2 = dcache.lane[2].data_ram.f_obs_words;
    wire [F_DW-1:0]       f_dl3 = dcache.lane[3].data_ram.f_obs_words;
    wire [F_T*F_SETS-1:0] f_dtag_words = dcache.tag_ram.f_obs_words;
`else
    (* hierconn *) wire [F_DW-1:0]       \dcache.lane[0].data_ram.f_obs_words ;
    (* hierconn *) wire [F_DW-1:0]       \dcache.lane[1].data_ram.f_obs_words ;
    (* hierconn *) wire [F_DW-1:0]       \dcache.lane[2].data_ram.f_obs_words ;
    (* hierconn *) wire [F_DW-1:0]       \dcache.lane[3].data_ram.f_obs_words ;
    (* hierconn *) wire [F_T*F_SETS-1:0] \dcache.tag_ram.f_obs_words ;
    wire [F_DW-1:0]       f_dl0 = \dcache.lane[0].data_ram.f_obs_words ;
    wire [F_DW-1:0]       f_dl1 = \dcache.lane[1].data_ram.f_obs_words ;
    wire [F_DW-1:0]       f_dl2 = \dcache.lane[2].data_ram.f_obs_words ;
    wire [F_DW-1:0]       f_dl3 = \dcache.lane[3].data_ram.f_obs_words ;
    wire [F_T*F_SETS-1:0] f_dtag_words = \dcache.tag_ram.f_obs_words ;
`endif
    // the tracked address's word in the lanes, lane k = bits [8k+7:8k]; its set's tag
    wire [7:0]     f_td_lane0 = f_dl0[8*f_t_slot +: 8];
    wire [7:0]     f_td_lane1 = f_dl1[8*f_t_slot +: 8];
    wire [7:0]     f_td_lane2 = f_dl2[8*f_t_slot +: 8];
    wire [7:0]     f_td_lane3 = f_dl3[8*f_t_slot +: 8];
    wire [31:0]    f_td_cached_word = {f_td_lane3, f_td_lane2, f_td_lane1, f_td_lane0};
    wire [F_T-1:0] f_td_cached_tag  = f_dtag_words[F_T*f_t_index +: F_T];
    // the D-line holding the tracked address is valid with that address's tag
    wire f_td_line_valid = f_adr[31:30] == 2'b00 && f_vd_valid[f_t_index] &&
                           f_td_cached_tag == f_t_tag;

    // ---- the memory-side request of the previous cycle, and the CPU's ----
    reg        f_dq_open, f_dq_refill, f_dq_we, f_dq_cont;
    reg [3:0]  f_dq_sel;
    reg [31:0] f_dq_adr, f_dq_dat;
    reg        f_cq_req, f_cq_we;
    reg [3:0]  f_cq_sel;
    reg [31:0] f_cq_adr, f_cq_dat;
    always @(posedge clk) begin
        f_dq_open   <= !rst && f_dreq && !dmem.ack && !dmem.err;
        f_dq_refill <= f_vd_refill;
        f_dq_we     <= dmem.we;
        f_dq_sel    <= dmem.sel;
        f_dq_adr    <= dmem.adr;
        f_dq_dat    <= dmem.dat_mosi;
        f_dq_cont   <= dmem_cont;
        f_cq_req    <= dcpu.cyc && dcpu.stb;
        f_cq_we     <= dcpu.we;
        f_cq_sel    <= dcpu.sel;
        f_cq_adr    <= dcpu.adr;
        f_cq_dat    <= dcpu.dat_mosi;
    end
    // the CPU presents the same request as in the previous cycle
    wire f_cpu_same = dcpu.cyc && dcpu.stb && f_cq_req && dcpu.adr == f_cq_adr &&
                      dcpu.we == f_cq_we && dcpu.sel == f_cq_sel && dcpu.dat_mosi == f_cq_dat;

    // memory's tracked word after a store acknowledged at the tracked address
    reg        f_upd_check;
    reg [31:0] f_upd_word;
    always @(posedge clk) begin
        f_upd_check <= !f_first && f_dst_ack && dcpu.adr == f_adr;
        f_upd_word  <= f_merge(f_word, dcpu.dat_mosi, dcpu.sel);
    end
`endif

`ifdef FH_ARBITER
    // =========================================================================================
    // The I-refill block and the memory port
    // =========================================================================================
    wire f_ireq     = refill.cyc && refill.stb;
    wire f_last_ack = f_v_refill && refill.ack && f_v_last;     // an I-refill's last beat answered
    reg f_blk;
    always @(posedge clk) f_blk <= !rst && f_v_refill && (f_blk || f_ag_i) && !f_last_ack;
    wire f_in_blk = !rst && f_v_refill && (f_blk || f_ag_i);
    // an I-refill's wait for its first grant (bound (b)); a granted I-refill (bound (c))
    reg  [7:0] f_iwait_q, f_icnt_q;
    wire [7:0] f_iwait = (!rst && f_v_refill && !f_blk) ? f_iwait_q + 8'd1 : 8'd0;
    wire [7:0] f_icnt  = f_in_blk ? f_icnt_q + 8'd1 : 8'd0;
    always @(posedge clk) begin
        f_iwait_q <= f_ag_i ? 8'd0 : f_iwait;
        f_icnt_q  <= f_last_ack ? 8'd0 : f_icnt;
    end
    wire f_mw_ans = mbus.cyc && mbus.stb && mbus.we && mbus.ack;   // a memory write answered
`endif

`ifdef FH_FULL
    // a request at the D-cache's CPU port, from the first cycle in which it is presented (bound (a))
    reg  [7:0] f_dwait_q;
    wire [7:0] f_dwait = (!rst && dcpu.cyc && dcpu.stb) ? (d_hold ? f_dwait_q + 8'd1 : 8'd1) : 8'd0;
    always @(posedge clk) f_dwait_q <= (dcpu.ack || dcpu.err) ? 8'd0 : f_dwait;
    // a store to the tracked address has been acknowledged at slave 0 in an earlier cycle
    reg f_stored;
    always @(posedge clk) f_stored <= !f_first && (f_stored || (f_st_ans && f_st_adr == f_adr));
`endif

    // =========================================================================================
    // Properties
    // =========================================================================================

`ifdef CHECK_LOAD_DATA
`ifdef FH_DCACHE
    // A load ack delivers memory's word of the presented address as at the start of the cycle
    // (the last value written there), for the tracked address.
    always `F_AT if (f_check && f_dld_ack && dcpu.adr == f_adr) assert(dcpu.dat_miso == f_word);
    // Its lemma, asserted with it (so proved as well, never assumed): the D-line invariant of
    // dline_data. Bounded model checking assumes the assertions of the earlier steps when it
    // checks a step, so the lemma spares the solver the history of the line; without it the
    // first engine did not reach depth 20 in 10 minutes on the trial model.
    always `F_AT if (f_check && f_td_line_valid) assert(f_td_cached_word == f_word);
`endif
`endif

`ifdef CHECK_DLINE_DATA
`ifdef FH_DCACHE
    // A valid D-line holding the tracked address (valid with its tag) equals memory, lane by lane.
    always `F_AT if (f_check && f_td_line_valid) begin
        assert(f_td_lane0 == f_word[7:0]);
        assert(f_td_lane1 == f_word[15:8]);
        assert(f_td_lane2 == f_word[23:16]);
        assert(f_td_lane3 == f_word[31:24]);
    end
`endif
`endif

`ifdef CHECK_STORE_MEM
    // At each store-accept edge memory holds the store's sel lanes; one memory write per
    // acknowledged store, with its address, sel and data; no other write. Shares: the D-cache (its
    // store ack is st_accept and comes exactly with its memory write's answer, which carries the
    // store unchanged), the arbiter (exactly one memory write per answered data-side write, the
    // same transfer).
    always `F_AT if (f_check) begin
`ifdef FH_DCACHE
        assert(f_vd_st_accept == f_dst_ack);
        assert(f_dmw_ans == f_dst_ack);
        if (f_dst_ack)
            assert(dmem.adr == dcpu.adr && dmem.sel == dcpu.sel && dmem.dat_mosi == dcpu.dat_mosi);
        if (f_upd_check) assert(f_word == f_upd_word);
`endif
`ifdef FH_ARBITER
        assert(f_mw_ans == f_dmw_ans);
        if (f_dmw_ans)
            assert(mbus.adr == dmem.adr && mbus.sel == dmem.sel && mbus.dat_mosi == dmem.dat_mosi);
`endif
    end
`endif

`ifdef CHECK_ID_REFILL_NO_WRITE
`ifdef FH_ARBITER
    // No memory write from an I-refill's first grant through its last beat, unless a reset comes
    // in between, with the D-cache's stores and D-refills on the data side.
    always `F_AT if (f_check && f_in_blk) assert(!(mbus.cyc && mbus.stb && mbus.we));
`endif
`endif

`ifdef CHECK_DFILL_KEPT
    // A granted D-refill keeps the port to its last beat. Shares: the D-cache requests in every
    // cycle of a refill (a read) and tags beats 1.. as continuing (mem_cont exactly then); the
    // arbiter grants a continuing data beat, keeps a granted D-refill block, and passes the tags
    // to the memory port (mem_cont = gi && irefill_cont || gd && data_cont).
    always `F_AT if (f_check) begin
`ifdef FH_DCACHE
        if (!rst && f_vd_refill) assert(f_dreq && !dmem.we);
        if (!rst) assert(dmem_cont == (f_vd_refill && !f_vd_beat0));
`endif
`ifdef FH_ARBITER
        if (!rst && f_dblk && f_vd_refill) assert(f_ag_d);
        if (!rst && dmem_cont && f_d_req) assert(f_ag_d);
        assert(mbus_cont == ((f_gi && refill_cont) || (f_gd && dmem_cont)));
`endif
    end
`endif

`ifdef CHECK_DBOUND
`ifdef FH_FULL
    // Bounded response: (a) a request at the D-cache's CPU port is answered by cycle F_N_A of its
    // interval; (c) a granted I-refill's last beat by cycle F_R of its grant; (e) a D-refill is
    // granted by cycle F_R of its refill; (f) a granted D-refill's last beat by cycle F_R of its
    // grant. An interval's first cycle is its cycle 1; a reset cycle abandons it.
    always `F_AT if (f_check) begin
        assert(f_dwait <= F_N_A);
        if (f_dwait == F_N_A) assert(dcpu.ack || dcpu.err);
        assert(f_icnt <= F_R);
        if (f_icnt == F_R) assert(f_last_ack);
        assert(f_dgw <= F_R);
        if (f_dgw == F_R) assert(f_ag_d);
        assert(f_dcnt <= F_R);
        if (f_dcnt == F_R) assert(f_dlast_ack);
    end
`endif
`endif

`ifdef CHECK_DBOUND_CPU
`ifdef FH_FULL
    // Bound (b), with the CPU-like data side (FCACHE_CPU_DATA): an I-refill is granted by cycle
    // F_N_B = max(K_OLDER * (WR + 1), R + 1) of its wait, counted from its first refill cycle.
    always `F_AT if (f_check) begin
        assert(f_iwait <= F_N_B);
        if (f_iwait == F_N_B) assert(f_ag_i);
    end
`endif
`endif

`ifdef CHECK_DACK_REQ
`ifdef FH_DCACHE
    // ack only with cyc && stb; never err; no ack in REFILL.
    always `F_AT if (f_check) begin
        if (dcpu.ack || dcpu.err) assert(dcpu.cyc && dcpu.stb);
        assert(!dcpu.err);
        if (f_vd_refill) assert(!dcpu.ack);
    end
`endif
`endif

`ifdef CHECK_DWINDOW
`ifdef FH_DCACHE
    // Every memory-side request of the D-cache (refill beats and stores) lies inside the window.
    always `F_AT if (f_check && f_dreq) assert(f_inwin(dmem.adr));
`endif
`endif

`ifdef CHECK_DREFILL_STABLE
`ifdef FH_DCACHE
    // The D-cache's memory-side request does not change until it is answered, unless a reset
    // comes in between: a refill beat's in any case, a store's while the CPU holds the store
    // (address, we, sel, write data, continuation tag).
    always `F_AT if (f_check && !rst && f_dq_open && (f_dq_refill || f_cpu_same))
        assert(f_dreq && dmem.adr == f_dq_adr && dmem.we == f_dq_we && dmem.sel == f_dq_sel &&
               dmem.dat_mosi == f_dq_dat && dmem_cont == f_dq_cont);
`endif
`endif

`ifdef CHECK_DRESET_STATE
`ifdef FH_DCACHE
    // In the cycle after a reset cycle: no D valid bit set, the D-cache in LOOKUP with beat 0; the
    // state register is two bits wide.
    always `F_AT if (f_check && f_past_rst) begin
        assert(f_vd_valid == '0);
        assert(f_vd_lookup);
        assert(f_vd_beat0);
        assert(f_vd_state_bits == 32'd2);
    end
`endif
`endif

`ifdef CHECK_ID_FETCH_DATA
`ifdef FH_ICACHE
    // A fetch ack delivers memory's word of the presented address as it was at the start of the
    // cycle (for the tracked address), with the D-cache's stores writing memory.
    always `F_AT if (f_check && fetch.ack && fetch.adr == f_adr) assert(fetch.dat_miso == f_word);
`endif
`endif

`ifdef CHECK_ID_STORE_FETCH
`ifdef FH_FULL
    // After a store to the tracked address is acknowledged at slave 0 (by the D-cache), no later
    // fetch ack of that address returns any value other than memory's.
    always `F_AT if (f_check && f_stored && fetch.ack && fetch.adr == f_adr)
        assert(fetch.dat_miso == f_word);
`endif
`endif

`ifdef INDUCTION
`ifdef FH_DCACHE
    // =========================================================================================
    // Helper invariants for the k-induction attempt on the D-cache alone (harness/dcache_top.sv):
    // asserted, and so proved, together with the property they support.
    // =========================================================================================
    wire [F_I-1:0] f_dr_index = f_vd_refill_line[F_I-1:0];
    wire [31:0]    f_dr_first = {2'b00, f_vd_refill_line, {F_O{1'b0}}};
    always `F_AT if (f_check) begin
        // exactly one of the two named states; beat 0 outside a refill
        assert(f_vd_lookup != f_vd_refill);
        if (f_vd_lookup) assert(f_vd_beat0);
        if (f_vd_refill) begin
            // the line being refilled lies in the window, and its set's valid bit is clear
            assert(f_inwin(f_dr_first));
            assert(!f_vd_valid[f_dr_index]);
        end
        // the words of the tracked line that the current refill has already written are memory's
        if (f_vd_refill && f_adr[31:30] == 2'b00 && f_vd_refill_line == f_adr[29:F_O] &&
            f_vd_beat > f_adr[F_O-1:0])
            assert(f_td_cached_word == f_word);
        // the D-line invariant itself (dline_data)
        if (f_td_line_valid) assert(f_td_cached_word == f_word);
        // the CPU's held request lies in the window (as every request the environment starts)
        if (d_q_open) assert(f_inwin(d_q_adr));
    end
    // every valid D-line holds the tag of a line inside the window
    genvar f_h;
    generate
        for (f_h = 0; f_h < F_SETS; f_h = f_h + 1) begin : f_dvalid_tag
            wire [F_I-1:0] f_h_index = f_h;
            always `F_AT if (f_check && f_vd_valid[f_h])
                assert(f_inwin({2'b00, f_dtag_words[F_T*f_h +: F_T], f_h_index, {F_O{1'b0}}}));
        end
    endgenerate
`endif
`endif

    // =========================================================================================
    // Covers (full harness): each must be reached
    // =========================================================================================
`ifdef COVERS
`ifdef FH_FULL
    // a load missed while an I-refill held the port (second configuration's sequence)
    reg            f_c_mb, f_c_mb_answered;
    reg [29-F_O:0] f_c_mb_line;
    // the current I-refill started in a cycle in which the load presented to the D-cache missed
    // too (both caches missed in that cycle)
    reg            f_c_coinc;
    always @(posedge clk) begin
        if (rst) begin
            f_c_mb          <= 1'b0;
            f_c_mb_answered <= 1'b0;
        end else if (ed_load_miss && f_in_blk) begin
            f_c_mb          <= 1'b1;
            f_c_mb_answered <= 1'b0;
            f_c_mb_line     <= dcpu.adr[29:F_O];
        end else if (f_c_mb && ed_lookup_hit && dcpu.adr[29:F_O] == f_c_mb_line) begin
            f_c_mb_answered <= 1'b1;
        end
        f_c_coinc <= !rst && (e_miss ? ed_load_miss : (f_c_coinc && f_v_refill));
    end
    generate if (!F_CPU_DATA) begin : f_cover_generic
        always `F_AT if (f_check && !rst) begin
            // a D-refill completes; a store hit and a store miss
            cover(ed_fill);
            cover(ed_store_hit);
            cover(ed_store_miss);
            // a load hit during an I-refill (the I-refill holds the port)
            cover(f_dld_ack && f_in_blk);
            // both refills start in one cycle (both caches miss in the same cycle)
            cover(e_miss && ed_load_miss);
            // an I-miss during a D-refill
            cover(e_miss && f_vd_refill);
            // bound (a) reached exactly by a load
            cover(f_dwait == F_N_A && f_dld_ack);
            // the triggers of the properties
            cover(f_dld_ack && dcpu.adr == f_adr);                        // tracked word loaded
            cover(f_td_line_valid);                                       // tracked D-line valid
            cover(f_dst_ack && dcpu.adr == f_adr);                        // store to the tracked word
            cover(f_dst_ack && f_vd_present);                             // a store hit acknowledged
            cover(f_in_blk && dcpu.cyc && dcpu.stb && dcpu.we && !dcpu.ack);  // a store waits for an I-refill
            cover(f_dblk && f_ag_d && dmem_cont);                         // a granted D-refill continues
            cover(f_dgw == F_R && f_ag_d);                                // bound (e) reached exactly
            cover(f_dcnt == F_R && f_dlast_ack);                          // bound (f) reached exactly
            cover(f_icnt == F_R && f_last_ack);                           // bound (c) reached exactly
            cover(f_dq_open && f_dreq);                                   // a D request waits
            cover(f_stored && fetch.ack && fetch.adr == f_adr);           // a fetch after a store to it
            cover(fetch.ack && fetch.adr == f_adr);                       // tracked word fetched
        end
        // resets: in a D-refill beat, and while a store waits for its answer
        always `F_AT if (f_check && rst) begin
            cover(f_vd_refill && f_dreq);
            cover(f_vd_lookup && dcpu.cyc && dcpu.stb && dcpu.we && f_dreq && !dmem.ack);
        end
        // the second configuration: a load miss behind an I-refill, answered, then a hit to the
        // same line by a later load
        if (F_LINE_WORDS > 2) begin : f_cover_second
            always `F_AT if (f_check && !rst)
                cover(f_c_mb_answered && f_dld_ack && dcpu.adr[29:F_O] == f_c_mb_line);
        end
    end else begin : f_cover_cpu
        // with the CPU-like data side: the I-miss and the load's miss in one cycle, the I-refill
        // granted in cycle R + 1 exactly
        always `F_AT if (f_check && !rst) cover(f_c_coinc && f_iwait == F_R + 1 && f_ag_i);
        // bound (b) reached exactly by K_OLDER stores, where that term binds
        if (F_KOLDER * (F_WR + 1) > F_R + 1) begin : f_cover_kolder
            always `F_AT if (f_check && !rst) cover(f_iwait == F_N_B && f_ag_i && !f_c_coinc);
        end
    end endgenerate
`endif
`endif

`endif
