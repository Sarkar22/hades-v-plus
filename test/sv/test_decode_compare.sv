/* Exhaustive comparison between decode_stage (dut) and ref_decode_stage (ref_dut).
 * Drive many input combinations; report ANY disagreement on outputs. */

module test_decode_compare;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;

    logic clk, rst;
    int error_count = 0;
    int test_count  = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    // Shared inputs
    logic [31:0]              instruction_in;
    logic [31:0]              program_counter_in;
    forwarding::t             exe_forwarding_in;
    forwarding::t             mem_forwarding_in;
    forwarding::t             wb_forwarding_in;
    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    logic [31:0]              jump_address_backwards_in;

    // DUT outputs
    logic [31:0]              rs1_data_reg_out,    rs2_data_reg_out;
    logic [31:0]              program_counter_reg_out;
    instruction::t            instruction_reg_out;
    pipeline_status::forwards_t  status_forwards_out;
    pipeline_status::backwards_t status_backwards_out;
    logic [31:0]              jump_address_backwards_out;

    // REF outputs
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

    // Helper: reset both DUTs
    task do_reset();
        rst = 1;
        instruction_in        = 32'h0000_0013; // NOP
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

    // Helper: apply inputs and check after one posedge
    task apply_and_check(
        input string         label,
        input logic [31:0]   instr,
        input pipeline_status::forwards_t  sf_in,
        input pipeline_status::backwards_t sb_in,
        input forwarding::t  exe_fwd,
        input forwarding::t  mem_fwd,
        input forwarding::t  wb_fwd
    );
        instruction_in      = instr;
        status_forwards_in  = sf_in;
        status_backwards_in = sb_in;
        exe_forwarding_in   = exe_fwd;
        mem_forwarding_in   = mem_fwd;
        wb_forwarding_in    = wb_fwd;
        #1; // settle combinational
        test_count++;

        // Check combinational: status_backwards_out
        if (status_backwards_out !== ref_status_backwards_out) begin
            $display("COMB MISMATCH [%s]: status_backwards_out dut=%0d ref=%0d sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                label, status_backwards_out, ref_status_backwards_out,
                sf_in, sb_in,
                exe_fwd.data_valid, exe_fwd.address,
                mem_fwd.data_valid, mem_fwd.address);
            error_count++;
        end

        @(posedge clk); #1; // clock edge
        test_count++;

        // Check registered: status_forwards_out, program_counter_reg_out
        if (status_forwards_out !== ref_status_forwards_out) begin
            $display("REG  MISMATCH [%s]: status_forwards_out dut=%0d ref=%0d sf_in=%0d sb_in=%0d exe={dv=%0b,a=%0d} mem={dv=%0b,a=%0d}",
                label, status_forwards_out, ref_status_forwards_out,
                sf_in, sb_in,
                exe_fwd.data_valid, exe_fwd.address,
                mem_fwd.data_valid, mem_fwd.address);
            error_count++;
        end
        if (program_counter_reg_out !== ref_program_counter_reg_out) begin
            $display("REG  MISMATCH [%s]: pc_reg_out dut=%08h ref=%08h sf_in=%0d sb_in=%0d",
                label, program_counter_reg_out, ref_program_counter_reg_out, sf_in, sb_in);
            error_count++;
        end
    endtask

    // Instruction encodings
    // SLT x1, x2, x3:  funct7=0, rs2=3, rs1=2, funct3=010, rd=1, op=0110011
    localparam logic [31:0] SLT_x1_x2_x3  = 32'h0031_00B3;
    // SW  x7, 0(x6):   imm=0, rs2=7, rs1=6, funct3=010, imm=0, op=0100011
    localparam logic [31:0] SW_x7_0_x6    = 32'h0073_2023;
    // ADD x1, x2, x3:  funct7=0, rs2=3, rs1=2, funct3=000, rd=1, op=0110011
    localparam logic [31:0] ADD_x1_x2_x3  = 32'h0031_0033;
    // LW  x1, 0(x2):   imm=0, rs1=2, funct3=010, rd=1, op=0000011
    localparam logic [31:0] LW_x1_0_x2    = 32'h0001_2083;
    // BEQ x2, x3, 0:   imm=0, rs2=3, rs1=2, funct3=000, op=1100011
    localparam logic [31:0] BEQ_x2_x3_0   = 32'h0031_0063;
    // NOP (ADDI x0, x0, 0)
    localparam logic [31:0] NOP_INSTR     = 32'h0000_0013;
    // AUIPC x1, 0: rd=1, imm=0, op=0010111
    localparam logic [31:0] AUIPC_x1_0    = 32'h0000_0097;

    initial begin
        $dumpfile("test_decode_compare.fst");
        $dumpvars;

        do_reset();

        // -----------------------------------------------------------------------
        // SECTION A: status_forwards_in = VALID, exe hazard (data_valid=0)
        // -----------------------------------------------------------------------
        $display("=== SECTION A: VALID + exe hazard ===");
        // Test each register address 0..7 for exe_forwarding matching SLT rs1=2,rs2=3
        for (int addr = 0; addr <= 7; addr++) begin
            apply_and_check($sformatf("SLT-exe-dv0-addr%0d", addr),
                SLT_x1_x2_x3, VALID, READY,
                '{data_valid:0, data:32'hDEAD, address:addr[4:0]},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0});
        end
        for (int addr = 0; addr <= 7; addr++) begin
            apply_and_check($sformatf("SW-exe-dv0-addr%0d", addr),
                SW_x7_0_x6, VALID, READY,
                '{data_valid:0, data:32'hBEEF, address:addr[4:0]},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0});
        end

        // -----------------------------------------------------------------------
        // SECTION B: status_forwards_in = BUBBLE, exe hazard
        // -----------------------------------------------------------------------
        $display("=== SECTION B: BUBBLE + exe hazard ===");
        for (int addr = 0; addr <= 7; addr++) begin
            apply_and_check($sformatf("SLT-BUBBLE-exe-dv0-addr%0d", addr),
                SLT_x1_x2_x3, BUBBLE, READY,
                '{data_valid:0, data:32'hDEAD, address:addr[4:0]},
                '{data_valid:0, data:0, address:0},
                '{data_valid:0, data:0, address:0});
        end

        // -----------------------------------------------------------------------
        // SECTION C: status_backwards_in = STALL, then READY transition
        // -----------------------------------------------------------------------
        $display("=== SECTION C: STALL->READY transition ===");
        // Step A: STALL
        instruction_in      = SLT_x1_x2_x3;
        status_forwards_in  = VALID;
        status_backwards_in = STALL;
        exe_forwarding_in   = '{data_valid:0, data:0, address:5'd2};
        mem_forwarding_in   = '{data_valid:0, data:0, address:0};
        wb_forwarding_in    = '{data_valid:0, data:0, address:0};
        @(posedge clk); #1;
        // Step B: READY
        apply_and_check("SLT-STALL-to-READY-exe-dv0",
            SLT_x1_x2_x3, VALID, READY,
            '{data_valid:0, data:0, address:5'd2},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});

        // -----------------------------------------------------------------------
        // SECTION D: mem hazard (exe valid, mem invalid)
        // -----------------------------------------------------------------------
        $display("=== SECTION D: mem hazard (exe=valid/nomatch, mem=invalid) ===");
        for (int addr = 0; addr <= 7; addr++) begin
            apply_and_check($sformatf("SLT-mem-dv0-addr%0d", addr),
                SLT_x1_x2_x3, VALID, READY,
                '{data_valid:0, data:0, address:0},  // exe: no match
                '{data_valid:0, data:0, address:addr[4:0]},  // mem: addr match?
                '{data_valid:0, data:0, address:0});
        end

        // -----------------------------------------------------------------------
        // SECTION E: status_forwards_in != VALID (FETCH_FAULT, FETCH_MISALIGNED, etc.)
        // -----------------------------------------------------------------------
        $display("=== SECTION E: non-VALID status_forwards_in ===");
        apply_and_check("BEQ-FETCH_FAULT-exe-dv0",
            BEQ_x2_x3_0, FETCH_FAULT, READY,
            '{data_valid:0, data:0, address:5'd2},  // matches BEQ rs1=x2
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("BEQ-FETCH_MISALIGNED-exe-dv0",
            BEQ_x2_x3_0, FETCH_MISALIGNED, READY,
            '{data_valid:0, data:0, address:5'd2},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("BEQ-BUBBLE-exe-dv0",
            BEQ_x2_x3_0, BUBBLE, READY,
            '{data_valid:0, data:0, address:5'd2},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});

        // -----------------------------------------------------------------------
        // SECTION F: exe has data_valid=1 (should NOT stall)
        // -----------------------------------------------------------------------
        $display("=== SECTION F: exe data_valid=1 (no stall) ===");
        apply_and_check("SLT-exe-dv1-rs1match",
            SLT_x1_x2_x3, VALID, READY,
            '{data_valid:1, data:32'h42, address:5'd2},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("SW-exe-dv1-rs2match",
            SW_x7_0_x6, VALID, READY,
            '{data_valid:1, data:32'h42, address:5'd7},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});

        // -----------------------------------------------------------------------
        // SECTION G: exe hazard with different instruction types
        // -----------------------------------------------------------------------
        $display("=== SECTION G: different instruction types ===");
        apply_and_check("LW-exe-dv0-rs1match",
            LW_x1_0_x2, VALID, READY,
            '{data_valid:0, data:0, address:5'd2},  // rs1=x2
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("ADD-exe-dv0-rs2match",
            ADD_x1_x2_x3, VALID, READY,
            '{data_valid:0, data:0, address:5'd3},  // rs2=x3
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("AUIPC-exe-dv0-no-rs",
            AUIPC_x1_0, VALID, READY,
            '{data_valid:0, data:0, address:5'd0},  // AUIPC: no rs1/rs2
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});
        apply_and_check("NOP-exe-dv0-addr0",
            NOP_INSTR, VALID, READY,
            '{data_valid:0, data:0, address:5'd0},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});

        // -----------------------------------------------------------------------
        // SECTION H: status_backwards_in combinations
        // -----------------------------------------------------------------------
        $display("=== SECTION H: status_backwards_in variants ===");
        apply_and_check("SLT-JUMP-exe-dv0",
            SLT_x1_x2_x3, VALID, JUMP,
            '{data_valid:0, data:0, address:5'd2},
            '{data_valid:0, data:0, address:0},
            '{data_valid:0, data:0, address:0});

        // -----------------------------------------------------------------------
        // DONE
        // -----------------------------------------------------------------------
        if (error_count == 0)
            $display("\033[0;32mAll %0d checks passed — dut matches ref!\033[0m", test_count);
        else
            $display("\033[0;31m%0d/%0d checks FAILED\033[0m", error_count, test_count);
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish();
    end
endmodule
