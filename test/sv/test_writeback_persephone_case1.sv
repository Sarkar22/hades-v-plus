/* Mirror Persephone "special Interrupt cases" sequences. */
module test_writeback_persephone_case1;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;
    import op::*;

    logic clk, rst;
    int err = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    logic [31:0]   source_data_in;
    logic [31:0]   rd_data_in;
    instruction::t instruction_in;
    logic [31:0]   program_counter_in;
    logic [31:0]   next_program_counter_in;
    logic          external_interrupt_in;
    logic          timer_interrupt_in;
    pipeline_status::forwards_t status_forwards_in;

    forwarding::t                  dut_forwarding_out;
    pipeline_status::backwards_t   dut_status_backwards_out;
    logic [31:0]                   dut_jump_address_backwards_out;

    forwarding::t                  ref_forwarding_out;
    pipeline_status::backwards_t   ref_status_backwards_out;
    logic [31:0]                   ref_jump_address_backwards_out;

    writeback_stage dut (
        .clk(clk), .rst(rst), .source_data_in, .rd_data_in, .instruction_in,
        .program_counter_in, .next_program_counter_in,
        .external_interrupt_in, .timer_interrupt_in,
        .forwarding_out(dut_forwarding_out), .status_forwards_in,
        .status_backwards_out(dut_status_backwards_out),
        .jump_address_backwards_out(dut_jump_address_backwards_out)
    );

    ref_writeback_stage ref_dut (
        .clk(clk), .rst(rst), .source_data_in, .rd_data_in, .instruction_in,
        .program_counter_in, .next_program_counter_in,
        .external_interrupt_in, .timer_interrupt_in,
        .forwarding_out(ref_forwarding_out), .status_forwards_in,
        .status_backwards_out(ref_status_backwards_out),
        .jump_address_backwards_out(ref_jump_address_backwards_out)
    );

    function automatic instruction::t mk(
        op::t o, logic [4:0] rd, logic [4:0] rs1, csr::t c
    );
        mk.op = o; mk.rd_address = rd; mk.rs1_address = rs1;
        mk.rs2_address = 0; mk.csr = c; mk.immediate = 0;
    endfunction

    task automatic show(string lbl);
        $display("  [%-30s] DUT:fwd={dv=%0b,d=%08h,a=%0d} sb=%0d j=%08h  |  REF:fwd={dv=%0b,d=%08h,a=%0d} sb=%0d j=%08h",
            lbl,
            dut_forwarding_out.data_valid, dut_forwarding_out.data, dut_forwarding_out.address,
            dut_status_backwards_out, dut_jump_address_backwards_out,
            ref_forwarding_out.data_valid, ref_forwarding_out.data, ref_forwarding_out.address,
            ref_status_backwards_out, ref_jump_address_backwards_out);
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

    task automatic setup_mtvec_meie();
        // Set MTVEC
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MTVEC);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;
        // Set MEIE (and MTIE)
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000880;
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;
    endtask

    initial begin
        $dumpfile("test_writeback_persephone_case1.fst");
        $dumpvars(0, test_writeback_persephone_case1);

        // ==================================================================
        // SCENARIO 1: Persephone Case 1 - "check CSRs" CSRRC MSTATUS
        // Hypothesis: after an interrupt trap, MSTATUS should be 0x80.
        // Then CSRRC MSTATUS returns 0x80.
        // Setup: MTVEC, MEIE, MIE=1, then ext_int fires, trap, then CSRRC.
        // ==================================================================
        $display("\n====== SCENARIO 1: CSRRC MSTATUS after interrupt trap ======");
        do_reset();
        setup_mtvec_meie();

        // Enable MIE via CSRRW MSTATUS=0x08 (NO ext_int yet to avoid imm trap)
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;
        show("S1: MIE=1 set");

        // Drive a NORMAL VALID instruction with ext_int=1 → SEQUENTIAL interrupt trap
        external_interrupt_in = 1;
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        program_counter_in = 32'h0004000c;
        next_program_counter_in = 32'h00040010;
        @(posedge clk); #1;
        show("S1: ADDI+ext_int (seq int triggers)");

        // Stale BUBBLE (proper pipeline flush after JUMP)
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("S1: BUBBLE stale");

        // Now CSRRC MSTATUS with ext_int=1 (test instruction)
        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MSTATUS);
        source_data_in = 0;
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        external_interrupt_in = 1;
        #1; show("S1: CSRRC MSTATUS (comb)");
        @(posedge clk); #1;
        show("S1: CSRRC MSTATUS (reg)");

        // ==================================================================
        // SCENARIO 2: Persephone Case 2 - MRET from Exception while Int pending
        // Hypothesis: Exception handler finishes with MRET; ext_int arrives
        // during handler; MRET triggers imm interrupt.
        // ==================================================================
        $display("\n====== SCENARIO 2: MRET from Exception with Int pending ======");
        do_reset();
        setup_mtvec_meie();

        // Enable MIE=1 (no ext_int)
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;
        show("S2: MIE=1 set");

        // Exception occurs (FETCH_FAULT) - triggers trap, MPIE=mie_eff=1, MIE=0
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h00040018;
        next_program_counter_in = 32'h0004001c;
        external_interrupt_in = 0;
        @(posedge clk); #1;
        show("S2: FETCH_FAULT exception");

        // BUBBLE stale after exception JUMP
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("S2: BUBBLE after exc");

        // Handler instruction (e.g., NOP at mtvec)
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        @(posedge clk); #1;
        show("S2: handler NOP");

        // Ext int arrives now
        external_interrupt_in = 1;
        program_counter_in = 32'hdabbad04;
        next_program_counter_in = 32'hdabbad08;
        @(posedge clk); #1;
        show("S2: handler w/ ext_int");

        // MRET — should trigger imm interrupt because MPIE=1 → MIE=1 and ext_int pending
        instruction_in = mk(MRET, 5'd0, 5'd0, csr::MSTATUS);
        program_counter_in = 32'hdabbad08;
        next_program_counter_in = 32'hdabbad0c;
        #1; show("S2: MRET (comb) - expected JUMP to mtvec");
        @(posedge clk); #1;
        show("S2: MRET (reg)");

        // ==================================================================
        // SCENARIO 3: Case 3 - CSRRC MCAUSE after interrupt trap
        // Similar to S1 but checks MCAUSE.
        // ==================================================================
        $display("\n====== SCENARIO 3: CSRRC MCAUSE after interrupt trap ======");
        do_reset();
        setup_mtvec_meie();

        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = 32'h00000008;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;
        show("S3: MIE=1 set");

        external_interrupt_in = 1;
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        program_counter_in = 32'h0004000c;
        next_program_counter_in = 32'h00040010;
        @(posedge clk); #1;
        show("S3: ADDI+ext_int seq");

        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
        show("S3: BUBBLE stale");

        instruction_in = mk(CSRRC, 5'd5, 5'd0, csr::MCAUSE);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        external_interrupt_in = 1;
        #1; show("S3: CSRRC MCAUSE (comb)");
        @(posedge clk); #1;
        show("S3: CSRRC MCAUSE (reg)");

        $finish;
    end
endmodule
