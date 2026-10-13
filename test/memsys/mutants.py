#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""mutants.py -- the mutation campaign of the memory system with an instruction cache and a data cache.

Every mutant is a source patch, applied to a temporary copy of the tree (never to this checkout),
with its own build directory. The check that must catch it runs in that copy and the mutant is
reported as CAUGHT or MISSED:

    python3 test/memsys/mutants.py list                  every mutant: class, file, primary check
    python3 test/memsys/mutants.py anchors [<name>...]   do the patches find their text in this tree?
    python3 test/memsys/mutants.py show <name>           the diff that a mutant applies
    python3 test/memsys/mutants.py run [<name>...|all] [--jobs N] [--out DIR] [--map] [--keep]
    python3 test/memsys/mutants.py dryrun [<name>...]    apply each patch in a temporary copy, check
                                                         that the copy still builds, and discard it
    python3 test/memsys/mutants.py apply [--src TREE] [--subset DIR,...] <name> <dir>
                                                         write a copy of the tree with one mutant applied
                                                         (formal/cache/run.sh uses it for its negative
                                                         controls)

ANCHORS. A patch is a list of (file, regular expression, replacement, expected number of matches);
a patch whose expression does not match exactly that often is not applied, and the mutant is
reported as 'ANCHOR MISSING' (never as CAUGHT or MISSED). The patches of the test programs, of
sim/slow_memory.sv's fetch and data instances and of the scoreboard in sim/top.sv are written
against the code as it is; the patches of the cache's RTL (rtl/cache/icache.sv,
rtl/cache/mem_arbiter.sv, the cached branch of rtl/mcu.sv, the TIMEOUT_EXEMPT parameter of
lib/wishbone/wishbone_interconnect.sv, PORT "memory" of sim/slow_memory.sv and the new monitors of
sim/top.sv) are written against the interfaces and the fixed names of the cache documentation
(icache: req, inwin, hit, state, beat, refill_line, valid, LOOKUP/REFILL, mem_cont, the snoop and
event ports; mem_arbiter: d_req, i_req, free, gd, gi, owner, NONE/DATA/IREFILL, the ports data,
irefill, mem). 'anchors' shows which of them match the tree; a mutant whose description below and
whose patch disagree with the code is fixed in this file, never by changing the design.

The mutants of the data cache (dcache.sv, the arbiter's data_cont, the data-cache events of the
counter block in rtl/mcu.sv) are the second half of the list; they are written against the interfaces and
the fixed names of the data cache (dcache: state, beat, refill_line, valid, present, st_accept, tag_ram,
lane[0..3].data_ram, mem_cont, the event ports ev_lookup_hit ... ev_refill), 'anchors' shows which of the
patches find their text in the tree, and the patches whose text differs from the RTL are fixed in this file.

CHECKS. The primary check of each mutant is one of:
    bench          the I-cache bench (make test/sv/test_icache): caught when it does not end with
                   'ICACHE BENCH: PASS' and exit status 0
    dbench         the same for the memory-system bench of both caches (make test/sv/test_dcache,
                   'DCACHE BENCH: PASS')
    bench-assert   the bench with +compare=0 (only the assertions inside the RTL can stop it):
                   caught when the named assertion's message appears (dbench-assert: the other bench)
    bench-message  the bench with the options of the row (+compare=bounds: only its answer bounds
                   are checked): caught when the named message of its own checks appears
                   (dbench-message: the other bench)
    programs       test/memsys/programs.py run in a configuration: caught when a HaDes-V+ run
                   differs otherwise, or any run is bad (scoreboard, simulator error, exit status)
    blinded        the same with the scoreboard's comparison of fetched words disabled (a patch of
                   sim/top.sv): caught when a HaDes-V+ program's own reports differ; every blinded
                   run must still say 'SCOREBOARD: PASS', otherwise the run is not valid. For the data
                   cache the comparison of loaded words is disabled instead ('blind': ['load']), and,
                   for a mutant that never writes the RAM (store-hit-skips-memory), the scoreboard's two
                   comparisons of the RAM with its copy and its fetch compare as well (['fetch', 'load',
                   'store']): they would stop the run before the program has judged anything
    identities     a system run of programs, caught when a CACHE_STATS identity of matrix.py does not hold
    assert         a system run that only the named check can stop: caught when its message appears
    sweep          test/trapsweep/sweep.py run in a configuration: caught when a HaDes-V+ program is
                   not ISS-consistent or a simulation stops with an error
    formal         a property of make formal-cache (formal/cache/run.sh --only <property> in the
                   tiny configuration, without its negative controls): caught when it fails
    port-identity  the port cycles of refills and data transfers of a cached run at MEM_LAT=2
                   MEM_BEAT_LAT=0 (port_irefill = 6 * i_done + i_inflight_port, port_data =
                   3 * (d_loads + d_stores) + d_inflight_port; with a data cache port_data =
                   6 * dc_done + 3 * d_stores + dc_inflight_port + d_inflight_port): caught when one
                   does not hold
                   (a run that stops before its CACHE_STATS line, by a bounded-answer assertion for example,
                   has not shown them and counts as caught, with the stop as the evidence)
    resets         the mid-run reset runs (matrix.py, leg 'resets'): caught as the row says
--map runs the negative controls of the run-time assertions (ASSERTION_MAP) as well; the bench's
own negative cases (+negative=<case>) are run by legality.py.

DRY RUN. 'dryrun' applies every patch to a temporary copy of the tree, checks that the copy still
builds (Verilator elaborates the simulator of the mutant's configuration with --lint-only, and the
I-cache bench when the patch is in rtl/cache; a patched program is assembled) and deletes the copy;
it reports the patches that find no anchor, and checks that the checkout itself is unchanged.
"""
import argparse
import concurrent.futures as cf
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.dont_write_bytecode = True

ICACHE, ARB, MCU = "rtl/cache/icache.sv", "rtl/cache/mem_arbiter.sv", "rtl/mcu.sv"
DCACHE = "rtl/cache/dcache.sv"
ICON, SLOW, TOP = "lib/wishbone/wishbone_interconnect.sv", "sim/slow_memory.sv", "sim/top.sv"
IRQCHAIN = "test/memsys/irqchain.s"

SMALL_LAT0, SMALL_LAT2, SMALL_BURST, SMALL_STRESS = ["ICACHE=512"], ["ICACHE=512", "MEM_LAT=2"], ["ICACHE=512", "MEM_LAT=1:8", "MEM_BEAT_LAT=0"], \
    ["ICACHE=512", "MEM_LAT=1:64"]
LARGE_LAT2 = ["ICACHE=8192", "MEM_LAT=2"]
LAT2, LAT18 = ["MEM_LAT=2"], ["MEM_LAT=1:8"]
# the configurations with both caches (512-byte instruction and data cache)
VD_LAT0, VD_LAT2, VD_BURST = ["ICACHE=512", "DCACHE=512"], ["ICACHE=512", "DCACHE=512", "MEM_LAT=2"], \
    ["ICACHE=512", "DCACHE=512", "MEM_LAT=1:8", "MEM_BEAT_LAT=0"]
VD_BURST0 = ["ICACHE=512", "DCACHE=512", "MEM_LAT=2", "MEM_BEAT_LAT=0"]
VD_STRESS = ["ICACHE=512", "DCACHE=512", "MEM_LAT=1:64"]
PD_GD = ["ICACHE=8192", "DCACHE=4096", "MEM_LAT=8:24", "MEM_WR_LAT=1:4", "MEM_BEAT_LAT=0"]


def added_logic(f, decl, body=""):
    """Patches that add a mutant's own signals to a module: their declarations right after the port
    list (so that nothing uses them before they are declared) and their logic before endmodule."""
    out = [(f, r"(?sm)\A(.*?^module\s+\w+.*?\);[ \t]*\n)", lambda m, d=decl: m.group(1) + d + "\n", 1)]
    if body:
        out.append((f, r"(?s)(.*)(\bendmodule\b)", lambda m, b=body: m.group(1) + b + "\n" + m.group(2), 1))
    return out


# The scoreboard's comparison of a fetched word with its copy, disabled (the blinded runs)
BLIND = [(TOP, r"else if \(mcu\.fetch_bus\.dat_miso != sb_mem\[a - RAM_START\]\)",
          "else if (1'b0 && mcu.fetch_bus.dat_miso != sb_mem[a - RAM_START])", 1)]
# The scoreboard's comparison of a loaded word with its copy, disabled (the blinded runs of the data cache);
# and its two comparisons of the RAM with its copy (after each store, at the end), for a mutant that never
# writes the RAM: the program's own checks then decide
BLIND_LOAD = [(TOP, r"if \(mcu\.mem_bus\.dat_miso != sb_mem\[a - RAM_START\]\)",
               "if (1'b0 && mcu.mem_bus.dat_miso != sb_mem[a - RAM_START])", 1)]
BLIND_STORE = [(TOP, r"if \(mcu\.ram\.memory\[a - RAM_START\] != w\)", "if (1'b0 && mcu.ram.memory[a - RAM_START] != w)", 1),
               (TOP, r"if \(mcu\.ram\.memory\[i\] != sb_mem\[i\]\) begin", "if (1'b0 && mcu.ram.memory[i] != sb_mem[i]) begin", 1)]
# For the two mutants whose wrong acknowledge falls on a fetch outside the window (no-second-lookup and
# latched-lookup: the cache acknowledges an address that the CPU presents as an error), the scoreboard's
# protocol checks of the fetch bus 'ack and err together' and 'ack outside the RAM' would stop the run
# before the directed test has judged anything, and so does the I-cache's own assertion of the same rule; the
# blinded runs of these two mutants disable all three (EXTRA_BLINDED, answers=True), so that fetchredirect.s is
# the only judge. A blinded run still has to end with SCOREBOARD: PASS.
BLIND_ANSWERS = [
    (TOP, r"if \(mcu\.fetch_bus\.ack && mcu\.fetch_bus\.err\)\n(\s+sb_stop\(\$sformatf\(\"fetch bus: ack and err together)",
     r"if (1'b0 && mcu.fetch_bus.ack && mcu.fetch_bus.err)\n\1", 1),
    (TOP, r"if \(!sb_in_ram\(a\)\)\n(\s+sb_stop\(\$sformatf\(\"fetch bus: ack for address)",
     r"if (1'b0 && !sb_in_ram(a))\n\1", 1),
    (ICACHE, r"if \(cpu\.ack && cpu\.err\)\n(\s+\$fatal\(1, \"icache: ack and err together on the fetch port)",
     r"if (1'b0 && cpu.ack && cpu.err)\n\1", 1),
]


BLINDS = {"fetch": (BLIND, "1'b0 && mcu.fetch_bus.dat_miso"),
          "answers": (BLIND_ANSWERS, "1'b0 && mcu.fetch_bus.ack && mcu.fetch_bus.err"),
          "load": (BLIND_LOAD, "1'b0 && mcu.mem_bus.dat_miso"),
          "store": (BLIND_STORE, "1'b0 && mcu.ram.memory[a - RAM_START]")}


def m(name, cls, what, patches, primary, also="", needs_anchor=True, d=False):
    """d: a mutant of the data cache's configurations (its simulator and bench are the ones with both caches)."""
    return dict(name=name, cls=cls, what=what, patches=patches, primary=primary, also=also, needs_anchor=needs_anchor, d=d)


# ---- the fetch port's wrapper (sim/slow_memory.sv, PORT "fetch"), for the uncached configurations
def abandoned_fetch(only_kth):
    count = """
    int unsigned mut_count, mut_k;
    initial begin
        mut_k = 1;
        void'($value$plusargs("mut_k=%d", mut_k));
    end""" if only_kth else ""
    cond = "mut_count + 1 == mut_k" if only_kth else "1'b1"
    inc = "\n                mut_count <= mut_count + 1;" if only_kth else ""
    return [(SLOW, r"    assign memory\.adr      = master\.adr;\n", f"""    // (mutation) an abandoned fetch: the next answer carries the word of the old, held address
    logic        mut_stale;
    logic [31:0] mut_stale_adr;{count}
    always @(posedge clk) begin
        if (rst)
            mut_stale <= 0;
        else if (PORT == "fetch" && held && request && !same) begin{inc}
            if ({cond}) begin
                mut_stale     <= 1;
                mut_stale_adr <= held_adr;
            end
        end
        else if (pass)
            mut_stale <= 0;
    end
    // (the substitution only for an address inside the RAM, so that err stays as it is)
    assign memory.adr      = (PORT == "fetch" && mut_stale && master.adr - RAM_START < RAM_WORDS) ? mut_stale_adr
                                                                                                 : master.adr;
""", 1)]


def word_store(entries):
    bits = entries.bit_length() - 1
    return [(SLOW, r"    assign master\.dat_miso = memory\.dat_miso;\n", f"""    // (mutation) a {entries}-entry direct-mapped store of fetched words, never told of stores
    bit [31:0] mut_tag  [{entries}];
    bit [31:0] mut_word [{entries}];
    bit        mut_valid[{entries}];
    wire [{bits - 1}:0] mut_i = master.adr[{bits - 1}:0];
    wire        mut_hit = PORT == "fetch" && mut_valid[mut_i] && mut_tag[mut_i] == master.adr;
    always @(posedge clk)
        if (PORT == "fetch" && master.cyc && master.stb && memory.ack && !mut_hit) begin
            mut_valid[mut_i] <= 1;
            mut_tag[mut_i]   <= master.adr;
            mut_word[mut_i]  <= memory.dat_miso;
        end
    assign master.dat_miso = mut_hit ? mut_word[mut_i] : memory.dat_miso;
""", 1)]


def handler_mepc(delta):
    return [(IRQCHAIN, r"\n6:\n    mret\n", f"\n6:\n    csrr s4, mepc\n    addi s4, s4, {delta}\n    csrw mepc, s4\n    mret\n", 1)]


SB_CORRUPT = [
    (TOP, r"(\n    always @\(posedge clk\) begin\n        bit \[31:0\] a, w;\n)",
     r"""
    // (mutation) the scoreboard corrupts its saved copy of a waiting data request once (+mut_k)
    int unsigned mut_waits, mut_k;
    initial begin
        mut_k = 1;
        void'($value$plusargs("mut_k=%d", mut_k));
    end
\1""", 1),
    (TOP, r"(\n            sb_wait_dat = mcu\.mem_bus\.dat_mosi;\n)",
     r"""\1            if (sb_wait) begin
                mut_waits++;
                if (mut_waits == mut_k)
                    sb_wait_adr = sb_wait_adr ^ 32'h1;
            end
""", 1)]

# ------------------------------------------------------------------------------ the mutants
MUTANTS = [
    m("no-snoop", "coherence", "The snoop never invalidates.",
      [(ICACHE, r"(assign\s+snoop_inval\s*=\s*)snoop_store\b", r"\g<1>1'b0 && snoop_store", 1)],
      dict(kind="blinded", config=SMALL_LAT2, only="memsys/icoherence$"),
      "scoreboard fetch compare; bench; formal properties of the cached word and of the stores"),
    m("no-second-lookup", "late ack",
      "After the last beat, the refilled word for the latched address is acknowledged in the next cycle whatever "
      "is presented (a registered ack of the refill's own word instead of a lookup of the presented address).",
      [*added_logic(ICACHE, """    // (mutation) acknowledge the refilled word of the missed address one cycle after the last beat
    logic       mut_after_fill;
    logic [5:0] mut_word;          // the missed address's word in its line""",
                    """    always_ff @(posedge clk) begin
        mut_after_fill <= !rst && ev_fill;
        if (miss) mut_word <= 6'(cpu.adr[O-1:0]);
    end"""),
       (ICACHE, r"assign\s+cpu\.ack\s*=\s*([^;]+);", r"assign cpu.ack = (\1) || mut_after_fill;", 1),
       (ICACHE, r"(\.a_adr\(\s*state\s*==\s*REFILL\s*\?\s*\{\s*refill_index\s*,\s*beat\s*\}\s*:\s*)(cpu\.adr\[|\{\s*cpu_index\s*,\s*cpu\.adr\[)",
        r"\1mut_after_fill ? {refill_index, mut_word[O-1:0]} : \2", 1)],
      dict(kind="bench"), "scoreboard (fetchredirect.s); fetchredirect.s blinded; formal (the acknowledged word)"),
    m("latched-lookup", "late ack", "In the second-lookup cycle the hit is computed for the latched address "
      "(refill_line) instead of the presented one.",
      [*added_logic(ICACHE, """    // (mutation) the first lookup after a refill compares the latched line
    logic mut_second;""", """    always_ff @(posedge clk) mut_second <= !rst && ev_fill;"""),
       (ICACHE, r"(assign\s+hit\s*=\s*)([^;]+);", r"\1mut_second ? (req && valid[refill_line[I-1:0]]) : (\2);", 1)],
      dict(kind="bench"), "as no-second-lookup"),
    m("ignore-valid", "valid", "The hit ignores the valid bit.",
      [(ICACHE, r"(assign\s+hit\s*=[^;]*?)valid\[[^\]]+\]\s*&&\s*", r"\1", 1)],
      dict(kind="bench"), "scoreboard at the small cache, latency 0 (random tags from the window); formal"),
    m("reset-keeps-valid", "reset", "The reset leaves the valid bits as they are.",
      [(ICACHE, r"valid\s*<=\s*'0\s*;", "valid <= valid;", 1)],
      dict(kind="bench"), "formal (the state after a reset); not visible at system level"),
    m("no-window-check", "window", "No err for fetches outside the window: they are looked up and refilled.",
      [(ICACHE, r"(assign\s+inwin\s*=)[^;]*;", r"\1 1'b1;", 1)],
      dict(kind="sweep", config=SMALL_LAT2, fam="window"),
      "scoreboard (ack outside the RAM); bench; formal; the default ctl family's probe at 0x48000"),
    m("grant-free-between-beats", "arbiter", "The port is free after every beat of a refill: in the cycle after an "
      "answered beat the data side is granted if it requests.",
      [*added_logic(ARB, """    // (mutation) the port is free after every answered refill beat
    logic mut_beat_done;""", """    always_ff @(posedge clk) mut_beat_done <= !rst && gi && mem.ack;"""),
       (ARB, r"(assign\s+free\s*=\s*)([^;]+);", r"\1(\2) || (owner == IREFILL && mut_beat_done && d_req);", 1),
       (ARB, r"(assign\s+gi\s*=\s*)([^;]+);",
        r"\1i_req && ((owner == IREFILL && !(mut_beat_done && d_req)) || (free && !d_req));", 1)],
      dict(kind="bench"), "formal (cached word, no write during a refill, grants); the no-write-during-refill "
      "assertion; bounded answer of a granted refill"),
    m("answer-to-any-side", "arbiter", "The memory's answer (ack, err, dat_miso) goes to every slave side whose cyc "
      "is 1, regardless of the grant and of stb.",
      [(ARB, r"(assign\s+data\.ack\s*=\s*)gd\b", r"\1data.cyc", 1),
       (ARB, r"(assign\s+data\.err\s*=\s*)gd\b", r"\1data.cyc", 1),
       (ARB, r"(assign\s+data\.dat_miso\s*=\s*)gd\b", r"\1data.cyc", 1),
       (ARB, r"(assign\s+irefill\.ack\s*=\s*)gi\b", r"\1irefill.cyc", 1),
       (ARB, r"(assign\s+irefill\.err\s*=\s*)gi\b", r"\1irefill.cyc", 1),
       (ARB, r"(assign\s+irefill\.dat_miso\s*=\s*)gi\b", r"\1irefill.cyc", 1)],
      dict(kind="bench"), "scoreboard at the small cache, latency 0; formal; the arbiter's answer-only-with-request "
      "assertion on its data port (bench with +compare=0)"),
    m("snoop-wrong-index", "coherence", "The snoop's index bits are shifted by one.",
      [(ICACHE, r"snoop_adr\[\s*O\s*\+\s*I\s*-\s*1\s*:\s*O\s*\]", "snoop_adr[O+I:O+1]", 2)],
      dict(kind="blinded", config=SMALL_LAT2, only="memsys/icoherence$"), "bench; formal (stores)"),
    m("snoop-no-tag-compare", "performance", "Any valid line of the snooped set is invalidated (no tag compare).",
      [(ICACHE, r"(snoop_store\s*&&\s*valid\[\w+\])\s*&&\s*tag_b_rdata\s*==\s*snoop_adr\[[^\]]*\]", r"\1", 1)],
      dict(kind="bench"), "not functional: no correctness check can see it"),
    m("refill-word-off-by-one", "refill", "Refill beat k is written to word k+1 (the data array's address in REFILL).",
      [(ICACHE, r"\{\s*refill_index\s*,\s*beat\s*\}", r"{refill_index, beat + 1'b1}", 1)],
      dict(kind="programs", config=SMALL_LAT0, only=""), "bench; formal"),
    m("refill-first", "performance", "Priority inverted: the I-refill wins when both sides request.",
      [(ARB, r"(assign\s+gd\s*=\s*)([^;]+);", r"\1d_req && (owner == DATA || (free && !i_req));", 1),
       (ARB, r"(assign\s+gi\s*=\s*)([^;]+);", r"\1i_req && (owner == IREFILL || free);", 1)],
      dict(kind="bench"), "not functional"),
    m("ram-not-exempt", "exemption", "TIMEOUT_EXEMPT bit 0 is not set in the cached branch of rtl/mcu.sv.",
      [(MCU, r"\.TIMEOUT_EXEMPT\(9'b0_0000_0001\)", ".TIMEOUT_EXEMPT(9'b0_0000_0000)", 1)],
      dict(kind="assert", config=["ICACHE=512", "MEM_LAT=64"], only="memsys/(stores|irqchain)$",
           message=r"interconnect timeout at cycle \d+ on a RAM access"),
      "the formal proof with the mask of rtl/mcu.sv; the programs at the small cache under the stress profile"),
    m("all-exempt", "exemption", "TIMEOUT_EXEMPT all ones: I/O loses its timeout.",
      [(MCU, r"\.TIMEOUT_EXEMPT\(9'b0_0000_0001\)", ".TIMEOUT_EXEMPT(9'b1_1111_1111)", 1)],
      dict(kind="formal", prop="ic_io_timeout"), ""),
    m("ack-in-refill", "refill", "ack also in REFILL: the hit is not gated by the state.",
      [(ICACHE, r"(assign\s+cpu\.ack\s*=\s*)\(?\s*state\s*==\s*LOOKUP\s*\)?\s*&&\s*", r"\1", 1)],
      dict(kind="programs", config=SMALL_LAT0, only=""), "bench; formal"),
    m("store-sel-forced", "pass-through", "sel is not passed through on data writes (forced to 1111).",
      [(ARB, r"(assign\s+mem\.sel\s*=[^;]*?)\bdata\.sel\b", r"\1(data.we ? 4'b1111 : data.sel)", 1)],
      dict(kind="programs", config=SMALL_LAT0, only="memsys/stores$"), "bench; formal (exactly one write per store)"),
    m("fill-event-every-beat", "events", "ev_fill on every beat.",
      [(ICACHE, r"(assign\s+ev_fill\s*=)[^;]*;", r"\1 ev_beat;", 1)],
      dict(kind="bench"), "the CACHE_STATS identity i_refills = i_done + i_inflight; cachemodel.py rtlcheck"),
    m("cont-on-first-beat", "wrapper tag", "mem_cont also on beat 0 of a refill.",
      [(ICACHE, r"(assign\s+mem_cont\s*=)[^;]*;", r"\1 (state == REFILL);", 1)],
      dict(kind="assert", config=SMALL_BURST, only="", message=r"slow_memory: memory port: block_cont = 1 at cycle"),
      "the port identity at MEM_BEAT_LAT=0 (port_irefill); bench"),
    m("narrow-tag", "tags", "The tag compare uses only the tag bits that the RAM window needs (adr[16:O+I] with the "
      "32 KiB window).",
      [(ICACHE, r"(assign\s+hit\s*=[^;]*?)\btag_a_rdata\s*==\s*cpu_tag\b",
        r"\1tag_a_rdata[MUT_NARROW-1:0] == cpu_tag[MUT_NARROW-1:0]", 1),
       *added_logic(ICACHE, """    // (mutation) the tag bits below the top of the RAM window only (O + I = log2(BYTES / 4))
    localparam int MUT_NARROW = $clog2(WINDOW_START + WINDOW_WORDS) - $clog2(BYTES / 4);""", """""")],
      dict(kind="sweep", config=SMALL_LAT2, fam="window"),
      "the probe at 0xC0000 at the large cache; bench; formal; the I-cache's ack-and-err assertion"),
    m("ack-without-request", "protocol", "The hit is not gated by req (cyc && stb).",
      [(ICACHE, r"(assign\s+hit\s*=\s*)req\s*&&\s*", r"\1", 1)],
      dict(kind="bench"), "formal; the I-cache's answer-only-with-request assertion"),
    m("grant-never-released", "arbiter, deadlock", "After an I-refill block the owner stays IREFILL until the "
      "I-cache requests again: no free port for the data side after a refill, and the owner kept when nothing is "
      "granted.",
      [(ARB, r"(assign\s+free\s*=\s*)([^;]+);", r"\1(owner == NONE);", 1),
       (ARB, r"(else\s+)owner\s*<=\s*NONE\s*;", r"\1owner <= owner;", 1)],
      dict(kind="bench"), "formal (bounded response); bounded-answer assertion (a); +timeout"),
    m("refill-follows-cpu-adr", "refill", "The refill beat address takes its line from the presented address "
      "instead of refill_line.",
      [(ICACHE, r"(assign\s+mem\.adr\s*=\s*\{[^}]*?)\brefill_line\b", r"\1cpu.adr[29:O]", 1)],
      dict(kind="bench"), "formal; scoreboard (fetchredirect.s)"),
    m("data-dependent-hit", "data dependence", "A lookup whose cached word has a zero lowest byte is treated as a miss.",
      [(ICACHE, r"(assign\s+hit\s*=\s*)([^;]+);", r"\1(\2) && cpu.dat_miso[7:0] != 8'h00;", 1)],
      dict(kind="formal", prop="data_indep"), "bench"),
    m("snoop-full-words-only", "coherence", "The snoop acts only on stores with sel = 1111.",
      [(MCU, r"(\.snoop_store\s*\(\s*mem_bus_slaves\[0\]\.cyc[^)]*?mem_bus_slaves\[0\]\.ack)",
        r"\1 && mem_bus_slaves[0].sel == 4'b1111", 1)],
      dict(kind="blinded", config=SMALL_LAT2, only="memsys/icoherence$"), "bench; formal (stores)"),
    m("snoop-late", "coherence", "The snoop invalidates one cycle after the store's acknowledge (snoop_store and "
      "snoop_adr registered inside the I-cache).",
      [*added_logic(ICACHE, """    // (mutation) the snoop one cycle late
    logic        mut_snoop_store;
    logic [31:0] mut_snoop_adr;""", """    always_ff @(posedge clk) begin
        mut_snoop_store <= !rst && snoop_store;
        mut_snoop_adr   <= snoop_adr;
    end"""),
       (ICACHE, r"(\.b_adr\(\s*)snoop_adr\[", r"\1mut_snoop_adr[", 1),
       (ICACHE, r"(assign\s+snoop_index\s*=\s*)snoop_adr\[", r"\1mut_snoop_adr[", 1),
       (ICACHE, r"(assign\s+snoop_inval\s*=\s*)snoop_store(\s*&&[^;]*?==\s*)snoop_adr\[",
        r"\1mut_snoop_store\2mut_snoop_adr[", 1)],
      dict(kind="programs", config=SMALL_LAT0, only="memsys/icoherence$"),
      "bench; formal; the timing bench of the staleness window (sw+16 NEW)"),
    m("second-snoop-lost", "coherence", "Of two stores acknowledged in consecutive cycles, the second is not snooped.",
      [(ICACHE, r"(assign\s+snoop_inval\s*=\s*)snoop_store\b", r"\1snoop_store && !mut_prev_snoop", 1),
       *added_logic(ICACHE, """    // (mutation) the second of two back-to-back snoops is lost
    logic mut_prev_snoop;""", """    always_ff @(posedge clk) mut_prev_snoop <= !rst && snoop_store && !mut_prev_snoop;""")],
      dict(kind="blinded", config=SMALL_LAT0, only="memsys/icoherence$"), "bench; formal (stores)"),
    m("data-burst", "wrapper", "The wrapper ignores block_cont: the burst discount also applies to data transfers.",
      [(SLOW, r"(beat\s*=\s*beat_lat\s*>=\s*0)\s*&&\s*block_cont\b", r"\1", 1)],
      dict(kind="port-identity", config=["ICACHE=512", "MEM_LAT=2", "MEM_BEAT_LAT=0"], only="memsys/stores$"),
      "bench (system profile)"),
    m("cont-low", "wrapper tag", "mem_cont stays 0 on beats 1 to LINE_WORDS - 1.",
      [(ICACHE, r"(assign\s+mem_cont\s*=)[^;]*;", r"\1 1'b0;", 1)],
      dict(kind="port-identity", config=["ICACHE=512", "MEM_LAT=2", "MEM_BEAT_LAT=0"], only="memsys/stores$"),
      "bench (mem_cont compared)"),
    m("reset-keeps-state", "reset", "The reset clears the valid bits but not state and beat.",
      [(ICACHE, r"(\bif\s*\(\s*rst\s*\)\s*begin(?:(?!\bend\b).)*?)\bstate\s*<=\s*LOOKUP\s*;", r"\1", 1),
       (ICACHE, r"(\bif\s*\(\s*rst\s*\)\s*begin(?:(?!\bend\b).)*?)\bbeat\s*<=\s*[^;]+;", r"\1", 1)],
      dict(kind="bench"), "formal (the state after a reset); the reset runs"),
    m("stats-not-restarted", "testbench", "The CACHE_STATS counters of sim/top.sv do not restart at a reset.",
      [(TOP, r"(?s)(\bif\s*\(\s*mcu\.rst\s*\)\s*begin\s*\n)\s*cs_cycles\s*=\s*0\s*;.*?(\n\s*end\s*\n\s*else\s+begin\s*\n\s*cs_cycles\+\+;)",
        r"\1            // (mutation) the counters keep their values across a reset\2", 1)],
      dict(kind="resets", leg="resets", job=r"^resets/i512-lat2$", message=r"CACHE_STATS identity: cycles="), ""),
    m("event-feeds-back", "events", "ev_hit is used inside the I-cache: after a hit the next miss starts its refill "
      "one cycle later.",
      [*added_logic(ICACHE, """    // (mutation) an event read back inside the design
    logic mut_hit_q;""", """    always_ff @(posedge clk) mut_hit_q <= !rst && ev_hit;"""),
       (ICACHE, r"(assign\s+miss\s*=\s*)([^;]+);", r"\1(\2) && !mut_hit_q;", 1)],
      dict(kind="bench"), "review (no event is read inside the design)"),
    m("write-replay", "pass-through", "The arbiter presents an answered data write to the memory once more in the "
      "next cycle.",
      [*added_logic(ARB, """    // (mutation) an answered write is presented once more
    logic        mut_replay;
    logic [31:0] mut_adr, mut_dat;
    logic  [3:0] mut_sel;""", """    always_ff @(posedge clk) begin
        mut_replay <= !rst && gd && data.we && mem.ack;
        mut_adr    <= data.adr;
        mut_dat    <= data.dat_mosi;
        mut_sel    <= data.sel;
    end"""),
       (ARB, r"(assign\s+mem\.cyc\s*=\s*)([^;]+);", r"\1mut_replay || (\2);", 1),
       (ARB, r"(assign\s+mem\.stb\s*=\s*)([^;]+);", r"\1mut_replay || (\2);", 1),
       (ARB, r"(assign\s+mem\.we\s*=\s*)([^;]+);", r"\1mut_replay || (\2);", 1),
       (ARB, r"(assign\s+mem\.adr\s*=\s*)([^;]+);", r"\1mut_replay ? mut_adr : (\2);", 1),
       (ARB, r"(assign\s+mem\.sel\s*=\s*)([^;]+);", r"\1mut_replay ? mut_sel : (\2);", 1),
       (ARB, r"(assign\s+mem\.dat_mosi\s*=\s*)([^;]+);", r"\1mut_replay ? mut_dat : (\2);", 1)],
      dict(kind="assert", config=SMALL_LAT0, only="memsys/stores$",
           message=r"mem_arbiter: the memory answered at cycle \d+ .*no side is granted|SCOREBOARD: FAIL"),
      "formal (exactly one write per store); bench"),
    m("sb-wait-kept", "testbench", "The scoreboard keeps sb_wait across a reset (the behaviour before its reset "
      "handling).",
      [(TOP, r"\bif\s*\(\s*mcu\.rst\s*\)\s*sb_wait\s*=\s*(?:1'b)?0\s*;", "/* (mutation) sb_wait kept */", 1)],
      dict(kind="resets", leg="resets", job=r"^resets/i512-lat2$", message=r"changed before its answer"), "",
      needs_anchor=True),
    m("sb-request-corrupted", "testbench", "The scoreboard corrupts its saved copy of a waiting data request once "
      "(+mut_k, default the first waiting request).", SB_CORRUPT,
      dict(kind="assert", config=SMALL_LAT2, only="memsys/stores$", message=r"SCOREBOARD: FAIL .*changed before its answer"),
      "", needs_anchor=False),
    m("refill-never-ends", "deadlock", "After the last beat the I-cache stays in REFILL and refills the line again.",
      [(ICACHE, r"(?s)(\bif\s*\(\s*beat_answered\s*\).*?)\bstate\s*<=\s*LOOKUP\s*;", r"\1state <= REFILL;", 1)],
      dict(kind="assert", config=SMALL_LAT2, only="", message=r"bounded answer \(d\)"),
      "bench; formal (bounded response); +timeout"),
    m("i-side-starved", "arbiter", "An I-refill is granted only in a cycle that follows a cycle in which the port "
      "was idle.",
      [*added_logic(ARB, """    // (mutation) an I-refill only after an idle port cycle
    logic mut_idle_q;""", """    always_ff @(posedge clk) mut_idle_q <= rst || !(gd || gi);"""),
       (ARB, r"(assign\s+gi\s*=\s*)([^;]+);", r"\1(\2) && (owner == IREFILL || mut_idle_q);", 1)],
      dict(kind="bench"), "formal (bounded response)"),
    m("interconnect-default-exempt", "exemption", "The default of TIMEOUT_EXEMPT is all ones.",
      [(ICON, r"(TIMEOUT_EXEMPT\s*=\s*)'0", r"\1'1", 1)],
      dict(kind="formal", prop="ic_default"), ""),
    m("irefill-answer-by-owner", "arbiter", "The arbiter also routes the memory's answer to the I-side when owner == "
      "IREFILL: irefill.ack = (gi || owner == IREFILL) && mem.ack, and err and dat_miso likewise. It differs from the "
      "design only in the second-lookup cycle, in which the I-side owns the port without requesting.",
      [(ARB, r"(assign\s+irefill\.ack\s*=\s*)gi\b", r"\1(gi || owner == IREFILL)", 1),
       (ARB, r"(assign\s+irefill\.err\s*=\s*)gi\b", r"\1(gi || owner == IREFILL)", 1),
       (ARB, r"(assign\s+irefill\.dat_miso\s*=\s*)gi\b", r"\1(gi || owner == IREFILL)", 1)],
      dict(kind="assert", config=SMALL_LAT0, only="memsys/stores$", message=r"mem_arbiter: an answer without cyc && stb on the refill port",
           evidence=r"wait_d_for_port=([1-9]\d*)"),
      "bench (the I-side's ack compared every cycle); the same assertion in the bench with +compare=0; formal"),
    # the mutants of the fetch port's wrapper and of irqchain.s, in the uncached configurations
    m("abandoned-fetch-answer", "late ack", "When the presented fetch address changes while a read is held (an "
      "abandoned fetch), the next answer carries the word of the old, held address; once per abandoned fetch.",
      abandoned_fetch(False), dict(kind="blinded", config=LAT2, only="memsys/fetchredirect$", also_config=LAT18),
      "scoreboard fetch compare", needs_anchor=False),
    m("one-abandoned-fetch", "late ack", "As abandoned-fetch-answer, but only for the k-th abandoned fetch of the run "
      "(+mut_k=k, default 1).",
      abandoned_fetch(True), dict(kind="blinded", config=LAT2, only="memsys/fetchredirect$", also_config=LAT18),
      "scoreboard fetch compare", needs_anchor=False),
    m("fetch-word-cache-64", "coherence", "A 64-entry direct-mapped word store in the fetch wrapper, filled by fetches "
      "and never told of stores: a fetch that hits it returns the stored word even if a store changed the RAM since.",
      word_store(64), dict(kind="blinded", config=LAT2, only="memsys/icoherence$", also_config=LAT18),
      "scoreboard fetch compare", needs_anchor=False),
    m("fetch-word-cache-1024", "coherence", "As fetch-word-cache-64 with 1024 entries (4 KiB).",
      word_store(1024), dict(kind="blinded", config=LAT2, only="memsys/icoherence$", also_config=LAT18),
      "scoreboard fetch compare", needs_anchor=False),
    m("handler-mepc-plus4", "interrupts", "irqchain.s's handler adds 4 to mepc before mret (read, add, write back "
      "through a handler scratch register).",
      handler_mepc(4), dict(kind="blinded", config=LAT2, only="memsys/irqchain$", also_config=SMALL_LAT2), "",
      needs_anchor=False),
    m("handler-mepc-minus4", "interrupts", "As handler-mepc-plus4 with -4.",
      handler_mepc(-4), dict(kind="blinded", config=LAT2, only="memsys/irqchain$", also_config=SMALL_LAT2), "",
      needs_anchor=False),
]

# ------------------------------------------------------------------------------ the data cache's mutants
# The lines of rtl/cache/dcache.sv and rtl/cache/mem_arbiter.sv that the patches expect (the names of the
# data cache are the fixed ones: state, beat, refill_line, valid, present, st_accept, tag_ram and the
# four byte lanes lane[0..3], each with a data_ram; the rest follows the instruction cache's style):
#   assign present = valid[cpu_index] && tag_a_rdata == cpu_tag;
#   assign load_hit = state == LOOKUP && req && !cpu.we && present;   (load_miss: the same with !present)
#   assign st_accept = state == LOOKUP && req && cpu.we && mem.ack;
#   assign cpu.ack = load_hit || st_accept;
#   the write enable of lane k: ... st_accept && present && cpu.sel[k] ...
#   the tag array: .a_we(fill && !rst) and .a_wdata(refill_tag)
#   assign mem.cyc/stb = state == REFILL || store_req;   (store_req = state == LOOKUP && req && cpu.we)
#   assign mem.adr = state == REFILL ? {2'b00, refill_line, beat} : store_req ? cpu.adr : 32'h0;
#   assign mem_cont = state == REFILL && beat != '0;
#   assign ev_lookup_hit = !rst && cpu.ack && !cpu.we; assign ev_store_hit = !rst && st_accept && present; ...
#   the reset branch: state <= LOOKUP; beat <= '0; valid <= '0;
LANE_WE = r"(st_accept\s*&&\s*present\s*&&\s*)cpu\.sel\[(\w+)\]"
D_MUTANTS = [
    m("drop-lane-enable", "store lanes", "Lane 2's write enable on store hits is never set.",
      [(DCACHE, LANE_WE, r"\1cpu.sel[\2] && \2 != 2", 1)],
      dict(kind="dbench"), "scoreboard (dcache.s); formal dline_data; dcache.s with the load compare blinded", d=True),
    m("valid-on-store-miss", "store miss", "A store miss writes the selected lanes and the tag and sets valid, without a "
      "refill.",
      [*added_logic(DCACHE, """    // (mutation) a store miss marks its set valid
    logic [SETS-1:0] mut_av;""", """    always_ff @(posedge clk) begin
        if (rst)
            mut_av <= '0;
        else begin
            if (st_accept && !present)
                mut_av[cpu_index] <= 1'b1;
            if (load_miss)
                mut_av[cpu_index] <= 1'b0;
        end
    end"""),
       (DCACHE, LANE_WE, r"st_accept && cpu.sel[\2]", 1),
       (DCACHE, r"(\.a_we\()\s*fill\s*&&\s*!rst\s*(\))", r"\1(fill || (st_accept && !present)) && !rst\2", 1),
       (DCACHE, r"(\.a_wdata\()\s*refill_tag\s*(\))", r"\1(st_accept && !present) ? cpu_tag : refill_tag\2", 1),
       (DCACHE, r"(assign\s+present\s*=\s*)valid\[([^\]]+)\]", r"\1(valid[\2] || mut_av[\2])", 1)],
      dict(kind="dbench"), "formal load_data; dcache.s with the load compare blinded", d=True),
    m("store-hit-skips-memory", "store hit", "A store hit is acknowledged at once and written into the lanes without a "
      "memory write.",
      [(DCACHE, r"(assign\s+st_accept\s*=\s*)([^;]+);", r"\1(state == LOOKUP && req && cpu.we && (present || mem.ack));", 1),
       (DCACHE, r"(assign\s+mem\.cyc\s*=\s*)([^;]+);", r"\1(\2) && !(state == LOOKUP && req && cpu.we && present);", 1),
       (DCACHE, r"(assign\s+mem\.stb\s*=\s*)([^;]+);", r"\1(\2) && !(state == LOOKUP && req && cpu.we && present);", 1)],
      dict(kind="formal", prop="store_mem"),
      "the scoreboard's comparison of the RAM with its copy; dcache.s with the scoreboard's compares blinded "
      "(store, evict, reload)", d=True),
    m("ignore-valid-data", "valid", "The D hit ignores valid.",
      [(DCACHE, r"(assign\s+present\s*=\s*)valid\[[^\]]+\]\s*&&\s*", r"\1", 1)],
      dict(kind="dbench"),
      "scoreboard (all programs, VD, latency 0); formal load_data", d=True),
    m("forward-memory-ack", "late ack", "Every mem.ack is passed to a presented request: a refill beat answers the held "
      "load (the memory's ack forwarded to whatever request is presented).",
      [(DCACHE, r"(assign\s+cpu\.ack\s*=\s*)([^;]+);", r"\1(\2) || (req && mem.ack);", 1)],
      dict(kind="programs", config=VD_LAT0, only=""), "bench; formal load_data and dack_req", d=True),
    m("data-refill-word-off-by-one", "refill", "Beat k of a D-refill is written to word k + 1.",
      [(DCACHE, r"\{\s*refill_index\s*,\s*beat\s*\}", r"{refill_index, beat + 1'b1}", 1)],
      dict(kind="programs", config=VD_LAT0, only=""), "bench; formal dline_data", d=True),
    m("store-writes-all-lanes", "store lanes", "A store hit writes all four lanes.",
      [(DCACHE, LANE_WE, r"\1 1'b1", 1)],
      dict(kind="blinded", blind=["load"], config=VD_LAT0, only="memsys/dcache$"), "scoreboard; bench", d=True),
    m("data-ack-in-refill", "refill", "The D load hit is not gated by LOOKUP.",
      [(DCACHE, r"(assign\s+load_hit\s*=\s*)state\s*==\s*LOOKUP\s*&&\s*", r"\1", 1)],
      dict(kind="dbench"), "formal dack_req (invisible with a CPU: the held load's line is invalid)",
      d=True),
    m("data-refill-follows-cpu-adr", "refill", "The D-refill beat address takes its line from the presented address "
      "instead of refill_line.",
      [(DCACHE, r"(\{\s*2'b00\s*,\s*)refill_line\b", r"\1cpu.adr[29:O]", 1)],
      dict(kind="dbench"), "formal dwindow and drefill_stable", d=True),
    m("data-refill-gap", "refill", "The D-cache drops its request for a cycle after each answered beat of a refill.",
      [*added_logic(DCACHE, """    // (mutation) no request in the cycle after an answered refill beat
    logic mut_gap;""", """    always_ff @(posedge clk) mut_gap <= !rst && state == REFILL && mem.ack && beat != LAST_BEAT;"""),
       (DCACHE, r"(assign\s+mem\.cyc\s*=\s*)([^;]+);", r"\1(\2) && !mut_gap;", 1),
       (DCACHE, r"(assign\s+mem\.stb\s*=\s*)([^;]+);", r"\1(\2) && !mut_gap;", 1)],
      dict(kind="dbench-assert", message=r"mem_arbiter: a continuing data beat was not granted"),
      "the wrapper's block_cont check (VD, burst profile); formal dfill_kept; bound (f)", d=True),
    m("refill-beats-continuing-data", "arbiter", "The arbiter grants an I-refill over a continuing data beat.",
      [(ARB, r"(assign\s+gd\s*=\s*)([^;]+);", r"\1d_req && (owner == DATA || (free && !(i_req && data_cont)));", 1),
       (ARB, r"(assign\s+gi\s*=\s*)([^;]+);", r"\1i_req && (owner == IREFILL || (free && (!d_req || data_cont)));", 1)],
      dict(kind="formal", prop="dfill_kept"),
      "the arbiter's continuing-beat assertion; the bench with +compare=bounds (bound (e))", d=True),
    m("data-cont-on-first-beat", "wrapper tag", "mem_cont also on beat 0 of a D-refill.",
      [(DCACHE, r"(assign\s+mem_cont\s*=)[^;]*;", r"\1 (state == REFILL);", 1)],
      dict(kind="assert", config=VD_BURST, only="memsys/dcache$", message=r"slow_memory: memory port: block_cont = 1 at cycle"),
      "bench", d=True),
    m("data-cont-ignored", "arbiter", "The arbiter's mem_cont ignores data_cont.",
      [(ARB, r"(assign\s+mem_cont\s*=\s*)[^;]*;", r"\1gi && irefill_cont;", 1)],
      dict(kind="port-identity", config=VD_BURST0, only="memsys/dcache$"),
      "bound (f) first, where it stops the run (bench with +compare=bounds)", d=True),
    m("data-always-continues", "arbiter", "mem_cont = (gi && irefill_cont) || gd: every data transfer is tagged as "
      "continuing.",
      [(ARB, r"(assign\s+mem_cont\s*=\s*)[^;]*;", r"\1(gi && irefill_cont) || gd;", 1)],
      dict(kind="formal", prop="arb_equiv"), "the wrapper's block_cont check (VD, burst profile)", d=True),
    m("data-events-in-reset", "events", "A D-cache event is not forced to 0 in reset.",
      [(DCACHE, r"(assign\s+ev_lookup_hit\s*=\s*)!rst\s*&&\s*", r"\1", 1)],
      dict(kind="dbench"), "", d=True),
    m("store-event-every-wait-cycle", "events", "The store hit and miss events fire in every cycle of a store, not only "
      "in the cycle it is accepted.",
      [(DCACHE, r"(assign\s+ev_store_hit\s*=\s*!rst\s*&&\s*)st_accept(\s*&&\s*present)", r"\1req && cpu.we\2", 1),
       (DCACHE, r"(assign\s+ev_store_miss\s*=\s*!rst\s*&&\s*)st_accept(\s*&&\s*!present)", r"\1req && cpu.we\2", 1)],
      dict(kind="identities", config=VD_LAT2, only="memsys/(stores|dcache)$"),
      "bench", d=True),
    m("data-event-bits-swapped", "events", "The counter block swaps bits 12 and 13 of the memory-system vector "
      "(DC_LOOKUP_HIT and DC_LOAD_MISS).",
      [(MCU, r"cache_ev_d_load_miss,\s*cache_ev_d_lookup_hit\s*\}", "cache_ev_d_lookup_hit, cache_ev_d_load_miss}", 1)],
      dict(kind="assert", config=VD_LAT2, only="memsys/hpmdcache$", message=r"hpm_ext|wiring"),
      "hpmdcache.s (the warm loop: DC_LOAD_MISS = 0)", d=True),
    m("data-reset-keeps-state", "reset", "The reset clears the D valid bits but not state and beat.",
      [(DCACHE, r"(\bif\s*\(\s*rst\s*\)\s*begin(?:(?!\bend\b).)*?)\bstate\s*<=\s*LOOKUP\s*;", r"\1", 1),
       (DCACHE, r"(\bif\s*\(\s*rst\s*\)\s*begin(?:(?!\bend\b).)*?)\bbeat\s*<=\s*[^;]+;", r"\1", 1)],
      dict(kind="dbench"), "formal dreset_state", d=True),
    m("data-dependent-store-hit", "data dependence", "A store whose lowest byte is zero does not write the line (it is "
      "treated as a miss).",
      [(DCACHE, LANE_WE, r"\1cpu.dat_mosi[7:0] != 8'h00 && cpu.sel[\2]", 1),
       (DCACHE, r"(assign\s+ev_store_hit\s*=\s*!rst\s*&&\s*st_accept\s*&&\s*)present\b", r"\1present && cpu.dat_mosi[7:0] != 8'h00", 1),
       (DCACHE, r"(assign\s+ev_store_miss\s*=\s*!rst\s*&&\s*st_accept\s*&&\s*)!present\b",
        r"\1(!present || cpu.dat_mosi[7:0] == 8'h00)", 1)],
      dict(kind="formal", prop="ddata_indep"), "bench", d=True),
    m("data-reset-keeps-valid", "reset", "The reset leaves the D valid bits as they are.",
      [(DCACHE, r"valid\s*<=\s*'0\s*;", "valid <= valid;", 1)],
      dict(kind="dbench"), "formal dreset_state", d=True),
    m("store-hit-invalidates", "performance", "A store hit clears the line's valid bit and writes no lanes. Write-through "
      "hides it from every correctness check (the next load refills from memory); only performance shows it.",
      [*added_logic(DCACHE, """    // (mutation) a store hit kills its line until the next refill
    logic [SETS-1:0] mut_dead;""", """    always_ff @(posedge clk) begin
        if (rst)
            mut_dead <= '0;
        else begin
            if (st_accept && present)
                mut_dead[cpu_index] <= 1'b1;
            if (ev_fill)
                mut_dead[refill_index] <= 1'b0;
        end
    end"""),
       (DCACHE, r"(assign\s+present\s*=\s*)", r"\1!mut_dead[cpu_index] && ", 1)],
      dict(kind="dbench"), "dc_load_misses and dc_lookup_hits of the model agreement (VD, latency 2); hpmdcache.s (stores "
      "to a present line, then DC_LOAD_MISS = 0)", d=True),
    m("store-hit-ignores-tag", "store lanes", "A store writes its lanes whenever valid[s] is set, without the tag compare: "
      "it corrupts another line.",
      [(DCACHE, r"(st_accept\s*&&\s*)present(\s*&&\s*cpu\.sel\[\w+\])", r"\1valid[cpu_index]\2", 1)],
      dict(kind="programs", config=VD_LAT0, only="memsys/dcache$"), "bench; formal dline_data; dc_store_hits of the model "
      "agreement", d=True),
    m("load-hit-refills", "performance", "The first lookup of a load whose line is present is treated as a miss and the "
      "line is refilled (the valid bit stays set). Only performance shows it.",
      [*added_logic(DCACHE, """    // (mutation) the lookup after a fill hits, any other lookup of a load misses
    logic mut_second;""", """    always_ff @(posedge clk) mut_second <= !rst && ev_fill;"""),
       (DCACHE, r"(assign\s+load_miss\s*=\s*)([^;]+);", r"\1state == LOOKUP && req && !cpu.we && (!present || !mut_second);", 1),
       (DCACHE, r"(assign\s+load_hit\s*=\s*)([^;]+);", r"\1(\2) && mut_second;", 1)],
      dict(kind="dbench"), "dc_load_misses and dc_lookup_hits of the model agreement; hpmdcache.s and hpmcache.s (the "
      "warm loop: DC_LOAD_MISS = 0)", d=True),
    m("data-present-mask-hole", "events", "The counter block's hpm_ext_present[19:12] has bit 15 clear: DC_FILL is absent.",
      [(MCU, r"(hpm_ext_present\[19:12\]\s*=\s*)8'hFF\s*;", r"\g<1>8'hF7;", 1)],
      dict(kind="programs", config=VD_LAT2, only="asm/hpm$"), "hpmdcache.s", d=True),
]
MUTANTS += D_MUTANTS
# further checks of the directed tests with the fetch compare blinded, beyond the primary ones: run
# by 'run' after the primary check, and required (a mutant that the blinded test does not catch is
# reported as MISSED even if its primary check caught it)
EXTRA_BLINDED = {
    "no-second-lookup": dict(config=SMALL_LAT2, only="memsys/fetchredirect$", answers=True),
    "latched-lookup": dict(config=SMALL_LAT2, only="memsys/fetchredirect$", answers=True),
    # dcache.s with the load compare blinded must catch the four faults that the scoreboard would show first (the
    # fourth, store-writes-all-lanes, has it as its primary check). The mutant that never writes the RAM is seen first
    # by the scoreboard's other comparisons (the two of the RAM with its copy, and the fetch of the patched code line
    # that dcache.s runs after fence.i), which stop the run before the program has judged anything: they are blinded
    # as well, and the program's own reload check decides
    "drop-lane-enable": dict(config=VD_LAT0, only="memsys/dcache$", blind=["load"]),
    "valid-on-store-miss": dict(config=VD_LAT0, only="memsys/dcache$", blind=["load"]),
    "store-hit-skips-memory": dict(config=VD_LAT0, only="memsys/dcache$", blind=["fetch", "load", "store"]),
}

# Negative controls of the run-time assertions: the control, and the run in which only that check
# can stop it. For an assertion inside icache or mem_arbiter: the bench with +compare=0; the bench's
# own negative cases are run by legality.py.
ASSERTION_MAP = [
    ("the fetch port has we = 0 and sel = 1111", "bench case fetch-write", None),
    ("a data request stays the same until answered (scoreboard)", "sb-request-corrupted", None),
    ("a data request stays the same until answered (mem_arbiter)", "bench case request-change", None),
    ("ack and err never together (icache)", "narrow-tag", dict(kind="bench-assert", message=r"icache: ack and err together on the fetch port")),
    ("ack and err never together (mem_arbiter)", "bench case ack-err", None),
    ("ack or err only with cyc && stb (icache cpu port)", "ack-without-request",
     dict(kind="bench-assert", message=r"icache: an answer without cyc && stb on the fetch port")),
    ("ack or err only with cyc && stb (mem_arbiter data port)", "answer-to-any-side",
     dict(kind="bench-assert", message=r"mem_arbiter: an answer without cyc && stb on the data port")),
    ("ack or err only with cyc && stb (mem_arbiter irefill port)", "irefill-answer-by-owner", None),
    ("the memory never answers err to the I-cache", "bench case refill-err", None),
    ("no memory write while an I-refill block holds the port", "grant-free-between-beats",
     dict(kind="bench-assert", message=r"mem_arbiter: a memory write at cycle \d+, .* while an I-refill block holds")),
    ("no memory answer in a cycle without a grant", "write-replay", None),
    # the bounded-answer assertions are in sim/top.sv: system runs, except bound (b), which a CPU
    # cannot be made to reach on purpose; its control runs in the bench's CPU-like data mode
    ("bounded answer (a): a slave-0 data request", "grant-never-released",
     dict(kind="assert", config=SMALL_LAT2, only="memsys/stores$", message=r"bounded answer \(a\)")),
    ("bounded answer (b): an I-refill is granted", "i-side-starved",
     dict(kind="bench-message", args=["+compare=bounds", "+cover=0", "+cycles=100000"],
          message=r"refill of line .* not granted within")),
    # (c): in a system run the memory wrapper's block_cont check (a load between two beats) or the
    # arbiter's write check (a store) always stops this mutant first; the bench with only its bounds
    # checked reaches bound (c) first with seed 1 in this configuration (chosen once, recorded here)
    ("bounded answer (c): a granted refill's last beat", "grant-free-between-beats",
     dict(kind="bench-message", args=["+compare=bounds", "+cover=0", "+cycles=100000", "+seed=1",
                                      "+only=icache512-line16-small"],
          message=r"last beat not answered within R")),
    ("bounded answer (d): the fetch port gets ack or err", "refill-never-ends", None),
    ("the interconnect timeout never fires while slave 0 is selected", "ram-not-exempt", None),
    ("block_cont only for a read continuing the previous transfer", "cont-on-first-beat", None),
    ("the scoreboard's reset handling", "sb-wait-kept", None),
    # with a data cache (the bench of both caches takes the same options; it runs its CPU-like data mode, in which
    # bound (b) is checked, and its free mode in every configuration)
    ("ack and err never together, an answer only with cyc && stb (dcache)", "forward-memory-ack",
     dict(kind="dbench-assert", message=r"dcache: an answer without cyc && stb")),
    ("ack and err never together (dcache), bench case", "D bench case ack-err", None),
    ("the memory never answers err to a D-refill", "D bench case d-refill-err", None),
    ("the memory never answers err to a store of the D-cache", "D bench case d-store-err", None),
    ("no memory answer in a cycle without a grant (the bench of both caches)", "D bench case spontaneous-answer", None),
    ("a D-cache request lies inside the window", "D bench case d-out-of-window", None),
    ("the D-cache's memory-side request stays the same until answered", "D bench case d-request-change", None),
    ("a continuing data beat is granted", "data-refill-gap",
     dict(kind="dbench-assert", message=r"mem_arbiter: a continuing data beat was not granted")),
    ("bounded answer (a) with a D-cache: a slave-0 request", "grant-never-released",
     dict(kind="assert", config=VD_LAT2, only="memsys/stores$", message=r"bounded answer \(a\)")),
    ("bounded answer (b) with a D-cache: an I-refill is granted", "i-side-starved",
     dict(kind="dbench-message", args=["+compare=bounds", "+cover=0", "+cycles=100000"],
          message=r"refill of line .* not granted within")),
    ("bounded answer (e): a D-refill is granted", "refill-first",
     dict(kind="dbench-message", args=["+compare=bounds", "+cover=0", "+cycles=100000"],
          message=r"data refill of line .* not granted within")),
    ("bounded answer (f): a granted D-refill's last beat", "data-refill-gap",
     dict(kind="dbench-message", args=["+compare=bounds", "+cover=0", "+cycles=100000", "+seed=1"],
          message=r"data refill of line .* last beat not answered within R")),
    ("the wiring of bits 12 to 19 of the memory-system vector", "data-event-bits-swapped",
     dict(kind="assert", config=VD_LAT2, only="memsys/hpmdcache$", message=r"hpm_ext|wiring")),
    ("the present mask of the data-cache events (hpm.s, case 3)", "data-present-mask-hole", None),
]


# ------------------------------------------------------------------------------ applying patches
def find(name):
    for mu in MUTANTS:
        if mu["name"] == name:
            return mu
    sys.exit(f"mutants.py: no mutant {name}; see: mutants.py list")


def apply(root, patches):
    """Apply patches in the tree at root -> list of problems (an anchor that does not match)."""
    problems = []
    for f, rx, rep, count in patches:
        path = os.path.join(root, f)
        if not os.path.exists(path):
            problems.append(f"{f}: no such file")
            continue
        text = open(path).read()
        n = len(re.findall(rx, text, flags=re.S if "(?s)" not in rx else 0))
        if n != count:
            problems.append(f"{f}: /{rx[:70]}/ matches {n} time(s), not {count}")
            continue
        new = re.sub(rx, rep, text, count=count, flags=re.S if "(?s)" not in rx else 0)
        with open(path, "w") as fh:
            fh.write(new)
    return problems


def copy_tree(dst, src=REPO, subset=None):
    """The working tree without its build directories and git data (only the top-level paths of
    subset, if given)."""
    ignore = shutil.ignore_patterns("build", ".git", "__pycache__")
    if not subset:
        shutil.copytree(src, dst, ignore=ignore, symlinks=True)
        return
    os.makedirs(dst)
    for part in subset:
        s_, d_ = os.path.join(src, part), os.path.join(dst, part)
        if os.path.isdir(s_):
            shutil.copytree(s_, d_, ignore=ignore, symlinks=True)
        elif os.path.isfile(s_):
            os.makedirs(os.path.dirname(d_), exist_ok=True)
            shutil.copy(s_, d_)


# ------------------------------------------------------------------------------ checks
def clean_env():
    """The environment without the caller's simulator configuration (HADES_<option>, HADES_BUILD_DIR);
    HADES_FORMAL_ENV, the formal tools' setting, is kept."""
    return {k: v for k, v in os.environ.items() if not k.startswith("HADES_") or k == "HADES_FORMAL_ENV"}


def sh(cmd, cwd, timeout=None):
    r = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                       env=clean_env(), timeout=timeout)
    return r.returncode, r.stdout


BENCHES = {"icache": ("test_icache", "ICACHE BENCH"), "dcache": ("test_dcache", "DCACHE BENCH")}


def bench_run(root, args, bench="icache"):
    """Build the bench (the I-cache's, or the memory-system bench of both caches) in the tree at root (make)
    and run it with these options."""
    top = os.path.join(root, "build", "test", "sv", BENCHES[bench][0], "top")
    rc, text = sh(["make", "-s", "--no-print-directory", os.path.relpath(top, root)], root)
    if rc:
        return None, f"the bench does not build: {text.strip()[-160:]}"
    rc, text = sh([top] + list(args), os.path.dirname(top))
    return rc, text


def programs_run(root, config, only, sim_args="", cpu="dut"):
    out = os.path.join(root, "build", "mutant-programs")
    cmd = [sys.executable, os.path.join(root, "test", "memsys", "programs.py"), "run"] + config + \
        ["--cpu", cpu, "--jobs", "4", "--out", out] + (["--only", only] if only else []) + \
        (["--sim-args", sim_args] if sim_args else [])
    rc, text = sh(cmd, root)
    try:
        res = json.load(open(os.path.join(out, "results.json")))
    except (OSError, ValueError):
        res = None
    return rc, text, res, out


def check(root, spec, mu):
    """-> (caught, evidence)."""
    kind = spec["kind"]
    if kind in ("bench", "dbench"):
        bench = "dcache" if kind == "dbench" else "icache"
        tag = BENCHES[bench][1]
        if spec.get("args"):
            rc, text = bench_run(root, spec["args"], bench)
            if rc is None:
                return None, text
        else:
            rc, text = sh(["make", "-s", "--no-print-directory", "test/sv/" + BENCHES[bench][0]], root)
        ok = rc == 0 and f"{tag}: PASS" in text
        lines = text.splitlines()
        line = next((l for l in lines if f"{tag}: FAIL" in l or "%Fatal" in l or f"{tag}: PASS" in l),
                    lines[-1] if lines else "(no output)")
        return (not ok), line[:200]
    if kind in ("bench-message", "dbench-message"):
        rc, text = bench_run(root, spec.get("args", []), "dcache" if kind.startswith("d") else "icache")
        if rc is None:
            return None, text
        hit = next((l for l in text.splitlines() if re.search(spec["message"], l)), None)
        return hit is not None, (hit or "the message did not appear")[:200]
    if kind in ("bench-assert", "dbench-assert"):
        # only the assertions inside the RTL can stop the bench with +compare=0
        rc, text = bench_run(root, ["+compare=0", "+cover=0", "+cycles=100000"], "dcache" if kind.startswith("d") else "icache")
        if rc is None:
            return None, text
        hit = next((l for l in text.splitlines() if re.search(spec["message"], l) and "%" in l), None)
        return hit is not None, (hit or "the assertion's message did not appear")[:200]
    if kind in ("programs", "blinded", "assert", "port-identity", "identities"):
        if kind == "blinded":
            # the scoreboard comparisons that the row blinds (default: the fetch compare), each patched once
            for b in spec.get("blind", ["fetch"]) + (["answers"] if spec.get("answers") else []):
                patches, sentinel = BLINDS[b]
                if sentinel not in open(os.path.join(root, TOP)).read():
                    probs = apply(root, patches)
                    if probs:
                        return None, f"the blinding patch ({b}): " + "; ".join(probs)
        rc, text, res, out = programs_run(root, spec["config"], spec.get("only", ""))
        if res is None:
            return True, f"programs.py did not finish (exit {rc}): {text.strip()[-160:]}"
        runs = [r for r in res["results"] if r["cpu"] == "dut"]
        if kind == "programs":
            bad = [r for r in runs if r["judged"] == "DIFFERS" or r["problems"] or r["errors"]]
            return bool(bad), "; ".join(f"{r['program']}: {(r['differences'] + r['problems'] + r['errors'])[:1]}"
                                        for r in bad[:3]) or "every run the same or expected"
        if kind == "blinded":
            stopped = [r for r in runs if r["scoreboard"] != "PASS"]
            invalid = [r["program"] for r in stopped]
            if invalid:
                return None, f"blinded run(s) without SCOREBOARD: PASS (not valid): {invalid}"
            # the program's own checks: its reports against the run at latency 0 (which can be wrong in
            # the same way: a mutant of the memory path acts at every latency), and its verdict against
            # the verdict it gives on the standard memory
            sys.path.insert(0, os.path.join(root, "test", "memsys"))
            import programs
            sys.path.pop(0)
            bad = []
            for r in runs:
                want = programs.verdict_at_latency0(r["program"])[0]
                why = r["differences"][:1] if r["judged"] == "DIFFERS" else []
                if not r["verdict"].startswith(want):
                    why.append(f"verdict '{r['verdict']}', on the standard memory '{want}'")
                if why:
                    bad.append(f"{r['program']}: {why}")
            return bool(bad), "; ".join(bad[:3]) or "the programs' own reports and verdicts unchanged"
        logs = [open(os.path.join(out, r["dir"], "sim.log"), errors="replace").read() for r in runs]
        if kind == "identities":
            sys.path.insert(0, HERE)
            import matrix
            sys.path.pop(0)
            bad = [f"{r['program']}: {x}" for r, t in zip(runs, logs) for x in matrix.identities(t)]
            bad += [f"{r['program']}: {(r['problems'] + r['errors'])[0]}" for r in runs if r["problems"] or r["errors"]]
            return bool(bad), "; ".join(bad[:2]) or "the identities hold"
        if kind == "assert":
            hit = next((l for t in logs for l in t.splitlines() if re.search(spec["message"], l) and "%" in l), None)
            ev = ""
            if spec.get("evidence"):
                ev = "; evidence " + ", ".join(sorted({x for t in logs for x in re.findall(spec["evidence"], t)})[:3])
            return hit is not None, (hit or "the check's message did not appear")[:200] + ev
        # port-identity
        sys.path.insert(0, HERE)
        import matrix
        sys.path.pop(0)
        if not logs:
            return None, "no run matched: the identities were not evaluated"
        bad = []
        for t in logs:
            st = matrix.stats_of(t)
            if not st:
                # a run that stopped before its CACHE_STATS line has not shown the identities; the
                # stop (a bounded-answer assertion, an assertion, a scoreboard failure) is the difference
                stop = next((l.strip() for l in t.splitlines() if "%Fatal" in l or "%Error" in l), "no CACHE_STATS line")
                bad.append(f"the run stopped before its CACHE_STATS line: {stop}")
                continue
            if st["port_irefill"] != 6 * st["i_done"] + st["i_inflight_port"]:
                bad.append(f"port_irefill {st['port_irefill']} != 6 * {st['i_done']} + {st['i_inflight_port']}")
            if "dc_done" in st:
                # with a data cache: a refill is 6 cycles, a store 3
                want = 6 * st["dc_done"] + 3 * st["d_stores"] + st["dc_inflight_port"] + st["d_inflight_port"]
                if st["port_data"] != want:
                    bad.append(f"port_data {st['port_data']} != 6 * {st['dc_done']} + 3 * {st['d_stores']} + "
                               f"{st['dc_inflight_port']} + {st['d_inflight_port']}")
            elif st["port_data"] != 3 * (st["d_loads"] + st["d_stores"]) + st["d_inflight_port"]:
                bad.append(f"port_data {st['port_data']} != 3 * ({st['d_loads']} + {st['d_stores']}) + "
                           f"{st['d_inflight_port']}")
        return bool(bad), "; ".join(bad[:2]) or "the port identities hold"
    if kind == "sweep":
        cfg_rc, cfg = sh(["make", "-s", "--no-print-directory", "sim-config"] + spec["config"], root)
        env_line = re.search(r"\n\s+(HADES_BUILD_DIR=\S+(?: HADES_\w+=\S+)*)\s*$", cfg)
        env = {k: v for k, v in os.environ.items() if not k.startswith("HADES_")}
        for kv in (env_line.group(1).split() if env_line else []):
            k, v = kv.split("=", 1)
            env[k] = v
        r = subprocess.run([sys.executable, os.path.join(root, "test", "trapsweep", "sweep.py"), "run", "--fam",
                            spec["fam"], "--targets", "dut", "--jobs", "4", "--out",
                            os.path.join(root, "build", "mutant-sweep")], cwd=root, env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        m_ = re.search(r"^DUT: (\d+)/(\d+) programs ISS-consistent", r.stdout, re.M)
        caught = not m_ or m_.group(1) != m_.group(2) or r.returncode != 0
        return caught, (m_.group(0) if m_ else r.stdout.strip()[-160:])
    if kind == "formal":
        rc, text = sh(["bash", os.path.join(root, "formal", "cache", "run.sh"), "--only", spec["prop"], "--configs",
                       "tiny", "--no-controls", "--out", os.path.join(root, "build", "mutant-formal")], root)
        hit = re.search(rf"^\s*{re.escape(spec['prop'])}(_tiny)?\s+FAIL\b.*$", text, re.M)
        if hit is None and re.search(r"FORMAL CACHE RESULT: FAIL \(missing tools\)", text):
            return None, "the formal tools are missing (HADES_FORMAL_ENV)"
        return hit is not None, (hit.group(0).strip() if hit else f"no failure of {spec['prop']} (exit {rc})")[:200]
    if kind == "resets":
        rc, text = sh([sys.executable, os.path.join(root, "test", "memsys", "matrix.py"), "run", spec["leg"], "--only",
                       spec["job"], "--out", os.path.join(root, "build", "mutant-matrix")], root)
        hit = re.search(spec["message"], text)
        return hit is not None, (hit.group(0) if hit else "the reset runs did not show it")[:200]
    return None, f"unknown check {kind}"


def run_one(mu, out, keep, with_map, primary_only=False):
    d = tempfile.mkdtemp(prefix=f"mutant-{mu['name']}-")
    root = os.path.join(d, "tree")
    res = dict(name=mu["name"], cls=mu["cls"])
    try:
        copy_tree(root)
        probs = apply(root, mu["patches"])
        if probs:
            res.update(verdict="ANCHOR MISSING", evidence="; ".join(probs))
            return res
        caught, ev = check(root, mu["primary"], mu)
        res.update(verdict="CAUGHT" if caught else ("MISSED" if caught is not None else "INVALID"), evidence=ev)
        extra = mu["primary"].get("also_config")
        if extra and not primary_only:
            spec = dict(mu["primary"], config=extra)
            shutil.rmtree(os.path.join(root, "build", "mutant-programs"), ignore_errors=True)
            c2, ev2 = check(root, spec, mu)
            res["also_config"] = dict(config=extra, verdict="CAUGHT" if c2 else ("MISSED" if c2 is not None
                                                                                   else "INVALID"), evidence=ev2)
        blind = EXTRA_BLINDED.get(mu["name"])
        if blind and not primary_only:
            # the directed test with the scoreboard blinded: required in addition to the primary check
            shutil.rmtree(os.path.join(root, "build", "mutant-programs"), ignore_errors=True)
            c4, ev4 = check(root, dict(blind, kind="blinded"), mu)
            res["blinded"] = dict(config=blind["config"], only=blind["only"],
                                  verdict="CAUGHT" if c4 else ("MISSED" if c4 is not None else "INVALID"), evidence=ev4)
            if res["verdict"] == "CAUGHT" and res["blinded"]["verdict"] != "CAUGHT":
                res["verdict"] = res["blinded"]["verdict"]
                res["evidence"] += f"; with the scoreboard blinded: {res['blinded']['verdict']}: {ev4}"
        if with_map:
            for assertion, control, spec in ASSERTION_MAP:
                if control == mu["name"] and spec:
                    c3, ev3 = check(root, spec, mu)
                    res.setdefault("map", []).append(dict(assertion=assertion, shown=bool(c3), evidence=ev3))
        return res
    finally:
        if keep:
            res["tree"] = root
        else:
            shutil.rmtree(d, ignore_errors=True)


# ------------------------------------------------------------------------------ the dry run
def checkout_state():
    """The state of the checkout: its commit, its changes and its untracked files."""
    def git(*args):
        return subprocess.run(["git", "-C", REPO] + list(args), capture_output=True, text=True).stdout
    return git("rev-parse", "HEAD") + git("status", "--porcelain", "--untracked-files=all") + git("diff", "HEAD")


def build_check(root, mu):
    """Does the tree at root, with the mutant applied, still build? Verilator elaborates
    (--lint-only) the simulator of the mutant's configuration when a SystemVerilog file is patched,
    and the I-cache bench when a file of rtl/cache is; a patched program is assembled.
    -> (ok, what was checked or the first error)."""
    files = sorted({f for f, *_ in mu["patches"]})
    done = []
    if any(f.endswith(".sv") for f in files):
        config = mu["primary"].get("config") or (VD_LAT2 if mu.get("d") else SMALL_LAT2)
        rc, cfg = sh(["make", "-s", "--no-print-directory", "sim-config"] + config, root)
        m_ = re.search(r"Verilator defines:\s+(.*)", cfg)
        if rc or not m_:
            return False, f"make sim-config {' '.join(config)}: {cfg.strip()[-160:]}"
        defs = [] if m_.group(1).strip() == "(none)" else m_.group(1).split()
        lints = [("the simulator (" + " ".join(config) + ")",
                  ["-f", "sim/files.txt"] + defs + ["--top-module", "top", "sim/top.sv"])]
        if any(f.startswith("rtl/cache/") for f in files) and (not mu.get("d") or ARB in files):
            lints.append(("the I-cache bench", ["-f", "sim/files.txt", "-f", "test/sv/files.txt", "-y", "rtl/cache",
                                                "--top-module", "test_icache", "test/sv/test_icache.sv"]))
        if any(f.startswith("rtl/cache/") for f in files) and mu.get("d") and \
                os.path.exists(os.path.join(root, "test", "sv", "test_dcache.sv")):
            lints.append(("the memory-system bench", ["-f", "sim/files.txt", "-f", "test/sv/files.txt", "-y", "rtl/cache",
                                                      "--top-module", "test_dcache", "test/sv/test_dcache.sv"]))
        for what, args in lints:
            rc, text = sh(["verilator", "--lint-only", "-Wno-fatal", "--timing", "--assert",
                           "-Mdir", os.path.join(root, "build", "lint-only")] + args, root)
            err = next((l for l in text.splitlines() if l.startswith("%Error")), None)
            if rc or err:
                return False, f"{what}: {(err or text.strip()[-160:])[:200]}"
            done.append(what)
    for f in files:
        if f.endswith(".s"):
            target = os.path.join("build", os.path.splitext(f)[0], "init.mem")
            rc, text = sh(["make", "-s", "--no-print-directory", target], root)
            if rc:
                return False, f"{f} does not assemble: {text.strip()[-200:]}"
            done.append(f"{f} assembled")
    return True, "; ".join(done) or "nothing to build"


def dry_one(mu):
    d = tempfile.mkdtemp(prefix=f"mutant-dry-{mu['name']}-")
    root = os.path.join(d, "tree")
    try:
        copy_tree(root)
        probs = apply(root, mu["patches"])
        if probs:
            return mu["name"], "ANCHOR MISSING", "; ".join(probs)
        files = ", ".join(sorted({f for f, *_ in mu["patches"]}))
        ok, what = build_check(root, mu)
        return mu["name"], "BUILT" if ok else "BUILD FAILED", f"{files}: {what}"
    finally:
        shutil.rmtree(d, ignore_errors=True)


def cmd_dryrun(a):
    names = a.names or [mu["name"] for mu in MUTANTS]
    mus = [find(n) for n in names]
    before = checkout_state()
    count = {}
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for name, verdict, why in ex.map(dry_one, mus):
            count[verdict] = count.get(verdict, 0) + 1
            print(f"{verdict:14s} {name}: {why}", flush=True)
    same = checkout_state() == before
    print(f"DRY RUN: {count.get('BUILT', 0)} of {len(mus)} mutants applied and built, then discarded; "
          f"{count.get('ANCHOR MISSING', 0)} without an anchor, {count.get('BUILD FAILED', 0)} that do not build; "
          f"the checkout is {'unchanged' if same else 'CHANGED'}")
    return 0 if count.get("BUILT", 0) == len(mus) and same else 1


def cmd_apply(a):
    """A copy of the tree (or of the top-level paths of --subset) with one mutant applied."""
    mu = find(a.name)
    dst = os.path.abspath(a.dir)
    if os.path.exists(dst):
        sys.exit(f"mutants.py: {dst} exists")
    copy_tree(dst, os.path.abspath(a.src), a.subset.split(",") if a.subset else None)
    probs = apply(dst, mu["patches"])
    if probs:
        print(f"mutants.py: {mu['name']}: ANCHOR MISSING: " + "; ".join(probs))
        return 1
    print(f"mutants.py: {mu['name']} applied in {dst}")
    return 0


# ------------------------------------------------------------------------------ commands
def cmd_list(a):
    for mu in MUTANTS:
        p = mu["primary"]
        where = " ".join(p.get("config", [])) or ""
        what = p["kind"] + (f" ({where}" + (f", {p['only']}" if p.get("only") else "") + ")" if where else "") + \
            (f" {p.get('fam', '')}{p.get('prop', '')}" if p["kind"] in ("sweep", "formal") else "")
        files = sorted({f for f, *_ in mu["patches"]})
        print(f"{mu['name']:28s} {mu['cls']:18s} {', '.join(files):45s} {what}")
        if a.verbose:
            print(f"    {mu['what']}")
            if mu["also"]:
                print(f"    also: {mu['also']}")
    print(f"{len(MUTANTS)} mutants")
    print("negative controls of the run-time assertions:")
    for assertion, control, spec in ASSERTION_MAP:
        print(f"    {assertion:62s} {control}" + (f"  [{spec['kind']}]" if spec else ""))
    return 0


def cmd_anchors(a):
    names = a.names or [mu["name"] for mu in MUTANTS]
    bad = 0
    for n in names:
        mu = find(n)
        d = tempfile.mkdtemp(prefix="mutant-anchor-")
        try:
            for f in {f for f, *_ in mu["patches"]}:
                src = os.path.join(REPO, f)
                if os.path.exists(src):
                    os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
                    shutil.copy(src, os.path.join(d, f))
            probs = apply(d, mu["patches"])
        finally:
            shutil.rmtree(d, ignore_errors=True)
        bad += bool(probs)
        print(f"{'ok     ' if not probs else 'MISSING'} {n}" + "".join(f"\n        {p}" for p in probs))
    d = tempfile.mkdtemp(prefix="mutant-anchor-")
    try:
        for f in (TOP, ICACHE):
            os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
            shutil.copy(os.path.join(REPO, f), os.path.join(d, f))
        probs = apply(d, BLIND)
        probs_a = apply(d, BLIND_ANSWERS)
        probs_l = apply(d, BLIND_LOAD)
        probs_s = apply(d, BLIND_STORE)
    finally:
        shutil.rmtree(d, ignore_errors=True)
    for what, pr in (("the blinding of the fetch compare", probs), ("the blinding of the fetch answer checks", probs_a),
                     ("the blinding of the load compare", probs_l), ("the blinding of the RAM comparisons", probs_s)):
        print(f"{'ok     ' if not pr else 'MISSING'} ({what})" + "".join(f"\n        {p}" for p in pr))
    probs += probs_a + probs_l + probs_s
    print(f"ANCHORS: {len(names) - bad} of {len(names)} mutants apply to this tree")
    return 0 if not bad and not probs else 1


def cmd_show(a):
    mu = find(a.name)
    d = tempfile.mkdtemp(prefix="mutant-show-")
    try:
        for f in {f for f, *_ in mu["patches"]}:
            if os.path.exists(os.path.join(REPO, f)):
                os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True)
                shutil.copy(os.path.join(REPO, f), os.path.join(d, f))
        probs = apply(d, mu["patches"])
        for f in sorted({f for f, *_ in mu["patches"]}):
            if os.path.exists(os.path.join(d, f)):
                old = open(os.path.join(REPO, f)).read().splitlines(True)
                new = open(os.path.join(d, f)).read().splitlines(True)
                sys.stdout.writelines(difflib.unified_diff(old, new, f"a/{f}", f"b/{f}"))
        for p in probs:
            print(f"ANCHOR MISSING: {p}")
    finally:
        shutil.rmtree(d, ignore_errors=True)
    print(f"{mu['name']}: {mu['what']}")
    return 0


def cmd_run(a):
    names = [mu["name"] for mu in MUTANTS] if not a.names or a.names == ["all"] else a.names
    mus = [find(n) for n in names]
    os.makedirs(a.out, exist_ok=True)
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
        for res in ex.map(lambda mu: run_one(mu, a.out, a.keep, a.map, a.primary_only), mus):
            results.append(res)
            extra = res.get("also_config")
            blind = res.get("blinded")
            print(f"{res['verdict']:14s} {res['name']}: {res['evidence']}" +
                  (f"\n{'':14s}   also {' '.join(extra['config'])}: {extra['verdict']}: {extra['evidence']}"
                   if extra else "") +
                  (f"\n{'':14s}   blinded {blind['only']} at {' '.join(blind['config'])}: {blind['verdict']}: "
                   f"{blind['evidence']}" if blind else "") +
                  "".join(f"\n{'':14s}   assertion '{x['assertion']}': {'shown' if x['shown'] else 'NOT shown'}: "
                          f"{x['evidence']}" for x in res.get("map", [])), flush=True)
    with open(os.path.join(a.out, "mutants.json"), "w") as f:
        json.dump(results, f, indent=1)
    caught = sum(r["verdict"] == "CAUGHT" for r in results)
    others = ", ".join(f"{v} {sum(r['verdict'] == v for r in results)}"
                       for v in ("MISSED", "INVALID", "ANCHOR MISSING") if any(r["verdict"] == v for r in results))
    print(f"MUTANTS: {caught} of {len(results)} CAUGHT; " + (f"{others}; " if others else "") + f"{a.out}/mutants.json")
    return 0 if caught == len(results) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("list")
    p.add_argument("-v", "--verbose", action="store_true")
    p = sub.add_parser("anchors")
    p.add_argument("names", nargs="*")
    p = sub.add_parser("show")
    p.add_argument("name")
    p = sub.add_parser("dryrun")
    p.add_argument("names", nargs="*")
    p.add_argument("--jobs", type=int, default=4)
    p = sub.add_parser("apply")
    p.add_argument("--src", default=REPO, help="the tree to copy (default: this checkout)")
    p.add_argument("--subset", default="", help="only these top-level paths, comma-separated (e.g. rtl,lib,defines)")
    p.add_argument("name")
    p.add_argument("dir")
    p = sub.add_parser("run")
    p.add_argument("names", nargs="*")
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--out", default=os.path.join(REPO, "build", "mutants"))
    p.add_argument("--map", action="store_true", help="also the negative controls of the run-time assertions")
    p.add_argument("--keep", action="store_true", help="keep the temporary trees")
    p.add_argument("--primary-only", action="store_true", help="only the primary check's configuration")
    a = ap.parse_args()
    return {"list": cmd_list, "anchors": cmd_anchors, "show": cmd_show, "run": cmd_run, "dryrun": cmd_dryrun,
            "apply": cmd_apply}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
