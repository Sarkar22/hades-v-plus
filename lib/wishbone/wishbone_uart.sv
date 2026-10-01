/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: wishbone_uart.sv
 */



module wishbone_uart #(
    parameter bit [31:0] ADDRESS,
    parameter bit [31:0] SIZE,
    parameter bit [31:0] BAUD_RATE,
    parameter real CLK_FREQUENCY_MHZ
) (
    input logic clk,
    input logic rst,

    input  logic rx_serial_in,
    output logic tx_serial_out,

    output logic interrupt,

    wishbone_interface.slave wishbone
);

    // --------------------------------------------------------------------------------------------
    // |                                        Registers                                         |
    // --------------------------------------------------------------------------------------------

    /*
    <--------- TX STATUS ---------> <-------- RX STATUS ---------> <----------> <- BUFFER ->
    |           31...24           |||          23...16           |||  15...8  |||  7...0   |
    | 31-27|   26   |  25 |  24   ||| 23-19|   18  |  17 |  16   ||| 15-----8 ||| 7------0 |
    | xxxxx|TX_EMPTY|TX_IE|TX_ERR ||| xxxxx|RX_FULL|RX_IE|RX_ERR ||| xxxxxxxx |||  BUFFER  |
    */

    /*verilator lint_off UNUSED*/
    localparam TX_EMPTY_IDX = 26;
    localparam TX_IE_IDX    = 25;
    localparam TX_ERR_IDX   = 24;
    localparam RX_FULL_IDX  = 18;
    localparam RX_IE_IDX    = 17;
    localparam RX_ERR_IDX   = 16;
    localparam BUFFER_IDX   =  0;
    /*verilator lint_on UNUSED*/

    logic [7:0] tx_buffer_reg;
    logic       tx_err_reg;
    logic       tx_intr_enable_reg;
    logic       tx_buffer_empty;

    logic [7:0] rx_buffer_reg;
    logic       rx_err_reg;
    logic       rx_intr_enable_reg;
    logic       rx_buffer_full;

    // --------------------------------------------------------------------------------------------
    // |                                        Interrupt                                         |
    // --------------------------------------------------------------------------------------------

    logic rx_intr_enable_sig;
    always_comb begin
        rx_intr_enable_sig = rx_intr_enable_reg;
        if (wb_write_rx_status) begin
            rx_intr_enable_sig = wb_dat_mosi[RX_IE_IDX];
        end
    end

    logic tx_intr_enable_sig;
    always_comb begin
        tx_intr_enable_sig = tx_intr_enable_reg;
        // same write as tx_intr_enable_reg (TX status byte, sel[3]); was wb_write_rx_status,
        // copied from the RX block above (regression: test/asm/uartirq.s)
        if (wb_write_tx_status) begin
            tx_intr_enable_sig = wb_dat_mosi[TX_IE_IDX];
        end
    end

    assign interrupt = ((rx_buffer_full  && rx_intr_enable_sig) ||
                        (tx_buffer_empty && tx_intr_enable_sig) );

    // --------------------------------------------------------------------------------------------
    // |                                     UART Transmitter                                     |
    // --------------------------------------------------------------------------------------------

    logic tx_start;
    /*verilator lint_off UNUSED*/
    logic tx_done;
    /*verilator lint_on UNUSED*/
    logic tx_active;

    uart_tx #(
        .CLKS_PER_BIT(int'(CLK_FREQUENCY_MHZ*1_000_000.0/BAUD_RATE))
    ) uart_tx_module (
        .clk(clk),
        .rst(rst),
        .tx_start_in(tx_start),
        .tx_byte_in(tx_buffer_reg),
        .tx_serial_out(tx_serial_out),
        .tx_done_out(tx_done),
        .tx_active_out(tx_active)
    );

    // --------------------------------------------------------------------------------------------
    // TX - State Machine
    enum {
        TX_INIT,
        TX_BUFFER_EMPTY_IDLE,
        TX_BUFFER_FULL_START,
        TX_BUFFER_EMPTY_ACTIVE,
        TX_BUFFER_FULL_ACTIVE
    } tx_state;

    always_ff @(posedge clk) begin
        if (rst) begin
            tx_state <= TX_INIT;
        end
        else begin
            case(tx_state)
                TX_INIT: begin
                    tx_state <= TX_BUFFER_EMPTY_IDLE;
                end
                TX_BUFFER_EMPTY_IDLE: begin
                    if (wb_write_tx_buffer && tx_active) begin tx_state <= TX_BUFFER_EMPTY_ACTIVE; end // should not happen (tx started without start signal)
                    else if (wb_write_tx_buffer)         begin tx_state <= TX_BUFFER_FULL_START; end
                    else if (tx_active)                  begin tx_state <= TX_BUFFER_EMPTY_IDLE; end // should not happen (tx started without start signal)
                end
                TX_BUFFER_FULL_START: begin
                    if (wb_write_tx_buffer && tx_active) begin tx_state <= TX_BUFFER_FULL_ACTIVE; end
                    else if (wb_write_tx_buffer)         begin tx_state <= TX_BUFFER_FULL_START; end // signal error
                    else if (tx_active)                  begin tx_state <= TX_BUFFER_EMPTY_ACTIVE; end
                end
                TX_BUFFER_EMPTY_ACTIVE: begin
                    if (wb_write_tx_buffer && tx_active == 0) begin tx_state <= TX_BUFFER_FULL_START; end
                    else if (wb_write_tx_buffer)              begin tx_state <= TX_BUFFER_FULL_ACTIVE; end
                    else if (tx_active == 0)                  begin tx_state <= TX_BUFFER_EMPTY_IDLE; end
                end
                TX_BUFFER_FULL_ACTIVE: begin
                    if (wb_write_tx_buffer && tx_active == 0) begin tx_state <= TX_BUFFER_FULL_START; end // signal error
                    else if (wb_write_tx_buffer)              begin tx_state <= TX_BUFFER_FULL_ACTIVE; end // signal error
                    else if (tx_active == 0)                  begin tx_state <= TX_BUFFER_FULL_START; end
                end
                default: begin
                    tx_state <= TX_INIT;
                end
            endcase
        end
    end
    // --------------------------------------------------------------------------------------------
    // TX - Start signal
    assign tx_start = (tx_state == TX_BUFFER_FULL_START) ? 1 : 0;
    // --------------------------------------------------------------------------------------------
    // TX - Buffer Register
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_buffer_reg <= 0;
        end
        else begin
            case(tx_state)
                TX_INIT: begin
                    tx_buffer_reg <= 0;
                end
                TX_BUFFER_EMPTY_IDLE: begin
                    if (wb_write_tx_buffer && tx_active) begin tx_buffer_reg <= 0; end // should not happen (tx started without start signal)
                    else if (wb_write_tx_buffer)         begin tx_buffer_reg <= wb_dat_mosi[7:0]; end
                    else if (tx_active)                  begin tx_buffer_reg <= 0; end // should not happen (tx started without start signal)
                end
                TX_BUFFER_FULL_START: begin
                    if (wb_write_tx_buffer && tx_active) begin tx_buffer_reg <= wb_dat_mosi[7:0]; end
                    else if (wb_write_tx_buffer)         begin tx_buffer_reg <= wb_dat_mosi[7:0]; end // signal error
                    else if (tx_active)                  begin tx_buffer_reg <= 0; end
                end
                TX_BUFFER_EMPTY_ACTIVE: begin
                    if (wb_write_tx_buffer && tx_active == 0) begin tx_buffer_reg <= wb_dat_mosi[7:0]; end
                    else if (wb_write_tx_buffer)              begin tx_buffer_reg <= wb_dat_mosi[7:0]; end
                    else if (tx_active == 0)                  begin tx_buffer_reg <= tx_buffer_reg; end
                end
                TX_BUFFER_FULL_ACTIVE: begin
                    if (wb_write_tx_buffer && tx_active == 0) begin tx_buffer_reg <= wb_dat_mosi[7:0]; end // signal error
                    else if (wb_write_tx_buffer)              begin tx_buffer_reg <= wb_dat_mosi[7:0]; end // signal error
                    else if (tx_active == 0)                  begin tx_buffer_reg <= tx_buffer_reg; end
                end
                default: begin
                    tx_buffer_reg <= 0;
                end
            endcase
        end
    end
    // --------------------------------------------------------------------------------------------
    // TX - Buffer empty
    always_comb begin
        case(tx_state)
            TX_INIT:                begin tx_buffer_empty = 1'b1; end
            TX_BUFFER_EMPTY_IDLE:   begin tx_buffer_empty = 1'b1; end
            TX_BUFFER_FULL_START:   begin tx_buffer_empty = 1'b0; end
            TX_BUFFER_EMPTY_ACTIVE: begin tx_buffer_empty = 1'b1; end
            TX_BUFFER_FULL_ACTIVE:  begin tx_buffer_empty = 1'b0; end
            default:                begin tx_buffer_empty = 1'b1; end
        endcase
    end
    // --------------------------------------------------------------------------------------------
    // TX - Error
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_err_reg <= 0;
        end
        else begin
            if (tx_state == TX_BUFFER_FULL_START && (wb_write_tx_buffer)) begin
                tx_err_reg <= 1;
            end
            else if (tx_state == TX_BUFFER_FULL_ACTIVE && (wb_write_tx_buffer)) begin
                tx_err_reg <= 1;
            end
            else if (wb_write_tx_status) begin
                tx_err_reg <= wb_dat_mosi[TX_ERR_IDX];
            end
            else if (wb_read_tx_status) begin // clear on read
                tx_err_reg <= 0;
            end
        end
    end
    // --------------------------------------------------------------------------------------------
    // TX - Interrupt enable
    always_ff @(posedge clk) begin
        if (rst) begin
            tx_intr_enable_reg <= 0;
        end
        else begin
            if (wb_write_tx_status) begin
                tx_intr_enable_reg <= wb_dat_mosi[TX_IE_IDX];
            end
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                      UART Receiver                                       |
    // --------------------------------------------------------------------------------------------

    logic [7:0] rx_recieved_byte_sig;
    logic       rx_done;
    /*verilator lint_off UNUSED*/
    logic       rx_receiver_err_sig;
    /*verilator lint_on UNUSED*/

    uart_rx #(
        .CLKS_PER_BIT(int'(CLK_FREQUENCY_MHZ*1_000_000.0/BAUD_RATE))
    ) uart_rx_module (
        .clk(clk),
        .rst(rst),
        .rx_serial_in(rx_serial_in),
        .rx_byte_out(rx_recieved_byte_sig),
        .rx_done_out(rx_done),
        .rx_error_out(rx_receiver_err_sig)
    );

    // --------------------------------------------------------------------------------------------
    // RX - State Machine
    enum {
        RX_INIT,
        RX_BUFFER_EMPTY,
        RX_BUFFER_FULL
    } rx_state;

    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state <= RX_INIT;
        end
        else begin
            case(rx_state)
                RX_INIT: begin
                    rx_state <= RX_BUFFER_EMPTY;
                end
                RX_BUFFER_EMPTY: begin
                    if (wb_read_rx_buffer && rx_done == 1) begin rx_state <= RX_BUFFER_EMPTY; end // set rx_buffer_sig and clear buffer reg
                    else if (wb_read_rx_buffer)            begin rx_state <= RX_BUFFER_EMPTY; end
                    else if (rx_done == 1)                 begin rx_state <= RX_BUFFER_FULL; end
                end
                RX_BUFFER_FULL: begin
                    if (wb_read_rx_buffer && rx_done == 1) begin rx_state <= RX_BUFFER_FULL; end // set rx_buffer_reg to new value and return old one
                    else if (wb_read_rx_buffer)            begin rx_state <= RX_BUFFER_EMPTY; end
                    else if (rx_done == 1)                 begin rx_state <= RX_BUFFER_FULL; end // signal error
                end
                default: begin
                    rx_state <= RX_INIT;
                end
            endcase
        end
    end
    // --------------------------------------------------------------------------------------------
    // RX - Buffer Register
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_buffer_reg <= 0;
        end
        else begin
            case(rx_state)
                RX_INIT: begin
                    rx_buffer_reg <= 0;
                end
                RX_BUFFER_EMPTY: begin
                    if (wb_read_rx_buffer && rx_done == 1) begin rx_buffer_reg <= 0; end // set rx_buffer_sig and clear buffer reg
                    else if (wb_read_rx_buffer)            begin rx_buffer_reg <= 0; end
                    else if (rx_done == 1)                 begin rx_buffer_reg <= rx_recieved_byte_sig; end
                end
                RX_BUFFER_FULL: begin
                    if (wb_read_rx_buffer && rx_done == 1) begin rx_buffer_reg <= rx_recieved_byte_sig; end // set rx_buffer_reg to new value and return old one
                    else if (wb_read_rx_buffer)            begin rx_buffer_reg <= 0; end
                    else if (rx_done == 1)                 begin rx_buffer_reg <= rx_recieved_byte_sig; end // signal error
                end
                default: begin
                    rx_buffer_reg <= 0;
                end
            endcase
        end
    end

    logic [7:0] rx_buffer_sig;
    always_comb begin
        rx_buffer_sig = rx_buffer_reg;
        if (rx_state == RX_BUFFER_EMPTY && (wb_read_rx_buffer && rx_done == 1)) begin
            rx_buffer_sig = rx_recieved_byte_sig;
        end
    end
    // --------------------------------------------------------------------------------------------
    // RX - Buffer full
    always_comb begin
        case(rx_state)
            RX_INIT:         begin rx_buffer_full = 0; end
            RX_BUFFER_EMPTY: begin rx_buffer_full = (wb_read_rx_buffer && rx_done == 1) ? 1 : 0; end
            RX_BUFFER_FULL:  begin rx_buffer_full = 1; end
            default:         begin rx_buffer_full = 0; end
        endcase
    end
    // --------------------------------------------------------------------------------------------
    // RX - Error
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_err_reg <= 0;
        end
        else begin
            if (rx_state == RX_BUFFER_FULL && (wb_read_rx_buffer == 0 && rx_done == 1)) begin
                rx_err_reg <= 1;
            end
            else if (wb_write_rx_status) begin
                rx_err_reg <= wb_dat_mosi[RX_ERR_IDX];
            end
            else if (wb_read_rx_status) begin // clear on read
                rx_err_reg <= 0;
            end
        end
    end
    // --------------------------------------------------------------------------------------------
    // RX - Interrupt enable
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_intr_enable_reg <= 0;
        end
        else begin
            if (wb_write_rx_status) begin
                rx_intr_enable_reg <= wb_dat_mosi[RX_IE_IDX];
            end
        end
    end

    // --------------------------------------------------------------------------------------------
    // |                                         Wishbone                                         |
    // --------------------------------------------------------------------------------------------

    /*verilator lint_off UNUSED*/
    logic [31:0] wb_dat_mosi;
    assign       wb_dat_mosi = wishbone.dat_mosi;

    logic  wb_access;
    assign wb_access = (wishbone.cyc && wishbone.stb && wishbone.ack == 0 && wishbone.err == 0) && // wb cycle
                       (wishbone.adr >= ADDRESS && wishbone.adr < ADDRESS + SIZE); // wb address valid

    logic [3:0] wb_write_sel;
    assign      wb_write_sel = (wb_access && wishbone.we) ? wishbone.sel : 0;
    /*verilator lint_on UNUSED*/

    always_ff @(posedge clk) begin
        if (rst) begin
            wishbone.ack      <= 0;
            wishbone.err      <= 0;
            wishbone.dat_miso <= 0;
        end
        else begin
            // default output
            wishbone.ack      <= 0;
            wishbone.err      <= 0;
            wishbone.dat_miso <= 0;
            // wishbone access
            if (wishbone.cyc && wishbone.stb && wishbone.ack == 0 && wishbone.err == 0) begin
                // check address space
                if (wishbone.adr >= ADDRESS && wishbone.adr < ADDRESS + SIZE) begin
                    wishbone.ack <= 1;
                    wishbone.err <= 0;
                    if (wishbone.we == 0) begin
                        // read
                        wishbone.dat_miso <= { 5'b0, tx_buffer_empty, tx_intr_enable_reg, tx_err_reg,
                                               5'b0, rx_buffer_full,  rx_intr_enable_reg, rx_err_reg,
                                               8'b0,
                                               rx_buffer_sig
                                             };
                    end
                end
                else begin
                    wishbone.ack <= 0;
                    wishbone.err <= 1;
                end
            end
        end
    end

    // Helper signals detecting individual read/write
    logic  wb_read_rx_buffer, wb_write_tx_buffer;
    assign wb_read_rx_buffer  = wb_access && wishbone.we == 0 && wishbone.sel[0];
    assign wb_write_tx_buffer = wb_access && wishbone.we == 1 && wishbone.sel[0];

    logic  wb_read_rx_status, wb_write_rx_status;
    assign wb_read_rx_status  = wb_access && wishbone.we == 0 && wishbone.sel[2];
    assign wb_write_rx_status = wb_access && wishbone.we == 1 && wishbone.sel[2];

    logic  wb_read_tx_status, wb_write_tx_status;
    assign wb_read_tx_status  = wb_access && wishbone.we == 0 && wishbone.sel[3];
    assign wb_write_tx_status = wb_access && wishbone.we == 1 && wishbone.sel[3];

    // --------------------------------------------------------------------------------------------
    // |                              Simulation UART stdout echo                                  |
    // --------------------------------------------------------------------------------------------
    // In Verilator simulation there is no real serial line, so echo every byte
    // written to the TX buffer directly to the simulator's stdout via $write.
    // Has zero effect on synthesis (Vivado ignores $write).
    always @(posedge clk) begin
        if (wb_write_tx_buffer)
            $write("%c", wb_dat_mosi[7:0]);
    end

endmodule
