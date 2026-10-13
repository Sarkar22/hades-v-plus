// SPDX-License-Identifier: MIT
// =============================================================================================
// decoder_props.vh -- the properties of the instruction decoder (harness/decoder_top.sv),
// inserted after sv2v before the final endmodule of decoder_top. Combinational: the word is
// free, so a proof covers all 2^32 instruction words.
//   decoder_miter  the decoder of the tree equals the base commit's on every word and every
//                  output field, except on the CSR words at address 0x320 (mcountinhibit): there
//                  the base decoder gives ILLEGAL and the new one the CSR operation of the
//                  word's funct3, with every other field equal.
//   decoder_legal  on every CSR word, the decoder's op is not ILLEGAL exactly when the address is
//                  in the ISS's legal set and the word is not a write form at a read-only address
//                  (address bits 11:10 = 11); and then the op is the CSR operation of funct3.
// =============================================================================================
`ifdef FORMAL
    always @* begin
        `ifdef CHECK_DECODER_MITER
        if (at_mcountinhibit) begin
            assert(base_illegal);
            assert(new_is_form_op);
            assert(rest_equal);
        end else begin
            assert(all_equal);
        end
        `endif
        `ifdef CHECK_DECODER_LEGAL
        if (csr_form) begin
            assert(!new_illegal == (iss_legal && !(read_only && writes)));
            if (!new_illegal) assert(new_is_form_op);
        end
        `endif
        `ifdef COVERS
        cover(at_mcountinhibit && !new_illegal && f3 == 3'd1);
        cover(at_mcountinhibit && !new_illegal && f3 == 3'd7);
        cover(csr_form && addr == 12'h321 && new_illegal);
        cover(csr_form && read_only && writes && new_illegal && iss_legal);
        cover(csr_form && read_only && !writes && !new_illegal);
        `endif
    end
`endif
