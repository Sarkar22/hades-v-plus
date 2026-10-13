// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// csr_map.sv -- the CSR legality map of an instruction decoder (make csr-legal-check).
//
// Feeds the decoder every CSR instruction word: all 4096 addresses, the six forms (csrrw, csrrs,
// csrrc, csrrwi, csrrsi, csrrci), each with the rs1 (uimm) field 0 and then non-zero, and prints
// the addresses that some access may use, in the format of `python3 test/trapsweep/iss.py
// --csr-map`: '0x<addr> <12 letters>', L = no trap, '.' = illegal instruction. The decoder is
// rtl/instruction_decoder.sv, or the golden CPU's with +define+CSR_MAP_GOLDEN.
// ---------------------------------------------------------------------------------------------
module csr_map;
    logic [31:0]   word;
    instruction::t decoded;

`ifdef CSR_MAP_GOLDEN
    ref_instruction_decoder dec (.instruction_in(word), .instruction_out(decoded));
`else
    instruction_decoder dec (.instruction_in(word), .instruction_out(decoded));
`endif

    localparam bit [2:0] FUNCT3 [6] = '{3'd1, 3'd2, 3'd3, 3'd5, 3'd6, 3'd7};

    initial begin
        $display("# CSR legality map of the decoder: csrrw csrrs csrrc csrrwi csrrsi csrrci, each with the rs1/uimm field 0, then non-zero");
        for (int csr = 0; csr < 4096; csr++) begin
            string row;
            bit any;
            row = "";
            any = 1'b0;
            for (int f = 0; f < 6; f++) begin
                for (int rs1 = 0; rs1 < 2; rs1++) begin
                    word = {12'(csr), 5'(rs1), FUNCT3[f], 5'd0, 7'b1110011};
                    #1;
                    if (decoded.op != op::ILLEGAL) begin
                        row = {row, "L"};
                        any = 1'b1;
                    end else begin
                        row = {row, "."};
                    end
                end
            end
            if (any) $display("0x%03x %s", csr, row);
        end
        $finish;
    end
endmodule
