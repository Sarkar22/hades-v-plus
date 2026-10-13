// SPDX-License-Identifier: MIT
// =============================================================================================
// dpair_props.vh -- non-interference of the memory system with both caches with data values.
//
// formal/cache/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of harness/memsys_pair_top.sv. The two copies receive equal inputs except data
// values (memory's read data, the write data of the CPU's stores, the initial data-array
// contents). From the cycle after the first one, in every cycle (reset cycles included), they must
// produce equal ack and err on every port (fetch, the D-cache's CPU port, both caches' memory
// ports), equal request control signals of the memory port (cyc, stb, address, we, sel: all 0
// when idle) and of both caches' memory ports (cyc and stb; the address, we and sel while they
// request), equal continuation tags, equal grants and the 21 equal events: no handshake, grant,
// request or event depends on a data value.
// =============================================================================================
`ifdef FORMAL
`ifdef FSIM
`define F_AT @(posedge clk)
`else
`define F_AT @(*)
`endif
`ifdef CHECK_DDATA_INDEP
    always `F_AT if (!f_first) begin
        assert(fetch_a.ack == fetch_b.ack && fetch_a.err == fetch_b.err);
        assert(dcpu_a.ack == dcpu_b.ack && dcpu_a.err == dcpu_b.err);
        assert(dmem_a.ack == dmem_b.ack && dmem_a.err == dmem_b.err);
        assert(refill_a.ack == refill_b.ack && refill_a.err == refill_b.err);
        assert(refill_a.cyc == refill_b.cyc && refill_a.stb == refill_b.stb);
        if (refill_a.cyc && refill_a.stb)
            assert(refill_a.adr == refill_b.adr && refill_a.we == refill_b.we &&
                   refill_a.sel == refill_b.sel);
        assert(dmem_a.cyc == dmem_b.cyc && dmem_a.stb == dmem_b.stb);
        if (dmem_a.cyc && dmem_a.stb)
            assert(dmem_a.adr == dmem_b.adr && dmem_a.we == dmem_b.we && dmem_a.sel == dmem_b.sel);
        assert(mbus_a.cyc == mbus_b.cyc && mbus_a.stb == mbus_b.stb && mbus_a.adr == mbus_b.adr &&
               mbus_a.we == mbus_b.we && mbus_a.sel == mbus_b.sel);
        assert(refill_cont_a == refill_cont_b);
        assert(dmem_cont_a == dmem_cont_b);
        assert(mbus_cont_a == mbus_cont_b);
        assert(f_gd_a == f_gd_b && f_gi_a == f_gi_b);
        assert(ei_a == ei_b);
        assert(ed_a == ed_b);
        assert(ea_a == ea_b);
    end
`endif
`ifdef COVERS
    // the copies are compared through refills of both caches, store hits and load hits
    always `F_AT if (!f_first && !rst) begin
        cover(ed_a[3]);                         // a D-refill completes
        cover(ei_a[3]);                         // an I-refill completes
        cover(ed_a[4]);                         // a store hit
        cover(ed_a[0] && !ed_a[1] && !ed_a[7]); // a load answered from the arrays
    end
`endif
`endif
