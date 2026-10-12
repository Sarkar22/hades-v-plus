// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// interconnect_top.sv -- formal harness of the interconnect's timeout exemption.
//
// dut is lib/wishbone/wishbone_interconnect.sv of the tree under proof; base is the copy of the
// module before the exemption was added (formal/cache/wishbone_interconnect_base.sv, the base
// commit's file with only its module name changed). Both get the slave map of rtl/mcu.sv (nine
// slaves, slave 0 the RAM, the addresses and sizes of defines/constants.sv), the same reset, the
// same master request and the same slave answers. The first cycle is a reset; later resets, the
// master's request and every slave's answers are free inputs. props/interconnect_props.vh holds
// the properties. Macros (set by formal/cache/run.sh):
//   IC_DEFAULT     dut without a mask (its default); the master is free.
//   IC_RAM_EXEMPT  dut with the mask IC_MASK read from rtl/mcu.sv's cached branch; the master
//                  holds cyc, stb, address, we, sel and write data from the first cycle of a
//                  request until the cycle in which it gets ack or err (a reset cycle ends a
//                  request too: the request may change in the cycle after it), and so drops cyc
//                  only after an answer.
//   IC_IO_TIMEOUT  dut with that mask; the master is free except that it never selects slave 0
//                  (cyc is 0 whenever the address lies in the RAM window).
// ---------------------------------------------------------------------------------------------
module interconnect_top (
    input logic                 clk,
    input logic                 in_rst,
    input logic                 in_cyc,
    input logic                 in_stb,
    input logic                 in_we,
    input logic [3:0]           in_sel,
    input logic [31:0]          in_adr,
    input logic [31:0]          in_dat,
    input logic [8:0]           in_s_ack,
    input logic [8:0]           in_s_err,
    input logic [32*9-1:0]      in_s_dat
);
    import constants::*;

    logic f_first = 1'b1;
    always_ff @(posedge clk) f_first <= 1'b0;
    wire  rst = in_rst || f_first;

    localparam bit [32*9-1:0] F_ADDRESS = {MEMORY_START, LEDS_START, BUTTONS_START,
        SWITCHES_START, SEGMENTS_START, UART_START, TIMER_START, VGA_START, TEST_START};
    localparam bit [32*9-1:0] F_SIZE = {MEMORY_SIZE, LEDS_SIZE, BUTTONS_SIZE, SWITCHES_SIZE,
        SEGMENTS_SIZE, UART_SIZE, TIMER_SIZE, VGA_SIZE, TEST_SIZE};

    wishbone_interface m_dut();
    wishbone_interface s_dut[9]();
    wishbone_interface m_base();
    wishbone_interface s_base[9]();

    // ---- the master ----
    logic        q_open, q_cyc, q_stb, q_we;
    logic [3:0]  q_sel;
    logic [31:0] q_adr, q_dat;
    wire         in_ram = in_adr >= MEMORY_START && in_adr < MEMORY_START + MEMORY_SIZE;
`ifdef IC_RAM_EXEMPT
    wire         hold = q_open;
    wire         cyc  = hold ? q_cyc : in_cyc;
`elsif IC_IO_TIMEOUT
    wire         hold = 1'b0;
    wire         cyc  = in_cyc && !in_ram;
`else
    wire         hold = 1'b0;
    wire         cyc  = in_cyc;
`endif
    wire         stb = hold ? q_stb : in_stb;
    wire         we  = hold ? q_we  : in_we;
    wire  [3:0]  sel = hold ? q_sel : in_sel;
    wire  [31:0] adr = hold ? q_adr : in_adr;
    wire  [31:0] dat = hold ? q_dat : in_dat;
    always_ff @(posedge clk) begin
        q_open <= !rst && cyc && stb && !m_dut.ack && !m_dut.err;
        q_cyc  <= cyc;
        q_stb  <= stb;
        q_we   <= we;
        q_sel  <= sel;
        q_adr  <= adr;
        q_dat  <= dat;
    end
    assign m_dut.cyc  = cyc;  assign m_base.cyc  = cyc;
    assign m_dut.stb  = stb;  assign m_base.stb  = stb;
    assign m_dut.we   = we;   assign m_base.we   = we;
    assign m_dut.sel  = sel;  assign m_base.sel  = sel;
    assign m_dut.adr  = adr;  assign m_base.adr  = adr;
    assign m_dut.dat_mosi = dat;  assign m_base.dat_mosi = dat;

    // ---- the slaves' answers: free, the same for both ----
    for (genvar k = 0; k < 9; k++) begin : answers
        assign s_dut[k].ack       = in_s_ack[k];
        assign s_dut[k].err       = in_s_err[k];
        assign s_dut[k].dat_miso  = in_s_dat[32*k +: 32];
        assign s_base[k].ack      = in_s_ack[k];
        assign s_base[k].err      = in_s_err[k];
        assign s_base[k].dat_miso = in_s_dat[32*k +: 32];
    end

    wishbone_interconnect #(
        .NUM_SLAVES(9), .SLAVE_ADDRESS(F_ADDRESS), .SLAVE_SIZE(F_SIZE)
`ifdef IC_MASK
        , .TIMEOUT_EXEMPT(`IC_MASK)
`endif
    ) dut (.clk(clk), .rst(rst), .master(m_dut), .slaves(s_dut));

    wishbone_interconnect_base #(
        .NUM_SLAVES(9), .SLAVE_ADDRESS(F_ADDRESS), .SLAVE_SIZE(F_SIZE)
    ) base (.clk(clk), .rst(rst), .master(m_base), .slaves(s_base));
endmodule
