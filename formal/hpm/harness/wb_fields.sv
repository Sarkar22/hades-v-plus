// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// wb_fields.sv -- a helper of the Writeback harness (the top module that formal/hpm/scripts/
// model.py writes): the fields and classes of the instruction, the status and the predictor
// record that Writeback receives, read with the names of the packages, so that the properties
// (props/writeback_props.vh, plain Verilog after sv2v) need no field positions or op numbers.
// ---------------------------------------------------------------------------------------------
module wb_fields (
    input  instruction::t              instruction_in,
    input  pipeline_status::forwards_t status_in,
    input  bpredict::bp_data_t         bp_in,
    output logic [11:0]                csr,
    output logic [4:0]                 rs1,
    output logic                       is_csr_op,      // CSRRW .. CSRRCI
    output logic                       is_set_clear,   // CSRRS, CSRRC, CSRRSI, CSRRCI
    output logic                       is_valid,       // status VALID
    output logic                       is_ecall,       // status ECALL
    output logic                       is_load,
    output logic                       is_store,
    output logic                       is_branch,
    output logic                       is_jump,
    output logic                       is_mul,
    output logic                       is_div,
    output logic                       is_bitmanip,    // Zba, and EXT with immediate[11] = 0
    output logic                       is_crypto,      // EXT with immediate[11] = 1
    output logic                       is_mret,
    output logic                       is_fence_i,
    output logic                       bp_valid,
    output logic                       bp_predicted_taken,
    output logic                       bp_was_taken
);
    import op::*;
    assign csr          = instruction_in.csr;
    assign rs1          = instruction_in.rs1_address;
    assign is_csr_op    = instruction_in.op inside {CSRRW, CSRRS, CSRRC, CSRRWI, CSRRSI, CSRRCI};
    assign is_set_clear = instruction_in.op inside {CSRRS, CSRRC, CSRRSI, CSRRCI};
    assign is_valid     = status_in == pipeline_status::VALID;
    assign is_ecall     = status_in == pipeline_status::ECALL;
    assign is_load      = instruction_in.op inside {LB, LH, LW, LBU, LHU};
    assign is_store     = instruction_in.op inside {SB, SH, SW};
    assign is_branch    = instruction_in.op inside {BEQ, BNE, BLT, BGE, BLTU, BGEU};
    assign is_jump      = instruction_in.op inside {JAL, JALR};
    assign is_mul       = instruction_in.op inside {MUL, MULH, MULHSU, MULHU};
    assign is_div       = instruction_in.op inside {DIV, DIVU, REM, REMU};
    assign is_bitmanip  = instruction_in.op inside {SH1ADD, SH2ADD, SH3ADD} ||
                          (instruction_in.op == EXT && !instruction_in.immediate[11]);
    assign is_crypto    = instruction_in.op == EXT && instruction_in.immediate[11];
    assign is_mret      = instruction_in.op == MRET;
    assign is_fence_i   = instruction_in.op == FENCE_I;
    assign bp_valid           = bp_in.valid;
    assign bp_predicted_taken = bp_in.predicted_taken;
    assign bp_was_taken       = bp_in.was_taken;
endmodule
