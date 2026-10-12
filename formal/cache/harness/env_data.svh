// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// env_data.svh -- the data side as interconnect slave 0 sees it, made legal by construction.
// Included inside a harness module with the interface dbus (slave 0 of the interconnect), the
// free inputs in_d_cyc, in_d_stb, in_d_we, in_d_sel, in_d_adr, in_d_dat and a wire d_block
// (1: no new request may start in this cycle).
//
// - A request (cyc and stb) is held unchanged (address, we, sel, write data) until it is answered
//   (ack or err) or until a reset cycle drops it; it may already change in the reset cycle.
// - A new request lies in the window: slave 0 is selected only there.
// - Between requests, cyc is free and may be 1 with stb 0, as at slave 0 during every I/O access
//   (the interconnect gives slave 0 the master's cyc, but stb only for the RAM window); the
//   address, we, sel and write data are free then.
// - stb is never 1 without cyc.
// ---------------------------------------------------------------------------------------------
    logic        d_q_open;                  // the previous cycle presented an unanswered request
    logic        d_q_we;
    logic [3:0]  d_q_sel;
    logic [31:0] d_q_adr, d_q_dat;
    wire         d_hold    = d_q_open && !rst;
    wire         d_new_req = in_d_cyc && in_d_stb && !d_block;
    wire  [31:0] d_new_adr = d_new_req ? F_WINDOW_START + (in_d_adr & (F_WINDOW_WORDS - 32'd1))
                                       : in_d_adr;
    assign dbus.cyc      = d_hold ? 1'b1    : in_d_cyc;
    assign dbus.stb      = d_hold ? 1'b1    : d_new_req;
    assign dbus.adr      = d_hold ? d_q_adr : d_new_adr;
    assign dbus.we       = d_hold ? d_q_we  : in_d_we;
    assign dbus.sel      = d_hold ? d_q_sel : in_d_sel;
    assign dbus.dat_mosi = d_hold ? d_q_dat : in_d_dat;
    always_ff @(posedge clk) begin
        d_q_open <= !rst && dbus.cyc && dbus.stb && !dbus.ack && !dbus.err;
        d_q_we   <= dbus.we;
        d_q_sel  <= dbus.sel;
        d_q_adr  <= dbus.adr;
        d_q_dat  <= dbus.dat_mosi;
    end
