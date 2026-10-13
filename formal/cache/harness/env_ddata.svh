// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// env_ddata.svh -- the CPU's data requests at the D-cache's CPU port (interconnect slave 0), made
// legal by construction. Included inside a harness module with the interface dcpu (the D-cache's
// CPU port), the free inputs in_d_cyc, in_d_stb, in_d_we, in_d_sel, in_d_adr, in_d_dat and a wire
// d_block (1: no new request may start in this cycle). The rules of env_data.svh:
//
// - A request (cyc and stb) is held unchanged (address, we, sel, write data) until it is answered
//   (ack or err) or until a reset cycle drops it; it may already change in the reset cycle. One
//   request at a time: a new one starts at the earliest in the cycle after the previous answer.
// - A new request lies in the window: slave 0 is selected only there.
// - Between requests, cyc is free and may be 1 with stb 0, as at slave 0 during every I/O access;
//   the address, we, sel and write data are free then.
// - stb is never 1 without cyc.
//
// FCACHE_FREE_DATA (free mode): nothing is held; in every cycle the request is a free choice
// within the window (cyc without stb with a free address as above). It allows every sequence of
// the held mode and more, for example a request that changes while the D-cache refills.
// ---------------------------------------------------------------------------------------------
    logic        d_q_open;                  // the previous cycle presented an unanswered request
    logic        d_q_we;
    logic [3:0]  d_q_sel;
    logic [31:0] d_q_adr, d_q_dat;
`ifdef FCACHE_FREE_DATA
    localparam bit F_FREE_DATA = 1'b1;
    wire         d_hold    = 1'b0;
`else
    localparam bit F_FREE_DATA = 1'b0;
    wire         d_hold    = d_q_open && !rst;
`endif
    wire         d_new_req = in_d_cyc && in_d_stb && !d_block;
    wire  [31:0] d_new_adr = d_new_req ? F_WINDOW_START + (in_d_adr & (F_WINDOW_WORDS - 32'd1))
                                       : in_d_adr;
    // a CPU data request starts in this cycle (it is presented and does not continue a held one)
    wire         d_begin   = !d_hold && d_new_req;
    assign dcpu.cyc      = d_hold ? 1'b1    : in_d_cyc;
    assign dcpu.stb      = d_hold ? 1'b1    : d_new_req;
    assign dcpu.adr      = d_hold ? d_q_adr : d_new_adr;
    assign dcpu.we       = d_hold ? d_q_we  : in_d_we;
    assign dcpu.sel      = d_hold ? d_q_sel : in_d_sel;
    assign dcpu.dat_mosi = d_hold ? d_q_dat : in_d_dat;
    always_ff @(posedge clk) begin
        d_q_open <= !rst && dcpu.cyc && dcpu.stb && !dcpu.ack && !dcpu.err;
        d_q_we   <= dcpu.we;
        d_q_sel  <= dcpu.sel;
        d_q_adr  <= dcpu.adr;
        d_q_dat  <= dcpu.dat_mosi;
    end
