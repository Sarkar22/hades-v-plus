// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// arbiter_id_top.sv -- formal harness of the memory arbiter alone with both caches' masters: its
// share of the decomposed harness of the fallback ladder for the properties of both caches.
//
// The I-side is the refill master of harness/arbiter_top.sv: in a cycle without a request it may
// start a refill of an in-window line; from the next cycle it requests the line's F_LINE_WORDS
// words in order from word 0 as one block (cyc held, each beat held until it is answered, the
// continuation tag on every beat but the first); the cycle after the last beat has no request.
// The data side is a master that behaves as the D-cache's memory port does: in a cycle without a
// request it may start either a single transfer (a load or a store with free sel and write data,
// in the window, held until it is answered) or a refill block of an in-window line (reads, sel
// 1111, write data 0, the words in order from word 0, each beat held until it is answered, the
// data continuation tag on every beat but the first), with no request in the cycle after the last
// beat (the second lookup). A reset drops both. The memory is env_memory.svh's.
// props/dcache_props.vh holds the properties (macro FH_ARBITER).
// ---------------------------------------------------------------------------------------------
module arbiter_id_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_i_start,      // the I-side misses in this cycle and starts a refill
    input logic [31:0] in_i_adr,        // the line it refills (made an in-window line)
    input logic        in_d_start,      // the data side starts a transfer or a refill block
    input logic        in_d_block,      // ... a refill block (else a single transfer)
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat,
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat
);
`include "config.svh"
`include "config_memsys.svh"
`include "env_common.svh"

    wishbone_interface dmem();      // the D-cache's memory port, the arbiter's data side
    wishbone_interface refill();    // the I-cache's refill port
    wishbone_interface mbus();      // the single memory port

    wire mbus_cont;
    wire e_wait_i, e_wait_d, e_grant_i, e_grant_d, e_port_load, e_port_store;

    // ---- the I-side ----
    logic              i_active;
    logic [F_O-1:0]    i_beat;
    logic [29-F_O:0]   i_line;
    wire  [31:0]       i_start_adr = F_WINDOW_START + (in_i_adr & (F_WINDOW_WORDS - 32'd1));
    assign refill.cyc      = i_active;
    assign refill.stb      = i_active;
    assign refill.adr      = {2'b00, i_line, i_beat};
    assign refill.we       = 1'b0;
    assign refill.sel      = 4'b1111;
    assign refill.dat_mosi = 32'd0;
    wire   refill_cont     = i_active && i_beat != '0;
    always_ff @(posedge clk) begin
        if (rst) begin
            i_active <= 1'b0;
            i_beat   <= '0;
        end else if (!i_active) begin
            if (in_i_start) begin
                i_active <= 1'b1;
                i_line   <= i_start_adr[29:F_O];
                i_beat   <= '0;
            end
        end else if (refill.ack) begin
            i_beat <= i_beat + 1'b1;
            if (i_beat == F_O'(F_LINE_WORDS - 1)) i_active <= 1'b0;
        end
    end

    // ---- the data side ----
    // d_one: a single transfer is presented (held until answered); d_blk_on: a refill block is in
    // progress; d_gap: the cycle after a block's last beat (no request)
    logic              d_one, d_blk_on, d_gap;
    logic              d_q_we;
    logic [3:0]        d_q_sel;
    logic [31:0]       d_q_adr, d_q_dat;
    logic [F_O-1:0]    d_beat;
    logic [29-F_O:0]   d_line;
    wire  [31:0]       d_start_adr = F_WINDOW_START + (in_d_adr & (F_WINDOW_WORDS - 32'd1));
    wire               d_idle   = !d_one && !d_blk_on && !d_gap;
    wire               d_new    = d_idle && in_d_start && !in_d_block;   // a new single transfer
    assign dmem.cyc      = d_one || d_blk_on || d_new;
    assign dmem.stb      = d_one || d_blk_on || d_new;
    assign dmem.adr      = d_blk_on ? {2'b00, d_line, d_beat} : d_one ? d_q_adr : d_start_adr;
    assign dmem.we       = d_blk_on ? 1'b0 : d_one ? d_q_we : in_d_we;
    assign dmem.sel      = d_blk_on ? 4'b1111 : d_one ? d_q_sel : in_d_sel;
    assign dmem.dat_mosi = d_blk_on ? 32'd0 : d_one ? d_q_dat : in_d_dat;
    wire   dmem_cont     = d_blk_on && d_beat != '0;
    always_ff @(posedge clk) begin
        d_gap <= !rst && d_blk_on && dmem.ack && d_beat == F_O'(F_LINE_WORDS - 1);
        if (rst) begin
            d_one    <= 1'b0;
            d_blk_on <= 1'b0;
            d_beat   <= '0;
        end else if (d_blk_on) begin
            if (dmem.ack) begin
                d_beat <= d_beat + 1'b1;
                if (d_beat == F_O'(F_LINE_WORDS - 1)) d_blk_on <= 1'b0;
            end
        end else if (d_one || d_new) begin
            d_one   <= !dmem.ack && !dmem.err;
            d_q_we  <= dmem.we;
            d_q_sel <= dmem.sel;
            d_q_adr <= dmem.adr;
            d_q_dat <= dmem.dat_mosi;
        end else if (d_idle && in_d_start && in_d_block) begin
            // the miss cycle: no request in it; the block requests from the next cycle
            d_blk_on <= 1'b1;
            d_line   <= d_start_adr[29:F_O];
            d_beat   <= '0;
        end
    end

    mem_arbiter mem_arbiter (
        .clk(clk), .rst(rst), .data(dmem.slave), .data_cont(dmem_cont), .irefill(refill.slave),
        .irefill_cont(refill_cont), .mem(mbus.master), .mem_cont(mbus_cont),
        .ev_wait_i(e_wait_i), .ev_wait_d(e_wait_d), .ev_grant_i(e_grant_i), .ev_grant_d(e_grant_d),
        .ev_port_load(e_port_load), .ev_port_store(e_port_store));

    // ---- views used by props/dcache_props.vh ----
    wire f_v_lookup      = !i_active;
    wire f_v_refill      = i_active;
    wire f_v_last        = i_beat == F_O'(F_LINE_WORDS - 1);
    wire f_v_beat0       = i_beat == '0;
    wire f_vd_refill     = d_blk_on;
    wire f_vd_last       = d_beat == F_O'(F_LINE_WORDS - 1);
    wire f_vd_beat0      = d_beat == '0;
    wire f_v_own_none    = mem_arbiter.f_obs_owner_none;
    wire f_v_own_data    = mem_arbiter.f_obs_owner_data;
    wire f_v_own_irefill = mem_arbiter.f_obs_owner_irefill;

    wire f_d_req = dmem.cyc && dmem.stb;
    wire f_i_req = refill.cyc && refill.stb;
    wire f_free  = f_v_own_none || (f_v_own_irefill && !f_i_req);
    wire f_gd    = f_d_req && (f_v_own_data || f_free);
    wire f_gi    = f_i_req && (f_v_own_irefill || (f_free && !f_d_req));
    wire f_ag_d  = e_grant_d;
    wire f_ag_i  = e_grant_i;

`include "env_memory.svh"
endmodule
