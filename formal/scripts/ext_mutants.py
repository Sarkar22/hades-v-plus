#!/usr/bin/env python3
"""ext_mutants.py <work_dir>: for every line of mutants/ext_mutants.txt create
<work_dir>/mutants/ext_<name>/execute_stage_formal.v from <work_dir>/gen/execute_stage_formal.v
(each mutant = exactly one textual substitution of the sv2v model of the real RTL; the
original text must occur exactly once; in both texts \\n and \\t stand for a newline and a
tab) and <work_dir>/sby/mut_ext_<name>_ext.sby.
Prints "<name> <target task> <description>" per mutant."""
import os, sys
w = sys.argv[1]
src = open(os.path.join(w, 'gen/execute_stage_formal.v')).read()
sby = open(os.path.join(w, 'sby', 'ext.sby')).read()
for line in open(os.path.join(w, 'mutants/ext_mutants.txt')):
    if line.startswith('#') or not line.strip():
        continue
    fields = line.rstrip('\n').replace('\\|', '\x00').split('|')
    name, target, old, new, desc = [x.replace('\x00', '|') for x in fields]
    old, new = [x.replace('\\n', '\n').replace('\\t', '\t') for x in (old, new)]
    n = src.count(old)
    if n != 1:
        sys.exit(f"mutant {name}: original text occurs {n} times (expected exactly 1)")
    d = os.path.join(w, 'mutants', 'ext_' + name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'execute_stage_formal.v'), 'w').write(src.replace(old, new))
    t = sby.replace('../gen/execute_stage_formal.v', f'../mutants/ext_{name}/execute_stage_formal.v')
    open(os.path.join(w, 'sby', f'mut_ext_{name}_ext.sby'), 'w').write(t)
    print(f"{name} {target} {desc}")
