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
`ifdef HADES_ICACHE_BYTES
    // With caches (simulation only, see the memory system below) a RAM access may wait behind a
    // cache refill on the shared memory port, so the RAM (slave 0) is exempt from the bus
    // timeout; every other slave keeps it. The slave map is that of the instance in the else
    // branch below: keep both in step (only TIMEOUT_EXEMPT differs).
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
        }),
        .TIMEOUT_EXEMPT(9'b0_0000_0001)
    ) peripheral_bus_interconnect (
        .clk(clk),
        .rst(rst),
        .master(mem_bus),
        .slaves(mem_bus_slaves)
    );
`else
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
`endif

`ifdef HADES_ICACHE_BYTES
    // Simulation only (+define+HADES_ICACHE_BYTES, make ICACHE=<bytes>; docs/CACHES.md): an
    // instruction cache on the fetch bus, and one memory port that an arbiter shares between
    // the cache's refills and the data side (slave 0 of the interconnect, the RAM window), in
    // front of port A of the RAM through one slow-memory wrapper (sim/slow_memory.sv, which
    // gives the latencies of make MEM_LAT=...). Port B of the RAM is idle. The CPU-side buses
    // fetch_bus and mem_bus are unchanged. Synthesis never defines HADES_ICACHE_BYTES, and it
    // does not read rtl/cache/.
`ifdef HADES_CACHE_LINE_BYTES
    localparam int unsigned ICACHE_LINE_BYTES = `HADES_CACHE_LINE_BYTES;
`else
    localparam int unsigned ICACHE_LINE_BYTES = 16;
`endif

    wishbone_interface icache_mem();      // the I-cache's refill port
    logic              icache_mem_cont;   // ... its continuation tag
    wishbone_interface memory_port();     // the one memory port
    logic              memory_port_cont;  // ... its continuation tag
    wishbone_interface ram_port();        // port A of the RAM
    wishbone_interface ram_idle();        // port B of the RAM, never requested

    // The events of the I-cache and the arbiter (docs/CACHES.md lists their conditions). The
    // names and the conditions are fixed, so that other logic can count them; nothing in this
    // memory system reads them.
    logic cache_ev_i_hit;
    logic cache_ev_i_miss;
    logic cache_ev_i_beat;
    logic cache_ev_i_fill;
    logic cache_ev_i_abandoned;
    logic cache_ev_i_snoop_inval;
    logic cache_ev_wait_i;
    logic cache_ev_wait_d;
    logic cache_ev_grant_i;
    logic cache_ev_grant_d;
    logic cache_ev_port_load;
    logic cache_ev_port_store;
    logic cache_ev_i_refill;

    icache #(
        .BYTES(`HADES_ICACHE_BYTES),
        .LINE_BYTES(ICACHE_LINE_BYTES),
        .WINDOW_START(MEMORY_START),
        .WINDOW_WORDS(MEMORY_SIZE)
    ) icache (
        .clk(clk),
        .rst(rst),
        .cpu(fetch_bus.slave),
        .mem(icache_mem.master),
        .mem_cont(icache_mem_cont),
        // every store acknowledged at the RAM's port of the interconnect
        .snoop_store(mem_bus_slaves[0].cyc && mem_bus_slaves[0].stb && mem_bus_slaves[0].we && mem_bus_slaves[0].ack),
        .snoop_adr(mem_bus_slaves[0].adr),
        .ev_hit(cache_ev_i_hit),
        .ev_miss(cache_ev_i_miss),
        .ev_beat(cache_ev_i_beat),
        .ev_fill(cache_ev_i_fill),
        .ev_abandoned(cache_ev_i_abandoned),
        .ev_snoop_inval(cache_ev_i_snoop_inval),
        .ev_refill(cache_ev_i_refill)
    );

    mem_arbiter mem_arbiter (
        .clk(clk),
        .rst(rst),
        .data(mem_bus_slaves[0]),
        .irefill(icache_mem.slave),
        .irefill_cont(icache_mem_cont),
        .mem(memory_port.master),
        .mem_cont(memory_port_cont),
        .ev_wait_i(cache_ev_wait_i),
        .ev_wait_d(cache_ev_wait_d),
        .ev_grant_i(cache_ev_grant_i),
        .ev_grant_d(cache_ev_grant_d),
        .ev_port_load(cache_ev_port_load),
        .ev_port_store(cache_ev_port_store)
    );

    slow_memory #(
        .PORT("memory"),
        .INDEX(2)
    ) memory_delay (
        .clk(clk),
        .rst(rst),
        .master(memory_port.slave),
        .block_cont(memory_port_cont),
        .memory(ram_port.master)
    );

    assign ram_idle.cyc      = 1'b0;
    assign ram_idle.stb      = 1'b0;
    assign ram_idle.we       = 1'b0;
    assign ram_idle.adr      = 32'h0;
    assign ram_idle.sel      = 4'h0;
    assign ram_idle.dat_mosi = 32'h0;

    wishbone_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(ram_port.slave),
        .port_b(ram_idle.slave)
    );

`ifndef SYNTHESIS
`ifndef HADES_SLOW_MEM
    initial $fatal(1, "rtl/mcu.sv: HADES_ICACHE_BYTES needs HADES_SLOW_MEM as well (the testbench's memory checks and the latency options of sim/slow_memory.sv); make ICACHE=<bytes> defines both");
`endif
`ifdef HADES_MEM_SEED
    localparam int unsigned ICACHE_DEFAULT_SEED = `HADES_MEM_SEED;
`else
    localparam int unsigned ICACHE_DEFAULT_SEED = 1;
`endif

    // At time 0: the cacheable window must be the RAM's and the interconnect's slave 0's; then
    // the configuration line
    initial begin : cache_configuration
        int unsigned seed;
        if (icache.WINDOW_START != ram.ADDRESS || icache.WINDOW_WORDS != ram.SIZE ||
            icache.WINDOW_START != peripheral_bus_interconnect.SLAVE_ADDRESS[8*32 +: 32] ||
            icache.WINDOW_WORDS != peripheral_bus_interconnect.SLAVE_SIZE[8*32 +: 32])
            $fatal(1, "rtl/mcu.sv: the I-cache's window (word address 0x%08x, 0x%08x words) must be the RAM's (0x%08x, 0x%08x words) and the interconnect's slave 0's (0x%08x, 0x%08x words)",
                   icache.WINDOW_START, icache.WINDOW_WORDS, ram.ADDRESS, ram.SIZE,
                   peripheral_bus_interconnect.SLAVE_ADDRESS[8*32 +: 32], peripheral_bus_interconnect.SLAVE_SIZE[8*32 +: 32]);
        seed = ICACHE_DEFAULT_SEED;
        void'($value$plusargs("mem_seed=%d", seed));
        $display("CACHE I-cache %0d bytes, %0d-byte lines, %0d sets, direct-mapped; tag adr[29:%0d], index adr[%0d:%0d], word adr[%0d:0]; window 0x%08x-0x%08x; random initial arrays, seed %0d; one memory port, data side first; RAM exempt from the interconnect timeout",
                 icache.BYTES, icache.LINE_BYTES, icache.SETS, icache.O + icache.I, icache.O + icache.I - 1, icache.O,
                 icache.O - 1, icache.WINDOW_START << 2, ((icache.WINDOW_START + icache.WINDOW_WORDS) << 2) - 1, seed);
    end
`endif
`elsif HADES_SLOW_MEM
    // Simulation only (+define+HADES_SLOW_MEM, e.g. make MEM_LAT=2): wait states in front of
    // both RAM ports, see sim/slow_memory.sv. At latency 0 every signal passes unchanged.
    wishbone_interface ram_port_a();
    wishbone_interface ram_port_b();

    slow_memory #(
        .PORT("fetch"),
        .INDEX(0)
    ) fetch_memory_delay (
        .clk(clk),
        .rst(rst),
        .master(fetch_bus.slave),
        .block_cont(1'b1),
        .memory(ram_port_a.master)
    );

    slow_memory #(
        .PORT("data"),
        .INDEX(1)
    ) data_memory_delay (
        .clk(clk),
        .rst(rst),
        .master(mem_bus_slaves[0]),
        .block_cont(1'b1),
        .memory(ram_port_b.master)
    );

    wishbone_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(ram_port_a.slave),
        .port_b(ram_port_b.slave)
    );
`else
    wishbone_ram #(
        .ADDRESS(MEMORY_START),
        .SIZE(MEMORY_SIZE)
    ) ram (
        .clk(clk_mem),
        .rst(rst),
        .port_a(fetch_bus.slave),
        .port_b(mem_bus_slaves[0])
    );
`endif

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
