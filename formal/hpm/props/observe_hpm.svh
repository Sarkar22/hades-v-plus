// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// observe_hpm.svh -- inserted by formal/hpm/scripts/model.py, as one include line, before the
// final endmodule of its copy of rtl/hpm.sv (never into the source itself). It exports the
// state of the counter unit under fixed names, which the properties read as u_hpm.f_obs_*:
//   f_obs_cnt  counter 3 + k at bits [k*64 +: 64], zero-extended to 64 bits (k < N; 0 above);
//   f_obs_sel  the event code of counter 3 + k at bits [k*8 +: 8] (k < N; 0 above);
//   f_obs_inh  the mcountinhibit register, 32 bits.
// It reads the unit's parameters N and W and its registers cnt, sel (arrays indexed 0 .. N-1
// for counters 3 .. 2+N) and inh. If the unit keeps its state under other names or in another
// layout, this file is the one place to change.
// ---------------------------------------------------------------------------------------------
    logic [7*64-1:0] f_obs_cnt;
    logic [7*8-1:0]  f_obs_sel;
    logic [31:0]     f_obs_inh;
    for (genvar f_obs_k = 0; f_obs_k < 7; f_obs_k++) begin : f_obs
        if (f_obs_k < N) begin : f_on
            assign f_obs_cnt[f_obs_k*64 +: 64] = 64'(cnt[f_obs_k]);
            assign f_obs_sel[f_obs_k*8 +: 8]   = sel[f_obs_k];
        end else begin : f_off
            assign f_obs_cnt[f_obs_k*64 +: 64] = 64'b0;
            assign f_obs_sel[f_obs_k*8 +: 8]   = 8'b0;
        end
    end
    assign f_obs_inh = inh;
