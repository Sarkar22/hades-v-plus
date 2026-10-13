#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""identities.py -- the identity gate of the hardware performance counters.

Reads the output of simulator runs made with +hpm_stats (the HPM line: the totals of the event model in
sim/top.sv, each event counted in the cycle of its condition since the last reset; the counter unit is
not read, so this gate checks the model and the programs, and +hpm_check ties the model to the RTL) and, where the run
printed them, the RETIRED line (+retired, or any slow-memory or cached run) and the CACHE_STATS line
(a run with an instruction cache), and checks the identities that hold in every run without a reset
in the middle:

  classes   FETCH_WAIT + FRONT_OK + HAZARD + MSTALL_ANY + MEMWAIT_ANY + REDIRECT_ANY = CYCLE
  parts     MSTALL_MUL + MSTALL_DIV = MSTALL_ANY; MEMWAIT_LOAD + MEMWAIT_STORE = MEMWAIT_ANY;
      REDIRECT_BRANCH + REDIRECT_JUMP + REDIRECT_WB = REDIRECT_ANY; HAZARD_LOAD <= HAZARD;
      MEMWAIT_IO <= MEMWAIT_ANY
  traps     EXC_ECALL + EXC_OTHER = EXCEPTION; INT_TIMER + INT_EXT = INTERRUPT
  redirects REDIRECT_WB + p = EXCEPTION + INTERRUPT + MRET + FENCE_I - q - r, with the simulation-only terms
      p = x_irq_pending (a sequential interrupt decided but not yet jumped at the end), q = x_mret_irq
      (an MRET that took an interrupt at once) and r = x_fencei_j (a FENCE.I that retired as the
      stale instruction of an interrupt)
  branches  BP_NN + BP_NT + BP_TN + BP_TT = BRANCH; BP_NT + BP_TT = BRANCH_TAKEN;
      BP_NT + BP_TN = BR_MISPREDICT; REDIRECT_BRANCH >= BR_MISPREDICT; REDIRECT_JUMP >= JUMP;
      INSTRET <= FETCH_DELIVER
  retired   INSTRET and CYCLE equal the instructions and cycles of the RETIRED line
  standard  FETCH_WAIT = 0 and MEMWAIT_IO = MEMWAIT_ANY in the standard build (no slow memory, no cache)
  cache     with an instruction cache (the CACHE_STATS line): i_hits = FETCH_DELIVER + FETCH_DISCARD;
      IC_HIT_USED = FETCH_DELIVER; IC_MISS_JUMP <= i_refills; wait_d_for_port <= MEMWAIT_ANY;
      0 <= i_refills - i_done <= 1; 0 <= i_beats - LINE_WORDS * i_done <= LINE_WORDS - 1

    python3 test/hpm/identities.py <log> [<log> ...]

Each log is the text of one run. A run with +reset_at is refused (the HPM and CACHE_STATS lines restart
at a reset, the RETIRED line does not). Result: one line 'HPM IDENTITIES: PASS (<n> runs)' and exit
status 0, or the failing identities, 'HPM IDENTITIES: FAIL (...)' and exit status 1; 2 when a log has
no HPM line.
"""
import re
import sys


def keys(line):
    return {k: int(v) for k, v in re.findall(r"\b([A-Za-z_0-9]+)=(-?\d+)\b", line)}


def find(text, prefix):
    for line in text.splitlines():
        if line.startswith(prefix + " "):
            return line
    return None


def check(text):
    """-> (list of failed identities, list of notes)"""
    bad, notes = [], []
    hl = find(text, "HPM")
    if hl is None:
        raise SystemExit("no HPM line (run the simulator with +hpm_stats)")
    h = keys(hl)
    g = lambda k: h.get(k, 0)

    def eq(name, left, right, what):
        if left != right:
            bad.append(f"{name}: {what}: {left} != {right}")

    def le(name, small, big, what):
        if not small <= big:
            bad.append(f"{name}: {what}: {small} > {big}")

    eq("classes", g("FETCH_WAIT") + g("FRONT_OK") + g("HAZARD") + g("MSTALL_ANY") + g("MEMWAIT_ANY") + g("REDIRECT_ANY"),
       g("CYCLE"), "the six cycle classes against CYCLE")
    eq("parts", g("MSTALL_MUL") + g("MSTALL_DIV"), g("MSTALL_ANY"), "MSTALL_MUL + MSTALL_DIV against MSTALL_ANY")
    eq("parts", g("MEMWAIT_LOAD") + g("MEMWAIT_STORE"), g("MEMWAIT_ANY"), "MEMWAIT_LOAD + MEMWAIT_STORE against MEMWAIT_ANY")
    eq("parts", g("REDIRECT_BRANCH") + g("REDIRECT_JUMP") + g("REDIRECT_WB"), g("REDIRECT_ANY"),
       "the three redirect kinds against REDIRECT_ANY")
    le("parts", g("HAZARD_LOAD"), g("HAZARD"), "HAZARD_LOAD against HAZARD")
    le("parts", g("MEMWAIT_IO"), g("MEMWAIT_ANY"), "MEMWAIT_IO against MEMWAIT_ANY")
    eq("traps", g("EXC_ECALL") + g("EXC_OTHER"), g("EXCEPTION"), "EXC_ECALL + EXC_OTHER against EXCEPTION")
    eq("traps", g("INT_TIMER") + g("INT_EXT"), g("INTERRUPT"), "INT_TIMER + INT_EXT against INTERRUPT")
    eq("redirects", g("REDIRECT_WB") + g("x_irq_pending"),
       g("EXCEPTION") + g("INTERRUPT") + g("MRET") + g("FENCE_I") - g("x_mret_irq") - g("x_fencei_j"),
       "REDIRECT_WB + p against EXCEPTION + INTERRUPT + MRET + FENCE_I - q - r")
    eq("branches", g("BP_NN") + g("BP_NT") + g("BP_TN") + g("BP_TT"), g("BRANCH"), "the four prediction outcomes against BRANCH")
    eq("branches", g("BP_NT") + g("BP_TT"), g("BRANCH_TAKEN"), "BP_NT + BP_TT against BRANCH_TAKEN")
    eq("branches", g("BP_NT") + g("BP_TN"), g("BR_MISPREDICT"), "BP_NT + BP_TN against BR_MISPREDICT")
    le("branches", g("BR_MISPREDICT"), g("REDIRECT_BRANCH"), "BR_MISPREDICT against REDIRECT_BRANCH")
    le("branches", g("JUMP"), g("REDIRECT_JUMP"), "JUMP against REDIRECT_JUMP")
    le("branches", g("INSTRET"), g("FETCH_DELIVER"), "INSTRET against FETCH_DELIVER")

    rl = find(text, "RETIRED")
    if rl is not None:
        r = keys(rl)
        eq("retired", g("INSTRET"), r.get("instructions", -1), "INSTRET against the RETIRED line's instructions")
        eq("retired", g("CYCLE"), r.get("cycles", -1), "CYCLE against the RETIRED line's cycles")
    else:
        notes.append("no RETIRED line: the retired identity not checked")

    cl = find(text, "CACHE_STATS")
    slow = re.search(r"^SLOW MEMORY|^CACHE I-cache|slow memory", text, re.M) is not None
    if cl is None and not slow:
        eq("standard", g("FETCH_WAIT"), 0, "FETCH_WAIT in the standard build")
        eq("standard", g("MEMWAIT_IO"), g("MEMWAIT_ANY"), "MEMWAIT_IO against MEMWAIT_ANY in the standard build")
    if cl is not None:
        c = keys(cl)
        m = re.search(r"(\d+)-byte lines", text)
        words = int(m.group(1)) // 4 if m else None
        eq("cache", c.get("i_hits", -1), g("FETCH_DELIVER") + g("FETCH_DISCARD"), "i_hits against FETCH_DELIVER + FETCH_DISCARD")
        eq("cache", g("IC_HIT_USED"), g("FETCH_DELIVER"), "IC_HIT_USED against FETCH_DELIVER")
        le("cache", g("IC_MISS_JUMP"), c.get("i_refills", 0), "IC_MISS_JUMP against i_refills")
        le("cache", c.get("wait_d_for_port", 0), g("MEMWAIT_ANY"), "wait_d_for_port against MEMWAIT_ANY")
        pend = c.get("i_refills", 0) - c.get("i_done", 0)
        if not 0 <= pend <= 1:
            bad.append(f"cache: i_refills - i_done = {pend}, not 0 or 1")
        if words:
            extra = c.get("i_beats", 0) - words * c.get("i_done", 0)
            if not 0 <= extra <= words - 1:
                bad.append(f"cache: i_beats - {words} * i_done = {extra}, not in 0..{words - 1}")
        else:
            notes.append("no line size in the log: the beat bound of the cache identities not checked")
    return bad, notes


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    failed, n = [], 0
    for path in sys.argv[1:]:
        text = open(path, errors="replace").read()
        if re.search(r"^RESET at cycle", text, re.M):
            failed.append(f"{path}: the run has resets in the middle (+reset_at): refused")
            continue
        try:
            bad, notes = check(text)
        except SystemExit as e:
            print(f"{path}: {e}")
            return 2
        n += 1
        for b in bad:
            failed.append(f"{path}: {b}")
        for note in notes:
            print(f"{path}: note: {note}")
    for f in failed:
        print(f"  {f}")
    print(f"HPM IDENTITIES: {'FAIL (' + str(len(failed)) + ' identities)' if failed else 'PASS (' + str(n) + ' runs)'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
