/* Execute stage with the branch predictor's prediction applied, against the golden
 * ref_execute_stage (which has no predictor, i.e. behaves as "predict never taken").
 *
 * next_program_counter_reg_out is the ARCHITECTURAL next PC of the instruction: it
 * travels to Writeback, which uses it as mepc when an interrupt is taken right after
 * the instruction retires. It must therefore not depend on the prediction: for every
 * branch, whatever bp_prediction_in.predicted_taken says, it must equal the golden
 * model's value (target if taken, PC+4 if not; PC+4 for a non-VALID branch).
 * A correctly predicted taken branch used to carry PC+4 here (test/asm/bpirq*.s).
 *
 * Also checked, per vector:
 *   - every other registered output equals the golden one (the prediction may only
 *     change the flush decision);
 *   - the stage flushes (JUMP) exactly when a VALID branch was mispredicted, and then
 *     to the golden next PC; a correctly predicted branch does not flush.
 * Misaligned targets are only driven with predicted_taken = 0: the predictor never
 * predicts a branch with offset[1:0] != 0 taken (branch_predictor.sv).
 */

module test_execute_bpred_nextpc;
    import clk_params::*;
    import pipeline_status::*;
    import op::*;

    localparam int N = 20000;

    logic clk, rst;
    int errors = 0, checks = 0, nextpc_errors = 0;
    int n_pred_taken_correct = 0, n_pred_taken_wrong = 0, n_pred_nt_correct = 0, n_pred_nt_wrong = 0;

    initial begin clk = 1; forever #(int'(SIM_CYCLES_PER_SYS_CLK / 2)) clk = ~clk; end

    logic [31:0]   rs1_data_in, rs2_data_in, program_counter_in, jump_address_backwards_in;
    instruction::t instruction_in;
    pipeline_status::forwards_t  status_forwards_in;
    pipeline_status::backwards_t status_backwards_in;
    bpredict::bp_data_t bp_prediction_in, bp_feedback_out;

    logic [31:0]   d_src, d_rd, d_pc, d_npc, d_jaddr;
    instruction::t d_instr;
    forwarding::t  d_fwd;
    pipeline_status::forwards_t  d_sf;
    pipeline_status::backwards_t d_sb;

    logic [31:0]   r_src, r_rd, r_pc, r_npc, r_jaddr;
    instruction::t r_instr;
    forwarding::t  r_fwd;
    pipeline_status::forwards_t  r_sf;
    pipeline_status::backwards_t r_sb;

    execute_stage dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in), .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in), .program_counter_in(program_counter_in),
        .source_data_reg_out(d_src), .rd_data_reg_out(d_rd), .instruction_reg_out(d_instr),
        .program_counter_reg_out(d_pc), .next_program_counter_reg_out(d_npc),
        .forwarding_out(d_fwd),
        .bp_prediction_in(bp_prediction_in), .bp_feedback_out(bp_feedback_out),
        .status_forwards_in(status_forwards_in), .status_forwards_out(d_sf),
        .status_backwards_in(status_backwards_in), .status_backwards_out(d_sb),
        .jump_address_backwards_in(jump_address_backwards_in), .jump_address_backwards_out(d_jaddr)
    );

    ref_execute_stage ref_dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in), .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in), .program_counter_in(program_counter_in),
        .source_data_reg_out(r_src), .rd_data_reg_out(r_rd), .instruction_reg_out(r_instr),
        .program_counter_reg_out(r_pc), .next_program_counter_reg_out(r_npc),
        .forwarding_out(r_fwd),
        .status_forwards_in(status_forwards_in), .status_forwards_out(r_sf),
        .status_backwards_in(status_backwards_in), .status_backwards_out(r_sb),
        .jump_address_backwards_in(jump_address_backwards_in), .jump_address_backwards_out(r_jaddr)
    );

    task automatic report_fail(string what, int k, logic [31:0] dv, logic [31:0] rv);
        errors++;
        if (errors <= 20)
            $display("[%0d] FAIL %s: op=%s pc=%08h imm=%08h rs1=%08h rs2=%08h st=%s pred=%0b dut=%08h ref=%08h",
                     k, what, instruction_in.op.name(), program_counter_in, instruction_in.immediate,
                     rs1_data_in, rs2_data_in, status_forwards_in.name(), bp_prediction_in.predicted_taken,
                     dv, rv);
    endtask

    function automatic logic taken(op::t o, logic [31:0] a, logic [31:0] b);
        case (o)
            BEQ:  return a == b;
            BNE:  return a != b;
            BLT:  return $signed(a) <  $signed(b);
            BGE:  return $signed(a) >= $signed(b);
            BLTU: return a <  b;
            BGEU: return a >= b;
            default: return 1'b0;
        endcase
    endfunction

    op::t ops [6] = '{BEQ, BNE, BLT, BGE, BLTU, BGEU};

    initial begin
        void'($urandom(32'h5eed_b9ed));
        rst = 1;
        rs1_data_in = 0; rs2_data_in = 0; program_counter_in = 0; jump_address_backwards_in = 0;
        instruction_in = instruction::NOP;
        status_forwards_in = VALID; status_backwards_in = READY;
        bp_prediction_in = '0;
        @(posedge clk); #1; @(posedge clk); #1;
        rst = 0;
        @(posedge clk); #1;

        for (int k = 0; k < N; k++) begin
            logic [31:0] imm, a, b;
            logic [12:0] off;
            logic        misaligned, tk, mispredicted, exp_flush;
            int          r;

            // B-type immediate: 13-bit signed, even; 1 in 8 with offset[1] set (misaligned)
            off = 13'($urandom);
            imm = {{19{off[12]}}, off} & 32'hFFFF_FFFC;
            misaligned = ($urandom % 8) == 0;
            if (misaligned) imm[1] = 1'b1;
            a = $urandom;
            r = $urandom % 4;
            b = (r == 0) ? a : (r == 1) ? a + 1 : (r == 2) ? a - 1 : $urandom;

            instruction_in                = instruction::NOP;
            instruction_in.op             = ops[$urandom % 6];
            instruction_in.rd_address     = 5'd0;
            instruction_in.rs1_address    = 5'($urandom);
            instruction_in.rs2_address    = 5'($urandom);
            instruction_in.immediate      = imm;
            rs1_data_in                   = a;
            rs2_data_in                   = b;
            program_counter_in            = {$urandom} & 32'hFFFF_FFFC;
            r = $urandom % 10;
            status_forwards_in = (r < 7) ? VALID : (r == 7) ? BUBBLE : (r == 8) ? ILLEGAL_INSTRUCTION : FETCH_FAULT;
            status_backwards_in = READY;
            bp_prediction_in                 = '0;
            bp_prediction_in.valid           = !misaligned;
            bp_prediction_in.predicted_taken = misaligned ? 1'b0 : 1'($urandom);
            bp_prediction_in.index           = 5'($urandom);

            tk = taken(instruction_in.op, a, b);
            mispredicted = (status_forwards_in == VALID) && (tk != bp_prediction_in.predicted_taken);
            if (status_forwards_in == VALID) begin
                if (bp_prediction_in.predicted_taken) begin
                    if (tk) n_pred_taken_correct++; else n_pred_taken_wrong++;
                end else begin
                    if (tk) n_pred_nt_wrong++; else n_pred_nt_correct++;
                end
            end

            // combinational: flush decision (checked against the golden next PC after the edge)
            #1;
            checks++;
            exp_flush = mispredicted;
            if ((d_sb == JUMP) != exp_flush)
                report_fail(exp_flush ? "no flush on a misprediction" : "flush without a misprediction",
                     k, 32'(d_sb), 32'(r_sb));
            if (!bp_prediction_in.predicted_taken && (d_sb != r_sb))
                report_fail("flush decision differs from golden with predicted_taken=0", k, 32'(d_sb), 32'(r_sb));
            begin
                logic        dj; logic [31:0] da;
                dj = (d_sb == JUMP); da = d_jaddr;
                @(posedge clk); #1;
                checks++;
                if (d_npc !== r_npc) begin
                    nextpc_errors++;
                    report_fail("next_program_counter", k, d_npc, r_npc);
                end
                if (dj && (da !== r_npc))
                    report_fail("flush target != golden next PC", k, da, r_npc);
                if (d_pc !== r_pc)       report_fail("program_counter_reg", k, d_pc, r_pc);
                if (d_rd !== r_rd)       report_fail("rd_data_reg", k, d_rd, r_rd);
                if (d_src !== r_src)     report_fail("source_data_reg", k, d_src, r_src);
                if (d_instr !== r_instr) report_fail("instruction_reg", k, 32'(d_instr.op), 32'(r_instr.op));
                if (d_sf !== r_sf)       report_fail("status_forwards_out", k, 32'(d_sf), 32'(r_sf));
            end
        end

        $display("");
        $display("VALID branches: predicted taken & taken %0d, predicted taken & not taken %0d, predicted not taken & taken %0d, predicted not taken & not taken %0d",
                 n_pred_taken_correct, n_pred_taken_wrong, n_pred_nt_wrong, n_pred_nt_correct);
        $display("next_program_counter mismatches vs golden: %0d", nextpc_errors);
        if (errors == 0)
            $display("All %0d branch-prediction next-PC checks passed", checks);
        else
            $display("Checks: %0d   Errors: %0d   SOME CHECKS FAILED", checks, errors);
        $finish;
    end
endmodule
