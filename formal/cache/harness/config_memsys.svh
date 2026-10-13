// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// config_memsys.svh -- the bounds of the memory system with both caches (formal/cache/README.md,
// section 10). Included after config.svh inside harness/memsys_top.sv, memsys_pair_top.sv,
// dcache_top.sv and arbiter_id_top.sv. Both caches have the sizes, lines and window of
// config.svh.
//
//   F_R    cycles a granted refill block takes (either cache): every beat a read of at most
//          F_MAX_WAIT wait cycles
//   F_WR   the longest wait of a write (F_MAX_WAIT_WR: 0 with FCACHE_WRITE_NOWAIT)
//   F_N_A  (a) a request at the D-cache's CPU port is answered by this cycle of its interval:
//          R + max(R + 1, WR). A load: its miss cycle leaves the port free, an I-refill granted in
//          it holds the port R cycles, then the D-refill R, then the second lookup (2R + 1). A
//          store: an I-refill granted earlier holds the port until cycle R - 1 at the latest, the
//          store is granted in R and answered by R + WR.
//   F_N_B  (b) an I-refill is granted by this cycle of its interval (CPU-like data side only):
//          max(K_OLDER * (WR + 1), R + 1). K_OLDER stores, the first in the I-miss cycle; or the
//          load in the Memory stage missing in the I-miss cycle itself, whose D-refill then wins
//          the port for R cycles and whose second lookup frees it in cycle R + 1.
//   (c), (e), (f) a granted I-refill ends, a D-refill is granted, a granted D-refill ends, each
//          within F_R cycles.
// ---------------------------------------------------------------------------------------------
    localparam int unsigned F_WR  = F_MAX_WAIT_WR;
    localparam int unsigned F_N_A = F_R + ((F_R + 1 > F_WR) ? F_R + 1 : F_WR);
    localparam int unsigned F_N_B = (F_KOLDER * (F_WR + 1) > F_R + 1) ? F_KOLDER * (F_WR + 1) : F_R + 1;
