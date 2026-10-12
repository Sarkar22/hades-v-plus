// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// icache_top.sv -- formal harness of the I-cache alone: the k-induction attempt and the I-cache's
// share of the decomposed harness of the fallback ladder.
//
// The refill port is driven by the memory directly, through an abstract port instead of the
// arbiter: a refill that requests is granted in a cycle of free choice (in_grant) and then
// holds the port while it requests; memory answers it only while it holds the port, after 0 to
// F_MAX_WAIT wait cycles of each transfer (env_memory.svh's rules). Stores acknowledged at slave
// 0 (the snoop) are free choices, in the window, never in a reset cycle and never while a refill
// holds the port; a store at the tracked address updates the tracked word by its sel lanes. This
// allows every order of refill grants and stores that the arbiter allows, and more.
// props/cache_props.vh holds the properties (macro FH_ICACHE).
// ---------------------------------------------------------------------------------------------
module icache_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_f_cyc,
    input logic        in_f_stb,
    input logic [31:0] in_f_adr,
    input logic        in_grant,        // a waiting refill is granted the port in this cycle
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat,
    input logic        in_s_store,      // a store is acknowledged at slave 0 in this cycle
    input logic [31:0] in_s_adr,
    input logic [3:0]  in_s_sel,
    input logic [31:0] in_s_dat
);
`include "config.svh"
`include "env_common.svh"

    wishbone_interface fetch();     // the CPU's fetch bus
    wishbone_interface refill();    // icache.mem, answered by the abstract port

    wire refill_cont;
    wire e_hit, e_miss, e_beat, e_fill, e_abandoned, e_snoop_inval, e_refill;

    // the abstract port: g_held, the refill was granted in the previous cycle
    wire  f_ireq_in = refill.cyc && refill.stb;
    logic g_held;
    wire  f_gi = !rst && f_ireq_in && (g_held || in_grant);
    always_ff @(posedge clk) g_held <= f_gi;

    // stores acknowledged at slave 0
    wire        f_snoop_store = in_s_store && !rst && !f_gi;
    wire [31:0] f_snoop_adr   = in_s_store ? F_WINDOW_START + (in_s_adr & (F_WINDOW_WORDS - 32'd1))
                                           : in_s_adr;
    wire        f_st_ans      = f_snoop_store;
    wire [31:0] f_st_adr      = f_snoop_adr;

    icache #(
        .BYTES(F_BYTES), .LINE_BYTES(F_LINE_BYTES),
        .WINDOW_START(F_WINDOW_START), .WINDOW_WORDS(F_WINDOW_WORDS)
    ) icache (
        .clk(clk), .rst(rst), .cpu(fetch.slave), .mem(refill.master), .mem_cont(refill_cont),
        .snoop_store(f_snoop_store), .snoop_adr(f_snoop_adr),
        .ev_hit(e_hit), .ev_miss(e_miss), .ev_beat(e_beat), .ev_fill(e_fill),
        .ev_abandoned(e_abandoned), .ev_snoop_inval(e_snoop_inval), .ev_refill(e_refill));

    assign fetch.cyc      = in_f_cyc;
    assign fetch.stb      = in_f_stb;
    assign fetch.adr      = in_f_adr;
    assign fetch.we       = 1'b0;
    assign fetch.sel      = 4'b1111;
    assign fetch.dat_mosi = 32'd0;

    // memory on the refill port, only while the refill holds the port
    wire         m_req = f_gi;
    logic        m_q_open, m_q_we;
    logic [1:0]  m_q_wait;
    logic [3:0]  m_q_sel;
    logic [31:0] m_q_adr, m_q_dat;
    wire         m_same = m_q_open && m_req && refill.adr == m_q_adr && refill.we == m_q_we &&
                          refill.sel == m_q_sel && refill.dat_mosi == m_q_dat;
    wire  [1:0]  m_wait = m_same ? m_q_wait + 2'd1 : 2'd0;
    wire         m_ans  = m_req && (in_m_ans || m_wait == 2'(F_MAX_WAIT));
    assign refill.err      = m_ans && !f_inwin(refill.adr) && in_m_err;
    assign refill.ack      = m_ans && !refill.err;
    assign refill.dat_miso = (!refill.we && refill.adr == f_adr) ? f_word : in_m_dat;
    always_ff @(posedge clk) begin
        m_q_open <= m_req && !m_ans;
        m_q_wait <= m_wait;
        m_q_we   <= refill.we;
        m_q_sel  <= refill.sel;
        m_q_adr  <= refill.adr;
        m_q_dat  <= refill.dat_mosi;
        if (refill.ack && refill.we && refill.adr == f_adr)
            f_word <= f_merge(f_word, refill.dat_mosi, refill.sel);
        else if (f_snoop_store && f_snoop_adr == f_adr)
            f_word <= f_merge(f_word, in_s_dat, in_s_sel);
    end

    // ---- views used by props/cache_props.vh ----
    wire                f_v_lookup       = icache.f_obs_lookup;
    wire                f_v_refill       = icache.f_obs_refill;
    wire [F_SETS-1:0]   f_v_valid        = icache.f_obs_valid;
    wire                f_v_last         = icache.f_obs_beat == F_LINE_WORDS - 1;
    wire [29-F_O:0]     f_v_refill_line  = icache.f_obs_refill_line[29-F_O:0];
    wire [31:0]         f_v_beat         = icache.f_obs_beat;
    wire                f_v_beat0        = icache.f_obs_beat == 0;
    wire                f_v_port_held    = g_held;
    wire                f_ag_i           = f_gi;     // the grant the abstract port gives
endmodule
