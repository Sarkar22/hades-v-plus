/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: top.sv
 */



module top;
    import clk_params::*;

    integer error_count = 0;

    /* verilator lint_off unusedsignal */
    logic        clk;
    logic        clk_vga;
    logic [15:0] switches_async = 0;
    logic [15:0] leds;
    logic  [7:0] segments;
    logic  [3:0] segments_select;
    logic  [4:0] buttons_async = 0;
    logic  [3:0] vga_red;
    logic  [3:0] vga_blue;
    logic  [3:0] vga_green;
    logic        vga_hsync;
    logic        vga_vsync;
    logic        uart_rx_async = 1;
    logic        uart_tx;
    /* verilator lint_on unusedsignal */
    mcu #(
        .CLK_FREQUENCY_MHZ(SYS_CLK_FREQUENCY_MHZ),
        .UART_BAUD_RATE( int'((SYS_CLK_FREQUENCY_MHZ*1_000_000) / 15) )
    ) mcu (
        .clk(clk),
        .clk_mem(~clk),
        .clk_vga(clk_vga),
        .switches_async(switches_async),
        .leds(leds),
        .segments(segments),
        .segments_select(segments_select),
        .buttons_async(buttons_async),
        .vga_red(vga_red),
        .vga_blue(vga_blue),
        .vga_green(vga_green),
        .vga_hsync(vga_hsync),
        .vga_vsync(vga_vsync),
        .uart_rx_async(uart_rx_async),
        .uart_tx(uart_tx)
    );

    // System clock
    initial begin
        clk = 1;
        forever begin
            #(int'(SIM_CYCLES_PER_SYS_CLK / 2));
            clk = ~clk;
        end
    end

    // VGA pixel clock
    initial begin
        clk_vga = 1;
        forever begin
            #(int'(SIM_CYCLES_PER_VGA_CLK / 2));
            clk_vga = ~clk_vga;
        end
    end

    // Simulation run-time options (all optional; the defaults reproduce the
    // original behaviour exactly, so existing tests are unaffected):
    //   +timeout=<cycles>   cycle limit before "Simulation timeout!" (default 100000)
    //   +nodump             do not write sim.fst (long runs would produce huge traces)
    //   +switches=<hex>     drive the 16 board switches (e.g. a per-run seed for software)
    //   +trace              print the architectural trace port and the UART bytes
    //                       (TRACE / UARTCHAR lines, used by test/trapsweep)
    longint unsigned timeout_cycles = 100000;

    initial begin
        void'($value$plusargs("timeout=%d", timeout_cycles));
        void'($value$plusargs("switches=%h", switches_async));

        if (!$test$plusargs("nodump")) begin
            $dumpfile("sim.fst");
            $dumpvars;
        end

        // Run for timeout_cycles cycles max
        for (longint unsigned cycle = 0; cycle < timeout_cycles; cycle++) @(negedge clk);

        // Stop simulation
        $display("\033[0;33m"); // color_orange
        $display("Simulation timeout!");
        $display("\033[0m"); // color off
        $finish();
    end

    // ---- Architectural trace port (test/trapsweep; enabled with +trace) ----
    // Every completed store to byte addresses [0x47E00, 0x47F00) is printed as
    // "TRACE <cycle> <offset> <data>". Works identically for cpu and ref_cpu
    // because it snoops the memory bus, not the core. Passive: without +trace
    // nothing is printed and the simulation is unchanged.
    bit              trace_en;      // 2-state: 0 until the initial block runs
    longint unsigned trace_cycle;   // 2-state: starts at 0
    initial trace_en = $test$plusargs("trace");
    always @(posedge clk) begin
        trace_cycle <= trace_cycle + 1;
        if (trace_en && mcu.mem_bus.cyc && mcu.mem_bus.stb && mcu.mem_bus.we && mcu.mem_bus.ack
            && mcu.mem_bus.adr >= 32'h0001_1F80 && mcu.mem_bus.adr < 32'h0001_1FC0)
            $display("TRACE %0d %03x %08x", trace_cycle, 10'((mcu.mem_bus.adr - 32'h0001_1F80) << 2), mcu.mem_bus.dat_mosi);
    end

    // UART transmit snoop (+trace): print each byte written to the UART
    // data register as "UARTCHAR <char>" so per-iteration test verdicts are visible in the log.
    always @(posedge clk) begin
        if (trace_en && mcu.mem_bus.cyc && mcu.mem_bus.stb && mcu.mem_bus.we && mcu.mem_bus.ack
            && mcu.mem_bus.adr == 32'h0008_4000 && mcu.mem_bus.sel[0])
            $display("UARTCHAR %0d %c", trace_cycle, mcu.mem_bus.dat_mosi[7:0]);
    end

    // Respond to test interface
    always @(posedge clk) begin
        if (mcu.wb_test.test_stb) begin
            case (mcu.wb_test.test_reg)
                0: $display("(%6d ps) Test pass!", $time());
                1: begin
                    $display("(%6d ps) Test fail!", $time());
                    error_count <= error_count + 1;
                end
                2: begin
                    $finish();
                    print_test_done();
                end
            endcase
        end
    end

    // --------------------------------------------------------------------------------------------
    // print helper functions
    function void print_test_done();
        if (error_count == 0) begin
            $display("\033[0;33m"); // color_orange
            $display("Inital test failed! (# Errors: %1d)", error_count);
        end
        else if (error_count > 1) begin
            $display("\033[0;31m"); // color_red
            $display("Some test(s) failed! (# Errors: %1d)", error_count);
        end
        else begin
            $display("\033[0;32m"); // color green
            $display("All tests passed! (# Errors: %1d = initial test)", error_count);
        end
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("\033[0m"); // color off
    endfunction
endmodule
