#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""iss.py -- timing-independent architectural oracle for test/trapsweep.

A small RV32IM(+Zba)+Zicsr instruction-set model of the bare-metal MCU: a
separate implementation in Python, neither the RTL nor the frozen golden
models (it does encode this platform's CSR map, reset values and memory map). It
replays an RTL run (DUT or golden) using ONLY the RTL's choice of interrupt
boundaries, which it reads from the RTL trace (minstret at each trap entry +
mcause), and checks that everything else the RTL did is architecturally
explainable:
  * every interrupt is taken at an instruction boundary where it is enabled
    (mstatus.MIE and mie.MxIE) and its source is armed,
  * every exception the program raises is taken, with the right cause, exactly
    at that instruction (never lost, never duplicated, never out of place),
  * the whole trace-port stream (CSR values seen by handlers, result registers,
    minstret deltas, final register dump) is identical to the ISS's.
Values that depend on timing (mip, mcycle, time, peripheral counters) are
tainted and compared as wildcards.

The program must follow the trace protocol of probes.py (trap-entry records at
0x10/0x14/0x1C, iteration headers at 0x00, minstret snapshot at 0x38, ...).
Kind 'ref' (the golden CPU) is modelled without M, Zba and Zicntr, and with its
minstret reading one higher than the DUT's from reset (a golden quirk).
To check a NEW instruction, add it to ISS.step() (and, for a new CSR, to
CSR_VALID/csr_read/csr_write); the frozen golden models cannot check it.

usage: iss.py <rundir> [dut] [ref] [--nom] [-v]
       (reads <rundir>/init.bin and <rundir>/<kind>/sim.log; --nom: no M extension)
"""
import sys, struct

RAM0, RAMN = 0x40000, 0x8000
TRACE0, TRACE1 = 0x47E00, 0x47F00

class Viol(Exception):
    pass

def sx(v, b):
    v &= (1 << b) - 1
    return v - (1 << b) if v >> (b - 1) else v

M32 = 0xffffffff

class ISS:
    def __init__(self, binf, instret_off=0, has_m=True, has_zba=True):
        data = open(binf, 'rb').read()
        self.ram = bytearray(RAMN); self.ram[:len(data)] = data
        self.x = [0] * 32; self.tx = [False] * 32   # value, taint
        self.pc = RAM0
        self.mie_b = 0; self.mpie = 1               # reset: MPIE=1 (both DUT and golden)
        self.meie = 0; self.mtie = 0
        self.mtvec = 0; self.mepc = 0; self.mcause = 0; self.mscratch = 0
        self.minstret = instret_off; self.off = instret_off
        self.ext_armed = False; self.timer_cmph = 0; self.timer_cmpl = 0
        self.leds = 0; self.stall = 0; self.vga = {}
        self.trace = []; self.halted = False
        self.has_m = has_m; self.has_zba = has_zba
        self.taint_mem = set()
        self.bp_ctl = 0
        self.no_zicntr = False
        self.on_trace = None

    # ---------------- memory -----------------
    def load(self, a, n):
        """returns (value, tainted) or raises ('fault')"""
        if RAM0 <= a < RAM0 + RAMN:
            v = int.from_bytes(self.ram[a - RAM0:a - RAM0 + n], 'little')
            t = (a & ~3) in self.taint_mem
            return v, t
        w = a & ~3; sh = (a & 3) * 8
        if w == 0x480000: return 0, False
        if w == 0x480004: return 0, True          # interrupt counter (timing)
        if w == 0x480008: return 0, True          # free-running counter
        if w == 0x48000C: return (self.stall >> sh) & ((1 << 8 * n) - 1), False
        if w == 0x480010: raise Viol('fault')
        if w == 0x200000: return ((self.leds & 0xffff) >> sh) & ((1 << 8 * n) - 1), False
        if 0x214000 <= w < 0x214014:
            if w == 0x21400C: return (self.timer_cmpl >> sh) & ((1 << 8 * n) - 1), False
            if w == 0x214010: return (self.timer_cmph >> sh) & ((1 << 8 * n) - 1), False
            return 0, True
        if w == 0x210000: return 0, True
        if 0x240000 <= w < 0x240000 + 0x9600 * 4:
            return (self.vga.get(w, 0) >> sh) & ((1 << 8 * n) - 1), False
        if w in (0x204000, 0x208000, 0x20C000): return 0, True
        raise Viol('fault')

    def store(self, a, n, v, t):
        v &= (1 << 8 * n) - 1
        if RAM0 <= a < RAM0 + RAMN:
            self.ram[a - RAM0:a - RAM0 + n] = v.to_bytes(n, 'little')
            if t: self.taint_mem.add(a & ~3)
            elif n == 4: self.taint_mem.discard(a & ~3)
            if TRACE0 <= a < TRACE1:
                self.trace.append((a - TRACE0, v, t))
                if self.on_trace: self.on_trace(a - TRACE0, v)
            return
        w = a & ~3; sh = (a & 3) * 8
        if w == 0x480000:
            if v == 2: self.halted = True
            return
        if w == 0x480004:
            self.ext_armed = (v != 0); return      # RTL uses the full word (no byte lanes)
        if w == 0x480008: return
        if w == 0x48000C:
            m = ((1 << 8 * n) - 1) << sh; self.stall = (self.stall & ~m) | (v << sh); return
        if w == 0x480010: raise Viol('fault')
        if w == 0x200000:
            m = ((1 << 8 * n) - 1) << sh; self.leds = ((self.leds & ~m) | (v << sh)) & 0xffff; return
        if 0x214000 <= w < 0x214014:
            m = ((1 << 8 * n) - 1) << sh
            if w == 0x21400C: self.timer_cmpl = (self.timer_cmpl & ~m) | (v << sh)
            if w == 0x214010: self.timer_cmph = (self.timer_cmph & ~m) | (v << sh)
            return
        if w == 0x210000: return
        if 0x240000 <= w < 0x240000 + 0x9600 * 4:
            m = ((1 << 8 * n) - 1) << sh; self.vga[w] = (self.vga.get(w, 0) & ~m) | (v << sh); return
        if w == 0x20C000: return
        raise Viol('fault')

    # ---------------- CSRs -------------------
    CSR_VALID = set([0xF11, 0xF12, 0xF13, 0xF14, 0xF15, 0x300, 0x301, 0x302, 0x303, 0x304, 0x305, 0x306, 0x310,
                     0x340, 0x341, 0x342, 0x343, 0x344, 0xB00, 0xB02, 0xB80, 0xB82, 0xC00, 0xC01, 0xC02, 0xC80, 0xC81, 0xC82]
                    + list(range(0xB03, 0xB20)) + list(range(0xB83, 0xBA0)) + list(range(0x323, 0x340)))

    def csr_read(self, c):
        if c == 0x300: return (self.mpie << 7) | (self.mie_b << 3), False
        if c == 0x304: return (self.meie << 11) | (self.mtie << 7), False
        if c == 0x305: return self.mtvec, False
        if c == 0x341: return self.mepc, False
        if c == 0x342: return self.mcause, False
        if c == 0x340: return self.mscratch, False
        if c == 0x344: return 0, True                                  # mip: timing
        if c in (0xB02, 0xC02): return self.minstret & M32, False
        if c in (0xB82, 0xC82): return (self.minstret >> 32) & M32, False
        if c in (0xB00, 0xC00, 0xB80, 0xC80, 0xC01, 0xC81): return 0, True   # cycle/time: timing
        if c == 0x323 + 7: return self.bp_ctl, False                   # mhpmevent10
        if c in (0xB0A, 0xB0B, 0xB0C, 0xB0D): return 0, True          # bp counters: timing-ish
        return 0, False

    def csr_write(self, c, v):
        if c == 0x300: self.mie_b = (v >> 3) & 1; self.mpie = (v >> 7) & 1
        elif c == 0x304: self.meie = (v >> 11) & 1; self.mtie = (v >> 7) & 1
        elif c == 0x305: self.mtvec = v & ~3 & M32
        elif c == 0x341: self.mepc = v & ~3 & M32
        elif c == 0x342: self.mcause = v & M32
        elif c == 0x340: self.mscratch = v & M32
        elif c == 0x323 + 7: self.bp_ctl = v & M32
        elif c == 0xB02: self.minstret = ((self.minstret & ~M32) | v) - 1     # the writing instruction is not counted
        elif c == 0xB82: self.minstret = ((v << 32) | (self.minstret & M32)) - 1
        elif c in (0xB00, 0xB80): pass

    # ---------------- traps ------------------
    def trap(self, cause, epc):
        self.mcause = cause & M32; self.mepc = epc & ~3 & M32
        self.mpie = self.mie_b; self.mie_b = 0
        self.pc = self.mtvec

    def irq_enabled(self, cause):
        if not self.mie_b: return False
        if cause == 0x8000000B: return bool(self.meie) and self.ext_armed
        if cause == 0x80000007: return bool(self.mtie) and self.timer_cmph != 0xffffffff
        return False

    # ---------------- execute one instruction ------------------
    def step(self):
        """Executes one instruction. Returns None (retired) or an exception cause."""
        pc = self.pc
        if not (RAM0 <= pc < RAM0 + RAMN) or pc & 3:
            return 1 if pc & 3 == 0 else 0
        ins = int.from_bytes(self.ram[pc - RAM0:pc - RAM0 + 4], 'little')
        op = ins & 0x7f; rd = (ins >> 7) & 31; f3 = (ins >> 12) & 7; rs1 = (ins >> 15) & 31; rs2 = (ins >> 20) & 31
        f7 = ins >> 25
        a, ta = self.x[rs1], self.tx[rs1]; b, tb = self.x[rs2], self.tx[rs2]
        npc = (pc + 4) & M32
        def wr(v, t=False):
            if rd: self.x[rd] = v & M32; self.tx[rd] = t
        if op == 0x37: wr(ins & 0xfffff000)
        elif op == 0x17: wr(pc + (ins & 0xfffff000))
        elif op == 0x6f:
            imm = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xff) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3ff) << 1), 21)
            if (pc + imm) & 3: return 0
            wr(pc + 4); npc = (pc + imm) & M32
        elif op == 0x67 and f3 == 0:
            if ta: raise Viol('ISS: jalr on tainted register')
            t = (a + sx(ins >> 20, 12)) & ~1 & M32
            if t & 3: return 0
            wr(pc + 4); npc = t
        elif op == 0x63:
            imm = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3f) << 5) | (((ins >> 8) & 0xf) << 1), 13)
            if f3 in (2, 3): return 2
            if ta or tb: raise Viol(f'ISS: branch on tainted register at {pc:x}')
            sa, sb = sx(a, 32), sx(b, 32)
            c = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb, 6: a < b, 7: a >= b}[f3]
            if c:
                if (pc + imm) & 3: return 0
                npc = (pc + imm) & M32
        elif op == 0x03:
            if f3 not in (0, 1, 2, 4, 5): return 2
            if ta: raise Viol('ISS: load address tainted')
            addr = (a + sx(ins >> 20, 12)) & M32
            n = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}[f3]
            if addr % n: return 4
            try: v, t = self.load(addr, n)
            except Viol: return 5
            if f3 == 0: v = sx(v, 8) & M32
            if f3 == 1: v = sx(v, 16) & M32
            wr(v, t)
        elif op == 0x23:
            if f3 not in (0, 1, 2): return 2
            if ta: raise Viol('ISS: store address tainted')
            addr = (a + sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)) & M32
            n = {0: 1, 1: 2, 2: 4}[f3]
            if addr % n: return 6
            try: self.store(addr, n, b, tb)
            except Viol: return 7
        elif op == 0x13:
            imm = sx(ins >> 20, 12) & M32; sh = (ins >> 20) & 31
            if f3 == 0: v = a + imm
            elif f3 == 2: v = int(sx(a, 32) < sx(imm, 32))
            elif f3 == 3: v = int(a < imm)
            elif f3 == 4: v = a ^ imm
            elif f3 == 6: v = a | imm
            elif f3 == 7: v = a & imm
            elif f3 == 1:
                if f7 != 0: return 2
                v = a << sh
            else:
                if f7 == 0: v = a >> sh
                elif f7 == 0x20: v = (sx(a, 32) >> sh)
                else: return 2
            wr(v & M32, ta)
        elif op == 0x33:
            t = ta or tb
            if f7 == 0:
                v = {0: a + b, 1: a << (b & 31), 2: int(sx(a, 32) < sx(b, 32)), 3: int(a < b), 4: a ^ b,
                     5: a >> (b & 31), 6: a | b, 7: a & b}[f3]
            elif f7 == 0x20 and f3 in (0, 5):
                v = (a - b) if f3 == 0 else (sx(a, 32) >> (b & 31))
            elif f7 == 1 and self.has_m:
                sa, sb = sx(a, 32), sx(b, 32)
                if f3 == 0: v = a * b
                elif f3 == 1: v = (sa * sb) >> 32
                elif f3 == 2: v = (sa * b) >> 32
                elif f3 == 3: v = (a * b) >> 32
                elif f3 == 4: v = M32 if b == 0 else (sa if (sa == -2**31 and sb == -1) else _tdiv(sa, sb))
                elif f3 == 5: v = M32 if b == 0 else a // b
                elif f3 == 6: v = a if b == 0 else (0 if (sa == -2**31 and sb == -1) else sa - sb * _tdiv(sa, sb))
                else: v = a if b == 0 else a % b
            elif f7 == 0x10 and self.has_zba and f3 in (2, 4, 6):
                v = (a << (f3 // 2)) + b
            else:
                return 2
            wr(v & M32, t)
        elif op == 0x0f:
            if f3 not in (0, 1): return 2
        elif op == 0x73:
            if f3 == 0:
                hi = ins >> 7
                if hi == 0: return 11
                if hi == (1 << 13): return 3
                if ins == 0x30200073:
                    npc = self.mepc; self.mie_b = self.mpie; self.mpie = 1
                elif ins == 0x10500073:
                    pass
                else:
                    return 2
            elif f3 == 4:
                return 2
            else:
                c = ins >> 20
                if c not in self.CSR_VALID: return 2
                if self.no_zicntr and (c >> 8) == 0xC: return 2
                imm_form = f3 >= 5
                src = rs1 if imm_form else a
                tsrc = False if imm_form else ta
                writes = f3 in (1, 5) or rs1 != 0
                if (c >> 10) == 3 and writes: return 2
                old, told = self.csr_read(c)
                kind = f3 & 3
                if writes and c == 0x344:
                    pass                                   # mip: read-only bits here, writes ignored
                elif writes:
                    if told and kind != 1: raise Viol(f'ISS: RMW of tainted CSR {c:x}')
                    if tsrc: raise Viol('ISS: CSR write of tainted value')
                    nv = src if kind == 1 else (old | src if kind == 2 else old & ~src)
                    # note: csrrw with rd=x0 still "reads" in this core; no side effects on read anyway
                    self.csr_write(c, nv & M32)
                wr(old, told)
        else:
            return 2
        self.pc = npc
        return None

def _tdiv(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q

# ------------------------------------------------------------------------------------------
def rtl_trace(path):
    recs = []
    for l in open(path, errors='replace'):
        if l.startswith('TRACE '):
            _, c, off, v = l.split(); recs.append((int(off, 16), int(v, 16), int(c)))
    return recs

def rtl_traps(recs):
    """(minstret_at_entry, mcause, cycle, group) per trap, in order"""
    traps = []; cur = None; g = 0
    for off, v, c in recs:
        if off == 0: g += 1
        if off == 0x1C: cur = [v, None, c, g, None]; traps.append(cur)
        elif off == 0x14 and cur is not None and cur[1] is None: cur[1] = v
        elif off == 0x10 and cur is not None and cur[4] is None: cur[4] = v
    return traps

import copy
def _later_match(s, v, mepc, n=12):
    """minstret can repeat after a minstret write: is there a boundary within n instructions
    with the same minstret AND pc == the RTL's mepc? (then inject there instead)"""
    t = copy.copy(s); t.x = list(s.x); t.tx = list(s.tx); t.ram = bytearray(s.ram); t.trace = []; t.on_trace = None
    t.vga = dict(s.vga); t.taint_mem = set(s.taint_mem)
    for _ in range(n):
        try:
            e = t.step()
        except Viol:
            return False
        if e is not None: return False
        t.minstret += 1
        if t.minstret == v and t.pc == mepc: return True
    return False

def check(rundir, kind, has_m=True, max_steps=20_000_000, verbose=False):
    recs = rtl_trace(f"{rundir}/{kind}/sim.log")
    traps = rtl_traps(recs)
    snaps = {}; g = 0
    for off_, v, c in recs:
        if off_ == 0: g += 1
        if off_ == 0x38: snaps[g] = v
    first_trap_of_group = {}
    for i, t in enumerate(traps): first_trap_of_group.setdefault(t[3], i)
    off = 1 if kind == 'ref' else 0
    s = ISS(f"{rundir}/init.bin", instret_off=off, has_m=has_m and kind != 'ref', has_zba=kind != 'ref')
    s.no_zicntr = (kind == 'ref')
    st = dict(ti=0, g=0)
    def on_trace(o, v):
        if o == 0:
            st['g'] += 1; st['gsteps'] = 0
            nxt = [i for gg, i in first_trap_of_group.items() if gg >= st['g']]
            st['ti'] = min(nxt) if nxt else len(traps)
        elif o == 0x38 and st['g'] in snaps:
            s.x[16] = snaps[st["g"]]               # a6 holds the snapshot
            s.minstret = snaps[st["g"]] + 1        # resync (csrr a6 has retired; the sw has not) (each iteration re-initialises its state)
    s.on_trace = on_trace
    steps = 0; violations = []; notes = []; pend_window = 0
    def viol(msg):
        violations.append((st['g'], msg))
    while not s.halted and steps < max_steps:
        steps += 1
        ti = st['ti']
        try:
            gsteps = st.get('gsteps', 0) + 1; st['gsteps'] = gsteps
            if gsteps > 300000:
                viol(f"ISS desynchronised from the RTL in group {st['g']} (after an earlier violation); stopping")
                break
            if ti < len(traps) and traps[ti][3] == st['g'] and traps[ti][1] is not None and traps[ti][1] >> 31 and traps[ti][0] == s.minstret \
                    and (s.pc == traps[ti][4] or not _later_match(s, traps[ti][0], traps[ti][4])):
                cause = traps[ti][1]
                if not s.irq_enabled(cause):
                    viol(f"RTL took interrupt {cause:#x} at pc={s.pc:#x} (cycle {traps[ti][2]}) where it is NOT enabled/armed: "
                         f"MIE={s.mie_b} MEIE={s.meie} MTIE={s.mtie} ext_armed={s.ext_armed} timer_cmph={s.timer_cmph:#x}")
                s.trap(cause, s.pc); st['ti'] += 1; pend_window = 0
                continue
            if s.mie_b and ((s.meie and s.ext_armed) or (s.mtie and s.timer_cmph != 0xffffffff)):
                pend_window += 1
                if pend_window == 400:
                    notes.append((st['g'], f"interrupt enabled+armed for 400 retired instructions without the RTL taking it (pc={s.pc:#x})"))
            else:
                pend_window = 0
            pc0 = s.pc
            exc = s.step()
        except Viol as e:
            viol(str(e)); break
        if exc is not None:
            ti = st['ti']
            if ti >= len(traps):
                viol(f"exception cause {exc} at pc={pc0:#x} (minstret={s.minstret}) but the RTL recorded no further trap")
            else:
                v, c, cyc, gg, _ = traps[ti]
                if c >> 31:
                    viol(f"exception cause {exc} at pc={pc0:#x} (minstret={s.minstret}); RTL's next trap is interrupt {c:#x} at minstret={v} (cycle {cyc})")
                elif c != exc or v != s.minstret:
                    viol(f"exception cause {exc} at pc={pc0:#x} (minstret={s.minstret}); RTL recorded cause {c} at minstret={v} (cycle {cyc})")
            s.trap(exc, pc0); st['ti'] += 1
        else:
            s.minstret += 1
            ti = st['ti']
            if ti < len(traps) and traps[ti][1] is not None and not (traps[ti][1] >> 31) and traps[ti][0] < s.minstret:
                viol(f"RTL recorded exception cause {traps[ti][1]} at minstret={traps[ti][0]} (cycle {traps[ti][2]}) "
                     f"but the ISS retired that instruction (pc={pc0:#x}) without an exception")
                st['ti'] += 1
    first_violation = violations[0][1] if violations else None
    # compare trace streams, group by group (a group starts at each iteration header, offset 0)
    A = [(o, v, c) for o, v, c in recs]
    B = [(o, v, t) for o, v, t in s.trace]
    def grp(L):
        G = []; cur = None
        for r in L:
            if r[0] == 0 or cur is None:
                cur = [r[1] if r[0] == 0 else None, []]; G.append(cur)
            cur[1].append(r)
        return G
    GA, GB = grp(A), grp(B)
    bad = []
    for i in range(max(len(GA), len(GB))):
        ga = GA[i] if i < len(GA) else None; gb = GB[i] if i < len(GB) else None
        if ga is None or gb is None or ga[0] != gb[0]:
            bad.append((i, ga, gb, 'group misaligned')); break
        ra, rb = ga[1], gb[1]
        ok = len(ra) == len(rb) and all(x[0] == y[0] and (y[2] or x[0] in (0x20, 0x38) or x[1] == y[1]) for x, y in zip(ra, rb))
        if not ok: bad.append((i, ga, gb, ''))
    mism = bad[0][0] if bad else None
    if not bad and first_violation is None and not s.halted:
        mism = -1
    res = dict(kind=kind, steps=steps, halted=s.halted, traps_rtl=len(traps), traps_used=st['ti'], violation=first_violation,
               trace_mismatch=mism, notes=notes, nrec=(len(A), len(B)), bad=bad, violations=violations)
    ctx = []
    for i, ga, gb, why in bad[:40]:
        h = ga[0] if ga else None
        ctx.append(f"group {i} header {h:#x} {why}" if h is not None else f"group {i} {why}")
        fa = ' '.join(f"{o:03x}:{v:x}" for o, v, c in (ga[1] if ga else []) if o not in (0,))
        fb = ' '.join(f"{o:03x}:{v:x}{'*' if t else ''}" for o, v, t in (gb[1] if gb else []) if o not in (0,))
        ctx.append(f"    rtl: {fa[:400]}")
        ctx.append(f"    iss: {fb[:400]}")
    res['ctx'] = ctx
    return res

if __name__ == '__main__':
    d = sys.argv[1]; kinds = [k for k in sys.argv[2:] if not k.startswith('-')] or ['dut', 'ref']
    nom = '--nom' in sys.argv
    rc = 0
    for k in kinds:
        r = check(d, k, has_m=not nom)
        ok = not r['violations'] and r['trace_mismatch'] is None and r['halted']
        print(f"ISS[{k}] {'CONSISTENT' if ok else 'INCONSISTENT'}: steps={r['steps']} halted={r['halted']} traps rtl={r['traps_rtl']} replayed={r['traps_used']} recs rtl/iss={r['nrec']}")
        for g, v in r['violations'][:20]: print(f"   VIOLATION (group {g}): {v}")
        for g, n in r['notes'][:5]: print(f"   note (group {g}): {n}")
        if r['trace_mismatch'] is not None:
            print(f"   trace mismatch: {len(r['bad'])} groups differ")
            for c in r.get('ctx', [])[: (400 if '-v' in sys.argv else 18)]: print("   " + c)
        if not ok: rc = 1
    sys.exit(rc)
