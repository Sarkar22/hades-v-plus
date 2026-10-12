#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""mkwarm.py -- warm-cache variants of the timing-exact test programs.

Some programs of test/asm time a block of their own instructions with two reads of mcycle (or
cycle) and require an exact cycle count: the two test_cycle_exact windows of zbb.s, zbkb.s,
zbkx.s, zbs.s, zicond.s and zknh.s, the three adjacent-read pairs of zicntr.s (its reports 4 and
5) and the 303 windows of zkt.s. With an instruction cache (docs/CACHES.md) the first fetch of
every line misses, so a window that runs once from a cold cache takes longer than on the
single-cycle RAM, at every memory latency. A warm variant runs each window twice in a row: the
first pass fills the cache, and only the readings of the second pass, in which every fetch of the
window hits and takes one cycle as on the standard RAM, reach the checks. With a cache the looped
windows are therefore exact again (test/memsys/programs.py judges them strictly).

    python3 test/memsys/mkwarm.py            write test/memsys/warm_<name>.s (and warm_zkt_<k>.s)
    python3 test/memsys/mkwarm.py --list     print the windows, the loop register and the parts
    python3 test/memsys/mkwarm.py --check    the committed files equal what this script writes,
                                             a negative case of the dependency rule, and a run
                                             of every warm file and its original on the standard
                                             simulator (HaDes-V+): equal reports and verdict

THE WINDOWS are listed below, per program, as line numbers of the original in test/asm:
(first line of the loop body, first read, second read). The loop body begins with the window's
operand set-up (li32 lines and flush_pipeline), so that both passes start from the same register
values, and ends with the window's second read. Only the listed pairs are windows: the gaps
between two windows are not.

THE LOOP. Before the body: 'addi <r>, zero, 2' and a label; after it: 'addi <r>, <r>, -1' and
'bnez <r>, <label>' (three words per window, outside the window). <r> is a register that the
original never uses. The body must contain no label, branch, jump, load, store, fence, CSR write
or other system instruction, and must be idempotent: no register that the body reads before
writing it may be written by the body (otherwise the second pass would start from other values;
zknh.s's chain, for example, depends on its start value, which the li32 set-up restores). The
script checks all of this on the assembled program and stops with an error naming the window.

DEPENDENCIES. A check may compare a window's delta with another window's. Every block check of
zkt.s (reports 3 to 304) compares its delta with s9, the delta of the reference window (report 2);
the test_cycle_exact checks compare the extension chain with the add chain; zicntr.s compares its
three pairs with each other. A looped window whose check reads another window's delta is exact
only if that window is looped in the same file, so the script refuses to write a file that loops
a window without the windows it depends on.

SIZE. Code must stay below the reserved top 4 KiB of the 32 KiB RAM (std/hades-v.ld), with at
least 64 bytes to spare. zkt.s alone uses almost all of that, so its windows are spread over
parts warm_zkt_1.s ... warm_zkt_<K>.s: every part keeps all of zkt.s, loops the reference window
and one contiguous range of the block windows; every block window is looped in exactly one part.
K follows from the assembled sizes.

Each generated file carries the line '# mkwarm: unlooped window reports: <list>' (or 'none'):
the reports of the windows that the file does not loop, which keep the original's timing rule
with a cache; programs.py reads it.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
ASM = os.path.join(REPO, "test", "asm")
TOOLS = "/opt/riscv32i/bin/riscv32-unknown-elf-"
LINKER_SCRIPT = os.path.join(REPO, "std", "hades-v.ld")
RAM_START = 0x40000
CODE_LIMIT = 28 * 1024          # below the reserved top 4 KiB of the 32 KiB RAM
SPARE = 64                      # bytes that every generated file must leave free
LOOP_WORDS = 3                  # 'addi r, zero, 2', 'addi r, r, -1', 'bnez r, label'
REGISTER_CHOICE = [26, 27, 16, 17, 4, 3, 8, 1]     # s10, s11, a6, a7, tp, gp, s0, ra
ABI = {1: "ra", 3: "gp", 4: "tp", 8: "s0", 16: "a6", 17: "a7", 26: "s10", 27: "s11"}

# The zkt.s windows: the reference window (report 2) first, then the 302 block windows in the order
# of their checks (reports 3 to 304).
ZKT_WINDOWS = [
    (177, 181, 190), (199, 203, 212), (215, 218, 227), (230, 233, 242), (245, 248, 257), (260, 263, 272),
    (275, 278, 287), (290, 293, 302), (305, 308, 317), (320, 323, 332), (335, 338, 347), (350, 353, 362),
    (365, 368, 377), (380, 383, 392), (395, 398, 407), (410, 413, 422), (425, 428, 437), (440, 443, 452),
    (455, 458, 467), (470, 473, 482), (485, 488, 497), (500, 503, 512), (515, 518, 527), (530, 533, 542),
    (545, 548, 557), (560, 563, 572), (575, 578, 587), (590, 593, 602), (605, 608, 617), (620, 623, 632),
    (635, 638, 647), (650, 653, 662), (665, 668, 677), (680, 683, 692), (695, 698, 707), (710, 713, 722),
    (725, 728, 737), (740, 743, 752), (755, 758, 767), (770, 773, 782), (785, 788, 797), (800, 803, 812),
    (815, 818, 827), (830, 833, 842), (845, 848, 857), (860, 863, 872), (875, 878, 887), (890, 893, 902),
    (905, 908, 917), (920, 923, 932), (941, 945, 954), (957, 960, 969), (972, 975, 984), (987, 990, 999),
    (1002, 1005, 1014), (1017, 1020, 1029), (1032, 1035, 1044), (1047, 1050, 1059), (1062, 1065, 1074), (1077, 1080, 1089),
    (1092, 1095, 1104), (1107, 1110, 1119), (1122, 1125, 1134), (1137, 1140, 1149), (1152, 1155, 1164), (1174, 1178, 1187),
    (1191, 1194, 1203), (1207, 1210, 1219), (1223, 1226, 1235), (1239, 1242, 1251), (1255, 1258, 1267), (1271, 1274, 1283),
    (1287, 1290, 1299), (1303, 1306, 1315), (1319, 1322, 1331), (1335, 1338, 1347), (1351, 1354, 1363), (1367, 1370, 1379),
    (1383, 1386, 1395), (1399, 1402, 1411), (1415, 1418, 1427), (1431, 1434, 1443), (1447, 1450, 1459), (1463, 1466, 1475),
    (1479, 1482, 1491), (1495, 1498, 1507), (1511, 1514, 1523), (1527, 1530, 1539), (1543, 1546, 1555), (1559, 1562, 1571),
    (1575, 1578, 1587), (1591, 1594, 1603), (1607, 1610, 1619), (1629, 1633, 1642), (1645, 1648, 1657), (1660, 1663, 1672),
    (1675, 1678, 1687), (1690, 1693, 1702), (1705, 1708, 1717), (1720, 1723, 1732), (1735, 1738, 1747), (1750, 1753, 1762),
    (1765, 1768, 1777), (1780, 1783, 1792), (1795, 1798, 1807), (1810, 1813, 1822), (1825, 1828, 1837), (1840, 1843, 1852),
    (1855, 1858, 1867), (1870, 1873, 1882), (1885, 1888, 1897), (1900, 1903, 1912), (1915, 1918, 1927), (1930, 1933, 1942),
    (1951, 1955, 1964), (1967, 1970, 1979), (1982, 1985, 1994), (1997, 2000, 2009), (2012, 2015, 2024), (2027, 2030, 2039),
    (2042, 2045, 2054), (2057, 2060, 2069), (2072, 2075, 2084), (2087, 2090, 2099), (2108, 2112, 2121), (2124, 2127, 2136),
    (2139, 2142, 2151), (2154, 2157, 2166), (2169, 2172, 2181), (2184, 2187, 2196), (2199, 2202, 2211), (2214, 2217, 2226),
    (2229, 2232, 2241), (2244, 2247, 2256), (2265, 2268, 2277), (2280, 2282, 2291), (2294, 2296, 2305), (2308, 2310, 2319),
    (2322, 2324, 2333), (2336, 2338, 2347), (2350, 2352, 2361), (2364, 2366, 2375), (2378, 2380, 2389), (2392, 2394, 2403),
    (2406, 2408, 2417), (2420, 2422, 2431), (2434, 2436, 2445), (2448, 2450, 2459), (2462, 2464, 2473), (2476, 2478, 2487),
    (2490, 2492, 2501), (2504, 2506, 2515), (2518, 2520, 2529), (2532, 2534, 2543), (2546, 2548, 2557), (2560, 2562, 2571),
    (2574, 2576, 2585), (2588, 2590, 2599), (2602, 2604, 2613), (2616, 2618, 2627), (2630, 2632, 2641), (2644, 2646, 2655),
    (2658, 2660, 2669), (2672, 2674, 2683), (2686, 2688, 2697), (2700, 2702, 2711), (2714, 2716, 2725), (2728, 2730, 2739),
    (2742, 2744, 2753), (2756, 2758, 2767), (2770, 2772, 2781), (2784, 2786, 2795), (2798, 2800, 2809), (2812, 2814, 2823),
    (2826, 2828, 2837), (2840, 2842, 2851), (2854, 2856, 2865), (2868, 2870, 2879), (2882, 2884, 2893), (2896, 2898, 2907),
    (2910, 2912, 2921), (2924, 2926, 2935), (2938, 2940, 2949), (2952, 2954, 2963), (2966, 2968, 2977), (2980, 2982, 2991),
    (2994, 2996, 3005), (3008, 3010, 3019), (3022, 3024, 3033), (3036, 3038, 3047), (3050, 3052, 3061), (3064, 3066, 3075),
    (3078, 3080, 3089), (3092, 3094, 3103), (3106, 3108, 3117), (3120, 3122, 3131), (3134, 3135, 3144), (3147, 3148, 3157),
    (3168, 3172, 3181), (3184, 3187, 3196), (3199, 3202, 3211), (3214, 3217, 3226), (3229, 3232, 3241), (3244, 3247, 3256),
    (3259, 3262, 3271), (3274, 3277, 3286), (3289, 3292, 3301), (3304, 3307, 3316), (3319, 3322, 3331), (3334, 3337, 3346),
    (3349, 3351, 3360), (3363, 3365, 3374), (3377, 3379, 3388), (3391, 3393, 3402), (3405, 3407, 3416), (3419, 3421, 3430),
    (3433, 3435, 3444), (3447, 3449, 3458), (3461, 3463, 3472), (3475, 3477, 3486), (3489, 3491, 3500), (3503, 3505, 3514),
    (3517, 3519, 3528), (3531, 3533, 3542), (3545, 3547, 3556), (3559, 3561, 3570), (3573, 3575, 3584), (3587, 3589, 3598),
    (3608, 3612, 3621), (3624, 3627, 3636), (3639, 3642, 3651), (3654, 3657, 3666), (3669, 3672, 3681), (3684, 3687, 3696),
    (3699, 3702, 3711), (3714, 3717, 3726), (3729, 3732, 3741), (3744, 3747, 3756), (3759, 3762, 3771), (3774, 3777, 3786),
    (3789, 3792, 3801), (3804, 3807, 3816), (3819, 3822, 3831), (3834, 3837, 3846), (3849, 3852, 3861), (3864, 3867, 3876),
    (3879, 3882, 3891), (3894, 3897, 3906), (3909, 3912, 3921), (3930, 3933, 3942), (3945, 3947, 3956), (3959, 3961, 3970),
    (3973, 3975, 3984), (3987, 3989, 3998), (4001, 4003, 4012), (4015, 4017, 4026), (4029, 4031, 4040), (4043, 4045, 4054),
    (4057, 4059, 4068), (4071, 4073, 4082), (4085, 4087, 4096), (4099, 4101, 4110), (4113, 4115, 4124), (4127, 4129, 4138),
    (4141, 4143, 4152), (4155, 4157, 4166), (4169, 4171, 4180), (4183, 4185, 4194), (4197, 4199, 4208), (4211, 4213, 4222),
    (4225, 4227, 4236), (4239, 4241, 4250), (4253, 4255, 4264), (4274, 4278, 4287), (4290, 4293, 4302), (4305, 4308, 4317),
    (4320, 4323, 4332), (4335, 4338, 4347), (4350, 4353, 4362), (4365, 4368, 4377), (4380, 4383, 4392), (4395, 4398, 4407),
    (4410, 4413, 4422), (4425, 4428, 4437), (4440, 4443, 4452), (4455, 4458, 4467), (4470, 4473, 4482), (4485, 4488, 4497),
    (4500, 4503, 4512), (4515, 4518, 4527), (4530, 4533, 4542), (4545, 4548, 4557), (4560, 4563, 4572), (4575, 4578, 4587),
    (4590, 4593, 4602), (4605, 4608, 4617), (4620, 4623, 4632), (4635, 4638, 4647), (4650, 4653, 4662), (4665, 4668, 4677),
    (4680, 4683, 4692), (4695, 4698, 4707), (4710, 4713, 4722),
]

# The test_cycle_exact windows of the six extension programs: the extension chain, the add chain
TWO_CHAINS = {0: [1], 1: [0]}
PROGRAMS = {
    "zbb":    dict(windows=[(1683, 1687, 1704), (1707, 1710, 1727)], depends=TWO_CHAINS),
    "zbkb":   dict(windows=[(946, 950, 967), (970, 973, 990)], depends=TWO_CHAINS),
    "zbkx":   dict(windows=[(905, 909, 926), (929, 932, 949)], depends=TWO_CHAINS),
    "zbs":    dict(windows=[(1365, 1369, 1386), (1389, 1392, 1409)], depends=TWO_CHAINS),
    "zicond": dict(windows=[(981, 985, 1002), (1005, 1008, 1025)], depends=TWO_CHAINS),
    "zknh":   dict(windows=[(1345, 1349, 1366), (1369, 1372, 1389)], depends=TWO_CHAINS),
    # test_cycle_is_mcycle: mcycle/mcycle (the baseline), mcycle/cycle, cycle/mcycle
    "zicntr": dict(windows=[(192, 193, 194), (196, 197, 198), (200, 201, 202)],
                   depends={0: [1, 2], 1: [0], 2: [0]}),
    # every block window depends on the reference window; the reports of the windows' checks
    "zkt":    dict(windows=ZKT_WINDOWS, depends={i: [0] for i in range(1, len(ZKT_WINDOWS))},
                   reports=[2 + i for i in range(len(ZKT_WINDOWS))], parts=True),
}

READ = re.compile(r"^\s*csrr\s+\w+,\s*(mcycle|cycle)\s*(#.*)?$")
LABEL = re.compile(r"^\s*[A-Za-z_.$0-9]+\s*:")
REPORT_MACRO = re.compile(r"^\s*(assert_equal|assert_value|expect_trap|pass|fail)\b")


class Refused(Exception):
    """A window or a file that the rules above do not allow."""


# ------------------------------------------------------------------------------ the source
def original(name):
    with open(os.path.join(ASM, name + ".s")) as f:
        return f.read().split("\n")


def check_listing(name, lines):
    """The listed lines must still be what they were: a set-up run, then two reads."""
    for i, (s, a, b) in enumerate(PROGRAMS[name]["windows"]):
        where = f"{name}.s window {i} (lines {s}, {a}, {b})"
        if not (s <= a < b <= len(lines)):
            raise Refused(f"{where}: the lines are out of order or beyond the end of the file")
        if not READ.match(lines[a - 1]) or not READ.match(lines[b - 1]):
            raise Refused(f"{where}: lines {a} and {b} are not two reads of mcycle or cycle")
        for k in range(s, b + 1):
            if LABEL.match(lines[k - 1]):
                raise Refused(f"{where}: line {k} holds a label inside the loop body")
        if any(READ.match(lines[k - 1]) for k in range(s, a)) or any(READ.match(lines[k - 1]) for k in range(a + 1, b)):
            raise Refused(f"{where}: another read of mcycle or cycle inside the window")


def check_reports(name, lines):
    """For zkt.s: the report of each window's check, counted in the order of the test code (after
    test_init, where the code runs straight through), must be the listed one."""
    p = PROGRAMS[name]
    if "reports" not in p:
        return
    start = next(i for i, l in enumerate(lines) if l.startswith("test_init:"))
    count, after = 0, {}
    ends = sorted((b, i) for i, (_, _, b) in enumerate(p["windows"]))
    j = 0
    for k in range(start, len(lines)):
        while j < len(ends) and ends[j][0] - 1 < k:
            after[ends[j][1]] = count + 1          # the next report after the window's second read
            j += 1
        if REPORT_MACRO.match(lines[k]):
            count += 1
    for i, want in enumerate(p["reports"]):
        if after.get(i) != want:
            raise Refused(f"{name}.s window {i}: its check is report {after.get(i)}, not {want} as listed")


def check_dependencies(name, looped):
    deps = PROGRAMS[name]["depends"]
    for w in sorted(looped):
        missing = [d for d in deps.get(w, []) if d not in looped]
        if missing:
            raise Refused(f"{name}: window {w} (lines {PROGRAMS[name]['windows'][w]}) is looped, but the "
                          f"window(s) {missing} that its check depends on are not")


def generate(name, looped, reg, part=None, parts=None):
    """The text of a warm file of <name> that loops the windows <looped> with register <reg>."""
    check_dependencies(name, set(looped))
    lines = original(name)
    p = PROGRAMS[name]
    before, after = {}, {}
    for i in looped:
        s, _, b = p["windows"][i]
        r = ABI[reg]
        before[s] = [f"    addi {r}, zero, 2               # warm loop {i}: the window below runs twice",
                     f"warm_loop_{i}:"]
        after[b] = [f"warm_loop_{i}_end:",
                    f"    addi {r}, {r}, -1",
                    f"    bnez {r}, warm_loop_{i}           # the second pass is the one that is checked"]
    unlooped = sorted(p["reports"][i] for i in range(len(p["windows"])) if i not in set(looped)) \
        if "reports" in p else []
    what = f"part {part} of {parts}" if part else "every window looped"
    note = ["#",
            f"# Generated by test/memsys/mkwarm.py from test/asm/{name}.s ({what}); do not edit, run",
            "# mkwarm.py instead. Each looped timing window (see mkwarm.py) runs twice in a row with its",
            "# operand set-up, and only its second pass, fetched from a warm instruction cache, reaches",
            f"# the checks. The loop counter is {ABI[reg]}, which the original never uses. Everything else is",
            "# the original program, so the reports are numbered as in the original.",
            f"# mkwarm: unlooped window reports: {ranges(unlooped) or 'none'}"]
    head = next((k for k, l in enumerate(lines[:12]) if l.startswith("# File:")), None)
    out = []
    for k, l in enumerate(lines, start=1):
        out += before.get(k, [])
        out.append(l)
        out += after.get(k, [])
        if head is not None and k == head + 1:
            out += note
    if head is None:
        out = note[1:] + out
    return "\n".join(out)


def ranges(nums):
    out, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        out.append(str(nums[i]) if i == j else f"{nums[i]}-{nums[j]}")
        i = j + 1
    return ",".join(out)


# ------------------------------------------------------------------------------ assembling
def assemble(text, d, base):
    """-> (words of the loaded image from RAM_START, symbols, image size in bytes)."""
    src = os.path.join(d, base + ".s")
    elf = os.path.join(d, base + ".elf")
    with open(src, "w") as f:
        f.write(text)
    # as the Makefile assembles test/asm and test/memsys programs
    r = subprocess.run([TOOLS + "gcc", "-nostdlib", "-nostartfiles", "-T", LINKER_SCRIPT, "-o", elf, src],
                       capture_output=True, text=True)
    if r.returncode:
        raise Refused(f"{base}: does not assemble:\n{r.stderr[-2000:]}")
    binf = os.path.join(d, base + ".bin")
    subprocess.run([TOOLS + "objcopy", "-O", "binary", elf, binf], check=True)
    data = open(binf, "rb").read()
    words = [int.from_bytes(data[k:k + 4], "little") for k in range(0, len(data) - 3, 4)]
    syms = {}
    for l in subprocess.run([TOOLS + "nm", elf], capture_output=True, text=True, check=True).stdout.splitlines():
        f = l.split()
        if len(f) == 3:
            syms[f[2]] = int(f[0], 16)
    end = RAM_START
    for l in subprocess.run([TOOLS + "size", "-A", elf], capture_output=True, text=True, check=True).stdout.splitlines():
        f = l.split()
        if len(f) == 3 and f[0] in (".reset", ".text", ".rodata", ".data", ".sdata", ".sbss", ".bss") \
                and f[1].isdigit() and int(f[1]):
            end = max(end, int(f[2]) + int(f[1]))
    return words, syms, end - RAM_START


def fields(w):
    return w & 0x7F, (w >> 7) & 31, (w >> 12) & 7, (w >> 15) & 31, (w >> 20) & 31


def decode(w):
    """-> (registers read, registers written, what forbids it in a loop body or None)."""
    op, rd, f3, rs1, rs2 = fields(w)
    if op in (0x37, 0x17):                       # lui, auipc
        return set(), {rd}, None
    if op == 0x13:                               # OP-IMM (also the unary Zbb/Zbkb/Zknh forms)
        return {rs1}, {rd}, None
    if op == 0x33:                               # OP (also M, Zbb, Zbkb, Zbkx, Zicond, Zknh)
        return {rs1, rs2}, {rd}, None
    if op == 0x73:
        if f3 == 0:
            return set(), set(), "a system instruction"
        writes = f3 in (1, 5) or rs1 != 0
        if writes:
            return {rs1} if f3 < 4 else set(), {rd}, "a CSR write"
        return set(), {rd}, None
    names = {0x63: "a branch", 0x6F: "a jump", 0x67: "a jump", 0x03: "a load", 0x23: "a store", 0x0F: "a fence"}
    return {rs1, rs2}, {rd}, names.get(op, f"an instruction with opcode 0x{op:02x}")


def registers_used(words):
    """Every register that an instruction word of the image names (data words count too)."""
    used = set()
    for w in words:
        op, rd, f3, rs1, rs2 = fields(w)
        if op in (0x37, 0x17, 0x6F):
            used |= {rd}
        elif op in (0x13, 0x03, 0x67, 0x73):
            used |= {rd, rs1}
        elif op in (0x23, 0x63):
            used |= {rs1, rs2}
        else:
            used |= {rd, rs1, rs2}
    return used - {0}


def is_counter_read(w):
    op, rd, f3, rs1, _ = fields(w)
    return op == 0x73 and f3 == 2 and rs1 == 0 and (w >> 20) in (0xB00, 0xC00)


def check_bodies(name, looped, words, syms):
    for i in looped:
        where = f"{name}.s window {i} (lines {PROGRAMS[name]['windows'][i]})"
        a, b = syms[f"warm_loop_{i}"], syms[f"warm_loop_{i}_end"]
        body = words[(a - RAM_START) // 4:(b - RAM_START) // 4]
        if not body or not is_counter_read(body[-1]) or sum(map(is_counter_read, body)) != 2:
            raise Refused(f"{where}: the loop body does not end with its second counter read")
        written, read_first = set(), set()
        for k, w in enumerate(body):
            rd_, wr, bad = decode(w)
            if bad:
                raise Refused(f"{where}: word {k} of the loop body (0x{w:08x}) is {bad}")
            read_first |= (rd_ - written) - {0}
            written |= wr - {0}
        clash = read_first & written
        if clash:
            raise Refused(f"{where}: the loop body is not idempotent: it reads x{sorted(clash)} before writing "
                          f"them and writes them too (add their set-up to the body)")


def loop_register(name, tmp):
    words, _, _ = assemble("\n".join(original(name)), tmp, name + "_orig")
    used = registers_used(words)
    for r in REGISTER_CHOICE:
        if r not in used:
            return r
    raise Refused(f"{name}.s: no free register for the loop counter")


def plan(tmp):
    """-> [(file name, program, looped windows, register, part, parts)] and the size of each file."""
    out = []
    for name, p in PROGRAMS.items():
        lines = original(name)
        check_listing(name, lines)
        check_reports(name, lines)
        reg = loop_register(name, tmp)
        n = len(p["windows"])
        if not p.get("parts"):
            out.append((f"warm_{name}.s", name, list(range(n)), reg, None, None))
            continue
        _, _, size = assemble("\n".join(lines), tmp, name + "_size")
        loops = (CODE_LIMIT - SPARE - size) // (4 * LOOP_WORDS)
        if loops < 2:
            raise Refused(f"{name}.s: {size} bytes leave no room for a loop")
        blocks = list(range(1, n))
        k = -(-len(blocks) // (loops - 1))
        per, extra = divmod(len(blocks), k)
        start = 0
        for part in range(1, k + 1):
            cnt = per + (1 if part <= extra else 0)
            out.append((f"warm_{name}_{part}.s", name, [0] + blocks[start:start + cnt], reg, part, k))
            start += cnt
    return out


def build_all(tmp):
    """-> {file name: text}, after every check."""
    files = {}
    covered = {}
    for fname, name, looped, reg, part, parts in plan(tmp):
        text = generate(name, looped, reg, part, parts)
        words, syms, size = assemble(text, tmp, fname[:-2])
        if size > CODE_LIMIT - SPARE:
            raise Refused(f"{fname}: {size} bytes, more than {CODE_LIMIT - SPARE} ({SPARE} bytes below the "
                          f"reserved top 4 KiB)")
        check_bodies(name, looped, words, syms)
        files[fname] = text + ("" if text.endswith("\n") else "\n")
        for w in looped:
            covered.setdefault(name, []).append(w)
    for name, p in PROGRAMS.items():       # zkt: each block window in exactly one part
        if p.get("parts"):
            got = sorted(covered[name])
            want = sorted([0] * sum(1 for f in files if f.startswith(f"warm_{name}_")) + list(range(1, len(p["windows"]))))
            if got != want:
                raise Refused(f"{name}: the parts do not loop every block window exactly once")
    return files


# ------------------------------------------------------------------------------ --check runs
def make(args, env, capture=True):
    r = subprocess.run(["make", "-s", "--no-print-directory", "-C", REPO] + args, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode:
        raise SystemExit(f"mkwarm.py: make {' '.join(args)} failed:\n{r.stdout[-3000:]}")
    return r.stdout


def reports(log):
    rep = "".join("P" if m.group(1) == "pass" else "F" for m in re.finditer(r"Test (pass|fail)!", log))
    final = next((l.strip() for l in log.splitlines()
                  if re.match(r"\s*(All tests passed|Some test\(s\) failed|Inital test failed|Simulation timeout!)", l)), "")
    return rep, final


def run_check(files, tmp, jobs, timeout):
    ok = True
    # 1. the committed files
    have = sorted(f for f in os.listdir(HERE) if re.match(r"warm_.*\.s$", f))
    for f in sorted(set(have) | set(files)):
        path = os.path.join(HERE, f)
        if f not in files:
            print(f"  STALE   {f}: committed, but mkwarm.py does not generate it"); ok = False
        elif f not in have:
            print(f"  MISSING {f}: mkwarm.py generates it, but it is not in test/memsys"); ok = False
        elif open(path).read() != files[f]:
            print(f"  DIFFERS {f}: not what mkwarm.py generates (run mkwarm.py)"); ok = False
        else:
            print(f"  same    {f}")
    # 2. a negative case of the dependency rule
    try:
        generate("zkt", list(range(1, 11)), loop_register("zkt", tmp), 1, 1)
        print("  NEGATIVE CASE FAILED: a zkt part without the reference window was not refused"); ok = False
    except Refused as e:
        print(f"  negative case: a zkt part without the reference window is refused ({e})")
    # 3. every warm file and its original on the standard simulator
    env = {k: v for k, v in os.environ.items() if not k.startswith("HADES_")}
    cfg = make(["sim-config"], env)
    bmake = re.search(r"build directory:\s+(\S+)", cfg).group(1)
    bdir = os.path.join(REPO, bmake)
    print("  building the standard HaDes-V+ simulator and the programs ...", flush=True)
    make(["frtos-model", "FRTOS_CPU=dut", "FRTOS_RAM_KB=32"], env)
    sim = os.path.join(bdir, "frtos-model", "dut-32k", "top")
    pairs = [(f, os.path.join("test", "memsys", f[:-2]), os.path.join("test", "asm", PROGRAM_OF[f])) for f in sorted(files)]
    targets = sorted({os.path.join(bmake, p, "init.mem") for _, w, o in pairs for p in (w, o)})
    make(targets, env)

    def run(prog):
        d = os.path.join(tmp, "runs", prog.replace("/", "-"))
        os.makedirs(d, exist_ok=True)
        shutil.copy(os.path.join(bdir, prog, "init.mem"), d)
        r = subprocess.run([sim, "+nodump", f"+timeout={timeout}"], cwd=d, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, errors="replace")
        return reports(r.stdout) + (r.returncode,)
    import concurrent.futures as cf
    progs = sorted({p for _, w, o in pairs for p in (w, o)})
    with cf.ThreadPoolExecutor(max_workers=jobs) as ex:
        res = dict(zip(progs, ex.map(run, progs)))
    for f, w, o in pairs:
        rw, ro = res[w], res[o]
        same = rw[:2] == ro[:2] and rw[2] == 0 and ro[2] == 0 and ro[1]
        ok &= bool(same)
        print(f"  {'same' if same else 'DIFFERS'} {f}: {rw[0].count('P')} pass, {rw[0].count('F')} fail, '{rw[1]}'"
              + ("" if same else f"; the original: {ro[0].count('P')} pass, {ro[0].count('F')} fail, '{ro[1]}'"
                 f" (reports {'equal' if rw[0] == ro[0] else 'differ'}; exit {rw[2]}/{ro[2]})"))
    return ok


PROGRAM_OF = {}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="check the committed files and run them")
    g.add_argument("--list", action="store_true", help="print the windows and the parts")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=100000, help="cycle limit of a --check run")
    a = ap.parse_args()
    tmp = tempfile.mkdtemp(prefix="mkwarm-")
    try:
        try:
            files = build_all(tmp)
        except Refused as e:
            print(f"mkwarm.py: refused: {e}")
            return 1
        for fname, name, looped, reg, part, parts in plan(tmp):
            PROGRAM_OF[fname] = name
        if a.list:
            for fname, name, looped, reg, part, parts in plan(tmp):
                ws = PROGRAMS[name]["windows"]
                print(f"{fname}: from test/asm/{name}.s, loop register {ABI[reg]}, {len(looped)} looped window(s): "
                      + ", ".join(f"{i} (lines {ws[i][0]}-{ws[i][2]})" for i in looped[:4])
                      + (f", ... {looped[-1]} (lines {ws[looped[-1]][0]}-{ws[looped[-1]][2]})" if len(looped) > 4 else ""))
            return 0
        if a.check:
            print("MKWARM CHECK")
            ok = run_check(files, tmp, a.jobs, a.timeout)
            print(f"MKWARM CHECK: {'PASS' if ok else 'FAIL'} ({len(files)} files)")
            return 0 if ok else 1
        for f in sorted(os.listdir(HERE)):
            if re.match(r"warm_.*\.s$", f) and f not in files:
                os.remove(os.path.join(HERE, f))
        for f, text in files.items():
            with open(os.path.join(HERE, f), "w") as fh:
                fh.write(text)
        print(f"mkwarm.py: wrote {len(files)} files: {', '.join(sorted(files))}")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
