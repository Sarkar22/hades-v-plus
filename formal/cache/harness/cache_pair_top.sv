// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// cache_pair_top.sv -- formal harness of the non-interference property: two copies of the I-cache
// and the arbiter (copy a and copy b), connected as in harness/cache_top.sv, receive the same
// inputs except data values: memory's read data, the data side's write data and the initial
// contents of the data arrays differ between the copies (each copy has its own free inputs, and
// the arrays of both start free). The reset, the fetch side, the data side's requests (cyc, stb,
// address, we, sel) and the timing of memory's answers are shared. props/pair_props.vh holds the
// property; formal/cache/run.sh inserts it before the final endmodule of the sv2v output.
//
// The environment follows env_data.svh and env_memory.svh: copy a's answers decide when a data
// request ends and when memory answers; copy b gets an answer only while it presents a transfer
// itself (until the copies differ, they present the same transfers).
// ---------------------------------------------------------------------------------------------
module cache_pair_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_f_cyc,
    input logic        in_f_stb,
    input logic [31:0] in_f_adr,
    input logic        in_d_cyc,
    input logic        in_d_stb,
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat_a,      // write data of copy a
    input logic [31:0] in_d_dat_b,      // write data of copy b
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat_a,      // read data of copy a
    input logic [31:0] in_m_dat_b       // read data of copy b
);
`include "config.svh"
`include "env_common.svh"

    wishbone_interface fetch_a();
    wishbone_interface fetch_b();
    wishbone_interface dbus_a();
    wishbone_interface dbus_b();
    wishbone_interface refill_a();
    wishbone_interface refill_b();
    wishbone_interface mbus_a();
    wishbone_interface mbus_b();

    wire refill_cont_a, refill_cont_b, mbus_cont_a, mbus_cont_b;
    wire [6:0] ei_a, ei_b;     // the I-cache's events
    wire [5:0] ea_a, ea_b;     // the arbiter's events

`include "snoop.svh"
    wire        snoop_a     = `F_SNOOP_STORE(dbus_a);
    wire        snoop_b     = `F_SNOOP_STORE(dbus_b);
    wire [31:0] snoop_adr_a = `F_SNOOP_ADR(dbus_a);
    wire [31:0] snoop_adr_b = `F_SNOOP_ADR(dbus_b);

    icache #(
        .BYTES(F_BYTES), .LINE_BYTES(F_LINE_BYTES),
        .WINDOW_START(F_WINDOW_START), .WINDOW_WORDS(F_WINDOW_WORDS)
    ) icache_a (
        .clk(clk), .rst(rst), .cpu(fetch_a.slave), .mem(refill_a.master), .mem_cont(refill_cont_a),
        .snoop_store(snoop_a), .snoop_adr(snoop_adr_a),
        .ev_hit(ei_a[0]), .ev_miss(ei_a[1]), .ev_beat(ei_a[2]), .ev_fill(ei_a[3]),
        .ev_abandoned(ei_a[4]), .ev_snoop_inval(ei_a[5]), .ev_refill(ei_a[6]));
    icache #(
        .BYTES(F_BYTES), .LINE_BYTES(F_LINE_BYTES),
        .WINDOW_START(F_WINDOW_START), .WINDOW_WORDS(F_WINDOW_WORDS)
    ) icache_b (
        .clk(clk), .rst(rst), .cpu(fetch_b.slave), .mem(refill_b.master), .mem_cont(refill_cont_b),
        .snoop_store(snoop_b), .snoop_adr(snoop_adr_b),
        .ev_hit(ei_b[0]), .ev_miss(ei_b[1]), .ev_beat(ei_b[2]), .ev_fill(ei_b[3]),
        .ev_abandoned(ei_b[4]), .ev_snoop_inval(ei_b[5]), .ev_refill(ei_b[6]));

    mem_arbiter mem_arbiter_a (
        .clk(clk), .rst(rst), .data(dbus_a.slave), .data_cont(1'b0), .irefill(refill_a.slave),
        .irefill_cont(refill_cont_a), .mem(mbus_a.master), .mem_cont(mbus_cont_a),
        .ev_wait_i(ea_a[0]), .ev_wait_d(ea_a[1]), .ev_grant_i(ea_a[2]), .ev_grant_d(ea_a[3]),
        .ev_port_load(ea_a[4]), .ev_port_store(ea_a[5]));
    mem_arbiter mem_arbiter_b (
        .clk(clk), .rst(rst), .data(dbus_b.slave), .data_cont(1'b0), .irefill(refill_b.slave),
        .irefill_cont(refill_cont_b), .mem(mbus_b.master), .mem_cont(mbus_cont_b),
        .ev_wait_i(ea_b[0]), .ev_wait_d(ea_b[1]), .ev_grant_i(ea_b[2]), .ev_grant_d(ea_b[3]),
        .ev_port_load(ea_b[4]), .ev_port_store(ea_b[5]));

    // fetch side: shared
    assign fetch_a.cyc = in_f_cyc;  assign fetch_b.cyc = in_f_cyc;
    assign fetch_a.stb = in_f_stb;  assign fetch_b.stb = in_f_stb;
    assign fetch_a.adr = in_f_adr;  assign fetch_b.adr = in_f_adr;
    assign fetch_a.we  = 1'b0;      assign fetch_b.we  = 1'b0;
    assign fetch_a.sel = 4'b1111;   assign fetch_b.sel = 4'b1111;
    assign fetch_a.dat_mosi = 32'd0; assign fetch_b.dat_mosi = 32'd0;

    // data side: shared requests (env_data.svh's rules), write data per copy
    logic        d_q_open, d_q_we;
    logic [3:0]  d_q_sel;
    logic [31:0] d_q_adr, d_q_dat_a, d_q_dat_b;
    wire         d_hold    = d_q_open && !rst;
    wire         d_new_req = in_d_cyc && in_d_stb;
    wire  [31:0] d_new_adr = d_new_req ? F_WINDOW_START + (in_d_adr & (F_WINDOW_WORDS - 32'd1))
                                       : in_d_adr;
    wire         d_cyc = d_hold ? 1'b1    : in_d_cyc;
    wire         d_stb = d_hold ? 1'b1    : d_new_req;
    wire  [31:0] d_adr = d_hold ? d_q_adr : d_new_adr;
    wire         d_we  = d_hold ? d_q_we  : in_d_we;
    wire  [3:0]  d_sel = d_hold ? d_q_sel : in_d_sel;
    assign dbus_a.cyc = d_cyc;  assign dbus_b.cyc = d_cyc;
    assign dbus_a.stb = d_stb;  assign dbus_b.stb = d_stb;
    assign dbus_a.adr = d_adr;  assign dbus_b.adr = d_adr;
    assign dbus_a.we  = d_we;   assign dbus_b.we  = d_we;
    assign dbus_a.sel = d_sel;  assign dbus_b.sel = d_sel;
    assign dbus_a.dat_mosi = d_hold ? d_q_dat_a : in_d_dat_a;
    assign dbus_b.dat_mosi = d_hold ? d_q_dat_b : in_d_dat_b;
    always_ff @(posedge clk) begin
        d_q_open  <= !rst && d_cyc && d_stb && !dbus_a.ack && !dbus_a.err;
        d_q_we    <= d_we;
        d_q_sel   <= d_sel;
        d_q_adr   <= d_adr;
        d_q_dat_a <= dbus_a.dat_mosi;
        d_q_dat_b <= dbus_b.dat_mosi;
    end

    // memory: env_memory.svh's rules on copy a's transfers; read data per copy
    wire         m_req_a = mbus_a.cyc && mbus_a.stb;
    wire         m_req_b = mbus_b.cyc && mbus_b.stb;
    logic        m_q_open, m_q_we;
    logic [1:0]  m_q_wait;
    logic [3:0]  m_q_sel;
    logic [31:0] m_q_adr, m_q_dat;
    wire         m_same = m_q_open && m_req_a && mbus_a.adr == m_q_adr && mbus_a.we == m_q_we &&
                          mbus_a.sel == m_q_sel && mbus_a.dat_mosi == m_q_dat;
    wire  [1:0]  m_wait = m_same ? m_q_wait + 2'd1 : 2'd0;
    wire         m_ans  = m_req_a && !rst && (in_m_ans || m_wait == 2'(F_MAX_WAIT));
    assign mbus_a.err      = m_ans && !f_inwin(mbus_a.adr) && in_m_err;
    assign mbus_a.ack      = m_ans && !mbus_a.err;
    assign mbus_b.err      = m_ans && m_req_b && !f_inwin(mbus_b.adr) && in_m_err;
    assign mbus_b.ack      = m_ans && m_req_b && !mbus_b.err;
    assign mbus_a.dat_miso = in_m_dat_a;
    assign mbus_b.dat_miso = in_m_dat_b;
    always_ff @(posedge clk) begin
        m_q_open <= m_req_a && !m_ans && !rst;
        m_q_wait <= m_wait;
        m_q_we   <= mbus_a.we;
        m_q_sel  <= mbus_a.sel;
        m_q_adr  <= mbus_a.adr;
        m_q_dat  <= mbus_a.dat_mosi;
    end

    // the grants of each copy, from its owner and its two requests
    wire i_req_a = refill_a.cyc && refill_a.stb;
    wire i_req_b = refill_b.cyc && refill_b.stb;
    wire d_req_a = dbus_a.cyc && dbus_a.stb;
    wire d_req_b = dbus_b.cyc && dbus_b.stb;
    wire free_a  = mem_arbiter_a.f_obs_owner_none || (mem_arbiter_a.f_obs_owner_irefill && !i_req_a);
    wire free_b  = mem_arbiter_b.f_obs_owner_none || (mem_arbiter_b.f_obs_owner_irefill && !i_req_b);
    wire f_gd_a  = d_req_a && (mem_arbiter_a.f_obs_owner_data || free_a);
    wire f_gd_b  = d_req_b && (mem_arbiter_b.f_obs_owner_data || free_b);
    wire f_gi_a  = i_req_a && (mem_arbiter_a.f_obs_owner_irefill || (free_a && !d_req_a));
    wire f_gi_b  = i_req_b && (mem_arbiter_b.f_obs_owner_irefill || (free_b && !d_req_b));
endmodule
