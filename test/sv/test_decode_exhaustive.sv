/* Exhaustive sweep: DUT vs REF for decode_stage.
 * Tests ALL combinations of instruction, forwarding, status signals,
 * across multiple sequential cycles to find any state-dependent disagreements.
 * Checks COMBINATIONAL outputs (before posedge) AND after-posedge outputs. */

module test_decode_exhaustive;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;

    logic clk, rst;
    int total   = 0;
    int errors  = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    /* ------------------------------------------------------------------ */
    /* Shared inputs                                                        */
    /* ------------------------------------------------------------------ */
    logic [31:0]              instruction_in;
    logic [31:0]              program_counter_in;
    forwarding::t             exe_forwarding_in;
    forwarding::t             mem_forwarding_in;
    forwarding::t             wb_forwarding_in;
    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    logic [31:0]              jump_address_backwards_in;

    /* ------------------------------------------------------------------ */
    /* DUT outputs                                                          */
    /* ------------------------------------------------------------------ */
    logic [31:0]              rs1_data_reg_out,    rs2_data_reg_out;
    logic [31:0]              program_counter_reg_out;
    instruction::t            instruction_reg_out;
    pipeline_status::forwards_t  status_forwards_out;
    pipeline_status::backwards_t status_backwards_out;
    logic [31:0]              jump_address_backwards_out;

    /* ------------------------------------------------------------------ */
    /* REF outputs                                                          */
    /* ------------------------------------------------------------------ */
    logic [31:0]              ref_rs1_data_reg_out, ref_rs2_data_reg_out;
    logic [31:0]              ref_program_counter_reg_out;
    instruction::t            ref_instruction_reg_out;
    pipeline_status::forwards_t  ref_status_forwards_out;
    pipeline_status::backwards_t ref_status_backwards_out;
    logic [31:0]              ref_jump_address_backwards_out;

    ref_decode_stage ref_dut (
        .clk(clk), .rst(rst),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .exe_forwarding_in(exe_forwarding_in),
        .mem_forwarding_in(mem_forwarding_in),
        .wb_forwarding_in(wb_forwarding_in),
        .rs1_data_reg_out(ref_rs1_data_reg_out),
        .rs2_data_reg_out(ref_rs2_data_reg_out),
        .program_counter_reg_out(ref_program_counter_reg_out),
        .instruction_reg_out(ref_instruction_reg_out),
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(ref_status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(ref_status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(ref_jump_address_backwards_out)
    );

    decode_stage dut (
        .clk(clk), .rst(rst),
        .instruction_in(instruction_in),
        .program_counter_in(program_counter_in),
        .exe_forwarding_in(exe_forwarding_in),
        .mem_forwarding_in(mem_forwarding_in),
        .wb_forwarding_in(wb_forwarding_in),
        .rs1_data_reg_out(rs1_data_reg_out),
        .rs2_data_reg_out(rs2_data_reg_out),
        .program_counter_reg_out(program_counter_reg_out),
        .instruction_reg_out(instruction_reg_out),
        .status_forwards_in(status_forwards_in),
        .status_forwards_out(status_forwards_out),
        .status_backwards_in(status_backwards_in),
        .status_backwards_out(status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(jump_address_backwards_out)
    );

    /* ------------------------------------------------------------------ */
    /* Instruction encodings                                                */
    /* ------------------------------------------------------------------ */
    // SLT  x1, x2, x3 : rs1=2, rs2=3
    localparam logic [31:0] SLT   = 32'h0031_00B3;
    // SW   x7, 0(x6)  : rs1=6, rs2=7
    localparam logic [31:0] SW    = 32'h0073_2023;
    // ADD  x1, x2, x3 : rs1=2, rs2=3
    localparam logic [31:0] ADD   = 32'h0031_0033;
    // LW   x1, 0(x2)  : rs1=2, rs2=imm (bits[24:20]=0)
    localparam logic [31:0] LW    = 32'h0001_2083;
    // BEQ  x2, x3, 0  : rs1=2, rs2=3
    localparam logic [31:0] BEQ   = 32'h0031_0063;
    // NOP (ADDI x0, x0, 0)
    localparam logic [31:0] NOP   = 32'h0000_0013;
    // AUIPC x1, 0 : no rs1/rs2
    localparam logic [31:0] AUIPC = 32'h0000_0097;

    /* All instructions to test */
    logic [31:0] instrs [7];
    string       inames [7];

    /* JALR  x8, x14, -1930  (imm=0xfffff876 → bits[31:20]=0xf87, rs1=14, rd=8, op=JALR) */
    /* Encoding: imm[11:0]=0x876, rs1=14, funct3=000, rd=8, op=1100111 */
    localparam logic [31:0] JALR_x8_x14 = {12'hf87, 5'd14, 3'b000, 5'd8, 7'b1100111};
    /* LHU   x7,  x16, -1930  (imm=0xfffff876, rs1=16, rd=7, funct3=101, op=0000011) */
    localparam logic [31:0] LHU_x7_x16  = {12'hf87, 5'd16, 3'b101, 5'd7, 7'b0000011};

    /* All interesting forwarding addresses */
    /* (0-7 covers all registers in SLT/SW/ADD/LW/BEQ) */

    /* ------------------------------------------------------------------ */
    /* check helper: compare COMB outputs right after #1                   */
    /* ------------------------------------------------------------------ */
    task check_comb(string tag);
        total++;
        if (status_backwards_out !== ref_status_backwards_out) begin
            $display("COMB FAIL [%s]: sb_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                tag, status_backwards_out, ref_status_backwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address);
            errors++;
        end
        if (status_forwards_out !== ref_status_forwards_out) begin
            $display("COMB FAIL [%s]: sf_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                tag, status_forwards_out, ref_status_forwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address);
            errors++;
        end
    endtask

    task check_reg(string tag);
        total++;
        if (status_forwards_out !== ref_status_forwards_out) begin
            $display("REG  FAIL [%s]: sf_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                tag, status_forwards_out, ref_status_forwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address);
            errors++;
        end
        if (status_backwards_out !== ref_status_backwards_out) begin
            $display("REG  FAIL [%s]: sb_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                tag, status_backwards_out, ref_status_backwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address);
            errors++;
        end
    endtask

    /* Check ALL registered outputs (rs1, rs2, pc, instr, sf_out, sb_out) */
    task check_reg_full(string tag);
        total++;
        if (status_forwards_out !== ref_status_forwards_out) begin
            $display("REG  FAIL [%s]: sf_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d,d=%08h} mem={dv=%0b,a=%0d,d=%08h} wb={dv=%0b,a=%0d,d=%08h}",
                tag, status_forwards_out, ref_status_forwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address, exe_forwarding_in.data,
                mem_forwarding_in.data_valid, mem_forwarding_in.address, mem_forwarding_in.data,
                wb_forwarding_in.data_valid,  wb_forwarding_in.address,  wb_forwarding_in.data);
            errors++;
        end
        if (status_backwards_out !== ref_status_backwards_out) begin
            $display("REG  FAIL [%s]: sb_out dut=%0d ref=%0d  instr=%08h sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                tag, status_backwards_out, ref_status_backwards_out,
                instruction_in, status_forwards_in, status_backwards_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address);
            errors++;
        end
        if (rs1_data_reg_out !== ref_rs1_data_reg_out) begin
            $display("REG  FAIL [%s]: rs1_data dut=%08h ref=%08h  instr=%08h exe={dv=%0b,a=%0d,d=%08h} mem={dv=%0b,a=%0d,d=%08h} wb={dv=%0b,a=%0d,d=%08h}",
                tag, rs1_data_reg_out, ref_rs1_data_reg_out,
                instruction_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address, exe_forwarding_in.data,
                mem_forwarding_in.data_valid, mem_forwarding_in.address, mem_forwarding_in.data,
                wb_forwarding_in.data_valid,  wb_forwarding_in.address,  wb_forwarding_in.data);
            errors++;
        end
        if (rs2_data_reg_out !== ref_rs2_data_reg_out) begin
            $display("REG  FAIL [%s]: rs2_data dut=%08h ref=%08h  instr=%08h exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d} wb={dv=%0b,a=%0d}",
                tag, rs2_data_reg_out, ref_rs2_data_reg_out,
                instruction_in,
                exe_forwarding_in.data_valid, exe_forwarding_in.address,
                mem_forwarding_in.data_valid, mem_forwarding_in.address,
                wb_forwarding_in.data_valid,  wb_forwarding_in.address);
            errors++;
        end
        if (program_counter_reg_out !== ref_program_counter_reg_out) begin
            $display("REG  FAIL [%s]: pc_reg dut=%08h ref=%08h  instr=%08h sf_in=%0d sb_in=%0d",
                tag, program_counter_reg_out, ref_program_counter_reg_out,
                instruction_in, status_forwards_in, status_backwards_in);
            errors++;
        end
    endtask

    /* ------------------------------------------------------------------ */
    /* apply: set inputs, settle, check COMB, clock, check REG             */
    /* ------------------------------------------------------------------ */
    task apply(
        input logic [31:0]   instr,
        input pipeline_status::forwards_t  sf,
        input pipeline_status::backwards_t sb,
        input forwarding::t  exe_fwd,
        input forwarding::t  mem_fwd,
        input forwarding::t  wb_fwd,
        input string         tag
    );
        instruction_in      = instr;
        status_forwards_in  = sf;
        status_backwards_in = sb;
        exe_forwarding_in   = exe_fwd;
        mem_forwarding_in   = mem_fwd;
        wb_forwarding_in    = wb_fwd;
        #1;
        check_comb(tag);
        @(posedge clk); #1;
        check_reg(tag);
    endtask

    /* ------------------------------------------------------------------ */
    /* apply_comb_only: set inputs, settle, check COMB only (no clock)     */
    /* Used to exactly mimic checking between posedges.                    */
    /* ------------------------------------------------------------------ */
    task apply_comb_only(
        input logic [31:0]   instr,
        input pipeline_status::forwards_t  sf,
        input pipeline_status::backwards_t sb,
        input forwarding::t  exe_fwd,
        input forwarding::t  mem_fwd,
        input forwarding::t  wb_fwd,
        input string         tag
    );
        instruction_in      = instr;
        status_forwards_in  = sf;
        status_backwards_in = sb;
        exe_forwarding_in   = exe_fwd;
        mem_forwarding_in   = mem_fwd;
        wb_forwarding_in    = wb_fwd;
        #1;
        check_comb(tag);
    endtask

    /* ------------------------------------------------------------------ */
    /* reset helper                                                         */
    /* ------------------------------------------------------------------ */
    task do_reset();
        rst = 1;
        instruction_in        = NOP;
        program_counter_in    = 32'h4_0000;
        exe_forwarding_in     = '{data_valid:0, data:0, address:0};
        mem_forwarding_in     = '{data_valid:0, data:0, address:0};
        wb_forwarding_in      = '{data_valid:0, data:0, address:0};
        status_forwards_in    = BUBBLE;
        status_backwards_in   = READY;
        jump_address_backwards_in = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
    endtask

    /* ------------------------------------------------------------------ */
    /* MAIN                                                                 */
    /* ------------------------------------------------------------------ */
    initial begin
        $dumpfile("test_decode_exhaustive.fst");
        $dumpvars;

        instrs[0] = SLT;   inames[0] = "SLT";
        instrs[1] = SW;    inames[1] = "SW";
        instrs[2] = ADD;   inames[2] = "ADD";
        instrs[3] = LW;    inames[3] = "LW";
        instrs[4] = BEQ;   inames[4] = "BEQ";
        instrs[5] = NOP;   inames[5] = "NOP";
        instrs[6] = AUIPC; inames[6] = "AUIPC";

        // ================================================================
        // SWEEP 1: All instructions x all exe_forwarding addresses (0-15)
        //   x data_valid (0,1) x status_forwards_in (VALID, BUBBLE)
        //   x status_backwards_in (READY, STALL, JUMP)
        //   -- FRESH RESET before each instruction
        // ================================================================
        $display("=== SWEEP 1: full signal sweep with fresh reset per group ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 15; addr++) begin
                for (int dv = 0; dv <= 1; dv++) begin
                    for (int sf = 0; sf < 4; sf++) begin  // VALID,BUBBLE,FETCH_MISALIGNED,FETCH_FAULT
                        for (int sb = 0; sb < 3; sb++) begin  // READY,STALL,JUMP
                            do_reset();
                            apply(instrs[ii],
                                pipeline_status::forwards_t'(sf),
                                pipeline_status::backwards_t'(sb),
                                '{data_valid:dv[0], data:32'hCAFE, address:addr[4:0]},
                                '{data_valid:0, data:0, address:0},
                                '{data_valid:0, data:0, address:0},
                                $sformatf("%s-sf%0d-sb%0d-exe-dv%0d-a%0d", inames[ii], sf, sb, dv, addr));
                        end
                    end
                end
            end
        end

        // ================================================================
        // SWEEP 2: mem_forwarding hazard (exe has no match)
        // ================================================================
        $display("=== SWEEP 2: mem_forwarding hazard sweep ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 7; addr++) begin
                for (int dv = 0; dv <= 1; dv++) begin
                    do_reset();
                    apply(instrs[ii], VALID, READY,
                        '{data_valid:0, data:0, address:0},  // exe: no match
                        '{data_valid:dv[0], data:32'hBEEF, address:addr[4:0]},
                        '{data_valid:0, data:0, address:0},
                        $sformatf("%s-mem-dv%0d-a%0d", inames[ii], dv, addr));
                end
            end
        end

        // ================================================================
        // SWEEP 3: STALL → READY transition while hazard active
        //          Exactly what tests 3&4 on Persephone seem to test
        // ================================================================
        $display("=== SWEEP 3: STALL->READY transition with hazard (exe) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 7; addr++) begin
                // Setup: STALL cycle with hazard
                do_reset();
                // Cycle A: apply hazard with STALL
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = STALL;
                exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:addr[4:0]};
                mem_forwarding_in   = '{data_valid:0, data:0, address:0};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                @(posedge clk); #1;  // fire STALL cycle

                // Cycle B: now READY, hazard still active (exe still not valid)
                apply(instrs[ii], VALID, READY,
                    '{data_valid:0, data:32'hDEAD, address:addr[4:0]},
                    '{data_valid:0, data:0, address:0},
                    '{data_valid:0, data:0, address:0},
                    $sformatf("%s-STALL-READY-exe-dv0-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 4: STALL → READY transition with mem hazard
        // ================================================================
        $display("=== SWEEP 4: STALL->READY transition with mem hazard ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 7; addr++) begin
                do_reset();
                // Cycle A: STALL with mem hazard
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = STALL;
                exe_forwarding_in   = '{data_valid:0, data:0, address:0};
                mem_forwarding_in   = '{data_valid:0, data:32'hBEEF, address:addr[4:0]};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                @(posedge clk); #1;

                // Cycle B: READY
                apply(instrs[ii], VALID, READY,
                    '{data_valid:0, data:0, address:0},
                    '{data_valid:0, data:32'hBEEF, address:addr[4:0]},
                    '{data_valid:0, data:0, address:0},
                    $sformatf("%s-STALL-READY-mem-dv0-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 5: JUMP → READY transition while hazard active
        // ================================================================
        $display("=== SWEEP 5: JUMP->READY transition with hazard ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 7; addr++) begin
                do_reset();
                // Cycle A: JUMP
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = JUMP;
                exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:addr[4:0]};
                mem_forwarding_in   = '{data_valid:0, data:0, address:0};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                @(posedge clk); #1;

                // Cycle B: READY, hazard still active
                apply(instrs[ii], VALID, READY,
                    '{data_valid:0, data:32'hDEAD, address:addr[4:0]},
                    '{data_valid:0, data:0, address:0},
                    '{data_valid:0, data:0, address:0},
                    $sformatf("%s-JUMP-READY-exe-dv0-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 6: Two-cycle STALL then READY — deeper state check
        // ================================================================
        $display("=== SWEEP 6: 2x STALL -> READY transition ===");
        for (int ii = 0; ii < 3; ii++) begin  // SLT, SW, ADD
            for (int addr = 1; addr <= 7; addr++) begin
                do_reset();
                // Cycle A: STALL
                instruction_in = instrs[ii]; status_forwards_in = VALID;
                status_backwards_in = STALL;
                exe_forwarding_in = '{data_valid:0, data:0, address:addr[4:0]};
                mem_forwarding_in = '{data_valid:0, data:0, address:0};
                wb_forwarding_in  = '{data_valid:0, data:0, address:0};
                @(posedge clk); #1;

                // Cycle B: still STALL
                @(posedge clk); #1;

                // Cycle C: READY, hazard still active
                apply(instrs[ii], VALID, READY,
                    '{data_valid:0, data:0, address:addr[4:0]},
                    '{data_valid:0, data:0, address:0},
                    '{data_valid:0, data:0, address:0},
                    $sformatf("%s-2xSTALL-READY-exe-dv0-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 7: Immediate check (comb only, no clock advance)
        //   Check combinational outputs IMMEDIATELY after input change
        // ================================================================
        $display("=== SWEEP 7: pure combinational check (no posedge, just #1 settle) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 0; addr <= 7; addr++) begin
                for (int dv = 0; dv <= 1; dv++) begin
                    do_reset();
                    apply_comb_only(instrs[ii], VALID, READY,
                        '{data_valid:dv[0], data:32'hABCD, address:addr[4:0]},
                        '{data_valid:0, data:0, address:0},
                        '{data_valid:0, data:0, address:0},
                        $sformatf("%s-COMB-exe-dv%0d-a%0d", inames[ii], dv, addr));
                end
            end
        end

        // ================================================================
        // SWEEP 8: Sequential — check BEFORE and AFTER posedge for SAME inputs
        //   Persephone might check at posedge boundary
        // ================================================================
        $display("=== SWEEP 8: check at posedge boundary ===");
        for (int ii = 0; ii < 3; ii++) begin
            for (int addr = 1; addr <= 4; addr++) begin
                do_reset();
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = READY;
                exe_forwarding_in   = '{data_valid:0, data:0, address:addr[4:0]};
                mem_forwarding_in   = '{data_valid:0, data:0, address:0};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};

                // Check immediately (delta settle only)
                #1;
                check_comb($sformatf("%s-presedge-exe-dv0-a%0d", inames[ii], addr));

                // Check at posedge
                @(posedge clk);
                #1;
                check_reg($sformatf("%s-atsedge-exe-dv0-a%0d", inames[ii], addr));

                // Check after posedge settle
                @(posedge clk); #1;
                check_reg($sformatf("%s-postsedge-exe-dv0-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 9: Multi-stage forwarding — same addr, only newest valid
        //   Persephone: "forward newest result (more stages same rd - only newest valid)"
        //   exe.dv=1 (newest, valid) + mem.dv=0 (older, invalid) + wb.dv=1/0
        //   for same register — check rs1_data, rs2_data, sf_out, sb_out
        // ================================================================
        $display("=== SWEEP 9: multi-stage same-addr forwarding (exe.dv=1, mem.dv=0) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 1; addr <= 7; addr++) begin
                // Sub-case A: exe=valid, mem=invalid, wb=valid (all same addr)
                do_reset();
                program_counter_in = 32'h4_0014;
                apply(instrs[ii], VALID, READY,
                    '{data_valid:1, data:32'h1111_1111, address:addr[4:0]},
                    '{data_valid:0, data:32'h5555_5555, address:addr[4:0]},
                    '{data_valid:1, data:32'h8888_8888, address:addr[4:0]},
                    $sformatf("%s-multi-exe1mem0wb1-a%0d", inames[ii], addr));
                // check full registered outputs
                check_reg_full($sformatf("%s-multi-exe1mem0wb1-a%0d-full", inames[ii], addr));

                // Sub-case B: exe=valid, mem=invalid, wb=invalid
                do_reset();
                program_counter_in = 32'h4_0014;
                apply(instrs[ii], VALID, READY,
                    '{data_valid:1, data:32'h1111_1111, address:addr[4:0]},
                    '{data_valid:0, data:32'h5555_5555, address:addr[4:0]},
                    '{data_valid:0, data:32'h8888_8888, address:addr[4:0]},
                    $sformatf("%s-multi-exe1mem0wb0-a%0d", inames[ii], addr));
                check_reg_full($sformatf("%s-multi-exe1mem0wb0-a%0d-full", inames[ii], addr));

                // Sub-case C: exe=invalid, mem=invalid (hazard expected)
                do_reset();
                program_counter_in = 32'h4_0014;
                apply(instrs[ii], VALID, READY,
                    '{data_valid:0, data:32'h1111_1111, address:addr[4:0]},
                    '{data_valid:0, data:32'h5555_5555, address:addr[4:0]},
                    '{data_valid:1, data:32'h8888_8888, address:addr[4:0]},
                    $sformatf("%s-multi-exe0mem0wb1-a%0d", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 10: STALL → READY where load moved from EXE to MEM
        //   Cycle A: sb=STALL, exe={dv=0,addr=X} — load in Execute, caused stall
        //   Cycle B: sb=READY, exe={dv=1,addr=X} (new valid result) + mem={dv=0,addr=X}
        //   This is Persephone's "STALL→READY with forwarding.data_valid=0" scenario
        // ================================================================
        $display("=== SWEEP 10: STALL->READY exe0->exe1+mem0 (load moved to mem) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 1; addr <= 7; addr++) begin
                do_reset();
                // Cycle A: STALL cycle, exe has dv=0 (load causing hazard)
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = STALL;
                exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:addr[4:0]};
                mem_forwarding_in   = '{data_valid:0, data:0, address:0};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                program_counter_in  = 32'h4_0014;
                @(posedge clk); #1;

                // Cycle B: sb=READY, load moved to Memory (mem.dv=0), new exe has dv=1
                instruction_in      = instrs[ii];
                status_forwards_in  = VALID;
                status_backwards_in = READY;
                exe_forwarding_in   = '{data_valid:1, data:32'h1111_1111, address:addr[4:0]};
                mem_forwarding_in   = '{data_valid:0, data:32'hDEAD,      address:addr[4:0]};
                wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                program_counter_in  = 32'h4_0014;
                #1;
                check_comb($sformatf("%s-STALL-READY-exe0to1-mem0-a%0d", inames[ii], addr));
                @(posedge clk); #1;
                check_reg_full($sformatf("%s-STALL-READY-exe0to1-mem0-a%0d-reg", inames[ii], addr));
            end
        end

        // ================================================================
        // SWEEP 11: Persephone JALR/LHU exact scenario
        //   Run a sequence of instructions at increasing PCs with
        //   multi-stage forwarding, verify registered outputs exactly.
        // ================================================================
        $display("=== SWEEP 11: Persephone JALR/LHU forwarding sequence ===");
        begin
            // Simulate: multiple instructions writing to same register (x14 for JALR)
            do_reset();
            program_counter_in = 32'h4_0010;

            // Cycle 1: "previous instruction" at pc=0x40010, sf=VALID, sb=READY
            // Drives some state into registers
            instruction_in      = ADD;  // ADD x1, x2, x3 as "previous"
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:0, data:0, address:0};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
            @(posedge clk); #1;

            // Cycle 2: JALR at pc=0x40014, exe.dv=1 for rs1(x14), mem.dv=0 for rs1(x14)
            // Expected: no stall, use exe data (0x11111111) for rs1
            program_counter_in  = 32'h4_0014;
            instruction_in      = JALR_x8_x14;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:1, data:32'h1111_1111, address:5'd14};
            mem_forwarding_in   = '{data_valid:0, data:32'h8888_8888, address:5'd14};
            wb_forwarding_in    = '{data_valid:1, data:32'h9999_9999, address:5'd14};
            #1;
            check_comb("JALR-multi-fwd-comb");
            @(posedge clk); #1;
            check_reg_full("JALR-multi-fwd-reg");
        end

        begin
            // LHU x7, rs1=x16 scenario
            do_reset();
            program_counter_in = 32'h4_0018;

            instruction_in      = NOP;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:0, data:0, address:0};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
            @(posedge clk); #1;

            // LHU at pc=0x4001c, exe.dv=1 for rs1(x16), mem.dv=0 for rs1(x16)
            program_counter_in  = 32'h4_001c;
            instruction_in      = LHU_x7_x16;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:1, data:32'h3333_3333, address:5'd16};
            mem_forwarding_in   = '{data_valid:0, data:32'h2222_2222, address:5'd16};
            wb_forwarding_in    = '{data_valid:1, data:32'haaaa_aaaa, address:5'd16};
            #1;
            check_comb("LHU-multi-fwd-comb");
            @(posedge clk); #1;
            check_reg_full("LHU-multi-fwd-reg");
        end

        // ================================================================
        // SWEEP 12: All combinations exe.dv × mem.dv × wb.dv for same addr
        //   Exhaustively tests multi-stage forwarding interactions
        // ================================================================
        $display("=== SWEEP 12: all dv combinations, same addr (exe/mem/wb) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int addr = 1; addr <= 7; addr++) begin
                for (int edv = 0; edv <= 1; edv++) begin
                    for (int mdv = 0; mdv <= 1; mdv++) begin
                        for (int wdv = 0; wdv <= 1; wdv++) begin
                            do_reset();
                            program_counter_in = 32'h4_0020;
                            instruction_in      = instrs[ii];
                            status_forwards_in  = VALID;
                            status_backwards_in = READY;
                            exe_forwarding_in   = '{data_valid:edv[0], data:32'h1111_0000 | addr, address:addr[4:0]};
                            mem_forwarding_in   = '{data_valid:mdv[0], data:32'h2222_0000 | addr, address:addr[4:0]};
                            wb_forwarding_in    = '{data_valid:wdv[0], data:32'h3333_0000 | addr, address:addr[4:0]};
                            #1;
                            check_comb($sformatf("%s-allstage-e%0d-m%0d-w%0d-a%0d",
                                inames[ii], edv, mdv, wdv, addr));
                            @(posedge clk); #1;
                            check_reg_full($sformatf("%s-allstage-e%0d-m%0d-w%0d-a%0d-reg",
                                inames[ii], edv, mdv, wdv, addr));
                        end
                    end
                end
            end
        end

        // ================================================================
        // SWEEP 13: Mixed independent exe.addr × mem.addr combinations
        //   exe and mem point to DIFFERENT registers simultaneously.
        //   Covers "real pipeline" scenarios: different stages hold
        //   results for different registers.
        //   Also tests sequential state (NO do_reset between sub-tests).
        // ================================================================
        $display("=== SWEEP 13: mixed independent exe × mem addr (cross-register) ===");
        for (int ii = 0; ii < 7; ii++) begin
            for (int ea = 0; ea <= 7; ea++) begin     // exe addr
                for (int edv = 0; edv <= 1; edv++) begin // exe dv
                    for (int ma = 0; ma <= 7; ma++) begin  // mem addr (different from exe typically)
                        for (int mdv = 0; mdv <= 1; mdv++) begin // mem dv
                            do_reset();
                            program_counter_in  = 32'h4_0030;
                            instruction_in      = instrs[ii];
                            status_forwards_in  = VALID;
                            status_backwards_in = READY;
                            exe_forwarding_in   = '{data_valid:edv[0], data:32'hAAAA_0000 | ea, address:ea[4:0]};
                            mem_forwarding_in   = '{data_valid:mdv[0], data:32'hBBBB_0000 | ma, address:ma[4:0]};
                            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
                            #1;
                            check_comb($sformatf("%s-mix-ea%0d-edv%0d-ma%0d-mdv%0d",
                                inames[ii], ea, edv, ma, mdv));
                            @(posedge clk); #1;
                            check_reg_full($sformatf("%s-mix-ea%0d-edv%0d-ma%0d-mdv%0d-reg",
                                inames[ii], ea, edv, ma, mdv));
                        end
                    end
                end
            end
        end

        // ================================================================
        // SWEEP 14: Sequential test (NO do_reset) — state-dependent checks
        //   Runs several instructions without reset to check that internal
        //   state (sf_out_reg) evolves correctly across cycles matching ref.
        // ================================================================
        $display("=== SWEEP 14: sequential no-reset state evolution ===");
        begin
            do_reset();
            // Sub-test A: normal instruction → sf_out_reg should become VALID
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                "seq-A-normal-SLT");

            // Sub-test B: immediately SW with exe hazard (no reset, state carries)
            apply(SW, VALID, READY,
                '{data_valid:0, data:32'hDEAD, address:5'd6},  // rs1=x6 of SW
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                "seq-B-SW-exe-hazard-a6");

            // Sub-test C: SW again with mem hazard (no reset)
            apply(SW, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hBEEF, address:5'd6},  // rs1=x6 of SW
                '{data_valid:0, data:0, address:0},
                "seq-C-SW-mem-hazard-a6");

            // Sub-test D: SLT with exe hazard (rs1=x2)
            apply(SLT, VALID, READY,
                '{data_valid:0, data:32'hDEAD, address:5'd2},  // rs1=x2 of SLT
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                "seq-D-SLT-exe-hazard-rs1");

            // Sub-test E: SLT with rs2 exe hazard
            apply(SLT, VALID, READY,
                '{data_valid:0, data:32'hDEAD, address:5'd3},  // rs2=x3 of SLT
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                "seq-E-SLT-exe-hazard-rs2");

            // Sub-test F: STALL then READY — exact Persephone scenario
            // Step 1: sb_in=STALL while exe has hazard
            instruction_in      = SLT;
            status_forwards_in  = VALID;
            status_backwards_in = STALL;
            exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:5'd2};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
            @(posedge clk); #1;
            // Step 2: READY, exe.dv=0 still (same addr)
            apply(SLT, VALID, READY,
                '{data_valid:0, data:32'hDEAD, address:5'd2},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                "seq-F-SLT-STALL-READY-exe-dv0");

            // Sub-test G: sb_in=STALL then READY — exe.dv transitions 0→1, mem has hazard
            // Step 1: sb_in=READY with exe.dv=0 → we detect hazard ourselves
            instruction_in      = SLT;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:5'd2};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
            @(posedge clk); #1;
            // Step 2: READY, load moved to mem (exe.dv=0 but addr=0 now, mem has old load)
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:5'd0},  // NOP/BUBBLE in Execute
                '{data_valid:0, data:32'hDEAD, address:5'd2},  // load in Memory
                '{data_valid:0, data:0, address:0},
                "seq-G-SLT-self-stall-then-mem-hazard");

            // Sub-test H: same but exe now has dv=1 for same addr
            // Step 1: sb=READY, exe.dv=0 → self-stall
            instruction_in      = SLT;
            status_forwards_in  = VALID;
            status_backwards_in = READY;
            exe_forwarding_in   = '{data_valid:0, data:32'hDEAD, address:5'd2};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:0, address:0};
            @(posedge clk); #1;
            // Step 2: READY, exe now valid for same addr, mem has old load invalid
            apply(SLT, VALID, READY,
                '{data_valid:1, data:32'h1111, address:5'd2},  // exe completed, dv=1
                '{data_valid:0, data:32'hDEAD, address:5'd2},  // load in Memory, dv=0
                '{data_valid:0, data:0, address:0},
                "seq-H-SLT-self-stall-then-exe1-mem0");

            // Sub-test I: SW rs1=x6 hazard with exe for rs2 (x7) valid
            // exe has x7 (rs2 of SW) valid, mem has x6 (rs1 of SW) invalid
            apply(SW, VALID, READY,
                '{data_valid:1, data:32'hABCD, address:5'd7},  // rs2=x7 exe valid
                '{data_valid:0, data:32'hBEEF, address:5'd6},  // rs1=x6 mem invalid
                '{data_valid:0, data:0, address:0},
                "seq-I-SW-exe-rs2-valid-mem-rs1-invalid");

            // Sub-test J: SW rs2=x7 hazard with exe for rs1 (x6) valid
            apply(SW, VALID, READY,
                '{data_valid:1, data:32'hABCD, address:5'd6},  // rs1=x6 exe valid
                '{data_valid:0, data:32'hBEEF, address:5'd7},  // rs2=x7 mem invalid
                '{data_valid:0, data:0, address:0},
                "seq-J-SW-exe-rs1-valid-mem-rs2-invalid");
        end

        // ================================================================
        // SWEEP 15: WB forwarding hazard (wb.dv=0, addr matches rs1/rs2)
        //   Tests whether the reference stalls when wb_forwarding_in has
        //   data_valid=0 and address matches a source register.
        // ================================================================
        $display("=== SWEEP 15: wb forwarding hazard (wb.dv=0) ===");
        begin
            // 15a: SLT rs1=x2, wb.addr=2, wb.dv=0, exe/mem no match
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd2},  // wb.addr=2=rs1, dv=0
                "wb-hazard-SLT-rs1");

            // 15b: SLT rs2=x3, wb.addr=3, wb.dv=0
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd3},  // wb.addr=3=rs2, dv=0
                "wb-hazard-SLT-rs2");

            // 15c: SW rs1=x6, wb.addr=6, wb.dv=0
            do_reset();
            apply(SW, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd6},  // wb.addr=6=rs1, dv=0
                "wb-hazard-SW-rs1");

            // 15d: SW rs2=x7, wb.addr=7, wb.dv=0
            do_reset();
            apply(SW, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd7},  // wb.addr=7=rs2, dv=0
                "wb-hazard-SW-rs2");

            // 15e: wb.dv=1 should NOT stall
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:1, data:32'hCCCC_0000, address:5'd2},  // wb.addr=2=rs1, dv=1
                "wb-no-hazard-SLT-dv1");

            // 15f: wb.addr=0 should NOT stall
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd0},  // wb.addr=0 (x0)
                "wb-no-hazard-SLT-addr0");

            // 15g: exe overrides wb (exe.addr=rs1, exe.dv=1)
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:1, data:32'hAAAA_0000, address:5'd2},  // exe.addr=2=rs1, dv=1
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd2},   // wb.addr=2=rs1, dv=0
                "wb-hazard-exe-override");

            // 15h: mem overrides wb (mem.addr=rs1, mem.dv=1)
            do_reset();
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:1, data:32'hBBBB_0000, address:5'd2},  // mem.addr=2=rs1, dv=1
                '{data_valid:0, data:32'hCCCC_0000, address:5'd2},   // wb.addr=2=rs1, dv=0
                "wb-hazard-mem-override");

            // 15i: STALL→READY with wb.dv=0 (Persephone scenario 3/4)
            do_reset();
            // Step 1: STALL cycle
            instruction_in      = SLT;
            status_forwards_in  = VALID;
            status_backwards_in = STALL;
            exe_forwarding_in   = '{data_valid:0, data:0, address:0};
            mem_forwarding_in   = '{data_valid:0, data:0, address:0};
            wb_forwarding_in    = '{data_valid:0, data:32'hCCCC_0000, address:5'd2};
            @(posedge clk); #1;
            // Step 2: READY — wb still dv=0
            apply(SLT, VALID, READY,
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:32'hCCCC_0000, address:5'd2},
                "wb-hazard-STALL-READY-SLT");
        end

        // ================================================================
        // Done
        // ================================================================
        if (errors == 0)
            $display("\033[0;32mAll %0d checks PASSED — dut matches ref!\033[0m", total);
        else
            $display("\033[0;31m%0d/%0d checks FAILED\033[0m", errors, total);
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish();
    end
endmodule
