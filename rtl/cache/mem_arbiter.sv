// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// mem_arbiter.sv -- one memory port shared by the data side and the I-cache's refills.
//
// Simulation only, like the caches (rtl/mcu.sv, +define+HADES_ICACHE_BYTES): the data side is
// the RAM's port of the data-bus interconnect (it requests only for addresses in the RAM
// window: the interconnect raises stb there only for those) or, with a D-cache
// (+define+HADES_DCACHE_BYTES), the D-cache's memory port, which carries its refill reads and
// its store writes; the other side is the I-cache's refill port. docs/CACHES.md describes the
// design.
//
// Rules (d_req, i_req: cyc && stb of the data and the refill side; owner: who holds the port):
//   - Data first: on a free port a data request is granted in the cycle it is made, the
//     I-cache only when the data side does not request in that cycle. A same-cycle grant, so
//     an access on an idle port takes exactly as long as without the arbiter.
//   - A grant is never taken away: a data grant lasts until its transfer is answered, an
//     I-refill grant until its block ends, which is the first cycle in which the I-cache does
//     not request (the port is free in that cycle). No fairness state.
//   - A D-refill block is never interrupted: each beat is a data transfer of its own, the port
//     is free after each answered beat, and the D-cache requests the next beat in the next
//     cycle, which data first grants at once (checked below: a continuing data beat is granted).
//   - The granted side's request reaches the memory unchanged and once; the answer (ack, err,
//     dat_miso) goes to the granted side only; the other side sees ack = err = 0 and
//     dat_miso = 0. An idle port is all zeros. An answer in a cycle without a grant reaches
//     no side (and stops a simulation).
//   - So no memory write can happen inside an I-refill block, and a store is never
//     acknowledged while an I-refill holds the port.
//   - mem_cont is the continuation tag of the granted side: the I-cache's (irefill_cont) while
//     the I-cache is granted, the data side's (data_cont: the D-cache's refill beats 1 and
//     later; 0 without a D-cache) while the data side is granted, else 0.
// The memory side is a plain Wishbone block port (plus that simulation-only tag): nothing
// here assumes when the memory answers, or that it drops a request at a reset.
// Events (ev_*): outputs only, 0 in cycles with rst = 1; rtl/mcu.sv names them cache_ev_*.
// ---------------------------------------------------------------------------------------------

module mem_arbiter (
    input  logic clk,
    input  logic rst,

    wishbone_interface.slave  data,           // the RAM's port of the interconnect, or the D-cache's memory port
    input  logic              data_cont,      // the data side's continuation tag (tie to 0 without a D-cache)
    wishbone_interface.slave  irefill,        // the I-cache's refill port
    input  logic              irefill_cont,   // the I-cache's continuation tag
    wishbone_interface.master mem,            // the memory port
    output logic              mem_cont,       // the continuation tag of the granted side

    output logic              ev_wait_i,      // the I-refill waits: the data side holds the port
    output logic              ev_wait_d,      // the data side waits: an I-refill holds the port
    output logic              ev_grant_i,     // a cycle of the port used by an I-refill
    output logic              ev_grant_d,     // a cycle of the port used by a data transfer
    output logic              ev_port_load,   // a load answered on the memory port
    output logic              ev_port_store   // a store answered on the memory port
);
    // Who holds the port across cycles, as named constants (sim/top.sv and the formal harness
    // compare with them)
    localparam logic [1:0] NONE    = 2'd0;
    localparam logic [1:0] DATA    = 2'd1;
    localparam logic [1:0] IREFILL = 2'd2;

    logic [1:0] owner;

    logic d_req, i_req, free, gd, gi;

    assign d_req = data.cyc && data.stb;
    assign i_req = irefill.cyc && irefill.stb;
    assign free  = owner == NONE || (owner == IREFILL && !i_req);
    assign gd    = d_req && (owner == DATA || free);                // data granted
    assign gi    = i_req && (owner == IREFILL || (free && !d_req));  // I-cache granted

    // The memory request: the granted side's, or idle
    assign mem.cyc      = gd || gi;
    assign mem.stb      = gd || gi;
    assign mem.adr      = gd ? data.adr      : gi ? irefill.adr      : 32'h0;
    assign mem.sel      = gd ? data.sel      : gi ? irefill.sel      : 4'h0;
    assign mem.we       = gd ? data.we       : gi ? irefill.we       : 1'b0;
    assign mem.dat_mosi = gd ? data.dat_mosi : gi ? irefill.dat_mosi : 32'h0;
    assign mem_cont     = (gi && irefill_cont) || (gd && data_cont);

    // The answer, to the granted side only
    assign data.ack         = gd && mem.ack;
    assign data.err         = gd && mem.err;
    assign data.dat_miso    = gd ? mem.dat_miso : 32'h0;
    assign irefill.ack      = gi && mem.ack;
    assign irefill.err      = gi && mem.err;
    assign irefill.dat_miso = gi ? mem.dat_miso : 32'h0;

    always_ff @(posedge clk) begin
        if (rst)
            owner <= NONE;
        else if (gd)
            owner <= (mem.ack || mem.err) ? NONE : DATA;
        else if (gi)
            owner <= IREFILL;
        else
            owner <= NONE;
    end

    assign ev_wait_i     = !rst && i_req && !gi;
    assign ev_wait_d     = !rst && d_req && !gd;
    assign ev_grant_i    = !rst && gi;
    assign ev_grant_d    = !rst && gd;
    assign ev_port_load  = !rst && gd && mem.ack && !data.we;
    assign ev_port_store = !rst && gd && mem.ack && data.we;

`ifndef SYNTHESIS
    // --------------------------------------------------------------------------------------------
    // |                                 Simulation: run-time checks                              |
    // --------------------------------------------------------------------------------------------

    // Sampled at the rising edge (the values at the end of the cycle), not in cycles with
    // rst = 1, and their history is cleared by a reset. The cycle is counted as sim/top.sv
    // counts it.
    longint unsigned sim_cycle;

    // The granted data request that was not answered, which must be presented again unchanged
    logic        d_held;
    logic [31:0] d_held_adr, d_held_dat;
    logic  [3:0] d_held_sel;
    logic        d_held_we;
    // The I-cache was granted in an earlier cycle and has requested ever since: its refill
    // block holds the port
    logic        i_block;

    always @(posedge clk) begin
        sim_cycle <= sim_cycle + 1;
        if (rst) begin
            d_held  <= 1'b0;
            i_block <= 1'b0;
        end
        else begin
            if (mem.ack && mem.err)
                $fatal(1, "mem_arbiter: ack and err together on the memory port at cycle %0d, address 0x%08x",
                       sim_cycle, mem.adr << 2);
            if (data.ack && data.err)
                $fatal(1, "mem_arbiter: ack and err together on the data port at cycle %0d, address 0x%08x",
                       sim_cycle, data.adr << 2);
            if (irefill.ack && irefill.err)
                $fatal(1, "mem_arbiter: ack and err together on the refill port at cycle %0d, address 0x%08x",
                       sim_cycle, irefill.adr << 2);
            if ((data.ack || data.err) && !d_req)
                $fatal(1, "mem_arbiter: an answer without cyc && stb on the data port at cycle %0d (ack=%0d err=%0d)",
                       sim_cycle, data.ack, data.err);
            if ((irefill.ack || irefill.err) && !i_req)
                $fatal(1, "mem_arbiter: an answer without cyc && stb on the refill port at cycle %0d (ack=%0d err=%0d)",
                       sim_cycle, irefill.ack, irefill.err);
            if ((mem.ack || mem.err) && !gd && !gi)
                $fatal(1, "mem_arbiter: the memory answered at cycle %0d (ack=%0d err=%0d), but no side is granted",
                       sim_cycle, mem.ack, mem.err);
            if (i_block && i_req && mem.cyc && mem.stb && mem.we)
                $fatal(1, "mem_arbiter: a memory write at cycle %0d, address 0x%08x, while an I-refill block holds the port",
                       sim_cycle, mem.adr << 2);
            if (d_held && !(d_req && data.adr == d_held_adr && data.sel == d_held_sel && data.we == d_held_we &&
                            (!data.we || data.dat_mosi == d_held_dat)))
                $fatal(1, "mem_arbiter: the granted data request (address 0x%08x sel=%04b we=%0d data 0x%08x) changed before its answer, at cycle %0d",
                       d_held_adr << 2, d_held_sel, d_held_we, d_held_dat, sim_cycle);
            if (data_cont && d_req && !gd)
                $fatal(1, "mem_arbiter: a continuing data beat was not granted at cycle %0d, address 0x%08x (a D-refill block must not be interrupted)",
                       sim_cycle, data.adr << 2);

            d_held     <= gd && !mem.ack && !mem.err;
            d_held_adr <= data.adr;
            d_held_sel <= data.sel;
            d_held_we  <= data.we;
            d_held_dat <= data.dat_mosi;
            i_block    <= i_req && (gi || i_block);
        end
    end
`endif

endmodule
