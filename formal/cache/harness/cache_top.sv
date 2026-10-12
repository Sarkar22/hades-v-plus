// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// cache_top.sv -- formal harness of the I-cache and the memory arbiter together.
//
// A plain top module without interface ports. It instantiates the wishbone_interface instances
// and the two modules under proof, connected as the cached memory system of rtl/mcu.sv connects
// them: the fetch bus to icache.cpu, icache.mem to the arbiter's irefill side, interconnect slave
// 0 to its data side, the snoop as rtl/mcu.sv connects it (the stores acknowledged at slave 0),
// and the arbiter's memory port to a memory model. Every free choice is an input of this module, so a proof gives it any
// value in every cycle; the environment turns the choices into a legal environment by
// construction (env_*.svh), without assumptions, so the same model also runs in a random
// simulation. The properties and covers are in props/cache_props.vh, which formal/cache/run.sh
// inserts before the final endmodule of the sv2v output of this file.
//
// Macros: FCACHE_SECOND, FCACHE_NARROW (config.svh); FCACHE_CPU_DATA: the data side behaves as
// the CPU does after a fetch misses (used only for the bound on the refill's grant): from the miss
// cycle up to the refill's first grant at most F_KOLDER data transfers hold the port, and at most
// F_KOLDER - 1 of them begin after the miss cycle. A data transfer that begins in a refill cycle
// before that grant is counted; once F_KOLDER - 1 have begun, no new request starts until the
// refill is granted.
// ---------------------------------------------------------------------------------------------
module cache_top (
    input logic        clk,
    input logic        in_rst,
    // fetch side: free in every cycle
    input logic        in_f_cyc,
    input logic        in_f_stb,
    input logic [31:0] in_f_adr,
    // data side: the choices for a new request (env_data.svh)
    input logic        in_d_cyc,
    input logic        in_d_stb,
    input logic        in_d_we,
    input logic [3:0]  in_d_sel,
    input logic [31:0] in_d_adr,
    input logic [31:0] in_d_dat,
    // memory: the choices for its answers (env_memory.svh)
    input logic        in_m_ans,
    input logic        in_m_err,
    input logic [31:0] in_m_dat
);
`include "config.svh"
`include "env_common.svh"

    wishbone_interface fetch();     // the CPU's fetch bus
    wishbone_interface dbus();      // interconnect slave 0: the data side
    wishbone_interface refill();    // icache.mem to the arbiter's irefill side
    wishbone_interface mbus();      // the single memory port

    wire refill_cont, mbus_cont;
    wire e_hit, e_miss, e_beat, e_fill, e_abandoned, e_snoop_inval, e_refill;
    wire e_wait_i, e_wait_d, e_grant_i, e_grant_d, e_port_load, e_port_store;

    // the snoop: a store acknowledged at slave 0, and its address, as rtl/mcu.sv connects them
    // (snoop.svh, written by scripts/model.py from the cached branch of rtl/mcu.sv)
`include "snoop.svh"
    wire        f_snoop_store = `F_SNOOP_STORE(dbus);
    wire [31:0] f_snoop_adr   = `F_SNOOP_ADR(dbus);
    // a data store answered at slave 0, as the properties see it
    wire        f_st_ans = dbus.cyc && dbus.stb && dbus.we && dbus.ack;
    wire [31:0] f_st_adr = dbus.adr;

    icache #(
        .BYTES(F_BYTES), .LINE_BYTES(F_LINE_BYTES),
        .WINDOW_START(F_WINDOW_START), .WINDOW_WORDS(F_WINDOW_WORDS)
    ) icache (
        .clk(clk), .rst(rst), .cpu(fetch.slave), .mem(refill.master), .mem_cont(refill_cont),
        .snoop_store(f_snoop_store), .snoop_adr(f_snoop_adr),
        .ev_hit(e_hit), .ev_miss(e_miss), .ev_beat(e_beat), .ev_fill(e_fill),
        .ev_abandoned(e_abandoned), .ev_snoop_inval(e_snoop_inval), .ev_refill(e_refill));

    mem_arbiter mem_arbiter (
        .clk(clk), .rst(rst), .data(dbus.slave), .irefill(refill.slave), .irefill_cont(refill_cont),
        .mem(mbus.master), .mem_cont(mbus_cont),
        .ev_wait_i(e_wait_i), .ev_wait_d(e_wait_d), .ev_grant_i(e_grant_i), .ev_grant_d(e_grant_d),
        .ev_port_load(e_port_load), .ev_port_store(e_port_store));

    // fetch side: cyc, stb and the address free; we 0, sel 1111 and write data 0, as the CPUs drive
    assign fetch.cyc      = in_f_cyc;
    assign fetch.stb      = in_f_stb;
    assign fetch.adr      = in_f_adr;
    assign fetch.we       = 1'b0;
    assign fetch.sel      = 4'b1111;
    assign fetch.dat_mosi = 32'd0;

    // ---- views used by props/cache_props.vh ----
    wire                f_v_lookup       = icache.f_obs_lookup;
    wire                f_v_refill       = icache.f_obs_refill;
    wire [F_SETS-1:0]   f_v_valid        = icache.f_obs_valid;
    wire                f_v_last         = icache.f_obs_beat == F_LINE_WORDS - 1;
    wire [29-F_O:0]     f_v_refill_line  = icache.f_obs_refill_line[29-F_O:0];
    wire [31:0]         f_v_beat         = icache.f_obs_beat;
    wire                f_v_beat0        = icache.f_obs_beat == 0;
    wire                f_v_own_none     = mem_arbiter.f_obs_owner_none;
    wire                f_v_own_data     = mem_arbiter.f_obs_owner_data;
    wire                f_v_own_irefill  = mem_arbiter.f_obs_owner_irefill;

    // The grants as the arbiter's rules define them, from its owner and the two requests.
    wire f_d_req = dbus.cyc && dbus.stb;
    wire f_i_req = refill.cyc && refill.stb;
    wire f_free  = f_v_own_none || (f_v_own_irefill && !f_i_req);
    wire f_gd    = f_d_req && (f_v_own_data || f_free);
    wire f_gi    = f_i_req && (f_v_own_irefill || (f_free && !f_d_req));
    // the grants the design actually gives: its grant events (0 in reset cycles)
    wire f_ag_d  = e_grant_d;
    wire f_ag_i  = e_grant_i;

    // ---- the data side's restriction (FCACHE_CPU_DATA) ----
    // k_granted: the current refill has been granted in an earlier cycle; k_begun: data transfers
    // begun in its refill cycles before that grant; d_q_gd: the previous cycle granted a data
    // transfer that was not answered there (so a grant now continues it).
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
