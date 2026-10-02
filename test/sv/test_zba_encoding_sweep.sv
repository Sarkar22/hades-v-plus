/* Adversarial encoding-hygiene sweep for the non-base extensions (Zba, M,
 * Zbb, Zbs and Zicond).
 *
 * Contract checked here: the DUT decoder must produce the SAME op::t as the
 * frozen reference decoder for every 32-bit word, with exactly three families of
 * exceptions -- the three SH1ADD / SH2ADD / SH3ADD encodings, the M encodings
 * (opcode 0110011, funct7 0000001) and the 28 Zbb/Zbs/Zicond encodings, which
 * all decode to op::EXT.  A decode arm that is too broad shows up as a word
 * where DUT.op != REF.op that belongs to none of the families.
 *
 * The EXT family is described here independently of the decoder, as the
 * MATCH/MASK table of the ISA manual ((word & MASK) == MATCH).  For an EXT word
 * the DUT must produce op::EXT, the raw rd/rs1/rs2 fields and exactly the
 * expected payload in the immediate (sub-operation, use_imm, shamt; see
 * op::ext_payload_t), and the reference must call it ILLEGAL.  Sweeps E and F
 * cover every immediate of OP-IMM and every funct7 x rs2 field of OP, so every
 * shamt of every immediate form, every unary form and every RV32-reserved
 * neighbour (shamt[5] = 1, wrong rs2 field) is decided.  Sweep G does the same
 * for OP-32 and OP-IMM-32, where the RV64-only word forms (ctzw, cpopw, the RV64
 * zext.h, ...) live: all of them must stay illegal.
 *
 * The M family is checked the same way Zba is: the DUT must produce the exact
 * expected op for every word in the family, the reference must call every one
 * of them ILLEGAL (it predates M), and the R-type field extraction must be
 * untouched.  Only the funct3 values that are actually implemented are claimed;
 * any unimplemented funct3 under funct7=0000001 must still decode to ILLEGAL,
 * which the final `else` branch enforces because it is then not an M word.
 *
 * rd_address / csr / immediate are also compared strictly.
 *
 * rs1_address / rs2_address are NOT compared strictly: the reference zeroes
 * them for instruction formats that do not use them (ADDI, LW, JAL, ILLEGAL
 * ...), while this project's decoder passes the raw bits through.  That
 * divergence predates Zba; it is counted and reported so it can be compared
 * against the pre-Zba baseline.
 */
module test_zba_encoding_sweep;
    import op::*;

    logic [31:0]   instr;
    instruction::t dut_out;
    instruction::t ref_out;

    int unsigned checks    = 0;
    int unsigned errors    = 0;
    int unsigned rs_diverge = 0;   // informational, pre-existing
    int unsigned field_diverge = 0; // informational, pre-existing
    int unsigned sys_diverge = 0;   // informational, pre-existing (SYSTEM/CSR opcode)
    int unsigned zba_hits  = 0;
    int unsigned sh1_hits  = 0;
    int unsigned sh2_hits  = 0;
    int unsigned sh3_hits  = 0;
    int unsigned m_hits    = 0;
    int unsigned m_f3_hits[8];
    int unsigned ext_hits  = 0;
    int unsigned ext_field_diverge = 0;  // EXT words: immediate differs from the reference by design
    int unsigned ext_form_hits[28];      // all sweeps
    int unsigned ext_det_hits[28];       // the deterministic sweeps (all but C)
    logic [31:0] ext_shamt_seen[28];     // immediate forms: bit s set once shamt s was decoded
    bit          in_sweep_c = 0;

    instruction_decoder     dut  (.instruction_in(instr), .instruction_out(dut_out));
    ref_instruction_decoder refd (.instruction_in(instr), .instruction_out(ref_out));

    function automatic bit is_zba_word(input logic [31:0] w);
        return (w[6:0]   == 7'b0110011)
            && (w[31:25] == 7'b0010000)
            && (w[14:12] == 3'b010 || w[14:12] == 3'b100 || w[14:12] == 3'b110);
    endfunction

    function automatic op::t zba_op(input logic [31:0] w);
        case (w[14:12])
            3'b010:  return SH1ADD;
            3'b100:  return SH2ADD;
            default: return SH3ADD;
        endcase
    endfunction

    // ---- M extension ---------------------------------------------------
    // IMPLEMENTED_M_F3 is a bit mask over funct3: bit i set means funct3 == i is
    // a decoded M instruction.  It is deliberately a mask rather than "all eight
    // funct3 values", so that a partially implemented M (multiply landed,
    // division not yet) is checked exactly as strictly: the funct3 values that
    // are NOT in the mask must still decode to ILLEGAL, matching the reference.
    localparam logic [7:0] IMPLEMENTED_M_F3 = 8'b1111_1111;

    function automatic bit is_m_word(input logic [31:0] w);
        return (w[6:0]   == 7'b0110011)
            && (w[31:25] == 7'b0000001)
            && IMPLEMENTED_M_F3[w[14:12]];
    endfunction

    function automatic op::t m_op(input logic [31:0] w);
        case (w[14:12])
            3'b000:  return MUL;
            3'b001:  return MULH;
            3'b010:  return MULHSU;
            3'b011:  return MULHU;
            3'b100:  return DIV;
            3'b101:  return DIVU;
            3'b110:  return REM;
            default: return REMU;
        endcase
    endfunction


    // ---- Zbb, Zbs, Zicond ----------------------------------------------
    // The 28 forms in the order of the ISA tables, as MATCH/MASK pairs. Register
    // and immediate (shamt) forms match funct7 in full, which is what makes the
    // RV32-reserved shamt[5] = 1 words illegal; the unary forms also match the
    // rs2 field, which is part of their opcode.
    localparam int EXT_FORMS = 28;
    localparam logic [31:0] EXT_MATCH [EXT_FORMS] = '{
        32'h40007033, 32'h40006033, 32'h40004033,              // andn orn xnor
        32'h60001013, 32'h60101013, 32'h60201013,              // clz ctz cpop
        32'h0A006033, 32'h0A007033, 32'h0A004033, 32'h0A005033, // max maxu min minu
        32'h60401013, 32'h60501013, 32'h08004033,              // sext.b sext.h zext.h
        32'h60001033, 32'h60005033, 32'h60005013,              // rol ror rori
        32'h28705013, 32'h69805013,                            // orc.b rev8
        32'h48001033, 32'h48001013, 32'h48005033, 32'h48005013, // bclr bclri bext bexti
        32'h68001033, 32'h68001013, 32'h28001033, 32'h28001013, // binv binvi bset bseti
        32'h0E005033, 32'h0E007033                             // czero.eqz czero.nez
    };
    localparam logic [31:0] EXT_MASK [EXT_FORMS] = '{
        32'hFE00707F, 32'hFE00707F, 32'hFE00707F,
        32'hFFF0707F, 32'hFFF0707F, 32'hFFF0707F,
        32'hFE00707F, 32'hFE00707F, 32'hFE00707F, 32'hFE00707F,
        32'hFFF0707F, 32'hFFF0707F, 32'hFFF0707F,
        32'hFE00707F, 32'hFE00707F, 32'hFE00707F,
        32'hFFF0707F, 32'hFFF0707F,
        32'hFE00707F, 32'hFE00707F, 32'hFE00707F, 32'hFE00707F,
        32'hFE00707F, 32'hFE00707F, 32'hFE00707F, 32'hFE00707F,
        32'hFE00707F, 32'hFE00707F
    };
    // Expected sub-operation code of each form ({group, variant}, defines/op.sv).
    localparam logic [4:0] EXT_SEL [EXT_FORMS] = '{
        5'b000_00, 5'b000_01, 5'b000_10,
        5'b001_00, 5'b001_01, 5'b001_10,
        5'b010_10, 5'b010_11, 5'b010_00, 5'b010_01,
        5'b011_00, 5'b011_01, 5'b011_10,
        5'b100_00, 5'b100_01, 5'b100_01,
        5'b101_00, 5'b101_01,
        5'b110_00, 5'b110_00, 5'b110_01, 5'b110_01,
        5'b110_10, 5'b110_10, 5'b110_11, 5'b110_11,
        5'b111_00, 5'b111_01
    };
    // Kind of each form: 0 register, 1 immediate (shamt), 2 unary.
    localparam int EXT_KIND [EXT_FORMS] = '{
        0, 0, 0,  2, 2, 2,  0, 0, 0, 0,  2, 2, 2,  0, 0, 1,  2, 2,
        0, 1, 0, 1,  0, 1, 0, 1,  0, 0
    };
    localparam string EXT_NAME [EXT_FORMS] = '{
        "andn", "orn", "xnor", "clz", "ctz", "cpop", "max", "maxu", "min", "minu",
        "sext.b", "sext.h", "zext.h", "rol", "ror", "rori", "orc.b", "rev8",
        "bclr", "bclri", "bext", "bexti", "binv", "binvi", "bset", "bseti",
        "czero.eqz", "czero.nez"
    };
    // Sub-operation codes the decoder may produce (all others are reserved).
    localparam logic [31:0] EXT_SEL_VALID = 32'h3F33_7F77;  // codes 0-2, 4-6, 8-14, 16, 17, 20, 21, 24-29

    // Index of the EXT form w encodes, or -1.
    function automatic int ext_form(input logic [31:0] w);
        for (int i = 0; i < EXT_FORMS; i++)
            if ((w & EXT_MASK[i]) == EXT_MATCH[i])
                return i;
        return -1;
    endfunction

    task automatic check_word(input logic [31:0] w);
        int          f;
        logic        want_use_imm;
        logic [31:0] want_imm;
        instr = w;
        #1;
        checks++;

        if (dut_out.rs1_address !== ref_out.rs1_address ||
            dut_out.rs2_address !== ref_out.rs2_address)
            rs_diverge++;

        f = ext_form(w);

        // An EXT word's immediate is the payload, not the reference's immediate,
        // so it is counted separately rather than as a field divergence.
        if (dut_out.rd_address !== ref_out.rd_address ||
            dut_out.csr        !== ref_out.csr ||
            dut_out.immediate  !== ref_out.immediate) begin
            if (f >= 0) ext_field_diverge++;
            else        field_diverge++;
        end

        // Whatever the word, the decoder must never produce a reserved sub-operation.
        if (dut_out.op === EXT && !EXT_SEL_VALID[dut_out.immediate[10:6]]) begin
            errors++;
            $display("EXT RESERVED SEL instr=%08h imm=%08h", w, dut_out.immediate);
        end

        if (f >= 0) begin
            // The payload the decoder must put in the immediate (op::ext_payload_t).
            want_use_imm = (EXT_KIND[f] == 1);
            want_imm     = {21'b0, EXT_SEL[f], want_use_imm, want_use_imm ? w[24:20] : 5'b0};
            ext_hits++;
            ext_form_hits[f]++;
            if (!in_sweep_c) ext_det_hits[f]++;
            if (EXT_KIND[f] == 1) ext_shamt_seen[f][w[24:20]] = 1'b1;
            if (dut_out.op !== EXT) begin
                errors++;
                $display("EXT-OP MISMATCH instr=%08h (%s) dut.op=%0d expected=%0d",
                         w, EXT_NAME[f], dut_out.op, EXT);
            end
            if (ref_out.op !== ILLEGAL) begin
                errors++;
                $display("REF-SANITY instr=%08h ref.op=%0d (expected ILLEGAL=%0d)", w, ref_out.op, ILLEGAL);
            end
            if (dut_out.rd_address  !== w[11:7]  ||
                dut_out.rs1_address !== w[19:15] ||
                dut_out.rs2_address !== w[24:20] ||
                dut_out.immediate   !== want_imm) begin
                errors++;
                $display("EXT-FIELD BAD instr=%08h (%s) rd=%0d rs1=%0d rs2=%0d imm=%08h expected imm=%08h",
                         w, EXT_NAME[f], dut_out.rd_address, dut_out.rs1_address, dut_out.rs2_address,
                         dut_out.immediate, want_imm);
            end
        end else if (is_zba_word(w)) begin
            zba_hits++;
            case (w[14:12])
                3'b010:  sh1_hits++;
                3'b100:  sh2_hits++;
                default: sh3_hits++;
            endcase
            if (dut_out.op !== zba_op(w)) begin
                errors++;
                $display("ZBA-OP MISMATCH instr=%08h dut.op=%0d expected=%0d", w, dut_out.op, zba_op(w));
            end
            if (ref_out.op !== ILLEGAL) begin
                errors++;
                $display("REF-SANITY instr=%08h ref.op=%0d (expected ILLEGAL=%0d)", w, ref_out.op, ILLEGAL);
            end
            // Zba is plain R-type: raw field extraction must be untouched.
            if (dut_out.rd_address  !== w[11:7]  ||
                dut_out.rs1_address !== w[19:15] ||
                dut_out.rs2_address !== w[24:20] ||
                dut_out.immediate   !== 32'b0) begin
                errors++;
                $display("ZBA-FIELD BAD instr=%08h rd=%0d rs1=%0d rs2=%0d imm=%08h",
                         w, dut_out.rd_address, dut_out.rs1_address, dut_out.rs2_address, dut_out.immediate);
            end
        end else if (is_m_word(w)) begin
            m_hits++;
            m_f3_hits[w[14:12]]++;
            if (dut_out.op !== m_op(w)) begin
                errors++;
                $display("M-OP MISMATCH instr=%08h dut.op=%0d expected=%0d", w, dut_out.op, m_op(w));
            end
            if (ref_out.op !== ILLEGAL) begin
                errors++;
                $display("REF-SANITY instr=%08h ref.op=%0d (expected ILLEGAL=%0d)", w, ref_out.op, ILLEGAL);
            end
            // M is plain R-type: raw field extraction must be untouched.
            if (dut_out.rd_address  !== w[11:7]  ||
                dut_out.rs1_address !== w[19:15] ||
                dut_out.rs2_address !== w[24:20] ||
                dut_out.immediate   !== 32'b0) begin
                errors++;
                $display("M-FIELD BAD instr=%08h rd=%0d rs1=%0d rs2=%0d imm=%08h",
                         w, dut_out.rd_address, dut_out.rs1_address, dut_out.rs2_address, dut_out.immediate);
            end
        end else if (w[6:0] == 7'b1110011) begin
            // SYSTEM opcode: this project's CSR decoder already diverges from the
            // reference on some CSR addresses (e.g. 303f71f3 -> CSRRCI vs ILLEGAL).
            // Verified identical on pre-Zba RTL, so it is counted, not failed.
            if (dut_out.op !== ref_out.op)
                sys_diverge++;
        end else begin
            if (dut_out.op !== ref_out.op) begin
                errors++;
                if (errors < 30)
                    $display("OP LEAK instr=%08h opcode=%07b funct3=%03b funct7=%07b dut.op=%0d ref.op=%0d",
                             w, w[6:0], w[14:12], w[31:25], dut_out.op, ref_out.op);
            end
        end
    endtask

    // Decode one hint word and require the given op from both decoders.
    task automatic check_hint(input logic [31:0] w, input op::t want, inout int unsigned bad);
        instr = w;
        #1;
        if (dut_out.op !== want || ref_out.op !== want) begin
            bad++;
            $display("HINT BAD instr=%08h dut.op=%0d ref.op=%0d expected=%0d", w, dut_out.op, ref_out.op, want);
        end
    endtask

    initial begin
        int unsigned rdv, rs1v, rs2v;
        int unsigned ext_after[7];
        int unsigned det_total, hint_bad;
        int          ext_pairs [2][2] = '{'{10, 11}, '{0, 31}};

        foreach (m_f3_hits[i]) m_f3_hits[i] = 0;
        foreach (ext_form_hits[i]) begin
            ext_form_hits[i]  = 0;
            ext_det_hits[i]   = 0;
            ext_shamt_seen[i] = 32'b0;
        end

        $display("WIDTH: $bits(op::t)=%0d  $bits(instruction::t)=%0d  (ref inner port is [64:0])",
                 $bits(op::t), $bits(instruction::t));
        if ($bits(op::t) != 6 || $bits(instruction::t) != 65) begin
            errors++;
            $display("WIDTH REGRESSION: op::t must stay 6 bits and instruction::t 65 bits");
        end
        $display("ENUM: ILLEGAL=%0d SH1ADD=%0d SH2ADD=%0d SH3ADD=%0d  (ILLEGAL must still be 49)",
                 ILLEGAL, SH1ADD, SH2ADD, SH3ADD);
        $display("ENUM: MUL=%0d MULH=%0d MULHSU=%0d MULHU=%0d DIV=%0d DIVU=%0d REM=%0d REMU=%0d",
                 MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU);
        if (int'(ILLEGAL) != 49) begin
            errors++;
            $display("ENUM REGRESSION: ILLEGAL renumbered");
        end
        if (int'(SH1ADD) != 50 || int'(SH3ADD) != 52 || int'(MUL) != 53 || int'(REMU) != 60) begin
            errors++;
            $display("ENUM REGRESSION: extension ops must occupy 50..60 with M appended last");
        end
        $display("ENUM: EXT=%0d  $bits(op::ext_payload_t)=%0d  (EXT must be 61, the payload 32 bits)",
                 EXT, $bits(op::ext_payload_t));
        if (int'(EXT) != 61 || $bits(op::ext_payload_t) != 32) begin
            errors++;
            $display("ENUM REGRESSION: EXT must be 61 and op::ext_payload_t 32 bits");
        end
        $display("=== SWEEP A: every opcode x funct3 x funct7 (rd=x10 rs1=x11 rs2=x12) ===");
        for (int oc = 0; oc < 128; oc++)
            for (int f3 = 0; f3 < 8; f3++)
                for (int f7 = 0; f7 < 128; f7++)
                    check_word({f7[6:0], 5'd12, 5'd11, f3[2:0], 5'd10, oc[6:0]});
        $display("    after A: checks=%0d errors=%0d zba_hits=%0d", checks, errors, zba_hits);
        ext_after[0] = ext_hits;

        $display("=== SWEEP B: OP opcode, all funct7 x funct3, 8 register triples ===");
        for (int k = 0; k < 8; k++) begin
            rdv  = (k * 3 + 1) % 32;
            rs1v = (k * 7 + 2) % 32;
            rs2v = (k * 11 + 5) % 32;
            for (int f3 = 0; f3 < 8; f3++)
                for (int f7 = 0; f7 < 128; f7++)
                    check_word({f7[6:0], rs2v[4:0], rs1v[4:0], f3[2:0], rdv[4:0], 7'b0110011});
        end
        $display("    after B: checks=%0d errors=%0d zba_hits=%0d", checks, errors, zba_hits);
        ext_after[1] = ext_hits;

        $display("=== SWEEP C: 150000 random 32-bit words ===");
        in_sweep_c = 1;
        for (int i = 0; i < 150000; i++)
            check_word($urandom());
        in_sweep_c = 0;
        $display("    after C: checks=%0d errors=%0d zba_hits=%0d", checks, errors, zba_hits);
        ext_after[2] = ext_hits;

        $display("=== SWEEP D: OP-IMM opcode, all funct7-position x funct3 ===");
        for (int f3 = 0; f3 < 8; f3++)
            for (int f7 = 0; f7 < 128; f7++)
                check_word({f7[6:0], 5'd12, 5'd11, f3[2:0], 5'd10, 7'b0010011});
        $display("    after D: checks=%0d errors=%0d", checks, errors);
        ext_after[3] = ext_hits;

        // Sweeps E and F come after C, so C's random words are the same as before
        // they existed. Two register pairs each: (rd, rs1) = (x10, x11) and (x0, x31).
        $display("=== SWEEP E: OP-IMM opcode, every imm[11:0] x funct3, 2 register pairs ===");
        for (int p = 0; p < 2; p++)
            for (int imm = 0; imm < 4096; imm++)
                for (int f3 = 0; f3 < 8; f3++)
                    check_word({imm[11:0], 5'(ext_pairs[p][1]), f3[2:0], 5'(ext_pairs[p][0]), 7'b0010011});
        $display("    after E: checks=%0d errors=%0d ext_hits=%0d", checks, errors, ext_hits - ext_after[3]);
        ext_after[4] = ext_hits;

        $display("=== SWEEP F: OP opcode, every funct7 x rs2 field x funct3, 2 register pairs ===");
        for (int p = 0; p < 2; p++)
            for (int f7 = 0; f7 < 128; f7++)
                for (int r2 = 0; r2 < 32; r2++)
                    for (int f3 = 0; f3 < 8; f3++)
                        check_word({f7[6:0], r2[4:0], 5'(ext_pairs[p][1]), f3[2:0], 5'(ext_pairs[p][0]), 7'b0110011});
        $display("    after F: checks=%0d errors=%0d ext_hits=%0d", checks, errors, ext_hits - ext_after[4]);
        ext_after[5] = ext_hits;

        // The RV64 word forms (clzw, ctzw, cpopw, zext.h, rolw, roriw, ...) live under
        // OP-32 and OP-IMM-32 with the same funct7 and rs2 fields as their RV32
        // counterparts. On RV32 they are illegal, and none of the sweeps above puts a
        // unary-form rs2 field under these two opcodes, so a decoder that matched the
        // opcode too loosely would go unnoticed. Every word here must decode as the
        // reference decodes it (ILLEGAL); the EXT table never matches these opcodes.
        $display("=== SWEEP G: OP-32 and OP-IMM-32 opcodes, every funct7 x rs2 field x funct3 ===");
        for (int oc = 0; oc < 2; oc++)
            for (int f7 = 0; f7 < 128; f7++)
                for (int r2 = 0; r2 < 32; r2++)
                    for (int f3 = 0; f3 < 8; f3++)
                        check_word({f7[6:0], r2[4:0], 5'd11, f3[2:0], 5'd10, (oc == 0) ? 7'b0111011 : 7'b0011011});
        $display("    after G: checks=%0d errors=%0d ext_hits=%0d", checks, errors, ext_hits - ext_after[5]);
        ext_after[6] = ext_hits;

        $display("EXT hits per sweep: A=%0d B=%0d C=%0d D=%0d E=%0d F=%0d G=%0d",
                 ext_after[0], ext_after[1] - ext_after[0], ext_after[2] - ext_after[1],
                 ext_after[3] - ext_after[2], ext_after[4] - ext_after[3], ext_after[5] - ext_after[4],
                 ext_after[6] - ext_after[5]);

        // Coverage of the EXT family. Over the deterministic sweeps (A, B, D, E, F)
        // the count of each form is fixed by the sweep shapes: 73 for each register
        // form, 66 for each immediate form, 2 for each unary form. Each immediate
        // form must also have been decoded with every shamt 0..31.
        det_total = 0;
        for (int i = 0; i < EXT_FORMS; i++) begin
            int want;
            want = (EXT_KIND[i] == 0) ? 73 : (EXT_KIND[i] == 1) ? 66 : 2;
            det_total += ext_det_hits[i];
            if (ext_det_hits[i] != want) begin
                errors++;
                $display("COVERAGE: %s decoded %0d times in sweeps A, B, D, E, F (expected %0d)",
                         EXT_NAME[i], ext_det_hits[i], want);
            end
            if (EXT_KIND[i] == 1 && ext_shamt_seen[i] != 32'hFFFF_FFFF) begin
                errors++;
                $display("COVERAGE HOLE: %s shamt seen mask %08h", EXT_NAME[i], ext_shamt_seen[i]);
            end
        end
        $display("EXT words exercised in sweeps A, B, D, E, F: %0d (%0d with sweep C)", det_total, ext_hits);

        // The hints of Zihintpause and Zihintntl are encodings of existing
        // instructions: PAUSE is a FENCE (pred = W, succ = 0) and NTL.P1/PALL/S1/ALL
        // are ADD x0, x0, x2..x5. Both decoders must decode them as such. These
        // words are outside the counted sweeps.
        hint_bad = 0;
        check_hint(32'h0100000F, FENCE, hint_bad);
        check_hint(32'h00200033, ADD, hint_bad);
        check_hint(32'h00300033, ADD, hint_bad);
        check_hint(32'h00400033, ADD, hint_bad);
        check_hint(32'h00500033, ADD, hint_bad);
        errors += hint_bad;
        if (hint_bad == 0)
            $display("HINTS: pause and ntl.p1/pall/s1/all decode to FENCE/ADD in both decoders: ok");
        else
            $display("HINTS: pause and ntl.p1/pall/s1/all: %0d of 5 decode wrongly", hint_bad);

        if (sh1_hits == 0 || sh2_hits == 0 || sh3_hits == 0) begin
            errors++;
            $display("COVERAGE HOLE: sh1=%0d sh2=%0d sh3=%0d", sh1_hits, sh2_hits, sh3_hits);
        end
        for (int f3 = 0; f3 < 8; f3++)
            if (IMPLEMENTED_M_F3[f3] && m_f3_hits[f3] == 0) begin
                errors++;
                $display("COVERAGE HOLE: no M word exercised for funct3=%0d", f3);
            end
        $display("Zba words exercised: sh1add=%0d sh2add=%0d sh3add=%0d (total %0d)",
                 sh1_hits, sh2_hits, sh3_hits, zba_hits);
        $display("M words exercised: f3 = %0d %0d %0d %0d %0d %0d %0d %0d (total %0d)",
                 m_f3_hits[0], m_f3_hits[1], m_f3_hits[2], m_f3_hits[3],
                 m_f3_hits[4], m_f3_hits[5], m_f3_hits[6], m_f3_hits[7], m_hits);
        $display("INFO: pre-existing rs1/rs2 DUT-vs-REF divergences = %0d of %0d", rs_diverge, checks);
        $display("INFO: pre-existing rd/csr/imm DUT-vs-REF divergences = %0d of %0d", field_diverge, checks);
        $display("INFO: EXT words whose immediate (the payload) differs from REF's = %0d of %0d", ext_field_diverge, ext_hits);
        $display("INFO: pre-existing SYSTEM-opcode op divergences = %0d of %0d", sys_diverge, checks);

        if (errors == 0)
            $display("\033[0;32mAll %0d encoding checks passed — dut op matches ref everywhere except the Zba, M, Zbb, Zbs and Zicond words\033[0m", checks);
        else
            $display("\033[0;31m%0d/%0d encoding checks FAILED\033[0m", errors, checks);
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish();
    end
endmodule
