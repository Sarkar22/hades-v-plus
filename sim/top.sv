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
    // +console_log=<file>, +console_prompt=<text>; see sim/console.cpp. +console_pace=<n>
    // makes the pauses below n times longer (see con_pace).
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
    // The pauses assume that the program takes each character out of its receive queue
    // before the next one arrives (the shell's queue holds 64). A slow memory
    // (sim/slow_memory.sv) makes the program up to 1 + its longest wait times slower, and a
    // long line would overflow the queue; so with a slow memory the pauses are that many
    // times longer. +console_pace=<n> sets the factor (1 to 32767; 1: the pace of the standard
    // simulator).
    // With caches (+define+HADES_ICACHE_BYTES) the default factor is 2 + the longest read,
    // write or (in burst mode) beat wait of the one memory port: one more than without
    // caches, since a miss costs a whole refill.
    int         con_pace;                  // the pauses are con_pace times longer

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
        con_pace = 1;
`ifdef HADES_ICACHE_BYTES
        @(posedge clk);                    // the memory wrapper has read its options by now
        con_pace = 2 + int'(mcu.memory_delay.rd_max);
        if (2 + int'(mcu.memory_delay.wr_max) > con_pace) con_pace = 2 + int'(mcu.memory_delay.wr_max);
        if (2 + mcu.memory_delay.beat_lat > con_pace) con_pace = 2 + mcu.memory_delay.beat_lat;
`elsif HADES_SLOW_MEM
        @(posedge clk);                    // the slow memories have read their options by now
        con_pace = 1 + int'(mcu.fetch_memory_delay.rd_max);
        if (1 + int'(mcu.data_memory_delay.rd_max) > con_pace) con_pace = 1 + int'(mcu.data_memory_delay.rd_max);
        if (1 + int'(mcu.data_memory_delay.wr_max) > con_pace) con_pace = 1 + int'(mcu.data_memory_delay.wr_max);
        if (1 + int'(mcu.fetch_memory_delay.beat_lat) > con_pace) con_pace = 1 + int'(mcu.fetch_memory_delay.beat_lat);
        if (1 + int'(mcu.data_memory_delay.beat_lat) > con_pace) con_pace = 1 + int'(mcu.data_memory_delay.beat_lat);
`endif
        // CON_MAX_WAIT * con_pace must fit in an int
        if ($value$plusargs("console_pace=%d", con_pace) && (con_pace < 1 || con_pace > 32767))
            $fatal(1, "+console_pace=%0d: give 1 to 32767", con_pace);
    end

    always @(posedge clk) begin
        int c;

        if (mcu.wb_uart.wb_write_tx_buffer) begin
            console_tx(int'(mcu.wb_uart.wb_dat_mosi[7:0]), longint'(trace_cycle));
            con_quiet <= 0;
        end
        else if (con_quiet < CON_QUIET_CYCLES * con_pace) begin
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
                if (con_waited < CON_MAX_WAIT * con_pace)
                    con_waited <= con_waited + 1;
                if (con_timer > 0) begin
                    con_timer <= con_timer - 1;
                end
                else if ((con_waited >= CON_QUIET_CYCLES * con_pace && con_quiet >= CON_QUIET_CYCLES * con_pace) ||
                         con_waited >= CON_MAX_WAIT * con_pace) begin
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

    // ==== Memory-system checks: scoreboard, bus hash, retired instructions ====
    // They sit at the end of the module so that the lines above keep their numbers (the
    // records in results/ quote the line of the $finish statement). Their run options:
    //   +scoreboard         check every answer of the RAM against a shadow copy of the
    //                       memory (+noscoreboard: do not); see the scoreboard below
    //   +bushash            print a hash of both CPU buses at the end (+nobushash: do not)
    //   +retired            print the retired instructions and the cycles per instruction
    //                       at the end (+noretired: do not); see below
    // Simulators with a slow memory (+define+HADES_SLOW_MEM) also take the latency
    // options of sim/slow_memory.sv (+mem_lat, +mem_rd_lat, +mem_wr_lat, +mem_beat_lat,
    // +mem_seed), and scale the default of +timeout (see the end of the module), and these
    // (see their blocks below):
    //   +reset_at=<cycle>[,<cycle>...]   resets in the middle of the run (RESET lines)
    //   +cache_phase_log=<file>          one byte per cycle: what the memory system is doing
    //   +ram_words=<byte address>[,...]  print these RAM words at the end (RAM_WORDS line)
    //   +retired_every=<n>               a RETIRED_AT line every n retired instructions
    // Simulators with caches (+define+HADES_ICACHE_BYTES: the slow memory and an I-cache) also
    // check that every request is answered within its bound, and take
    //   +cache_stats                     print the cache's event counts at the end (CACHE_STATS
    //                                    line; +nocache_stats: do not; on by default)
    // Every simulator of HaDes-V+ takes
    //   +irq_latency                     measure the latency of every interrupt (IRQLAT line)

    // The scoreboard and the bus hash below keep their own state with blocking assignments.
    /* verilator lint_off BLKSEQ */

    // ---- Shadow-memory scoreboard (+scoreboard) ----
    // An oracle for the memory system that depends on neither CPU: a copy of the RAM, loaded
    // from the same init.mem and updated from the stores acknowledged on the data bus
    // (mcu.mem_bus), byte lane by byte lane as sel selects them (the golden CPU drives the
    // other bytes of rs2 on the lanes a store does not select). Every acknowledged read of the
    // RAM window must return the copy's word, all 32 bits: each fetch on the fetch bus and
    // each load on the data bus. A read sees memory as it was at the start of its cycle:
    // every store acknowledged in an earlier cycle, but not a store to the same word that is
    // acknowledged in the same cycle on the other port. Both ports of wishbone_ram are
    // clocked by clk_mem, and a read beside a write of the same word returns the old word:
    // a store over the instruction three words after it (without fence.i) meets that
    // instruction's fetch in the same cycle, and the old instruction is executed.
    // After every store the RAM's word must equal the copy, and at the end of the run the
    // whole RAM must.
    // It also checks the protocol of both buses: never ack together with err, no answer
    // without cyc && stb, the fetch bus only reads whole words, a data request does not
    // change before its answer (address, sel, we and, for a write, the data; Wishbone leaves
    // dat_mosi undefined during a read), and no access to the RAM window ends in err.
    // The first discrepancy stops the simulation ($fatal) with the cycle, the bus, the
    // address and both values. The end of a run prints one SCOREBOARD line.
    // Default: on in simulators with a slow memory (+define+HADES_SLOW_MEM), off otherwise;
    // +define+HADES_SCOREBOARD=0|1 sets the default, +scoreboard / +noscoreboard the run.
`ifndef HADES_SCOREBOARD
`ifdef HADES_SLOW_MEM
`define HADES_SCOREBOARD 1
`else
`define HADES_SCOREBOARD 0
`endif
`endif
    localparam bit [31:0] RAM_START = constants::MEMORY_START;     // word addresses
    localparam bit [31:0] RAM_WORDS = constants::MEMORY_SIZE;

    bit              sb_en;
    bit       [31:0] sb_mem [RAM_WORDS];
    longint unsigned sb_fetches, sb_loads, sb_stores;
    bit              sb_wait;                       // a data request was not answered
    bit       [31:0] sb_wait_adr, sb_wait_dat;      // ... and this was it
    bit        [3:0] sb_wait_sel;
    bit              sb_wait_we;

    initial begin
        sb_en = `HADES_SCOREBOARD;
        if ($test$plusargs("noscoreboard")) sb_en = 0;
        if ($test$plusargs("scoreboard"))   sb_en = 1;
        if (sb_en) begin
            $readmemh("init.mem", sb_mem);
            $display("SCOREBOARD on: every answer from the RAM, addresses 0x%08x-0x%08x, is checked",
                     RAM_START << 2, ((RAM_START + RAM_WORDS) << 2) - 1);
        end
    end

    function automatic bit sb_in_ram(bit [31:0] adr);
        return adr - RAM_START < RAM_WORDS;
    endfunction

    task automatic sb_stop(string what);
        $fatal(1, "SCOREBOARD: FAIL at cycle %0d: %s", trace_cycle, what);
    endtask

    always @(posedge clk) begin
        bit [31:0] a, w;
        if (sb_en && !mcu.rst) begin
            // Fetch bus
            a = mcu.fetch_bus.adr;
            if (mcu.fetch_bus.ack && mcu.fetch_bus.err)
                sb_stop($sformatf("fetch bus: ack and err together, address 0x%08x", a << 2));
            if ((mcu.fetch_bus.ack || mcu.fetch_bus.err) && !(mcu.fetch_bus.cyc && mcu.fetch_bus.stb))
                sb_stop($sformatf("fetch bus: an answer without cyc && stb, address 0x%08x", a << 2));
            if (mcu.fetch_bus.cyc && mcu.fetch_bus.stb && (mcu.fetch_bus.we || mcu.fetch_bus.sel != 4'b1111))
                sb_stop($sformatf("fetch bus: we=%0d sel=%04b, address 0x%08x (only word reads are allowed)",
                                  mcu.fetch_bus.we, mcu.fetch_bus.sel, a << 2));
            if (mcu.fetch_bus.ack) begin
                if (!sb_in_ram(a))
                    sb_stop($sformatf("fetch bus: ack for address 0x%08x, outside the RAM", a << 2));
                else if (mcu.fetch_bus.dat_miso != sb_mem[a - RAM_START])
                    sb_stop($sformatf("fetch bus: address 0x%08x returned 0x%08x, memory holds 0x%08x",
                                      a << 2, mcu.fetch_bus.dat_miso, sb_mem[a - RAM_START]));
                sb_fetches++;
            end
            else if (mcu.fetch_bus.err && sb_in_ram(a)) begin
                sb_stop($sformatf("fetch bus: err for address 0x%08x, inside the RAM", a << 2));
            end

            // Data bus: protocol
            a = mcu.mem_bus.adr;
            if (mcu.mem_bus.ack && mcu.mem_bus.err)
                sb_stop($sformatf("data bus: ack and err together, address 0x%08x", a << 2));
            if ((mcu.mem_bus.ack || mcu.mem_bus.err) && !(mcu.mem_bus.cyc && mcu.mem_bus.stb))
                sb_stop($sformatf("data bus: an answer without cyc && stb, address 0x%08x", a << 2));
            if (sb_wait && !(mcu.mem_bus.cyc && mcu.mem_bus.stb && a == sb_wait_adr &&
                             mcu.mem_bus.sel == sb_wait_sel && mcu.mem_bus.we == sb_wait_we &&
                             (!sb_wait_we || mcu.mem_bus.dat_mosi == sb_wait_dat)))
                sb_stop($sformatf("data bus: the request (address 0x%08x sel=%04b we=%0d data 0x%08x) changed before its answer",
                                  sb_wait_adr << 2, sb_wait_sel, sb_wait_we, sb_wait_dat));
            sb_wait     = mcu.mem_bus.cyc && mcu.mem_bus.stb && !mcu.mem_bus.ack && !mcu.mem_bus.err;
            sb_wait_adr = a;
            sb_wait_sel = mcu.mem_bus.sel;
            sb_wait_we  = mcu.mem_bus.we;
            sb_wait_dat = mcu.mem_bus.dat_mosi;

            // Data bus: loads, then stores (a fetch above read the word before this cycle's store)
            if (mcu.mem_bus.cyc && mcu.mem_bus.stb && sb_in_ram(a)) begin
                if (mcu.mem_bus.err)
                    sb_stop($sformatf("data bus: err for address 0x%08x, inside the RAM", a << 2));
                if (mcu.mem_bus.ack && !mcu.mem_bus.we) begin
                    if (mcu.mem_bus.dat_miso != sb_mem[a - RAM_START])
                        sb_stop($sformatf("data bus: load from address 0x%08x (sel=%04b) returned 0x%08x, memory holds 0x%08x",
                                          a << 2, mcu.mem_bus.sel, mcu.mem_bus.dat_miso, sb_mem[a - RAM_START]));
                    sb_loads++;
                end
                if (mcu.mem_bus.ack && mcu.mem_bus.we) begin
                    w = sb_mem[a - RAM_START];
                    for (int lane = 0; lane < 4; lane++)
                        if (mcu.mem_bus.sel[lane]) w[8*lane +: 8] = mcu.mem_bus.dat_mosi[8*lane +: 8];
                    sb_mem[a - RAM_START] = w;
                    if (mcu.ram.memory[a - RAM_START] != w)
                        sb_stop($sformatf("data bus: after the store to address 0x%08x (sel=%04b data 0x%08x) the RAM holds 0x%08x, expected 0x%08x",
                                          a << 2, mcu.mem_bus.sel, mcu.mem_bus.dat_mosi, mcu.ram.memory[a - RAM_START], w));
                    sb_stores++;
                end
            end
        end
        // A reset drops the waiting request (the CPU presents none in the next cycle). The copy
        // of the memory stays: the RAM keeps its contents across a reset.
        if (mcu.rst)
            sb_wait = 0;
    end

    final begin
        if (sb_en) begin
            int unsigned bad;
            bad = 0;
            for (int unsigned i = 0; i < RAM_WORDS; i++) begin
                if (mcu.ram.memory[i] != sb_mem[i]) begin
                    if (bad < 8)
                        $display("SCOREBOARD: at the end the RAM holds 0x%08x at address 0x%08x, the copy 0x%08x",
                                 mcu.ram.memory[i], (RAM_START + i) << 2, sb_mem[i]);
                    bad++;
                end
            end
            if (bad == 0)
                $display("SCOREBOARD: PASS  %0d fetches, %0d loads, %0d stores checked; the RAM equals the copy at the end",
                         sb_fetches, sb_loads, sb_stores);
            else
                $fatal(1, "SCOREBOARD: FAIL  at the end %0d RAM word(s) differ from the copy", bad);
        end
    end

    // ---- Bus hash (+bushash) ----
    // A 64-bit hash of both CPU buses in every cycle after reset, printed at the end of the run
    // as one BUSHASH line, so that two simulators can be shown to drive and answer the buses
    // identically, cycle for cycle (e.g. the standard simulator and a slow-memory simulator at
    // latency 0):
    //   fetch: cyc, stb, ack, err, adr, dat_miso
    //   data:  cyc, stb, we, sel, ack, err, adr, dat_mosi, dat_miso
    // data_txn hashes only the completed data transfers (ack or err, we, sel, address, and the
    // data written or read), in order but without their timing: it stays the same under other
    // memory latencies as long as the program makes the same accesses.
    // +define+HADES_BUSHASH=1 makes it the default.
`ifndef HADES_BUSHASH
`define HADES_BUSHASH 0
`endif
    bit              bh_en;
    bit       [63:0] bh_fetch, bh_data, bh_txn;
    longint unsigned bh_cycles, bh_transfers;

    initial begin
        bh_en = `HADES_BUSHASH;
        if ($test$plusargs("nobushash")) bh_en = 0;
        if ($test$plusargs("bushash"))   bh_en = 1;
        bh_fetch = 64'hCBF2_9CE4_8422_2325;
        bh_data  = 64'hCBF2_9CE4_8422_2325;
        bh_txn   = 64'hCBF2_9CE4_8422_2325;
    end

    function automatic bit [63:0] bh_step(bit [63:0] h, bit [31:0] x);
        bit [63:0] z;
        z = (h ^ {32'h0, x}) * 64'h9E37_79B9_7F4A_7C15;
        return z ^ (z >> 29);
    endfunction

    always @(posedge clk) begin
        if (bh_en && !mcu.rst) begin
            bh_fetch = bh_step(bh_fetch, {28'h0, mcu.fetch_bus.cyc, mcu.fetch_bus.stb, mcu.fetch_bus.ack, mcu.fetch_bus.err});
            bh_fetch = bh_step(bh_fetch, mcu.fetch_bus.adr);
            bh_fetch = bh_step(bh_fetch, mcu.fetch_bus.dat_miso);
            bh_data  = bh_step(bh_data, {23'h0, mcu.mem_bus.cyc, mcu.mem_bus.stb, mcu.mem_bus.we,
                                         mcu.mem_bus.sel, mcu.mem_bus.ack, mcu.mem_bus.err});
            bh_data  = bh_step(bh_data, mcu.mem_bus.adr);
            bh_data  = bh_step(bh_data, mcu.mem_bus.dat_mosi);
            bh_data  = bh_step(bh_data, mcu.mem_bus.dat_miso);
            if (mcu.mem_bus.cyc && mcu.mem_bus.stb && (mcu.mem_bus.ack || mcu.mem_bus.err)) begin
                bh_txn = bh_step(bh_txn, {25'h0, mcu.mem_bus.ack, mcu.mem_bus.err, mcu.mem_bus.we, mcu.mem_bus.sel});
                bh_txn = bh_step(bh_txn, mcu.mem_bus.adr);
                bh_txn = bh_step(bh_txn, mcu.mem_bus.we ? mcu.mem_bus.dat_mosi
                                                         : (mcu.mem_bus.ack ? mcu.mem_bus.dat_miso : 32'h0));
                bh_transfers++;
            end
            bh_cycles++;
        end
    end

    final begin
        if (bh_en)
            $display("BUSHASH cycles=%0d fetch=%016x data=%016x data_txn=%016x transfers=%0d",
                     bh_cycles, bh_fetch, bh_data, bh_txn, bh_transfers);
    end
    /* verilator lint_on BLKSEQ */

    // ---- Retired instructions (+retired) ----
    // At the end of the run one RETIRED line gives the cycles after reset, the instructions
    // HaDes-V+ retired in them and the cycles per instruction (e.g. what a slow memory costs).
    // An instruction is counted when the Writeback stage counts it in minstret, so software
    // that writes minstret does not change the count. The golden CPU is a compiled library
    // whose counters the testbench cannot read: its line gives the cycles only.
    // Default: on in simulators with a slow memory (+define+HADES_SLOW_MEM), off otherwise;
    // +define+HADES_RETIRED=0|1 sets the default, +retired / +noretired the run.
`ifndef HADES_RETIRED
`ifdef HADES_SLOW_MEM
`define HADES_RETIRED 1
`else
`define HADES_RETIRED 0
`endif
`endif
    bit              rt_en;
    longint unsigned rt_cycles;
`ifndef USE_REF_CPU
    longint unsigned rt_instructions;
`endif

    initial begin
        rt_en = `HADES_RETIRED;
        if ($test$plusargs("noretired")) rt_en = 0;
        if ($test$plusargs("retired"))   rt_en = 1;
    end

    always @(posedge clk) begin
        if (rt_en && !mcu.rst) begin
            rt_cycles <= rt_cycles + 1;
`ifndef USE_REF_CPU
            if (mcu.cpu.i_writeback.is_valid && !mcu.cpu.i_writeback.stale_replay)
                rt_instructions <= rt_instructions + 1;
`endif
        end
    end

    final begin
        if (rt_en) begin
`ifdef USE_REF_CPU
            $display("RETIRED cycles=%0d instructions=n/a cpi=n/a (the golden CPU's counters cannot be read)",
                     rt_cycles);
`else
            $display("RETIRED cycles=%0d instructions=%0d cpi=%0.3f", rt_cycles, rt_instructions,
                     (rt_instructions == 0) ? 0.0 : real'(rt_cycles) / real'(rt_instructions));
`endif
        end
    end

    // ---- A RAM access must not time out (always checked) ----
    // The interconnect ends a data-bus access with err once no slave has answered it for 255
    // cycles. A RAM access must never end that way: the RAM's late answer would complete the
    // next access instead (the interconnect selects a slave by cyc and the address, not stb).
    always @(posedge clk) begin
        if (!mcu.rst && mcu.peripheral_bus_interconnect.timeout && mcu.peripheral_bus_interconnect.select[0])
            $fatal(1, "interconnect timeout at cycle %0d on a RAM access, address 0x%08x: no answer for 255 cycles",
                   trace_cycle, mcu.mem_bus.adr << 2);
    end

`ifdef HADES_BUSTRACE
    // ---- Bus trace for cache studies (make ... BUSTRACE=1: +define+HADES_BUSTRACE) ----
    // Writes one 16-byte record per clock cycle, from the first clock edge on, to the file
    // +bustrace=<file> (default: bustrace.bin in the run directory). A record is four
    // little-endian 32-bit words, sampled at the rising edge that ends the cycle:
    //   word 0  fetch port: [29:0] adr (a word address; bits 31:30 of adr are always 0),
    //           [31:30] Fetch's status in this cycle: 0 READY (an acknowledged word is taken),
    //           1 STALL (it is discarded and the same address is presented again),
    //           2 JUMP (it is discarded and the next address is the jump target)
    //   word 1  [0] fetch ack, [1] fetch err,
    //           [2] data cyc && stb, [3] data ack, [4] data err, [5] data we, [9:6] data sel,
    //           [10] the data access selects the RAM (interconnect slave 0),
    //           [11] an instruction is in Writeback (its status is not BUBBLE),
    //           [12] it retires (minstret counts it),
    //           [14:13], [16:15], [18:17] the backwards status out of Writeback, Memory
    //           and Execute (which stage redirects Fetch on a JUMP), [19] reset
    //   word 2  data port adr (a word address)
    //   word 3  PC of the instruction in Writeback
    // test/memsys/cachemodel.py reads the file. The monitor only reads signals, so the simulation
    // is unchanged. It reads Fetch's status and the Writeback stage inside cpu.sv, so it
    // exists for HaDes-V+ only.
`ifdef USE_REF_CPU
    initial $fatal(1, "HADES_BUSTRACE: the bus trace reads signals inside cpu.sv; it cannot trace ref_cpu");
`else
    int    bustrace_fd;                    // 2-state: 0 until the file is open
    string bustrace_file = "bustrace.bin";
    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        // opened at the first clock edge, so that record n belongs to cycle n
        if (bustrace_fd == 0) begin
            void'($value$plusargs("bustrace=%s", bustrace_file));
            bustrace_fd = $fopen(bustrace_file, "wb");
            if (bustrace_fd == 0)
                $fatal(1, "HADES_BUSTRACE: cannot open %s", bustrace_file);
        end
        $fwrite(bustrace_fd, "%u%u%u%u",
                {mcu.cpu.bwd_status_d, mcu.fetch_bus.adr[29:0]},
                {12'b0,
                 mcu.rst,
                 mcu.cpu.bwd_status_e, mcu.cpu.bwd_status_m, mcu.cpu.bwd_status_wb,
                 mcu.cpu.i_writeback.is_valid && !mcu.cpu.i_writeback.stale_replay,
                 mcu.cpu.fwd_status_m != pipeline_status::BUBBLE,
                 mcu.mem_bus_slaves[0].stb,
                 mcu.mem_bus.sel, mcu.mem_bus.we, mcu.mem_bus.err, mcu.mem_bus.ack,
                 mcu.mem_bus.cyc && mcu.mem_bus.stb,
                 mcu.fetch_bus.err, mcu.fetch_bus.ack},
                mcu.mem_bus.adr,
                mcu.cpu.pc_m);
    end
    /* verilator lint_on BLKSEQ */
    final if (bustrace_fd != 0) $fclose(bustrace_fd);
`endif
`endif

`ifdef HADES_SLOW_MEM
    // ---- Resets in the middle of a run (+reset_at=<cycle>[,<cycle>...]) ----
    // For each listed cycle c (the testbench's cycle count, as TRACE lines give it) the centre
    // button, the reset button, is held for exactly cycle c. Its two synchronizer stages and the
    // rst flip-flop of rtl/mcu.sv make rst high for exactly cycle c + 3. A run with +reset_at
    // is identical to the run without it up to then, so a reset wanted in cycle t is given as
    // +reset_at=<t - 3>; +cache_phase_log below shows what happens in every cycle. The cycles
    // must be strictly ascending and at least 2 apart (each gives its own one-cycle reset). In
    // the cycle in which rst is high one line is printed:
    //   RESET at cycle <n> (+reset_at=<c>): I-cache <phase>, data side <phase>
    // I-cache: idle | refill waiting for the port | refill beat <b> of <n> (b counted from 0;
    // idle without caches). Data side: idle | RAM load waiting | RAM store waiting | I/O access
    // waiting | granted (RAM load) | granted (RAM store): a request that has had no answer yet,
    // and with caches whether the arbiter grants it the memory port in that cycle ("RAM ...
    // waiting" then means waiting for the port). The memory checks above run across the reset:
    // the scoreboard keeps its copy of the memory and drops a waiting request. RETIRED and
    // BUSHASH keep counting from time 0; CACHE_STATS restarts at every reset.
    longint unsigned reset_at[$];          // the listed cycles
    int              reset_next;           // the next one to drive
    longint unsigned reset_due[$];         // driven, its reset still to come

    initial begin
        string text;
        longint unsigned c;
        int digits;
        bit ok;
        if ($value$plusargs("reset_at=%s", text)) begin
            c = 0;
            digits = 0;
            ok = text.len() > 0;
            for (int i = 0; i <= text.len() && ok; i++) begin
                if (i == text.len() || text.getc(i) == ",") begin
                    ok = digits > 0 && c > 0 &&
                         (reset_at.size() == 0 || c >= reset_at[reset_at.size() - 1] + 2);
                    reset_at.push_back(c);
                    c = 0;
                    digits = 0;
                end
                else if (text.getc(i) >= "0" && text.getc(i) <= "9" && digits < 18) begin
                    c = c * 10 + longint'(text.getc(i)) - 64'd48;   // a decimal digit
                    digits++;
                end
                else begin
                    ok = 0;
                end
            end
            if (!ok)
                $fatal(1, "+reset_at=%s: give cycles (decimal, at least 1) in strictly ascending order, at least 2 apart, separated by commas, e.g. +reset_at=1000,1002",
                       text);
        end
    end

    function automatic string reset_icache_phase();
`ifdef HADES_ICACHE_BYTES
        if (mcu.icache.state != mcu.icache.REFILL)
            return "idle";
        else if (!mcu.mem_arbiter.gi)
            return "refill waiting for the port";
        else
            return $sformatf("refill beat %0d of %0d", mcu.icache.beat, mcu.icache.LINE_WORDS);
`else
        return "idle";
`endif
    endfunction

    function automatic string reset_data_phase();
        string kind;
        if (!(mcu.mem_bus.cyc && mcu.mem_bus.stb) || mcu.mem_bus.ack || mcu.mem_bus.err)
            return "idle";
        if (!mcu.peripheral_bus_interconnect.select[0])
            return "I/O access waiting";
        kind = mcu.mem_bus.we ? "RAM store" : "RAM load";
`ifdef HADES_ICACHE_BYTES
        if (mcu.mem_arbiter.gd)
            return $sformatf("granted (%s)", kind);
`endif
        return $sformatf("%s waiting", kind);
    endfunction

    bit reset_seen_run;                    // a cycle without reset has passed

    always @(posedge clk) begin
        if (reset_next < reset_at.size() && trace_cycle + 1 == reset_at[reset_next]) begin
            buttons_async[0] <= 1'b1;      // high in cycle trace_cycle + 1
            reset_due.push_back(reset_at[reset_next]);
            reset_next <= reset_next + 1;
        end
        else begin
            buttons_async[0] <= 1'b0;
        end
        if (!mcu.rst)
            reset_seen_run <= 1'b1;
        else if (reset_seen_run && reset_due.size() > 0)
            $display("RESET at cycle %0d (+reset_at=%0d): I-cache %s, data side %s",
                     trace_cycle, reset_due.pop_front(), reset_icache_phase(), reset_data_phase());
    end

    // ---- Phase log (+cache_phase_log=<file>) ----
    // One byte per cycle, from the first clock edge on (byte n belongs to cycle n), for placing
    // the resets above: bit 0 the I-cache is granted the memory port, bit 1 an I-refill waits for
    // the port, bit 2 a data request on the CPU's data bus has had no answer yet in this cycle
    // (cyc && stb && !ack && !err), bit 3 it is a RAM access (interconnect slave 0), bit 4 it is
    // a write, bit 5 the data side is granted the memory port, bit 6 rst, bit 7 0. Bits 0, 1 and
    // 5 are 0 without caches.
    int    phase_fd;                       // 2-state: 0 unless the file is open

    initial begin
        string phase_file;
        if ($value$plusargs("cache_phase_log=%s", phase_file)) begin
            phase_fd = $fopen(phase_file, "wb");
            if (phase_fd == 0)
                $fatal(1, "+cache_phase_log=%s: cannot open the file", phase_file);
        end
    end

    always @(posedge clk) begin
        bit [7:0] b;
        if (phase_fd != 0) begin
            b = 8'h00;
            b[2] = mcu.mem_bus.cyc && mcu.mem_bus.stb && !mcu.mem_bus.ack && !mcu.mem_bus.err;
            b[3] = b[2] && mcu.peripheral_bus_interconnect.select[0];
            b[4] = b[2] && mcu.mem_bus.we;
            b[6] = mcu.rst;
`ifdef HADES_ICACHE_BYTES
            b[0] = mcu.mem_arbiter.gi;
            b[1] = mcu.mem_arbiter.i_req && !mcu.mem_arbiter.gi;
            b[5] = mcu.mem_arbiter.gd;
`endif
            $fwrite(phase_fd, "%c", b);
        end
    end

    final if (phase_fd != 0) $fclose(phase_fd);

    // ---- RAM words at the end (+ram_words=<byte address>[,<byte address>...]) ----
    // One line at the end of the run: RAM_WORDS <address>=<value> ... (addresses and values in
    // hexadecimal), for the words at these byte addresses: word-aligned, inside the RAM, given
    // in hexadecimal (0x...) or decimal.
    bit [31:0] ram_words[$];

    // "0x<hex digits>" or "<decimal digits>" -> v; 0 if t is neither or does not fit 32 bits
    function automatic bit ram_words_number(string t, output bit [31:0] v);
        longint value;
        int     base, first, digit;
        v = 0;
        value = 0;
        base  = (t.len() > 2 && t.getc(0) == "0" && (t.getc(1) == "x" || t.getc(1) == "X")) ? 16 : 10;
        first = (base == 16) ? 2 : 0;
        if (t.len() <= first || t.len() - first > 10)
            return 0;
        for (int i = first; i < t.len(); i++) begin
            if (t.getc(i) >= "0" && t.getc(i) <= "9")                    digit = int'(t.getc(i)) - 48;
            else if (base == 16 && t.getc(i) >= "a" && t.getc(i) <= "f") digit = int'(t.getc(i)) - 87;
            else if (base == 16 && t.getc(i) >= "A" && t.getc(i) <= "F") digit = int'(t.getc(i)) - 55;
            else return 0;
            value = value * longint'(base) + longint'(digit);
        end
        if (value > 64'hFFFF_FFFF)
            return 0;
        v = 32'(value);
        return 1;
    endfunction

    initial begin
        string text, item;
        bit [31:0] a;
        int first;
        if ($value$plusargs("ram_words=%s", text)) begin
            first = 0;
            for (int i = 0; i <= text.len(); i++) begin
                if (i == text.len() || text.getc(i) == ",") begin
                    item = (i > first) ? text.substr(first, i - 1) : "";
                    if (!ram_words_number(item, a) || a[1:0] != 2'b00 || !sb_in_ram(a >> 2))
                        $fatal(1, "+ram_words=%s: '%s' is not the byte address of a RAM word (word-aligned, 0x%08x-0x%08x; hexadecimal 0x... or decimal)",
                               text, item, RAM_START << 2, ((RAM_START + RAM_WORDS) << 2) - 4);
                    ram_words.push_back(a);
                    first = i + 1;
                end
            end
        end
    end

    final begin
        string line;
        if (ram_words.size() > 0) begin
            line = "RAM_WORDS";
            foreach (ram_words[i])
                line = {line, $sformatf(" 0x%08x=0x%08x", ram_words[i], mcu.ram.memory[(ram_words[i] >> 2) - RAM_START])};
            $display("%s", line);
        end
    end

    // ---- Retired instructions, every n of them (+retired_every=<n>, HaDes-V+ only) ----
    // A line RETIRED_AT instructions=<i> cycles=<c> each time the count of the RETIRED line
    // reaches another multiple of n: the instructions and cycles that RETIRED would print if the
    // run ended there (counted the same way, also with +noretired).
    longint unsigned retired_every;
`ifndef USE_REF_CPU
    longint unsigned ra_cycles, ra_instructions;
`endif

    initial begin
        if ($value$plusargs("retired_every=%d", retired_every) && retired_every == 0)
            $fatal(1, "+retired_every: give a number of instructions above 0");
`ifdef USE_REF_CPU
        if (retired_every > 0)
            $display("RETIRED_AT n/a: +retired_every counts the instructions of HaDes-V+; the golden CPU's counters cannot be read");
`endif
    end

`ifndef USE_REF_CPU
    always @(posedge clk) begin
        if (retired_every > 0 && !mcu.rst) begin
            ra_cycles <= ra_cycles + 1;
            if (mcu.cpu.i_writeback.is_valid && !mcu.cpu.i_writeback.stale_replay) begin
                ra_instructions <= ra_instructions + 1;
                if ((ra_instructions + 1) % retired_every == 0)
                    $display("RETIRED_AT instructions=%0d cycles=%0d", ra_instructions + 1, ra_cycles + 1);
            end
        end
    end
`endif
`endif

    // ---- Interrupt latency (+irq_latency, HaDes-V+ only) ----
    // For every interrupt the CPU takes: the cycles from the first cycle in which an interrupt is
    // pending and enabled in Writeback (rtl/writeback_stage.sv: ext_int_pending or
    // timer_int_pending) to the first cycle after the interrupt's jump cycle (int_jump_fire, or
    // the immediate jump of an instruction that enables a pending interrupt) in which the fetch
    // bus answers with ack: latency = (that cycle) - (the first pending cycle). (An answer in
    // the jump cycle itself belongs to the old address.) A pending interrupt that disappears
    // without being taken is not counted. At the end: IRQLAT interrupts=<n> max=<cycles>
    // mean=<cycles>, the observed figures of this run. Reads signals inside cpu.sv, so it exists
    // for HaDes-V+ only.
    bit irq_en;
    initial irq_en = $test$plusargs("irq_latency");
`ifdef USE_REF_CPU
    final if (irq_en)
        $display("IRQLAT interrupts=n/a max=n/a mean=n/a (the golden CPU's signals cannot be read)");
`else
    longint unsigned irq_count, irq_max, irq_sum, irq_start;
    int              irq_phase;            // 0 nothing pending, 1 pending, 2 taken: waiting for ack

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        bit pending, jump;
        if (irq_en) begin
            if (mcu.rst) begin
                irq_phase = 0;
            end
            else begin
                pending = mcu.cpu.i_writeback.ext_int_pending || mcu.cpu.i_writeback.timer_int_pending;
                jump    = mcu.cpu.i_writeback.int_jump_fire ||
                          (mcu.cpu.i_writeback.is_interrupt_imm && !mcu.cpu.i_writeback.is_exception);
                if (irq_phase == 2 && mcu.fetch_bus.ack) begin
                    irq_count++;
                    irq_sum += trace_cycle - irq_start;
                    if (trace_cycle - irq_start > irq_max) irq_max = trace_cycle - irq_start;
                    irq_phase = 0;
                end
                if (irq_phase == 0 && pending) begin
                    irq_start = trace_cycle;
                    irq_phase = 1;
                end
                if (irq_phase == 1) begin
                    if (jump)
                        irq_phase = 2;
                    else if (!pending && !mcu.cpu.i_writeback.int_jump_reg)
                        irq_phase = 0;             // gone without a trap
                end
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    final if (irq_en)
        $display("IRQLAT interrupts=%0d max=%0d mean=%0.2f", irq_count, irq_max,
                 (irq_count == 0) ? 0.0 : real'(irq_sum) / real'(irq_count));
`endif

`ifdef HADES_ICACHE_BYTES
    // ==== Simulators with caches (+define+HADES_ICACHE_BYTES) ====
    // The memory system of rtl/mcu.sv: the I-cache (mcu.icache), the arbiter of the one memory
    // port (mcu.mem_arbiter) and its wrapper (mcu.memory_delay, sim/slow_memory.sv).

    // The longest time the memory port takes, from the wrapper's configured maxima (RD, WR and
    // the beat latency B, which is RD unless burst mode is on): a granted I-refill of LINE_WORDS
    // beats takes at most R = (RD + 1) + (LINE_WORDS - 1) * (B + 1) cycles, a granted data
    // transfer at most D = max(RD, WR) + 1.
    function automatic int cache_refill_cycles();
        int rd, b;
        rd = int'(mcu.memory_delay.rd_max);
        b  = (mcu.memory_delay.beat_lat >= 0) ? mcu.memory_delay.beat_lat : rd;
        return (rd + 1) + (int'(mcu.icache.LINE_WORDS) - 1) * (b + 1);
    endfunction

    function automatic int cache_transfer_cycles();
        int rd, wr;
        rd = int'(mcu.memory_delay.rd_max);
        wr = int'(mcu.memory_delay.wr_max);
        return ((rd > wr) ? rd : wr) + 1;
    endfunction

    // ---- Bounded answers (always checked with caches) ----
    // RAM accesses are exempt from the interconnect's timeout here, so a lost answer would hang
    // the CPU instead of faulting it. Each request must therefore be answered within a bound
    // that a correct memory system meets, or the simulation stops. K_OLDER = 3: once a fetch
    // misses, only the up to three older instructions in Fetch's, Decode's and Execute's output
    // registers can still make a data request, so at most three data transfers hold the port
    // from the miss cycle up to the refill's first grant (at most two of them beginning after
    // the miss cycle). Counting: the first cycle of an interval is its cycle 1; a check fails
    // when its event has not happened by the end of cycle N.
    //   (a) a data request at the RAM's interconnect port is answered, counted from its first
    //       cycle: N = R + D
    //   (b) an I-refill is granted, from its first refill cycle: N = K_OLDER * D
    //   (c) the last beat of a granted I-refill is answered, from its first granted cycle: N = R
    //   (d) the fetch bus is answered (ack or err), from the first cycle without an answer:
    //       N = 8 * (R + K_OLDER * D + 2) (at most three refills lie between two answers, each
    //       with its miss cycle, its wait for the port, the refill and the second lookup;
    //       8 instead of 3 leaves a margin, the check only has to catch a deadlock)
    // No check runs in a cycle with rst = 1, and a reset abandons every open interval.
    localparam int K_OLDER = 3;
    int unsigned bound_data_wait, bound_grant_wait, bound_fill_wait, bound_fetch_wait;
    bit          bound_refill_granted;     // the current refill has had its first grant

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        int r, d;
        if (mcu.rst) begin
            bound_data_wait      = 0;
            bound_grant_wait     = 0;
            bound_fill_wait      = 0;
            bound_fetch_wait     = 0;
            bound_refill_granted = 0;
        end
        else begin
            r = cache_refill_cycles();
            d = cache_transfer_cycles();
            // (a)
            if (mcu.mem_bus_slaves[0].cyc && mcu.mem_bus_slaves[0].stb &&
                !mcu.mem_bus_slaves[0].ack && !mcu.mem_bus_slaves[0].err) begin
                bound_data_wait++;
                if (bound_data_wait >= r + d)
                    $fatal(1, "bounded answer (a): the data request at address 0x%08x (we=%0d) has had no answer for %0d cycles (R + D = %0d + %0d), at cycle %0d",
                           mcu.mem_bus_slaves[0].adr << 2, mcu.mem_bus_slaves[0].we, bound_data_wait, r, d, trace_cycle);
            end
            else begin
                bound_data_wait = 0;
            end
            // (b), (c)
            if (mcu.icache.state == mcu.icache.REFILL) begin
                if (!bound_refill_granted && !mcu.mem_arbiter.gi) begin
                    bound_grant_wait++;
                    if (bound_grant_wait >= K_OLDER * d)
                        $fatal(1, "bounded answer (b): the I-refill of address 0x%08x has not been granted for %0d cycles (K_OLDER * D = %0d * %0d), at cycle %0d",
                               mcu.icache_mem.adr << 2, bound_grant_wait, K_OLDER, d, trace_cycle);
                end
                else begin
                    bound_refill_granted = 1;
                    bound_fill_wait++;
                    if (!mcu.cache_ev_i_fill && bound_fill_wait >= r)
                        $fatal(1, "bounded answer (c): the granted I-refill of address 0x%08x has not ended for %0d cycles (R = %0d), at cycle %0d",
                               mcu.icache_mem.adr << 2, bound_fill_wait, r, trace_cycle);
                end
            end
            else begin
                bound_grant_wait     = 0;
                bound_fill_wait      = 0;
                bound_refill_granted = 0;
            end
            // (d)
            if (mcu.fetch_bus.cyc && mcu.fetch_bus.stb && !mcu.fetch_bus.ack && !mcu.fetch_bus.err) begin
                bound_fetch_wait++;
                if (bound_fetch_wait >= 8 * (r + K_OLDER * d + 2))
                    $fatal(1, "bounded answer (d): the fetch bus has had no answer for %0d cycles (8 * (R + K_OLDER * D + 2) with R = %0d, D = %0d), address 0x%08x, at cycle %0d",
                           bound_fetch_wait, r, d, mcu.fetch_bus.adr << 2, trace_cycle);
            end
            else begin
                bound_fetch_wait = 0;
            end
        end
    end
    /* verilator lint_on BLKSEQ */

    // ---- Cache statistics (+cache_stats, on by default; +nocache_stats: off) ----
    // Counts the event signals of rtl/mcu.sv (cache_ev_*: each is 1 exactly in the cycles in
    // which its event happens) and prints at the end of the run one line,
    //   CACHE_STATS cycles=<n> i_hits=<n> i_refills=<n> i_done=<n> i_beats=<n> i_abandoned=<n>
    //   snoop_inval=<n> i_refill_cycles=<n> wait_i_for_port=<n> wait_d_for_port=<n>
    //   port_irefill=<n> port_data=<n> d_loads=<n> d_stores=<n> i_inflight=<0|1>
    //   i_inflight_beats=<n> i_inflight_port=<n> d_inflight=<0|1> d_inflight_port=<n>
    // (one line). Every counter restarts at every reset; cycles counts the cycles with rst = 0
    // since the last reset. Fields: i_hits fetches answered from the cache (lookups repeated in
    // stalls and answers thrown away on jumps count too), i_refills refills started (misses),
    // i_done refills completed, i_beats refill beats, i_abandoned refills completed while the CPU
    // presented no address of the line, snoop_inval lines invalidated by stores,
    // i_refill_cycles cycles in a refill, wait_i_for_port and wait_d_for_port cycles in which a
    // refill or a data request waited for the port held by the other side, port_irefill and
    // port_data cycles of the port used by refills and data transfers, d_loads and d_stores RAM
    // loads and stores answered. The state at the end, after the last counted edge: i_inflight
    // 1 if a refill is in progress, with the beats answered and the port cycles it has had so
    // far; d_inflight 1 if a data transfer holds the port, with its port cycles so far.
    // In a run without a reset in its middle: i_refills = i_done + i_inflight, i_refill_cycles =
    // wait_i_for_port + port_irefill, i_beats = LINE_WORDS * i_done + i_inflight_beats; i_hits,
    // d_loads and d_stores equal the fetches, loads and stores of the SCOREBOARD line, and
    // cycles the cycles of the RETIRED line.
    bit              cs_en;
    longint unsigned cs_cycles, cs_i_hits, cs_i_refills, cs_i_done, cs_i_beats, cs_i_abandoned,
                     cs_snoop_inval, cs_i_refill_cycles, cs_wait_i, cs_wait_d, cs_port_irefill,
                     cs_port_data, cs_d_loads, cs_d_stores;
    longint unsigned cs_cur_i_beats, cs_cur_i_port, cs_cur_d_port;   // of the refill and the
                                                                      // transfer in progress

    initial begin
        cs_en = 1;
        if ($test$plusargs("nocache_stats")) cs_en = 0;
        if ($test$plusargs("cache_stats"))   cs_en = 1;
    end

    /* verilator lint_off BLKSEQ */
    always @(posedge clk) begin
        if (mcu.rst) begin
            cs_cycles          = 0;
            cs_i_hits          = 0;
            cs_i_refills       = 0;
            cs_i_done          = 0;
            cs_i_beats         = 0;
            cs_i_abandoned     = 0;
            cs_snoop_inval     = 0;
            cs_i_refill_cycles = 0;
            cs_wait_i          = 0;
            cs_wait_d          = 0;
            cs_port_irefill    = 0;
            cs_port_data       = 0;
            cs_d_loads         = 0;
            cs_d_stores        = 0;
            cs_cur_i_beats     = 0;
            cs_cur_i_port      = 0;
            cs_cur_d_port      = 0;
        end
        else begin
            cs_cycles++;
            cs_i_hits          += 64'(mcu.cache_ev_i_hit);
            cs_i_refills       += 64'(mcu.cache_ev_i_miss);
            cs_i_done          += 64'(mcu.cache_ev_i_fill);
            cs_i_beats         += 64'(mcu.cache_ev_i_beat);
            cs_i_abandoned     += 64'(mcu.cache_ev_i_abandoned);
            cs_snoop_inval     += 64'(mcu.cache_ev_i_snoop_inval);
            cs_i_refill_cycles += 64'(mcu.cache_ev_i_refill);
            cs_wait_i          += 64'(mcu.cache_ev_wait_i);
            cs_wait_d          += 64'(mcu.cache_ev_wait_d);
            cs_port_irefill    += 64'(mcu.cache_ev_grant_i);
            cs_port_data       += 64'(mcu.cache_ev_grant_d);
            cs_d_loads         += 64'(mcu.cache_ev_port_load);
            cs_d_stores        += 64'(mcu.cache_ev_port_store);
            if (mcu.cache_ev_i_miss) begin             // a refill starts at the end of this cycle
                cs_cur_i_beats = 0;
                cs_cur_i_port  = 0;
            end
            else begin
                cs_cur_i_beats += 64'(mcu.cache_ev_i_beat);
                cs_cur_i_port  += 64'(mcu.cache_ev_grant_i);
            end
            if (mcu.cache_ev_grant_d)                  // a transfer's first granted cycle restarts it
                cs_cur_d_port = ((mcu.mem_arbiter.owner == mcu.mem_arbiter.DATA) ? cs_cur_d_port : 0) + 1;
        end
    end
    /* verilator lint_on BLKSEQ */

    final begin
        bit    i_inflight, d_inflight;
        string line;
        if (cs_en) begin
            i_inflight = mcu.icache.state == mcu.icache.REFILL;
            d_inflight = mcu.mem_arbiter.owner == mcu.mem_arbiter.DATA;
            line = $sformatf("CACHE_STATS cycles=%0d i_hits=%0d i_refills=%0d i_done=%0d i_beats=%0d i_abandoned=%0d",
                             cs_cycles, cs_i_hits, cs_i_refills, cs_i_done, cs_i_beats, cs_i_abandoned);
            line = {line, $sformatf(" snoop_inval=%0d i_refill_cycles=%0d wait_i_for_port=%0d wait_d_for_port=%0d",
                                    cs_snoop_inval, cs_i_refill_cycles, cs_wait_i, cs_wait_d)};
            line = {line, $sformatf(" port_irefill=%0d port_data=%0d d_loads=%0d d_stores=%0d",
                                    cs_port_irefill, cs_port_data, cs_d_loads, cs_d_stores)};
            line = {line, $sformatf(" i_inflight=%0d i_inflight_beats=%0d i_inflight_port=%0d d_inflight=%0d d_inflight_port=%0d",
                                    i_inflight, i_inflight ? cs_cur_i_beats : 64'd0, i_inflight ? cs_cur_i_port : 64'd0,
                                    d_inflight, d_inflight ? cs_cur_d_port : 64'd0)};
            $display("%s", line);
        end
    end
`endif

`ifdef HADES_ICACHE_BYTES
    // ---- Cycle limit with caches ----
    // A program on cached memory slows down by its misses, each of which costs a whole refill,
    // not one wait. So without +timeout the default limit (100000 cycles) is multiplied by 1 +
    // the longest refill or data transfer of the memory port, max(R, D) cycles (see the bounded
    // answers above); that is never less than the factor without caches.
    // test/memsys/programs.py uses the same rule for its runs. An explicit +timeout=<cycles> is
    // used as given. The loop at the top of the module compares its count with timeout_cycles
    // in every cycle, so the new limit takes effect.
    initial begin
        int longest;
        if (!$test$plusargs("timeout=")) begin
            @(posedge clk);                // the memory wrapper has read its options by now
            longest = cache_refill_cycles();
            if (cache_transfer_cycles() > longest) longest = cache_transfer_cycles();
            timeout_cycles = timeout_cycles * (64'd1 + 64'(longest));
            $display("SLOW MEMORY cycle limit %0d: 100000 times 1 + the longest refill or data transfer (%0d cycles); +timeout=<cycles> sets it",
                     timeout_cycles, longest);
        end
    end
`elsif HADES_SLOW_MEM
    // ---- Cycle limit with a slow memory ----
    // Wait states make a program up to 1 + the longest wait times slower, so without +timeout
    // the default limit (100000 cycles) is multiplied by 1 + the longest read, write or beat
    // wait of the two RAM ports, as test/memsys/programs.py does for its runs. An explicit
    // +timeout=<cycles> is used as given. The loop at the top of the module compares its count
    // with timeout_cycles in every cycle, so the new limit takes effect.
    initial begin
        int longest;
        if (!$test$plusargs("timeout=")) begin
            @(posedge clk);                // the slow memories have read their options by now
            longest = int'(mcu.fetch_memory_delay.rd_max);
            if (int'(mcu.data_memory_delay.rd_max) > longest) longest = int'(mcu.data_memory_delay.rd_max);
            if (int'(mcu.data_memory_delay.wr_max) > longest) longest = int'(mcu.data_memory_delay.wr_max);
            if (mcu.fetch_memory_delay.beat_lat > longest) longest = mcu.fetch_memory_delay.beat_lat;
            if (mcu.data_memory_delay.beat_lat > longest) longest = mcu.data_memory_delay.beat_lat;
            if (longest > 0) begin
                timeout_cycles = timeout_cycles * (64'd1 + 64'(longest));
                $display("SLOW MEMORY cycle limit %0d: 100000 times 1 + the longest wait (%0d); +timeout=<cycles> sets it",
                         timeout_cycles, longest);
            end
        end
    end
`endif
endmodule
