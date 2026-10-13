// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// config.svh -- the two formal configurations of the I-cache harnesses (formal/cache/README.md).
// Included inside each harness module. Macros, set by formal/cache/run.sh:
//   FCACHE_SECOND  the second configuration: 32 bytes, 16-byte lines (two sets of four words),
//                  window [16, 32); default: the tiny one, 16 bytes, 8-byte lines (two sets of two
//                  words), window [8, 16). Both windows hold four lines, two per set, and leave
//                  addresses below and above them. Addresses are word addresses.
//   FCACHE_NARROW  the narrower memory of the fallback ladder: every transfer is answered after 0
//                  or 1 wait cycles (default: 0 to 2).
//   FCACHE_WRITE_NOWAIT  writes are answered without wait cycles (reads keep F_MAX_WAIT): the
//                  memory then has a read bound and a write bound (F_MAX_WAIT_WR = 0). Off by
//                  default; only the harness of both caches uses it (harness/memsys_top.sv).
// ---------------------------------------------------------------------------------------------
`ifdef FCACHE_SECOND
    localparam int unsigned F_BYTES        = 32;
    localparam int unsigned F_LINE_BYTES   = 16;
    localparam bit [31:0]   F_WINDOW_START = 32'd16;
    localparam bit [31:0]   F_WINDOW_WORDS = 32'd16;
`else
    localparam int unsigned F_BYTES        = 16;
    localparam int unsigned F_LINE_BYTES   = 8;
    localparam bit [31:0]   F_WINDOW_START = 32'd8;
    localparam bit [31:0]   F_WINDOW_WORDS = 32'd8;
`endif
`ifdef FCACHE_NARROW
    localparam int unsigned F_MAX_WAIT = 1;
`else
    localparam int unsigned F_MAX_WAIT = 2;
`endif
`ifdef FCACHE_WRITE_NOWAIT
    localparam int unsigned F_MAX_WAIT_WR = 0;            // the longest wait of a write
`else
    localparam int unsigned F_MAX_WAIT_WR = F_MAX_WAIT;
`endif
    localparam int unsigned F_LINE_WORDS = F_LINE_BYTES / 4;
    localparam int unsigned F_O          = $clog2(F_LINE_WORDS);   // word-in-line bits
    localparam int unsigned F_SETS       = F_BYTES / F_LINE_BYTES;
    localparam int unsigned F_I          = $clog2(F_SETS);         // index bits
    localparam int unsigned F_T          = 30 - F_I - F_O;         // tag bits
    // The memory's longest wait is the read, write and beat latency (there are no bursts here):
    // a granted data transfer takes at most F_D cycles, a granted refill at most F_R.
    localparam int unsigned F_D          = F_MAX_WAIT + 1;
    localparam int unsigned F_R          = F_LINE_WORDS * (F_MAX_WAIT + 1);
    // The CPU's older instructions that can still access data after a fetch misses.
    localparam int unsigned F_KOLDER     = 3;
