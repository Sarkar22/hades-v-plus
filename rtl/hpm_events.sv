// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// hpm_events.sv -- the pipeline and memory-system events of the hardware performance counters.
//
// Registers the raw conditions once (one new load on each source net, ending at a flip-flop)
// and computes, from those flip-flops, the events of classes B1 and the first stage of B2
// (defines/hpm.sv, rtl/hpm.sv). Every output is therefore one cycle late: it describes the
// cycle before. All events are 0 for a cycle with rst = 1.
//
// Raw inputs (all of the same cycle):
//   status_d/e/m/wb   the backward status out of Decode, Execute, Memory and Writeback
//   fetch_ack/err     the fetch port's answer
//   op_d              the instruction in Execute (Decode's output register)
//   op_e              the instruction in Memory (Execute's output register)
//   load_use_hazard   Decode's load-use hazard
//   mem_cyc, mem_pending, mem_adr   the data port: cyc, an access started in an earlier
//                     cycle is still in flight, and the word address
//   ext               the memory-system event vector (rtl/mcu.sv; 0 without a cache)
//
// The six classes 32-37 divide every cycle into exactly one class, chosen by the oldest
// stage that holds the pipeline: MEMWAIT_ANY (m = STALL), else MSTALL_ANY (e = STALL), else
// REDIRECT_ANY (e = JUMP), else HAZARD (d = STALL), else FETCH_WAIT (no answer), else
// FRONT_OK.
// ---------------------------------------------------------------------------------------------

module hpm_events (
    input  logic                        clk,
    input  logic                        rst,

    input  pipeline_status::backwards_t status_d,
    input  pipeline_status::backwards_t status_e,
    input  pipeline_status::backwards_t status_m,
    input  pipeline_status::backwards_t status_wb,
    input  logic                        fetch_ack,
    input  logic                        fetch_err,
    input  op::t                        op_d,
    input  op::t                        op_e,
    input  logic                        load_use_hazard,
    input  logic                        mem_cyc,
    input  logic                        mem_pending,
    input  logic [31:0]                 mem_adr,
    input  logic [31:0]                 ext,

    output hpm_pkg::late_t                  late
);

    import pipeline_status::*;
    import op::*;

    // =========================================================================
    // Classification of the raw inputs
    // =========================================================================
    logic d_branch, d_jump, d_mul, d_div, d_load, e_load, e_store;

    always_comb begin
        d_branch = op_d inside {BEQ, BNE, BLT, BGE, BLTU, BGEU};
        d_jump   = op_d inside {JAL, JALR};
        d_mul    = op_d inside {MUL, MULH, MULHSU, MULHU};
        d_div    = op_d inside {DIV, DIVU, REM, REMU};
        d_load   = op_d inside {LB, LH, LW, LBU, LHU};
        e_load   = op_e inside {LB, LH, LW, LBU, LHU};
        e_store  = op_e inside {SB, SH, SW};
    end

    // in_ram(adr): the word address lies in the RAM window
    logic in_ram;
    assign in_ram = (mem_adr - constants::MEMORY_START) < constants::MEMORY_SIZE;

    // =========================================================================
    // The raw-input register
    // =========================================================================
    // r_valid is 0 in the cycle after a reset cycle, so a reset cycle has no events.
    logic        r_valid;
    backwards_t  r_d, r_e, r_m, r_wb;
    logic        r_ack, r_err;
    logic        r_d_branch, r_d_jump, r_d_mul, r_d_div, r_d_load;
    logic        r_e_load, r_e_store;
    logic        r_luh;
    logic        r_start, r_in_ram;
    logic [31:0] r_ext;

    always_ff @(posedge clk) begin
        if (rst) begin
            r_valid    <= 1'b0;
            r_d        <= READY;
            r_e        <= READY;
            r_m        <= READY;
            r_wb       <= READY;
            r_ack      <= 1'b0;
            r_err      <= 1'b0;
            r_d_branch <= 1'b0;
            r_d_jump   <= 1'b0;
            r_d_mul    <= 1'b0;
            r_d_div    <= 1'b0;
            r_d_load   <= 1'b0;
            r_e_load   <= 1'b0;
            r_e_store  <= 1'b0;
            r_luh      <= 1'b0;
            r_start    <= 1'b0;
            r_in_ram   <= 1'b0;
            r_ext      <= 32'b0;
        end else begin
            r_valid    <= 1'b1;
            r_d        <= status_d;
            r_e        <= status_e;
            r_m        <= status_m;
            r_wb       <= status_wb;
            r_ack      <= fetch_ack;
            r_err      <= fetch_err;
            r_d_branch <= d_branch;
            r_d_jump   <= d_jump;
            r_d_mul    <= d_mul;
            r_d_div    <= d_div;
            r_d_load   <= d_load;
            r_e_load   <= e_load;
            r_e_store  <= e_store;
            r_luh      <= load_use_hazard;
            r_start    <= mem_cyc && !mem_pending;   // a data access starts
            r_in_ram   <= in_ram;
            r_ext      <= ext;
        end
    end

    // =========================================================================
    // The events of the registered cycle
    // =========================================================================
    logic fetch_wait, front_ok, hazard, mstall_any, memwait_any, redirect_any;

    always_comb begin
        // the cycle partition (32-37)
        memwait_any  = r_valid && r_m == STALL;
        mstall_any   = r_valid && r_e == STALL && r_m != STALL;
        redirect_any = r_valid && r_e == JUMP;
        hazard       = r_valid && r_e == READY && r_d == STALL;
        fetch_wait   = r_valid && r_e == READY && r_d == READY && !r_ack && !r_err;
        front_ok     = r_valid && r_e == READY && r_d == READY && (r_ack || r_err);

        late = '0;

        // B2, first stage
        late.b2[hpm_pkg::EV_FETCH_WAIT]      = fetch_wait;
        late.b2[hpm_pkg::EV_FRONT_OK]        = front_ok;
        late.b2[hpm_pkg::EV_HAZARD]          = hazard;
        late.b2[hpm_pkg::EV_MSTALL_ANY]      = mstall_any;
        late.b2[hpm_pkg::EV_MEMWAIT_ANY]     = memwait_any;
        late.b2[hpm_pkg::EV_REDIRECT_ANY]    = redirect_any;
        late.b2[hpm_pkg::EV_HAZARD_LOAD]     = hazard && r_luh && r_d_load;
        late.b2[hpm_pkg::EV_MSTALL_MUL]      = mstall_any && r_d_mul;
        late.b2[hpm_pkg::EV_MSTALL_DIV]      = mstall_any && r_d_div;
        late.b2[hpm_pkg::EV_MEMWAIT_LOAD]    = memwait_any && r_e_load;
        late.b2[hpm_pkg::EV_MEMWAIT_STORE]   = memwait_any && r_e_store;
        late.b2[hpm_pkg::EV_MEMWAIT_IO]      = memwait_any && !r_in_ram;
        late.b2[hpm_pkg::EV_REDIRECT_BRANCH] = redirect_any && r_m == READY && r_d_branch;
        late.b2[hpm_pkg::EV_REDIRECT_JUMP]   = redirect_any && r_m == READY && r_d_jump;
        late.b2[hpm_pkg::EV_REDIRECT_WB]     = r_valid && r_wb == JUMP;

        // B1
        late.b1[hpm_pkg::EV_FETCH_DELIVER]   = r_valid && r_ack && r_d == READY;
        late.b1[hpm_pkg::EV_FETCH_DISCARD]   = r_valid && r_ack && r_d != READY;
        late.b1[hpm_pkg::EV_IO_ACCESS]       = r_valid && r_start && !r_in_ram;

        // B1, memory system: the raw vector and the combined codes
        late.ext                         = r_valid ? r_ext : 32'b0;
        late.comb[hpm_pkg::EV_IC_HIT_USED]   = r_valid && r_ext[hpm_pkg::EXT_IC_LOOKUP_HIT] && r_d == READY;
        late.comb[hpm_pkg::EV_IC_MISS_JUMP]  = r_valid && r_ext[hpm_pkg::EXT_IC_MISS] && r_d == JUMP;
    end

endmodule
