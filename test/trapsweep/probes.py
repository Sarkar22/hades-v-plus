#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""probes.py -- interrupt-offset sweep programs for test/trapsweep.

A *probe* is a short instruction sequence (a CSR op, an exception, a branch, a
bus access, ...). A *family* is a list of probes (see FAMS at the end). build()
turns probes into one bare-metal program in which every probe runs in a loop
over a delay k = 1..kmax: the wishbone_test interrupt register (0x480004) is
armed with k, so the external interrupt becomes pending exactly k cycles after
the arming store -- i.e. at every cycle offset around the probe.
src='timer' arms mtimecmp = mtime + k instead; src='both' arms both.
The interrupt handlers record every trap entry in the trace window, and iss.py
checks the recorded run against an instruction-set model.

Trace window 0x47E00.. (printed by sim/top.sv with +trace; checked by iss.py):
  0x00 iteration header (probe_id<<16 | k)       0x38 minstret snapshot at arm time
  per trap entry: 0x1C minstret (read in the vector stub = #retired before the trap)
                  [0x24 handler-B / 0x28 handler-C marker] 0x10 mepc 0x14 mcause 0x18 mstatus 0x20 mip
                  [periph snapshot: 0x0C STALLREG 0x08 LEDS 0x04 VGA[0] 0x2C RAM target]
                  [nested-ecall mode: 0x3C mstatus after the nested ECALL's MRET]
  0x30 'irq never taken' (0xDEAD)   0x34 minstret delta of the iteration
  0x40.. result registers (probe dump list, then s3=mstatus, s4=mie right after the probe window)
  0x80+4i final register dump.
Reserved: tp s11 s10 s9 s8 s7 gp t5 t6 t0 a6 s2 s3 s4.  RAM flags (untraced): 0x110 nested, 0x114 periph.
"""
import sys, random

HDR = """
.equ TEST,        0x480000
.equ TRACE,       0x47E00
.equ TIMER_MTIME, 0x214004
.equ TIMER_CMP,   0x21400C
.equ TIMER_CMPH,  0x214010
.equ LEDS,        0x200000
.equ VGA,         0x240000
.equ STALLREG,    0x48000C
.equ ERRREG,      0x480010
.equ UART,        0x210000
.equ MIE_CANON,   0x880
.section .text.__reset
.globl __reset
__reset:
    li   s11, TEST
    li   tp, TRACE
    li   t1, 1
    sw   t1, 0(s11)          # initial deliberate fail (test protocol)
    li   t0, TIMER_CMPH
    li   t1, -1
    sw   t1, 0(t0)           # timer disarmed
    sw   zero, 0x110(tp)
    sw   zero, 0x114(tp)
    la   t0, vec_base
    csrw mtvec, t0
    li   t0, MIE_CANON
    csrw mie, t0
    li   s10, 0
    li   s9, 0
    csrsi mstatus, 8
"""

def handler(label, marker):
    m = f"    li   t6, 0x{marker:x}\n    sw   t6, 0x{0x24 if marker == 0xB else 0x28:x}(tp)\n" if marker else ""
    return f"""
{label}:
    sw   t5, 0x1C(tp)
{m}    csrr t5, mepc
    sw   t5, 0x10(tp)
    csrr t6, mcause
    sw   t6, 0x14(tp)
    csrr t5, mstatus
    sw   t5, 0x18(tp)
    csrr t5, mip
    sw   t5, 0x20(tp)
    lw   t5, 0x114(tp)
    beqz t5, 4f
    li   gp, STALLREG
    lw   t5, 0(gp)
    sw   t5, 0x0C(tp)
    li   gp, LEDS
    lw   t5, 0(gp)
    sw   t5, 0x08(tp)
    li   gp, VGA
    lw   t5, 0(gp)
    sw   t5, 0x04(tp)
    la   gp, data_area
    lw   t5, 16(gp)
    sw   t5, 0x2C(tp)
4:  bltz t6, 1f
    li   t5, 1
    bne  t6, t5, 8f
    csrw mepc, ra             # fetch fault: return to the jump's link address
    mret
8:  csrr t5, mepc             # exception: skip the instruction
    addi t5, t5, 4
    csrw mepc, t5
    mret
1:  li   t5, 0x8000000B       # interrupt: clear the source that was taken
    bne  t6, t5, 6f
    sw   zero, 4(s11)         # external (wishbone_test)
    j    7f
6:  li   t5, TIMER_CMPH
    li   t6, -1
    sw   t6, 0(t5)            # timer
7:  addi s10, s10, 1
    lw   t5, 0x110(tp)
    beqz t5, 5f
    csrr gp, mepc             # nested mode: ECALL inside the interrupt handler (MIE=0)
    sw   gp, 0x108(tp)
    ecall
    csrr gp, mstatus
    sw   gp, 0x3C(tp)         # nested MRET must have restored MIE=0
    lw   gp, 0x108(tp)
    csrw mepc, gp
    li   gp, 0x80
    csrw mstatus, gp
5:  bnez s9, 3f
    mret
3:  csrr gp, mepc             # MRET probe: restore the probe's own mepc, return by jr
    csrw mepc, s9
    csrsi mstatus, 8
    jr   gp
"""

VEC = """
.align 8
vec_base:
    csrr t5, minstret
    j    handler_a
.align 4
vec_c:                        # vec_base + 0x10
    csrr t5, minstret
    j    handler_c
.align 8
vec_b:                        # vec_base + 0x100
    csrr t5, minstret
    j    handler_b
"""

FOOT = """
all_done:
""" + "".join(f"    sw   x{i}, 0x{0x80 + 4 * i:x}(tp)\n" for i in range(1, 32)) + """
    sw   zero, 0(s11)
    li   t1, 2
    sw   t1, 0(s11)
9:  j    9b
""" + handler("handler_a", 0) + handler("handler_b", 0xB) + handler("handler_c", 0xC) + VEC + """
.align 4
data_area:
    .word 0x11223344, 0x55667788, 0x99aabbcc, 0xddeeff00
    .word 0, 0, 0, 0
"""

def L(s):
    return [l for l in s.strip('\n').split('\n') if l.strip()] if s and s.strip() else []

def probe_block(pid, p, pre=10, post=10, src='ext', kmin=1):
    kmax = p.get('kmax', 36)
    dump = p.get('dump', ['a1'])
    lines = [f"\n# ---- probe {pid}: {p['name']} ----", f"    li   s8, {kmin}", f"P{pid}_loop:"]
    lines += [f"    li   t0, {pid << 16}", "    add  t0, t0, s8", "    sw   t0, 0(tp)"]
    lines += ["    la   t0, vec_base", "    csrw mtvec, t0", "    li   t0, MIE_CANON", "    csrw mie, t0",
              "    li   t0, 0x88", "    csrw mstatus, t0", "    csrw mepc, zero", "    csrw mcause, zero",
              "    csrw mscratch, zero",
              "    li   a0, 0x5a5a0f0f", "    li   a1, 0x11111111", "    li   a2, 0x22222222",
              "    li   a3, 0x33333333", "    li   a4, 0x44444444", "    li   a5, 0x55555555",
              "    li   s0, 0x0badf00d", "    li   s1, 0x0badf11d", "    la   t2, data_area",
              "    li   s3, 0", "    li   s4, 0"]
    if p.get('nested'): lines += ["    li   t0, 1", "    sw   t0, 0x110(tp)"]
    if p.get('periph'):
        lines += ["    li   t0, 1", "    sw   t0, 0x114(tp)", "    li   t0, STALLREG", "    sw   zero, 0(t0)", "    li   t0, LEDS",
                  "    sw   zero, 0(t0)", "    li   t0, VGA", "    sw   zero, 0(t0)", "    sw   zero, 16(t2)"]
    lines += L(p.get('setup', ''))
    lines += ["    mv   s7, s10", "    csrr a6, minstret", "    sw   a6, 0x38(tp)"]
    if src == 'ext':
        lines += ["    sw   s8, 4(s11)          # arm external irq, k cycles"]
    elif src == 'timer':
        lines += ["    li   t0, TIMER_MTIME", "    lw   t0, 0(t0)", "    add  t0, t0, s8", "    li   a7, TIMER_CMP",
                  "    sw   t0, 0(a7)", "    li   a7, TIMER_CMPH", "    sw   zero, 0(a7)"]
    elif src == 'both':
        lines += ["    li   t0, TIMER_MTIME", "    lw   t0, 0(t0)", "    add  t0, t0, s8", "    addi t0, t0, 3", "    li   a7, TIMER_CMP",
                  "    sw   t0, 0(a7)", "    li   a7, TIMER_CMPH", "    sw   zero, 0(a7)", "    sw   s8, 4(s11)"]
    lines += ["    nop"] * p.get('pre', pre)
    lines += p['probe'].strip('\n').split('\n')
    lines += ["    nop"] * p.get('post', post)
    lines += ["    csrr s3, mstatus", "    csrr s4, mie", "    li   s9, 0"]
    lines += L(p.get('restore', ''))
    if p.get('readback'):
        lines += [f"    csrr s2, {p['readback']}"]
    lines += ["    la   t0, vec_base", "    csrw mtvec, t0", "    li   t0, MIE_CANON", "    csrs mie, t0", "    csrsi mstatus, 8"]
    nwait = 2 if src == 'both' else 1
    for w in range(nwait):
        lines += [f"    addi t0, s7, {w + 1}", "    li   a7, 300", "1:  bge  s10, t0, 2f", "    addi a7, a7, -1", "    bnez a7, 1b",
                  f"    li   t0, 0x{0xDEAD + w:x}", "    sw   t0, 0x30(tp)", "    sw   zero, 4(s11)",
                  "    li   t0, TIMER_CMPH", "    li   a7, -1", "    sw   a7, 0(t0)", "2:"]
    lines += ["    sw   zero, 0x110(tp)", "    sw   zero, 0x114(tp)"]
    lines += ["    csrr t0, minstret", "    sub  t0, t0, a6", "    sw   t0, 0x34(tp)"]
    regs = dump + ['s3', 's4'] + (['s2'] if p.get('readback') else [])
    for i, r in enumerate(regs):
        lines += [f"    sw   {r}, 0x{0x40 + 4 * i:x}(tp)"]
    lines += ["    addi s8, s8, 1", f"    li   t0, {kmax}", f"    blt  s8, t0, P{pid}_loop"]
    return "\n".join(lines) + "\n"

import re
MTVEC_W = re.compile(r'csrr?[wsc]i?\s+(\w+,\s*)?mtvec')
def writes_mtvec(p):
    """True if the probe (or its setup) writes mtvec."""
    return bool(MTVEC_W.search(p.get('probe', '') + p.get('setup', '')))

def build(probes, src='ext', pre=10, post=10, kmin=1, no_mtvec=False):
    """probes: [(probe_id, probe_dict)] -> assembly source (str) of one program."""
    if no_mtvec:
        probes = [(i, p) for i, p in probes if not writes_mtvec(p)]
    out = [HDR]
    for pid, p in probes:
        psrc = p.get('src', src)
        if psrc == 'both' and 's9' in p.get('setup', ''):
            psrc = 'ext'      # the handler's MRET-probe return path (s9) is not re-entrant
        out.append(probe_block(pid, p, pre=pre, post=post, src=psrc, kmin=kmin))
    out.append("    j    all_done\n")
    out.append(FOOT)
    return "".join(out)

# ------------------------------------------------------------------------------------------
CSR_VALS = {
    'mstatus':  (0x88, 0x80, 0x80, 8, 8, 0x10),
    'mie':      (0x880, 0x80, 0x80, 0x1f, 0x1f, 0x1f),
    'mip':      (0xffffffff, 0x888, 0x888, 0x1f, 0x1f, 0x1f),
    'mepc':     (0x12345678, 0xf0, 0xf0, 0x1c, 0x13, 0x1f),
    'mcause':   (0x80000003, 0x5, 0x5, 0x1f, 0x13, 0x1f),
    'mscratch': (0xa5a5c3c3, 0xf0f0, 0xf0f0, 0x1c, 0x13, 0x1f),
}
CSR_DISABLE = {
    'mstatus': [('csrrw', 0x80), ('csrrc', 0x08), ('csrrwi', 0), ('csrrci', 8)],
    'mie':     [('csrrw', 0x080), ('csrrc', 0x800), ('csrrwi', 0)],
}

def csr_probes():
    ps = []
    for csr, (vw, vs, vc, iw, is_, ic) in CSR_VALS.items():
        for form, val in (('csrrw', vw), ('csrrs', vs), ('csrrc', vc)):
            ps.append(dict(name=f"{form} a1,{csr},a0 (a0={val:#x})", setup=f"    li   a0, {val:#x}",
                           probe=f"    {form} a1, {csr}, a0", readback=csr))
        for form, val in (('csrrwi', iw), ('csrrsi', is_), ('csrrci', ic)):
            ps.append(dict(name=f"{form} a1,{csr},{val:#x}", probe=f"    {form} a1, {csr}, {val:#x}", readback=csr))
        ps.append(dict(name=f"csrr a1,{csr}", probe=f"    csrr a1, {csr}", readback=csr))
        ps.append(dict(name=f"csrrw x0,{csr},a0", setup=f"    li   a0, {vw:#x}", probe=f"    csrw {csr}, a0", readback=csr))
    for csr, lst in CSR_DISABLE.items():
        for form, val in lst:
            if form.endswith('i'):
                ps.append(dict(name=f"{form} a1,{csr},{val:#x} (disables)", probe=f"    {form} a1, {csr}, {val:#x}", readback=csr))
            else:
                ps.append(dict(name=f"{form} a1,{csr},a0 (a0={val:#x}, disables)", setup=f"    li   a0, {val:#x}",
                               probe=f"    {form} a1, {csr}, a0", readback=csr))
    ps.append(dict(name="csrrw a1,mtvec,a0 (->B)", setup="    la   a0, vec_b", probe="    csrrw a1, mtvec, a0", readback='mtvec'))
    ps.append(dict(name="csrrs a1,mtvec,a0 (->B)", setup="    li   a0, 0x100", probe="    csrrs a1, mtvec, a0", readback='mtvec'))
    ps.append(dict(name="csrrc a1,mtvec,a0 (B->A)", setup="    la   t1, vec_b\n    csrw mtvec, t1\n    li   a0, 0x100",
                   probe="    csrrc a1, mtvec, a0", readback='mtvec'))
    ps.append(dict(name="csrrsi a1,mtvec,0x10 (->C)", probe="    csrrsi a1, mtvec, 0x10", readback='mtvec'))
    ps.append(dict(name="csrrci a1,mtvec,0x10 (C->A)", setup="    la   t1, vec_c\n    csrw mtvec, t1",
                   probe="    csrrci a1, mtvec, 0x10", readback='mtvec'))
    ps.append(dict(name="csrr a1,mtvec", probe="    csrr a1, mtvec", readback='mtvec'))
    ps.append(dict(name="csrrwi a1,mscratch,0 (uimm=0)", setup="    li   t1, 0x1234\n    csrw mscratch, t1", probe="    csrrwi a1, mscratch, 0", readback='mscratch'))
    ps.append(dict(name="csrrwi a1,mepc,0 (uimm=0)", setup="    li   t1, 0x1234\n    csrw mepc, t1", probe="    csrrwi a1, mepc, 0", readback='mepc'))
    return ps

EXC = [
    ("ecall", "    ecall"),
    ("ebreak", "    ebreak"),
    ("illegal 0x00000000", "    .word 0x00000000"),
    ("illegal 0xffffffff", "    .word 0xffffffff"),
    ("csrw cycle (read-only CSR)", "    csrw cycle, a0"),
    ("csrr a1, 0x7c0 (nonexistent CSR)", "    csrr a1, 0x7c0"),
    ("lh misaligned", "    lh   a1, 1(t2)"),
    ("lhu misaligned", "    lhu  a1, 3(t2)"),
    ("lw misaligned+2", "    lw   a1, 2(t2)"),
    ("lw misaligned+1", "    lw   a1, 1(t2)"),
    ("sh misaligned", "    sh   a0, 17(t2)"),
    ("sw misaligned", "    sw   a0, 18(t2)"),
    ("lw load fault (unmapped 0x0)", "    li   a3, 0\n    lw   a1, 0(a3)"),
    ("sw store fault (unmapped 0x0)", "    li   a3, 0\n    sw   a0, 0(a3)"),
    ("lw bus-error reg (3 stalls then err)", "    li   a3, ERRREG\n    lw   a1, 0(a3)"),
    ("sw bus-error reg", "    li   a3, ERRREG\n    sw   a0, 0(a3)"),
    ("ecall;ecall", "    ecall\n    ecall"),
    ("ecall;illegal", "    ecall\n    .word 0"),
    ("lw misaligned; ecall", "    lw   a1, 2(t2)\n    ecall"),
]

def exc_probes(variant=''):
    ps = []
    setups = {'': '', 'mie0': "    li   t1, 0x80\n    csrw mstatus, t1", 'mie0mpie0': "    csrw mstatus, zero",
              'mpie0': "    li   t1, 0x08\n    csrw mstatus, t1"}
    for name, code in EXC:
        ps.append(dict(name=f"{name} [{variant or 'MIE=1'}]", setup=setups[variant], probe=code, kmax=40 if 'ERRREG' in code else 36))
    return ps

def nested_probes():
    ps = []
    for name, code in [("nop", "    nop"), ("ecall", "    ecall"), ("csrci mstatus,8", "    csrci mstatus, 8"),
                       ("csrw mscratch", "    csrw mscratch, a0"), ("lw misaligned", "    lw   a1, 2(t2)"),
                       ("mret MIE=1", None), ("sw STALLREG", "    li   a3, STALLREG\n    sw   a0, 0(a3)")]:
        if code is None:
            ps.append(dict(name=f"nested-ecall handler; {name}", nested=True, setup="    la   s9, 5f\n    csrw mepc, s9",
                           probe="    mret\n    li   a1, 0xbad\n5:"))
        else:
            ps.append(dict(name=f"nested-ecall handler; {name}", nested=True, probe=code, kmax=40))
    return ps

def flow_probes():
    return [
        dict(name="mret MIE=1 MPIE=1", setup="    la   s9, 5f\n    csrw mepc, s9", probe="    mret\n    li   a1, 0xbad\n5:"),
        dict(name="mret MIE=0 MPIE=1 (mret enables -> imm)", setup="    la   s9, 5f\n    csrw mepc, s9\n    li   t1, 0x80\n    csrw mstatus, t1",
             probe="    mret\n    li   a1, 0xbad\n5:"),
        dict(name="mret MIE=1 MPIE=0 (mret disables)", setup="    la   s9, 5f\n    csrw mepc, s9\n    li   t1, 0x08\n    csrw mstatus, t1",
             probe="    mret\n    li   a1, 0xbad\n5:"),
        dict(name="mret MIE=0 MPIE=0", setup="    la   s9, 5f\n    csrw mepc, s9\n    csrw mstatus, zero",
             probe="    mret\n    li   a1, 0xbad\n5:"),
        dict(name="fence.i", probe="    fence.i"),
        dict(name="fence", probe="    fence"),
        dict(name="wfi", probe="    wfi"),
        dict(name="wfi with MIE=0 (pending irq must wake it)", setup="    li   t1, 0x80\n    csrw mstatus, t1", probe="    wfi\n    addi a2, a2, 1", dump=['a1', 'a2']),
        dict(name="taken beq (mispredict under NT)", probe="    beq  zero, zero, 5f\n    li   a1, 0xbad\n5:  addi a2, a2, 1", dump=['a1', 'a2']),
        dict(name="not-taken bne", probe="    bne  zero, zero, 5f\n    li   a1, 0x0ff\n5:  addi a2, a2, 1", dump=['a1', 'a2']),
        dict(name="jal", probe="    jal  a3, 5f\n    li   a1, 0xbad\n5:  addi a2, a2, 1", dump=['a1', 'a2']),
        dict(name="jalr", probe="    la   a4, 5f\n    jalr a3, 0(a4)\n    li   a1, 0xbad\n5:  addi a2, a2, 1", dump=['a1', 'a2']),
        dict(name="backward loop x3", probe="    li   a4, 3\n5:  addi a2, a2, 1\n    addi a4, a4, -1\n    bnez a4, 5b", dump=['a2', 'a4']),
        dict(name="load-use", probe="    lw   a1, 0(t2)\n    addi a2, a1, 1\n    add  a3, a2, a1", dump=['a1', 'a2', 'a3']),
        dict(name="load-use x2", probe="    lw   a1, 4(t2)\n    add  a2, a1, a1\n    lw   a3, 8(t2)\n    sub  a4, a3, a2", dump=['a1', 'a2', 'a3', 'a4']),
        dict(name="store-load", probe="    sw   a0, 16(t2)\n    lw   a1, 16(t2)\n    addi a2, a1, 1", dump=['a1', 'a2'], restore="    sw   zero, 16(t2)"),
        dict(name="load-use into branch", probe="    lw   a1, 0(t2)\n    beq  a1, zero, 5f\n    addi a2, a2, 1\n5:  addi a3, a3, 1", dump=['a1', 'a2', 'a3']),
        dict(name="load-use into jalr", probe="    la   a4, 5f\n    sw   a4, 20(t2)\n    lw   a5, 20(t2)\n    jalr a3, 0(a5)\n    li   a1, 0xbad\n5:  addi a2, a2, 1",
             dump=['a1', 'a2'], restore="    sw   zero, 20(t2)"),
        dict(name="load-use into csrw mstatus", probe="    li   a4, 0x80\n    sw   a4, 20(t2)\n    lw   a5, 20(t2)\n    csrw mstatus, a5\n    csrr a1, mstatus",
             dump=['a1'], restore="    sw   zero, 20(t2)"),
        dict(name="csrw mscratch then csrr", probe="    csrw mscratch, a0\n    csrr a1, mscratch", readback='mscratch'),
        dict(name="csrci;csrsi mstatus (crit section)", probe="    csrci mstatus, 8\n    csrr a1, mstatus\n    addi a2, a2, 1\n    csrsi mstatus, 8", dump=['a1', 'a2']),
        dict(name="csrw mepc; csrr mepc", probe="    csrw mepc, a0\n    csrr a1, mepc", readback='mepc'),
        dict(name="csrr minstret x2", probe="    csrr a1, minstret\n    csrr a2, minstret\n    sub  a3, a2, a1", dump=['a3']),
        dict(name="csrr instret; nop; csrr instret", probe="    csrr a1, instret\n    nop\n    csrr a2, instret\n    sub  a3, a2, a1", dump=['a3']),
        dict(name="csrw minstret", probe="    csrr a1, minstret\n    csrw minstret, a1\n    csrr a2, minstret\n    sub  a3, a2, a1", dump=['a3']),
    ]

def bus_probes():
    P = []
    for nm, addr, kmax in (("LEDS", "LEDS", 44), ("VGA", "VGA", 44), ("STALLREG", "STALLREG", 56), ("RAM", None, 40)):
        base = "    la   a3, data_area\n    addi a3, a3, 16" if addr is None else f"    li   a3, {addr}"
        P.append(dict(name=f"sw {nm} x3 distinct", periph=True, kmax=kmax,
                      probe=base + "\n    li   a0, 0x101\n    sw   a0, 0(a3)\n    addi a0, a0, 0x101\n    sw   a0, 0(a3)\n    addi a0, a0, 0x101\n    sw   a0, 0(a3)",
                      dump=['a0']))
        P.append(dict(name=f"sw {nm}; nop; sw {nm}", periph=True, kmax=kmax,
                      probe=base + "\n    li   a0, 0x202\n    sw   a0, 0(a3)\n    nop\n    li   a0, 0x303\n    sw   a0, 0(a3)", dump=['a0']))
        P.append(dict(name=f"sw {nm}; lw {nm}; use", periph=True, kmax=kmax,
                      probe=base + "\n    li   a0, 0x404\n    sw   a0, 0(a3)\n    lw   a1, 0(a3)\n    addi a2, a1, 1", dump=['a1', 'a2']))
        P.append(dict(name=f"sw {nm}; csrci mstatus,8", periph=True, kmax=kmax,
                      probe=base + "\n    li   a0, 0x505\n    sw   a0, 0(a3)\n    csrci mstatus, 8\n    csrr a1, mstatus", dump=['a1']))
        P.append(dict(name=f"sw {nm}; ecall", periph=True, kmax=kmax,
                      probe=base + "\n    li   a0, 0x606\n    sw   a0, 0(a3)\n    ecall\n    addi a0, a0, 1\n    sw   a0, 0(a3)", dump=['a0']))
        P.append(dict(name=f"sw {nm}; csrw mtvec->B", periph=True, kmax=kmax,
                      probe=base + "\n    la   a4, vec_b\n    li   a0, 0x707\n    sw   a0, 0(a3)\n    csrw mtvec, a4\n    addi a0, a0, 1\n    sw   a0, 0(a3)",
                      dump=['a0']))
        P.append(dict(name=f"lw {nm} ; lw {nm}", periph=True, kmax=kmax,
                      setup=base + "\n    li   a0, 0x808\n    sw   a0, 0(a3)",
                      probe="    lw   a1, 0(a3)\n    lw   a2, 0(a3)\n    add  a4, a1, a2", dump=['a1', 'a2', 'a4']))
    P.append(dict(name="sw ERRREG (fault) ; sw STALLREG", periph=True, kmax=50,
                  probe="    li   a3, ERRREG\n    li   a4, STALLREG\n    li   a0, 0x909\n    sw   a0, 0(a3)\n    sw   a0, 0(a4)", dump=['a0']))
    P.append(dict(name="sw STALLREG ; lw ERRREG (fault)", periph=True, kmax=50,
                  probe="    li   a3, ERRREG\n    li   a4, STALLREG\n    li   a0, 0xa0a\n    sw   a0, 0(a4)\n    lw   a1, 0(a3)", dump=['a0', 'a1']))
    P.append(dict(name="sw STALLREG ; mret MIE=1", periph=True, kmax=56, setup="    la   s9, 5f\n    csrw mepc, s9\n    li   a4, STALLREG",
                  probe="    li   a0, 0xb0b\n    sw   a0, 0(a4)\n    mret\n    li   a1, 0xbad\n5:  addi a0, a0, 1\n    sw   a0, 0(a4)", dump=['a0', 'a1']))
    P.append(dict(name="sw STALLREG ; fence.i", periph=True, kmax=56, setup="    li   a4, STALLREG",
                  probe="    li   a0, 0xc0c\n    sw   a0, 0(a4)\n    fence.i\n    addi a0, a0, 1\n    sw   a0, 0(a4)", dump=['a0']))
    P.append(dict(name="sw STALLREG ; taken branch", periph=True, kmax=56, setup="    li   a4, STALLREG",
                  probe="    li   a0, 0xd0d\n    sw   a0, 0(a4)\n    beq  zero, zero, 5f\n    li   a1, 0xbad\n5:  addi a0, a0, 1\n    sw   a0, 0(a4)", dump=['a0', 'a1']))
    return P

def pair_probes():
    ops = [
        ("csrci mstatus,8", "    csrci mstatus, 8"),
        ("csrsi mstatus,8", "    csrsi mstatus, 8"),
        ("csrrw mstatus=0x88", "    csrrw a1, mstatus, a2"),
        ("csrw mie=0x880", "    csrw mie, a3"),
        ("csrc mie MEIE", "    csrc mie, a4"),
        ("csrw mtvec->B", "    csrw mtvec, a5"),
        ("csrw mepc", "    csrw mepc, a0"),
        ("csrr mepc", "    csrr a1, mepc"),
        ("csrw mcause", "    csrw mcause, a0"),
        ("csrr mcause", "    csrr a1, mcause"),
        ("csrw mscratch", "    csrw mscratch, a0"),
        ("csrr minstret", "    csrr a1, minstret"),
        ("ecall", "    ecall"),
        ("sw RAM", "    sw   a0, 16(t2)"),
        ("lw RAM", "    lw   a1, 16(t2)"),
    ]
    ps = []
    for n1, c1 in ops:
        for n2, c2 in ops:
            ps.append(dict(name=f"{n1} ; {n2}", setup="    li   a2, 0x88\n    li   a3, 0x880\n    li   a4, 0x800\n    la   a5, vec_b",
                           probe=c1 + "\n" + c2, dump=['a1'], kmax=30, restore="    sw   zero, 16(t2)"))
    return ps

def pre_probes(has_m=True):
    """pipeline state immediately before the probe"""
    befores = [("taken-branch->", "    beq  zero, zero, 7f\n    nop\n7:"),
               ("load-use->", "    lw   a1, 0(t2)\n    addi a1, a1, 1"),
               ("sw STALLREG->", "    li   a3, STALLREG\n    sw   a0, 0(a3)"),
               ("lw VGA->", "    li   a3, VGA\n    lw   a1, 0(a3)"),
               ("fence.i->", "    fence.i"),
               ("jal->", "    jal  a3, 7f\n7:"),
               ("csrr minstret->", "    csrr a1, minstret")]
    if has_m:
        befores.append(("div->", "    li   a3, 7\n    div  a1, a0, a3"))
        befores.append(("mul->", "    mul  a1, a0, a0"))
    probes = [("ecall", "    ecall"), ("csrci mstatus,8", "    csrci mstatus, 8\n    csrr a2, mstatus"),
              ("csrw mtvec->B", "    la   a4, vec_b\n    csrw mtvec, a4"), ("csrw mscratch", "    csrw mscratch, a0\n    csrr a2, mscratch"),
              ("lw misaligned", "    lw   a2, 2(t2)"), ("sw STALLREG", "    li   a4, STALLREG\n    li   a0, 0x55\n    sw   a0, 0(a4)")]
    ps = []
    for bn, bc in befores:
        for pn, pc in probes:
            ps.append(dict(name=f"{bn}{pn}", probe=bc + "\n" + pc, dump=['a1', 'a2'], periph=True, kmax=48))
    return ps

def m_probes():
    return [
        dict(name="div", setup="    li   a0, 1000003\n    li   a2, 7", probe="    div  a1, a0, a2\n    addi a3, a1, 1", dump=['a1', 'a3'], kmax=60),
        dict(name="divu", setup="    li   a0, -7\n    li   a2, 3", probe="    divu a1, a0, a2", dump=['a1'], kmax=60),
        dict(name="rem", setup="    li   a0, -1000003\n    li   a2, 7", probe="    rem  a1, a0, a2", dump=['a1'], kmax=60),
        dict(name="remu", setup="    li   a0, -1000003\n    li   a2, 7", probe="    remu a1, a0, a2", dump=['a1'], kmax=60),
        dict(name="div;div (dependent)", setup="    li   a0, 1000003\n    li   a2, 7", probe="    div  a1, a0, a2\n    div  a3, a1, a2", dump=['a1', 'a3'], kmax=90),
        dict(name="mul;mulh;mulhsu;mulhu", setup="    li   a0, 123457\n    li   a2, -98765",
             probe="    mul  a1, a0, a2\n    mulh a3, a0, a2\n    mulhsu a4, a0, a2\n    mulhu a5, a0, a2", dump=['a1', 'a3', 'a4', 'a5'], kmax=44),
        dict(name="div by 0", setup="    li   a0, 1000003\n    li   a2, 0", probe="    div  a1, a0, a2", dump=['a1'], kmax=40),
        dict(name="div overflow", setup="    li   a0, 0x80000000\n    li   a2, -1", probe="    div  a1, a0, a2\n    rem  a3, a0, a2", dump=['a1', 'a3'], kmax=40),
        dict(name="lw; divu (load-use into div)", setup="    li   a2, 7", probe="    lw   a0, 0(t2)\n    divu a1, a0, a2", dump=['a1'], kmax=60),
        dict(name="div; ecall", setup="    li   a0, 1000003\n    li   a2, 7", probe="    div  a1, a0, a2\n    ecall", dump=['a1'], kmax=60),
        dict(name="ecall; div", setup="    li   a0, 1000003\n    li   a2, 7", probe="    ecall\n    div  a1, a0, a2", dump=['a1'], kmax=60),
        dict(name="div; csrci mstatus", setup="    li   a0, 1000003\n    li   a2, 7", probe="    div  a1, a0, a2\n    csrci mstatus, 8\n    csrr a3, mstatus", dump=['a1', 'a3'], kmax=60),
        dict(name="div; sw STALLREG", periph=True, setup="    li   a0, 1000003\n    li   a2, 7\n    li   a4, STALLREG",
             probe="    div  a1, a0, a2\n    sw   a1, 0(a4)\n    lw   a3, 0(a4)", dump=['a1', 'a3'], kmax=64),
        dict(name="sw STALLREG; div", periph=True, setup="    li   a0, 1000003\n    li   a2, 7\n    li   a4, STALLREG",
             probe="    sw   a0, 0(a4)\n    div  a1, a0, a2\n    lw   a3, 0(a4)", dump=['a1', 'a3'], kmax=64),
        dict(name="div; mret", setup="    li   a0, 1000003\n    li   a2, 7\n    la   s9, 5f\n    csrw mepc, s9",
             probe="    div  a1, a0, a2\n    mret\n    li   a3, 0xbad\n5:", dump=['a1', 'a3'], kmax=60),
        dict(name="div; csrw mtvec->B", setup="    li   a0, 1000003\n    li   a2, 7\n    la   a4, vec_b",
             probe="    div  a1, a0, a2\n    csrw mtvec, a4", dump=['a1'], kmax=60),
        dict(name="div in handler window (nested)", nested=True, setup="    li   a0, 1000003\n    li   a2, 7",
             probe="    div  a1, a0, a2\n    div  a3, a0, a2", dump=['a1', 'a3'], kmax=90),
        dict(name="sh1add;sh2add;sh3add", setup="    li   a0, 0x1234\n    li   a2, 0x10", probe="    sh1add a1, a0, a2\n    sh2add a3, a0, a2\n    sh3add a4, a0, a2",
             dump=['a1', 'a3', 'a4'], kmax=36),
    ]

def bp_probes():
    ps = []
    for mode in (1, 2, 3):
        pre = f"    li   t1, {mode}\n    csrw mhpmevent10, t1\n"
        for nm, code in (("taken fwd beq", "    beq  zero, zero, 5f\n    li   a1, 0xbad\n5:  addi a2, a2, 1"),
                         ("loop x4", "    li   a4, 4\n5:  addi a2, a2, 1\n    addi a4, a4, -1\n    bnez a4, 5b"),
                         ("nt bne", "    bne  zero, zero, 5f\n    addi a1, a1, 1\n5:  addi a2, a2, 1"),
                         ("alternating", "    li   a4, 6\n5:  andi a5, a4, 1\n    beqz a5, 6f\n    addi a1, a1, 1\n6:  addi a4, a4, -1\n    bnez a4, 5b"),
                         ("branch;ecall", "    beq  zero, zero, 5f\n    nop\n5:  ecall"),
                         ("branch;csrci", "    bnez a0, 5f\n    nop\n5:  csrci mstatus, 8\n    csrr a3, mstatus")):
            ps.append(dict(name=f"bp mode {mode}: {nm}", setup=pre, probe=code, dump=['a1', 'a2', 'a3'], kmax=48,
                           restore="    csrw mhpmevent10, zero"))
    return ps

def ctl_probes():
    return [
        dict(name="jalr to misaligned target (+2)", probe="    la   a4, 5f\n    addi a4, a4, 2\n    jalr a3, 0(a4)\n    li   a1, 0x77\n5:  nop", dump=['a1', 'a3']),
        dict(name="beq taken to misaligned target (.+6)", probe="    beq  zero, zero, .+6\n    li   a1, 0x77\n    nop", dump=['a1']),
        dict(name="bne not-taken with misaligned target", probe="    bne  zero, zero, .+6\n    li   a1, 0x77\n    nop", dump=['a1']),
        dict(name="jal to misaligned target (.+6)", probe="    jal  a3, .+6\n    li   a1, 0x77\n    nop", dump=['a1', 'a3']),
        dict(name="jalr to unmapped 0x100 (fetch fault)", probe="    li   a4, 0x100\n    jalr ra, 0(a4)\n    li   a1, 0x77", dump=['a1']),
        dict(name="jalr to end of RAM+ (fetch fault)", probe="    li   a4, 0x48000\n    jalr ra, 0(a4)\n    li   a1, 0x77", dump=['a1']),
        dict(name="self-modifying code + fence.i", setup="    la   a4, 6f\n    li   a5, 0x07700593\n    sw   a5, 0(a4)\n    fence.i\n    li   a5, 0x00100593",
             probe="    sw   a5, 0(a4)\n    fence.i\n6:  li   a1, 0x77\n    addi a2, a1, 1", dump=['a1', 'a2']),
        dict(name="self-modifying code, store right before target (no fence.i)", setup="    la   a4, 6f\n    li   a5, 0x07700593\n    sw   a5, 0(a4)\n    fence.i\n    li   a5, 0x00100593",
             probe="    sw   a5, 0(a4)\n    nop\n    nop\n    nop\n    nop\n    nop\n    nop\n6:  li   a1, 0x77", dump=['a1'], skip_iss_note=True),
        dict(name="csrw mtvec = vec_base|1 (mode bits)", probe="    la   a4, vec_base\n    ori  a4, a4, 1\n    csrw mtvec, a4\n    csrr a1, mtvec", dump=['a1']),
        dict(name="csrw mtvec = vec_base|3 then irq", probe="    la   a4, vec_base\n    ori  a4, a4, 3\n    csrw mtvec, a4\n    csrr a1, mtvec\n    nop\n    nop", dump=['a1']),
    ]

def race_probes():
    return [
        dict(name="sw zero,4(s11): store clears the pending ext irq", probe="    sw   zero, 4(s11)\n    li   a1, 0x77", kmax=36),
        dict(name="sw -1 -> mtimecmph: store disarms the timer", src='timer',
             probe="    li   a3, TIMER_CMPH\n    li   a4, -1\n    sw   a4, 0(a3)\n    li   a1, 0x77", kmax=40),
        dict(name="rearm ext irq to a long delay", probe="    li   a3, 1000\n    sw   a3, 4(s11)\n    li   a1, 0x77", kmax=36),
    ]

def ext_probes():
    """Zbb, Zbs and Zicond: every form, dependent chains into and out of the new
    instructions, the pipeline neighbours of the m family, and illegal neighbours that
    must keep trapping. The programs are assembled with sweep.py's MARCH (no Zbb/Zbs),
    so each probe enables the mnemonics itself; czero has none in binutils 2.39."""
    on = "    .option arch, +zbb, +zbs\n"
    def cz(f3, rd, rs1, rs2):        # czero.eqz (funct3 5) / czero.nez (funct3 7)
        return f"    .insn r 0x33, {f3}, 7, {rd}, {rs1}, {rs2}"
    def P(name, setup, probe, dump, kmax=36, **k):
        return dict(name=name, setup=on + setup, probe=probe, dump=dump, kmax=kmax, **k)
    ab = "    li   a0, 0x8f00f0a5\n    li   a2, 0x0ff0c35a"
    return [
        P("andn;orn;xnor", ab, "    andn a1, a0, a2\n    orn  a3, a0, a2\n    xnor a4, a0, a2", ['a1', 'a3', 'a4']),
        P("min;minu;max;maxu", "    li   a0, -5\n    li   a2, 3",
          "    min  a1, a0, a2\n    minu a3, a0, a2\n    max  a4, a0, a2\n    maxu a5, a0, a2", ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("clz;ctz;cpop", "    li   a0, 0x80f01800", "    clz  a1, a0\n    ctz  a3, a0\n    cpop a4, a0", ['a1', 'a3', 'a4']),
        P("clz;ctz;cpop of 0", "    li   a0, 0", "    clz  a1, a0\n    ctz  a3, a0\n    cpop a4, a0", ['a1', 'a3', 'a4']),
        P("sext.b;sext.h;zext.h", "    li   a0, 0x12344381", "    sext.b a1, a0\n    sext.h a3, a0\n    zext.h a4, a0", ['a1', 'a3', 'a4']),
        P("rol;ror;rori", "    li   a0, 0x80000001\n    li   a2, 0x2d",
          "    rol  a1, a0, a2\n    ror  a3, a0, a2\n    rori a4, a0, 31", ['a1', 'a3', 'a4']),
        P("orc.b;rev8", "    li   a0, 0x00a10070", "    orc.b a1, a0\n    rev8 a3, a0", ['a1', 'a3']),
        P("rev8;rev8 in place", "    li   a0, 0x01020304", "    rev8 a0, a0\n    rev8 a0, a0\n    rev8 a1, a0", ['a0', 'a1']),
        P("bclr;bset;binv;bext", "    li   a0, 0x0000ff00\n    li   a2, 0x28",
          "    bclr a1, a0, a2\n    bset a3, a0, a2\n    binv a4, a0, a2\n    bext a5, a0, a2", ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("bclri;bseti;binvi;bexti", "    li   a0, 0x80000000",
          "    bclri a1, a0, 31\n    bseti a3, a0, 0\n    binvi a4, a0, 31\n    bexti a5, a0, 31", ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("czero.eqz;czero.nez, rs2 != 0", "    li   a0, 0x1234\n    li   a2, 0x80000000",
          cz(5, "a1", "a0", "a2") + "\n" + cz(7, "a3", "a0", "a2"), ['a1', 'a3']),
        P("czero.eqz;czero.nez, rs2 == 0", "    li   a0, 0x1234\n    li   a2, 0",
          cz(5, "a1", "a0", "a2") + "\n" + cz(7, "a3", "a0", "a2"), ['a1', 'a3']),
        P("chain clz->rol->bset->max->czero.nez->cpop", "    li   a0, 0x00012345",
          "    clz  a1, a0\n    rol  a3, a0, a1\n    bset a4, a3, a1\n    max  a5, a4, a0\n" + cz(7, "t1", "a5", "zero")
          + "\n    cpop a1, t1", ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("lw; cpop (load-use into EXT)", "", "    lw   a0, 0(t2)\n    cpop a1, a0\n    rev8 a3, a1", ['a1', 'a3']),
        P("csrr minstret; ctz", "", "    csrr a1, minstret\n    ctz  a3, a1", ['a3']),
        P("cpop; ecall", "    li   a0, 0x7f", "    cpop a1, a0\n    ecall", ['a1']),
        P("ecall; cpop", "    li   a0, 0x7f", "    ecall\n    cpop a1, a0", ['a1']),
        P("rev8; csrci mstatus", "", "    rev8 a1, a0\n    csrci mstatus, 8\n    csrr a3, mstatus", ['a1', 'a3']),
        P("maxu; sw STALLREG; lw", "    li   a0, 0x123\n    li   a2, 0x45\n    li   a4, STALLREG",
          "    maxu a1, a0, a2\n    sw   a1, 0(a4)\n    lw   a3, 0(a4)", ['a1', 'a3'], kmax=48, periph=True),
        P("bext; mret", "    li   a2, 3\n    la   s9, 5f\n    csrw mepc, s9",
          "    bext a1, a0, a2\n    mret\n    li   a3, 0xbad\n5:", ['a1', 'a3']),
        P("orc.b;minu in handler window (nested)", "", "    orc.b a1, a0\n    minu a3, a1, a0", ['a1', 'a3'], kmax=60, nested=True),
        P("div; clz;ctz (M result into EXT)", "    li   a0, 1000003\n    li   a2, 7",
          "    div  a1, a0, a2\n    clz  a3, a1\n    ctz  a4, a1", ['a1', 'a3', 'a4'], kmax=60),
        P("clz; divu (EXT result into M)", "    li   a0, 0x00012345",
          "    clz  a1, a0\n    divu a3, a0, a1", ['a1', 'a3'], kmax=60),
        P("sh2add; rori; mul (Zba, Zbb, M)", "    li   a0, 0x1234\n    li   a2, 0x10",
          "    sh2add a1, a0, a2\n    rori a3, a1, 4\n    mul  a4, a3, a1", ['a1', 'a3', 'a4'], kmax=44),
        P("taken branch -> rori", "", "    beq  zero, zero, 7f\n    li   a3, 0xbad\n7:  rori a1, a0, 7", ['a1', 'a3']),
        P("bexti -> bnez", "    li   a0, 8", "    bexti a1, a0, 3\n    bnez a1, 7f\n    li   a3, 0x77\n7:  addi a4, a1, 1",
          ['a1', 'a3', 'a4']),
        P("bseti -> store address", "    li   a0, 0x600dcafe",
          "    bseti a4, t2, 2\n    sw   a0, 0(a4)\n    lw   a1, 4(t2)", ['a1']),
        P("EXT into x0", "    li   a0, -1\n    li   a2, 1",
          "    max  zero, a0, a2\n" + cz(5, "zero", "a0", "a2") + "\n    add  a1, zero, zero", ['a1']),
        P("legal edge: rori a0,a1,0 as a word", "", "    .word 0x6005D513\n    addi a1, a0, 1", ['a0', 'a1']),
        P("illegal: rori shamt[5]=1, rev8 RV64, clmul", "",
          "    .word 0x6205D513\n    .word 0x6B85D513\n    .word 0x0AC59533\n    addi a1, a0, 1", ['a0', 'a1'], kmax=40),
        P("illegal: funct7 0000100 neighbours, zip neighbour, unary rs2=3", "",
          "    .word 0x08C5D533\n    .word 0x08C5E533\n    .word 0x08E59513\n    .word 0x60359513\n    addi a1, a0, 1",
          ['a0', 'a1'], kmax=40),
    ]

def crypto_probes():
    """Zbkb, Zbkx and Zknh: every form Zbb does not already have, dependent chains into and out
    of them (load-use, branch operand, store address, jalr base), ECALL and MRET next to them,
    results to x0, use while the handler runs nested, and illegal neighbours that must keep
    trapping. Assembled with sweep.py's MARCH, so each probe enables the mnemonics itself."""
    on = "    .option arch, +zbb, +zbs, +zbkb, +zbkx, +zknh\n"
    def P(name, setup, probe, dump, kmax=36, **k):
        return dict(name=name, setup=on + setup, probe=probe, dump=dump, kmax=kmax, **k)
    ab = "    li   a0, 0x8f00f0a5\n    li   a2, 0x0ff0c35a"
    return [
        P("pack;packh;pack x0", ab, "    pack  a1, a0, a2\n    packh a3, a0, a2\n    pack  a4, a0, zero", ['a1', 'a3', 'a4']),
        P("brev8;zip;unzip", "    li   a0, 0x12345678",
          "    brev8 a1, a0\n    zip   a3, a0\n    unzip a4, a0", ['a1', 'a3', 'a4']),
        P("zip;unzip in place", "    li   a0, 0x8000ffff", "    zip   a0, a0\n    unzip a0, a0\n    zip   a1, a0", ['a0', 'a1']),
        P("xperm4;xperm8", "    li   a0, 0xfedcba98\n    li   a2, 0x80f30217",
          "    xperm4 a1, a0, a2\n    xperm8 a3, a0, a2\n    xperm8 a4, a2, a0", ['a1', 'a3', 'a4']),
        P("sha256sig0;sig1;sum0;sum1", "    li   a0, 0x6a09e667",
          "    sha256sig0 a1, a0\n    sha256sig1 a3, a0\n    sha256sum0 a4, a0\n    sha256sum1 a5, a0",
          ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("sha512sig0h;sig0l;sig1h;sig1l", "    li   a0, 0x6a09e667\n    li   a2, 0xf3bcc908",
          "    sha512sig0h a1, a0, a2\n    sha512sig0l a3, a2, a0\n    sha512sig1h a4, a0, a2\n    sha512sig1l a5, a2, a0",
          ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("sha512sum0r;sum1r, both halves", "    li   a0, 0x510e527f\n    li   a2, 0xade682d1",
          "    sha512sum0r a1, a0, a2\n    sha512sum0r a3, a2, a0\n    sha512sum1r a4, a0, a2\n    sha512sum1r a5, a2, a0",
          ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("chain zip->sha256sum1->xperm4->sha512sig1l->pack->brev8", "    li   a0, 0x00012345\n    li   a2, 0x76543210",
          "    zip  a1, a0\n    sha256sum1 a3, a1\n    xperm4 a4, a2, a3\n    sha512sig1l a5, a4, a3\n    pack t1, a5, a4"
          "\n    brev8 a1, t1", ['a1', 'a3', 'a4', 'a5'], kmax=40),
        P("lw; sha256sig0 (load-use)", "", "    lw   a0, 0(t2)\n    sha256sig0 a1, a0\n    xperm8 a3, a0, a1", ['a1', 'a3']),
        P("lw; sha512sum1r (load-use into rs2)", "    li   a2, 0x13579bdf",
          "    lw   a0, 4(t2)\n    sha512sum1r a1, a2, a0\n    unzip a3, a1", ['a1', 'a3']),
        P("csrr minstret; brev8", "", "    csrr a1, minstret\n    brev8 a3, a1", ['a3']),
        P("sha256sum0; ecall", "    li   a0, 0x7f", "    sha256sum0 a1, a0\n    ecall", ['a1']),
        P("ecall; sha256sum0", "    li   a0, 0x7f", "    ecall\n    sha256sum0 a1, a0", ['a1']),
        P("packh; mret", "    li   a2, 0x3c\n    la   s9, 5f\n    csrw mepc, s9",
          "    packh a1, a0, a2\n    mret\n    li   a3, 0xbad\n5:", ['a1', 'a3']),
        P("zip; csrci mstatus", "", "    zip  a1, a0\n    csrci mstatus, 8\n    csrr a3, mstatus", ['a1', 'a3']),
        P("xperm8 -> bnez", "    li   a0, 0x44332211\n    li   a2, 0x00000080",
          "    xperm8 a1, a0, a2\n    bnez a1, 7f\n    li   a3, 0x77\n7:  addi a4, a1, 1", ['a1', 'a3', 'a4']),
        P("sha512sig0h -> beq", "    li   a0, 0\n    li   a2, 1",
          "    sha512sig0h a1, a0, a2\n    beq  a1, a2, 7f\n    li   a3, 0x77\n7:  addi a4, a1, 1", ['a1', 'a3', 'a4']),
        P("pack -> store address", "    li   a0, 0x600dcafe\n    srli a4, t2, 16",
          "    pack a5, t2, a4\n    sw   a0, 16(a5)\n    lw   a1, 16(t2)", ['a1'], restore="    sw   zero, 16(t2)"),
        P("pack -> jalr base", "    la   a4, 8f\n    srli a2, a4, 16",
          "    pack a5, a4, a2\n    jalr ra, 0(a5)\n    li   a1, 0xbad\n8:  addi a3, a1, 1", ['a1', 'a3']),
        P("sha512sum0r; STALLREG store", "    li   a0, 0x123\n    li   a2, 0x45\n    li   a4, STALLREG",
          "    sha512sum0r a1, a0, a2\n    sw   a1, 0(a4)\n    lw   a3, 0(a4)", ['a1', 'a3'], kmax=48, periph=True),
        P("brev8;xperm4 in handler window (nested)", "",
          "    brev8 a1, a0\n    xperm4 a3, a1, a0", ['a1', 'a3'], kmax=60, nested=True),
        P("div; sha256sig1 (M result into crypto)", "    li   a0, 1000003\n    li   a2, 7",
          "    div  a1, a0, a2\n    sha256sig1 a3, a1", ['a1', 'a3'], kmax=60),
        P("sha256sig1; divu (crypto result into M)", "    li   a0, 0x00012345",
          "    sha256sig1 a1, a0\n    divu a3, a0, a1", ['a1', 'a3'], kmax=60),
        P("rev8; brev8; clz (Zbb and Zbkb)", "    li   a0, 0x01020304",
          "    rev8  a1, a0\n    brev8 a3, a1\n    clz   a4, a3", ['a1', 'a3', 'a4']),
        P("crypto into x0", "    li   a0, -1\n    li   a2, 1",
          "    sha512sig1h zero, a0, a2\n    zip  zero, a0\n    xperm4 zero, a0, a2\n    add  a1, zero, zero", ['a1']),
        P("taken branch -> sha256sum1", "", "    beq  zero, zero, 7f\n    li   a3, 0xbad\n7:  sha256sum1 a1, a0", ['a1', 'a3']),
        P("illegal: RV64 sha512sum0, aes32esi, funct7 0101100, unzip neighbour", "",
          "    .word 0x10459513\n    .word 0x22C58533\n    .word 0x58C58533\n    .word 0x08E5D513\n    addi a1, a0, 1",
          ['a0', 'a1'], kmax=40),
    ]

# Families that sweep.py runs only when named (sweep.py run --fam ext, --fam crypto): they are not part
# of 'all' or of 'sweep.py list', whose output the trapsweep record stores.
OPT_FAMS = {'ext': ext_probes, 'crypto': crypto_probes}

FAMS = {'ctl': ctl_probes, 'race': race_probes, 'csr': csr_probes, 'exc': exc_probes, 'exc_mie0': lambda: exc_probes('mie0'), 'exc_mie0mpie0': lambda: exc_probes('mie0mpie0'),
        'exc_mpie0': lambda: exc_probes('mpie0'), 'nested': nested_probes, 'flow': flow_probes, 'bus': bus_probes,
        'pairs': pair_probes, 'pre': pre_probes, 'pre_i': lambda: pre_probes(False), 'm': m_probes, 'bp': bp_probes}

# Families that only run on the DUT: the golden CPU has no M/Zba (m, pre) and no
# branch predictor (bp: it ignores MHPMEVENT10, so the sweep would test nothing).
# pre_i is the M-free subset of pre, for the golden CPU.
DUT_ONLY = {'m', 'pre', 'bp', 'ext', 'crypto'}

if __name__ == '__main__':
    # probes.py <family> [ext|timer|both] [ids-file]: print one program with every probe of a family
    fam = sys.argv[1]; src = sys.argv[2] if len(sys.argv) > 2 else 'ext'
    probes = [(i + 1, p) for i, p in enumerate(FAMS[fam]())]
    sys.stdout.write(build(probes, src=src))
    if len(sys.argv) > 3:
        with open(sys.argv[3], 'w') as f:
            for pid, p in probes:
                f.write(f"{pid}\t{p['name']}\n")
