// =============================================================================
// top_ext.v -- formal top for the EXT unit (Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh) of the REAL
// rtl/execute_stage.sv: port-level properties X1, X2 and X3.
//
// Same top as harness/top_iface.v: the real execute_stage, every input free
// except for the environment E0-E2 of props/div_props.vh (start from reset;
// Memory drives defined backwards values; Decode holds its outputs while
// Execute answers STALL). None of the M-unit groups (CTRL, DIVF, MULREG) and no
// lemma is assumed: the EXT properties do not depend on the M proof.
// The properties look only at the module's ports; nothing here is gated by an
// RTL-internal signal.
//
// An instruction is "EXT instruction <id>" when its opcode field is op::EXT
// (61 in the frozen op::t enum of defines/op.sv) and its immediate field is the
// payload the decoder builds for that instruction (op::ext_payload_t):
//   [31:12] 0,  [11:6] sel,  [5] use_imm,  [4:0] shamt (inst[24:20] when use_imm,
//   else 0).
// sel[5] (payload bit 11) selects the cryptography half: 0 for the 28 Zbb, Zbs and
// Zicond instructions, 1 for the 17 Zbkb, Zbkx and Zknh instructions.
// f_ext_payload below is that map (numbering of props/ext_spec.vh);
// scripts/ext_codes.py checks every sel and use_imm against defines/op.sv. The
// map from the 32-bit instruction word to this payload is the decoder's, outside
// this proof (it is covered by the decode tests).
// rs1_data_in, rs2_data_in and, for the immediate forms, shamt are free: the
// properties hold for all operand values, every rotate amount and bit index.
//
// Encodings (defines/pipeline_status.sv): forwards VALID = 0, BUBBLE = 1;
// backwards READY = 0, STALL = 1, JUMP = 2.
// forwarding_out (defines/forwarding.sv): {data_valid[37], data[36:5], address[4:0]}.
//
//   X1  (forwarding, same cycle): while EXT instruction <id> is in Execute,
//       forwarding_out.data == f_spec_ext(id, rs1, rs2, shamt),
//       forwarding_out.data_valid == (status_forwards_in == VALID), and
//       forwarding_out.address == (VALID ? rd_address : 0).
//   X2  (result): if in cycle t (no reset) a VALID EXT instruction <id> leaves
//       Execute -- Memory READY and Execute not answering STALL -- then in t+1
//       rd_data_reg_out == f_spec_ext(id, ...) of cycle t and
//       status_forwards_out == VALID.
//   X3  (never stalls, never jumps): for an op::EXT instruction with ANY
//       immediate field, out of reset and with Memory READY, Execute answers
//       READY (neither STALL nor JUMP). With X2 this means every VALID EXT
//       instruction that Memory accepts leaves Execute in the same cycle with
//       the specified result.
//   EXT_COVER: non-vacuity -- each of the 45 instructions can leave Execute
//       VALID after a reset.
// Macros: EXT_RES with EXT_ID=<0..44> (X1 and X2), EXT_NOSTALL (X3), EXT_COVER.
// =============================================================================
module top (
    input         clk,
    input         rst,
    input  [31:0] rs1_data_in,
    input  [31:0] rs2_data_in,
    input  [64:0] instruction_in,
    input  [31:0] program_counter_in,
    input  [7:0]  bp_prediction_in,
    input  [3:0]  status_forwards_in,
    input  [1:0]  status_backwards_in,
    input  [31:0] jump_address_backwards_in
);
    wire [31:0] source_data_reg_out, rd_data_reg_out, program_counter_reg_out;
    wire [31:0] next_program_counter_reg_out, jump_address_backwards_out;
    wire [64:0] instruction_reg_out;
    wire [37:0] forwarding_out;
    wire [7:0]  bp_feedback_out;
    wire [3:0]  status_forwards_out;
    wire [1:0]  status_backwards_out;
    execute_stage dut (
        .clk(clk), .rst(rst),
        .rs1_data_in(rs1_data_in), .rs2_data_in(rs2_data_in),
        .instruction_in(instruction_in), .program_counter_in(program_counter_in),
        .source_data_reg_out(source_data_reg_out), .rd_data_reg_out(rd_data_reg_out),
        .instruction_reg_out(instruction_reg_out),
        .program_counter_reg_out(program_counter_reg_out),
        .next_program_counter_reg_out(next_program_counter_reg_out),
        .forwarding_out(forwarding_out),
        .bp_prediction_in(bp_prediction_in), .bp_feedback_out(bp_feedback_out),
        .status_forwards_in(status_forwards_in), .status_forwards_out(status_forwards_out),
        .status_backwards_in(status_backwards_in), .status_backwards_out(status_backwards_out),
        .jump_address_backwards_in(jump_address_backwards_in),
        .jump_address_backwards_out(jump_address_backwards_out));

    // {sel[5:0], use_imm} of the decoder's payload for instruction <id>
    // (defines/op.sv, op::ext_t; one line per instruction, read by scripts/ext_codes.py)
    function [6:0] f_ext_payload;
        input [5:0] id;
        begin
            case (id)
                6'd0:  f_ext_payload = {6'b0_000_00, 1'b0};  // andn       EXT_ANDN
                6'd1:  f_ext_payload = {6'b0_000_01, 1'b0};  // orn        EXT_ORN
                6'd2:  f_ext_payload = {6'b0_000_10, 1'b0};  // xnor       EXT_XNOR
                6'd3:  f_ext_payload = {6'b0_001_00, 1'b0};  // clz        EXT_CLZ
                6'd4:  f_ext_payload = {6'b0_001_01, 1'b0};  // ctz        EXT_CTZ
                6'd5:  f_ext_payload = {6'b0_001_10, 1'b0};  // cpop       EXT_CPOP
                6'd6:  f_ext_payload = {6'b0_010_10, 1'b0};  // max        EXT_MAX
                6'd7:  f_ext_payload = {6'b0_010_11, 1'b0};  // maxu       EXT_MAXU
                6'd8:  f_ext_payload = {6'b0_010_00, 1'b0};  // min        EXT_MIN
                6'd9:  f_ext_payload = {6'b0_010_01, 1'b0};  // minu       EXT_MINU
                6'd10: f_ext_payload = {6'b0_011_00, 1'b0};  // sext.b     EXT_SEXT_B
                6'd11: f_ext_payload = {6'b0_011_01, 1'b0};  // sext.h     EXT_SEXT_H
                6'd12: f_ext_payload = {6'b0_011_10, 1'b0};  // zext.h     EXT_ZEXT_H
                6'd13: f_ext_payload = {6'b0_100_00, 1'b0};  // rol        EXT_ROL
                6'd14: f_ext_payload = {6'b0_100_01, 1'b0};  // ror        EXT_ROR
                6'd15: f_ext_payload = {6'b0_100_01, 1'b1};  // rori       EXT_ROR imm
                6'd16: f_ext_payload = {6'b0_101_00, 1'b0};  // orc.b      EXT_ORC_B
                6'd17: f_ext_payload = {6'b0_101_01, 1'b0};  // rev8       EXT_REV8
                6'd18: f_ext_payload = {6'b0_110_00, 1'b0};  // bclr       EXT_BCLR
                6'd19: f_ext_payload = {6'b0_110_00, 1'b1};  // bclri      EXT_BCLR imm
                6'd20: f_ext_payload = {6'b0_110_01, 1'b0};  // bext       EXT_BEXT
                6'd21: f_ext_payload = {6'b0_110_01, 1'b1};  // bexti      EXT_BEXT imm
                6'd22: f_ext_payload = {6'b0_110_10, 1'b0};  // binv       EXT_BINV
                6'd23: f_ext_payload = {6'b0_110_10, 1'b1};  // binvi      EXT_BINV imm
                6'd24: f_ext_payload = {6'b0_110_11, 1'b0};  // bset       EXT_BSET
                6'd25: f_ext_payload = {6'b0_110_11, 1'b1};  // bseti      EXT_BSET imm
                6'd26: f_ext_payload = {6'b0_111_00, 1'b0};  // czero.eqz  EXT_CZERO_EQZ
                6'd27: f_ext_payload = {6'b0_111_01, 1'b0};  // czero.nez  EXT_CZERO_NEZ
                6'd28: f_ext_payload = {6'b1_000_00, 1'b0};  // pack        EXT_PACK
                6'd29: f_ext_payload = {6'b1_000_01, 1'b0};  // packh       EXT_PACKH
                6'd30: f_ext_payload = {6'b1_001_00, 1'b0};  // brev8       EXT_BREV8
                6'd31: f_ext_payload = {6'b1_001_01, 1'b0};  // zip         EXT_ZIP
                6'd32: f_ext_payload = {6'b1_001_10, 1'b0};  // unzip       EXT_UNZIP
                6'd33: f_ext_payload = {6'b1_010_00, 1'b0};  // xperm4      EXT_XPERM4
                6'd34: f_ext_payload = {6'b1_010_01, 1'b0};  // xperm8      EXT_XPERM8
                6'd35: f_ext_payload = {6'b1_011_00, 1'b0};  // sha256sig0  EXT_SHA256SIG0
                6'd36: f_ext_payload = {6'b1_011_01, 1'b0};  // sha256sig1  EXT_SHA256SIG1
                6'd37: f_ext_payload = {6'b1_011_10, 1'b0};  // sha256sum0  EXT_SHA256SUM0
                6'd38: f_ext_payload = {6'b1_011_11, 1'b0};  // sha256sum1  EXT_SHA256SUM1
                6'd39: f_ext_payload = {6'b1_100_00, 1'b0};  // sha512sig0h EXT_SHA512SIG0H
                6'd40: f_ext_payload = {6'b1_100_01, 1'b0};  // sha512sig0l EXT_SHA512SIG0L
                6'd41: f_ext_payload = {6'b1_100_10, 1'b0};  // sha512sig1h EXT_SHA512SIG1H
                6'd42: f_ext_payload = {6'b1_100_11, 1'b0};  // sha512sig1l EXT_SHA512SIG1L
                6'd43: f_ext_payload = {6'b1_101_00, 1'b0};  // sha512sum0r EXT_SHA512SUM0R
                6'd44: f_ext_payload = {6'b1_101_01, 1'b0};  // sha512sum1r EXT_SHA512SUM1R
                default: f_ext_payload = 7'b1111111;         // no instruction
            endcase
        end
    endfunction

    // is instruction_in the EXT instruction <id> (opcode op::EXT, decoder's payload)?
    function f_is_ext;
        input [5:0]  id;
        input [64:0] insn;
        reg   [6:0]  p;
        begin
            p = f_ext_payload(id);
            f_is_ext = insn[64:59] == 6'd61 && insn[31:12] == 20'd0 && insn[11:6] == p[6:1]
                       && insn[5] == p[0] && (p[0] || insn[4:0] == 5'd0);
        end
    endfunction

    reg a_init = 1'b1;
    always @(posedge clk) a_init <= 1'b0;

    // the instruction leaves Execute in this cycle
    wire a_leave = !rst && (status_forwards_in == 4'd0) && (status_backwards_in == 2'd0)
                   && (status_backwards_out != 2'd1);

`ifdef EXT_RES
`include "ext_spec.vh"
    wire        x_is   = f_is_ext(`EXT_ID, instruction_in);
    wire [31:0] x_spec = f_spec_ext(`EXT_ID, rs1_data_in, rs2_data_in, instruction_in[4:0]);

    reg        x_leave_q = 1'b0;
    reg [31:0] x_spec_q;
    always @(posedge clk) begin
        x_leave_q <= a_leave && x_is;
        x_spec_q  <= x_spec;
    end

    always @(*) begin
        if (x_is)                                                                        // X1
            assert(forwarding_out[36:5] == x_spec
                   && forwarding_out[37] == (status_forwards_in == 4'd0)
                   && forwarding_out[4:0] == ((status_forwards_in == 4'd0) ? instruction_in[58:54] : 5'd0));
        if (!a_init)                                                                     // X2
            assert(!x_leave_q || (rd_data_reg_out == x_spec_q && status_forwards_out == 4'd0));
    end
`endif

`ifdef EXT_NOSTALL
    always @(*)                                                                          // X3
        if (!rst && instruction_in[64:59] == 6'd61 && status_backwards_in == 2'd0)
            assert(status_backwards_out == 2'd0);
`endif

`ifdef EXT_COVER
    reg c_seen_rst = 1'b0;
    always @(posedge clk) if (rst) c_seen_rst <= 1'b1;
    genvar gi;
    for (gi = 0; gi < 45; gi = gi + 1) begin : g_cov
        always @(*) if (!a_init) cover(c_seen_rst && a_leave && f_is_ext(gi, instruction_in)
                                       && rs1_data_in != 32'd0 && rs2_data_in != 32'd0);
    end
`endif
endmodule
