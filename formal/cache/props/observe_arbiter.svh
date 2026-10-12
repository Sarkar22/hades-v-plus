// SPDX-License-Identifier: MIT
// observe_arbiter.svh -- formal/cache/run.sh inserts this file, as one include line, before the
// final endmodule of its copy of rtl/cache/mem_arbiter.sv (never into the source itself). It names
// the three owners for the properties (the RTL's named constants, which the converted model shows
// only as numbers).
    wire f_obs_owner_none    = owner == NONE;
    wire f_obs_owner_data    = owner == DATA;
    wire f_obs_owner_irefill = owner == IREFILL;
