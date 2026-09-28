#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""fuzz.py <seed> <out.s> [--m] [--mtvec] [--bp] [--nseg N]
Random-program + random-interrupt-timing generator for test/trapsweep.
Each segment: canonical state, arm the external interrupt (random delay) and/or the timer
(random delay), run a random block, re-enable, wait for every armed interrupt, dump registers.
Uses the handler/vector/footer and trace layout of probes.py, so iss.py checks it unchanged.
  --m      also M and Zba instructions (DUT only: the golden CPU has neither)
  --mtvec  also csrrw mtvec (vectors A/B/C)
  --bp     switch the branch predictor on (random mode 1..3) at start-up
  --nseg   number of segments (default 60)"""
import os, sys, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.dont_write_bytecode = True     # no __pycache__ in the source tree
import probes as g

args = sys.argv[1:]
if len(args) < 2:
    sys.exit(__doc__)
seed = int(args[0], 0); outp = args[1]
USE_M = '--m' in args; USE_MTVEC = '--mtvec' in args; USE_BP = '--bp' in args
nseg = int(args[args.index('--nseg') + 1]) if '--nseg' in args else 60
R = random.Random(seed)
W = ['a0', 'a1', 'a2', 'a3', 'a4', 'a5', 's0', 's1', 's5', 's6', 't1', 't3', 't4']   # writable
lbl = [0]
def L():
    lbl[0] += 1; return f"L{lbl[0]}"
def r(): return R.choice(W)
def imm12(): return R.choice([0, 1, -1, 7, 0x7ff, -0x800, R.randint(-2048, 2047)])

def alu():
    op = R.choice(['add', 'sub', 'xor', 'or', 'and', 'sll', 'srl', 'sra', 'slt', 'sltu'] +
                  (['mul', 'mulh', 'mulhu', 'mulhsu', 'div', 'divu', 'rem', 'remu', 'sh1add', 'sh2add', 'sh3add'] if USE_M else []))
    return [f"    {op} {r()}, {r()}, {r()}"]
def alui():
    op = R.choice(['addi', 'xori', 'ori', 'andi', 'slti', 'sltiu', 'slli', 'srli', 'srai'])
    if op in ('slli', 'srli', 'srai'): return [f"    {op} {r()}, {r()}, {R.randint(0, 31)}"]
    return [f"    {op} {r()}, {r()}, {imm12()}"]
def lui(): return [f"    lui  {r()}, {R.randint(0, 0xfffff)}"]
def ram_ld():
    op, al = R.choice([('lw', 4), ('lh', 2), ('lhu', 2), ('lb', 1), ('lbu', 1)])
    return [f"    {op} {r()}, {R.randrange(0, 32, al)}(t2)"]
def ram_st():
    op, al = R.choice([('sw', 4), ('sh', 2), ('sb', 1)])
    return [f"    {op} {r()}, {R.randrange(0, 32, al)}(t2)"]
def misal():
    return [R.choice([f"    lw   {r()}, {R.choice([1, 2, 3])}(t2)", f"    lh   {r()}, {R.choice([1, 3])}(t2)",
                      f"    sw   {r()}, {R.choice([1, 2, 3]) + 4}(t2)", f"    sh   {r()}, {R.choice([1, 3]) + 4}(t2)",
                      f"    lhu  {r()}, 5(t2)"])]
def exc():
    return [R.choice(["    ecall", "    ebreak", "    .word 0x00000000", "    .word 0xffffffff", "    csrw cycle, a0"])]
def fault():
    return R.choice([["    li   t1, ERRREG", f"    lw   {r()}, 0(t1)"], ["    li   t1, ERRREG", f"    sw   {r()}, 0(t1)"],
                     [f"    lw   {r()}, 0(zero)"], [f"    sw   {r()}, 0(zero)"]])
def slow():
    base = R.choice(['LEDS', 'VGA', 'STALLREG'])
    return [f"    li   t1, {base}", R.choice([f"    sw   {r()}, 0(t1)", f"    lw   {R.choice(['a0', 'a1', 'a2', 's0'])}, 0(t1)"])]
def csr():
    c = R.choice(['mscratch', 'mepc', 'mcause', 'mstatus', 'mie', 'minstret_r'] + (['mtvec'] if USE_MTVEC else []))
    rd = r()
    if c == 'minstret_r': return [f"    csrr {rd}, minstret"]
    if c in ('mscratch', 'mepc', 'mcause'):
        f = R.choice(['csrrw', 'csrrs', 'csrrc', 'csrrwi', 'csrrsi', 'csrrci', 'csrr'])
        if f == 'csrr': return [f"    csrr {rd}, {c}"]
        if f.endswith('i'): return [f"    {f} {rd}, {c}, {R.randint(1, 31)}"]
        return [f"    {f} {rd}, {c}, {r()}"]
    if c == 'mstatus':
        v = R.choice([0x88, 0x80, 0x08, 0x00])
        return R.choice([["    csrci mstatus, 8"], ["    csrsi mstatus, 8"], [f"    csrr {rd}, mstatus"],
                         [f"    li   t1, {v:#x}", f"    csrrw {rd}, mstatus, t1"], [f"    csrrsi {rd}, mstatus, 8"], [f"    csrrci {rd}, mstatus, 8"],
                         [f"    li   t1, 0x80", f"    csrrs {rd}, mstatus, t1"], [f"    li   t1, 0x80", f"    csrrc {rd}, mstatus, t1"]])
    if c == 'mie':
        v = R.choice([0x880, 0x800, 0x080, 0x000])
        return R.choice([[f"    li   t1, {v:#x}", f"    csrrw {rd}, mie, t1"], [f"    csrr {rd}, mie"],
                         [f"    li   t1, 0x800", f"    csrrc {rd}, mie, t1"], [f"    li   t1, 0x880", f"    csrrs {rd}, mie, t1"]])
    if c == 'mtvec':
        tgt = R.choice(['vec_base', 'vec_b', 'vec_c'])
        return [f"    la   t1, {tgt}", f"    csrrw {rd}, mtvec, t1"]
def branch():
    l = L(); cond = R.choice(['beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'])
    body = []
    for _ in range(R.randint(1, 3)): body += R.choice([alu, alui, lui])()
    return [f"    {cond} {r()}, {r()}, {l}"] + body + [f"{l}:"]
def loop():
    l = L(); n = R.randint(1, 5)
    body = []
    for _ in range(R.randint(1, 3)): body += R.choice([alu, alui, ram_ld, csr])() if USE_M else R.choice([alu, alui, ram_ld])()
    body = [b for b in body if 't4' not in b]
    return [f"    li   t4, {n}", f"{l}:"] + body + ["    addi t4, t4, -1", f"    bnez t4, {l}"]
def jal():
    l = L(); return [f"    jal  {r()}, {l}"] + alui() + [f"{l}:"]
def jalr():
    l = L(); return [f"    la   t1, {l}", f"    jalr {r()}, 0(t1)"] + alui() + [f"{l}:"]
def fences(): return [R.choice(["    fence", "    fence.i", "    wfi"])]
def mret():
    l = L(); v = R.choice([0x88, 0x80, 0x08, 0x00])
    return [f"    la   s9, {l}", f"    li   t1, {v:#x}", "    csrw mstatus, t1", "    csrw mepc, s9", "    mret", "    li   a0, 0xbad", f"{l}:", "    li   s9, 0"]
def loaduse():
    d = r(); return [f"    lw   {d}, {R.randrange(0, 32, 4)}(t2)", f"    add  {r()}, {d}, {r()}"]

POOL = [(alu, 12), (alui, 12), (lui, 2), (ram_ld, 6), (ram_st, 6), (misal, 2), (exc, 3), (fault, 1), (slow, 3), (csr, 10),
        (branch, 6), (loop, 3), (jal, 2), (jalr, 2), (fences, 2), (mret, 2), (loaduse, 4)]
FUNCS = [f for f, w in POOL for _ in range(w)]

out = [g.HDR]
if USE_BP:
    out.append(f"    li   t1, {R.choice([1, 2, 3])}\n    csrw mhpmevent10, t1\n")
for seg in range(nseg):
    lines = [f"\n# ---- segment {seg} ----", f"    li   t0, {(seg + 1) << 16 | seed & 0xffff}", "    sw   t0, 0(tp)",
             "    la   t0, vec_base", "    csrw mtvec, t0", "    li   t0, MIE_CANON", "    csrw mie, t0", "    li   t0, 0x88", "    csrw mstatus, t0",
             "    la   t2, data_area"]
    nested = R.random() < 0.15; periph = R.random() < 0.3
    if nested: lines += ["    li   t0, 1", "    sw   t0, 0x110(tp)"]
    if periph: lines += ["    li   t0, 1", "    sw   t0, 0x114(tp)"]
    for w in W: lines += [f"    li   {w}, {R.randint(-2**31, 2**31 - 1)}"] if R.random() < 0.3 else []
    lines += ["    mv   s7, s10", "    csrr a6, minstret", "    sw   a6, 0x38(tp)"]
    body = []
    for _ in range(R.randint(8, 30)):
        body += R.choice(FUNCS)()
    has_mret = any('mret' in x for x in body)
    # the handler's MRET-probe return path (s9) is not re-entrant: one interrupt source only
    src = R.choice(['ext', 'ext', 'timer', 'none'] if has_mret else ['ext', 'ext', 'timer', 'both', 'none'])
    narm = {'ext': 1, 'timer': 1, 'both': 2, 'none': 0}[src]
    if src in ('timer', 'both'):
        lines += ["    li   t0, TIMER_MTIME", "    lw   t0, 0(t0)", f"    addi t0, t0, {R.randint(1, 70)}", "    li   a7, TIMER_CMP",
                  "    sw   t0, 0(a7)", "    li   a7, TIMER_CMPH", "    sw   zero, 0(a7)"]
    if src in ('ext', 'both'):
        lines += [f"    li   t0, {R.randint(1, 70)}", "    sw   t0, 4(s11)"]
    lines += body
    lines += ["    li   s9, 0", "    la   t0, vec_base", "    csrw mtvec, t0", "    li   t0, MIE_CANON", "    csrs mie, t0", "    csrsi mstatus, 8"]
    for wv in range(narm):
        lines += [f"    addi t0, s7, {wv + 1}", "    li   a7, 400", f"1:  bge  s10, t0, 2f", "    addi a7, a7, -1", "    bnez a7, 1b",
                  f"    li   t0, 0x{0xDEAD + wv:x}", "    sw   t0, 0x30(tp)", "    sw   zero, 4(s11)",
                  "    li   t0, TIMER_CMPH", "    li   a7, -1", "    sw   a7, 0(t0)", "2:"]
    lines += ["    sw   zero, 0x110(tp)", "    sw   zero, 0x114(tp)", "    csrr t0, minstret", "    sub  t0, t0, a6", "    sw   t0, 0x34(tp)"]
    for i, w in enumerate(W):
        lines += [f"    sw   {w}, 0x{0x40 + 4 * i:x}(tp)"]
    lines += ["    csrr t0, mscratch", "    sw   t0, 0x74(tp)", "    lw   t0, 0(t2)", "    sw   t0, 0x78(tp)", "    lw   t0, 4(t2)", "    sw   t0, 0x7c(tp)"]
    out.append("\n".join(lines) + "\n")
out.append("    j    all_done\n")
out.append(g.FOOT.replace("    .word 0, 0, 0, 0\n", "    .word 0, 0, 0, 0\n    .word 0x01234567, 0x89abcdef, 0x0f0f0f0f, 0xf0f0f0f0\n    .word 0, 0, 0, 0\n"))
open(outp, 'w').write("".join(out))
