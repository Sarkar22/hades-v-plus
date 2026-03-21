/* Copyright (c) 2024 Tobias Scheipel, David Beikircher, Florian Riedl
 * Embedded Architectures & Systems Group, Graz University of Technology
 * SPDX-License-Identifier: MIT
 * ---------------------------------------------------------------------
 * File: register_file.sv
 */



module register_file (
    input logic clk,
    input logic rst,
    // read ports
    input  logic [4:0]  read_address1,
    output logic [31:0] read_data1,
    input  logic [4:0]  read_address2,
    output logic [31:0] read_data2,
    // write port
    input  logic [4:0]  write_address,
    input  logic [31:0] write_data,
    input  logic        write_enable
);

    // TODO: Delete the following line and implement this module.
    // ref_register_file golden(.*);

    logic[31:0] reg_file [31:0];

    // x0 is hardwired to 0 — reads from address 0 always return 0
    assign read_data1 = (read_address1 == 5'b0) ? 32'b0 : reg_file[read_address1];
    assign read_data2 = (read_address2 == 5'b0) ? 32'b0 : reg_file[read_address2];

    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset all registers to 0
            for (int i = 0; i < 32; i++) begin
                reg_file[i] <= 32'b0;
            end
        end else if (write_enable && write_address != 5'b0) begin
            // x0 is hardwired to 0 — never allow writes to it
            reg_file[write_address] <= write_data;
        end
    end

endmodule
