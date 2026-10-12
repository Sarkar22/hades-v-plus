// SPDX-License-Identifier: MIT
// =============================================================================================
// interconnect_props.vh -- properties of the interconnect's timeout exemption.
//
// formal/cache/run.sh inserts this file, as one include line, before the final endmodule of the
// sv2v output of harness/interconnect_top.sv; sv2v puts both interconnects inside that module,
// so their internal names are visible as dut.<name> and base.<name>. Everything is checked from
// the cycle after the first one (the first cycle is the common reset).
//
// CHECK_IC_EQUAL (with IC_DEFAULT or IC_IO_TIMEOUT): dut and base have equal outputs (the
//   master's ack, err and read data; every slave's cyc, stb, address, sel, we and write data)
//   and equal timeout counters in every cycle. The equal counters are the invariant that makes
//   the proof by induction unbounded.
// CHECK_IC_RAM_EXEMPT (with IC_RAM_EXEMPT): the timeout never fires while slave 0 is selected,
//   and the counter is 0 in every cycle in which slave 0 is selected.
// =============================================================================================
`ifdef FORMAL
    wire f_check = !f_first;

`ifdef CHECK_IC_EQUAL
    always @(*) if (f_check) begin
        assert(m_dut.ack == m_base.ack);
        assert(m_dut.err == m_base.err);
        assert(m_dut.dat_miso == m_base.dat_miso);
        assert(dut.count == base.count);
    end
    genvar f_k;
    generate
        for (f_k = 0; f_k < 9; f_k = f_k + 1) begin : f_slave
            always @(*) if (f_check) begin
                assert(s_dut[f_k].cyc == s_base[f_k].cyc);
                assert(s_dut[f_k].stb == s_base[f_k].stb);
                assert(s_dut[f_k].adr == s_base[f_k].adr);
                assert(s_dut[f_k].sel == s_base[f_k].sel);
                assert(s_dut[f_k].we == s_base[f_k].we);
                assert(s_dut[f_k].dat_mosi == s_base[f_k].dat_mosi);
            end
        end
    endgenerate
`endif

`ifdef CHECK_IC_RAM_EXEMPT
    always @(*) if (f_check) begin
        assert(!(dut.timeout && dut.select[0]));
        if (dut.select[0]) assert(dut.count == 8'd0);
    end
`endif

`ifdef COVERS
    // a slave-0 request held for 256 cycles: one more than the timeout allows without the mask
    reg [8:0] f_ram_wait;
    always @(posedge clk)
        f_ram_wait <= (!rst && dut.select[0] && m_dut.stb && !m_dut.ack && !m_dut.err)
                      ? f_ram_wait + 9'd1 : 9'd0;
    always @(*) if (f_check && !rst) begin
`ifdef IC_RAM_EXEMPT
        cover(f_ram_wait == 9'd256);                 // a RAM access waits 256 cycles, no timeout
`else
        cover(dut.timeout);                          // an I/O access still times out
`endif
    end
`endif
`endif
