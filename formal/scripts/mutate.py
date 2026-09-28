#!/usr/bin/env python3
"""mutate.py <work_dir>: for every line of mutants/mutants.txt create
<work_dir>/mutants/<name>/execute_stage_formal.v from <work_dir>/gen/execute_stage_formal.v
(each mutant = exactly one textual substitution of the sv2v model of the real RTL;
the original text must occur exactly once) and the matching sby files
<work_dir>/sby/mut_<name>_{div,fmul_ops,iface}.sby. Prints one line per mutant."""
import os, sys
w = sys.argv[1]
src = open(os.path.join(w, 'gen/execute_stage_formal.v')).read()
for line in open(os.path.join(w, 'mutants/mutants.txt')):
    if line.startswith('#') or not line.strip():
        continue
    fields = line.rstrip('\n').replace('\\|', '\x00').split('|')
    name, old, new, desc = [x.replace('\x00', '|').replace('\\n', '\n') for x in fields]
    n = src.count(old)
    if n != 1:
        sys.exit(f"mutant {name}: original text occurs {n} times (expected exactly 1)")
    d = os.path.join(w, 'mutants', name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'execute_stage_formal.v'), 'w').write(src.replace(old, new))
    for sby in ('div.sby', 'fmul_ops.sby', 'iface.sby'):
        t = open(os.path.join(w, 'sby', sby)).read()
        t = t.replace('../gen/execute_stage_formal.v', f'../mutants/{name}/execute_stage_formal.v')
        open(os.path.join(w, 'sby', f'mut_{name}_{sby}'), 'w').write(t)
    print(f"{name}: {desc}")
