// SPDX-License-Identifier: MIT
// observe_icache.svh -- formal/cache/run.sh inserts this file, as one include line, before the
// final endmodule of its copy of rtl/cache/icache.sv (never into the source itself). It gives the
// properties the I-cache's state in fixed forms: the two states by name (sv2v replaces the
// enumeration names by numbers), the valid bits as a vector with bit k for set k (whether the
// design keeps them packed or unpacked), the beat counter and the refill line zero-extended.
    wire f_obs_lookup = state == LOOKUP;
    wire f_obs_refill = state == REFILL;
    wire [BYTES/LINE_BYTES-1:0] f_obs_valid;
    for (genvar f_obs_k = 0; f_obs_k < BYTES/LINE_BYTES; f_obs_k++) begin : f_obs_valid_bits
        assign f_obs_valid[f_obs_k] = valid[f_obs_k];
    end
    wire [31:0] f_obs_beat        = 32'(beat);
    wire [31:0] f_obs_refill_line = 32'(refill_line);
