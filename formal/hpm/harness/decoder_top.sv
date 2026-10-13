// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// decoder_top.sv -- formal harness of the instruction decoder: the decoder of the tree under
// proof (instruction_decoder) and the decoder of the base commit (instruction_decoder_base,
// base/instruction_decoder_base.sv: that commit's rtl/instruction_decoder.sv with only its module
// name changed) read the same free 32-bit instruction word. The legal CSR set of the trap-sweep
// ISS (test/trapsweep/iss.py, CSR_VALID) comes from iss_csr_legal.svh, which
// formal/hpm/scripts/model.py writes from that table. The properties are in
// props/decoder_props.vh, inserted after sv2v before the final endmodule of this module.
// ---------------------------------------------------------------------------------------------
module decoder_top (
    input logic [31:0] word
);
    import op::*;

    instruction::t d_new, d_base;
    instruction_decoder      u_new  (.instruction_in(word), .instruction_out(d_new));
    instruction_decoder_base u_base (.instruction_in(word), .instruction_out(d_base));

`include "iss_csr_legal.svh"

    logic [2:0]  f3;
    logic [11:0] addr;
    logic        csr_form, at_mcountinhibit, writes, read_only, iss_legal;
    assign f3        = word[14:12];
    assign addr      = word[31:20];
    // the CSR words: SYSTEM opcode, funct3 1, 2, 3, 5, 6 or 7
    assign csr_form  = word[6:0] == 7'b1110011 && f3 != 3'd0 && f3 != 3'd4;
    assign at_mcountinhibit = csr_form && addr == 12'h320;
    // CSRRW and CSRRWI always write; the other forms write when the rs1 or uimm field is not 0
    assign writes    = f3 == 3'd1 || f3 == 3'd5 || word[19:15] != 5'd0;
    assign read_only = addr[11:10] == 2'b11;
    assign iss_legal = f_iss_csr_legal(addr);

    op::t f_csr_op;
    always_comb begin
        case (f3)
            3'd1:    f_csr_op = CSRRW;
            3'd2:    f_csr_op = CSRRS;
            3'd3:    f_csr_op = CSRRC;
            3'd5:    f_csr_op = CSRRWI;
            3'd6:    f_csr_op = CSRRSI;
            default: f_csr_op = CSRRCI;
        endcase
    end

    logic new_illegal, base_illegal, new_is_form_op, all_equal, rest_equal;
    assign new_illegal    = d_new.op == ILLEGAL;
    assign base_illegal   = d_base.op == ILLEGAL;
    assign new_is_form_op = d_new.op == f_csr_op;
    assign all_equal      = d_new == d_base;
    assign rest_equal     = d_new.rd_address == d_base.rd_address &&
                            d_new.rs1_address == d_base.rs1_address &&
                            d_new.rs2_address == d_base.rs2_address &&
                            d_new.csr == d_base.csr && d_new.immediate == d_base.immediate;
endmodule
