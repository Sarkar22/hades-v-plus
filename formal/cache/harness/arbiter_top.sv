// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// arbiter_top.sv -- formal harness of the memory arbiter alone: its share of the decomposed
// harness of the fallback ladder.
//
// Both slave sides are free within the protocol: the data side as in harness/cache_top.sv
// (env_data.svh, with the same FCACHE_CPU_DATA restriction), and the I-side as a refill master
// that behaves as the I-cache's refill port does: in a cycle without a request it may decide to
// refill an in-window line (the miss cycle); from the next cycle it requests the line's
// F_LINE_WORDS words in order from word 0 as one block (cyc held, each beat's request held until
// it is answered, the continuation tag on every beat but the first); the cycle after the last
// beat has no request; a reset drops the block. The memory is env_memory.svh's.
// props/cache_props.vh holds the properties (macro FH_ARBITER).
// ---------------------------------------------------------------------------------------------
module arbiter_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_d_cyc,
    input logic        in_d_stb,
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat,
    input logic        in_i_start,      // the I-side misses in this cycle and starts a refill
    input logic [31:0] in_i_adr,        // the line it refills (made an in-window line)
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat
);
`include "config.svh"
`include "env_common.svh"

    wishbone_interface dbus();      // interconnect slave 0: the data side
    wishbone_interface refill();    // the I-side's refill port
    wishbone_interface mbus();      // the single memory port

    wire mbus_cont;
    wire e_wait_i, e_wait_d, e_grant_i, e_grant_d, e_port_load, e_port_store;

`include "snoop.svh"
    wire        f_snoop_store = `F_SNOOP_STORE(dbus);
    wire [31:0] f_snoop_adr   = `F_SNOOP_ADR(dbus);

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

    mem_arbiter mem_arbiter (
        .clk(clk), .rst(rst), .data(dbus.slave), .data_cont(1'b0), .irefill(refill.slave), .irefill_cont(refill_cont),
        .mem(mbus.master), .mem_cont(mbus_cont),
        .ev_wait_i(e_wait_i), .ev_wait_d(e_wait_d), .ev_grant_i(e_grant_i), .ev_grant_d(e_grant_d),
        .ev_port_load(e_port_load), .ev_port_store(e_port_store));

    // ---- views used by props/cache_props.vh ----
    wire f_v_lookup      = !i_active;
    wire f_v_refill      = i_active;
    wire f_v_last        = i_beat == F_O'(F_LINE_WORDS - 1);
    wire f_v_beat0       = i_beat == '0;
    wire f_v_own_none    = mem_arbiter.f_obs_owner_none;
    wire f_v_own_data    = mem_arbiter.f_obs_owner_data;
    wire f_v_own_irefill = mem_arbiter.f_obs_owner_irefill;

    wire f_d_req = dbus.cyc && dbus.stb;
    wire f_i_req = refill.cyc && refill.stb;
    wire f_free  = f_v_own_none || (f_v_own_irefill && !f_i_req);
    wire f_gd    = f_d_req && (f_v_own_data || f_free);
    wire f_gi    = f_i_req && (f_v_own_irefill || (f_free && !f_d_req));
    // the grants the design actually gives: its grant events (0 in reset cycles)
    wire f_ag_d  = e_grant_d;
    wire f_ag_i  = e_grant_i;

    // ---- the data side's restriction (FCACHE_CPU_DATA), as in harness/cache_top.sv ----
    logic       k_granted, d_q_gd;
    logic [1:0] k_begun;
    wire        k_pre   = f_v_refill && !k_granted && !rst;
    wire        d_begin = f_ag_d && !d_q_gd;
`ifdef FCACHE_CPU_DATA
    localparam bit F_CPU_DATA = 1'b1;
    wire        d_block = k_pre && k_begun >= 2'(F_KOLDER - 1);
`else
    localparam bit F_CPU_DATA = 1'b0;
    wire        d_block = 1'b0;
`endif
    always_ff @(posedge clk) begin
        k_granted <= !rst && f_v_refill && (k_granted || f_ag_i);
        k_begun   <= (!rst && f_v_refill) ? k_begun + {1'b0, k_pre && d_begin} : 2'd0;
        d_q_gd    <= !rst && f_ag_d && !dbus.ack && !dbus.err;
    end

`include "env_data.svh"
`include "env_memory.svh"
endmodule
