/* Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh: Execute-level test of the EXT unit.
 *
 * This drives execute_stage directly with op::EXT instructions, as the decoder
 * builds them (the sub-operation, use_imm and shamt in the immediate field, see
 * op::ext_payload_t), and checks three things:
 *
 *   1. THE ARITHMETIC of all 45 forms, against a model written here from the ISA
 *      text and deliberately unlike the unit: the counts scan bit by bit, the
 *      rotates take a slice of the doubled word, min/max use SystemVerilog's own
 *      signed and unsigned compares, the byte operations loop over bytes, brev8,
 *      zip and unzip compute a source index for every result bit, xperm indexes
 *      the table with a part-select, and the six sha512 forms are the high and
 *      low words of the 64-bit SHA-512 functions of FIPS 180-4 (the identities of
 *      the ISA text) rather than the per-word shift expressions. Every form runs
 *      on a corner set (144 values: 0, -1, single bits and their complements, low
 *      and high masks, byte and half-word patterns) crossed with itself or with
 *      every shift amount, plus random operands; xperm8 also with index bytes
 *      drawn from 0..3 and 0x80..0x83, so that in-range indices are common.
 *
 *   2. THE PIPELINE PROTOCOL. An EXT instruction is an ordinary one-cycle ALU
 *      instruction: its result is forwarded in the same cycle with data_valid set
 *      and address = rd; Execute never stalls or jumps on its behalf; a STALL from
 *      Memory holds the registered outputs; a JUMP from Memory flushes it into a
 *      BUBBLE; a non-VALID EXT forwards address 0 and data_valid 0; rd = x0 is
 *      forwarded as x0; next_program_counter is pc + 4; and the payload reaches
 *      instruction_reg_out unchanged.
 *
 *   3. THE OPERANDS THAT MUST NOT MATTER. The immediate and unary forms (brev8,
 *      zip, unzip and the sha256 forms among them) do not read rs2, so every one
 *      of their checks drives rs2 with a different garbage value; the register
 *      forms that use a bit index or rotate amount see rs2 with its upper 27 bits
 *      set.
 */
module test_ext_execute;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;
    int   errors = 0;
    int   checks = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    logic [31:0]   rs1_data_in, rs2_data_in;
    instruction::t instruction_in;
    logic [31:0]   program_counter_in;

    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    logic [31:0]                 jump_address_backwards_in;

    logic [31:0]   dut_source_data_reg_out, dut_rd_data_reg_out;
    instruction::t dut_instruction_reg_out;
    logic [31:0]   dut_program_counter_reg_out, dut_next_program_counter_reg_out;
    forwarding::t  dut_forwarding_out;
    pipeline_status::forwards_t  dut_status_forwards_out;
    pipeline_status::backwards_t dut_status_backwards_out;
    logic [31:0]   dut_jump_address_backwards_out;

    bpredict::bp_data_t bp_prediction_in;
    bpredict::bp_data_t bp_feedback_out;

    execute_stage dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in),
        .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .source_data_reg_out(dut_source_data_reg_out),
        .rd_data_reg_out(dut_rd_data_reg_out),
        .instruction_reg_out(dut_instruction_reg_out),
        .program_counter_reg_out(dut_program_counter_reg_out),
        .next_program_counter_reg_out(dut_next_program_counter_reg_out),
        .forwarding_out(dut_forwarding_out),
        .bp_prediction_in(bp_prediction_in),
        .bp_feedback_out(bp_feedback_out),
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(dut_status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(dut_status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(dut_jump_address_backwards_out)
    );

    // ---------------------------------------------------------------------
    // The 45 forms
    // ---------------------------------------------------------------------
    localparam int FORMS = 45;
    // Kind: 0 register (reads rs2), 1 immediate (shamt), 2 unary (rs1 only).
    localparam int KIND [FORMS] = '{
        0, 0, 0,  2, 2, 2,  0, 0, 0, 0,  2, 2, 2,  0, 0, 1,  2, 2,
        0, 1, 0, 1,  0, 1, 0, 1,  0, 0,
        0, 0,  2, 2, 2,  0, 0,  2, 2, 2, 2,  0, 0, 0, 0,  0, 0
    };
    localparam ext_t SEL [FORMS] = '{
        EXT_ANDN, EXT_ORN, EXT_XNOR, EXT_CLZ, EXT_CTZ, EXT_CPOP,
        EXT_MAX, EXT_MAXU, EXT_MIN, EXT_MINU, EXT_SEXT_B, EXT_SEXT_H, EXT_ZEXT_H,
        EXT_ROL, EXT_ROR, EXT_ROR, EXT_ORC_B, EXT_REV8,
        EXT_BCLR, EXT_BCLR, EXT_BEXT, EXT_BEXT, EXT_BINV, EXT_BINV, EXT_BSET, EXT_BSET,
        EXT_CZERO_EQZ, EXT_CZERO_NEZ,
        EXT_PACK, EXT_PACKH, EXT_BREV8, EXT_ZIP, EXT_UNZIP, EXT_XPERM4, EXT_XPERM8,
        EXT_SHA256SIG0, EXT_SHA256SIG1, EXT_SHA256SUM0, EXT_SHA256SUM1,
        EXT_SHA512SIG0H, EXT_SHA512SIG0L, EXT_SHA512SIG1H, EXT_SHA512SIG1L,
        EXT_SHA512SUM0R, EXT_SHA512SUM1R
    };
    localparam string NAME [FORMS] = '{
        "andn", "orn", "xnor", "clz", "ctz", "cpop", "max", "maxu", "min", "minu",
        "sext.b", "sext.h", "zext.h", "rol", "ror", "rori", "orc.b", "rev8",
        "bclr", "bclri", "bext", "bexti", "binv", "binvi", "bset", "bseti",
        "czero.eqz", "czero.nez",
        "pack", "packh", "brev8", "zip", "unzip", "xperm4", "xperm8",
        "sha256sig0", "sha256sig1", "sha256sum0", "sha256sum1",
        "sha512sig0h", "sha512sig0l", "sha512sig1h", "sha512sig1l",
        "sha512sum0r", "sha512sum1r"
    };
    // The register forms whose rs2 is a bit index or rotate amount (only rs2[4:0]
    // counts): rol, ror, bclr, bext, binv, bset.
    function automatic bit uses_amount(int f);
        return f == 13 || f == 14 || f == 18 || f == 20 || f == 22 || f == 24;
    endfunction

    function automatic instruction::t ext_instr(int f, logic [4:0] shamt, logic [4:0] rd);
        instruction::t i;
        logic use_imm;
        use_imm       = (KIND[f] == 1);
        i.op          = EXT;
        i.rd_address  = rd;
        i.rs1_address = 5'd11;
        i.rs2_address = use_imm ? shamt : 5'd12;
        i.csr         = csr::t'(12'h000);
        i.immediate   = {20'b0, SEL[f], use_imm, use_imm ? shamt : 5'b0};
        return i;
    endfunction

    // ---------------------------------------------------------------------
    // Model, from the ISA text. b is rs2 for the register forms and the shift
    // amount for the immediate forms.
    // ---------------------------------------------------------------------
    // The SHA-512 functions of FIPS 180-4 on a 64-bit word; the sha512 forms of
    // RV32 compute one 32-bit half each: for x = {hi, lo}, sigma0(x) is
    // {sha512sig0h(hi, lo), sha512sig0l(lo, hi)}, sigma1(x) likewise with sig1,
    // Sigma0(x) is {sha512sum0r(hi, lo), sha512sum0r(lo, hi)}, Sigma1(x) likewise.
    function automatic logic [63:0] ror64(logic [63:0] x, int n);
        return (x >> n) | (x << (64 - n));
    endfunction
    function automatic logic [63:0] sigma0_512(logic [63:0] x);
        return ror64(x, 1) ^ ror64(x, 8) ^ (x >> 7);
    endfunction
    function automatic logic [63:0] sigma1_512(logic [63:0] x);
        return ror64(x, 19) ^ ror64(x, 61) ^ (x >> 6);
    endfunction
    function automatic logic [63:0] bigsigma0_512(logic [63:0] x);
        return ror64(x, 28) ^ ror64(x, 34) ^ ror64(x, 39);
    endfunction
    function automatic logic [63:0] bigsigma1_512(logic [63:0] x);
        return ror64(x, 14) ^ ror64(x, 18) ^ ror64(x, 41);
    endfunction

    function automatic logic [31:0] model(int f, logic [31:0] a, logic [31:0] b);
        logic [63:0] twice;
        int          s, n;
        logic [31:0] r;
        s     = int'(b[4:0]);
        twice = {a, a};
        r     = 32'b0;
        case (NAME[f])
            "andn":   r = a & ~b;
            "orn":    r = a | ~b;
            "xnor":   r = ~(a ^ b);
            "clz":    begin n = 0; for (int i = 31; i >= 0 && !a[i]; i--) n++; r = 32'(n); end
            "ctz":    begin n = 0; for (int i = 0; i < 32 && !a[i]; i++) n++; r = 32'(n); end
            "cpop":   begin n = 0; for (int i = 0; i < 32; i++) n += int'(a[i]); r = 32'(n); end
            "max":    r = ($signed(a) > $signed(b)) ? a : b;
            "maxu":   r = (a > b) ? a : b;
            "min":    r = ($signed(a) < $signed(b)) ? a : b;
            "minu":   r = (a < b) ? a : b;
            "sext.b": r = 32'($signed(a[7:0]));
            "sext.h": r = 32'($signed(a[15:0]));
            "zext.h": r = 32'(a[15:0]);
            "rol":    r = twice[63 - s -: 32];
            "ror", "rori": r = twice[s +: 32];
            "orc.b":  for (int k = 0; k < 4; k++) r[8*k +: 8] = (a[8*k +: 8] != 8'h00) ? 8'hFF : 8'h00;
            "rev8":   for (int k = 0; k < 4; k++) r[8*k +: 8] = a[8*(3-k) +: 8];
            "bclr", "bclri": begin r = a; r[s] = 1'b0; end
            "bext", "bexti": r = {31'b0, a[s]};
            "binv", "binvi": begin r = a; r[s] = ~a[s]; end
            "bset", "bseti": begin r = a; r[s] = 1'b1; end
            "czero.eqz": r = (b == 32'b0) ? 32'b0 : a;
            "czero.nez": r = (b != 32'b0) ? 32'b0 : a;
            "pack":   r = {b[15:0], a[15:0]};
            "packh":  r = {16'b0, b[7:0], a[7:0]};
            "brev8":  for (int k = 0; k < 32; k++) r[k] = a[(k & ~7) + 7 - (k & 7)];
            "zip":    for (int k = 0; k < 32; k++) r[k] = a[(k >> 1) + 16 * (k & 1)];
            "unzip":  for (int k = 0; k < 32; k++) r[k] = a[2 * (k % 16) + k / 16];
            "xperm4": for (int k = 0; k < 8; k++) begin
                          n = int'(b[4*k +: 4]);
                          if (n < 8) r[4*k +: 4] = a[4*n +: 4];
                      end
            "xperm8": for (int k = 0; k < 4; k++) begin
                          n = int'(b[8*k +: 8]);
                          if (n < 4) r[8*k +: 8] = a[8*n +: 8];
                      end
            "sha256sig0": r = twice[7 +: 32] ^ twice[18 +: 32] ^ (a >> 3);
            "sha256sig1": r = twice[17 +: 32] ^ twice[19 +: 32] ^ (a >> 10);
            "sha256sum0": r = twice[2 +: 32] ^ twice[13 +: 32] ^ twice[22 +: 32];
            "sha256sum1": r = twice[6 +: 32] ^ twice[11 +: 32] ^ twice[25 +: 32];
            "sha512sig0h": r = sigma0_512({a, b})[63:32];
            "sha512sig0l": r = sigma0_512({b, a})[31:0];
            "sha512sig1h": r = sigma1_512({a, b})[63:32];
            "sha512sig1l": r = sigma1_512({b, a})[31:0];
            "sha512sum0r": r = bigsigma0_512({a, b})[63:32];
            "sha512sum1r": r = bigsigma1_512({a, b})[63:32];
            default:  r = 32'hDEAD_DEAD;
        endcase
        return r;
    endfunction

    // ---------------------------------------------------------------------
    // One combinational check: drive, settle, compare the forwarding output.
    // ---------------------------------------------------------------------
    int form_checks [FORMS];

    task automatic check_one(int f, logic [31:0] a, logic [31:0] b, logic [31:0] rs2_garbage);
        logic [31:0] want;
        want                = model(f, a, b);
        instruction_in      = ext_instr(f, b[4:0], 5'd10);
        rs1_data_in         = a;
        rs2_data_in         = (KIND[f] == 0) ? b : rs2_garbage;
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        #1;
        checks++;
        form_checks[f]++;
        if (dut_forwarding_out.data !== want || dut_forwarding_out.data_valid !== 1'b1 ||
            dut_forwarding_out.address !== 5'd10 || dut_status_backwards_out !== READY) begin
            errors++;
            if (errors < 40)
                $display("FAIL %s a=%08h b=%08h rs2=%08h: fwd={dv=%0b addr=%0d d=%08h} back=%0d want d=%08h",
                         NAME[f], a, b, rs2_data_in, dut_forwarding_out.data_valid,
                         dut_forwarding_out.address, dut_forwarding_out.data,
                         dut_status_backwards_out, want);
        end
    endtask

    // The corner set: 0, -1, 1 << k, ~(1 << k), (1 << k) - 1, -1 << k and a set
    // of byte, half-word and alternating patterns (sorted, no duplicates).
    logic [31:0] corners[$];

    task automatic build_corners();
        logic [31:0] pool[$];
        pool.push_back(32'h0);
        pool.push_back(32'hFFFF_FFFF);
        for (int k = 0; k < 32; k++) begin
            pool.push_back(32'h1 << k);
            pool.push_back(~(32'h1 << k));
        end
        for (int k = 1; k <= 32; k++) pool.push_back(32'((64'h1 << k) - 1));
        for (int k = 1; k < 32; k++)  pool.push_back(32'hFFFF_FFFF << k);
        pool.push_back(32'h5555_5555); pool.push_back(32'hAAAA_AAAA);
        pool.push_back(32'h3333_3333); pool.push_back(32'hCCCC_CCCC);
        pool.push_back(32'h0F0F_0F0F); pool.push_back(32'hF0F0_F0F0);
        pool.push_back(32'h00FF_00FF); pool.push_back(32'hFF00_FF00);
        pool.push_back(32'h0101_0101); pool.push_back(32'h8080_8080);
        pool.push_back(32'h7F7F_7F7F); pool.push_back(32'hFEFE_FEFE);
        pool.push_back(32'h0001_0001); pool.push_back(32'h8000_0001);
        pool.push_back(32'h7FFF_FFFE); pool.push_back(32'h1234_5678);
        pool.push_back(32'h8765_4321); pool.push_back(32'hDEAD_BEEF);
        pool.push_back(32'h0000_FF00); pool.push_back(32'h00FF_0000);
        pool.push_back(32'hFFFF_FF80); pool.push_back(32'hFFFF_8000);
        pool.push_back(32'h0000_00FF);
        pool.sort();
        corners.delete();
        foreach (pool[i])
            if (corners.size() == 0 || corners[corners.size() - 1] != pool[i])
                corners.push_back(pool[i]);
    endtask

    // Idle the stage for one cycle with a harmless NOP.
    task automatic idle_cycle();
        instruction_in      = instruction::NOP;
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        @(posedge clk); #1;
    endtask

    task automatic expect_true(bit cond, string what);
        checks++;
        if (!cond) begin
            errors++;
            $display("FAIL %s", what);
        end
    endtask

    initial begin
        logic [31:0] a, b, want, want2;
        instruction::t ins;

        rst = 1;
        rs1_data_in = 0; rs2_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = 32'h4000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        bp_prediction_in = '0;
        foreach (form_checks[f]) form_checks[f] = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        build_corners();
        $display("corner set: %0d values", corners.size());
        if (corners.size() != 144) begin
            errors++;
            $display("FAIL corner set has %0d values, expected 144", corners.size());
        end

        // =================================================================
        $display("=== 1: known answers ===");
        // =================================================================
        check_one(3, 32'h0, 0, 32'hA5A5A5A5);              // clz(0) = 32
        check_one(3, 32'h1, 0, 32'hA5A5A5A5);              // clz(1) = 31
        check_one(4, 32'h8000_0000, 0, 32'hA5A5A5A5);      // ctz = 31
        check_one(5, 32'hFFFF_FFFF, 0, 32'hA5A5A5A5);      // cpop = 32
        check_one(16, 32'h0001_0080, 0, 32'hA5A5A5A5);     // orc.b
        check_one(17, 32'h1234_5678, 0, 32'hA5A5A5A5);     // rev8
        check_one(13, 32'h8000_0001, 32'd1, 0);            // rol
        check_one(14, 32'h3, 32'd1, 0);                    // ror
        check_one(24, 32'h0, 32'd37, 0);                   // bset, index 37 & 31 = 5
        check_one(26, 32'd5, 32'd0, 0);                    // czero.eqz(5, 0) = 0
        check_one(27, 32'd5, 32'd0, 0);                    // czero.nez(5, 0) = 5
        check_one(28, 32'h1234_5678, 32'h9ABC_DEF0, 0);   // pack = DEF05678
        check_one(29, 32'h1234_5678, 32'h9ABC_DEF0, 0);   // packh = 0000F078
        check_one(30, 32'h1234_5678, 0, 32'hA5A5A5A5);     // brev8 = 482C6A1E
        check_one(31, 32'h1234_5678, 0, 32'hA5A5A5A5);     // zip = 131C1F60
        check_one(32, 32'h1234_5678, 0, 32'hA5A5A5A5);     // unzip = 141646EC
        check_one(33, 32'hFEDC_BA98, 32'hF0F0_F0F0, 0);   // xperm4 = 08080808
        check_one(34, 32'h4433_2211, 32'h04FF_0100, 0);   // xperm8 = 00002211
        check_one(35, 32'h1234_5678, 0, 32'hA5A5A5A5);     // sha256sig0 = E7FCE6EE
        check_one(38, 32'h1234_5678, 0, 32'hA5A5A5A5);     // sha256sum1 = 3561ABDA
        check_one(40, 32'h1234_5678, 32'h9ABC_DEF0, 0);   // sha512sig0l = 192C77C6
        check_one(41, 32'h1234_5678, 32'h9ABC_DEF0, 0);   // sha512sig1h = 0A3460DB
        check_one(44, 32'h1234_5678, 32'h9ABC_DEF0, 0);   // sha512sum1r = 70311233
        expect_true(model(28, 32'h1234_5678, 32'h9ABC_DEF0) == 32'hDEF0_5678 &&
                    model(29, 32'h1234_5678, 32'h9ABC_DEF0) == 32'h0000_F078 &&
                    model(30, 32'h0102_0304, 0) == 32'h8040_C020 && model(30, 32'h1234_5678, 0) == 32'h482C_6A1E &&
                    model(31, 32'h0000_FFFF, 0) == 32'h5555_5555 && model(31, 32'h1234_5678, 0) == 32'h131C_1F60 &&
                    model(32, 32'h1234_5678, 0) == 32'h1416_46EC && model(32, 32'h5555_5555, 0) == 32'h0000_FFFF &&
                    model(33, 32'h7654_3210, 32'h0123_4567) == 32'h0123_4567 &&
                    model(33, 32'h7654_3210, 32'h89AB_CDEF) == 32'h0 &&
                    model(33, 32'hFEDC_BA98, 32'hF0F0_F0F0) == 32'h0808_0808 &&
                    model(34, 32'h4433_2211, 32'h0001_0203) == 32'h1122_3344 &&
                    model(34, 32'h4433_2211, 32'h04FF_0100) == 32'h0000_2211,
                    "the bench model reproduces the known answers of Zbkb and Zbkx");
        expect_true(model(35, 1, 0) == 32'h0200_4000 && model(36, 1, 0) == 32'h0000_A000 &&
                    model(37, 1, 0) == 32'h4008_0400 && model(38, 1, 0) == 32'h0420_0080 &&
                    model(35, 32'h1234_5678, 0) == 32'hE7FC_E6EE && model(36, 32'h1234_5678, 0) == 32'hA1F7_8649 &&
                    model(37, 32'h1234_5678, 0) == 32'h6614_6474 && model(38, 32'h1234_5678, 0) == 32'h3561_ABDA &&
                    model(39, 32'h1234_5678, 32'h9ABC_DEF0) == 32'hF92C_77C6 &&
                    model(40, 32'h1234_5678, 32'h9ABC_DEF0) == 32'h192C_77C6 &&
                    model(41, 32'h1234_5678, 32'h9ABC_DEF0) == 32'h0A34_60DB &&
                    model(42, 32'h1234_5678, 32'h9ABC_DEF0) == 32'hCA34_60DB &&
                    model(43, 32'h1234_5678, 32'h9ABC_DEF0) == 32'h7C57_A100 &&
                    model(44, 32'h1234_5678, 32'h9ABC_DEF0) == 32'h7031_1233 &&
                    model(39, 0, 1) == 32'h8100_0000 && model(40, 0, 1) == 32'h8300_0000 &&
                    model(41, 0, 1) == 32'h0000_2000 && model(42, 0, 1) == 32'h0400_2000 &&
                    model(43, 0, 1) == 32'h0000_0010 && model(44, 0, 1) == 32'h0004_4000,
                    "the bench model reproduces the known answers of Zknh");
        expect_true(model(3, 0, 0) == 32 && model(16, 32'h0001_0080, 0) == 32'h00FF_00FF &&
                    model(17, 32'h1234_5678, 0) == 32'h7856_3412 && model(13, 32'h8000_0001, 1) == 3 &&
                    model(24, 0, 37) == 32'h20 && model(27, 5, 0) == 5 && model(8, 32'hFFFF_FFFF, 1) == 32'hFFFF_FFFF,
                    "the bench model reproduces the known answers of the ISA text");

        // =================================================================
        $display("=== 2: every form on the corner set ===");
        // =================================================================
        for (int f = 0; f < FORMS; f++) begin
            if (KIND[f] == 0) begin
                foreach (corners[i])
                    foreach (corners[j])
                        check_one(f, corners[i], corners[j], 0);
                // Bit index / rotate amount with the upper 27 bits of rs2 set:
                // only rs2[4:0] may count.
                if (uses_amount(f))
                    foreach (corners[i])
                        for (int s = 0; s < 32; s++)
                            check_one(f, corners[i], {27'h7FF_FFFF, s[4:0]}, 0);
            end else if (KIND[f] == 1) begin
                foreach (corners[i])
                    for (int s = 0; s < 32; s++)
                        check_one(f, corners[i], 32'(s), $urandom());
            end else begin
                foreach (corners[i])
                    check_one(f, corners[i], 0, $urandom());
            end
        end

        // =================================================================
        $display("=== 3: random operands ===");
        // =================================================================
        for (int f = 0; f < FORMS; f++)
            for (int n = 0; n < 20000; n++) begin
                a = $urandom();
                b = $urandom();
                if (KIND[f] == 1) b = {27'b0, b[4:0]};
                check_one(f, a, b, $urandom());
            end
        // czero with rs2 = 0 often enough to matter
        for (int n = 0; n < 2000; n++) begin
            check_one(26, $urandom(), 32'b0, 0);
            check_one(27, $urandom(), 32'b0, 0);
        end
        // xperm8 with in-range indices often enough to matter: each index byte
        // is 0..3 or 0x80..0x83 (in range or out of range only through bit 7);
        // and with one high index bit at a time
        for (int n = 0; n < 20000; n++)
            check_one(34, $urandom(), $urandom() & 32'h8383_8383, 0);
        for (int n = 0; n < 2000; n++)
            for (int k = 2; k < 8; k++)
                check_one(34, $urandom(), ($urandom() & 32'h0303_0303) | (32'h0101_0101 << k), 0);

        // =================================================================
        $display("=== 4: pipeline protocol ===");
        // =================================================================
        // 4a. Registered outputs: result, payload, rd, pc, next pc.
        for (int f = 0; f < FORMS; f++) begin
            idle_cycle();
            a   = 32'h8421_F00D + 32'(f);
            b   = 32'h0000_0013;
            ins = ext_instr(f, 5'd19, 5'd10);
            instruction_in      = ins;
            rs1_data_in         = a;
            rs2_data_in         = b;
            program_counter_in  = 32'h0000_4000 + 32'(4 * f);
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            want = model(f, a, b);
            #1;
            expect_true(dut_status_backwards_out == READY, $sformatf("%s: Execute stays READY", NAME[f]));
            @(posedge clk); #1;
            expect_true(dut_rd_data_reg_out === want, $sformatf("%s: rd_data_reg_out %08h want %08h",
                        NAME[f], dut_rd_data_reg_out, want));
            expect_true(dut_instruction_reg_out === ins, $sformatf("%s: instruction_reg_out (payload) unchanged", NAME[f]));
            expect_true(dut_status_forwards_out == VALID, $sformatf("%s: forwards VALID", NAME[f]));
            expect_true(dut_program_counter_reg_out === 32'h0000_4000 + 32'(4 * f),
                        $sformatf("%s: program_counter_reg_out", NAME[f]));
            expect_true(dut_next_program_counter_reg_out === 32'h0000_4004 + 32'(4 * f),
                        $sformatf("%s: next_program_counter_reg_out = pc + 4", NAME[f]));
        end

        // 4b. A STALL from Memory holds every registered output.
        idle_cycle();
        instruction_in      = ext_instr(0, 5'd0, 5'd10);   // andn
        rs1_data_in         = 32'hFFFF_0000;
        rs2_data_in         = 32'h0F0F_0F0F;
        program_counter_in  = 32'h0000_5000;
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        want = model(0, 32'hFFFF_0000, 32'h0F0F_0F0F);
        @(posedge clk); #1;
        expect_true(dut_rd_data_reg_out === want, "andn registered before the stall");
        instruction_in      = ext_instr(5, 5'd0, 5'd11);   // cpop, different rd
        rs1_data_in         = 32'h0000_00FF;
        program_counter_in  = 32'h0000_5004;
        status_backwards_in = STALL;
        for (int k = 0; k < 3; k++) begin
            @(posedge clk); #1;
            expect_true(dut_rd_data_reg_out === want && dut_instruction_reg_out.rd_address == 5'd10 &&
                        dut_program_counter_reg_out == 32'h0000_5000 && dut_status_forwards_out == VALID,
                        $sformatf("Memory STALL cycle %0d holds the registered EXT result", k));
        end
        status_backwards_in = READY;
        @(posedge clk); #1;
        expect_true(dut_rd_data_reg_out === 32'd8 && dut_instruction_reg_out.rd_address == 5'd11,
                    "after the stall the next EXT instruction (cpop) is registered");

        // 4c. A JUMP from Memory turns the EXT instruction into a BUBBLE.
        instruction_in      = ext_instr(13, 5'd0, 5'd12);  // rol
        rs1_data_in         = 32'h8000_0001;
        rs2_data_in         = 32'd4;
        status_backwards_in = JUMP;
        jump_address_backwards_in = 32'h0000_6000;
        @(posedge clk); #1;
        expect_true(dut_status_forwards_out == BUBBLE, "JUMP from Memory flushes the EXT instruction");
        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        idle_cycle();

        // 4d. A non-VALID EXT instruction forwards nothing.
        instruction_in      = ext_instr(7, 5'd0, 5'd10);   // maxu
        rs1_data_in         = 32'd1;
        rs2_data_in         = 32'd2;
        status_forwards_in  = BUBBLE;
        status_backwards_in = READY;
        #1;
        expect_true(dut_forwarding_out.address == 5'd0 && dut_forwarding_out.data_valid == 1'b0,
                    "BUBBLE EXT forwards address 0, data_valid 0");
        expect_true(dut_status_backwards_out == READY, "BUBBLE EXT does not stall");
        @(posedge clk); #1;
        expect_true(dut_status_forwards_out == BUBBLE, "BUBBLE EXT stays a BUBBLE");
        status_forwards_in  = ILLEGAL_INSTRUCTION;
        #1;
        expect_true(dut_forwarding_out.address == 5'd0 && dut_forwarding_out.data_valid == 1'b0,
                    "an EXT carrying an exception status forwards address 0, data_valid 0");
        status_forwards_in  = VALID;
        idle_cycle();

        // 4e. rd = x0: forwarded as x0, the value is computed but never claimed.
        instruction_in      = ext_instr(22, 5'd0, 5'd0);   // binv into x0
        rs1_data_in         = 32'h0;
        rs2_data_in         = 32'd31;
        #1;
        expect_true(dut_forwarding_out.address == 5'd0, "EXT with rd = x0 forwards address 0");
        @(posedge clk); #1;
        expect_true(dut_instruction_reg_out.rd_address == 5'd0, "EXT with rd = x0 registers rd = 0");

        // 4f. Back-to-back EXT instructions: each one is a single cycle, never a stall.
        for (int f = 0; f < FORMS; f++) begin
            a = $urandom(); b = $urandom();
            if (KIND[f] == 1) b = {27'b0, b[4:0]};
            instruction_in      = ext_instr(f, b[4:0], 5'(1 + f));
            rs1_data_in         = a;
            rs2_data_in         = (KIND[f] == 0) ? b : $urandom();
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            want2 = model(f, a, b);
            #1;
            expect_true(dut_status_backwards_out == READY && dut_forwarding_out.data_valid &&
                        dut_forwarding_out.data === want2 && dut_forwarding_out.address == 5'(1 + f),
                        $sformatf("%s back-to-back: forwarded in its own cycle", NAME[f]));
            @(posedge clk); #1;
            expect_true(dut_rd_data_reg_out === want2 && dut_status_forwards_out == VALID,
                        $sformatf("%s back-to-back: registered after one cycle", NAME[f]));
        end
        idle_cycle();

        // 4g. The data registers of the source operand: rs2 for EXT as for every
        // ALU instruction (unused downstream, but it must not be anything else).
        instruction_in      = ext_instr(1, 5'd0, 5'd10);
        rs1_data_in         = 32'h1;
        rs2_data_in         = 32'hCAFE_F00D;
        @(posedge clk); #1;
        expect_true(dut_source_data_reg_out === 32'hCAFE_F00D, "source_data_reg_out = rs2 for EXT");
        idle_cycle();

        // =================================================================
        $display("");
        $display("========================================");
        for (int f = 0; f < FORMS; f++)
            if (form_checks[f] == 0) begin
                errors++;
                $display("COVERAGE HOLE: %s never checked", NAME[f]);
            end
        $display("  Checks: %0d   Errors: %0d", checks, errors);
        $display("========================================");
        if (errors == 0)
            $display("\033[0;32mAll %0d EXT-unit checks passed\033[0m", checks);
        else
            $display("\033[0;31m%0d EXT-unit checks FAILED\033[0m", errors);
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish;
    end
endmodule
