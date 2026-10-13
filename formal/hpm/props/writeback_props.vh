// SPDX-License-Identifier: MIT
// =============================================================================================
// writeback_props.vh -- the Writeback miter: the Writeback stage of the tree under proof
// (wb_new) against the base commit's (wb_base: base/writeback_stage_base.sv, that commit's
// rtl/writeback_stage.sv with only its module name changed), with the same inputs; the inputs
// that only the new stage has are free. formal/hpm/scripts/model.py writes the top module
// (writeback_top) from the two port lists and inserts this file, as one include line, before
// its endmodule. The top provides clk, rst (a reset in the first cycle, free later), f_first,
// the shared inputs in_<port>, the outputs b_<port> and n_<port>, the fields of the instruction
// in Writeback (f_*, from harness/wb_fields.sv) and, when the new stage instantiates the
// counter unit as i_hpm, the macro F_HAS_HPM and the ranges of its ports ev_a and trap_raw.
//
// Assumed (the intended differences): the instruction in Writeback, when its status is VALID,
// is not a CSR operation on 0x320, 0x323-0x329, 0x32B-0x32D, 0xB03-0xB0D or 0xB83-0xB89, and not
// CSRRS, CSRRC, CSRRSI or CSRRCI with a non-zero rs1 field on 0xB00, 0xB02, 0xB80 or 0xB82. In
// the first cycle the two states are equal (mcycle is not reset). With ASSUME_X0_SOURCE (run.sh
// --assume-x0-source) also: a CSRRS, CSRRC, CSRRSI or CSRRCI with rs1 field 0 has source 0.
//
//   writeback_miter   in every cycle: equal outputs (status_backwards_out,
//                     jump_address_backwards_out, forwarding_out, bp_control_out) and equal
//                     state (mstatus MIE and MPIE, mtvec, mie MEIE and MTIE, the registered mip
//                     bits, mepc, mcause, mscratch, mcycle, minstret, bp_control, int_jump_reg,
//                     imm_jump_reg, int_next_pc_reg); with the counter unit, its inhibit outputs
//                     are 0. Unbounded, by k-induction: the asserted equalities are the
//                     invariants.
//   writeback_events  (only with the counter unit) in every cycle without reset: the class-A
//                     events that Writeback gives the unit (ev_a, bit c = code c, codes 2-20)
//                     and its six trap events (trap_raw, bit k = code 21 + k) are the
//                     conditions of the event tables, computed from the base stage's signals:
//                     retire = VALID and not replayed; the predictor events from Execute's
//                     record delayed two cycles; the trap events from the trap decision.
// =============================================================================================
`ifdef FORMAL
    // ---- the state of the two stages ----
    (* hierconn *) wire        \wb_base.mstatus_mpie ;     (* hierconn *) wire        \wb_new.mstatus_mpie ;
    (* hierconn *) wire        \wb_base.mstatus_mie ;      (* hierconn *) wire        \wb_new.mstatus_mie ;
    (* hierconn *) wire [31:0] \wb_base.mtvec ;            (* hierconn *) wire [31:0] \wb_new.mtvec ;
    (* hierconn *) wire        \wb_base.mie_meie ;         (* hierconn *) wire        \wb_new.mie_meie ;
    (* hierconn *) wire        \wb_base.mie_mtie ;         (* hierconn *) wire        \wb_new.mie_mtie ;
    (* hierconn *) wire        \wb_base.mip_meip_reg ;     (* hierconn *) wire        \wb_new.mip_meip_reg ;
    (* hierconn *) wire        \wb_base.mip_mtip_reg ;     (* hierconn *) wire        \wb_new.mip_mtip_reg ;
    (* hierconn *) wire [31:0] \wb_base.mepc ;             (* hierconn *) wire [31:0] \wb_new.mepc ;
    (* hierconn *) wire [31:0] \wb_base.mcause ;           (* hierconn *) wire [31:0] \wb_new.mcause ;
    (* hierconn *) wire [31:0] \wb_base.mscratch ;         (* hierconn *) wire [31:0] \wb_new.mscratch ;
    (* hierconn *) wire [63:0] \wb_base.mcycle ;           (* hierconn *) wire [63:0] \wb_new.mcycle ;
    (* hierconn *) wire [63:0] \wb_base.minstret ;         (* hierconn *) wire [63:0] \wb_new.minstret ;
    (* hierconn *) wire [31:0] \wb_base.bp_control ;       (* hierconn *) wire [31:0] \wb_new.bp_control ;
    (* hierconn *) wire        \wb_base.int_jump_reg ;     (* hierconn *) wire        \wb_new.int_jump_reg ;
    (* hierconn *) wire        \wb_base.imm_jump_reg ;     (* hierconn *) wire        \wb_new.imm_jump_reg ;
    (* hierconn *) wire [31:0] \wb_base.int_next_pc_reg ;  (* hierconn *) wire [31:0] \wb_new.int_next_pc_reg ;
    wire [327:0] f_state_base = {\wb_base.mstatus_mpie , \wb_base.mstatus_mie , \wb_base.mtvec ,
        \wb_base.mie_meie , \wb_base.mie_mtie , \wb_base.mip_meip_reg , \wb_base.mip_mtip_reg ,
        \wb_base.mepc , \wb_base.mcause , \wb_base.mscratch , \wb_base.mcycle , \wb_base.minstret ,
        \wb_base.bp_control , \wb_base.int_jump_reg , \wb_base.imm_jump_reg , \wb_base.int_next_pc_reg };
    wire [327:0] f_state_new = {\wb_new.mstatus_mpie , \wb_new.mstatus_mie , \wb_new.mtvec ,
        \wb_new.mie_meie , \wb_new.mie_mtie , \wb_new.mip_meip_reg , \wb_new.mip_mtip_reg ,
        \wb_new.mepc , \wb_new.mcause , \wb_new.mscratch , \wb_new.mcycle , \wb_new.minstret ,
        \wb_new.bp_control , \wb_new.int_jump_reg , \wb_new.imm_jump_reg , \wb_new.int_next_pc_reg };

    // ---- signals of the base stage (the reference for the event conditions and the covers) ----
    (* hierconn *) wire \wb_base.is_valid ;
    (* hierconn *) wire \wb_base.stale_replay ;
    (* hierconn *) wire \wb_base.is_exception ;
    (* hierconn *) wire \wb_base.is_interrupt_seq ;
    (* hierconn *) wire \wb_base.is_interrupt_imm ;
    (* hierconn *) wire \wb_base.ext_int_pending ;
    (* hierconn *) wire \wb_base.int_hold ;
    (* hierconn *) wire \wb_base.int_jump_fire ;
    wire f_exc_cover_ok = !\wb_base.int_jump_reg && !\wb_base.imm_jump_reg ;

    // ---- the assumptions: the intended differences are excluded ----
    wire f_excl_addr = f_csr == 12'h320 || (f_csr >= 12'h323 && f_csr <= 12'h329) ||
                       (f_csr >= 12'h32B && f_csr <= 12'h32D) ||
                       (f_csr >= 12'hB03 && f_csr <= 12'hB0D) ||
                       (f_csr >= 12'hB83 && f_csr <= 12'hB89);
    wire f_excl_rmw  = f_is_set_clear && f_rs1 != 5'd0 &&
                       (f_csr == 12'hB00 || f_csr == 12'hB02 || f_csr == 12'hB80 || f_csr == 12'hB82);
    always @* begin
        assume(!(f_is_valid && f_is_csr_op && (f_excl_addr || f_excl_rmw)));
        `ifdef ASSUME_X0_SOURCE
        if (f_is_set_clear && f_rs1 == 5'd0) assume(in_source_data_in == 32'b0);
        `endif
        if (f_first) assume(f_state_base == f_state_new);
    end

`ifdef F_HAS_HPM
    (* hierconn *) wire [`F_EV_A_HI:`F_EV_A_LO]   \wb_new.i_hpm.ev_a ;
    (* hierconn *) wire [`F_TRAP_HI:`F_TRAP_LO]   \wb_new.i_hpm.trap_raw ;
    (* hierconn *) wire                           \wb_new.i_hpm.inh_cy ;
    (* hierconn *) wire                           \wb_new.i_hpm.inh_ir ;
    (* hierconn *) wire [3:0]                     \wb_new.i_hpm.inh_bp ;
    wire [63:0] f_ev_a_raw = {32'b0, \wb_new.i_hpm.ev_a };
    wire [31:0] f_ev_a = f_ev_a_raw << `F_EV_A_LO;
    wire [5:0]  f_trap = \wb_new.i_hpm.trap_raw ;
`endif

    // ---- the required equalities ----
    always @* begin
        `ifdef CHECK_WRITEBACK_MITER
        assert(b_status_backwards_out == n_status_backwards_out);
        assert(b_jump_address_backwards_out == n_jump_address_backwards_out);
        assert(b_forwarding_out == n_forwarding_out);
        assert(b_bp_control_out == n_bp_control_out);
        assert(f_state_base == f_state_new);
        `ifdef F_HAS_HPM
        if (!f_first) assert(!\wb_new.i_hpm.inh_cy && !\wb_new.i_hpm.inh_ir && \wb_new.i_hpm.inh_bp == 4'b0);
        `endif
        `endif
    end

`ifdef F_HAS_HPM
    // ---- the event conditions, from the base stage ----
    reg [2:0] f_rec1, f_rec2;    // Execute's record {valid, predicted_taken, was_taken}, delayed
    always @(posedge clk) begin
        f_rec1 <= rst ? 3'b0 : {f_bp_valid, f_bp_predicted_taken, f_bp_was_taken};
        f_rec2 <= rst ? 3'b0 : f_rec1;
    end
    wire f_retire = \wb_base.is_valid && !\wb_base.stale_replay ;
    wire f_bp     = f_rec2[2] && f_retire && f_is_branch;
    wire f_exc    = \wb_base.is_exception && !\wb_base.int_jump_reg && !\wb_base.imm_jump_reg ;
    wire f_int    = \wb_base.is_interrupt_seq || (\wb_base.is_interrupt_imm && !\wb_base.imm_jump_reg );
    wire [31:0] f_ev_a_exp = {11'b0,
        f_bp &&  f_rec2[1] &&  f_rec2[0],                // 20 BP_TT
        f_bp &&  f_rec2[1] && !f_rec2[0],                // 19 BP_TN
        f_bp && !f_rec2[1] &&  f_rec2[0],                // 18 BP_NT
        f_bp && !f_rec2[1] && !f_rec2[0],                // 17 BP_NN
        f_bp && (f_rec2[1] != f_rec2[0]),                // 16 BR_MISPREDICT
        \wb_base.stale_replay ,                          // 15 REPLAY
        f_retire && f_is_fence_i,                        // 14 FENCE_I
        f_retire && f_is_mret,                           // 13 MRET
        f_retire && f_is_crypto,                         // 12 CRYPTO
        f_retire && f_is_bitmanip,                       // 11 BITMANIP
        f_retire && f_is_csr_op,                         // 10 CSR
        f_retire && f_is_div,                            //  9 DIV
        f_retire && f_is_mul,                            //  8 MUL
        f_retire && f_is_jump,                           //  7 JUMP
        f_retire && f_is_branch && in_rd_data_in[0],     //  6 BRANCH_TAKEN
        f_retire && f_is_branch,                         //  5 BRANCH
        f_retire && f_is_store,                          //  4 STORE
        f_retire && f_is_load,                           //  3 LOAD
        f_retire,                                        //  2 INSTRET
        2'b0};                                           //  1 CYCLE (not checked), 0
    wire [5:0] f_trap_exp = {f_int && \wb_base.ext_int_pending , f_int && !\wb_base.ext_int_pending , f_int,
                             f_exc && !f_is_ecall, f_exc && f_is_ecall, f_exc};
    always @* if (!f_first && !rst) begin
        `ifdef CHECK_WRITEBACK_EVENTS
        assert(f_ev_a[20:2] == f_ev_a_exp[20:2]);
        assert(f_trap == f_trap_exp);
        `endif
    end
`endif

    // ---- covers: the trap and interrupt paths the miter compares ----
    always @* if (!f_first && !rst) begin
        `ifdef COVERS
        cover(\wb_base.is_exception && f_exc_cover_ok);
        cover(\wb_base.is_interrupt_seq );
        cover(\wb_base.int_jump_fire && \wb_base.is_valid && !\wb_base.stale_replay );
        cover(\wb_base.stale_replay );
        cover(\wb_base.int_hold );
        cover(\wb_base.is_interrupt_imm && f_is_mret && f_is_valid);
        cover(\wb_base.is_interrupt_imm && f_is_csr_op && f_csr == 12'h300 && f_is_set_clear);
        cover(\wb_base.is_interrupt_imm && f_is_csr_op && f_csr == 12'h304);
        cover(f_is_valid && f_is_csr_op && f_csr == 12'hB00 && !f_is_set_clear);
        cover(f_is_valid && f_is_csr_op && f_csr == 12'h32A);
        `endif
    end
`endif
