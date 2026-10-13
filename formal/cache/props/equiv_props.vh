// SPDX-License-Identifier: MIT
// =============================================================================================
// equiv_props.vh -- the arbiter of the tree with data_cont = 0 equals the arbiter of the base
// commit (harness/arbiter_equiv_top.sv). formal/cache/run.sh inserts this file, as one include
// line, before the final endmodule of the sv2v output of that harness.
//
// From the cycle after the first one (a common reset), in every cycle, reset cycles included:
// equal memory requests (cyc, stb, address, sel, we, write data) and continuation tags, equal
// answers on both slave sides (ack, err, read data), equal events, and the same owner (compared
// by the names of the owner constants, which the observer of each copy gives). Each owner is one
// of its three named values: this, with the equal owners, is the invariant of the induction.
// CHECK_ARB_EQUIV turns the assertions on; COVERS a cover that the copies are compared through a
// data transfer and a refill block.
// =============================================================================================
`ifdef FORMAL
    wire f_check = !f_first;
`ifdef CHECK_ARB_EQUIV
    always @(*) if (f_check) begin
        assert(dut.f_obs_owner_none + dut.f_obs_owner_data + dut.f_obs_owner_irefill == 2'd1);
        assert(base.f_obs_owner_none + base.f_obs_owner_data + base.f_obs_owner_irefill == 2'd1);
        assert(dut.f_obs_owner_none == base.f_obs_owner_none);
        assert(dut.f_obs_owner_data == base.f_obs_owner_data);
        assert(dut.f_obs_owner_irefill == base.f_obs_owner_irefill);
        assert(mem_t.cyc == mem_b.cyc && mem_t.stb == mem_b.stb && mem_t.adr == mem_b.adr &&
               mem_t.sel == mem_b.sel && mem_t.we == mem_b.we && mem_t.dat_mosi == mem_b.dat_mosi);
        assert(cont_t == cont_b);
        assert(data_t.ack == data_b.ack && data_t.err == data_b.err &&
               data_t.dat_miso == data_b.dat_miso);
        assert(refill_t.ack == refill_b.ack && refill_t.err == refill_b.err &&
               refill_t.dat_miso == refill_b.dat_miso);
        assert(ev_t == ev_b);
    end
`endif
`ifdef COVERS
    reg f_c_seen_data;
    always @(posedge clk) f_c_seen_data <= !rst && (f_c_seen_data || (ev_t[3] && mem_t.ack));
    always @(*) if (f_check && !rst) begin
        cover(f_c_seen_data && ev_t[2] && in_i_cont && cont_t);   // a data transfer, then a refill beat
    end
`endif
`endif
