/* Compare writeback_stage (DUT) against ref_writeback_stage (REF).
 * Covers CSR ops, exceptions, interrupts, MRET, FENCE.I, forwarding. */

module test_writeback_compare;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;
    int error_count = 0;
    int test_count  = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    // Shared inputs
    logic [31:0]   source_data_in;
    logic [31:0]   rd_data_in;
    instruction::t instruction_in;
    logic [31:0]   program_counter_in;
    logic [31:0]   next_program_counter_in;
    logic          external_interrupt_in;
    logic          timer_interrupt_in;
    pipeline_status::forwards_t status_forwards_in;

    // DUT outputs
    forwarding::t                  dut_forwarding_out;
    pipeline_status::backwards_t   dut_status_backwards_out;
    logic [31:0]                   dut_jump_address_backwards_out;

    // REF outputs
    forwarding::t                  ref_forwarding_out;
    pipeline_status::backwards_t   ref_status_backwards_out;
    logic [31:0]                   ref_jump_address_backwards_out;

    // DUT
    writeback_stage dut (
        .clk(clk), .rst(rst),
        .source_data_in(source_data_in),
        .rd_data_in(rd_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .next_program_counter_in(next_program_counter_in),
        .external_interrupt_in(external_interrupt_in),
        .timer_interrupt_in(timer_interrupt_in),
        .forwarding_out(dut_forwarding_out),
        .status_forwards_in(status_forwards_in),
        .status_backwards_out(dut_status_backwards_out),
        .jump_address_backwards_out(dut_jump_address_backwards_out)
    );

    // REF
    ref_writeback_stage ref_dut (
        .clk(clk), .rst(rst),
        .source_data_in(source_data_in),
        .rd_data_in(rd_data_in),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .next_program_counter_in(next_program_counter_in),
        .external_interrupt_in(external_interrupt_in),
        .timer_interrupt_in(timer_interrupt_in),
        .forwarding_out(ref_forwarding_out),
        .status_forwards_in(status_forwards_in),
        .status_backwards_out(ref_status_backwards_out),
        .jump_address_backwards_out(ref_jump_address_backwards_out)
    );

    // Compare all outputs
    task automatic compare(string label);
        test_count++;
        if (dut_forwarding_out !== ref_forwarding_out) begin
            $display("[%0d] %s FAIL fwd: dut={dv=%0b,d=%08h,a=%0d} ref={dv=%0b,d=%08h,a=%0d}", test_count, label,
                     dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address,
                     ref_forwarding_out.data_valid, ref_forwarding_out.data, ref_forwarding_out.address);
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

    // Compare combinational outputs (before clock edge)
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

    // Helper to build instruction structs
    function automatic instruction::t make_instr(
        op::t op_v, logic [4:0] rd, logic [4:0] rs1, logic [4:0] rs2,
        csr::t csr_v, logic [31:0] imm
    );
        make_instr.op          = op_v;
        make_instr.rd_address  = rd;
        make_instr.rs1_address = rs1;
        make_instr.rs2_address = rs2;
        make_instr.csr         = csr_v;
        make_instr.immediate   = imm;
    endfunction

    // Shorthand for non-CSR instructions
    function automatic instruction::t make_simple(op::t op_v, logic [4:0] rd);
        make_simple = make_instr(op_v, rd, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
    endfunction

    initial begin
        $dumpfile("test_writeback_compare.fst");
        $dumpvars(0, test_writeback_compare);

        // Default all inputs
        rst = 1;
        source_data_in = 0;
        rd_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = 0;
        next_program_counter_in = 0;
        external_interrupt_in = 0;
        timer_interrupt_in = 0;
        status_forwards_in = BUBBLE;

        // Reset for 2 cycles
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // =================================================================
        // SWEEP 1: Basic VALID instruction passthrough (ALU)
        // =================================================================
        $display("=== SWEEP 1: Basic ALU passthrough ===");

        instruction_in = make_simple(ADDI, 5'd1);
        rd_data_in = 32'h12345678;
        source_data_in = 0;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        status_forwards_in = VALID;
        #1; compare_comb("1a_ADDI_comb");
        @(posedge clk); #1;
        compare("1a_ADDI_reg");

        instruction_in = make_simple(ADD, 5'd5);
        rd_data_in = 32'hDEADBEEF;
        program_counter_in = 32'h40004;
        next_program_counter_in = 32'h40008;
        #1; compare_comb("1b_ADD_comb");
        @(posedge clk); #1;
        compare("1b_ADD_reg");

        // =================================================================
        // SWEEP 2: BUBBLE passthrough (no register write, no jump)
        // =================================================================
        $display("=== SWEEP 2: BUBBLE passthrough ===");

        status_forwards_in = BUBBLE;
        instruction_in = make_simple(ADDI, 5'd10);
        rd_data_in = 32'hCAFEBABE;
        program_counter_in = 32'h40008;
        next_program_counter_in = 32'h4000C;
        #1; compare_comb("2a_BUBBLE_comb");
        @(posedge clk); #1;
        compare("2a_BUBBLE_reg");

        // =================================================================
        // SWEEP 3: CSR Write/Read — CSRRW to MSCRATCH
        // =================================================================
        $display("=== SWEEP 3: CSR CSRRW MSCRATCH ===");

        // Write 0xABCD0000 to MSCRATCH, rd gets old value (0)
        instruction_in = make_instr(CSRRW, 5'd2, 5'd1, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = 32'hABCD0000;
        rd_data_in = 0;
        status_forwards_in = VALID;
        program_counter_in = 32'h4000C;
        next_program_counter_in = 32'h40010;
        #1; compare_comb("3a_CSRRW_mscratch_comb");
        @(posedge clk); #1;
        compare("3a_CSRRW_mscratch_reg");

        // Read MSCRATCH back with CSRRS (source=0 means no set, just read)
        instruction_in = make_instr(CSRRS, 5'd3, 5'd0, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = 32'h0;  // rs1=x0, no bits set
        #1; compare_comb("3b_CSRRS_read_mscratch_comb");
        @(posedge clk); #1;
        compare("3b_CSRRS_read_mscratch_reg");

        // =================================================================
        // SWEEP 4: CSR MTVEC write (lowest 2 bits forced to 0)
        // =================================================================
        $display("=== SWEEP 4: CSR MTVEC ===");

        instruction_in = make_instr(CSRRW, 5'd4, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'h80001003;  // lowest 2 bits should be masked
        status_forwards_in = VALID;
        program_counter_in = 32'h40010;
        next_program_counter_in = 32'h40014;
        #1; compare_comb("4a_CSRRW_mtvec_comb");
        @(posedge clk); #1;
        compare("4a_CSRRW_mtvec_reg");

        // Read it back
        instruction_in = make_instr(CSRRS, 5'd5, 5'd0, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 0;
        #1; compare_comb("4b_read_mtvec_comb");
        @(posedge clk); #1;
        compare("4b_read_mtvec_reg");

        // =================================================================
        // SWEEP 5: CSR MEPC write (lowest 2 bits forced to 0)
        // =================================================================
        $display("=== SWEEP 5: CSR MEPC ===");

        instruction_in = make_instr(CSRRW, 5'd6, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h12345677;  // bit1=1, bit0=1 should be masked
        status_forwards_in = VALID;
        program_counter_in = 32'h40014;
        next_program_counter_in = 32'h40018;
        #1; compare_comb("5a_CSRRW_mepc_comb");
        @(posedge clk); #1;
        compare("5a_CSRRW_mepc_reg");

        // =================================================================
        // SWEEP 6: CSR MSTATUS — write MIE and MPIE
        // =================================================================
        $display("=== SWEEP 6: CSR MSTATUS ===");

        // Set MIE=1 (bit3), MPIE=1 (bit7) → write 0x88
        instruction_in = make_instr(CSRRW, 5'd7, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000088;
        status_forwards_in = VALID;
        program_counter_in = 32'h40018;
        next_program_counter_in = 32'h4001C;
        #1; compare_comb("6a_CSRRW_mstatus_comb");
        @(posedge clk); #1;
        compare("6a_CSRRW_mstatus_reg");

        // Read MSTATUS back
        instruction_in = make_instr(CSRRS, 5'd8, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        #1; compare_comb("6b_read_mstatus_comb");
        @(posedge clk); #1;
        compare("6b_read_mstatus_reg");

        // Clear MIE for next tests (so interrupts don't fire unexpectedly)
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;  // MIE=0, MPIE=1
        status_forwards_in = VALID;
        program_counter_in = 32'h4001C;
        next_program_counter_in = 32'h40020;
        @(posedge clk); #1;

        // =================================================================
        // SWEEP 7: CSR MIE — write MEIE and MTIE
        // =================================================================
        $display("=== SWEEP 7: CSR MIE ===");

        instruction_in = make_instr(CSRRW, 5'd9, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;  // MEIE=1 (bit11), MTIE=1 (bit7)
        status_forwards_in = VALID;
        program_counter_in = 32'h40020;
        next_program_counter_in = 32'h40024;
        #1; compare_comb("7a_CSRRW_mie_comb");
        @(posedge clk); #1;
        compare("7a_CSRRW_mie_reg");

        // Read MIE back
        instruction_in = make_instr(CSRRS, 5'd10, 5'd0, 5'd0, csr::MIE, 32'h0);
        source_data_in = 0;
        #1; compare_comb("7b_read_mie_comb");
        @(posedge clk); #1;
        compare("7b_read_mie_reg");

        // =================================================================
        // SWEEP 8: CSR immediate variants (CSRRWI, CSRRSI, CSRRCI)
        // =================================================================
        $display("=== SWEEP 8: CSR immediate variants ===");

        // CSRRWI to MSCRATCH with uimm=5'd21 (0x15)
        // In HaDes-V, decode/execute set source_data_in = zero_extend(uimm) for CSR-I variants
        instruction_in = make_instr(CSRRWI, 5'd11, 5'd21, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = {27'b0, 5'd21};  // zero-extended uimm
        status_forwards_in = VALID;
        program_counter_in = 32'h40024;
        next_program_counter_in = 32'h40028;
        #1; compare_comb("8a_CSRRWI_comb");
        @(posedge clk); #1;
        compare("8a_CSRRWI_reg");

        // CSRRSI to MSCRATCH — set bit 0 (uimm=1)
        instruction_in = make_instr(CSRRSI, 5'd12, 5'd1, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = {27'b0, 5'd1};  // zero-extended uimm
        #1; compare_comb("8b_CSRRSI_comb");
        @(posedge clk); #1;
        compare("8b_CSRRSI_reg");

        // CSRRCI to MSCRATCH — clear bit 0 (uimm=1)
        instruction_in = make_instr(CSRRCI, 5'd13, 5'd1, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = {27'b0, 5'd1};  // zero-extended uimm
        #1; compare_comb("8c_CSRRCI_comb");
        @(posedge clk); #1;
        compare("8c_CSRRCI_reg");

        // =================================================================
        // SWEEP 9: Exception handling (trap to MTVEC)
        // =================================================================
        $display("=== SWEEP 9: Exception traps ===");

        // First set MTVEC to a known value
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'h80000100;
        status_forwards_in = VALID;
        program_counter_in = 32'h40028;
        next_program_counter_in = 32'h4002C;
        @(posedge clk); #1;

        // Also clear MIE so interrupts don't interfere
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h0;  // MIE=0, MPIE=0
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // FETCH_MISALIGNED exception
        status_forwards_in = FETCH_MISALIGNED;
        instruction_in = make_simple(ADDI, 5'd1);
        rd_data_in = 32'h99999999;
        program_counter_in = 32'h40030;
        next_program_counter_in = 32'h40034;
        #1; compare_comb("9a_FETCH_MISALIGNED_comb");
        @(posedge clk); #1;
        compare("9a_FETCH_MISALIGNED_reg");

        // Verify MCAUSE was set (read it)
        instruction_in = make_instr(CSRRS, 5'd14, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        program_counter_in = 32'h80000100;
        next_program_counter_in = 32'h80000104;
        #1; compare_comb("9b_read_mcause_comb");
        @(posedge clk); #1;
        compare("9b_read_mcause_reg");

        // Verify MEPC was set
        instruction_in = make_instr(CSRRS, 5'd15, 5'd0, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 0;
        #1; compare_comb("9c_read_mepc_comb");
        @(posedge clk); #1;
        compare("9c_read_mepc_reg");

        // Test other exception types
        begin
            pipeline_status::forwards_t exc_types[7] = '{
                FETCH_FAULT, ILLEGAL_INSTRUCTION, LOAD_MISALIGNED,
                LOAD_FAULT, STORE_MISALIGNED, STORE_FAULT,
                pipeline_status::ECALL
            };
            for (int i = 0; i < 7; i++) begin
                status_forwards_in = exc_types[i];
                instruction_in = make_simple(ADDI, 5'd1);
                rd_data_in = 32'hAAAA0000 + i;
                program_counter_in = 32'h50000 + i * 4;
                next_program_counter_in = 32'h50004 + i * 4;
                #1; compare_comb($sformatf("9d_exc%0d_comb", i));
                @(posedge clk); #1;
                compare($sformatf("9d_exc%0d_reg", i));
            end
        end

        // EBREAK
        status_forwards_in = pipeline_status::EBREAK;
        instruction_in = make_simple(op::EBREAK, 5'd0);
        program_counter_in = 32'h5001C;
        next_program_counter_in = 32'h50020;
        #1; compare_comb("9e_EBREAK_comb");
        @(posedge clk); #1;
        compare("9e_EBREAK_reg");

        // =================================================================
        // SWEEP 10: Interrupt — external interrupt
        // =================================================================
        $display("=== SWEEP 10: External interrupt ===");

        // Setup: MTVEC=0x80000200, MIE(global)=1, MEIE=1
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'h80000200;
        status_forwards_in = VALID;
        external_interrupt_in = 0;
        timer_interrupt_in = 0;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;  // MEIE=1, MTIE=1
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // MIE=1
        @(posedge clk); #1;

        // Now assert external interrupt with a VALID instruction
        external_interrupt_in = 1;
        instruction_in = make_simple(ADDI, 5'd1);
        rd_data_in = 32'h42;
        source_data_in = 0;
        program_counter_in = 32'h60000;
        next_program_counter_in = 32'h60004;
        status_forwards_in = VALID;
        #1; compare_comb("10a_ext_int_comb");
        @(posedge clk); #1;
        compare("10a_ext_int_reg");
        external_interrupt_in = 0;

        // After trap, MIE should be 0. Verify no more interrupts fire.
        instruction_in = make_simple(ADDI, 5'd2);
        rd_data_in = 32'h43;
        program_counter_in = 32'h80000200;
        next_program_counter_in = 32'h80000204;
        status_forwards_in = VALID;
        #1; compare_comb("10b_after_trap_comb");
        @(posedge clk); #1;
        compare("10b_after_trap_reg");

        // =================================================================
        // SWEEP 11: Timer interrupt
        // =================================================================
        $display("=== SWEEP 11: Timer interrupt ===");

        // Re-enable MIE
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // MIE=1
        status_forwards_in = VALID;
        @(posedge clk); #1;

        timer_interrupt_in = 1;
        instruction_in = make_simple(ADDI, 5'd3);
        rd_data_in = 32'h44;
        source_data_in = 0;
        program_counter_in = 32'h60008;
        next_program_counter_in = 32'h6000C;
        status_forwards_in = VALID;
        #1; compare_comb("11a_timer_int_comb");
        @(posedge clk); #1;
        compare("11a_timer_int_reg");
        timer_interrupt_in = 0;

        // =================================================================
        // SWEEP 12: MRET — return from trap
        // =================================================================
        $display("=== SWEEP 12: MRET ===");

        // Setup MEPC for return address
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h70000;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // Set MSTATUS: MIE=0, MPIE=1 (typical trap handler state)
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;  // MPIE=1, MIE=0
        @(posedge clk); #1;

        // Execute MRET
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h80000210;
        next_program_counter_in = 32'h80000214;
        status_forwards_in = VALID;
        #1; compare_comb("12a_MRET_comb");
        @(posedge clk); #1;
        compare("12a_MRET_reg");

        // After MRET, MIE should be restored from MPIE (=1)
        instruction_in = make_instr(CSRRS, 5'd16, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        #1; compare_comb("12b_mstatus_after_mret_comb");
        @(posedge clk); #1;
        compare("12b_mstatus_after_mret_reg");

        // Clear MIE for next tests
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h0;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // =================================================================
        // SWEEP 13: MRET + immediate interrupt (same cycle)
        // =================================================================
        $display("=== SWEEP 13: MRET + immediate interrupt ===");

        // Setup: MEPC=0x70100, MTVEC=0x80000200, MIE(reg)=0, MPIE=1
        // MEIE=1, external interrupt asserted.
        // MRET restores MIE=MPIE=1, interrupt fires immediately.
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h70100;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'h80000200;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;  // MPIE=1, MIE=0
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000800;  // MEIE=1
        @(posedge clk); #1;

        // Now MRET with external interrupt active
        external_interrupt_in = 1;
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h80000220;
        next_program_counter_in = 32'h80000224;
        status_forwards_in = VALID;
        #1; compare_comb("13a_MRET_int_comb");
        @(posedge clk); #1;
        compare("13a_MRET_int_reg");
        external_interrupt_in = 0;

        // =================================================================
        // SWEEP 14: FENCE.I — jump to next_pc
        // =================================================================
        $display("=== SWEEP 14: FENCE.I ===");

        // Clear interrupts first
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h0;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        instruction_in = make_instr(FENCE_I, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h70004;
        next_program_counter_in = 32'h70008;
        status_forwards_in = VALID;
        #1; compare_comb("14a_FENCE_I_comb");
        @(posedge clk); #1;
        compare("14a_FENCE_I_reg");

        // =================================================================
        // SWEEP 15: WFI and FENCE — treated as NOPs
        // =================================================================
        $display("=== SWEEP 15: WFI and FENCE (NOPs) ===");

        instruction_in = make_simple(WFI, 5'd0);
        rd_data_in = 0;
        program_counter_in = 32'h70008;
        next_program_counter_in = 32'h7000C;
        status_forwards_in = VALID;
        #1; compare_comb("15a_WFI_comb");
        @(posedge clk); #1;
        compare("15a_WFI_reg");

        instruction_in = make_simple(FENCE, 5'd0);
        program_counter_in = 32'h7000C;
        next_program_counter_in = 32'h70010;
        #1; compare_comb("15b_FENCE_comb");
        @(posedge clk); #1;
        compare("15b_FENCE_reg");

        // =================================================================
        // SWEEP 16: MIP read (external + timer interrupt pending bits)
        // =================================================================
        $display("=== SWEEP 16: MIP read ===");

        external_interrupt_in = 1;
        timer_interrupt_in = 1;
        // MIE=0 so no trap fires, just read MIP
        instruction_in = make_instr(CSRRS, 5'd17, 5'd0, 5'd0, csr::MIP, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        program_counter_in = 32'h70010;
        next_program_counter_in = 32'h70014;
        #1; compare_comb("16a_MIP_read_comb");
        @(posedge clk); #1;
        compare("16a_MIP_read_reg");
        external_interrupt_in = 0;
        timer_interrupt_in = 0;

        // =================================================================
        // SWEEP 17: CSRRC — clear bits
        // =================================================================
        $display("=== SWEEP 17: CSRRC ===");

        // Write something to MSCRATCH first
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = 32'hFFFF0000;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // CSRRC: clear bits 16-23
        instruction_in = make_instr(CSRRC, 5'd18, 5'd1, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = 32'h00FF0000;
        #1; compare_comb("17a_CSRRC_comb");
        @(posedge clk); #1;
        compare("17a_CSRRC_reg");

        // Read back to verify
        instruction_in = make_instr(CSRRS, 5'd19, 5'd0, 5'd0, csr::MSCRATCH, 32'h0);
        source_data_in = 0;
        #1; compare_comb("17b_CSRRC_verify_comb");
        @(posedge clk); #1;
        compare("17b_CSRRC_verify_reg");

        // =================================================================
        // SWEEP 18: Read-only zero CSRs (MVENDORID, MARCHID, etc.)
        // =================================================================
        $display("=== SWEEP 18: Read-only zero CSRs ===");

        instruction_in = make_instr(CSRRS, 5'd20, 5'd0, 5'd0, csr::MVENDORID, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("18a_MVENDORID_comb");
        @(posedge clk); #1;
        compare("18a_MVENDORID_reg");

        instruction_in = make_instr(CSRRS, 5'd21, 5'd0, 5'd0, csr::MHARTID, 32'h0);
        source_data_in = 0;
        #1; compare_comb("18b_MHARTID_comb");
        @(posedge clk); #1;
        compare("18b_MHARTID_reg");

        // =================================================================
        // SWEEP 19: MCYCLE/MINSTRET counters
        // =================================================================
        $display("=== SWEEP 19: Cycle/instret counters ===");

        // Read MCYCLE
        instruction_in = make_instr(CSRRS, 5'd22, 5'd0, 5'd0, csr::MCYCLE, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        program_counter_in = 32'h80000;
        next_program_counter_in = 32'h80004;
        #1; compare_comb("19a_MCYCLE_read_comb");
        @(posedge clk); #1;
        compare("19a_MCYCLE_read_reg");

        // Read MINSTRET
        instruction_in = make_instr(CSRRS, 5'd23, 5'd0, 5'd0, csr::MINSTRET, 32'h0);
        source_data_in = 0;
        #1; compare_comb("19b_MINSTRET_read_comb");
        @(posedge clk); #1;
        compare("19b_MINSTRET_read_reg");

        // Write MCYCLE
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MCYCLE, 32'h0);
        source_data_in = 32'h1000;
        #1; compare_comb("19c_MCYCLE_write_comb");
        @(posedge clk); #1;
        compare("19c_MCYCLE_write_reg");

        // Read back (should be 1000, not 1001, since write suppresses increment?
        // Actually after the write cycle, the next cycle it will increment.)
        instruction_in = make_instr(CSRRS, 5'd24, 5'd0, 5'd0, csr::MCYCLE, 32'h0);
        source_data_in = 0;
        #1; compare_comb("19d_MCYCLE_readback_comb");
        @(posedge clk); #1;
        compare("19d_MCYCLE_readback_reg");

        // MCYCLEH write
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MCYCLEH, 32'h0);
        source_data_in = 32'hDEAD;
        #1; compare_comb("19e_MCYCLEH_write_comb");
        @(posedge clk); #1;
        compare("19e_MCYCLEH_write_reg");

        // Read MCYCLEH back
        instruction_in = make_instr(CSRRS, 5'd25, 5'd0, 5'd0, csr::MCYCLEH, 32'h0);
        source_data_in = 0;
        #1; compare_comb("19f_MCYCLEH_readback_comb");
        @(posedge clk); #1;
        compare("19f_MCYCLEH_readback_reg");

        // =================================================================
        // SWEEP 20: Interrupt on BUBBLE (should NOT fire)
        // =================================================================
        $display("=== SWEEP 20: Interrupt on BUBBLE ===");

        // Enable MIE
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // MIE=1
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // Assert interrupt but status is BUBBLE — should NOT trap
        external_interrupt_in = 1;
        instruction_in = make_simple(ADDI, 5'd1);
        rd_data_in = 32'h55;
        status_forwards_in = BUBBLE;
        program_counter_in = 32'h90000;
        next_program_counter_in = 32'h90004;
        #1; compare_comb("20a_int_bubble_comb");
        @(posedge clk); #1;
        compare("20a_int_bubble_reg");
        external_interrupt_in = 0;

        // Disable MIE again
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h0;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        // =================================================================
        // SWEEP 21: CSR write enables interrupt in same cycle
        // =================================================================
        $display("=== SWEEP 21: CSR enables interrupt same cycle ===");

        // Setup: MIE=0 in register, MEIE=1, external interrupt active.
        // CSR instruction writes MSTATUS.MIE=1 → interrupt should fire.
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000800;  // MEIE=1
        status_forwards_in = VALID;
        @(posedge clk); #1;

        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // MIE=1
        status_forwards_in = VALID;
        program_counter_in = 32'hA0000;
        next_program_counter_in = 32'hA0004;
        #1; compare_comb("21a_csr_enable_int_comb");
        @(posedge clk); #1;
        compare("21a_csr_enable_int_reg");
        external_interrupt_in = 0;

        // =================================================================
        // SWEEP 22: Stores/branches/etc — no register writeback
        // =================================================================
        $display("=== SWEEP 22: Stores and branches ===");

        // Clear MIE
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h0;
        status_forwards_in = VALID;
        @(posedge clk); #1;

        instruction_in = make_simple(SW, 5'd0);
        rd_data_in = 32'h99;
        source_data_in = 32'hBB;
        status_forwards_in = VALID;
        program_counter_in = 32'hB0000;
        next_program_counter_in = 32'hB0004;
        #1; compare_comb("22a_SW_comb");
        @(posedge clk); #1;
        compare("22a_SW_reg");

        instruction_in = make_simple(BEQ, 5'd0);
        rd_data_in = 32'h1;
        status_forwards_in = VALID;
        #1; compare_comb("22b_BEQ_comb");
        @(posedge clk); #1;
        compare("22b_BEQ_reg");

        // =================================================================
        // SWEEP 23: Reset mid-operation
        // =================================================================
        $display("=== SWEEP 23: Reset ===");

        instruction_in = make_simple(ADDI, 5'd1);
        rd_data_in = 32'h100;
        status_forwards_in = VALID;
        program_counter_in = 32'hC0000;
        next_program_counter_in = 32'hC0004;
        @(posedge clk); #1;
        compare("23a_pre_reset");

        rst = 1;
        @(posedge clk); #1;
        compare("23b_reset");

        rst = 0;
        instruction_in = make_simple(ADDI, 5'd2);
        rd_data_in = 32'h200;
        status_forwards_in = VALID;
        program_counter_in = 32'hC0004;
        next_program_counter_in = 32'hC0008;
        @(posedge clk); #1;
        compare("23c_post_reset");

        // =================================================================
        // SWEEP 24: MCAUSE write and read back
        // =================================================================
        $display("=== SWEEP 24: MCAUSE write/read ===");

        instruction_in = make_instr(CSRRW, 5'd26, 5'd1, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 32'h8000000B;
        status_forwards_in = VALID;
        #1; compare_comb("24a_MCAUSE_write_comb");
        @(posedge clk); #1;
        compare("24a_MCAUSE_write_reg");

        instruction_in = make_instr(CSRRS, 5'd27, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        #1; compare_comb("24b_MCAUSE_read_comb");
        @(posedge clk); #1;
        compare("24b_MCAUSE_read_reg");

        // =================================================================
        // SWEEP 25: MINSTRET write and verify suppression of auto-increment
        // =================================================================
        $display("=== SWEEP 25: MINSTRET write ===");

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MINSTRET, 32'h0);
        source_data_in = 32'h5000;
        status_forwards_in = VALID;
        #1; compare_comb("25a_MINSTRET_write_comb");
        @(posedge clk); #1;
        compare("25a_MINSTRET_write_reg");

        // Read back
        instruction_in = make_instr(CSRRS, 5'd28, 5'd0, 5'd0, csr::MINSTRET, 32'h0);
        source_data_in = 0;
        #1; compare_comb("25b_MINSTRET_readback_comb");
        @(posedge clk); #1;
        compare("25b_MINSTRET_readback_reg");

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
