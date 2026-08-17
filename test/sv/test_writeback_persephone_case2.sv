/* Exact Persephone Case 2 replay — MRET from Exception while Interrupt pending.
 * Persephone report: DUT=0x00040018 (=MEPC), Expected=0xdabbad00 (=MTVEC).
 * Goal: find which MIE/MEIE pre-state produces DUT=0x00040018, and see REF's answer.
 */
module test_writeback_persephone_case2;
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
        $display("  [%-40s] DUT:{d=%08h sb=%0d j=%08h} REF:{d=%08h sb=%0d j=%08h}",
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

    task automatic set_mtvec();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MTVEC);
        source_data_in = 32'hdabbad00;
        status_forwards_in = VALID;
        program_counter_in = 32'h00040000;
        next_program_counter_in = 32'h00040004;
        @(posedge clk); #1;
    endtask

    task automatic set_meie();
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MIE);
        source_data_in = 32'h00000800; // MEIE=1
        program_counter_in = 32'h00040004;
        next_program_counter_in = 32'h00040008;
        @(posedge clk); #1;
    endtask

    task automatic set_mie(logic val);
        instruction_in = mk(CSRRW, 5'd0, 5'd1, csr::MSTATUS);
        source_data_in = val ? 32'h00000008 : 32'h00000000;
        program_counter_in = 32'h00040008;
        next_program_counter_in = 32'h0004000c;
        @(posedge clk); #1;
    endtask

    // Trigger a FETCH_FAULT exception at program_counter_in = 0x00040018
    task automatic trigger_exception();
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = FETCH_FAULT;
        program_counter_in = 32'h00040018;  // Will be saved to MEPC
        next_program_counter_in = 32'h0004001c;
        external_interrupt_in = 0;
        @(posedge clk); #1;
        status_forwards_in = BUBBLE;
        @(posedge clk); #1;
    endtask

    // Handler prologue: one valid NOP at MTVEC to simulate handler running
    task automatic handler_prologue();
        instruction_in = mk(ADDI, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        external_interrupt_in = 0;
        @(posedge clk); #1;
    endtask

    // MRET with ext_int=1
    task automatic do_mret_with_int(string lbl);
        instruction_in = mk(MRET, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad04;
        next_program_counter_in = 32'hdabbad08;
        external_interrupt_in = 1;
        #1; show({lbl, " MRET+ext_int (comb)"});
        @(posedge clk); #1;
        show({lbl, " MRET+ext_int (reg)"});
    endtask

    initial begin
        $dumpfile("test_writeback_persephone_case2.fst");
        $dumpvars(0, test_writeback_persephone_case2);

        // ==================================================================
        // V1: MIE=1 pre-exception, MEIE=1
        // Expected: MPIE=1 post-exc → MRET restores MIE=1 → IMM trap → MTVEC
        // ==================================================================
        $display("\n==== V1: MIE=1 pre-exc, MEIE=1 (standard MRET+pending) ====");
        do_reset(); set_mtvec(); set_meie(); set_mie(1);
        show("V1: pre-exception (MIE=1,MEIE=1)");
        trigger_exception();
        show("V1: after FETCH_FAULT (MPIE=1,MIE=0)");
        handler_prologue();
        show("V1: handler NOP");
        do_mret_with_int("V1:");

        // ==================================================================
        // V2: MIE=0 pre-exception, MEIE=1
        // Expected: MPIE=0 post-exc → MRET restores MIE=0 → no trap → MEPC
        // ==================================================================
        $display("\n==== V2: MIE=0 pre-exc, MEIE=1 (MPIE=0 hypothesis) ====");
        do_reset(); set_mtvec(); set_meie();  // skip set_mie → MIE=0 from reset
        show("V2: pre-exception (MIE=0,MEIE=1)");
        trigger_exception();
        show("V2: after FETCH_FAULT (MPIE=0,MIE=0)");
        handler_prologue();
        show("V2: handler NOP");
        do_mret_with_int("V2:");

        // ==================================================================
        // V3: MIE=1 pre-exception, MEIE=0
        // Expected: MPIE=1 post-exc; MEIE=0 → no trap → MEPC
        // ==================================================================
        $display("\n==== V3: MIE=1 pre-exc, MEIE=0 (MEIE=0 hypothesis) ====");
        do_reset(); set_mtvec();  // skip set_meie
        set_mie(1);
        show("V3: pre-exception (MIE=1,MEIE=0)");
        trigger_exception();
        show("V3: after FETCH_FAULT (MPIE=1,MIE=0,MEIE=0)");
        handler_prologue();
        show("V3: handler NOP");
        do_mret_with_int("V3:");

        // ==================================================================
        // V4: Minimal - just MTVEC, then exception, then MRET+ext_int
        //     (MEIE=0, MIE=0, MPIE=0 — just reset + MTVEC)
        // ==================================================================
        $display("\n==== V4: Minimal — MTVEC only, no MIE/MEIE setup ====");
        do_reset(); set_mtvec();
        show("V4: pre-exception (all 0)");
        trigger_exception();
        show("V4: after FETCH_FAULT");
        handler_prologue();
        show("V4: handler NOP");
        do_mret_with_int("V4:");

        // ==================================================================
        // V5: Like V2 but WITHOUT handler_prologue — MRET directly after BUBBLE
        // ==================================================================
        $display("\n==== V5: V2 without handler NOP ====");
        do_reset(); set_mtvec(); set_meie();
        trigger_exception();
        show("V5: after FETCH_FAULT");
        // MRET right away (no handler prologue)
        instruction_in = mk(MRET, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        external_interrupt_in = 1;
        #1; show("V5: MRET+ext_int (comb)");
        @(posedge clk); #1;
        show("V5: MRET+ext_int (reg)");

        // ==================================================================
        // V6: Like V1 but WITHOUT handler_prologue
        // ==================================================================
        $display("\n==== V6: V1 without handler NOP ====");
        do_reset(); set_mtvec(); set_meie(); set_mie(1);
        trigger_exception();
        show("V6: after FETCH_FAULT (MPIE=1)");
        instruction_in = mk(MRET, 5'd0, 5'd0, csr::MSTATUS);
        status_forwards_in = VALID;
        program_counter_in = 32'hdabbad00;
        next_program_counter_in = 32'hdabbad04;
        external_interrupt_in = 1;
        #1; show("V6: MRET+ext_int (comb)");
        @(posedge clk); #1;
        show("V6: MRET+ext_int (reg)");

        $finish;
    end
endmodule
