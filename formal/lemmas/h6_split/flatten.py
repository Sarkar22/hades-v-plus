#!/usr/bin/env python3
"""flatten.py <dir>: turn the Yosys SMT2 model <dir>/h6_model.smt2 of the H6
validity check into plain QF_BV queries for a single state, one per divisor case:
  * every free input  (declare-fun |hint_validity#N| (|hint_validity_s|) (_ BitVec W))
    becomes            (declare-const |in#N| (_ BitVec W)) + (define-fun ... |in#N|)
    -- semantics-preserving: the query mentions exactly one state s0, so an
    uninterpreted function applied to it is just an unconstrained value;
  * query:  assert (i s0), (h s0), (u s0)  and  (not (a s0))    -- as yosys-smtbmc does;
  * case k (0..31): 2^k <= f_q_B < 2^(k+1)   (k=31: f_q_B >= 2^31);  case 'zero': f_q_B == 0.
The 33 cases cover every 32-bit f_q_B; all unsat  <=>  H6 valid."""
import os, re, sys
d = sys.argv[1] if len(sys.argv) > 1 else '.'
src = open(os.path.join(d, 'h6_model.smt2')).read()
decl = re.compile(r'^\(declare-fun (\|hint_validity#(\d+)\|) \(\|hint_validity_s\|\) (\(_ BitVec \d+\)|Bool)\)(.*)$', re.M)
fqb = None
def rep(m):
    global fqb
    name, n, sort, comment = m.group(1), m.group(2), m.group(3), m.group(4)
    if comment.strip() == '; \\f_q_B': fqb = f'|in#{n}|'
    return (f'(declare-const |in#{n}| {sort}){comment}\n'
            f'(define-fun {name} ((state |hint_validity_s|)) {sort} |in#{n}|)')
body, cnt = decl.subn(rep, src)
assert fqb is not None, "f_q_B input not found"
head = "(set-logic ALL)\n"   # the model uses an uninterpreted sort for the (single) state
tail_common = ("(declare-const s0 |hint_validity_s|)\n(assert (|hint_validity_i| s0))\n"
               "(assert (|hint_validity_h| s0))\n(assert (|hint_validity_u| s0))\n"
               "(assert (not (|hint_validity_a| s0)))\n")
cases = [('zero', f'(assert (= {fqb} (_ bv0 32)))')]
for k in range(32):
    c = f'(assert (bvuge {fqb} (_ bv{1<<k} 32)))'
    if k < 31: c += f'\n(assert (bvult {fqb} (_ bv{1<<(k+1)} 32)))'
    cases.append((f'k{k}', c))
for name, c in cases:
    open(os.path.join(d, f'h6_{name}.smt2'), 'w').write(head + body + tail_common + c + "\n(check-sat)\n")
print(f"{cnt} inputs flattened; f_q_B = {fqb}; wrote {len(cases)} case queries")
