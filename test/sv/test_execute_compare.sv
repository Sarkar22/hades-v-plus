/* Compare execute_stage (DUT) against ref_execute_stage (REF).
 * Covers Persephone failures: JALR misalignment, STALL forwarding.
 * Also sweeps all op types with random data. */

module test_execute_compare;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;
    int error_count = 0;
    int test_count  = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    // Shared inputs
    logic [31:0]   rs1_data_in;
    logic [31:0]   rs2_data_in;
    instruction::t instruction_in;
    logic [31:0]   program_counter_in;

    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    logic [31:0]                 jump_address_backwards_in;

    // DUT outputs
    logic [31:0]   dut_source_data_reg_out;
    logic [31:0]   dut_rd_data_reg_out;
    instruction::t dut_instruction_reg_out;
    logic [31:0]   dut_program_counter_reg_out;
    logic [31:0]   dut_next_program_counter_reg_out;
    forwarding::t  dut_forwarding_out;
    pipeline_status::forwards_t  dut_status_forwards_out;
    pipeline_status::backwards_t dut_status_backwards_out;
    logic [31:0]   dut_jump_address_backwards_out;

    // REF outputs
    logic [31:0]   ref_source_data_reg_out;
    logic [31:0]   ref_rd_data_reg_out;
    instruction::t ref_instruction_reg_out;
    logic [31:0]   ref_program_counter_reg_out;
    logic [31:0]   ref_next_program_counter_reg_out;
    forwarding::t  ref_forwarding_out;
    pipeline_status::forwards_t  ref_status_forwards_out;
    pipeline_status::backwards_t ref_status_backwards_out;
    logic [31:0]   ref_jump_address_backwards_out;

    // DUT
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
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(dut_status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(dut_status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(dut_jump_address_backwards_out)
    );

    // REF
    ref_execute_stage ref_dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in),
        .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
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

    // Compare all outputs (registered + combinational)
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
        if (dut_jump_address_backwards_out !== ref_jump_address_backwards_out) begin
            $display("[%0d] %s COMB jump_addr: dut=%08h ref=%08h", test_count, label,
                     dut_jump_address_backwards_out, ref_jump_address_backwards_out);
            error_count++;
        end
    endtask

    // Helper
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

    initial begin
        $dumpfile("test_execute_compare.fst");
        $dumpvars(0, test_execute_compare);

        // Reset
        rst = 1;
        rs1_data_in = 0; rs2_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = 0;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // =================================================================
        // SWEEP 1: JALR misalignment (Persephone failures)
        // =================================================================
        $display("=== SWEEP 1: JALR misalignment ===");

        // 1a: rs1=0x33333333 + imm=0x11111110 = 0x44444443, &~1 = 0x44444442
        instruction_in = make_instr(JALR, 5'd1, 5'd2, 5'd0, 32'h11111110);
        rs1_data_in = 32'h33333333;
        rs2_data_in = 0;
        program_counter_in = 32'h1000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("1a_JALR_odd_comb");
        @(posedge clk); #1;
        compare("1a_JALR_odd_reg");

        // 1b: rs1=0x77777777 + imm=0x1111110E = 0x88888885, &~1 = 0x88888884
        instruction_in = make_instr(JALR, 5'd3, 5'd4, 5'd0, 32'h1111110E);
        rs1_data_in = 32'h77777777;
        program_counter_in = 32'h2000;
        #1; compare_comb("1b_JALR_odd_comb");
        @(posedge clk); #1;
        compare("1b_JALR_odd_reg");

        // 1c: aligned JALR — should NOT raise misalignment
        instruction_in = make_instr(JALR, 5'd5, 5'd6, 5'd0, 32'h4);
        rs1_data_in = 32'h1000;
        program_counter_in = 32'h3000;
        #1; compare_comb("1c_JALR_aligned_comb");
        @(posedge clk); #1;
        compare("1c_JALR_aligned_reg");

        // 1d: bit0=1 only — after mask target is aligned
        instruction_in = make_instr(JALR, 5'd7, 5'd8, 5'd0, 32'h1);
        rs1_data_in = 32'h2000;
        program_counter_in = 32'h4000;
        #1; compare_comb("1d_JALR_bit0_comb");
        @(posedge clk); #1;
        compare("1d_JALR_bit0_reg");

        // 1e: bit1=1, bit0=0 — after mask target has bit1 set (truly misaligned)
        instruction_in = make_instr(JALR, 5'd9, 5'd10, 5'd0, 32'h2);
        rs1_data_in = 32'h3000;
        program_counter_in = 32'h5000;
        #1; compare_comb("1e_JALR_bit1_comb");
        @(posedge clk); #1;
        compare("1e_JALR_bit1_reg");

        // =================================================================
        // SWEEP 2: STALL with JALR (Persephone failure)
        // =================================================================
        $display("=== SWEEP 2: STALL scenarios ===");

        // Send JALR first
        instruction_in = make_instr(JALR, 5'd10, 5'd11, 5'd0, 32'h3);
        rs1_data_in = 32'hAAAAAAAA;
        program_counter_in = 32'h5000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        @(posedge clk); #1;
        compare("2a_JALR_pre_stall");

        // Now STALL — held outputs, forwarding from registered state
        status_backwards_in = STALL;
        instruction_in = make_instr(ADDI, 5'd12, 5'd0, 5'd0, 32'h42);
        rs1_data_in = 0;
        program_counter_in = 32'h5004;
        #1; compare_comb("2b_STALL_comb");
        @(posedge clk); #1;
        compare("2b_STALL_reg");

        // Release
        status_backwards_in = READY;
        #1; compare_comb("2c_release_comb");
        @(posedge clk); #1;
        compare("2c_release_reg");

        // =================================================================
        // SWEEP 3: JUMP from Memory
        // =================================================================
        $display("=== SWEEP 3: JUMP from Memory ===");

        instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
        rs1_data_in = 32'h100; rs2_data_in = 32'h200;
        program_counter_in = 32'h6000;
        status_forwards_in = VALID;
        status_backwards_in = JUMP;
        jump_address_backwards_in = 32'hDEAD_0000;
        #1; compare_comb("3a_JUMP_mem_comb");
        @(posedge clk); #1;
        compare("3a_JUMP_mem_reg");

        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        instruction_in = make_instr(ADDI, 5'd4, 5'd5, 5'd0, 32'h10);
        rs1_data_in = 32'h50;
        program_counter_in = 32'h7000;
        #1; compare_comb("3b_after_jump_comb");
        @(posedge clk); #1;
        compare("3b_after_jump_reg");

        // =================================================================
        // SWEEP 4: Branches
        // =================================================================
        $display("=== SWEEP 4: Branches ===");

        // BEQ taken
        instruction_in = make_instr(BEQ, 5'd0, 5'd1, 5'd2, 32'h100);
        rs1_data_in = 32'hABCD; rs2_data_in = 32'hABCD;
        program_counter_in = 32'h8000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("4a_BEQ_taken_comb");
        @(posedge clk); #1;
        compare("4a_BEQ_taken_reg");

        // BEQ not taken
        rs2_data_in = 32'h1234;
        program_counter_in = 32'h8004;
        #1; compare_comb("4b_BEQ_notaken_comb");
        @(posedge clk); #1;
        compare("4b_BEQ_notaken_reg");

        // BNE taken
        instruction_in = make_instr(BNE, 5'd0, 5'd1, 5'd2, 32'hFFFFF000);
        rs1_data_in = 32'h1; rs2_data_in = 32'h2;
        program_counter_in = 32'h9000;
        #1; compare_comb("4c_BNE_taken_comb");
        @(posedge clk); #1;
        compare("4c_BNE_taken_reg");

        // BLT taken (signed: -1 < 0)
        instruction_in = make_instr(BLT, 5'd0, 5'd1, 5'd2, 32'h20);
        rs1_data_in = 32'hFFFFFFFF; rs2_data_in = 32'h0;
        program_counter_in = 32'hA000;
        #1; compare_comb("4d_BLT_taken_comb");
        @(posedge clk); #1;
        compare("4d_BLT_taken_reg");

        // BGE not taken
        instruction_in = make_instr(BGE, 5'd0, 5'd1, 5'd2, 32'h20);
        program_counter_in = 32'hA004;
        #1; compare_comb("4e_BGE_nottaken_comb");
        @(posedge clk); #1;
        compare("4e_BGE_nottaken_reg");

        // BLTU not taken (unsigned: 0xFFFFFFFF > 0)
        instruction_in = make_instr(BLTU, 5'd0, 5'd1, 5'd2, 32'h20);
        program_counter_in = 32'hA008;
        #1; compare_comb("4f_BLTU_nottaken_comb");
        @(posedge clk); #1;
        compare("4f_BLTU_nottaken_reg");

        // BGEU taken (unsigned: 0xFFFFFFFF >= 0)
        instruction_in = make_instr(BGEU, 5'd0, 5'd1, 5'd2, 32'h20);
        program_counter_in = 32'hA00C;
        #1; compare_comb("4g_BGEU_taken_comb");
        @(posedge clk); #1;
        compare("4g_BGEU_taken_reg");

        // =================================================================
        // SWEEP 5: JAL
        // =================================================================
        $display("=== SWEEP 5: JAL ===");
        instruction_in = make_instr(JAL, 5'd1, 5'd0, 5'd0, 32'h1000);
        rs1_data_in = 0; rs2_data_in = 0;
        program_counter_in = 32'hB000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("5a_JAL_comb");
        @(posedge clk); #1;
        compare("5a_JAL_reg");

        // =================================================================
        // SWEEP 6: R-type ALU
        // =================================================================
        $display("=== SWEEP 6: R-type ALU ===");
        begin
            op::t r_ops[10] = '{ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND};
            for (int i = 0; i < 10; i++) begin
                instruction_in = make_instr(r_ops[i], 5'd10, 5'd11, 5'd12, 32'h0);
                rs1_data_in = 32'hDEADBEEF;
                rs2_data_in = 32'h00000005;
                program_counter_in = 32'hC000 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("6_%0s_comb", r_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("6_%0s_reg", r_ops[i].name()));
            end
        end

        // =================================================================
        // SWEEP 7: I-type ALU
        // =================================================================
        $display("=== SWEEP 7: I-type ALU ===");
        begin
            op::t i_ops[9] = '{ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI};
            for (int i = 0; i < 9; i++) begin
                instruction_in = make_instr(i_ops[i], 5'd15, 5'd16, 5'd0, 32'h3);
                rs1_data_in = 32'hCAFEBABE;
                program_counter_in = 32'hD000 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("7_%0s_comb", i_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("7_%0s_reg", i_ops[i].name()));
            end
        end

        // =================================================================
        // SWEEP 8: Loads / Stores
        // =================================================================
        $display("=== SWEEP 8: Loads & Stores ===");
        begin
            op::t ls_ops[8] = '{LB, LH, LW, LBU, LHU, SB, SH, SW};
            for (int i = 0; i < 8; i++) begin
                instruction_in = make_instr(ls_ops[i], 5'd20, 5'd21, 5'd22, 32'h10);
                rs1_data_in = 32'h10000000;
                rs2_data_in = 32'hBEEF_CAFE;
                program_counter_in = 32'hE000 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("8_%0s_comb", ls_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("8_%0s_reg", ls_ops[i].name()));
            end
        end

        // =================================================================
        // SWEEP 9: LUI / AUIPC
        // =================================================================
        $display("=== SWEEP 9: LUI & AUIPC ===");
        instruction_in = make_instr(LUI, 5'd1, 5'd0, 5'd0, 32'hDEADB000);
        rs1_data_in = 0; rs2_data_in = 0;
        program_counter_in = 32'hF000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        #1; compare_comb("9a_LUI_comb");
        @(posedge clk); #1;
        compare("9a_LUI_reg");

        instruction_in = make_instr(AUIPC, 5'd2, 5'd0, 5'd0, 32'h1000);
        program_counter_in = 32'hF004;
        #1; compare_comb("9b_AUIPC_comb");
        @(posedge clk); #1;
        compare("9b_AUIPC_reg");

        // =================================================================
        // SWEEP 10: CSR
        // =================================================================
        $display("=== SWEEP 10: CSR ===");
        begin
            op::t csr_ops[6] = '{CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI};
            for (int i = 0; i < 6; i++) begin
                instruction_in = make_instr(csr_ops[i], 5'd25, 5'd26, 5'd0, 32'h1F);
                rs1_data_in = 32'hAAAAAAAA;
                program_counter_in = 32'h10000 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("10_%0s_comb", csr_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("10_%0s_reg", csr_ops[i].name()));
            end
        end

        // =================================================================
        // SWEEP 11: BUBBLE suppresses jumps
        // =================================================================
        $display("=== SWEEP 11: BUBBLE suppresses jumps ===");
        instruction_in = make_instr(JAL, 5'd1, 5'd0, 5'd0, 32'h1000);
        program_counter_in = 32'h20000;
        status_forwards_in = BUBBLE;
        status_backwards_in = READY;
        #1; compare_comb("11a_JAL_bubble_comb");
        @(posedge clk); #1;
        compare("11a_JAL_bubble_reg");

        instruction_in = make_instr(BEQ, 5'd0, 5'd1, 5'd2, 32'h100);
        rs1_data_in = 32'h5; rs2_data_in = 32'h5;
        program_counter_in = 32'h20004;
        status_forwards_in = BUBBLE;
        #1; compare_comb("11b_BEQ_bubble_comb");
        @(posedge clk); #1;
        compare("11b_BEQ_bubble_reg");

        // =================================================================
        // SWEEP 12: Special ops
        // =================================================================
        $display("=== SWEEP 12: Special ops ===");
        begin
            op::t special_ops[7] = '{FENCE, FENCE_I, op::ECALL, op::EBREAK, MRET, WFI, ILLEGAL};
            for (int i = 0; i < 7; i++) begin
                instruction_in = make_instr(special_ops[i], 5'd0, 5'd0, 5'd0, 32'h0);
                rs1_data_in = 0; rs2_data_in = 0;
                program_counter_in = 32'h30000 + i * 4;
                status_forwards_in = VALID;
                status_backwards_in = READY;
                #1; compare_comb($sformatf("12_%0s_comb", special_ops[i].name()));
                @(posedge clk); #1;
                compare($sformatf("12_%0s_reg", special_ops[i].name()));
            end
        end

        // =================================================================
        // SWEEP 13: Exception statuses
        // =================================================================
        $display("=== SWEEP 13: Exception statuses ===");
        begin
            pipeline_status::forwards_t exc_stats[8] = '{
                FETCH_MISALIGNED, FETCH_FAULT, ILLEGAL_INSTRUCTION,
                LOAD_MISALIGNED, LOAD_FAULT, STORE_MISALIGNED, STORE_FAULT,
                pipeline_status::ECALL
            };
            for (int i = 0; i < 8; i++) begin
                instruction_in = make_instr(JAL, 5'd1, 5'd0, 5'd0, 32'h1000);
                rs1_data_in = 0; rs2_data_in = 0;
                program_counter_in = 32'h40000 + i * 4;
                status_forwards_in = exc_stats[i];
                status_backwards_in = READY;
                #1; compare_comb($sformatf("13_exc%0d_comb", i));
                @(posedge clk); #1;
                compare($sformatf("13_exc%0d_reg", i));
            end
        end

        // =================================================================
        // SWEEP 14: Reset mid-operation
        // =================================================================
        $display("=== SWEEP 14: Reset ===");
        instruction_in = make_instr(ADD, 5'd1, 5'd2, 5'd3, 32'h0);
        rs1_data_in = 32'h100; rs2_data_in = 32'h200;
        program_counter_in = 32'h50000;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        @(posedge clk); #1;
        compare("14a_pre_reset");

        rst = 1;
        @(posedge clk); #1;
        compare("14b_reset");

        rst = 0;
        instruction_in = make_instr(ADDI, 5'd4, 5'd5, 5'd0, 32'h42);
        rs1_data_in = 32'h10;
        program_counter_in = 32'h50004;
        @(posedge clk); #1;
        compare("14c_post_reset");

        // =================================================================
        // SUMMARY
        // =================================================================
        $display("");
        $display("========================================");
        $display("  Tests: %0d   Errors: %0d", test_count, error_count);
        $display("========================================");
        if (error_count == 0) $display("ALL PASS");
        else $display("SOME TESTS FAILED");
        $finish;
    end
endmodule
