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
    logic        uart_rx_async`ifndef HADES_CONSOLE = 1`endif;   // console variant: see its block below
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

`ifdef HADES_CONSOLE
    // ---- Console bridge (only in simulators verilated with +define+HADES_CONSOLE) ----
    // Connects the UART to the terminal the simulator runs in, to a pseudo-terminal, or
    // to a command script; the host side is sim/console.cpp (DPI-C), the make targets
    // are freertos-shell, freertos-shell-test, freertos-shell-compare and
    // freertos-shell-tty-test (docs/FREERTOS.md). The default simulator does not
    // contain this block.
    //
    // Input: every CON_POLL_CYCLES, in every state of the injector below, console_poll()
    // reads whatever input has arrived into a queue on the host side and looks for the
    // quit key (Ctrl-]), so that the simulation can always be ended, also when the program
    // has stopped reading the UART.
    // Receive: each input character is shifted into the RX pin as a real 8N1 frame,
    // 16 clock cycles per bit, which is the receiver's sampling interval (uart_rx
    // samples every CLKS_PER_BIT + 1 = 16 cycles at the simulation baud rate of
    // sys_clk/15), so every bit is sampled in its middle. The injection is paced like a
    // careful typist: the next frame starts only after the program has read the
    // previous character out of the UART's one-byte receive buffer, at least
    // CON_QUIET_CYCLES later, and once the program's own output has paused for
    // CON_QUIET_CYCLES. (A program echoes each character, and at this baud rate a
    // character arrives faster than a program can take it from its interrupt handler,
    // echo it and wait for the next one: a pasted line, unpaced, would overflow the
    // program's receive queue.) While the program prints without a pause, a character
    // still goes through every CON_MAX_WAIT cycles. sim/console.cpp adds the line level:
    // after Enter, the rest of a script or a paste waits for the program's next prompt.
    // Transmit: sim/console.cpp sees every byte written to the transmit buffer (the
    // same event wishbone_uart.sv echoes to stdout) and needs it for the pseudo-terminal
    // and for the prompt detection.
    // Run options: +console_pty, +console_pty_link=<path>, +console_script=<file>,
    // +console_log=<file>, +console_prompt=<text>; see sim/console.cpp.
    import "DPI-C" function void console_init(input string mode, input string script_file,
                                              input string pty_link, input string log_file,
                                              input string prompt);
    import "DPI-C" function int  console_poll(input longint cycle);
    import "DPI-C" function int  console_next_byte(input longint cycle);
    import "DPI-C" function void console_tx(input int c, input longint cycle);
    import "DPI-C" function void console_close();

    localparam int CON_BIT_CYCLES   = 16;      // one bit on the RX line
    localparam int CON_POLL_CYCLES  = 64;      // console_poll() interval; injector retry interval
    localparam int CON_QUIET_CYCLES = 512;     // pause between characters, and in the output
    localparam int CON_MAX_WAIT     = 65536;   // ... or the character has waited this long

    typedef enum bit [1:0] { CON_IDLE, CON_FRAME, CON_DRAIN } con_state_t;
    con_state_t con_state;                 // 2-state types: all start at 0 (CON_IDLE)
    bit   [9:0] con_frame;                 // stop bit, 8 data bits (LSB first), start bit
    bit         con_rx_low;                // the RX line is driven low (0: idle, high)
    int         con_bit;                   // bit of con_frame on the line
    int         con_timer;                 // cycles left of the current bit or wait
    int         con_poll;                  // cycles until the next console_poll()
    int         con_quiet;                 // cycles since the program last wrote to the UART
    int         con_waited;                // cycles since the RX line became free

    // In this variant the bridge drives the RX line (whose declaration has no initial
    // value here); con_rx_low starts at 0, so the line is idle (high) from time 0 on.
    assign uart_rx_async = !con_rx_low;

    initial begin
        string mode, script_file, pty_link, log_file, prompt;
        mode = "stdio";
        script_file = "";
        pty_link = "";
        log_file = "";
        prompt = "hades> ";
        if ($test$plusargs("console_pty")) mode = "pty";
        if ($value$plusargs("console_script=%s", script_file)) mode = "script";
        void'($value$plusargs("console_pty_link=%s", pty_link));
        void'($value$plusargs("console_log=%s", log_file));
        void'($value$plusargs("console_prompt=%s", prompt));
        console_init(mode, script_file, pty_link, log_file, prompt);
    end

    always @(posedge clk) begin
        int c;

        if (mcu.wb_uart.wb_write_tx_buffer) begin
            console_tx(int'(mcu.wb_uart.wb_dat_mosi[7:0]), longint'(trace_cycle));
            con_quiet <= 0;
        end
        else if (con_quiet < CON_QUIET_CYCLES) begin
            con_quiet <= con_quiet + 1;
        end

        if (con_poll > 0) begin
            con_poll <= con_poll - 1;
        end
        else begin
            con_poll <= CON_POLL_CYCLES - 1;
            if (console_poll(longint'(trace_cycle)) < 0)
                $finish();                                 // quit key
        end

        case (con_state)
            CON_IDLE: begin
                if (con_waited < CON_MAX_WAIT)
                    con_waited <= con_waited + 1;
                if (con_timer > 0) begin
                    con_timer <= con_timer - 1;
                end
                else if ((con_waited >= CON_QUIET_CYCLES && con_quiet >= CON_QUIET_CYCLES) ||
                         con_waited >= CON_MAX_WAIT) begin
                    con_timer <= CON_POLL_CYCLES - 1;
                    c = console_next_byte(longint'(trace_cycle));
                    if (c >= 0) begin
                        con_frame  <= {1'b1, c[7:0], 1'b0};
                        con_rx_low <= 1'b1;                // start bit
                        con_bit    <= 0;
                        con_timer  <= CON_BIT_CYCLES - 1;
                        con_state  <= CON_FRAME;
                    end
                    else if (c == -2) begin
                        $finish();                         // end of the script or of the input
                    end
                end
            end
            CON_FRAME: begin
                if (con_timer > 0) begin
                    con_timer <= con_timer - 1;
                end
                else if (con_bit == 9) begin               // stop bit done: one more idle bit
                    con_timer <= CON_BIT_CYCLES - 1;
                    con_state <= CON_DRAIN;
                end
                else begin
                    con_rx_low <= !con_frame[con_bit + 1];
                    con_bit    <= con_bit + 1;
                    con_timer  <= CON_BIT_CYCLES - 1;
                end
            end
            CON_DRAIN: begin                               // until the program has read it
                if (con_timer > 0) begin
                    con_timer <= con_timer - 1;
                end
                else if (!mcu.wb_uart.rx_buffer_full) begin
                    con_timer  <= 0;
                    con_waited <= 0;
                    con_state  <= CON_IDLE;
                end
            end
            default: con_state <= CON_IDLE;
        endcase
    end

    final console_close();
`endif
endmodule
