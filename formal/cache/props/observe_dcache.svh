// SPDX-License-Identifier: MIT
// observe_dcache.svh -- formal/cache/run.sh inserts this file, as one include line, before the
// final endmodule of its copy of rtl/cache/dcache.sv (never into the source itself). It gives the
// properties the D-cache's state in fixed forms: the two states by name (the RTL's named
// constants, which the converted model shows only as numbers) and the width of the state
// register, the valid bits as a vector with bit k for set k (whether the design keeps them packed
// or unpacked), the beat counter and the refill line zero-extended, and the two signals the
// design names for the store rule: present (the presented address's line is valid with its tag)
// and st_accept (a store completes in this cycle).
    wire f_obs_lookup = state == LOOKUP;
    wire f_obs_refill = state == REFILL;
    wire [31:0] f_obs_state_bits = $bits(state);
    wire [BYTES/LINE_BYTES-1:0] f_obs_valid;
    for (genvar f_obs_k = 0; f_obs_k < BYTES/LINE_BYTES; f_obs_k++) begin : f_obs_valid_bits
        assign f_obs_valid[f_obs_k] = valid[f_obs_k];
    end
    wire [31:0] f_obs_beat        = 32'(beat);
    wire [31:0] f_obs_refill_line = 32'(refill_line);
    wire        f_obs_present     = present;
    wire        f_obs_st_accept   = st_accept;
