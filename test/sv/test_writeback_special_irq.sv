/* Focused test for "special Interrupt cases" failures from Persephone.
 * Tests stale instruction suppression after JUMP, and exception+interrupt combos.
 * Compares DUT against REF to find divergence. */

module test_writeback_special_irq;
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
        end else begin
            $display("[%0d] %s OK fwd: {dv=%0b,d=%08h,a=%0d}", test_count, label,
                     dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address);
        end
        if (dut_status_backwards_out !== ref_status_backwards_out) begin
            $display("[%0d] %s FAIL sb: dut=%0d ref=%0d", test_count, label,
                     dut_status_backwards_out, ref_status_backwards_out);
            error_count++;
        end else begin
            $display("[%0d] %s OK sb: %0d", test_count, label, dut_status_backwards_out);
        end
        if (dut_jump_address_backwards_out !== ref_jump_address_backwards_out) begin
            $display("[%0d] %s FAIL jump: dut=%08h ref=%08h", test_count, label,
                     dut_jump_address_backwards_out, ref_jump_address_backwards_out);
            error_count++;
        end else begin
            $display("[%0d] %s OK jump: %08h", test_count, label, dut_jump_address_backwards_out);
        end
    endtask

    task automatic compare_comb(string label);
        test_count++;
        if (dut_forwarding_out !== ref_forwarding_out) begin
            $display("[%0d] %s COMB fwd: dut={dv=%0b,d=%08h,a=%0d} ref={dv=%0b,d=%08h,a=%0d}", test_count, label,
                     dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address,
                     ref_forwarding_out.data_valid, ref_forwarding_out.data, ref_forwarding_out.address);
            error_count++;
        end
        if (dut_status_backwards_out !== ref_status_backwards_out) begin
            $display("[%0d] %s COMB sb: dut=%0d ref=%0d", test_count, label,
                     dut_status_backwards_out, ref_status_backwards_out);
            error_count++;
        end
        if (dut_jump_address_backwards_out !== ref_jump_address_backwards_out) begin
            $display("[%0d] %s COMB jump: dut=%08h ref=%08h", test_count, label,
                     dut_jump_address_backwards_out, ref_jump_address_backwards_out);
            error_count++;
        end
    endtask

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

    function automatic instruction::t make_simple(op::t op_v, logic [4:0] rd);
        make_simple = make_instr(op_v, rd, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
    endfunction

    initial begin
        $dumpfile("test_writeback_special_irq.fst");
        $dumpvars(0, test_writeback_special_irq);

        rst = 1;
        source_data_in = 0;
        rd_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = 0;
        next_program_counter_in = 0;
        external_interrupt_in = 0;
        timer_interrupt_in = 0;
        status_forwards_in = BUBBLE;

        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // =================================================================
        // TEST A: Basic setup — mtvec, meie, check state
        // =================================================================
        $display("\n=== TEST A: Setup mtvec=0xdabbad00, MEIE=1 ===");

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;
        compare("A1_mtvec");

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;  // MEIE=1, MTIE=1
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;
        compare("A2_mie");

        // =================================================================
        // TEST B: "trigger Interrupt immediately" — CSRRS enables MIE
        // Mimics Persephone's exact test
        // =================================================================
        $display("\n=== TEST B: CSRRS MSTATUS MIE=1 with ext_int ===");

        // Enable MIE via CSRRS (set bit 3) with ext_interrupt=1
        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRS, 5'd1, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // Set MIE bit
        program_counter_in = 32'h00040010;
        next_program_counter_in = 32'h00040014;
        #1; compare_comb("B1_csrrs_mstatus_comb");
        @(posedge clk); #1;
        compare("B1_csrrs_mstatus_reg");

        // =================================================================
        // TEST B2: What happens next cycle? (stale instruction)
        // Try BUBBLE as stale
        // =================================================================
        $display("\n=== TEST B2: BUBBLE after immediate interrupt ===");
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = BUBBLE;
        program_counter_in = 32'h00040014;
        next_program_counter_in = 32'h00040018;
        external_interrupt_in = 1;
        rd_data_in = 0;
        source_data_in = 0;
        #1; compare_comb("B2_bubble_stale_comb");
        @(posedge clk); #1;
        compare("B2_bubble_stale_reg");

        // =================================================================
        // TEST B3: Check CSRs — read MEPC (like Persephone)
        // =================================================================
        $display("\n=== TEST B3: Check MEPC after immediate interrupt ===");
        external_interrupt_in = 0;
        instruction_in = make_instr(CSRRW, 5'd1, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'hfaceb00c;  // Write new MEPC value
        status_forwards_in = VALID;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        #1; compare_comb("B3_read_mepc_comb");
        @(posedge clk); #1;
        compare("B3_read_mepc_reg");

        // =================================================================
        // TEST C: Now try FETCH_FAULT as stale (instead of BUBBLE)
        // Reset and redo
        // =================================================================
        $display("\n=== TEST C: Reset and repeat with FETCH_FAULT stale ===");

        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Setup again
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;

        // Trigger immediate interrupt
        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRS, 5'd1, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;
        program_counter_in = 32'h00040010;
        next_program_counter_in = 32'h00040014;
        @(posedge clk); #1;
        compare("C1_int_imm");

        // Now send FETCH_FAULT as stale (NOT bubble!)
        $display("\n--- FETCH_FAULT stale after immediate interrupt ---");
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h00040014;
        next_program_counter_in = 32'h00040018;
        rd_data_in = 0;
        source_data_in = 0;
        #1; compare_comb("C2_fetchfault_stale_comb");
        @(posedge clk); #1;
        compare("C2_fetchfault_stale_reg");

        // Check MEPC — did the FETCH_FAULT corrupt it?
        external_interrupt_in = 0;
        instruction_in = make_instr(CSRRW, 5'd1, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'hfaceb00c;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        #1; compare_comb("C3_read_mepc_comb");
        @(posedge clk); #1;
        compare("C3_read_mepc_reg");

        // Check MSTATUS
        instruction_in = make_instr(CSRRS, 5'd2, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        #1; compare_comb("C4_read_mstatus_comb");
        @(posedge clk); #1;
        compare("C4_read_mstatus_reg");

        // Check MCAUSE
        instruction_in = make_instr(CSRRS, 5'd3, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        #1; compare_comb("C5_read_mcause_comb");
        @(posedge clk); #1;
        compare("C5_read_mcause_reg");

        // =================================================================
        // TEST D: Exception + interrupt simultaneous (MIE=1)
        // Reset and test exception+interrupt combo
        // =================================================================
        $display("\n=== TEST D: Exception + interrupt simultaneous ===");

        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Setup
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;

        // Enable MIE=1 (no interrupt yet)
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;

        // Now: FETCH_FAULT + ext_interrupt=1, MIE=1
        $display("\n--- FETCH_FAULT + ext_interrupt with MIE=1 ---");
        external_interrupt_in = 1;
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        rd_data_in = 0;
        source_data_in = 0;
        #1; compare_comb("D1_exc_int_comb");
        @(posedge clk); #1;
        compare("D1_exc_int_reg");

        // Stale after exception+interrupt JUMP: send another FETCH_FAULT
        $display("\n--- Stale FETCH_FAULT after exception+interrupt JUMP ---");
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h0004001c;
        next_program_counter_in = 32'h00040020;
        #1; compare_comb("D2_stale_exc_comb");
        @(posedge clk); #1;
        compare("D2_stale_exc_reg");

        // Check CSRs
        external_interrupt_in = 0;
        instruction_in = make_instr(CSRRS, 5'd4, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("D3_mcause_comb");
        @(posedge clk); #1;
        compare("D3_mcause_reg");

        instruction_in = make_instr(CSRRS, 5'd5, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        #1; compare_comb("D4_mstatus_comb");
        @(posedge clk); #1;
        compare("D4_mstatus_reg");

        instruction_in = make_instr(CSRRS, 5'd6, 5'd0, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 0;
        #1; compare_comb("D5_mepc_comb");
        @(posedge clk); #1;
        compare("D5_mepc_reg");

        // =================================================================
        // TEST E: Full "special Interrupt cases" sequence
        // Start from a known state, do the complete flow
        // =================================================================
        $display("\n=== TEST E: Full special interrupt cases sequence ===");

        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Setup MTVEC, MEIE, MTIE
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;  // MEIE=1, MTIE=1
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;

        // Step 1: Enable MIE=1 (ext_int=0, no interrupt)
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000008;  // MIE=1
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;
        compare("E1_enable_mie");

        // Step 2: MRET+interrupt (simulating end of "MRET while Interrupt pending")
        // First set MEPC and MPIE for MRET
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h0004005c;
        program_counter_in = 32'h0004000c;
        next_program_counter_in = 32'h00040010;
        @(posedge clk); #1;

        // Set MSTATUS: MPIE=1, MIE=0 (typical state before MRET)
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;  // MPIE=1, MIE=0
        program_counter_in = 32'h00040010;
        next_program_counter_in = 32'h00040014;
        @(posedge clk); #1;

        // MRET + ext_interrupt (should jump to MTVEC via immediate interrupt)
        external_interrupt_in = 1;
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h00040014;
        next_program_counter_in = 32'h00040018;
        status_forwards_in = VALID;
        #1; compare_comb("E2_mret_int_comb");
        @(posedge clk); #1;
        compare("E2_mret_int_reg");

        // Step 3: Stale after MRET+interrupt — try BUBBLE
        $display("\n--- Stale BUBBLE after MRET+interrupt ---");
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = BUBBLE;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        rd_data_in = 0;
        source_data_in = 0;
        #1; compare_comb("E3a_bubble_stale_comb");
        @(posedge clk); #1;
        compare("E3a_bubble_stale_reg");

        // Check MSTATUS after MRET+interrupt+bubble
        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRC, 5'd1, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("E4_mstatus_check_comb");
        @(posedge clk); #1;
        compare("E4_mstatus_check_reg");

        // MRET from exception while interrupt pending
        // Need MPIE=1 for MRET to restore MIE
        // After the MRET+interrupt trap: MPIE should be 1, MIE should be 0
        // MEPC should hold old value from before the interrupt
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        #1; compare_comb("E5_mret_exc_int_comb");
        @(posedge clk); #1;
        compare("E5_mret_exc_int_reg");

        // Check MCAUSE
        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRC, 5'd2, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("E6_mcause_check_comb");
        @(posedge clk); #1;
        compare("E6_mcause_check_reg");

        // =================================================================
        // TEST F: Same as E but with FETCH_FAULT stale instead of BUBBLE
        // =================================================================
        $display("\n=== TEST F: FETCH_FAULT stale after MRET+interrupt ===");

        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // Setup
        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h0004005c;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;  // MPIE=1, MIE=0
        program_counter_in = 32'h0004000c;
        next_program_counter_in = 32'h00040010;
        @(posedge clk); #1;

        // MRET + ext_interrupt
        external_interrupt_in = 1;
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h00040014;
        next_program_counter_in = 32'h00040018;
        status_forwards_in = VALID;
        #1; compare_comb("F1_mret_int_comb");
        @(posedge clk); #1;
        compare("F1_mret_int_reg");

        // FETCH_FAULT stale instead of BUBBLE!
        $display("\n--- FETCH_FAULT stale ---");
        instruction_in = make_simple(ADDI, 5'd0);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        rd_data_in = 0;
        source_data_in = 0;
        #1; compare_comb("F2_fetchfault_stale_comb");
        @(posedge clk); #1;
        compare("F2_fetchfault_stale_reg");

        // Check CSRs
        external_interrupt_in = 1;
        instruction_in = make_instr(CSRRC, 5'd1, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("F3_mstatus_check_comb");
        @(posedge clk); #1;
        compare("F3_mstatus_check_reg");

        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        #1; compare_comb("F4_mret_comb");
        @(posedge clk); #1;
        compare("F4_mret_reg");

        instruction_in = make_instr(CSRRC, 5'd2, 5'd0, 5'd0, csr::MCAUSE, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("F5_mcause_check_comb");
        @(posedge clk); #1;
        compare("F5_mcause_check_reg");

        // =================================================================
        // TEST G: No stale at all — MRET+int then directly check CSRs
        // =================================================================
        $display("\n=== TEST G: No stale — direct check after MRET+int ===");

        rst = 1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MTVEC, 32'h0);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MIE, 32'h0);
        source_data_in = 32'h00000880;
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MEPC, 32'h0);
        source_data_in = 32'h0004005c;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;

        instruction_in = make_instr(CSRRW, 5'd0, 5'd1, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 32'h00000080;
        program_counter_in = 32'h0004000c;
        next_program_counter_in = 32'h00040010;
        @(posedge clk); #1;

        // MRET + ext_interrupt
        external_interrupt_in = 1;
        instruction_in = make_instr(MRET, 5'd0, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        rd_data_in = 0;
        program_counter_in = 32'h00040014;
        next_program_counter_in = 32'h00040018;
        status_forwards_in = VALID;
        @(posedge clk); #1;
        compare("G1_mret_int");

        // Directly check MSTATUS — no stale in between
        instruction_in = make_instr(CSRRC, 5'd1, 5'd0, 5'd0, csr::MSTATUS, 32'h0);
        source_data_in = 0;
        status_forwards_in = VALID;
        #1; compare_comb("G2_mstatus_comb");
        @(posedge clk); #1;
        compare("G2_mstatus_reg");

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
