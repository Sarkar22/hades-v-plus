// SPDX-License-Identifier: MIT
// =============================================================================================
// pair_props.vh -- non-interference of the I-cache and the arbiter with data values.
//
// formal/cache/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of harness/cache_pair_top.sv. The two copies receive equal inputs except data
// values (memory's read data, the data side's write data, the initial data-array contents).
// From the cycle after the first one, in every cycle (reset cycles included), they must produce
// equal ack and err on every port, equal request control signals of the memory port (cyc, stb,
// address, we, sel: all 0 when idle) and of the I-cache's refill port (cyc and stb; the address,
// we and sel while it requests), equal continuation tags, equal grants and equal events: no
// handshake, grant, request or event depends on a data value.
// =============================================================================================
`ifdef FORMAL
`ifdef FSIM
`define F_AT @(posedge clk)
`else
`define F_AT @(*)
`endif
`ifdef CHECK_DATA_INDEP
    always `F_AT if (!f_first) begin
        assert(fetch_a.ack == fetch_b.ack && fetch_a.err == fetch_b.err);
        assert(dbus_a.ack == dbus_b.ack && dbus_a.err == dbus_b.err);
        assert(refill_a.ack == refill_b.ack && refill_a.err == refill_b.err);
        assert(refill_a.cyc == refill_b.cyc && refill_a.stb == refill_b.stb);
        if (refill_a.cyc && refill_a.stb)
            assert(refill_a.adr == refill_b.adr && refill_a.we == refill_b.we &&
                   refill_a.sel == refill_b.sel);
        assert(mbus_a.cyc == mbus_b.cyc && mbus_a.stb == mbus_b.stb && mbus_a.adr == mbus_b.adr &&
               mbus_a.we == mbus_b.we && mbus_a.sel == mbus_b.sel);
        assert(refill_cont_a == refill_cont_b);
        assert(mbus_cont_a == mbus_cont_b);
        assert(f_gd_a == f_gd_b && f_gi_a == f_gi_b);
        assert(ei_a == ei_b);
        assert(ea_a == ea_b);
    end
`endif
`ifdef COVERS
    // the copies are compared through refills, hits and data transfers
    always `F_AT if (!f_first && !rst) begin
        cover(ei_a[3]);                 // a refill completes
        cover(ei_a[0] && f_gd_a);       // a hit while a data transfer is granted
        cover(dbus_a.ack && dbus_a.we); // a store is answered
    end
`endif
`endif
