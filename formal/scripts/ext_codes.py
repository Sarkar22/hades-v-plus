#!/usr/bin/env python3
"""ext_codes.py <repo_root> <formal_dir>

The EXT proof (harness/top_ext.v) names each of the 45 Zbb, Zbs, Zicond, Zbkb, Zbkx
and Zknh instructions by the decoder's payload in the immediate field. This check ties the
numbers written into the harness to the design's own definitions in
defines/op.sv, so that the proof cannot silently refer to the wrong encoding:
  1. op::EXT is entry 61 of the op::t enum (the harness tests insn[64:59] == 61),
     and op::t is 6 bits wide;
  2. op::ext_payload_t is {zero[19:0], sel (ext_t, 6 bits), use_imm, shamt[4:0]};
  3. every line of f_ext_payload has the sel value of the op::ext_t constant it
     names, use_imm = 1 exactly for rori, bclri, bexti, binvi and bseti, and every
     op::ext_t constant is used;
  4. the instruction numbering of f_ext_payload is that of props/ext_spec.vh.
Prints one line and exits 0 on success, 1 on any difference."""
import re, sys
root, fdir = sys.argv[1], sys.argv[2]
op = open(root + "/defines/op.sv").read()
# line comments first: a line comment may contain "/*" (e.g. "ref/*.so")
op = re.sub(r"/\*.*?\*/", "", re.sub(r"//[^\n]*", "", op), flags=re.S)
err = []
m = re.search(r"typedef\s+enum\s+logic\s*\[5:0\]\s*\{(.*?)\}\s*t\s*;", op, re.S)
ops = [x.strip().split("=")[0].strip() for x in m.group(1).split(",") if x.strip()] if m else []
if "EXT" not in ops or ops.index("EXT") != 61:
    err.append("op::EXT is not entry 61 of op::t (found %s)" % (ops.index("EXT") if "EXT" in ops else "none"))
m = re.search(r"typedef\s+enum\s+logic\s*\[5:0\]\s*\{(.*?)\}\s*ext_t\s*;", op, re.S)
codes = {}
for k, v in re.findall(r"(EXT_\w+)\s*=\s*6'b([01_]+)", m.group(1) if m else ""):
    codes[k] = v.replace("_", "")
if len(codes) != 40:
    err.append("expected 40 op::ext_t constants, found %d" % len(codes))
m = re.search(r"typedef\s+struct\s+packed\s*\{(.*?)\}\s*ext_payload_t\s*;", op, re.S)
fields = re.findall(r"(logic\s*\[\d+:\d+\]|logic|ext_t)\s+(\w+)\s*;", m.group(1) if m else "")
want = [("logic [19:0]", "zero"), ("ext_t", "sel"), ("logic", "use_imm"), ("logic [4:0]", "shamt")]
if [(re.sub(r"\s+", " ", t).replace("logic [", "logic ["), n) for t, n in fields] != want:
    err.append("op::ext_payload_t is not {zero[19:0], sel, use_imm, shamt[4:0]}: %s" % fields)
harness = open(fdir + "/harness/top_ext.v").read()
rows = re.findall(r"6'd(\d+):\s*f_ext_payload\s*=\s*\{6'b([01_]+),\s*1'b([01])\};\s*//\s*(\S+)\s+(EXT_\w+)", harness)
if len(rows) != 45:
    err.append("expected 45 rows in f_ext_payload, found %d" % len(rows))
spec = open(fdir + "/props/ext_spec.vh").read()
names = {}
for line in spec.splitlines():
    if line.startswith("//") and re.search(r"\b\d+ [a-z]", line) and "numbering" not in line:
        for i, n in re.findall(r"\b(\d+) ([a-z][a-z0-9.]*)", line):
            names[int(i)] = n
IMM = {"rori", "bclri", "bexti", "binvi", "bseti"}
used = set()
for i, sel, imm, name, const in rows:
    i = int(i); used.add(const)
    if names.get(i) != name:
        err.append("id %d is %s in top_ext.v but %s in ext_spec.vh" % (i, name, names.get(i)))
    if codes.get(const) != sel.replace("_", ""):
        err.append("%s: sel %s in top_ext.v, %s = %s in defines/op.sv" % (name, sel, const, codes.get(const)))
    if (imm == "1") != (name in IMM):
        err.append("%s: use_imm = %s" % (name, imm))
if len(names) != 45:
    err.append("expected 45 instructions in the ext_spec.vh numbering, found %d" % len(names))
if set(codes) - used:
    err.append("op::ext_t constants not used: %s" % sorted(set(codes) - used))
if err:
    print("ext payload map: %d difference(s)" % len(err)); [print("  " + e) for e in err]; sys.exit(1)
print("ext payload map: op::EXT = 61, ext_payload_t layout, 45 rows of f_ext_payload match "
      "the %d op::ext_t constants of defines/op.sv and the numbering of ext_spec.vh" % len(codes))
