/* M extension: datapath + execute-stall protocol test.
 *
 * This drives execute_stage directly, because the two things worth proving about
 * the M extension are both invisible from software:
 *
 *   1. THE ARITHMETIC, against an independently written golden model that uses
 *      SystemVerilog's own signed/unsigned * / and % rather than a copy of the
 *      restoring-division datapath. Directed corner cases plus a random sweep.
 *
 *   2. THE STALL PROTOCOL. Execute had never stalled on its own behalf before
 *      the divider, so every interaction between the new backwards STALL and the
 *      pre-existing STALL/JUMP from Memory is new behaviour:
 *        - a divide flushed by a JUMP must be ABANDONED and must not hang;
 *        - a JUMP landing on the very cycle the divide finishes must still win;
 *        - a STALL from Memory must not lose or corrupt an in-flight divide;
 *        - a completed divide must survive a Memory stall that outlasts it;
 *        - a non-VALID (BUBBLE) M op must never stall at all;
 *        - back-to-back M ops must each start from a clean unit.
 *
 * Every wait loop is bounded and reports a HANG rather than spinning, because a
 * hang is the specific failure mode this design risks.
 */
module test_m_execute;
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

    function automatic instruction::t make_instr(op::t o, logic [4:0] rd,
                                                 logic [4:0] rs1, logic [4:0] rs2);
        make_instr.op          = o;
        make_instr.rd_address  = rd;
        make_instr.rs1_address = rs1;
        make_instr.rs2_address = rs2;
        make_instr.csr         = csr::MSTATUS;
        make_instr.immediate   = 32'b0;
    endfunction

    // ---------------------------------------------------------------------
    // Golden model — deliberately NOT a copy of the DUT datapath.
    // The multiplies are done by widening both operands to 64 bits and using
    // one multiply; the divisions use SystemVerilog's own / and %, whose
    // truncate-toward-zero and sign-of-dividend rules are exactly RISC-V's.
    // Only the two architecturally mandated special cases are spelled out.
    // ---------------------------------------------------------------------
    function automatic logic [31:0] m_ref(op::t o, logic [31:0] a, logic [31:0] b);
        logic signed [63:0] as, bs, au, bu;
        as = {{32{a[31]}}, a};
        bs = {{32{b[31]}}, b};
        au = {32'b0, a};
        bu = {32'b0, b};
        case (o)
            MUL:     m_ref = 32'(au * bu);
            MULH:    m_ref = 32'((as * bs) >>> 32);
            MULHSU:  m_ref = 32'((as * bu) >>> 32);
            MULHU:   m_ref = 32'(unsigned'(au * bu) >> 32);

            DIV:     if (b == 32'h0)                                 m_ref = 32'hFFFF_FFFF;
                     else if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) m_ref = 32'h8000_0000;
                     else                                            m_ref = $signed(a) / $signed(b);

            DIVU:    if (b == 32'h0) m_ref = 32'hFFFF_FFFF;
                     else            m_ref = a / b;

            REM:     if (b == 32'h0)                                 m_ref = a;
                     else if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) m_ref = 32'h0;
                     else                                            m_ref = $signed(a) % $signed(b);

            REMU:    if (b == 32'h0) m_ref = a;
                     else            m_ref = a % b;

            default: m_ref = 32'h0;
        endcase
    endfunction

    function automatic string opname(op::t o);
        case (o)
            MUL: opname = "MUL";       MULH: opname = "MULH";
            MULHSU: opname = "MULHSU"; MULHU: opname = "MULHU";
            DIV: opname = "DIV";       DIVU: opname = "DIVU";
            REM: opname = "REM";       REMU: opname = "REMU";
            default: opname = "OTHER";
        endcase
    endfunction

    // Idle the stage for one cycle with a harmless NOP.
    task automatic idle_cycle();
        instruction_in      = make_instr(ADDI, 5'd0, 5'd0, 5'd0);
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        @(posedge clk); #1;
    endtask

    // Issue one M op, ride out however many stall cycles it takes, and check
    // both the forwarded (combinational) result and the registered result.
    // Returns the number of cycles the instruction occupied Execute.
    task automatic run_m(op::t o, logic [31:0] a, logic [31:0] b, output int cycles);
        logic [31:0] exp;
        exp = m_ref(o, a, b);

        instruction_in      = make_instr(o, 5'd10, 5'd11, 5'd12);
        rs1_data_in         = a;
        rs2_data_in         = b;
        program_counter_in  = 32'h4000;
        status_forwards_in  = VALID;
        status_backwards_in = READY;

        cycles = 0;
        #1;
        while (dut_status_backwards_out == STALL) begin
            // While stalling, Execute must hand Memory a BUBBLE and must not
            // advertise its partial result as forwardable.
            if (dut_forwarding_out.data_valid !== 1'b0) begin
                $display("FAIL %s(%08h,%08h): data_valid set mid-stall", opname(o), a, b);
                errors++;
            end
            @(posedge clk); #1;
            cycles++;
            if (dut_status_forwards_out !== BUBBLE) begin
                $display("FAIL %s(%08h,%08h): forwards_out=%0d during stall (want BUBBLE)",
                         opname(o), a, b, dut_status_forwards_out);
                errors++;
            end
            if (cycles > 200) begin
                $display("HANG %s(%08h,%08h): still stalling after %0d cycles",
                         opname(o), a, b, cycles);
                errors++;
                return;
            end
        end

        checks++;
        // Retire cycle: the result must be forwardable now.
        if (dut_forwarding_out.data !== exp || dut_forwarding_out.data_valid !== 1'b1) begin
            $display("FAIL %s(%08h,%08h): fwd={dv=%0b,d=%08h} want dv=1 d=%08h",
                     opname(o), a, b, dut_forwarding_out.data_valid, dut_forwarding_out.data, exp);
            errors++;
        end
        @(posedge clk); #1;
        cycles++;
        if (dut_rd_data_reg_out !== exp) begin
            $display("FAIL %s(%08h,%08h): rd_data=%08h want %08h",
                     opname(o), a, b, dut_rd_data_reg_out, exp);
            errors++;
        end
        if (dut_status_forwards_out !== VALID) begin
            $display("FAIL %s(%08h,%08h): forwards_out=%0d at retire (want VALID)",
                     opname(o), a, b, dut_status_forwards_out);
            errors++;
        end
    endtask

    task automatic expect_eq(int unsigned got, int unsigned want, string what);
        checks++;
        if (got !== want) begin
            $display("FAIL %s: got %0d want %0d", what, got, want);
            errors++;
        end
    endtask

    op::t div_ops[4] = '{DIV, DIVU, REM, REMU};
    op::t all_ops[8] = '{MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU};

    logic [31:0] corners[] = '{
        32'h0000_0000, 32'h0000_0001, 32'h0000_0002, 32'h0000_0003, 32'h0000_0007,
        32'h7FFF_FFFF, 32'h8000_0000, 32'h8000_0001, 32'hFFFF_FFFF, 32'hFFFF_FFFE,
        32'hFFFF_FFF9, 32'h0000_FFFF, 32'h0001_0000, 32'hDEAD_BEEF, 32'h1234_5678,
        32'h9ABC_DEF0, 32'h5555_5555, 32'hAAAA_AAAA
    };

    initial begin
        int c, c2, mul_cycles, div_cycles, early_cycles;
        logic [31:0] a, b;

        $dumpfile("test_m_execute.fst");
        $dumpvars(0, test_m_execute);

        rst = 1;
        rs1_data_in = 0; rs2_data_in = 0;
        instruction_in = instruction::NOP;
        program_counter_in = 0;
        status_forwards_in = VALID;
        status_backwards_in = READY;
        jump_address_backwards_in = 0;
        bp_prediction_in = '0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        // =================================================================
        $display("=== 1: latency of each class ===");
        // =================================================================
        run_m(MUL, 32'd6, 32'd7, mul_cycles);
        idle_cycle();
        run_m(DIV, 32'd100, 32'd7, div_cycles);
        idle_cycle();
        run_m(DIV, 32'd100, 32'd0, early_cycles);
        idle_cycle();
        $display("    MEASURED: multiply = %0d cycles, divide = %0d cycles, early-out divide = %0d cycle(s)",
                 mul_cycles, div_cycles, early_cycles);
        expect_eq(mul_cycles,   2,  "multiply occupancy");
        expect_eq(div_cycles,   34, "divide occupancy");
        expect_eq(early_cycles, 1,  "early-out occupancy");

        // =================================================================
        $display("=== 2: mandated divide-by-zero results ===");
        // =================================================================
        foreach (corners[i]) begin
            foreach (div_ops[k]) begin
                run_m(div_ops[k], corners[i], 32'h0, c);
                idle_cycle();
                // Divide by zero must never iterate.
                expect_eq(c, 1, $sformatf("div-by-zero %s is an early-out", opname(div_ops[k])));
            end
        end

        // =================================================================
        $display("=== 3: mandated signed-overflow results (-2^31 / -1) ===");
        // =================================================================
        foreach (div_ops[k]) begin
            run_m(div_ops[k], 32'h8000_0000, 32'hFFFF_FFFF, c);
            idle_cycle();
        end

        // =================================================================
        $display("=== 4: sign-of-remainder in all four quadrants ===");
        // =================================================================
        begin
            logic [31:0] quad_a[4] = '{32'd7, 32'hFFFF_FFF9, 32'd7, 32'hFFFF_FFF9}; // 7,-7,7,-7
            logic [31:0] quad_b[4] = '{32'd2, 32'd2, 32'hFFFF_FFFE, 32'hFFFF_FFFE}; // 2,2,-2,-2
            for (int q = 0; q < 4; q++) begin
                run_m(DIV, quad_a[q], quad_b[q], c); idle_cycle();
                run_m(REM, quad_a[q], quad_b[q], c); idle_cycle();
            end
        end

        // =================================================================
        $display("=== 5: corner x corner, all eight ops ===");
        // =================================================================
        foreach (corners[i])
            foreach (corners[j])
                foreach (all_ops[k]) begin
                    run_m(all_ops[k], corners[i], corners[j], c);
                    idle_cycle();
                end

        // =================================================================
        $display("=== 6: random sweep ===");
        // =================================================================
        for (int n = 0; n < 400; n++) begin
            a = $urandom();
            b = $urandom();
            // bias towards small divisors as well, they exercise long quotients
            if (n % 4 == 0) b = b & 32'h0000_00FF;
            if (n % 8 == 0) a = a & 32'h0000_FFFF;
            foreach (all_ops[k]) begin
                run_m(all_ops[k], a, b, c);
                idle_cycle();
            end
        end

        // =================================================================
        $display("=== 7: back-to-back M ops with no gap ===");
        // =================================================================
        // No idle_cycle() between these: the unit must return to idle on the
        // same edge the previous instruction retires.
        run_m(DIV,  32'd1000, 32'd7,  c);
        run_m(REM,  32'd1000, 32'd7,  c2);
        expect_eq(c2, 34, "second back-to-back divide still takes 34 cycles");
        run_m(MUL,  32'd1000, 32'd7,  c);
        run_m(MULH, 32'hFFFF_FFFF, 32'hFFFF_FFFF, c2);
        expect_eq(c2, 2, "back-to-back multiply still takes 2 cycles");
        run_m(DIVU, 32'd0, 32'd0, c);       // early-out straight after a multiply
        expect_eq(c, 1, "early-out straight after a multiply");
        idle_cycle();

        // =================================================================
        $display("=== 8: a BUBBLE M op must not stall ===");
        // =================================================================
        instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
        rs1_data_in         = 32'd1000;
        rs2_data_in         = 32'd7;
        status_forwards_in  = BUBBLE;
        status_backwards_in = READY;
        #1;
        checks++;
        if (dut_status_backwards_out !== READY) begin
            $display("FAIL BUBBLE divide asserted %0d backwards (want READY)", dut_status_backwards_out);
            errors++;
        end
        @(posedge clk); #1;
        idle_cycle();

        // Same for an M op carrying an exception status.
        instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
        status_forwards_in  = ILLEGAL_INSTRUCTION;
        #1;
        checks++;
        if (dut_status_backwards_out !== READY) begin
            $display("FAIL exception-status divide asserted %0d backwards (want READY)",
                     dut_status_backwards_out);
            errors++;
        end
        @(posedge clk); #1;
        idle_cycle();

        // =================================================================
        $display("=== 9: JUMP mid-divide — abandon, no hang ===");
        // =================================================================
        for (int wait_cycles = 0; wait_cycles < 36; wait_cycles++) begin
            instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
            rs1_data_in         = 32'hDEAD_BEEF;
            rs2_data_in         = 32'd7;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            #1;
            for (int w = 0; w < wait_cycles; w++) begin
                @(posedge clk); #1;
            end

            // Memory/Writeback flushes us.
            status_backwards_in       = JUMP;
            jump_address_backwards_in = 32'hCAFE_0000;
            #1;
            checks++;
            if (dut_status_backwards_out !== JUMP) begin
                $display("FAIL JUMP@%0d: backwards_out=%0d (want JUMP) — divide is holding the pipeline",
                         wait_cycles, dut_status_backwards_out);
                errors++;
            end
            if (dut_jump_address_backwards_out !== 32'hCAFE_0000) begin
                $display("FAIL JUMP@%0d: jump address not passed through", wait_cycles);
                errors++;
            end
            @(posedge clk); #1;
            checks++;
            if (dut_status_forwards_out !== BUBBLE) begin
                $display("FAIL JUMP@%0d: flushed instruction not squashed to BUBBLE (got %0d)",
                         wait_cycles, dut_status_forwards_out);
                errors++;
            end

            // Pipeline resumes. An ordinary ADD must retire immediately, which
            // proves the unit was released rather than left holding a stall.
            status_backwards_in = READY;
            instruction_in      = make_instr(ADD, 5'd5, 5'd11, 5'd12);
            rs1_data_in         = 32'd100;
            rs2_data_in         = 32'd23;
            status_forwards_in  = VALID;
            #1;
            checks++;
            if (dut_status_backwards_out !== READY) begin
                $display("FAIL JUMP@%0d: stage still stalling after flush (got %0d) — HANG",
                         wait_cycles, dut_status_backwards_out);
                errors++;
            end
            @(posedge clk); #1;
            checks++;
            if (dut_rd_data_reg_out !== 32'd123) begin
                $display("FAIL JUMP@%0d: ADD after flush produced %08h want 0000007b",
                         wait_cycles, dut_rd_data_reg_out);
                errors++;
            end
            idle_cycle();

            // And a fresh divide must work from a clean unit.
            run_m(DIV, 32'd1000, 32'd7, c);
            checks++;
            if (c != 34) begin
                $display("FAIL JUMP@%0d: divide after flush took %0d cycles, want 34",
                         wait_cycles, c);
                errors++;
            end
            idle_cycle();
        end

        // =================================================================
        $display("=== 9b: a valid M op presented on the cycle right after a flush ===");
        // =================================================================
        // In the assembled pipeline Decode always injects at least one BUBBLE
        // behind a JUMP, so this input sequence does not occur there. It is
        // driven here on purpose: it is what makes "the FSM is reset by the
        // flush itself" a locally checkable property of execute_stage rather
        // than an inherited assumption about what Decode happens to do. Without
        // the reset the unit would still be parked in M_READY and the new
        // divide would retire immediately with the previous divide's result.
        for (int wait_cycles = 1; wait_cycles < 36; wait_cycles++) begin
            instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
            rs1_data_in         = 32'hDEAD_BEEF;
            rs2_data_in         = 32'd7;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            #1;
            for (int w = 0; w < wait_cycles; w++) begin
                @(posedge clk); #1;
            end
            status_backwards_in       = JUMP;
            jump_address_backwards_in = 32'hFEED_0000;
            #1;
            @(posedge clk); #1;          // flush edge
            status_backwards_in = READY;
            // No idle cycle: a brand-new divide, different operands, right away.
            run_m(REMU, 32'd1000, 32'd7, c);
            checks++;
            if (c != 34) begin
                $display("FAIL flush-then-M@%0d: new divide took %0d cycles, want 34 (unit not reset)",
                         wait_cycles, c);
                errors++;
            end
            idle_cycle();
        end

        // =================================================================
        $display("=== 10: JUMP arriving on the exact cycle the divide finishes ===");
        // =================================================================
        instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
        rs1_data_in         = 32'd1000;
        rs2_data_in         = 32'd7;
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        #1;
        while (dut_status_backwards_out == STALL) begin
            @(posedge clk); #1;
        end
        // The result is ready THIS cycle. Now flush.
        status_backwards_in       = JUMP;
        jump_address_backwards_in = 32'hBEEF_0000;
        #1;
        checks++;
        if (dut_status_backwards_out !== JUMP) begin
            $display("FAIL JUMP-on-done: backwards_out=%0d (want JUMP)", dut_status_backwards_out);
            errors++;
        end
        @(posedge clk); #1;
        checks++;
        if (dut_status_forwards_out !== BUBBLE) begin
            $display("FAIL JUMP-on-done: not squashed to BUBBLE (got %0d)", dut_status_forwards_out);
            errors++;
        end
        status_backwards_in = READY;
        idle_cycle();
        run_m(DIV, 32'd1000, 32'd7, c);
        expect_eq(c, 34, "divide after JUMP-on-done runs clean");
        idle_cycle();

        // =================================================================
        $display("=== 11: STALL from Memory during a divide ===");
        // =================================================================
        // Assert Memory's STALL for a stretch in the middle of a divide. The
        // divide must keep iterating underneath it (it is not frozen), and the
        // result must be correct.
        for (int at = 1; at < 33; at += 7) begin
            logic [31:0] exp;
            int total;
            exp = m_ref(DIV, 32'hFFFF_FFF9, 32'd2);   // -7 / 2 = -3
            instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
            rs1_data_in         = 32'hFFFF_FFF9;
            rs2_data_in         = 32'd2;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            total = 0;
            #1;
            for (int w = 0; w < at; w++) begin @(posedge clk); #1; total++; end
            status_backwards_in = STALL;
            for (int w = 0; w < 5; w++) begin @(posedge clk); #1; total++; end
            status_backwards_in = READY;
            #1;
            while (dut_status_backwards_out == STALL) begin
                @(posedge clk); #1; total++;
                if (total > 200) begin $display("HANG mem-stall@%0d", at); errors++; break; end
            end
            @(posedge clk); #1; total++;
            checks++;
            if (dut_rd_data_reg_out !== exp) begin
                $display("FAIL mem-stall@%0d: rd_data=%08h want %08h", at, dut_rd_data_reg_out, exp);
                errors++;
            end
            // 5 cycles of Memory stall on top of a 34-cycle divide must not cost
            // 5 extra divide cycles: the unit kept working through the stall.
            checks++;
            if (total > 34 + 5) begin
                $display("FAIL mem-stall@%0d: took %0d cycles, more than 34+5 — divide was frozen",
                         at, total);
                errors++;
            end
            idle_cycle();
        end

        // =================================================================
        $display("=== 12: Memory STALL outlasting the divide ===");
        // =================================================================
        begin
            logic [31:0] exp;
            exp = m_ref(DIVU, 32'hFFFF_FFFF, 32'd3);
            instruction_in      = make_instr(DIVU, 5'd10, 5'd11, 5'd12);
            rs1_data_in         = 32'hFFFF_FFFF;
            rs2_data_in         = 32'd3;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            #1;
            // Hold STALL for far longer than the divide needs.
            status_backwards_in = STALL;
            for (int w = 0; w < 60; w++) begin @(posedge clk); #1; end
            status_backwards_in = READY;
            #1;
            checks++;
            if (dut_status_backwards_out !== READY) begin
                $display("FAIL long-stall: still stalling after divide should be parked (got %0d)",
                         dut_status_backwards_out);
                errors++;
            end
            if (dut_forwarding_out.data !== exp || !dut_forwarding_out.data_valid) begin
                $display("FAIL long-stall: fwd={dv=%0b,d=%08h} want dv=1 d=%08h",
                         dut_forwarding_out.data_valid, dut_forwarding_out.data, exp);
                errors++;
            end
            @(posedge clk); #1;
            checks++;
            if (dut_rd_data_reg_out !== exp) begin
                $display("FAIL long-stall: rd_data=%08h want %08h", dut_rd_data_reg_out, exp);
                errors++;
            end
            idle_cycle();
        end

        // =================================================================
        $display("=== 13: reset in the middle of a divide ===");
        // =================================================================
        instruction_in      = make_instr(DIV, 5'd10, 5'd11, 5'd12);
        rs1_data_in         = 32'd1000;
        rs2_data_in         = 32'd7;
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        #1;
        for (int w = 0; w < 10; w++) begin @(posedge clk); #1; end
        rst = 1;
        @(posedge clk); #1;
        rst = 0;
        idle_cycle();
        run_m(DIV, 32'd1000, 32'd7, c);
        expect_eq(c, 34, "divide after mid-divide reset runs clean");
        idle_cycle();

        // =================================================================
        $display("");
        $display("========================================");
        $display("  Checks: %0d   Errors: %0d", checks, errors);
        $display("========================================");
        if (errors == 0)
            $display("\033[0;32mAll %0d M-extension checks passed\033[0m", checks);
        else
            $display("\033[0;31m%0d M-extension checks FAILED\033[0m", errors);
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish;
    end
endmodule
