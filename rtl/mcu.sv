/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: mcu.sv
 */



module mcu #(
    parameter real CLK_FREQUENCY_MHZ,
    parameter int  UART_BAUD_RATE
) (
    // Main system clk
    input logic clk,
    // Memory clock
    input logic clk_mem,
    // VGA pixel clock
    input logic clk_vga,

    // Switches
    input  logic [15:0] switches_async,

    // LEDs
    output logic [15:0] leds,

    // 7 Segment Display
    output logic [7:0] segments,
    output logic [3:0] segments_select,

    // Buttons (order: 4 - drluc- 0)
    input  logic [4:0] buttons_async,

    // VGA output
    output logic [3:0] vga_red,
    output logic [3:0] vga_blue,
    output logic [3:0] vga_green,
    output logic       vga_hsync,
    output logic       vga_vsync,

    // UART
    input  logic uart_rx_async,
    output logic uart_tx
);
    import constants::*;

    // --------------------------------------------------------------------------------------------
    // |                                     Synchronization                                      |
    // --------------------------------------------------------------------------------------------

    logic [4:0] buttons;
    for (genvar i = 0; i < 5; i++) begin: button_conditioning
        synchronizer button_sync(
            .clk(clk),
            .async_in(buttons_async[i]),
            .sync_out(buttons[i])
        );
    end

    logic [15:0] switches;
    for (genvar i = 0; i < 16; i++) begin: switch_conditioning
        synchronizer switch_sync(
            .clk(clk),
            .async_in(switches_async[i]),
            .sync_out(switches[i])
        );
    end

    logic uart_rx;
    synchronizer uart_rx_sync(
        .clk(clk),
        .async_in(uart_rx_async),
        .sync_out(uart_rx)
    );

    // --------------------------------------------------------------------------------------------
    // |                                           rst                                            |
    // --------------------------------------------------------------------------------------------

    // Use initial assignment to ensure initial reset after loading the configuration (FPGA only)
    logic rst = 1;

    // Use center button as reset
    always_ff @(posedge clk) begin
        rst <= buttons[0];
    end

    // --------------------------------------------------------------------------------------------
    // |                                           CPU                                            |
    // --------------------------------------------------------------------------------------------

    // Wishbone
    wishbone_interface fetch_bus();
    wishbone_interface mem_bus();

    // Interrupts    
    logic test_interrupt;
    logic uart_interrupt;
    logic timer_interrupt;

    logic external_interrupt;
    assign external_interrupt = |{
        uart_interrupt,
        test_interrupt
    };

    // Live mtime from the wishbone timer, fed to the core so the Zicntr TIME/TIMEH
    // CSRs shadow the real memory-mapped mtime (see wishbone_timer.mtime_out).
    logic [63:0] mtime;

    // Instantiate CPU
    // To run a test against the golden model instead, verilate with +define+USE_REF_CPU:
    // ref_cpu has a frozen port list with no mtime_in, so that pin is excluded and
    // TIME/TIMEH read 0 on the reference (it predates Zicntr).
`ifdef USE_REF_CPU
    ref_cpu cpu(
        .clk(clk),
        .rst(rst),
        .memory_fetch_port(fetch_bus.master),
        .memory_mem_port(mem_bus.master),
        .external_interrupt_in(external_interrupt),
        .timer_interrupt_in(timer_interrupt)
    );
`else
    cpu cpu(
        .clk(clk),
        .rst(rst),
        .memory_fetch_port(fetch_bus.master),
        .memory_mem_port(mem_bus.master),
        .external_interrupt_in(external_interrupt),
        .timer_interrupt_in(timer_interrupt),
        .mtime_in(mtime)
    );
`endif

    // --------------------------------------------------------------------------------------------
    // |                                       Peripherals                                        |
    // --------------------------------------------------------------------------------------------

    // Memory bus interconnect
    wishbone_interface mem_bus_slaves[9]();
    wishbone_interconnect #(
        .NUM_SLAVES(9),
        .SLAVE_ADDRESS({
            MEMORY_START,
            LEDS_START,
            BUTTONS_START,
            SWITCHES_START,
            SEGMENTS_START,
            UART_START,
            TIMER_START,
            VGA_START,
            TEST_START
        }),
        .SLAVE_SIZE({
            MEMORY_SIZE,
            LEDS_SIZE,
            BUTTONS_SIZE,
            SWITCHES_SIZE,
            SEGMENTS_SIZE,
            UART_SIZE,
            TIMER_SIZE,
            VGA_SIZE,
            TEST_SIZE
        })
    ) peripheral_bus_interconnect (
        .clk(clk),
        .rst(rst),
        .master(mem_bus),
        .slaves(mem_bus_slaves)
    );

    wishbone_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(fetch_bus.slave),
        .port_b(mem_bus_slaves[0])
    );

    wishbone_leds #(
        .ADDRESS(LEDS_START),
        .SIZE(LEDS_SIZE)
    ) wb_leds (
        .clk(clk),
        .rst(rst),
        .leds(leds),
        .wishbone(mem_bus_slaves[1])
    );

    wishbone_buttons #(
        .ADDRESS(BUTTONS_START),
        .SIZE(BUTTONS_SIZE)
    ) wb_buttons (
        .clk(clk),
        .rst(rst),
        .buttons(buttons),
        .wishbone(mem_bus_slaves[2])
    );

    wishbone_switches #(
        .ADDRESS(SWITCHES_START),
        .SIZE(SWITCHES_SIZE)
    ) wb_switches (
        .clk(clk),
        .rst(rst),
        .switches(switches),
        .wishbone(mem_bus_slaves[3])
    );

    wishbone_segments #(
        .ADDRESS(SEGMENTS_START),
        .SIZE(SEGMENTS_SIZE)
    ) wb_segments (
        .clk(clk),
        .rst(rst),
        .segments(segments),
        .segments_select(segments_select),
        .wishbone(mem_bus_slaves[4])
    );

    wishbone_uart #(
        .ADDRESS(UART_START),
        .SIZE(UART_SIZE),
        .BAUD_RATE(UART_BAUD_RATE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_uart (
        .clk(clk),
        .rst(rst),
        .rx_serial_in(uart_rx),
        .tx_serial_out(uart_tx),
        .interrupt(uart_interrupt),
        .wishbone(mem_bus_slaves[5])
    );

    wishbone_timer #(
        .ADDRESS(TIMER_START),
        .SIZE(TIMER_SIZE),
        .CLK_FREQUENCY_MHZ(CLK_FREQUENCY_MHZ)
    ) wb_timer (
        .clk(clk),
        .rst(rst),

        .interrupt(timer_interrupt),
        .mtime_out(mtime),

        .wishbone(mem_bus_slaves[6])
    );

    wishbone_vga #(
        .ADDRESS(VGA_START),
        .SIZE(VGA_SIZE)
    ) wb_vga (
        .clk(clk),
        .rst(rst),

        .clk_vga(clk_vga),

        .vga_vsync(vga_vsync),
        .vga_hsync(vga_hsync),
        .vga_r(vga_red),
        .vga_g(vga_green),
        .vga_b(vga_blue),

        .wishbone(mem_bus_slaves[7])
    );

    wishbone_test #(
        .ADDRESS(TEST_START),
        .SIZE(TEST_SIZE)
    ) wb_test (
        .clk(clk),
        .rst(rst),
        .interrupt(test_interrupt),
        .wishbone(mem_bus_slaves[8])
    );

endmodule
