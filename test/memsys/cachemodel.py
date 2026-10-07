#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# ---------------------------------------------------------------------------------------------
# cachemodel.py -- trace-driven model of the planned L1 caches of HaDes-V+
#
# Answers the sizing questions of L1 caches before any cache RTL exists: cache sizes, line
# size, direct-mapped or 2-way, abort-on-redirect, and whether stores without a write buffer
# stall too often. It replays a bus trace of the core without caches (taken with the standard
# single-cycle RAM) through split L1 caches in front of a slow memory and counts misses,
# refills and the cycles they cost.
#
#   python3 test/memsys/cachemodel.py prep  <bustrace.bin> <out dir> --ram-kb N [--name NAME]
#   python3 test/memsys/cachemodel.py stats <prepared dir>...
#   python3 test/memsys/cachemodel.py run   <prepared dir>... [configuration options] [--out FILE]
#   python3 test/memsys/cachemodel.py check [<prepared dir>...]
#
# 1. RECORDING A TRACE
# A simulator built with the Makefile option BUSTRACE=1 (+define+HADES_BUSTRACE) writes one
# record per clock cycle (the format is documented next to the monitor in sim/top.sv) to
# bustrace.bin in its run directory (+bustrace=<file>: elsewhere), for example
#     make freertos APP=stress BUSTRACE=1
#     -> build/cfg-trace/test/freertos/stress/bustrace.bin   (16 bytes per cycle)
# The option builds its own simulators (build/cfg-trace); the standard ones stay as they
# are. The monitor only reads signals: the run's cycle count and output are the standard
# ones. Record with the standard memory (no MEM_LAT): the model supplies the latencies.
#
# 2. PREPARING IT (prep)
# prep reduces the 16-byte records to what the model needs, in <out dir>:
#   fa.npy    uint32 per cycle  the fetch word address
#   code.npy  uint8  per cycle  [1:0] Fetch's status (0 READY, 1 STALL, 2 JUMP), [3:2] a RAM
#                               access starts in this cycle (1 load, 2 store), [4] the word
#                               taken by a READY fetch reaches Writeback (it is not flushed),
#                               [5] an instruction retires, [6] a cycle of an I/O access,
#                               [7] reset
#   dcyc.npy, dadr.npy, dsel.npy  per RAM access: cycle, word address, byte lanes
#   meta.json                     RAM window, cycles, instructions, consistency counts
# Reset cycles at the start are dropped (record 0 is the reset edge). A fetch is "consumed"
# when Fetch is READY and the RAM answers (ack or err). Whether a consumed fetch reaches
# Writeback is found by matching, in order, the PCs of the non-bubble instructions in
# Writeback against the consumed fetches; the unmatched ones were flushed (wrong path). The
# matching keeps the pipeline's rule that a flushed fetch is followed by a JUMP cycle before
# the next fetch that reaches Writeback (see prep()).
#
# 3. THE MODEL (run)
# What is modelled (caches in rtl/mcu.sv, outside the CPU):
#   - an I-cache between the fetch port and memory and a D-cache as interconnect slave 0;
#     I/O accesses keep their latency and never use the memory port;
#   - direct-mapped, or 2-way with one LRU bit per set (an invalid way is filled first; load
#     hits, fetch hits and refills update it, stores do not);
#   - full tags; lines of 8 to 64 bytes, one size for both caches;
#   - one memory port behind a fixed-priority arbiter: the data side first; a grant lasts
#     for one refill or one write and is never taken away;
#   - hits take one cycle, as the standard RAM does;
#   - blocking misses: the miss is seen in cycle t, the refill requests the port from t+1,
#     the line becomes valid with its last beat, and the request is looked up again in the
#     cycle after the last beat (a READY fetch that misses at t with a free port is taken
#     at t + 1 + R, R = refill cycles). While a refill waits or runs, the I-cache answers
#     nothing;
#   - the I-cache cannot tell which lookups Fetch will use: it serves every presented
#     address, also in STALL and JUMP cycles, so discarded and wrong-path lookups start
#     refills as they would in hardware;
#   - the victim line is dropped when the miss is seen (--evict miss, the default)
#     or only when the refill is granted the port (--evict grant). The two differ only when
#     a request is withdrawn before its grant (abort-on-redirect);
#   - write-through, no write-allocate: a store updates the D-cache only if the line is
#     present. Write buffer (--wbuf): none (a store holds the CPU until memory acknowledges
#     it), line (one line-wide entry that merges stores to the same line; it is written
#     when a store to another line arrives or before any refill, so refills see an empty
#     buffer, and a store waits only while the entry holds another line), or ideal (every
#     store is taken at once and written when the port is free, in order; an upper bound);
#   - the I-cache snoops every store when memory acknowledges it, or when the buffer takes
#     it, and drops the line if it holds it;
#   - a fetch outside the RAM window gets err at once and never starts a refill;
#   - abort-on-redirect (--abort): a refill request is withdrawn, or a running refill
#     stopped after the beat in flight, as soon as the fetch address leaves the line; the
#     line stays invalid. Without it a started refill always completes.
# Memory models (--mem): per-beat ("beat"): every word of a line costs a full access of
# L + 1 cycles, L drawn per word; burst ("burst"): the first word costs L + 1 cycles and
# every further word --beat-cycles (default 1) cycle. L is drawn uniformly from --rd-lat
# (default 8:24, a DRAM-like profile); a store costs W + 1 cycles, W from
# --wr-lat (default 1:4); a buffered line of k words is written like k words of a refill
# (k accesses of W + 1 cycles per beat, or W + 1 + (k - 1) * beat cycles in a burst).
# Draws come from a seeded generator (--seed).
#
# The replay: the trace is the core's cycle-by-cycle behaviour with the standard RAM. The cached
# core executes the same cycles in order; a trace cycle completes only when the RAM access
# it starts (if any) and a READY fetch (if any) whose word reaches Writeback are both
# answered. Until then the whole core waits, while the fetch port keeps presenting the
# cycle's address: these presented but not consumed lookups (STALL and JUMP cycles of the
# trace, and every cycle in which the core waits for the data side) may start refills, as
# they would in hardware.
# A READY fetch whose word is flushed later (a wrong-path fetch) does not hold the core:
# the instruction that redirects Fetch is older and reaches its stage whether or not the
# wrong-path word arrives. Its lookup still starts a refill on a miss; if it is not
# answered, Fetch keeps presenting that address (it advances only on an acknowledged
# READY fetch or a JUMP) until the next JUMP cycle, which in the trace always follows a
# flushed fetch. --wait-flushed restores the simpler rule in which every READY fetch holds
# the core; it overstates the cost of wrong-path misses and hides most of what
# abort-on-redirect can save.
# "The whole core waits" is the main approximation that remains:
#   - older instructions would in reality keep draining during an I-miss (at most three,
#     so a few cycles, more under a divide), so I-miss costs are slightly pessimistic;
#   - the core's later behaviour does not change with the timing (interrupts and the
#     scheduler would arrive at other points of the program; the trace cannot show that).
# The fast replay skips cycles in which nothing can change (a fetch in the same line as the
# previous cycle, no RAM access, no refill or write running) and jumps over cycles in which
# the core only waits. It must give exactly the result of the plain per-cycle replay, which
# is kept as the specification (--reference) and compared by `check`.
#
# 4. OUTPUT
# One JSON object per (trace, configuration): the configuration, cycles and instructions
# with and without caches, refills by the kind of lookup that started them (CAUSES below),
# what became of each refilled line (USES below, or aborted), refills whose line Fetch had
# left before the last beat, stall cycles by cause (fetch, load miss, store), port use,
# write-buffer activity and snoop invalidations. MPKI = completed refills (I) or load misses
# (D) per 1000 retired instructions.
# ---------------------------------------------------------------------------------------------

import argparse
import array
import json
import os
import random
import sys
import time

import numpy as np

RAM_START = 0x10000                     # word address of the RAM (defines/constants.sv)
RECORD = np.dtype([('f', '<u4'), ('fl', '<u4'), ('da', '<u4'), ('pc', '<u4')])
READY, STALL, JUMP = 0, 1, 2
# What kind of lookup started a refill: a READY fetch whose word reaches Writeback, a STALL
# cycle, a JUMP cycle, a cycle in which the core waits for the data side, a READY fetch whose
# word is flushed later (wrong path).
CAUSES = ('ready', 'stall', 'jump', 'dwait', 'flushed')
USES = ('unused', 'flushed', 'retired')         # what took a refilled line before it left
WBUF_MODES = ('none', 'line', 'ideal')


# =============================================================================================
# 1. Preparing a trace
# =============================================================================================

def prep(trace, outdir, ram_kb, name=None, chunk=1 << 22):
    """Reduce a bustrace.bin to the per-cycle arrays the model reads (see the header)."""
    rec = np.memmap(trace, dtype=RECORD, mode='r')
    n_all = len(rec)
    ram_end = RAM_START + ram_kb * 256
    # skip the reset cycles at the start
    first = 0
    while first < n_all and (int(rec['fl'][first]) >> 19) & 1:
        first += 1
    n = n_all - first
    os.makedirs(outdir, exist_ok=True)
    fa = np.lib.format.open_memmap(os.path.join(outdir, 'fa.npy'), mode='w+', dtype=np.uint32, shape=(n,))
    code = np.lib.format.open_memmap(os.path.join(outdir, 'code.npy'), mode='w+', dtype=np.uint8, shape=(n,))
    dcyc, dadr, dsel = [], [], []
    counts = dict(cycles=n, reset_cycles_skipped=first, retired=0, wb_nonbubble=0, consumed=0,
                  consumed_reaching_wb=0, wb_unmatched=0, wb_lookahead_failed=0, wb_rule_broken=0,
                  fetch_err=0, ram_loads=0, ram_stores=0, io_accesses=0, io_cycles=0, data_err=0,
                  ram_multicycle=0, reset_later=0)
    prev_busy = False          # previous cycle had cyc&stb without ack/err (access continues)
    # Which consumed fetches reach Writeback: the PCs of the non-bubble instructions in
    # Writeback are matched in order against the consumed fetch addresses; the fetches skipped
    # over were flushed (wrong path). A redirect (a JUMP cycle) flushes every fetch younger
    # than the instruction that redirects, so a flushed fetch is always followed by a JUMP
    # cycle before the next fetch that reaches Writeback. A Writeback PC is matched to the
    # first equal fetch address, at most MAXSKIP fetches ahead, that keeps this rule for
    # itself and leaves a fetch that keeps it for the next Writeback PC. The rule settles the
    # cases in which a jump goes to an address that was just fetched and flushed (a jr to the
    # next instruction, an mret into the code right after it): the equal fetch after the
    # JUMP reaches Writeback, not the first one. The counts wb_lookahead_failed (the next PC
    # found no such fetch), wb_rule_broken (no fetch kept the rule; the first equal address
    # within LOOK was taken) and wb_unmatched are 0 on a consistent trace.
    pend_pos = array.array('I'); pend_adr = array.array('I')
    pend_jc = array.array('I')                 # JUMP cycles before each pending fetch
    wpend = array.array('I')                   # Writeback PCs not yet matched; the last one of
                                               # a chunk waits for its successor
    njump = 0
    MAXSKIP = 8
    LOOK = 64
    for c0 in range(0, n, chunk):
        r = np.array(rec[first + c0:first + min(n, c0 + chunk)])
        f = r['f']; fl = r['fl']
        st = (f >> 30).astype(np.uint8)
        adr = f & 0x3FFFFFFF
        fack = fl & 1; ferr = (fl >> 1) & 1
        dreq = (fl >> 2) & 1; dack = (fl >> 3) & 1; derr = (fl >> 4) & 1; dwe = (fl >> 5) & 1
        sel = (fl >> 6) & 15; ram = (fl >> 10) & 1; wbv = (fl >> 11) & 1; ret = (fl >> 12) & 1
        rst = (fl >> 19) & 1
        done = dreq & (dack | derr)
        # an access starts in a cycle with cyc&stb if the previous cycle did not continue one
        busy = (dreq == 1) & (done == 0)
        prevb = np.empty_like(busy); prevb[0] = prev_busy; prevb[1:] = busy[:-1]
        start = (dreq == 1) & ~prevb
        prev_busy = bool(busy[-1])
        ramstart = start & (ram == 1)
        cc = st.copy()
        cc |= (ramstart & (dwe == 0)).astype(np.uint8) << 2
        cc |= (ramstart & (dwe == 1)).astype(np.uint8) << 3
        cc |= ret.astype(np.uint8) << 5
        cc |= ((dreq == 1) & (ram == 0)).astype(np.uint8) << 6
        cc |= rst.astype(np.uint8) << 7
        idx = np.flatnonzero(ramstart)
        dcyc.append((idx + c0).astype(np.uint32)); dadr.append(r['da'][idx]); dsel.append(sel[idx].astype(np.uint8))
        cons = (st == READY) & ((fack | ferr) == 1) & (rst == 0)
        ci = np.flatnonzero(cons)
        wi = np.flatnonzero((wbv == 1) & (rst == 0))
        jmp = ((st == JUMP) & (rst == 0)).astype(np.int64)
        jbefore = njump + np.cumsum(jmp) - jmp
        njump += int(jmp.sum())
        pend_pos.frombytes((ci + c0).astype(np.uint32).tobytes())
        pend_adr.frombytes(adr[ci].astype(np.uint32).tobytes())
        pend_jc.frombytes(jbefore[ci].astype(np.uint32).tobytes())
        wpend.frombytes((r['pc'][wi] >> 2).astype(np.uint32).tobytes())
        todo = len(wpend) if c0 + chunk >= n else max(0, len(wpend) - 1)
        matched = array.array('I')
        j = 0; nc = len(pend_adr)
        for i in range(todo):
            w = wpend[i]
            w2 = wpend[i + 1] if i + 1 < len(wpend) else None
            pick = -1; first_ok = -1
            for k in range(j, min(nc, j + MAXSKIP + 1)):
                # fetch k may reach Writeback if the fetches j..k-1 before it were flushed by
                # a JUMP that comes before it
                if pend_adr[k] != w or (k > j and pend_jc[k] == pend_jc[k - 1]):
                    continue
                if first_ok < 0:
                    first_ok = k
                if w2 is None:
                    pick = k
                    break
                for k2 in range(k + 1, min(nc, k + MAXSKIP + 2)):
                    if pend_adr[k2] == w2 and (k2 == k + 1 or pend_jc[k2] != pend_jc[k2 - 1]):
                        pick = k
                        break
                if pick >= 0:
                    break
            if pick < 0 and first_ok >= 0:
                pick = first_ok
                counts['wb_lookahead_failed'] += 1
            if pick < 0:
                k = j; lim = min(nc, j + LOOK)
                while k < lim and pend_adr[k] != w:
                    k += 1
                if k < lim:
                    pick = k
                    counts['wb_rule_broken'] += 1
            if pick >= 0:
                matched.append(pend_pos[pick])
                j = pick + 1
            else:
                counts['wb_unmatched'] += 1     # leave the fetch pointer where it is
        wpend = wpend[todo:]
        # keep the fetches not yet matched (the ones before j were flushed)
        pend_pos = pend_pos[j:]; pend_adr = pend_adr[j:]; pend_jc = pend_jc[j:]
        mp = np.frombuffer(matched.tobytes(), dtype=np.uint32).astype(np.int64)
        inchunk = mp >= c0
        cc[mp[inchunk] - c0] |= 16
        fa[c0:c0 + len(r)] = adr
        code[c0:c0 + len(r)] = cc
        if (~inchunk).any():                     # matched fetches of the previous chunk
            code[mp[~inchunk]] |= 16
        counts['consumed_reaching_wb'] += len(mp)
        counts['retired'] += int(ret[rst == 0].sum())
        counts['wb_nonbubble'] += len(wi)
        counts['consumed'] += len(ci)
        counts['fetch_err'] += int(ferr.sum())
        counts['ram_loads'] += int((ramstart & (dwe == 0)).sum())
        counts['ram_stores'] += int((ramstart & (dwe == 1)).sum())
        counts['io_accesses'] += int((start & (ram == 0)).sum())
        counts['io_cycles'] += int(((dreq == 1) & (ram == 0)).sum())
        counts['data_err'] += int((done & derr).sum())
        counts['ram_multicycle'] += int(((dreq == 1) & (ram == 1) & (done == 0)).sum())
        counts['reset_later'] += int(rst.sum())
        del r
    dcyc = np.concatenate(dcyc); dadr = np.concatenate(dadr); dsel = np.concatenate(dsel)
    np.save(os.path.join(outdir, 'dcyc.npy'), dcyc)
    np.save(os.path.join(outdir, 'dadr.npy'), dadr)
    np.save(os.path.join(outdir, 'dsel.npy'), dsel)
    code.flush(); fa.flush()
    del code, fa
    meta = dict(name=name or os.path.basename(os.path.normpath(outdir)), trace=os.path.abspath(trace),
                ram_kb=ram_kb, ram_start=RAM_START, ram_end=ram_end, **counts)
    with open(os.path.join(outdir, 'meta.json'), 'w') as fh:
        json.dump(meta, fh, indent=1)
    return meta


class Trace:
    """A prepared trace, or a window [w0, w1) of it (cycle indices of the prepared arrays)."""

    def __init__(self, d, w0=0, w1=None):
        with open(os.path.join(d, 'meta.json')) as fh:
            self.meta = json.load(fh)
        fa = np.load(os.path.join(d, 'fa.npy'), mmap_mode='r')
        code = np.load(os.path.join(d, 'code.npy'), mmap_mode='r')
        n = len(fa)
        w1 = n if w1 is None else min(w1, n)
        self.name = self.meta['name']
        self.w0, self.w1, self.n = w0, w1, w1 - w0
        # array.array for fast scalar access in the replay, numpy views of the same memory
        self.fa = array.array('I'); self.fa.frombytes(np.ascontiguousarray(fa[w0:w1]).tobytes())
        self.code = array.array('B'); self.code.frombytes(np.ascontiguousarray(code[w0:w1]).tobytes())
        self.fa_np = np.frombuffer(self.fa, dtype=np.uint32)
        self.code_np = np.frombuffer(self.code, dtype=np.uint8)
        dcyc = np.load(os.path.join(d, 'dcyc.npy'), mmap_mode='r')
        lo, hi = np.searchsorted(dcyc, [w0, w1])
        self.dcyc_np = (np.array(dcyc[lo:hi]) - w0).astype(np.uint32)
        self.dadr = array.array('I')
        self.dadr.frombytes(np.ascontiguousarray(np.load(os.path.join(d, 'dadr.npy'), mmap_mode='r')[lo:hi]).astype(np.uint32).tobytes())
        self.ram_start = self.meta['ram_start']
        self.ram_end = self.meta['ram_end']
        self._events = {}

    def instructions(self, a=0, b=None):
        b = self.n if b is None else b
        return int(((self.code_np[a:b] >> 5) & 1).sum())

    def events(self, lshift, extra=()):
        """Cycles at which the fast replay must look: the fetch enters another line (of
        2**lshift words), a RAM access starts, or a cycle in `extra`. Per event, bit 0: a
        READY fetch follows before the next event, bit 1: one of them reaches Writeback."""
        key = (lshift, tuple(extra))
        if key not in self._events:
            n = self.n
            line = self.fa_np >> np.uint32(lshift)
            ev = np.zeros(n + 1, dtype=bool)
            ev[0] = True
            ev[1:n] = line[1:] != line[:-1]
            ev[:n] |= ((self.code_np >> 2) & 3) != 0
            for x in extra:
                if 0 <= x <= n:
                    ev[x] = True
            ev[n] = True
            E = np.flatnonzero(ev).astype(np.uint32)
            ready = (self.code_np & 3) == READY
            reach = ready & ((self.code_np & 16) != 0)
            hr = np.maximum.reduceat(ready, E[:-1]).astype(np.uint8)
            hw = np.maximum.reduceat(reach, E[:-1]).astype(np.uint8)
            F = np.zeros(len(E), dtype=np.uint8)
            F[:-1] = hr | (hw << 1)
            self._events[key] = (array.array('I', E.tobytes()), array.array('B', F.tobytes()))
        return self._events[key]


# =============================================================================================
# 2. The replay
# =============================================================================================

def log2(x):
    k = x.bit_length() - 1
    if x <= 0 or (1 << k) != x:
        raise ValueError(f'{x} is not a power of two')
    return k


def simulate(tr, cfg, stat_from=0, reference=False):
    """Replay trace window `tr` with caches `cfg` (a dict, see make_config). Statistics count
    from trace cycle `stat_from` on (earlier cycles warm the caches up). Returns a dict of
    counters. With reference=True every cycle is stepped (the specification); otherwise
    quiet cycles are skipped, with exactly the same result."""
    line_bytes = cfg['line']
    lw = line_bytes // 4                       # words per line
    lshift = log2(lw)
    wmask = lw - 1
    iways, dways = cfg['iways'], cfg['dways']
    if iways not in (1, 2) or dways not in (1, 2):
        raise ValueError('1 or 2 ways')
    isets = cfg['ibytes'] // line_bytes // iways
    dsets = cfg['dbytes'] // line_bytes // dways
    if isets < 1 or dsets < 1:
        raise ValueError('cache smaller than one set')
    log2(isets); log2(dsets)
    imask, dmask = isets - 1, dsets - 1
    abort = cfg['abort']
    if cfg['evict'] not in ('miss', 'grant'):
        raise ValueError('evict: miss or grant')
    evict_at_grant = cfg['evict'] == 'grant'
    wbmode = cfg['wbuf']
    if wbmode not in WBUF_MODES:
        raise ValueError('wbuf: ' + ', '.join(WBUF_MODES))
    wait_flushed = cfg['wait_flushed']
    burst = cfg['mem'] == 'burst'
    rlo, rhi = cfg['rd_lat']
    wlo, whi = cfg['wr_lat']
    bcyc = cfg['beat_cycles']
    randint = random.Random(cfg['seed']).randint
    RS, RE = tr.ram_start, tr.ram_end

    FA, CODE, DADR = tr.fa, tr.code, tr.dadr
    n = tr.n
    E, EF = tr.events(lshift, (stat_from,))

    ITAG = [-1] * (isets * iways); ILRU = [0] * isets          # ILRU: the way to replace next
    ICAUSE = [0] * (isets * iways); IUSE = [0] * (isets * iways)
    DTAG = [-1] * (dsets * dways); DLRU = [0] * dsets

    NC = len(CAUSES)
    C = dict(i_refills=[0] * NC, i_done=0, i_abort_wait=[0] * NC, i_abort_run=[0] * NC,
             i_fate=[[0, 0, 0] for _ in range(NC)], i_left=0, snoop_inval=0,
             d_loads=0, d_load_misses=0, d_stores=0, d_store_hits=0,
             st_fetch=0, st_load=0, st_store=0,
             port_irefill=0, port_drefill=0, port_store=0, port_abort_tail=0,
             wait_i_for_port=0, wait_d_for_port=0,
             flushed_unanswered=0, hold_conflict=0,
             wb_accepts=0, wb_merges=0, wb_drains=0, wb_drain_words=0)
    fate = C['i_fate']

    def draw_read():
        """Cycles of one line refill and, with abort, the end offsets (exclusive) of its beats."""
        if burst:
            L = rlo if rlo == rhi else randint(rlo, rhi)
            if abort:
                return L + 1 + (lw - 1) * bcyc, [L + 1 + k * bcyc for k in range(lw)]
            return L + 1 + (lw - 1) * bcyc, None
        tot = 0
        ends = [] if abort else None
        for _ in range(lw):
            tot += (rlo if rlo == rhi else randint(rlo, rhi)) + 1
            if abort:
                ends.append(tot)
        return tot, ends

    def draw_write(words):
        """Port cycles of writing `words` words of one line (the buffered line)."""
        if burst:
            return (wlo if wlo == whi else randint(wlo, whi)) + 1 + (words - 1) * bcyc
        tot = 0
        for _ in range(words):
            tot += (wlo if wlo == whi else randint(wlo, whi)) + 1
        return tot

    T = 0; p = 0; ev = 0; nxt = E[0]
    port_free = 0                      # the port is free from this cycle on
    i_state = 0                        # 0 lookup, 1 refill waits for the port, 2 refill running
    i_line = -1; i_slot = 0; i_done = 0; i_beats = None; i_cause = 0; i_start = 0
    d_state = 0                        # 0 idle, 1 refill waits, 2 refill runs, 3 store waits, 4 store runs
    d_line = -1; d_slot = 0; d_done = 0; d_ack = 0
    d_served = False                   # the RAM access of trace cycle p has been answered
    st_issued = False                  # its store has been granted the port (or buffered)
    dptr = 0                           # index of the RAM access of trace cycle p (tr.dcyc order)
    d_loads = 0                        # kept local: the fast path counts it
    isl = 0
    held = -1                          # address Fetch keeps presenting after an unanswered
                                       # wrong-path fetch, until the next JUMP cycle
    wb_line = -1; wb_words = 0         # the line write buffer: its line (-1 empty), its words
    wb_drain = False; wb_end = 0       # it is being written, until wb_end
    snap = None; snap_T = 0; snap_loads = 0

    while p < n:
        if p == stat_from and snap is None:
            snap = json.loads(json.dumps(C)); snap_T = T; snap_loads = d_loads
        # ---------------------------------------------------------------- fast path
        # Nothing is running and the port is free: if this event cycle's lookups hit, the
        # following cycles up to the next event are hits in the same line, without RAM
        # accesses, so they take one cycle each and change nothing.
        if p == nxt and not reference and held < 0 and i_state == 0 and d_state == 0 and port_free <= T:
            c = CODE[p]
            dk = (c >> 2) & 3
            A = FA[p]
            dhit = True
            if dk:
                dl = DADR[dptr] >> lshift
                di = dl & dmask
                if dways == 1:
                    dsl = di
                    dhit = DTAG[di] == dl
                else:
                    dsl = di << 1
                    if DTAG[dsl] != dl:
                        dsl += 1
                        dhit = DTAG[dsl] == dl
            inwin = RS <= A < RE
            ihit = True
            if inwin:
                al = A >> lshift
                ii = al & imask
                if iways == 1:
                    isl = ii
                    ihit = ITAG[ii] == al
                else:
                    isl = ii << 1
                    if ITAG[isl] != al:
                        isl += 1
                        ihit = ITAG[isl] == al
            extra = -1               # cycles this trace cycle takes beyond one, if handled here
            if ihit and dk == 2 and wbmode == 'none':
                # a store, the fetch hits: the port is granted at once, the core waits W
                # cycles; the snoop acts at the acknowledge edge
                W = wlo if wlo == whi else randint(wlo, whi)
                C['port_store'] += W + 1
                C['st_store'] += W
                C['d_stores'] += 1
                if DTAG[dsl] == dl:
                    C['d_store_hits'] += 1
                extra = W
            elif ihit and (dk == 0 or dk == 1 and dhit):
                extra = 0
                if dk == 1:
                    d_loads += 1
                    if dways == 2:
                        DLRU[di] = (dsl & 1) ^ 1
            elif ihit and dk == 1 and wb_line < 0:
                # a load miss, the fetch hits: refill from T+1, taken at T+1+R
                if dways == 1:
                    d_slot = di
                else:
                    b = di << 1
                    d_slot = b if DTAG[b] == -1 else (b + 1 if DTAG[b + 1] == -1 else b + DLRU[di])
                C['d_load_misses'] += 1
                R, _ = draw_read()
                DTAG[d_slot] = dl
                if dways == 2:
                    DLRU[di] = (d_slot & 1) ^ 1
                C['port_drefill'] += R
                C['st_load'] += R + 1
                d_loads += 1
                extra = R + 1
            elif ((c & 3) == READY and (c & 16 or wait_flushed) and inwin and wb_line < 0
                  and (dk == 0 or dk == 1 and dhit)):
                # a READY fetch that must be answered misses: refill from T+1, taken at T+1+R
                cause = 0 if c & 16 else 4
                if iways == 1:
                    i_slot = ii
                else:
                    b = ii << 1
                    i_slot = b if ITAG[b] == -1 else (b + 1 if ITAG[b + 1] == -1 else b + ILRU[ii])
                if ITAG[i_slot] != -1:
                    fate[ICAUSE[i_slot]][IUSE[i_slot]] += 1
                C['i_refills'][cause] += 1
                R, _ = draw_read()
                ITAG[i_slot] = al; ICAUSE[i_slot] = cause; IUSE[i_slot] = 0
                isl = i_slot
                if iways == 2:
                    ILRU[ii] = (i_slot & 1) ^ 1
                C['i_done'] += 1
                C['port_irefill'] += R
                C['st_fetch'] += R + 1
                if dk == 1:
                    d_loads += 1
                    if dways == 2:
                        DLRU[di] = (dsl & 1) ^ 1
                extra = R + 1
            if extra >= 0:
                if dk:
                    dptr += 1
                # a store whose snoop drops the line being fetched ends the quiet stretch
                cut = dk == 2 and inwin and dl == al
                if inwin:
                    if iways == 2:
                        ILRU[ii] = (isl & 1) ^ 1
                    if not cut:
                        f = EF[ev]                       # every READY up to the next event
                    elif (c & 3) == READY:
                        f = 1 | ((c >> 3) & 2)           # only this cycle's fetch
                    else:
                        f = 0
                    if f & 2:
                        IUSE[isl] = 2
                    elif f & 1 and IUSE[isl] == 0:
                        IUSE[isl] = 1
                if dk == 2:
                    port_free = T + extra + 1
                    ii2 = dl & imask
                    for sl in ((ii2,) if iways == 1 else (ii2 << 1, (ii2 << 1) + 1)):
                        if ITAG[sl] == dl:
                            fate[ICAUSE[sl]][IUSE[sl]] += 1
                            ITAG[sl] = -1
                            C['snoop_inval'] += 1
                    if cut:
                        T += extra + 1
                        p += 1
                        while E[ev] < p:
                            ev += 1
                        nxt = E[ev]
                        continue
                elif extra:
                    port_free = T + extra
                ev += 1
                nxt = E[ev]
                T += nxt - p + extra
                p = nxt
                continue
        # ---------------------------------------------------------------- one cycle T
        c = CODE[p]
        s = c & 3
        dk = (c >> 2) & 3
        if held >= 0 and s == READY and c & 16:
            C['hold_conflict'] += 1            # a needed fetch while Fetch is held: see the header
            held = -1
        A = FA[p] if held < 0 else held
        inwin = RS <= A < RE
        al = A >> lshift
        if dk:
            dl = DADR[dptr] >> lshift
        need = s == READY and (c & 16 or wait_flushed)    # the core waits for this fetch
        changed = False
        # 1. refills and writes that end at the start of this cycle
        if i_state == 2 and T >= i_done:
            ITAG[i_slot] = i_line; ICAUSE[i_slot] = i_cause; IUSE[i_slot] = 0
            if iways == 2:
                ILRU[i_line & imask] = (i_slot & 1) ^ 1
            if not (inwin and al == i_line):
                C['i_left'] += 1
            C['i_done'] += 1
            i_state = 0; changed = True
        if d_state == 2 and T >= d_done:
            DTAG[d_slot] = d_line
            if dways == 2:
                DLRU[d_line & dmask] = (d_slot & 1) ^ 1
            d_state = 0; changed = True
        elif d_state == 4 and T > d_ack:
            d_state = 0; changed = True
        if wb_drain and T >= wb_end:
            wb_drain = False; wb_line = -1; wb_words = 0; changed = True
        # 2. abort-on-redirect: a waiting I-refill request is withdrawn when the presented
        #    address has left its line (before the arbiter can grant it)
        if abort and i_state == 1 and not (inwin and al == i_line):
            C['i_abort_wait'][i_cause] += 1
            i_state = 0; changed = True
        # 3. the memory port: data side first; a grant is never taken away
        store_now = dk == 2 and not st_issued and not d_served
        if port_free <= T:
            if (wb_line >= 0 and not wb_drain
                    and (d_state == 1 or i_state == 1 or store_now and dl != wb_line)):
                # the buffered line is written first: refills see an empty buffer, and a
                # store to another line waits for it
                k = bin(wb_words).count('1')
                Wc = draw_write(k)
                wb_drain = True; wb_end = T + Wc; port_free = T + Wc; changed = True
                C['port_store'] += Wc; C['wb_drains'] += 1; C['wb_drain_words'] += k
            elif d_state == 1:
                R, _ = draw_read()
                d_done = T + R; port_free = T + R; d_state = 2; changed = True
                C['port_drefill'] += R
            elif wbmode == 'none' and (d_state == 3 or (store_now and d_state == 0)):
                W = wlo if wlo == whi else randint(wlo, whi)
                d_ack = T + W; port_free = T + W + 1; d_state = 4; st_issued = True; changed = True
                C['port_store'] += W + 1
            elif i_state == 1:
                if evict_at_grant and ITAG[i_slot] != -1:
                    fate[ICAUSE[i_slot]][IUSE[i_slot]] += 1
                    ITAG[i_slot] = -1
                R, i_beats = draw_read()
                i_start = T; i_done = T + R; port_free = T + R; i_state = 2; changed = True
                C['port_irefill'] += R
        if store_now and not st_issued:
            if wbmode == 'ideal':
                # ideal write buffer (an upper bound): every store is taken at once and
                # written when the port is free, in order; refills wait for the port
                W = wlo if wlo == whi else randint(wlo, whi)
                port_free = (port_free if port_free > T else T) + W + 1
                C['port_store'] += W + 1
                st_issued = True; changed = True
            elif wbmode == 'line':
                if wb_line < 0:
                    wb_line = dl; wb_words = 1 << (DADR[dptr] & wmask)
                    st_issued = True; changed = True
                    C['wb_accepts'] += 1
                elif wb_line == dl and not wb_drain:
                    wb_words |= 1 << (DADR[dptr] & wmask)
                    st_issued = True; changed = True
                    C['wb_merges'] += 1
            elif d_state == 0:
                d_state = 3; changed = True
        if i_state == 1:
            C['wait_i_for_port'] += 1
        if d_state == 1 or d_state == 3:
            C['wait_d_for_port'] += 1
        # 4. the RAM access of this trace cycle
        snoop = -1
        if dk == 1:
            if not d_served and d_state == 0:
                di = dl & dmask
                if dways == 1:
                    dsl = di
                else:
                    dsl = di << 1
                    if DTAG[dsl] != dl:
                        dsl += 1
                if DTAG[dsl] == dl:
                    d_served = True
                    d_loads += 1
                    if dways == 2:
                        DLRU[di] = (dsl & 1) ^ 1
                else:
                    if dways == 1:
                        d_slot = di
                    else:
                        b = di << 1
                        d_slot = b if DTAG[b] == -1 else (b + 1 if DTAG[b + 1] == -1 else b + DLRU[di])
                    DTAG[d_slot] = -1
                    d_line = dl; d_state = 1; changed = True
                    C['d_load_misses'] += 1
            d_ok = d_served
        elif dk == 2:
            if not d_served and (wbmode != 'none' and st_issued or d_state == 4 and T == d_ack):
                d_served = True; changed = True
                C['d_stores'] += 1
                di = dl & dmask
                if DTAG[di * dways] == dl or (dways == 2 and DTAG[di * 2 + 1] == dl):
                    C['d_store_hits'] += 1
                snoop = dl
            d_ok = d_served
        else:
            d_ok = True
        # 5. the fetch lookup of this cycle
        f_ans = False
        if i_state != 0 and abort and not (inwin and al == i_line):
            # stop the running refill after the beat in flight; the line stays invalid
            k = T - i_start
            for e_ in i_beats:
                if e_ > k:
                    break
            end = i_start + e_
            C['port_abort_tail'] += end - T
            C['port_irefill'] -= i_done - end
            port_free = end
            C['i_abort_run'][i_cause] += 1
            i_state = 0; changed = True
        if not inwin:
            f_ans = True                               # err at once, in any state
        elif i_state == 0:
            ii = al & imask
            if iways == 1:
                isl = ii
            else:
                isl = ii << 1
                if ITAG[isl] != al:
                    isl += 1
            if ITAG[isl] == al:
                f_ans = True
                if iways == 2:
                    ILRU[ii] = (isl & 1) ^ 1
            else:
                if iways == 1:
                    i_slot = ii
                else:
                    b = ii << 1
                    i_slot = b if ITAG[b] == -1 else (b + 1 if ITAG[b + 1] == -1 else b + ILRU[ii])
                if not evict_at_grant and ITAG[i_slot] != -1:
                    fate[ICAUSE[i_slot]][IUSE[i_slot]] += 1
                    ITAG[i_slot] = -1
                i_line = al
                if not d_ok:
                    i_cause = 3
                elif s == READY:
                    i_cause = 0 if c & 16 else 4
                else:
                    i_cause = s
                C['i_refills'][i_cause] += 1
                i_state = 1; changed = True
        # 6. the trace cycle completes when its RAM access and a needed READY fetch are
        #    answered; an unanswered wrong-path fetch leaves Fetch presenting its address
        if d_ok and (f_ans or not need):
            if s == READY and f_ans and inwin:
                if c & 16:
                    IUSE[isl] = 2
                elif IUSE[isl] == 0:
                    IUSE[isl] = 1
            if s == JUMP or s == READY and f_ans:
                held = -1
            elif s == READY:
                held = A
                C['flushed_unanswered'] += 1
            if dk:
                dptr += 1
            d_served = False; st_issued = False
            p += 1
            while E[ev] < p:
                ev += 1
            nxt = E[ev]
            advanced = True
        else:
            advanced = False
            if not d_ok:
                if dk == 1:
                    C['st_load'] += 1
                else:
                    C['st_store'] += 1
            else:
                C['st_fetch'] += 1
        # a store's snoop acts at its acknowledge edge, after this cycle's lookup
        if snoop >= 0:
            ii = snoop & imask
            for sl in ((ii,) if iways == 1 else (ii << 1, (ii << 1) + 1)):
                if ITAG[sl] == snoop:
                    fate[ICAUSE[sl]][IUSE[sl]] += 1
                    ITAG[sl] = -1
                    C['snoop_inval'] += 1
        T += 1
        # the core waits and nothing changed: nothing can change before the next end of a
        # refill or write, or before the port frees for a waiting request
        if not reference and not advanced and not changed:
            t = 1 << 62
            if i_state == 2 and i_done < t:
                t = i_done
            if d_state == 2 and d_done < t:
                t = d_done
            if d_state == 4 and d_ack < t:
                t = d_ack
            if wb_drain and wb_end < t:
                t = wb_end
            if ((i_state == 1 or d_state == 1 or d_state == 3 or dk == 2 and not st_issued and wb_line >= 0)
                    and port_free < t):
                t = port_free
            if t != 1 << 62 and t > T:
                k = t - T
                if not d_ok:
                    if dk == 1:
                        C['st_load'] += k
                    else:
                        C['st_store'] += k
                else:
                    C['st_fetch'] += k
                if i_state == 1:
                    C['wait_i_for_port'] += k
                if d_state == 1 or d_state == 3:
                    C['wait_d_for_port'] += k
                T = t
    C['d_loads'] = d_loads
    if snap is None:
        snap = json.loads(json.dumps(C)); snap_T = T; snap_loads = d_loads
    snap['d_loads'] = snap_loads
    for sl in range(len(ITAG)):                       # lines still cached at the end
        if ITAG[sl] != -1:
            fate[ICAUSE[sl]][IUSE[sl]] += 1

    def diff(a, b):
        if isinstance(a, list):
            return [diff(x, y) for x, y in zip(a, b)]
        return a - b
    R = {k: diff(C[k], snap[k]) for k in C}
    R['cycles'] = T - snap_T
    R['cycles_total'] = T
    return R


# =============================================================================================
# 3. Configurations, running, reporting
# =============================================================================================

def make_config(ibytes=8192, dbytes=4096, line=16, ways=1, iways=None, dways=None, mem='burst',
                rd_lat=(8, 24), wr_lat=(1, 4), beat_cycles=1, abort=False, evict='miss',
                wbuf='none', wait_flushed=False, seed=1):
    return dict(ibytes=ibytes, dbytes=dbytes, line=line, iways=iways or ways, dways=dways or ways,
                mem=mem, rd_lat=tuple(rd_lat), wr_lat=tuple(wr_lat), beat_cycles=beat_cycles,
                abort=bool(abort), evict=evict, wbuf=wbuf, wait_flushed=bool(wait_flushed), seed=seed)


def summarize(tr, cfg, R, stat_from, wall):
    ninst = tr.instructions(stat_from)
    base = tr.n - stat_from
    out = dict(trace=tr.name, window=[tr.w0 + stat_from, tr.w1], cfg=cfg, instructions=ninst,
               cycles_base=base, cpi_base=base / ninst, cycles=R['cycles'], cpi=R['cycles'] / ninst,
               wall_s=round(wall, 2))
    k = 1000.0 / ninst
    irefills = sum(R['i_refills'])
    out['i_mpki'] = R['i_done'] * k
    out['i_refills_started_pki'] = irefills * k
    out['i_refills_by_cause_pki'] = {CAUSES[i]: R['i_refills'][i] * k for i in range(len(CAUSES))}
    # refilled lines that no fetch reaching Writeback ever took (wasted refills)
    out['i_wasted_pki'] = sum(f[0] + f[1] for f in R['i_fate']) * k
    out['i_aborted_pki'] = (sum(R['i_abort_wait']) + sum(R['i_abort_run'])) * k
    out['d_mpki'] = R['d_load_misses'] * k
    out['store_stall_share'] = R['st_store'] / R['cycles']
    out['stall_share'] = {x: R['st_' + x] / R['cycles'] for x in ('fetch', 'load', 'store')}
    out['port_share'] = (R['port_irefill'] + R['port_drefill'] + R['port_store'] + R['port_abort_tail']) / R['cycles']
    out['raw'] = R
    return out


def cfg_label(cfg):
    ways = f"{cfg['iways']}" if cfg['iways'] == cfg['dways'] else f"{cfg['iways']}:{cfg['dways']}"
    return (f"I{cfg['ibytes']:>6} D{cfg['dbytes']:>6} L{cfg['line']:>2} w{ways} {cfg['mem']:5s} "
            f"ab{int(cfg['abort'])}{'g' if cfg['evict'] == 'grant' else 'm'} wb-{cfg['wbuf']:5s} "
            f"{'wf ' if cfg['wait_flushed'] else ''}rd{cfg['rd_lat'][0]}:{cfg['rd_lat'][1]} "
            f"wr{cfg['wr_lat'][0]}:{cfg['wr_lat'][1]}")


def run_main(a):
    cfgs = []
    for line in a.line:
        for ways in a.ways:
            iw, _, dw = ways.partition(':')
            iw = int(iw); dw = int(dw) if dw else iw
            for mem in a.mem:
                for ab in a.abort:
                    for evict in a.evict:
                        if evict == 'grant' and not ab and len(a.evict) > 1:
                            continue            # identical to evict=miss without abort
                        for wb in a.wbuf:
                            for wf in a.wait_flushed:
                                for ib, db in pairs(a):
                                    cfgs.append(make_config(ib, db, line, iways=iw, dways=dw, mem=mem,
                                                            rd_lat=a.rd_lat,
                                                            wr_lat=a.wr_lat, beat_cycles=a.beat_cycles,
                                                            abort=ab, evict=evict, wbuf=wb,
                                                            wait_flushed=wf, seed=a.seed))
    out = open(a.out, 'a') if a.out else sys.stdout
    for d in a.traces:
        tr = Trace(d, a.w0, a.w1)
        stat_from = max(0, (a.stat_from or 0) - a.w0)
        for cfg in cfgs:
            t0 = time.time()
            R = simulate(tr, cfg, stat_from, reference=a.reference)
            res = summarize(tr, cfg, R, stat_from, time.time() - t0)
            out.write(json.dumps(res) + '\n'); out.flush()
            if a.out:
                print(f"{tr.name:14s} {cfg_label(cfg)}: CPI {res['cpi_base']:.3f} -> {res['cpi']:.3f}  "
                      f"I-MPKI {res['i_mpki']:.2f}  D-MPKI {res['d_mpki']:.2f}  ({res['wall_s']} s)", flush=True)


def pairs(a):
    if a.pair:
        return list(zip(a.isize, a.dsize))
    return [(i, d) for i in a.isize for d in a.dsize]


def parse_range(s):
    lo, _, hi = s.partition(':')
    lo = int(lo); hi = int(hi) if hi else lo
    if not 0 <= lo <= hi:
        raise argparse.ArgumentTypeError(f'bad range {s}')
    return (lo, hi)


def stats_main(a):
    for d in a.traces:
        tr = Trace(d)
        m = tr.meta
        code = tr.code_np
        st = code & 3
        n = tr.n
        ninst = tr.instructions()
        cons = (st == READY)
        reach = cons & ((code & 16) != 0)
        print(f"{tr.name}: cycles {n}  retired {ninst}  CPI {n / ninst:.3f}")
        print(f"  fetch: READY {int(cons.sum())} ({cons.sum() / ninst:.3f}/instr, reaching Writeback "
              f"{int(reach.sum())}), STALL {int((st == STALL).sum())} ({(st == STALL).sum() / ninst:.3f}/instr), "
              f"JUMP {int((st == JUMP).sum())} ({(st == JUMP).sum() / ninst:.3f}/instr)")
        print(f"  data: RAM loads {m['ram_loads']} ({m['ram_loads'] / ninst:.3f}/instr), RAM stores "
              f"{m['ram_stores']} ({m['ram_stores'] / ninst:.3f}/instr), I/O accesses {m['io_accesses']} "
              f"in {m['io_cycles']} cycles")
        print(f"  checks: fetch err {m['fetch_err']}, data err {m['data_err']}, multi-cycle RAM "
              f"accesses {m['ram_multicycle']}, later reset cycles {m['reset_later']}, Writeback "
              f"instructions not matched {m['wb_unmatched']} of {m['wb_nonbubble']} (matched against "
              f"the rule {m.get('wb_rule_broken', '-')}, without a successor that keeps it "
              f"{m.get('wb_lookahead_failed', '-')})")


# =============================================================================================
# 4. Self-check: hand-computed cases, and the fast replay against the per-cycle replay
# =============================================================================================

class Synthetic(Trace):
    """A trace built in memory: per cycle (fetch address, status[, reaches Writeback]) and
    RAM accesses (cycle, word address, is a store). A READY fetch reaches Writeback unless
    the third element says otherwise."""

    def __init__(self, fetch, data=(), ram_words=0x2000, name='synthetic'):
        self.meta = dict(name=name)
        self.name = name
        self.w0, self.w1 = 0, len(fetch)
        self.n = len(fetch)
        fa = np.array([x[0] for x in fetch], dtype=np.uint32)
        code = np.array([x[1] | (16 if x[1] == READY and (len(x) < 3 or x[2]) else 0) | 32
                         for x in fetch], dtype=np.uint8)
        dc, da = [], []
        for (cyc, adr, we) in data:
            code[cyc] |= (2 if we else 1) << 2
            dc.append(cyc); da.append(adr)
        self.fa_np, self.code_np = fa, code
        self.dcyc_np = np.array(dc, dtype=np.uint32)
        self.dadr_np = np.array(da, dtype=np.uint32)
        self.ram_start, self.ram_end = RAM_START, RAM_START + ram_words
        self.fa = array.array('I', fa.tobytes())
        self.code = array.array('B', code.tobytes())
        self.dadr = array.array('I', self.dadr_np.tobytes())
        self._events = {}


def selftest():
    ok = True

    def expect(what, got, want):
        nonlocal ok
        flag = 'ok ' if got == want else 'BAD'
        if got != want:
            ok = False
        print(f'  {flag} {what}: got {got}, expected {want}')

    def both(tr, cfg):
        for ref in (True, False):
            yield ('reference' if ref else 'fast'), simulate(tr, cfg, reference=ref)

    B = RAM_START
    # straight-line code, 8 words, 16-byte lines, per-beat memory with L = 2 (3 cycles a word)
    tr = Synthetic([(B + k, READY) for k in range(8)])
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), wr_lat=(1, 1))
    for how, R in both(tr, cfg):
        # each line: miss at t, refill 4*3 = 12 cycles from t+1, taken at t+13 -> +13 per line
        expect(f'straight line, {how}: cycles', R['cycles'], 8 + 2 * 13)
        expect('  refills', R['i_refills'], [2, 0, 0, 0, 0])
    # burst memory: R = L + 1 + 3 = 6 -> +7 per line
    cfg = make_config(512, 512, 16, 1, mem='burst', rd_lat=(2, 2))
    expect('straight line, burst: cycles', simulate(tr, cfg)['cycles'], 8 + 2 * 7)
    # a JUMP cycle presents a wrong-path word in a new line, then the target (cached) follows
    fetch = [(B, READY), (B + 1, READY), (B + 2, READY), (B + 3, READY),   # line 0
             (B + 4, JUMP),                                                # wrong path: line 1
             (B, READY), (B + 1, READY)]                                   # back to line 0
    tr = Synthetic(fetch)
    for ab in (False, True):
        cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), abort=ab)
        for how, R in both(tr, cfg):
            # line 0: +13. JUMP-cycle miss of line 1 at t=17: without abort its refill runs
            # 18..29 and the target is taken at 30 instead of 18 (+12); with abort the
            # request is withdrawn at 18 before any beat is issued (+0)
            want = 7 + 13 + (0 if ab else 12)
            expect(f'wrong-path JUMP miss, abort={ab}, {how}: cycles', R['cycles'], want)
            expect('  refills started (ready, stall, jump, dwait, flushed)', R['i_refills'], [1, 0, 1, 0, 0])
            expect('  aborted before the port', R['i_abort_wait'], [0, 0, 1 if ab else 0, 0, 0])
    # a store: 1 + W cycles; it drops the I-line it hits (snoop); write latency 3
    fetch = [(B + k, READY) for k in range(4)] + [(B + k, READY) for k in range(4)]
    tr = Synthetic(fetch, data=[(5, B + 2, True)])
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), wr_lat=(3, 3))
    for how, R in both(tr, cfg):
        # +13 first line; store at cycle 5 (+3); the snoop drops line 0 at its acknowledge,
        # so the fetch of B+2 in cycle 6 misses again (+13)
        expect(f'store with snoop, {how}: cycles', R['cycles'], 8 + 13 + 3 + 13)
        expect('  snoop invalidations', R['snoop_inval'], 1)
        expect('  store stall cycles', R['st_store'], 3)
    # a load miss while an I-refill started in a STALL cycle holds the port
    fetch = [(B + 8, STALL), (B + 8, STALL), (B + 8, STALL), (B + 8, READY)]
    tr = Synthetic(fetch, data=[(1, B + 100, False)])
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2))
    for how, R in both(tr, cfg):
        # t0: I miss (stall) -> I-refill 1..12. t1: load miss -> waits for the port until 13,
        # D-refill 13..24, taken at 25 (trace cycle 1 completes at 25). t2,3 follow: line
        # valid since 13 -> cycles = 25 + 1 (cycle 1) + 2 = 28
        expect(f'load miss behind a running I-refill, {how}: cycles', R['cycles'], 28)
        expect('  D waited for the port (cycles)', R['wait_d_for_port'], 11)
    # a wrong-path READY fetch (its word is flushed) misses; the JUMP and the cached target
    # follow. It does not hold the core, and abort stops its refill when the target appears.
    fetch = [(B, READY), (B + 1, READY), (B + 2, READY), (B + 3, READY),   # line 0
             (B + 4, READY, False),                                        # wrong path: line 1
             (B + 5, JUMP),
             (B, READY), (B + 1, READY)]                                   # target: line 0
    tr = Synthetic(fetch)
    for ab, wf, want in ((False, False, 32), (True, False, 21), (False, True, 34), (True, True, 34)):
        cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), abort=ab, wait_flushed=wf)
        for how, R in both(tr, cfg):
            # line 0 taken at 13, cycles 1-3 at 14-16. The wrong-path miss at 17 asks for the
            # port; the JUMP cycle (18) still presents B+4 and the refill is granted (18..29).
            # The target B at 19: without abort it waits for the refill, taken at 30 (32 in
            # all); with abort the refill stops after the beat in flight (18..20) and B hits
            # at 19 (21 in all). --wait-flushed holds the core at 17 until 30 (34 in all),
            # with or without abort.
            expect(f'wrong-path READY miss, abort={ab}, wait-flushed={wf}, {how}: cycles', R['cycles'], want)
            expect('  refills started (ready, stall, jump, dwait, flushed)', R['i_refills'], [1, 0, 0, 0, 1])
            expect('  running refills stopped', R['i_abort_run'], [0, 0, 0, 0, 1 if ab and not wf else 0])
            expect('  port cycles of I-refills', R['port_irefill'], 12 + (3 if ab and not wf else 12))
    # Fetch stays at the unanswered wrong-path address until the JUMP: the JUMP cycle's own
    # address B+8 (line 2) is never looked up, and only the target ends the refill of line 1
    fetch = [(B, READY), (B + 1, READY), (B + 2, READY), (B + 3, READY),
             (B + 7, READY, False), (B + 8, JUMP), (B, READY), (B + 1, READY)]
    tr = Synthetic(fetch)
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), abort=True, evict='grant')
    for how, R in both(tr, cfg):
        expect(f'held wrong-path address, {how}: cycles', R['cycles'], 21)
        expect('  refills started', R['i_refills'], [1, 0, 0, 0, 1])
        expect('  withdrawn / stopped', (R['i_abort_wait'], R['i_abort_run']), ([0] * 5, [0, 0, 0, 0, 1]))
        expect('  unanswered wrong-path fetches', R['flushed_unanswered'], 1)
    # a JUMP-cycle lookup in the set of the target's line (512 B, 16 B lines: 128 words
    # apart): with abort, dropping the victim at the miss still costs the target a refill;
    # dropping it only at the grant costs nothing
    fetch = [(B, READY), (B + 1, READY), (B + 2, READY), (B + 3, READY),
             (B + 128, JUMP), (B, READY), (B + 1, READY)]
    tr = Synthetic(fetch)
    for ab, evict, want in ((False, 'miss', 45), (False, 'grant', 45), (True, 'miss', 33), (True, 'grant', 20)):
        cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), abort=ab, evict=evict)
        for how, R in both(tr, cfg):
            # line 0 by 16. JUMP miss at 17. No abort: refill 18..29, the target misses at 30,
            # refill 31..42, taken at 43 (45 in all). Abort, evict at the miss: withdrawn at
            # 18, B misses, refill 19..30, taken at 31 (33). Evict at the grant: B hits at 18.
            expect(f'conflicting JUMP lookup, abort={ab}, evict={evict}, {how}: cycles', R['cycles'], want)
    # the line write buffer: two stores to one line merge; a store to another line waits
    # while the first line is written; a load miss waits until the buffer is empty
    fetch = [(B + k % 4, READY) for k in range(8)]                         # all in line 0
    data = [(2, B + 1000, True), (3, B + 1001, True), (5, B + 1100, True), (6, B + 1200, False)]
    tr = Synthetic(fetch, data=data)
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), wr_lat=(3, 3), wbuf='line')
    for how, R in both(tr, cfg):
        # line 0 at 13, cycles 1-4 at 14-17 (stores taken at 15 and 16, merged). The store at
        # 18 (another line) starts the write of 2 words (2 * 4 cycles, 18..25) and is taken at
        # 26. The load at 27 misses; the buffer (1 word) is written 28..31; refill 32..43;
        # taken at 44; cycle 7 at 45 -> 46 in all
        expect(f'line write buffer, {how}: cycles', R['cycles'], 46)
        expect('  accepted, merged, written', (R['wb_accepts'], R['wb_merges'], R['wb_drains'], R['wb_drain_words']),
               (2, 1, 2, 3))
        expect('  store and load stall cycles', (R['st_store'], R['st_load']), (8, 17))
    cfg = make_config(512, 512, 16, 1, mem='beat', rd_lat=(2, 2), wr_lat=(3, 3), wbuf='ideal')
    for how, R in both(tr, cfg):
        # the stores are taken at once; the port is busy with them until 27, so the load miss
        # at 19 is refilled 27..38 and taken at 39 -> 41 in all
        expect(f'ideal write buffer, {how}: cycles', R['cycles'], 41)
    return ok


def check_main(a):
    print('hand-computed cases:')
    good = selftest()
    for d in a.traces:
        tr = Trace(d, a.w0, a.w1)
        stat_from = max(0, (a.stat_from or 0) - a.w0)
        print(f'fast replay against the per-cycle replay on {tr.name} [{tr.w0}, {tr.w1}), '
              f'counting from {tr.w0 + stat_from}:')
        for cfg in (make_config(512, 512, 16, 1, mem='beat'),
                    make_config(1024, 512, 8, 2, mem='burst', abort=True),
                    make_config(2048, 1024, 32, 1, mem='beat', abort=True, evict='grant'),
                    make_config(4096, 2048, 16, 2, mem='burst', wbuf='ideal'),
                    make_config(512, 1024, 32, 2, mem='beat', rd_lat=(0, 3), wr_lat=(0, 2), abort=True,
                                evict='grant', wbuf='line'),
                    make_config(8192, 4096, 16, 1, mem='burst', wbuf='line'),
                    make_config(16384, 8192, 32, 2, mem='beat', abort=True, wait_flushed=True),
                    make_config(8192, 4096, 32, 1, mem='burst', rd_lat=(2, 2), wr_lat=(1, 1), abort=True,
                                evict='grant', wbuf='line')):
            t0 = time.time(); Rr = simulate(tr, cfg, stat_from, reference=True); t1 = time.time()
            Rf = simulate(tr, cfg, stat_from, reference=False); t2 = time.time()
            same = Rr == Rf
            good &= same
            print(f"  {'same' if same else 'DIFFERENT'}: {cfg_label(cfg)}: cycles "
                  f"{Rr['cycles']} / {Rf['cycles']}  ({t1 - t0:.1f} s / {t2 - t1:.1f} s)")
            if not same:
                for k in Rr:
                    if Rr[k] != Rf[k]:
                        print(f'      {k}: {Rr[k]} / {Rf[k]}')
    print('CHECK:', 'PASS' if good else 'FAIL')
    return 0 if good else 1


def main():
    ap = argparse.ArgumentParser(description='Trace-driven model of the planned L1 caches (see the file header).')
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('prep', help='prepare a bustrace.bin')
    p.add_argument('trace'); p.add_argument('outdir')
    p.add_argument('--ram-kb', type=int, required=True, help='RAM size of the simulator (FRTOS_RAM_KB)')
    p.add_argument('--name')
    p = sub.add_parser('stats', help='statistics of prepared traces')
    p.add_argument('traces', nargs='+')
    for name in ('run', 'check'):
        p = sub.add_parser(name)
        p.add_argument('traces', nargs='*')
        p.add_argument('--w0', type=int, default=0, help='first cycle of the window')
        p.add_argument('--w1', type=int, default=None, help='end of the window')
        p.add_argument('--stat-from', type=int, default=None, help='count from this cycle (warm-up before)')
        if name == 'run':
            p.add_argument('--isize', type=int, nargs='+', default=[8192])
            p.add_argument('--dsize', type=int, nargs='+', default=[4096])
            p.add_argument('--pair', action='store_true', help='pair --isize and --dsize instead of all combinations')
            p.add_argument('--line', type=int, nargs='+', default=[16])
            p.add_argument('--ways', nargs='+', default=['1'],
                           help='1 or 2 for both caches, or I:D, for example 2:1 (2-way I-cache, direct-mapped D-cache)')
            p.add_argument('--mem', nargs='+', default=['burst'], choices=['beat', 'burst'])
            p.add_argument('--rd-lat', type=parse_range, default=(8, 24))
            p.add_argument('--wr-lat', type=parse_range, default=(1, 4))
            p.add_argument('--beat-cycles', type=int, default=1)
            p.add_argument('--abort', type=int, nargs='+', default=[0])
            p.add_argument('--evict', nargs='+', default=['miss'], choices=['miss', 'grant'],
                           help='drop the victim at the miss or at the grant (with --abort 0 only miss is run)')
            p.add_argument('--wbuf', nargs='+', default=['none'], choices=list(WBUF_MODES))
            p.add_argument('--wait-flushed', type=int, nargs='+', default=[0],
                           help='1: wrong-path READY fetches hold the core like any other')
            p.add_argument('--seed', type=int, default=1)
            p.add_argument('--reference', action='store_true', help='plain per-cycle replay')
            p.add_argument('--out')
    a = ap.parse_args()
    if a.cmd == 'prep':
        m = prep(a.trace, a.outdir, a.ram_kb, a.name)
        print(json.dumps(m, indent=1))
    elif a.cmd == 'stats':
        stats_main(a)
    elif a.cmd == 'run':
        run_main(a)
    elif a.cmd == 'check':
        return check_main(a)
    return 0


if __name__ == '__main__':
    sys.exit(main())
