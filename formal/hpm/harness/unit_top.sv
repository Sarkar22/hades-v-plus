// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// unit_top.sv -- formal harness of the performance-counter unit: the event block
// (rtl/hpm_events.sv) and the counter unit (rtl/hpm.sv) together.
//
// A plain top module. Every input is free in every cycle, except that the first cycle is a reset
// and the mask of present memory-system events is one free constant for the whole run. The
// harness instantiates the two modules through harness/unit_bind.svh, the only file that names
// their ports, and computes, from the same free inputs, its own model of the events: the
// condition of every event code, written again from the event tables of the counter
// documentation, delayed by its counting class:
//   class A  (codes 1-20)                     counted at the end of the cycle of its condition;
//   class B1 (codes 47-49, 128-159, 160-161)  one cycle later;
//   class B2 (codes 21-26, 32-46)             two cycles later.
// An event is 0 in a cycle with rst = 1, and a reset clears the events still on their way.
// The properties and covers are in props/unit_props.vh, which formal/hpm/run.sh inserts, as one
// include line, before the final endmodule of the sv2v output of this file.
//
// The free inputs are the signals the event block and the counter unit see in the CPU:
//   the backward status out of Decode, Execute, Memory and Writeback (d, e, m, wb; the unused
//   encoding 3 is read as READY), the fetch port's ack and err, the instructions in Execute
//   (inst_d) and in Memory (inst_e), Decode's load-use hazard, the data port's cyc, its pending
//   flag and address, the memory-system event vector, the class-A events and the six trap events
//   of Writeback, and the CSR access that Writeback presents (address, write strobe, value).
// ---------------------------------------------------------------------------------------------
module unit_top (
    input logic                         clk,
    input logic                         in_rst,
    input logic [1:0]                   in_st_d,
    input logic [1:0]                   in_st_e,
    input logic [1:0]                   in_st_m,
    input logic [1:0]                   in_st_wb,
    input logic                         fetch_ack,
    input logic                         fetch_err,
    input logic [$bits(instruction::t)-1:0] in_inst_d,
    input logic [$bits(instruction::t)-1:0] in_inst_e,
    input logic                         load_use_hazard,
    input logic                         mem_cyc,
    input logic                         mem_pending,
    input logic [31:0]                  mem_adr,
    input logic [31:0]                  hpm_ext,
    input logic [31:0]                  in_ev_a,
    input logic [5:0]                   trap_raw,
    input logic [11:0]                  csr_addr,
    input logic                         csr_we,
    input logic [31:0]                  csr_wdata
);
    import pipeline_status::*;
    import op::*;

    localparam int F_N = hpm::COUNTERS;
    localparam int F_W = hpm::WIDTH;

    // ---- reset: the first cycle is a reset, later resets are free ----
    logic f_first = 1'b1;
    always_ff @(posedge clk) f_first <= 1'b0;
    logic rst;
    assign rst = in_rst || f_first;

    // ---- the present mask: one free constant ----
    (* anyconst *) logic [31:0] hpm_ext_present;

    // ---- legal status values, instructions ----
    backwards_t st_d, st_e, st_m, st_wb;
    assign st_d  = backwards_t'(in_st_d  == 2'd3 ? 2'd0 : in_st_d);
    assign st_e  = backwards_t'(in_st_e  == 2'd3 ? 2'd0 : in_st_e);
    assign st_m  = backwards_t'(in_st_m  == 2'd3 ? 2'd0 : in_st_m);
    assign st_wb = backwards_t'(in_st_wb == 2'd3 ? 2'd0 : in_st_wb);
    instruction::t inst_d, inst_e;
    assign inst_d = instruction::t'(in_inst_d);
    assign inst_e = instruction::t'(in_inst_e);

    // ---- class-A events: code c is bit c; CYCLE (code 1) is 1 in every cycle, as Writeback
    //      drives it ----
    logic [31:0] ev_a;
    assign ev_a = {in_ev_a[31:2], 1'b1, in_ev_a[0]};

    // ---- the outputs of the counter unit (driven in unit_bind.svh) ----
    logic [31:0] rdata;
    logic        inh_cy, inh_ir;
    logic [3:0]  inh_bp;

`include "unit_bind.svh"

    // =========================================================================================
    // The event model
    // =========================================================================================
    logic d_branch, d_jump, d_mul, d_div, d_load, e_load, e_store, in_ram, acc_start;
    assign d_branch  = inst_d.op inside {BEQ, BNE, BLT, BGE, BLTU, BGEU};
    assign d_jump    = inst_d.op inside {JAL, JALR};
    assign d_mul     = inst_d.op inside {MUL, MULH, MULHSU, MULHU};
    assign d_div     = inst_d.op inside {DIV, DIVU, REM, REMU};
    assign d_load    = inst_d.op inside {LB, LH, LW, LBU, LHU};
    assign e_load    = inst_e.op inside {LB, LH, LW, LBU, LHU};
    assign e_store   = inst_e.op inside {SB, SH, SW};
    assign in_ram    = (mem_adr - constants::MEMORY_START) < constants::MEMORY_SIZE;
    assign acc_start = mem_cyc && !mem_pending;

    // the condition of every B1 and B2 code in this cycle (0 in a reset cycle)
    logic [255:0] f_cond;
    logic f_hazard, f_mstall, f_memwait;
    assign f_hazard  = st_e == READY && st_d == STALL;
    assign f_mstall  = st_e == STALL && st_m != STALL;
    assign f_memwait = st_m == STALL;
    always_comb begin
        f_cond = '0;
        if (!rst) begin
            f_cond[21] = trap_raw[0];                          // EXCEPTION
            f_cond[22] = trap_raw[1];                          // EXC_ECALL
            f_cond[23] = trap_raw[2];                          // EXC_OTHER
            f_cond[24] = trap_raw[3];                          // INTERRUPT
            f_cond[25] = trap_raw[4];                          // INT_TIMER
            f_cond[26] = trap_raw[5];                          // INT_EXT
            f_cond[32] = st_e == READY && st_d == READY && !fetch_ack && !fetch_err; // FETCH_WAIT
            f_cond[33] = st_e == READY && st_d == READY && (fetch_ack || fetch_err);  // FRONT_OK
            f_cond[34] = f_hazard;                             // HAZARD
            f_cond[35] = f_mstall;                             // MSTALL_ANY
            f_cond[36] = f_memwait;                            // MEMWAIT_ANY
            f_cond[37] = st_e == JUMP;                         // REDIRECT_ANY
            f_cond[38] = f_hazard && load_use_hazard && d_load; // HAZARD_LOAD
            f_cond[39] = f_mstall && d_mul;                    // MSTALL_MUL
            f_cond[40] = f_mstall && d_div;                    // MSTALL_DIV
            f_cond[41] = f_memwait && e_load;                  // MEMWAIT_LOAD
            f_cond[42] = f_memwait && e_store;                 // MEMWAIT_STORE
            f_cond[43] = f_memwait && !in_ram;                 // MEMWAIT_IO
            f_cond[44] = st_e == JUMP && st_m == READY && d_branch; // REDIRECT_BRANCH
            f_cond[45] = st_e == JUMP && st_m == READY && d_jump;   // REDIRECT_JUMP
            f_cond[46] = st_wb == JUMP;                        // REDIRECT_WB
            f_cond[47] = fetch_ack && st_d == READY;           // FETCH_DELIVER
            f_cond[48] = fetch_ack && st_d != READY;           // FETCH_DISCARD
            f_cond[49] = acc_start && !in_ram;                 // IO_ACCESS
            f_cond[159:128] = hpm_ext;                         // the raw memory-system bits
            f_cond[160] = hpm_ext[0] && st_d == READY;         // IC_HIT_USED
            f_cond[161] = hpm_ext[1] && st_d == JUMP;          // IC_MISS_JUMP
        end
    end

    // one and two cycles later; a reset clears both stages
    logic [255:0] f_q1, f_q2;
    always_ff @(posedge clk) begin
        f_q1 <= rst ? '0 : f_cond;
        f_q2 <= rst ? '0 : f_q1;
    end

    // the event each code contributes at the end of this cycle
    logic [255:0] f_ev_exp;
    always_comb begin
        f_ev_exp = '0;
        for (int c = 1; c <= 20; c++)   f_ev_exp[c] = ev_a[c] && !rst;
        for (int c = 21; c <= 26; c++)  f_ev_exp[c] = f_q2[c];
        for (int c = 32; c <= 46; c++)  f_ev_exp[c] = f_q2[c];
        for (int c = 47; c <= 49; c++)  f_ev_exp[c] = f_q1[c];
        for (int c = 128; c <= 161; c++) f_ev_exp[c] = f_q1[c];
    end
endmodule
