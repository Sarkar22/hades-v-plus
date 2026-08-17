/* Local testbench to reproduce FORWARDING NOT VALID => insert BUBBLE failures */

module test_decode_hazard;
    import clk_params::*;
    import pipeline_status::*;
    import forwarding::*;

    logic clk, rst;
    int error_count = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    // DUT ports
    logic [31:0]         instruction_in;
    logic [31:0]         program_counter_in;
    forwarding::t        exe_forwarding_in;
    forwarding::t        mem_forwarding_in;
    forwarding::t        wb_forwarding_in;
    logic [31:0]         rs1_data_reg_out;
    logic [31:0]         rs2_data_reg_out;
    logic [31:0]         program_counter_reg_out;
    instruction::t       instruction_reg_out;
    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::forwards_t  status_forwards_out;
    pipeline_status::backwards_t status_backwards_in;
    pipeline_status::backwards_t status_backwards_out;
    logic [31:0]         jump_address_backwards_in;
    logic [31:0]         jump_address_backwards_out;

    // Reference implementation for comparison
    pipeline_status::backwards_t ref_status_backwards_out;
    pipeline_status::forwards_t  ref_status_forwards_out;
    logic [31:0] ref_rs1_data_reg_out, ref_rs2_data_reg_out;
    logic [31:0] ref_jump_address_backwards_out;
    instruction::t ref_instruction_reg_out;
    logic [31:0] ref_program_counter_reg_out;

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

    // -----------------------------------------------------------------------
    // Helper: clear all forwarding inputs (no forwarding active)
    task clear_forwarding();
        exe_forwarding_in = '{data_valid: 0, data: 0, address: 0};
        mem_forwarding_in = '{data_valid: 0, data: 0, address: 0};
        wb_forwarding_in  = '{data_valid: 0, data: 0, address: 0};
    endtask

    task reset_dut();
        @(negedge clk); #1;
        rst = 1;
        instruction_in          = 32'h0000_0013; // NOP (addi x0, x0, 0)
        program_counter_in      = 32'h4_0000;
        clear_forwarding();
        status_forwards_in      = BUBBLE;
        status_backwards_in     = READY;
        jump_address_backwards_in = 32'b0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
    endtask

    task check(string msg, int exp_sb, int exp_sf);
        if (int'(status_backwards_out) !== exp_sb) begin
            $display("FAIL [%s]: status_backwards_out = %0d (exp %0d)", msg, status_backwards_out, exp_sb);
            error_count++;
        end
        if (int'(status_forwards_out) !== exp_sf) begin
            $display("FAIL [%s]: status_forwards_out  = %0d (exp %0d)", msg, status_forwards_out, exp_sf);
            error_count++;
        end
        if (int'(status_backwards_out) === exp_sb && int'(status_forwards_out) === exp_sf)
            $display("PASS [%s]", msg);
    endtask

    initial begin
        $dumpfile("test_decode_hazard.fst");
        $dumpvars;

        reset_dut();

        // ===================================================================
        // TEST 1: SLT x1, x2, x3 — exe_forwarding.data_valid=0 for rs1 (x2)
        // ===================================================================
        // SLT x1, x2, x3: funct7=0000000, rs2=x3(3), rs1=x2(2), funct3=010, rd=x1(1), op=0110011
        // encoding: 0000000_00011_00010_010_00001_0110011 = 0x003100B3
        $display("--- TEST 1: SLT load-use hazard via exe_forwarding (rs1 match) ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        // exe has data_valid=0 for x2 (rs1 of SLT) — load-use hazard
        exe_forwarding_in   = '{data_valid: 0, data: 32'hDEAD, address: 5'd2};
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SLT exe-rs1 hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // ===================================================================
        // TEST 2: SLT — exe_forwarding.data_valid=0 for rs2 (x3)
        // ===================================================================
        $display("--- TEST 2: SLT load-use hazard via exe_forwarding (rs2 match) ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 0, data: 32'hBEEF, address: 5'd3}; // x3 = rs2
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SLT exe-rs2 hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // ===================================================================
        // TEST 3: SW x7, 0(x6) — exe_forwarding.data_valid=0 for x6 (rs1)
        // ===================================================================
        // SW x7, 0(x6): opcode=0100011, funct3=010, rs1=x6(6), rs2=x7(7), imm=0
        // encoding: 0000000_00111_00110_010_00000_0100011 = 0x0073_2023
        $display("--- TEST 3: SW load-use hazard via exe_forwarding (rs1 match) ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0073_2023; // SW x7, 0(x6)
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd6}; // x6 = rs1
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SW exe-rs1 hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // ===================================================================
        // TEST 4: SW — exe_forwarding.data_valid=0 for x7 (rs2)
        // ===================================================================
        $display("--- TEST 4: SW load-use hazard via exe_forwarding (rs2 match) ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0073_2023; // SW x7, 0(x6)
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd7}; // x7 = rs2
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SW exe-rs2 hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // ===================================================================
        // TEST 5: SLT — mem_forwarding.data_valid=0 (CSR-use hazard)
        // ===================================================================
        $display("--- TEST 5: SLT csr-use hazard via mem_forwarding (no exe match) ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0}; // no exe match
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd2}; // x2 = rs1, data_valid=0
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SLT mem-rs1 csr-hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // ===================================================================
        // TEST 6: SLT — mem_forwarding.data_valid=0 but exe has valid data (no stall)
        // ===================================================================
        $display("--- TEST 6: SLT mem invalid but exe valid → no stall ---");
        @(posedge clk); #1;
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 1, data: 32'h42, address: 5'd2}; // x2 valid in exe
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd2}; // x2 invalid in mem
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};

        @(posedge clk); #1;
        check("SLT exe-valid beats mem-invalid, no stall", 0/*READY*/, 0/*VALID*/);

        // ===================================================================
        // TEST 7: Check status_backwards_out BEFORE clock edge (combinational)
        // ===================================================================
        $display("--- TEST 7: SLT hazard — check backwards BEFORE posedge ---");
        // Set inputs, then check status_backwards_out combinationally (no clock)
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = READY;
        exe_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd2}; // x2 = rs1
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};
        #1; // just settle combinational
        if (int'(status_backwards_out) !== 1) begin
            $display("FAIL [SLT comb backwards]: status_backwards_out = %0d (exp 1 = STALL)", status_backwards_out);
            error_count++;
        end else
            $display("PASS [SLT comb backwards = STALL]");
        // Now clock and check forwards
        @(posedge clk); #1;
        if (int'(status_forwards_out) !== 1) begin
            $display("FAIL [SLT comb forwards]: status_forwards_out = %0d (exp 1 = BUBBLE)", status_forwards_out);
            error_count++;
        end else
            $display("PASS [SLT registered forwards = BUBBLE]");

        // ===================================================================
        // TEST 8: Sequential — STALL then READY with hazard still active
        // ===================================================================
        $display("--- TEST 8: Transition STALL->READY, hazard still active ---");
        // Step A: status_backwards_in=STALL, hazard present → hold outputs
        @(posedge clk); #1;
        instruction_in      = 32'h0031_00B3; // SLT x1, x2, x3
        status_forwards_in  = VALID;
        status_backwards_in = STALL; // Execute is stalled
        exe_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd2};
        mem_forwarding_in   = '{data_valid: 0, data: 0, address: 5'd0};
        wb_forwarding_in    = '{data_valid: 0, data: 0, address: 5'd0};
        @(posedge clk); #1; // fire with STALL → hold outputs (status_forwards_out stays BUBBLE from prev)
        // Step B: now status_backwards_in=READY, hazard still active → should output STALL/BUBBLE
        status_backwards_in = READY;
        @(posedge clk); #1; // fire with READY + pipeline_hazard=1 → set BUBBLE
        check("STALL->READY transition with hazard", 1/*STALL*/, 1/*BUBBLE*/);

        // done
        if (error_count == 0) begin
            $display("\033[0;32mAll tests passed! (# Errors:    0)\033[0m");
        end else begin
            $display("\033[0;31mSome tests failed! (# Errors: %0d)\033[0m", error_count);
        end
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!! TEST DONE !!!!!!!!!!!!!!!!!!!!");
        $display("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
        $finish();
    end

endmodule
