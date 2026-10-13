// SPDX-License-Identifier: MIT
// =============================================================================================
// unit_props.vh -- the properties and covers of the performance-counter unit.
//
// formal/hpm/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of harness/unit_top.sv. It reads the unit's state through the observer
// props/observe_hpm.svh (u_hpm.f_obs_cnt, f_obs_sel, f_obs_inh), its outputs (rdata, inh_cy,
// inh_ir, inh_bp) and the harness's event model (f_ev_exp: the event each code contributes at
// the end of this cycle). Every property is checked from the cycle after the first one. One task
// per property (sby/unit.sby) defines its CHECK_ macro; each also asserts the two invariants
// below, which its k-induction needs.
//
// Notation: counter n = 3 + k (k = 0 .. N-1), W its width, cnt' its value one cycle later. A
// write is csr_we with the counter's address: low half 0xB00 + n, high half 0xB80 + n, selector
// 0x320 + n, mcountinhibit 0x320. step = (event of the selected code) and not inhibited.
//   increment      no write and no reset: cnt' = cnt or cnt + 1 (mod 2^W); cnt' = cnt when the
//                  counter is inhibited or its selector is 0.
//   write_rule     a low write: cnt'[31:0] = the written value, the high half that of
//                  cnt + step; a high write: cnt'[W-1:32] = the written value's W-32 low bits,
//                  the low half that of cnt + step (with W = 32 a high write is ignored).
//   event_timing   no write and no reset: cnt' = cnt + step, with the event of the model:
//                  class A in the same cycle, B1 one cycle later, B2 two cycles later.
//   selector_warl  every selector holds 0 or a code this build has (an invariant); after a
//                  write it holds the written value if that is such a code (bits 31:8 zero),
//                  else 0; the selectors of counters 11-13 read 18, 19 and 20.
//   inhibit        mcountinhibit has only the implemented bits (CY, IR, 3 .. 2+N, 10-13), TM
//                  is 0 (an invariant); after a write it is the written value masked to them;
//                  inh_cy, inh_ir and inh_bp are its bits 0, 2 and 13:10.
//   isolation      a selector changes only through its own write, mcountinhibit only through
//                  its write, and a counter not written and without its event keeps its value.
//   read_value     rdata is the specified value for every address, and 0 for every address the
//                  unit does not implement (except those Writeback answers itself, where rdata
//                  is never used).
//   reset_state    in the cycle after a reset cycle every counter, selector and mcountinhibit
//                  is 0.
// =============================================================================================
`ifdef FORMAL
    // ---- the observed state ----
    (* hierconn *) wire [7*64-1:0] \u_hpm.f_obs_cnt ;
    (* hierconn *) wire [7*8-1:0]  \u_hpm.f_obs_sel ;
    (* hierconn *) wire [31:0]     \u_hpm.f_obs_inh ;
    wire [7*64-1:0] f_cnt_all = \u_hpm.f_obs_cnt ;
    wire [7*8-1:0]  f_sel_all = \u_hpm.f_obs_sel ;
    wire [31:0]     f_inh     = \u_hpm.f_obs_inh ;

    localparam [63:0] F_MASK = {64{1'b1}} >> (64 - F_W);
    // the implemented bits of mcountinhibit: CY, IR, HPM3 .. HPM(2+N), HPM10-13
    function [31:0] f_impl_mask_of;
        input integer n;
        integer i;
        begin
            f_impl_mask_of = 32'h0000_3C05;
            for (i = 0; i < 7; i = i + 1)
                if (i < n) f_impl_mask_of[3 + i] = 1'b1;
        end
    endfunction
    localparam [31:0] F_IMPL_MASK = f_impl_mask_of(F_N);

    // a code this build has: 1-26, 32-49 always; 128 + k with present bit k; 160 and 161 with
    // present bits 0 and 1
    function f_impl;
        input [7:0]  c;
        input [31:0] p;
        begin
            f_impl = (c >= 8'd1 && c <= 8'd26) || (c >= 8'd32 && c <= 8'd49) ||
                     (c >= 8'd128 && c <= 8'd159 && p[c[4:0]]) ||
                     (c == 8'd160 && p[0]) || (c == 8'd161 && p[1]);
        end
    endfunction
    wire f_legal_wdata = csr_wdata[31:8] == 24'b0 && f_impl(csr_wdata[7:0], hpm_ext_present);
    wire f_w_inh = csr_we && csr_addr == 12'h320;

    // addresses whose read value Writeback answers itself; the unit's rdata is never used there
    wire f_wb_owned = csr_addr == 12'h300 || csr_addr == 12'h304 || csr_addr == 12'h305 ||
                      csr_addr == 12'h340 || csr_addr == 12'h341 || csr_addr == 12'h342 ||
                      csr_addr == 12'h344 || csr_addr == 12'hB00 || csr_addr == 12'hB02 ||
                      csr_addr == 12'hB80 || csr_addr == 12'hB82 ||
                      (csr_addr >= 12'hC00 && csr_addr <= 12'hC02) ||
                      (csr_addr >= 12'hC80 && csr_addr <= 12'hC82) ||
                      csr_addr == 12'h32A || (csr_addr >= 12'hB0A && csr_addr <= 12'hB0D);

    // the specified read value of the unit for csr_addr
    reg [31:0] f_rd_exp;
    integer f_i;
    always @* begin
        f_rd_exp = 32'b0;
        if (csr_addr == 12'h320) f_rd_exp = f_inh;
        if (csr_addr == 12'h32B) f_rd_exp = 32'd18;
        if (csr_addr == 12'h32C) f_rd_exp = 32'd19;
        if (csr_addr == 12'h32D) f_rd_exp = 32'd20;
        for (f_i = 0; f_i < 7; f_i = f_i + 1) begin
            if (f_i < F_N) begin
                if (csr_addr == 12'h323 + f_i) f_rd_exp = {24'b0, f_sel_all[f_i*8 +: 8]};
                if (csr_addr == 12'hB03 + f_i) f_rd_exp = f_cnt_all[f_i*64 +: 32];
                if (csr_addr == 12'hB83 + f_i) f_rd_exp = f_cnt_all[f_i*64 + 32 +: 32];
            end
        end
    end

    // ---- the invariants (asserted in every task) and the unit-wide properties ----
    always @* if (!f_first) begin
        `ifndef COVERS
        assert((f_inh & ~F_IMPL_MASK) == 32'b0);
        `endif
        `ifdef CHECK_INHIBIT
        assert(f_inh[1] == 1'b0);
        assert(inh_cy == f_inh[0] && inh_ir == f_inh[2] && inh_bp == f_inh[13:10]);
        `endif
        `ifdef CHECK_SELECTOR_WARL
        if (csr_addr == 12'h32B) assert(rdata == 32'd18);
        if (csr_addr == 12'h32C) assert(rdata == 32'd19);
        if (csr_addr == 12'h32D) assert(rdata == 32'd20);
        `endif
        `ifdef CHECK_READ_VALUE
        if (!f_wb_owned) assert(rdata == f_rd_exp);
        `endif
    end
    always @(posedge clk) if (!f_first) begin
        `ifdef CHECK_INHIBIT
        if (!$past(rst) && $past(f_w_inh)) assert(f_inh == ($past(csr_wdata) & F_IMPL_MASK));
        `endif
        `ifdef CHECK_ISOLATION
        if (!$past(rst) && !$past(f_w_inh)) assert(f_inh == $past(f_inh));
        `endif
        `ifdef CHECK_RESET_STATE
        if ($past(rst)) assert(f_inh == 32'b0);
        `endif
    end

    // ---- per counter ----
    genvar fk;
    generate for (fk = 0; fk < 7; fk = fk + 1) begin : f_ctr
        if (fk < F_N) begin : f_on
            wire [63:0] cnt   = f_cnt_all[fk*64 +: 64];
            wire [7:0]  sel   = f_sel_all[fk*8 +: 8];
            wire        inh_n = f_inh[3 + fk];
            wire        w_lo  = csr_we && csr_addr == 12'hB03 + fk;
            wire        w_hi  = csr_we && csr_addr == 12'hB83 + fk;
            wire        w_sel = csr_we && csr_addr == 12'h323 + fk;
            wire        step  = f_ev_exp[sel] && !inh_n;
            wire [63:0] inc   = (cnt + {63'b0, step}) & F_MASK;
            wire [63:0] inc1  = (cnt + 64'd1) & F_MASK;

            always @* if (!f_first) begin
                `ifndef COVERS
                assert(sel == 8'd0 || f_impl(sel, hpm_ext_present));
                `endif
            end
            always @(posedge clk) if (!f_first) begin
                `ifdef CHECK_INCREMENT
                if (!$past(rst) && !$past(w_lo) && !$past(w_hi)) begin
                    assert(cnt == $past(cnt) || cnt == $past(inc1));
                    if ($past(inh_n) || $past(sel) == 8'd0) assert(cnt == $past(cnt));
                end
                `endif
                `ifdef CHECK_EVENT_TIMING
                if (!$past(rst) && !$past(w_lo) && !$past(w_hi)) assert(cnt == $past(inc));
                `endif
                `ifdef CHECK_WRITE_RULE
                if (!$past(rst) && $past(w_lo)) begin
                    assert(cnt[31:0] == $past(csr_wdata));
                    assert(cnt[63:32] == $past(inc[63:32]));
                end
                if (!$past(rst) && $past(w_hi)) begin
                    assert(cnt[31:0] == $past(inc[31:0]));
                    if (F_W > 32) assert(cnt[63:32] == ($past(csr_wdata) & F_MASK[63:32]));
                    else          assert(cnt[63:32] == 32'b0);
                end
                `endif
                `ifdef CHECK_SELECTOR_WARL
                if (!$past(rst) && $past(w_sel))
                    assert(sel == ($past(f_legal_wdata) ? $past(csr_wdata[7:0]) : 8'd0));
                `endif
                `ifdef CHECK_ISOLATION
                if (!$past(rst) && !$past(w_sel)) assert(sel == $past(sel));
                if (!$past(rst) && !$past(w_lo) && !$past(w_hi) && !$past(step))
                    assert(cnt == $past(cnt));
                `endif
                `ifdef CHECK_RESET_STATE
                if ($past(rst)) assert(cnt == 64'b0 && sel == 8'd0);
                `endif
            end

            `ifdef COVERS
            if (fk == 0) begin : f_cov
                always @(posedge clk) if (!f_first && !$past(rst)) begin
                    // a class-A, a class-B1 and a class-B2 event counted
                    cover($past(sel) == 8'd2  && cnt == $past(inc1) && !$past(w_lo) && !$past(w_hi));
                    cover($past(sel) == 8'd49 && cnt == $past(inc1) && !$past(w_lo) && !$past(w_hi));
                    cover($past(sel) == 8'd36 && cnt == $past(inc1) && !$past(w_lo) && !$past(w_hi));
                    cover($past(sel) == 8'd24 && cnt == $past(inc1) && !$past(w_lo) && !$past(w_hi));
                    cover($past(sel) == 8'd160 && cnt == $past(inc1) && !$past(w_lo) && !$past(w_hi));
                    // a carry from the low into the high half, and a wrap at 2^W
                    cover($past(cnt[31:0]) == 32'hFFFF_FFFF && cnt[31:0] == 32'b0 && cnt[63:32] != $past(cnt[63:32]));
                    cover($past(cnt) == F_MASK && cnt == 64'b0);
                    // a write in the same cycle as an event (the event is discarded in that half)
                    cover($past(w_lo) && $past(step));
                    cover($past(w_hi) && $past(step));
                    // a legal and an illegal selector write
                    cover($past(w_sel) && $past(csr_wdata) == 32'd161 && sel == 8'd161);
                    cover($past(w_sel) && $past(csr_wdata) == 32'd27 && sel == 8'd0);
                    // the inhibit bit holds a counter whose event happens
                    cover($past(inh_n) && $past(f_ev_exp[sel]) && cnt == $past(cnt));
                end
            end
            `endif
        end
    end endgenerate
`endif
