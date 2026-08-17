/* Minimal single-cycle replica of Persephone Cases 1 and 3.
 * Persephone: "CSRRC with status_forwards_in = VALID, ext/timer int = 1/0, csr = MSTATUS|MCAUSE"
 * Expected: MSTATUS=0x80, MCAUSE=0x8000000b.
 * Current DUT produces: MSTATUS=0x00, MCAUSE=0x01.
 *
 * Hypothesis: Persephone sets up ONE prior cycle with ext_int trap to a particular state.
 * We try several pre-state setups to find what Persephone uses.
 */
module test_writeback_persephone_case13;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    logic [31:0]   source_data_in;
    logic [31:0]   rd_data_in;
    instruction::t instruction_in;
    logic [31:0]   program_counter_in;
    logic [31:0]   next_program_counter_in;
    logic          external_interrupt_in;
    logic          timer_interrupt_in;
    pipeline_status::forwards_t status_forwards_in;

    forwarding::t                  dut_fwd, ref_fwd;
    pipeline_status::backwards_t   dut_sb, ref_sb;
    logic [31:0]                   dut_ja, ref_ja;

    writeback_stage dut (
        .clk, .rst, .source_data_in, .rd_data_in, .instruction_in,
        .program_counter_in, .next_program_counter_in,
        .external_interrupt_in, .timer_interrupt_in,
        .forwarding_out(dut_fwd), .status_forwards_in,
        .status_backwards_out(dut_sb),
        .jump_address_backwards_out(dut_ja)
    );
    ref_writeback_stage ref_dut (
        .clk, .rst, .source_data_in, .rd_data_in, .instruction_in,
        .program_counter_in, .next_program_counter_in,
        .external_interrupt_in, .timer_interrupt_in,
        .forwarding_out(ref_fwd), .status_forwards_in,
        .status_backwards_out(ref_sb),
        .jump_address_backwards_out(ref_ja)
    );

    function automatic instruction::t mk(
        op::t o, logic [4:0] rd, logic [4:0] rs1, csr::t c
    );
        mk.op = o; mk.rd_address = rd; mk.rs1_address = rs1;
        mk.rs2_address = 0; mk.csr = c; mk.immediate = 0;
    endfunction

    task automatic show(string lbl);
        $display("  [%-50s] DUT:{d=%08h sb=%0d j=%08h} REF:{d=%08h sb=%0d j=%08h}",
            lbl, dut_fwd.data, dut_sb, dut_ja,
                 ref_fwd.data, ref_sb, ref_ja);
    endtask

    task automatic do_reset();
        rst = 1; status_forwards_in = BUBBLE; external_interrupt_in = 0; timer_interrupt_in = 0;
        instruction_in = instruction::NOP; source_data_in = 0; rd_data_in = 0;
        program_counter_in = 0; next_program_counter_in = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;
    endtask

    initial begin
        $dumpfile("test_writeback_persephone_case13.fst");
        $dumpvars(0, test_writeback_persephone_case13);

        // ========================================================================
        // T1: Absolutely minimal — just reset, then CSRRC MSTATUS with ext_int=1
        // Checks REF's behavior when no state was set up
        // ========================================================================
        $display("\n==== T1: Minimal CSRRC MSTATUS ext_int=1, no setup ====");
        do_reset();
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        timer_interrupt_in = 0;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        #1; show("T1: CSRRC MSTATUS ext=1 (comb)");
        @(posedge clk); #1;
        show("T1: CSRRC MSTATUS ext=1 (reg)");

        // ========================================================================
        // T2: CSRRC MCAUSE (instead of MSTATUS) with ext_int=1, no setup
        // ========================================================================
        $display("\n==== T2: Minimal CSRRC MCAUSE ext_int=1, no setup ====");
        do_reset();
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        source_data_in = 0;
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        timer_interrupt_in = 0;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        #1; show("T2: CSRRC MCAUSE ext=1 (comb)");
        @(posedge clk); #1;
        show("T2: CSRRC MCAUSE ext=1 (reg)");

        // ========================================================================
        // T3: Precede with CSRS MIE (enable MEIE) then CSRRC MSTATUS + ext_int
        // ========================================================================
        $display("\n==== T3: MEIE set, then CSRRC MSTATUS ext_int=1 ====");
        do_reset();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800; // MEIE
        status_forwards_in = VALID;
        @(posedge clk); #1;
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        external_interrupt_in = 1;
        #1; show("T3: CSRRC MSTATUS (comb)");
        @(posedge clk); #1;
        show("T3: CSRRC MSTATUS (reg)");

        // ========================================================================
        // T4: MEIE+MIE set, then CSRRC MSTATUS + ext_int=1 (enable-changing CSR)
        // ========================================================================
        $display("\n==== T4: MEIE+MIE set, then CSRRC MSTATUS ext_int=1 ====");
        do_reset();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800;
        status_forwards_in = VALID;
        @(posedge clk); #1;
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008; // MIE=1
        @(posedge clk); #1;
        // Now CSRRC MSTATUS with ext_int=1 (IMM trap because MIE=1, MEIE=1, enable-change)
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        external_interrupt_in = 1;
        #1; show("T4: CSRRC MSTATUS (comb)");
        @(posedge clk); #1;
        show("T4: CSRRC MSTATUS (reg)");

        // ========================================================================
        // T5: Same but CSRRC MCAUSE
        // ========================================================================
        $display("\n==== T5: MEIE+MIE set, then CSRRC MCAUSE ext_int=1 ====");
        do_reset();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800;
        status_forwards_in = VALID;
        @(posedge clk); #1;
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        @(posedge clk); #1;
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        source_data_in = 0;
        external_interrupt_in = 1;
        #1; show("T5: CSRRC MCAUSE (comb)");
        @(posedge clk); #1;
        show("T5: CSRRC MCAUSE (reg)");

        // ========================================================================
        // T6: FETCH_FAULT exception → then CSRRC MSTATUS with ext_int=1
        // Hypothesis: Persephone's setup is minimal — just a prior FETCH_FAULT
        // sets mcause=1, mpie=0 (since MIE was 0). Then test input fires.
        // ========================================================================
        $display("\n==== T6: FETCH_FAULT, then CSRRC MSTATUS ext_int=1 ====");
        do_reset();
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        @(posedge clk); #1;
        show("T6: after FETCH_FAULT");
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("T6: BUBBLE stale");
        // Test input
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        program_counter_in = 32'h40008;
        next_program_counter_in = 32'h4000c;
        #1; show("T6: CSRRC MSTATUS (comb)");
        @(posedge clk); #1;
        show("T6: CSRRC MSTATUS (reg)");

        // ========================================================================
        // T7: FETCH_FAULT exception → then CSRRC MCAUSE with ext_int=1
        // ========================================================================
        $display("\n==== T7: FETCH_FAULT, then CSRRC MCAUSE ext_int=1 ====");
        do_reset();
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        @(posedge clk); #1;
        show("T7: after FETCH_FAULT");
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("T7: BUBBLE stale");
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        source_data_in = 0;
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        program_counter_in = 32'h40008;
        next_program_counter_in = 32'h4000c;
        #1; show("T7: CSRRC MCAUSE (comb)");
        @(posedge clk); #1;
        show("T7: CSRRC MCAUSE (reg)");

        // ========================================================================
        // T9: SEQUENCE — ext_int seq trap, then stale FETCH_FAULT, then CSRRC MCAUSE
        // Hypothesis: DUT overwrites mcause with stale ERROR's cause (=1, FETCH_FAULT)
        // after the sequential interrupt, corrupting it before CSRRC reads.
        // ========================================================================
        $display("\n==== T9: seq_int + stale FETCH_FAULT + CSRRC MCAUSE ====");
        do_reset();
        // Setup: MEIE, MIE
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800; status_forwards_in = VALID;
        program_counter_in = 32'h40000; next_program_counter_in = 32'h40004;
        @(posedge clk); #1;
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        @(posedge clk); #1;
        // Fire seq int
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        program_counter_in = 32'h40008; next_program_counter_in = 32'h4000c;
        @(posedge clk); #1;
        show("T9: after seq_int trigger");
        // Now a stale FETCH_FAULT arrives (this is the int_jump_reg cycle)
        status_forwards_in = FETCH_FAULT;
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        program_counter_in = 32'h40010; next_program_counter_in = 32'h40014;
        @(posedge clk); #1;
        show("T9: stale FETCH_FAULT at int_jump_reg cycle");
        // Another possibly stale cycle
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("T9: BUBBLE");
        // CSRRC MCAUSE with ext_int=1
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        source_data_in = 0; status_forwards_in = VALID;
        external_interrupt_in = 1;
        #1; show("T9: CSRRC MCAUSE (comb)");

        // ========================================================================
        // T10: Same but FETCH_FAULT AFTER int_jump_reg, two cycles out
        // ========================================================================
        $display("\n==== T10: seq_int + BUBBLE + stale FETCH_FAULT + CSRRC MCAUSE ====");
        do_reset();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800; status_forwards_in = VALID;
        program_counter_in = 32'h40000; next_program_counter_in = 32'h40004;
        @(posedge clk); #1;
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        @(posedge clk); #1;
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        @(posedge clk); #1;
        show("T10: after seq_int trigger");
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("T10: BUBBLE (int_jump_reg)");
        // Now a stale FETCH_FAULT
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h40010; next_program_counter_in = 32'h40014;
        @(posedge clk); #1;
        show("T10: stale FETCH_FAULT after int_jump_reg");
        // CSRRC MCAUSE
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        source_data_in = 0; status_forwards_in = VALID;
        external_interrupt_in = 1;
        #1; show("T10: CSRRC MCAUSE (comb)");

        // ========================================================================
        // T8: Directly test what happens with a VALID non-CSR at reset, ext=1
        // Is REF generating state out of thin air?
        // ========================================================================
        $display("\n==== T8: VALID ADDI+ext=1 at reset, then CSRRC MSTATUS ====");
        do_reset();
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        program_counter_in = 32'h40000;
        next_program_counter_in = 32'h40004;
        #1; show("T8: VALID+ext=1 (comb)");
        @(posedge clk); #1;
        show("T8: after VALID+ext=1");
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("T8: BUBBLE");
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        status_forwards_in = VALID;
        external_interrupt_in = 1;
        #1; show("T8: CSRRC MSTATUS (comb)");
        @(posedge clk); #1;
        show("T8: CSRRC MSTATUS (reg)");

        $finish;
    end
endmodule
