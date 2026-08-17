/* Compare memory_stage (DUT) against ref_memory_stage (REF).
 * Both get their own Wishbone bus connected to identical async RAM slaves.
 * We drive various load/store scenarios and compare all outputs. */

module test_memory_compare;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;
    int error_count = 0;
    int test_count  = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    // =========================================================================
    // Wishbone buses — one for DUT, one for REF
    // =========================================================================
    wishbone_interface dut_wb();
    wishbone_interface ref_wb();

    // =========================================================================
    // Simple async RAM slave (combinational ack, no wait states)
    // Shared backing store so both see the same data.
    // 256 words = 1KB, word-addressed.
    // =========================================================================
    logic [31:0] ram [0:255];

    // DUT slave
    always_comb begin
        dut_wb.ack = dut_wb.cyc & dut_wb.stb;
        dut_wb.err = 1'b0;
        dut_wb.dat_miso = ram[dut_wb.adr[7:0]];
    end
    // DUT writes
    always_ff @(posedge clk) begin
        if (dut_wb.cyc && dut_wb.stb && dut_wb.we) begin
            if (dut_wb.sel[0]) ram[dut_wb.adr[7:0]][7:0]   <= dut_wb.dat_mosi[7:0];
            if (dut_wb.sel[1]) ram[dut_wb.adr[7:0]][15:8]  <= dut_wb.dat_mosi[15:8];
            if (dut_wb.sel[2]) ram[dut_wb.adr[7:0]][23:16] <= dut_wb.dat_mosi[23:16];
            if (dut_wb.sel[3]) ram[dut_wb.adr[7:0]][31:24] <= dut_wb.dat_mosi[31:24];
        end
    end

    // REF slave
    always_comb begin
        ref_wb.ack = ref_wb.cyc & ref_wb.stb;
        ref_wb.err = 1'b0;
        ref_wb.dat_miso = ram[ref_wb.adr[7:0]];
    end
    // REF writes — must produce identical result since inputs are identical
    // (We rely on DUT and REF driving the same addresses/data/sel)
    // REF writes are intentionally not applied to avoid double-write conflicts;
    // we verify that REF's bus signals match DUT's.

    // =========================================================================
    // Shared inputs
    // =========================================================================
    logic [31:0]              source_data_in;
    logic [31:0]              rd_data_in;
    instruction::t            instruction_in;
    logic [31:0]              program_counter_in;
    logic [31:0]              next_program_counter_in;
    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    logic [31:0]              jump_address_backwards_in;

    // =========================================================================
    // DUT outputs
    // =========================================================================
    logic [31:0]              dut_source_data_reg_out;
    logic [31:0]              dut_rd_data_reg_out;
    instruction::t            dut_instruction_reg_out;
    logic [31:0]              dut_program_counter_reg_out;
    logic [31:0]              dut_next_program_counter_reg_out;
    forwarding::t             dut_forwarding_out;
    pipeline_status::forwards_t  dut_status_forwards_out;
    pipeline_status::backwards_t dut_status_backwards_out;
    logic [31:0]              dut_jump_address_backwards_out;

    // =========================================================================
    // REF outputs
    // =========================================================================
    logic [31:0]              ref_source_data_reg_out;
    logic [31:0]              ref_rd_data_reg_out;
    instruction::t            ref_instruction_reg_out;
    logic [31:0]              ref_program_counter_reg_out;
    logic [31:0]              ref_next_program_counter_reg_out;
    forwarding::t             ref_forwarding_out;
    pipeline_status::forwards_t  ref_status_forwards_out;
    pipeline_status::backwards_t ref_status_backwards_out;
    logic [31:0]              ref_jump_address_backwards_out;

    // =========================================================================
    // DUT instantiation
    // =========================================================================
    memory_stage dut (
        .clk(clk), .rst(rst),
        .wb(dut_wb),
        .source_data_in(source_data_in),
        .rd_data_in(rd_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .next_program_counter_in(next_program_counter_in),
        .source_data_reg_out(dut_source_data_reg_out),
        .rd_data_reg_out(dut_rd_data_reg_out),
        .instruction_reg_out(dut_instruction_reg_out),
        .program_counter_reg_out(dut_program_counter_reg_out),
        .next_program_counter_reg_out(dut_next_program_counter_reg_out),
        .forwarding_out(dut_forwarding_out),
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(dut_status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(dut_status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(dut_jump_address_backwards_out)
    );

    // =========================================================================
    // REF instantiation
    // =========================================================================
    ref_memory_stage ref_dut (
        .clk(clk), .rst(rst),
        .wb(ref_wb),
        .source_data_in(source_data_in),
        .rd_data_in(rd_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .next_program_counter_in(next_program_counter_in),
        .source_data_reg_out(ref_source_data_reg_out),
        .rd_data_reg_out(ref_rd_data_reg_out),
        .instruction_reg_out(ref_instruction_reg_out),
        .program_counter_reg_out(ref_program_counter_reg_out),
        .next_program_counter_reg_out(ref_next_program_counter_reg_out),
        .forwarding_out(ref_forwarding_out),
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(ref_status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(ref_status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(ref_jump_address_backwards_out)
    );

    // =========================================================================
    // Helper: make instruction struct
    // =========================================================================
    function automatic instruction::t make_instr(
        op::t op_v, logic [4:0] rd, logic [4:0] rs1, logic [4:0] rs2,
        logic [31:0] imm
    );
        make_instr.op          = op_v;
        make_instr.rd_address  = rd;
        make_instr.rs1_address = rs1;
        make_instr.rs2_address = rs2;
        make_instr.csr         = csr::MSTATUS;
        make_instr.immediate   = imm;
    endfunction

    // =========================================================================
    // Compare Wishbone bus outputs (combinational)
    // =========================================================================
    task automatic compare_wb(string label);
        if (dut_wb.cyc !== ref_wb.cyc) begin
            $display("[%0d] %s FAIL wb.cyc: dut=%0b ref=%0b", test_count, label,
                     dut_wb.cyc, ref_wb.cyc);
            error_count++;
        end
        if (dut_wb.stb !== ref_wb.stb) begin
            $display("[%0d] %s FAIL wb.stb: dut=%0b ref=%0b", test_count, label,
                     dut_wb.stb, ref_wb.stb);
            error_count++;
        end
        if (dut_wb.cyc && dut_wb.stb) begin
            if (dut_wb.adr !== ref_wb.adr) begin
                $display("[%0d] %s FAIL wb.adr: dut=%08h ref=%08h", test_count, label,
                         dut_wb.adr, ref_wb.adr);
                error_count++;
            end
            if (dut_wb.sel !== ref_wb.sel) begin
                $display("[%0d] %s FAIL wb.sel: dut=%04b ref=%04b", test_count, label,
                         dut_wb.sel, ref_wb.sel);
                error_count++;
            end
            if (dut_wb.we !== ref_wb.we) begin
                $display("[%0d] %s FAIL wb.we: dut=%0b ref=%0b", test_count, label,
                         dut_wb.we, ref_wb.we);
                error_count++;
            end
            if (dut_wb.we && (dut_wb.dat_mosi !== ref_wb.dat_mosi)) begin
                $display("[%0d] %s FAIL wb.dat_mosi: dut=%08h ref=%08h", test_count, label,
                         dut_wb.dat_mosi, ref_wb.dat_mosi);
                error_count++;
            end
        end
    endtask

    // =========================================================================
    // Compare all registered + combinational outputs
    // =========================================================================
    task automatic compare(string label);
        test_count++;
        if (dut_rd_data_reg_out !== ref_rd_data_reg_out) begin
            $display("[%0d] %s FAIL rd_data: dut=%08h ref=%08h", test_count, label,
                     dut_rd_data_reg_out, ref_rd_data_reg_out);
            error_count++;
        end
        if (dut_source_data_reg_out !== ref_source_data_reg_out) begin
            $display("[%0d] %s FAIL source_data: dut=%08h ref=%08h", test_count, label,
                     dut_source_data_reg_out, ref_source_data_reg_out);
            error_count++;
        end
        if (dut_instruction_reg_out !== ref_instruction_reg_out) begin
            $display("[%0d] %s FAIL instr_reg: dut=%0h ref=%0h", test_count, label,
                     dut_instruction_reg_out, ref_instruction_reg_out);
            error_count++;
        end
        if (dut_program_counter_reg_out !== ref_program_counter_reg_out) begin
            $display("[%0d] %s FAIL pc_reg: dut=%08h ref=%08h", test_count, label,
                     dut_program_counter_reg_out, ref_program_counter_reg_out);
            error_count++;
        end
        if (dut_next_program_counter_reg_out !== ref_next_program_counter_reg_out) begin
            $display("[%0d] %s FAIL next_pc: dut=%08h ref=%08h", test_count, label,
                     dut_next_program_counter_reg_out, ref_next_program_counter_reg_out);
            error_count++;
        end
        if (dut_forwarding_out !== ref_forwarding_out) begin
            $display("[%0d] %s FAIL fwd: dut={dv=%0b,d=%08h,a=%0d} ref={dv=%0b,d=%08h,a=%0d}", test_count, label,
                     dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address,
                     ref_forwarding_out.data_valid, ref_forwarding_out.data, ref_forwarding_out.address);
            error_count++;
        end
        if (dut_status_forwards_out !== ref_status_forwards_out) begin
            $display("[%0d] %s FAIL sf_out: dut=%0d ref=%0d", test_count, label,
                     dut_status_forwards_out, ref_status_forwards_out);
            error_count++;
        end
        if (dut_status_backwards_out !== ref_status_backwards_out) begin
            $display("[%0d] %s FAIL sb_out: dut=%0d ref=%0d", test_count, label,
                     dut_status_backwards_out, ref_status_backwards_out);
            error_count++;
        end
        if (dut_jump_address_backwards_out !== ref_jump_address_backwards_out) begin
            $display("[%0d] %s FAIL jump_addr: dut=%08h ref=%08h", test_count, label,
                     dut_jump_address_backwards_out, ref_jump_address_backwards_out);
            error_count++;
        end
    endtask

    // Compare combinational outputs only (before clock edge)
    task automatic compare_comb(string label);
        test_count++;
        compare_wb(label);
        if (dut_forwarding_out !== ref_forwarding_out) begin
            $display("[%0d] %s COMB fwd: dut={dv=%0b,d=%08h,a=%0d} ref={dv=%0b,d=%08h,a=%0d}", test_count, label,
                     dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address,
                     ref_forwarding_out.data_valid, ref_forwarding_out.data, ref_forwarding_out.address);
            error_count++;
        end
        if (dut_status_backwards_out !== ref_status_backwards_out) begin
            $display("[%0d] %s COMB sb_out: dut=%0d ref=%0d", test_count, label,
                     dut_status_backwards_out, ref_status_backwards_out);
            error_count++;
        end
    endtask

    // =========================================================================
    // Initialize RAM with known pattern
    // =========================================================================
    task init_ram();
        for (int i = 0; i < 256; i++) begin
            ram[i] = 32'hDEAD_0000 + i * 4;
        end
    endtask

    initial begin
        $dumpfile("test_memory_compare.fst");
        $dumpvars(0, test_memory_compare);

        init_ram();

        // =====================================================================
        // RESET
        // =====================================================================
        rst = 1;
        source_data_in = 0;
        rd_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = constants::RESET_ADDRESS;
        next_program_counter_in = constants::RESET_ADDRESS + 4;
        status_forwards_in = BUBBLE;
        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // =====================================================================
        // SWEEP 1: Non-memory instruction passthrough (ADD)
        // =====================================================================
        $display("=== SWEEP 1: Non-memory passthrough ===");

        instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
        rd_data_in = 32'h0000_1234;    // ALU result
        source_data_in = 32'h0000_5678; // rs2
        program_counter_in = 32'h0004_0000;
        next_program_counter_in = 32'h0004_0004;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("1a_ADD_comb");
        @(posedge clk); #1;
        compare("1a_ADD_reg");

        // ADDI
        instruction_in = make_instr(ADDI, 5'd4, 5'd5, 5'd0, 32'h10);
        rd_data_in = 32'hAAAA_BBBB;
        program_counter_in = 32'h0004_0004;
        next_program_counter_in = 32'h0004_0008;
        #1; compare_comb("1b_ADDI_comb");
        @(posedge clk); #1;
        compare("1b_ADDI_reg");

        // LUI
        instruction_in = make_instr(LUI, 5'd6, 5'd0, 5'd0, 32'hDEAD_B000);
        rd_data_in = 32'hDEAD_B000;
        program_counter_in = 32'h0004_0008;
        next_program_counter_in = 32'h0004_000C;
        #1; compare_comb("1c_LUI_comb");
        @(posedge clk); #1;
        compare("1c_LUI_reg");

        // =====================================================================
        // SWEEP 2: LW — word load (aligned)
        // =====================================================================
        $display("=== SWEEP 2: LW (word load) ===");

        // LW from byte address 0x00 → word address 0x00
        // ram[0] = 0xDEAD_0000
        instruction_in = make_instr(LW, 5'd1, 5'd2, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0000;  // byte address 0x00
        source_data_in = 32'h0;
        program_counter_in = 32'h0004_0010;
        next_program_counter_in = 32'h0004_0014;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("2a_LW_addr0_comb");
        @(posedge clk); #1;
        compare("2a_LW_addr0_reg");

        // LW from byte address 0x10 → word address 0x04
        // ram[4] = 0xDEAD_0010
        instruction_in = make_instr(LW, 5'd2, 5'd3, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0010;  // byte address 0x10
        program_counter_in = 32'h0004_0014;
        next_program_counter_in = 32'h0004_0018;
        #1; compare_comb("2b_LW_addr10_comb");
        @(posedge clk); #1;
        compare("2b_LW_addr10_reg");

        // =====================================================================
        // SWEEP 3: LH / LHU — halfword loads
        // =====================================================================
        $display("=== SWEEP 3: LH / LHU ===");

        // LH from addr 0x00 (low half of ram[0] = 0x0000)
        // ram[0] = 0xDEAD_0000 → low half = 0x0000, sign-ext = 0x0000_0000
        instruction_in = make_instr(LH, 5'd3, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0000;  // byte address 0x00
        program_counter_in = 32'h0004_0020;
        next_program_counter_in = 32'h0004_0024;
        #1; compare_comb("3a_LH_low_comb");
        @(posedge clk); #1;
        compare("3a_LH_low_reg");

        // LH from addr 0x02 (high half of ram[0] = 0xDEAD)
        // sign bit = 1, sign-ext = 0xFFFF_DEAD
        instruction_in = make_instr(LH, 5'd4, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0002;  // byte address 0x02
        program_counter_in = 32'h0004_0024;
        next_program_counter_in = 32'h0004_0028;
        #1; compare_comb("3b_LH_high_comb");
        @(posedge clk); #1;
        compare("3b_LH_high_reg");

        // LHU from addr 0x02 (high half, zero-ext = 0x0000_DEAD)
        instruction_in = make_instr(LHU, 5'd5, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0002;
        program_counter_in = 32'h0004_0028;
        next_program_counter_in = 32'h0004_002C;
        #1; compare_comb("3c_LHU_high_comb");
        @(posedge clk); #1;
        compare("3c_LHU_high_reg");

        // =====================================================================
        // SWEEP 4: LB / LBU — byte loads
        // =====================================================================
        $display("=== SWEEP 4: LB / LBU ===");

        // ram[1] = 0xDEAD_0004
        // byte 0 (addr 0x04) = 0x04
        // byte 1 (addr 0x05) = 0x00
        // byte 2 (addr 0x06) = 0xAD
        // byte 3 (addr 0x07) = 0xDE

        // LB from addr 0x06 → byte 2 of ram[1] = 0xAD, sign-ext = 0xFFFF_FFAD
        instruction_in = make_instr(LB, 5'd6, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0006;
        program_counter_in = 32'h0004_0030;
        next_program_counter_in = 32'h0004_0034;
        #1; compare_comb("4a_LB_byte2_comb");
        @(posedge clk); #1;
        compare("4a_LB_byte2_reg");

        // LBU from addr 0x06 → 0x000000AD
        instruction_in = make_instr(LBU, 5'd7, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0006;
        program_counter_in = 32'h0004_0034;
        next_program_counter_in = 32'h0004_0038;
        #1; compare_comb("4b_LBU_byte2_comb");
        @(posedge clk); #1;
        compare("4b_LBU_byte2_reg");

        // LB from addr 0x04 → byte 0 of ram[1] = 0x04, sign-ext = 0x0000_0004
        instruction_in = make_instr(LB, 5'd8, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0004;
        program_counter_in = 32'h0004_0038;
        next_program_counter_in = 32'h0004_003C;
        #1; compare_comb("4c_LB_byte0_comb");
        @(posedge clk); #1;
        compare("4c_LB_byte0_reg");

        // LB from addr 0x07 → byte 3 of ram[1] = 0xDE, sign-ext = 0xFFFF_FFDE
        instruction_in = make_instr(LB, 5'd9, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0007;
        program_counter_in = 32'h0004_003C;
        next_program_counter_in = 32'h0004_0040;
        #1; compare_comb("4d_LB_byte3_comb");
        @(posedge clk); #1;
        compare("4d_LB_byte3_reg");

        // =====================================================================
        // SWEEP 5: SW — word store
        // =====================================================================
        $display("=== SWEEP 5: SW ===");

        // SW: store 0xCAFEBABE to byte address 0x80 → word 0x20
        instruction_in = make_instr(SW, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0080;  // address
        source_data_in = 32'hCAFE_BABE;  // data to store (rs2)
        program_counter_in = 32'h0004_0040;
        next_program_counter_in = 32'h0004_0044;
        #1; compare_comb("5a_SW_comb");
        @(posedge clk); #1;
        compare("5a_SW_reg");

        // Verify: read it back with LW
        instruction_in = make_instr(LW, 5'd11, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0080;
        source_data_in = 0;
        program_counter_in = 32'h0004_0044;
        next_program_counter_in = 32'h0004_0048;
        #1; compare_comb("5b_LW_readback_comb");
        @(posedge clk); #1;
        compare("5b_LW_readback_reg");

        // =====================================================================
        // SWEEP 6: SH — halfword store
        // =====================================================================
        $display("=== SWEEP 6: SH ===");

        // SH: store 0x1234 to low half of word at byte address 0x84
        instruction_in = make_instr(SH, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0084;
        source_data_in = 32'h0000_1234;
        program_counter_in = 32'h0004_0048;
        next_program_counter_in = 32'h0004_004C;
        #1; compare_comb("6a_SH_low_comb");
        @(posedge clk); #1;
        compare("6a_SH_low_reg");

        // SH: store 0xABCD to high half of same word (byte addr 0x86)
        instruction_in = make_instr(SH, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0086;
        source_data_in = 32'h0000_ABCD;
        program_counter_in = 32'h0004_004C;
        next_program_counter_in = 32'h0004_0050;
        #1; compare_comb("6b_SH_high_comb");
        @(posedge clk); #1;
        compare("6b_SH_high_reg");

        // =====================================================================
        // SWEEP 7: SB — byte store
        // =====================================================================
        $display("=== SWEEP 7: SB ===");

        // SB: store 0xFF to byte address 0x88 (byte 0 of word 0x22)
        instruction_in = make_instr(SB, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0088;
        source_data_in = 32'h0000_00FF;
        program_counter_in = 32'h0004_0050;
        next_program_counter_in = 32'h0004_0054;
        #1; compare_comb("7a_SB_byte0_comb");
        @(posedge clk); #1;
        compare("7a_SB_byte0_reg");

        // SB: store 0xAA to byte address 0x8B (byte 3 of word 0x22)
        instruction_in = make_instr(SB, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_008B;
        source_data_in = 32'h0000_00AA;
        program_counter_in = 32'h0004_0054;
        next_program_counter_in = 32'h0004_0058;
        #1; compare_comb("7b_SB_byte3_comb");
        @(posedge clk); #1;
        compare("7b_SB_byte3_reg");

        // =====================================================================
        // SWEEP 8: Alignment errors
        // =====================================================================
        $display("=== SWEEP 8: Alignment errors ===");

        // LW misaligned (addr[1:0] = 01)
        instruction_in = make_instr(LW, 5'd1, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0001;  // misaligned
        program_counter_in = 32'h0004_0060;
        next_program_counter_in = 32'h0004_0064;
        #1; compare_comb("8a_LW_misalign_comb");
        @(posedge clk); #1;
        compare("8a_LW_misalign_reg");

        // SW misaligned (addr[1:0] = 10)
        instruction_in = make_instr(SW, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0002;
        source_data_in = 32'hBEEF_BEEF;
        program_counter_in = 32'h0004_0064;
        next_program_counter_in = 32'h0004_0068;
        #1; compare_comb("8b_SW_misalign_comb");
        @(posedge clk); #1;
        compare("8b_SW_misalign_reg");

        // LH misaligned (addr[0] = 1)
        instruction_in = make_instr(LH, 5'd2, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0001;
        program_counter_in = 32'h0004_0068;
        next_program_counter_in = 32'h0004_006C;
        #1; compare_comb("8c_LH_misalign_comb");
        @(posedge clk); #1;
        compare("8c_LH_misalign_reg");

        // SH misaligned (addr[0] = 1)
        instruction_in = make_instr(SH, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0003;
        source_data_in = 32'h0000_ABCD;
        program_counter_in = 32'h0004_006C;
        next_program_counter_in = 32'h0004_0070;
        #1; compare_comb("8d_SH_misalign_comb");
        @(posedge clk); #1;
        compare("8d_SH_misalign_reg");

        // LB aligned at odd address (no error — byte ops never misalign)
        instruction_in = make_instr(LB, 5'd3, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0003;
        program_counter_in = 32'h0004_0070;
        next_program_counter_in = 32'h0004_0074;
        #1; compare_comb("8e_LB_odd_ok_comb");
        @(posedge clk); #1;
        compare("8e_LB_odd_ok_reg");

        // =====================================================================
        // SWEEP 9: BUBBLE / non-VALID status_forwards_in
        // =====================================================================
        $display("=== SWEEP 9: BUBBLE / non-VALID status ===");

        // BUBBLE with LW — should NOT access bus
        instruction_in = make_instr(LW, 5'd1, 5'd2, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0000;
        status_forwards_in = BUBBLE;
        program_counter_in = 32'h0004_0080;
        next_program_counter_in = 32'h0004_0084;
        #1; compare_comb("9a_LW_BUBBLE_comb");
        @(posedge clk); #1;
        compare("9a_LW_BUBBLE_reg");

        // FETCH_FAULT with SW — should NOT access bus
        instruction_in = make_instr(SW, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0000;
        source_data_in = 32'hBEEF_CAFE;
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h0004_0084;
        next_program_counter_in = 32'h0004_0088;
        #1; compare_comb("9b_SW_FETCH_FAULT_comb");
        @(posedge clk); #1;
        compare("9b_SW_FETCH_FAULT_reg");

        // Restore to VALID
        status_forwards_in = VALID;

        // =====================================================================
        // SWEEP 10: JUMP from Writeback
        // =====================================================================
        $display("=== SWEEP 10: JUMP from WB ===");

        // LW with JUMP — should not start bus transaction, output BUBBLE
        instruction_in = make_instr(LW, 5'd1, 5'd2, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0000;
        status_forwards_in = VALID;
        status_backwards_in = JUMP;
        jump_address_backwards_in = 32'hDEAD_0000;
        program_counter_in = 32'h0004_0090;
        next_program_counter_in = 32'h0004_0094;
        #1; compare_comb("10a_LW_JUMP_comb");
        @(posedge clk); #1;
        compare("10a_LW_JUMP_reg");

        // Non-memory with JUMP
        instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
        rd_data_in = 32'h0000_0300;
        source_data_in = 32'h0000_0400;
        program_counter_in = 32'h0004_0094;
        next_program_counter_in = 32'h0004_0098;
        #1; compare_comb("10b_ADD_JUMP_comb");
        @(posedge clk); #1;
        compare("10b_ADD_JUMP_reg");

        // Return to READY
        status_backwards_in = READY;
        jump_address_backwards_in = 0;

        // =====================================================================
        // SWEEP 11: STALL from Writeback
        // =====================================================================
        $display("=== SWEEP 11: STALL from WB ===");

        // First clock a normal ADD through
        instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
        rd_data_in = 32'h1111_1111;
        source_data_in = 32'h2222_2222;
        program_counter_in = 32'h0004_00A0;
        next_program_counter_in = 32'h0004_00A4;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        @(posedge clk); #1;
        compare("11a_ADD_pre_stall");

        // Now STALL — outputs should hold
        status_backwards_in = STALL;
        instruction_in = make_instr(ADDI, 5'd4, 5'd5, 5'd0, 32'h42);
        rd_data_in = 32'h3333_3333;
        program_counter_in = 32'h0004_00A4;
        next_program_counter_in = 32'h0004_00A8;
        #1; compare_comb("11b_STALL_comb");
        @(posedge clk); #1;
        compare("11b_STALL_reg");

        // Release
        status_backwards_in = READY;
        #1; compare_comb("11c_release_comb");
        @(posedge clk); #1;
        compare("11c_release_reg");

        // =====================================================================
        // SWEEP 12: Forwarding — data_valid for loads vs CSR vs stores
        // =====================================================================
        $display("=== SWEEP 12: Forwarding ===");

        // Load: data_valid should be 1
        instruction_in = make_instr(LW, 5'd10, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        program_counter_in = 32'h0004_00B0;
        next_program_counter_in = 32'h0004_00B4;
        #1; compare_comb("12a_LW_fwd_comb");
        @(posedge clk); #1;
        compare("12a_LW_fwd_reg");

        // CSR: data_valid should be 0
        instruction_in = make_instr(CSRRW, 5'd11, 5'd12, 5'd0, 32'h0);
        rd_data_in = 32'h0000_AAAA;
        program_counter_in = 32'h0004_00B4;
        next_program_counter_in = 32'h0004_00B8;
        #1; compare_comb("12b_CSRRW_fwd_comb");
        @(posedge clk); #1;
        compare("12b_CSRRW_fwd_reg");

        // Store: forwarding address should be 0
        instruction_in = make_instr(SW, 5'd0, 5'd0, 5'd10, 32'h0);
        rd_data_in = 32'h0000_0000;
        source_data_in = 32'h1234_5678;
        program_counter_in = 32'h0004_00B8;
        next_program_counter_in = 32'h0004_00BC;
        #1; compare_comb("12c_SW_fwd_comb");
        @(posedge clk); #1;
        compare("12c_SW_fwd_reg");

        // Branch: forwarding address should be 0
        instruction_in = make_instr(BEQ, 5'd0, 5'd1, 5'd2, 32'h100);
        rd_data_in = 32'h0000_0000;
        program_counter_in = 32'h0004_00BC;
        next_program_counter_in = 32'h0004_00C0;
        #1; compare_comb("12d_BEQ_fwd_comb");
        @(posedge clk); #1;
        compare("12d_BEQ_fwd_reg");

        // =====================================================================
        // SWEEP 13: All exception statuses passthrough
        // =====================================================================
        $display("=== SWEEP 13: Exception statuses ===");
        begin
            pipeline_status::forwards_t exc_stats[8] = '{
                FETCH_MISALIGNED, FETCH_FAULT, ILLEGAL_INSTRUCTION,
                LOAD_MISALIGNED, LOAD_FAULT, STORE_MISALIGNED, STORE_FAULT,
                pipeline_status::ECALL
            };
            for (int i = 0; i < 8; i++) begin
                instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
                rd_data_in = 32'h0000_0000;
                source_data_in = 32'h0;
                program_counter_in = 32'h0004_00D0 + i * 4;
                next_program_counter_in = 32'h0004_00D4 + i * 4;
                status_forwards_in = exc_stats[i];
                status_backwards_in = READY;
                #1; compare_comb($sformatf("13_exc%0d_comb", i));
                @(posedge clk); #1;
                compare($sformatf("13_exc%0d_reg", i));
            end
        end

        // Restore
        status_forwards_in = VALID;

        // =====================================================================
        // SWEEP 14: Reset mid-operation
        // =====================================================================
        $display("=== SWEEP 14: Reset ===");

        instruction_in = make_instr(LW, 5'd1, 5'd0, 5'd0, 32'h0);
        rd_data_in = 32'h0000_0010;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        program_counter_in = 32'h0004_00F0;
        next_program_counter_in = 32'h0004_00F4;
        @(posedge clk); #1;
        compare("14a_LW_pre_reset");

        rst = 1;
        @(posedge clk); #1;
        compare("14b_reset");

        rst = 0;
        instruction_in = make_instr(ADDI, 5'd4, 5'd5, 5'd0, 32'h42);
        rd_data_in = 32'h0000_0010;
        status_forwards_in = VALID;
        program_counter_in = 32'h0004_00F4;
        next_program_counter_in = 32'h0004_00F8;
        @(posedge clk); #1;
        compare("14c_post_reset");

        // =====================================================================
        // SWEEP 15: All CSR ops (data_valid = 0)
        // =====================================================================
        $display("=== SWEEP 15: CSR ops ===");
        begin
            op::t csr_ops[6] = '{CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI};
            for (int i = 0; i < 6; i++) begin
                instruction_in = make_instr(csr_ops[i], 5'd25, 5'd26, 5'd0, 32'h1F);
                rd_data_in = 32'hBBBB_CCCC;
                source_data_in = 32'hAAAA_AAAA;
                program_counter_in = 32'h0005_0000 + i * 4;
                next_program_counter_in = 32'h0005_0004 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("15_%0s_comb", csr_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("15_%0s_reg", csr_ops[i].name()));
            end
        end

        // =====================================================================
        // SUMMARY
        // =====================================================================
        $display("");
        $display("========================================");
        $display("  Tests: %0d   Errors: %0d", test_count, error_count);
        $display("========================================");
        if (error_count == 0) $display("\033[0;32mALL PASS\033[0m");
        else $display("\033[0;31mSOME TESTS FAILED\033[0m");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish;
    end
endmodule
