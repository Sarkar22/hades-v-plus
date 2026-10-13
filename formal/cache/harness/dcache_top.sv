// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// dcache_top.sv -- formal harness of the D-cache alone: the k-induction attempt on the D-cache
// and the D-cache's share of the decomposed harness of the fallback ladder.
//
// The CPU side is env_ddata.svh's. The memory side is abstract, instead of the arbiter and the
// I-cache: a request of the D-cache (a refill beat or a store) is granted in a cycle of free
// choice (in_grant) and then holds the port until it is answered; memory answers it only while
// it holds the port, after 0 to F_MAX_WAIT wait cycles (writes F_MAX_WAIT_WR), never in a reset
// cycle; reads return the tracked word at the tracked address, and a write answered there updates
// it. Between the beats of a refill the port may go elsewhere, which the arbiter never allows:
// the abstract port allows every order of grants that the arbiter allows, and more. Memory is
// written only by the D-cache's stores, as in the system (the I-cache only reads).
// props/dcache_props.vh holds the properties (macro FH_DCACHE).
// ---------------------------------------------------------------------------------------------
module dcache_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_d_cyc,
    input logic        in_d_stb,
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat,
    input logic        in_grant,        // a waiting request of the D-cache is granted in this cycle
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat
);
`include "config.svh"
`include "config_memsys.svh"
`include "env_common.svh"

    wishbone_interface dcpu();      // interconnect slave 0: the D-cache's CPU port
    wishbone_interface dmem();      // dcache.mem, answered by the abstract port

    wire dmem_cont;
    wire ed_lookup_hit, ed_load_miss, ed_beat, ed_fill, ed_store_hit, ed_store_miss, ed_store_wait,
         ed_refill;

    dcache #(
        .BYTES(F_BYTES), .LINE_BYTES(F_LINE_BYTES),
        .WINDOW_START(F_WINDOW_START), .WINDOW_WORDS(F_WINDOW_WORDS)
    ) dcache (
        .clk(clk), .rst(rst), .cpu(dcpu.slave), .mem(dmem.master), .mem_cont(dmem_cont),
        .ev_lookup_hit(ed_lookup_hit), .ev_load_miss(ed_load_miss), .ev_beat(ed_beat),
        .ev_fill(ed_fill), .ev_store_hit(ed_store_hit), .ev_store_miss(ed_store_miss),
        .ev_store_wait(ed_store_wait), .ev_refill(ed_refill));

    // the abstract port: g_held, the D-cache's request was granted in the previous cycle and not
    // answered there
    wire  f_d_req = dmem.cyc && dmem.stb;
    logic g_held;
    wire  f_gd    = !rst && f_d_req && (g_held || in_grant);
    wire  f_ag_d  = f_gd;               // the grant the abstract port gives
    // memory on the D-cache's port, only while it holds the port
    wire         m_req = f_gd;
    logic        m_q_open, m_q_we;
    logic [1:0]  m_q_wait;
    logic [3:0]  m_q_sel;
    logic [31:0] m_q_adr, m_q_dat;
    wire         m_same = m_q_open && m_req && dmem.adr == m_q_adr && dmem.we == m_q_we &&
                          dmem.sel == m_q_sel && dmem.dat_mosi == m_q_dat;
    wire  [1:0]  m_wait = m_same ? m_q_wait + 2'd1 : 2'd0;
    wire         m_ans  = m_req && (in_m_ans || m_wait == 2'(dmem.we ? F_MAX_WAIT_WR : F_MAX_WAIT));
    assign dmem.err      = m_ans && !f_inwin(dmem.adr) && in_m_err;
    assign dmem.ack      = m_ans && !dmem.err;
    assign dmem.dat_miso = (!dmem.we && dmem.adr == f_adr) ? f_word : in_m_dat;
    always_ff @(posedge clk) begin
        g_held   <= f_gd && !dmem.ack && !dmem.err;
        m_q_open <= m_req && !m_ans;
        m_q_wait <= m_wait;
        m_q_we   <= dmem.we;
        m_q_sel  <= dmem.sel;
        m_q_adr  <= dmem.adr;
        m_q_dat  <= dmem.dat_mosi;
        if (dmem.ack && dmem.we && dmem.adr == f_adr)
            f_word <= f_merge(f_word, dmem.dat_mosi, dmem.sel);
    end

    // ---- views used by props/dcache_props.vh ----
    wire                f_vd_lookup      = dcache.f_obs_lookup;
    wire                f_vd_refill      = dcache.f_obs_refill;
    wire [31:0]         f_vd_state_bits  = dcache.f_obs_state_bits;
    wire [F_SETS-1:0]   f_vd_valid       = dcache.f_obs_valid;
    wire                f_vd_last        = dcache.f_obs_beat == F_LINE_WORDS - 1;
    wire [31:0]         f_vd_beat        = dcache.f_obs_beat;
    wire                f_vd_beat0       = dcache.f_obs_beat == 0;
    wire [29-F_O:0]     f_vd_refill_line = dcache.f_obs_refill_line[29-F_O:0];
    wire                f_vd_present     = dcache.f_obs_present;
    wire                f_vd_st_accept   = dcache.f_obs_st_accept;
    wire                f_vd_port_held   = g_held;
    wire                f_st_ans         = dcpu.cyc && dcpu.stb && dcpu.we && dcpu.ack;
    wire [31:0]         f_st_adr         = dcpu.adr;

    wire d_block = 1'b0;
`include "env_ddata.svh"
endmodule
