// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// arbiter_equiv_top.sv -- formal harness of the arbiter's equivalence: rtl/cache/mem_arbiter.sv
// of the tree with its data continuation tag tied to 0 (instance dut) against the arbiter of the
// base commit (instance base: mem_arbiter_base.sv, a copy of that commit's file with only its
// module name changed; formal/cache/run.sh checks the copy against the commit).
//
// Both get the same inputs in every cycle, all free: the requests of the data side and of the
// refill side (cyc, stb, address, we, sel, write data; the I-cache's continuation tag) and the
// memory's answers (ack, err, read data), with no protocol rule at all. The first cycle is a reset
// of both; later resets are free. props/equiv_props.vh compares every output and the owner in
// every cycle; formal/cache/run.sh proves it unbounded, by induction.
// ---------------------------------------------------------------------------------------------
module arbiter_equiv_top (
    input logic        clk,
    input logic        in_rst,
    input logic        in_d_cyc,
    input logic        in_d_stb,
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat,
    input logic        in_i_cyc,
    input logic        in_i_stb,
    input logic        in_i_we,
    input logic [3:0]  in_i_sel,
    input logic [31:0] in_i_adr,
    input logic [31:0] in_i_dat,
    input logic        in_i_cont,
    input logic        in_m_ack,
    input logic        in_m_err,
    input logic [31:0] in_m_dat
);
    logic f_first = 1'b1;
    always_ff @(posedge clk) f_first <= 1'b0;
    wire  rst = in_rst || f_first;

    wishbone_interface data_t();    wishbone_interface data_b();
    wishbone_interface refill_t();  wishbone_interface refill_b();
    wishbone_interface mem_t();     wishbone_interface mem_b();
    wire       cont_t, cont_b;
    wire [5:0] ev_t, ev_b;

    mem_arbiter dut (
        .clk(clk), .rst(rst), .data(data_t.slave), .data_cont(1'b0), .irefill(refill_t.slave),
        .irefill_cont(in_i_cont), .mem(mem_t.master), .mem_cont(cont_t),
        .ev_wait_i(ev_t[0]), .ev_wait_d(ev_t[1]), .ev_grant_i(ev_t[2]), .ev_grant_d(ev_t[3]),
        .ev_port_load(ev_t[4]), .ev_port_store(ev_t[5]));
    mem_arbiter_base base (
        .clk(clk), .rst(rst), .data(data_b.slave), .irefill(refill_b.slave),
        .irefill_cont(in_i_cont), .mem(mem_b.master), .mem_cont(cont_b),
        .ev_wait_i(ev_b[0]), .ev_wait_d(ev_b[1]), .ev_grant_i(ev_b[2]), .ev_grant_d(ev_b[3]),
        .ev_port_load(ev_b[4]), .ev_port_store(ev_b[5]));

    assign data_t.cyc = in_d_cyc;        assign data_b.cyc = in_d_cyc;
    assign data_t.stb = in_d_stb;        assign data_b.stb = in_d_stb;
    assign data_t.we  = in_d_we;         assign data_b.we  = in_d_we;
    assign data_t.sel = in_d_sel;        assign data_b.sel = in_d_sel;
    assign data_t.adr = in_d_adr;        assign data_b.adr = in_d_adr;
    assign data_t.dat_mosi = in_d_dat;   assign data_b.dat_mosi = in_d_dat;
    assign refill_t.cyc = in_i_cyc;      assign refill_b.cyc = in_i_cyc;
    assign refill_t.stb = in_i_stb;      assign refill_b.stb = in_i_stb;
    assign refill_t.we  = in_i_we;       assign refill_b.we  = in_i_we;
    assign refill_t.sel = in_i_sel;      assign refill_b.sel = in_i_sel;
    assign refill_t.adr = in_i_adr;      assign refill_b.adr = in_i_adr;
    assign refill_t.dat_mosi = in_i_dat; assign refill_b.dat_mosi = in_i_dat;
    assign mem_t.ack = in_m_ack;         assign mem_b.ack = in_m_ack;
    assign mem_t.err = in_m_err;         assign mem_b.err = in_m_err;
    assign mem_t.dat_miso = in_m_dat;    assign mem_b.dat_miso = in_m_dat;
endmodule
