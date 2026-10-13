#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""model.py -- build the formal models of formal/cache from the RTL of a source tree.

  model.py gen <src> <here> <out> [--mutant NAME --mutants FILE] MODEL...
      Copies the RTL of <src> (rtl/cache/icache.sv, dcache.sv, cache_ram.sv, mem_arbiter.sv,
      rtl/mcu.sv, lib/wishbone/wishbone_interface.sv, wishbone_interconnect.sv, defines/*.sv) to
      <out>/src, and <here>/mem_arbiter_base.sv (the base commit's arbiter) to
      <out>/src/formal/cache, applies the named mutant of the mutant table (an exact text that
      must occur exactly once, replaced), inserts one include line of an observer before the final
      endmodule of the copies of icache.sv, dcache.sv, mem_arbiter.sv and mem_arbiter_base.sv,
      converts every MODEL with sv2v (SYNTHESIS and HADES_FORMAL defined) to <out>/<MODEL>.v and
      inserts, before the final endmodule of the harness module and of module cache_ram, one
      include line each (the properties; the array observer). It checks that these lines are the
      only differences from the RTL and from the sv2v output.
      MODEL: cache_<cfg>[_narrow][_cpu], pair_<cfg>[_narrow], icache_<cfg>[_narrow],
      arbiter_<cfg>[_narrow][_cpu] (cfg tiny or second), ic_default, ic_ram_exempt, ic_io_timeout;
      with both caches: memsys_<cfg>[_nowait][_narrow][_free|_cpu], mpair_<cfg>[_narrow],
      dcache_<cfg>[_nowait][_narrow][_free], arbid_<cfg>[_nowait][_narrow], equiv.
  model.py mask <mcu.sv>
      Prints the TIMEOUT_EXEMPT mask of the interconnect in rtl/mcu.sv's cached branch (the
      `ifdef HADES_ICACHE_BYTES regions) as <width>'b<bits>; exits 1 if there is none, more than
      one, or one outside those regions.
  model.py base <repo> <commit> <copy> [<path> <module>]
      Checks <copy> against `git show <commit>:<path>` (default lib/wishbone/wishbone_interconnect.sv,
      module wishbone_interconnect) with only the module name changed to <module>_base. Prints
      SAME, DIFFERENT or UNAVAILABLE.
  model.py mutants <file>
      Lists the mutant table: name, properties, defined or not.
  model.py snoop <mcu.sv>
      Prints snoop.svh: the snoop connections of rtl/mcu.sv's cached branch as macros (gen writes
      it to <out>/snoop.svh, which the harnesses include).
"""
import hashlib, os, re, shutil, subprocess, sys

PACKAGES = ['op.sv', 'csr.sv', 'pipeline_status.sv', 'forwarding.sv', 'bpredict.sv', 'constants.sv',
            'instruction.sv', 'clk_params.sv']
CACHE_RTL = ['rtl/cache/icache.sv', 'rtl/cache/cache_ram.sv', 'rtl/cache/mem_arbiter.sv',
             'rtl/cache/dcache.sv']
OTHER = ['rtl/mcu.sv', 'lib/wishbone/wishbone_interface.sv', 'lib/wishbone/wishbone_interconnect.sv']
OBSERVERS = {'rtl/cache/icache.sv': ('icache', 'observe_icache.svh'),
             'rtl/cache/mem_arbiter.sv': ('mem_arbiter', 'observe_arbiter.svh'),
             'rtl/cache/dcache.sv': ('dcache', 'observe_dcache.svh')}
# the base commit's arbiter (a copy in formal/cache with its module renamed), for the equivalence
ARB_BASE = 'formal/cache/mem_arbiter_base.sv'


def die(msg):
    sys.exit('model.py: ' + msg)


# ---- the mutant table ------------------------------------------------------------------------
def unescape(text):
    return text.replace('\\n', '\n').replace('\\t', '\t')


def read_mutants(path):
    """name | properties | file | exact original text | replacement | description. Several rows
    with the same name are one mutant made of several changes (the first row's properties and
    description count); a mutant is defined when every one of its rows has an original text."""
    muts = {}
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        fields = [f.replace('\x00', '|').strip() for f in
                  line.rstrip('\n').replace('\\|', '\x00').split('|')]
        if len(fields) != 6:
            die(f'{path}: a row needs 6 fields separated by |: {line.strip()}')
        name, props, path_, old, new, desc = fields
        m = muts.setdefault(name, dict(name=name, props=props.split(), desc=desc, changes=[]))
        m['changes'].append(dict(file=path_, old=unescape(old), new=unescape(new)))
    for m in muts.values():
        m['defined'] = all(c['old'] for c in m['changes'])
    return list(muts.values())


# ---- sources ----------------------------------------------------------------------------------
def module_span(text, name):
    """(start, end) of module <name> ... endmodule in text, end = index of its endmodule line."""
    m = re.search(r'^[ \t]*module[ \t]+' + re.escape(name) + r'\b', text, re.M)
    if not m:
        return None
    e = re.compile(r'^[ \t]*endmodule\b', re.M).search(text, m.end())
    if not e:
        return None
    return m.start(), e.start()


def insert_before_endmodule(text, name, line):
    span = module_span(text, name)
    if span is None:
        die(f'module {name} or its endmodule not found')
    return text[:span[1]] + line + '\n' + text[span[1]:]


def check_one_line_added(before, after, line, what):
    b, a = before.split('\n'), after.split('\n')
    if len(a) != len(b) + 1:
        die(f'{what}: expected exactly one added line')
    for i in range(len(b) + 1):
        if a[:i] + a[i + 1:] == b:
            if a[i] != line:
                die(f'{what}: the added line is {a[i]!r}, not {line!r}')
            return
    die(f'{what}: the only difference must be the line {line!r}')


def copy_sources(src, here, out, mutant):
    dst = os.path.join(out, 'src')
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    files = [f for f in CACHE_RTL + OTHER] + ['defines/' + p for p in PACKAGES]
    have = []
    for f in files:
        s = os.path.join(src, f)
        if os.path.isfile(s):
            os.makedirs(os.path.dirname(os.path.join(dst, f)), exist_ok=True)
            shutil.copyfile(s, os.path.join(dst, f))
            have.append(f)
    if mutant:
        if not mutant['defined']:
            die(f"mutant {mutant['name']}: its text is not defined in the mutant table")
        for c in mutant['changes']:
            p = os.path.join(dst, c['file'])
            if not os.path.isfile(p):
                die(f"mutant {mutant['name']}: {c['file']} not found")
            t = open(p).read()
            n = t.count(c['old'])
            if n != 1:
                die(f"mutant {mutant['name']}: the original text occurs {n} times in "
                    f"{c['file']} (expected exactly 1)")
            open(p, 'w').write(t.replace(c['old'], c['new']))
    # the base commit's arbiter, never mutated
    base = os.path.join(here, 'mem_arbiter_base.sv')
    if os.path.isfile(base):
        os.makedirs(os.path.dirname(os.path.join(dst, ARB_BASE)), exist_ok=True)
        shutil.copyfile(base, os.path.join(dst, ARB_BASE))
    # the observers: one include line before the final endmodule of the copies
    for f, (mod, inc) in list(OBSERVERS.items()) + [(ARB_BASE, ('mem_arbiter_base', 'observe_arbiter.svh'))]:
        p = os.path.join(dst, f)
        if not os.path.isfile(p):
            continue
        before = open(p).read()
        line = f'`include "{inc}"'
        after = insert_before_endmodule(before, mod, line)
        check_one_line_added(before, after, line, f)
        open(p, 'w').write(after)
    with open(os.path.join(out, 'SHA256SUMS'), 'w') as h:
        for f in sorted(have):
            h.write(hashlib.sha256(open(os.path.join(src, f), 'rb').read()).hexdigest() +
                    '  ' + f + '\n')
    return have


# ---- the mask of rtl/mcu.sv's cached branch -----------------------------------------------------
def cached_regions(text):
    """Text spans selected by `ifdef HADES_ICACHE_BYTES (up to its `else/`elsif/`endif)."""
    spans, stack = [], []
    for m in re.finditer(r'`(ifdef|ifndef|elsif|else|endif)\b[ \t]*(\w*)', text):
        kind, arg = m.group(1), m.group(2)
        if kind in ('ifdef', 'ifndef'):
            stack.append([kind == 'ifdef' and arg == 'HADES_ICACHE_BYTES', m.end()])
        elif kind in ('elsif', 'else'):
            if stack and stack[-1][0]:
                spans.append((stack[-1][1], m.start()))
            if stack:
                stack[-1][0] = False
        elif kind == 'endif':
            if stack:
                top = stack.pop()
                if top[0]:
                    spans.append((top[1], m.start()))
    return spans


def parse_literal(lit):
    m = re.fullmatch(r"(\d+)'([bBhHdD])([0-9a-fA-F_]+)", lit.replace(' ', ''))
    if not m:
        return None
    width, base, digits = int(m.group(1)), m.group(2).lower(), m.group(3).replace('_', '')
    value = int(digits, {'b': 2, 'h': 16, 'd': 10}[base])
    if value >= (1 << width):
        return None
    return width, value


def read_mask(mcu):
    text = re.sub(r'//[^\n]*', '', open(mcu).read())
    found = [(m.start(), m.group(1).strip()) for m in
             re.finditer(r'\.TIMEOUT_EXEMPT\s*\(\s*([^()]*?)\s*\)', text)]
    regions = cached_regions(text)
    inside = [f for f in found if any(a <= f[0] < b for a, b in regions)]
    outside = [f for f in found if f not in inside]
    if outside:
        return None, 'a .TIMEOUT_EXEMPT(...) outside the HADES_ICACHE_BYTES branch'
    if len(inside) != 1:
        return None, f'{len(inside)} .TIMEOUT_EXEMPT(...) in the HADES_ICACHE_BYTES branch (expected 1)'
    lit = inside[0][1]
    parsed = parse_literal(lit)
    if parsed is None:
        return None, f'the mask {lit!r} is not a sized binary, hex or decimal number'
    width, value = parsed
    return (width, value, lit), None


# ---- the snoop as rtl/mcu.sv's cached branch connects it --------------------------------------
SNOOP_DEFAULT = {'snoop_store': 'bus.cyc && bus.stb && bus.we && bus.ack', 'snoop_adr': 'bus.adr'}


def balanced(text, i):
    """text[i] == '(': the text inside the matching parentheses."""
    depth = 0
    for j in range(i, len(text)):
        if text[j] == '(':
            depth += 1
        elif text[j] == ')':
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
    return None


def snoop_header(mcu):
    """`define F_SNOOP_STORE(bus) / F_SNOOP_ADR(bus): the expressions that rtl/mcu.sv connects to
    the snoop ports of instance icache in its HADES_ICACHE_BYTES branch, with mem_bus_slaves[0]
    replaced by the macro's argument (one level of an intermediate wire is followed). Without such
    a connection, the expressions of the cache design (cyc && stb && we && ack of slave 0; its
    address) are used, and the header says so."""
    lines, notes = [], []
    text = re.sub(r'//[^\n]*', '', open(mcu).read()) if os.path.isfile(mcu) else ''
    regions = cached_regions(text)
    region = ''.join(text[a:b] for a, b in regions)
    inst = re.search(r'\bicache\b\s*(?:#\s*\(.*?\)\s*)?\bicache\s*\(', region, re.S)
    for port, macro in (('snoop_store', 'F_SNOOP_STORE'), ('snoop_adr', 'F_SNOOP_ADR')):
        expr = None
        if inst:
            body = balanced(region, inst.end() - 1) or ''
            m = re.search(r'\.' + port + r'\s*\(', body)
            if m:
                expr = (balanced(body, m.end() - 1) or '').strip()
                w = re.fullmatch(r'\w+', expr)
                if w:
                    d = re.search(r'(?:assign\s+|(?:wire|logic)\s+(?:\[[^\]]*\]\s*)?)' + expr +
                                  r'\s*=\s*([^;]*);', region)
                    if d:
                        expr = d.group(1).strip()
        if expr and 'mem_bus_slaves[0]' in expr and re.fullmatch(r'[\w\s\[\]\.&|!~=()\'0-9]+', expr):
            expr = '(' + ' '.join(expr.replace('mem_bus_slaves[0]', 'bus').split()) + ')'
            notes.append(f'{port}: from rtl/mcu.sv')
        else:
            expr = '(' + SNOOP_DEFAULT[port] + ')'
            notes.append(f'{port}: rtl/mcu.sv has no usable connection, the default is used')
        lines.append(f'`define {macro}(bus) {expr}')
    return ('// generated by formal/cache/scripts/model.py: ' + '; '.join(notes) + '\n' +
            '\n'.join(lines) + '\n')


# ---- sv2v and the include lines ---------------------------------------------------------------
def array_name(text):
    span = module_span(text, 'cache_ram')
    if span is None:
        die('module cache_ram not found in the sv2v output')
    body = text[span[0]:span[1]]
    names = re.findall(r'^\s*reg\s*(?:signed\s*)?(?:\[[^\]]*\])?\s*(\w+)\s*\[[^\]]*\]\s*;', body, re.M)
    if len(names) != 1:
        die('cache_ram must keep its words in exactly one memory array (an unpacked array such as '
            f'logic [WIDTH-1:0] words [DEPTH]); found {len(names)}: {names}')
    return names[0]


def sv2v(cmd, outfile):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        die('sv2v failed: ' + ' '.join(cmd) + '\n' + r.stderr)
    open(outfile, 'w').write(r.stdout)
    return r.stdout


def gen_model(name, here, out, have):
    srcdir = os.path.join(out, 'src')
    parts = name.split('_')
    defs = ['-DSYNTHESIS', '-DHADES_FORMAL']
    incs = ['-I' + out, '-I' + os.path.join(here, 'harness'), '-I' + os.path.join(here, 'props'),
            '-I' + os.path.join(srcdir, 'defines')]
    pkgs = [os.path.join(srcdir, 'defines', p) for p in PACKAGES if 'defines/' + p in have]
    iface = os.path.join(srcdir, 'lib/wishbone/wishbone_interface.sv')
    if parts[0] == 'ic':
        mode = '_'.join(parts[1:])
        if mode not in ('default', 'ram_exempt', 'io_timeout'):
            die(f'unknown model {name}')
        defs.append('-DIC_' + mode.upper())
        if mode != 'default':
            mask, err = read_mask(os.path.join(srcdir, 'rtl/mcu.sv'))
            if mask is None:
                die('rtl/mcu.sv: ' + err)
            width, value, lit = mask
            defs.append(f"-DIC_MASK={width}'b{value:0{width}b}")
        files = pkgs + [iface, os.path.join(srcdir, 'lib/wishbone/wishbone_interconnect.sv'),
                        os.path.join(here, 'wishbone_interconnect_base.sv'),
                        os.path.join(here, 'harness/interconnect_top.sv')]
        top, props = 'interconnect_top', 'interconnect_props.vh'
    elif parts[0] == 'equiv':
        # the arbiter of the tree against the base commit's (both with their observers)
        if len(parts) != 1:
            die(f'unknown model {name}')
        if 'rtl/cache/mem_arbiter.sv' not in have:
            die('rtl/cache/mem_arbiter.sv not found in the source tree')
        if not os.path.isfile(os.path.join(srcdir, ARB_BASE)):
            die('mem_arbiter_base.sv not found in ' + here)
        files = pkgs + [iface, os.path.join(srcdir, 'rtl/cache/mem_arbiter.sv'),
                        os.path.join(srcdir, ARB_BASE),
                        os.path.join(here, 'harness/arbiter_equiv_top.sv')]
        top, props = 'arbiter_equiv_top', 'equiv_props.vh'
    else:
        # harness, its modules (in this order on the sv2v command line) and its properties
        table = {
            'cache':   ('cache_top', ['cache_ram', 'icache', 'mem_arbiter'], 'cache_props.vh'),
            'pair':    ('cache_pair_top', ['cache_ram', 'icache', 'mem_arbiter'], 'pair_props.vh'),
            'icache':  ('icache_top', ['cache_ram', 'icache'], 'cache_props.vh'),
            'arbiter': ('arbiter_top', ['cache_ram', 'mem_arbiter'], 'cache_props.vh'),
            'memsys':  ('memsys_top', ['cache_ram', 'icache', 'dcache', 'mem_arbiter'], 'dcache_props.vh'),
            'mpair':   ('memsys_pair_top', ['cache_ram', 'icache', 'dcache', 'mem_arbiter'], 'dpair_props.vh'),
            'dcache':  ('dcache_top', ['cache_ram', 'dcache'], 'dcache_props.vh'),
            'arbid':   ('arbiter_id_top', ['cache_ram', 'mem_arbiter'], 'dcache_props.vh'),
        }
        if parts[0] not in table or len(parts) < 2 or parts[1] not in ('tiny', 'second'):
            die(f'unknown model {name}')
        harness, mods, props = table[parts[0]]
        flags = parts[2:]
        allowed = ('narrow', 'cpu') if parts[0] in ('cache', 'pair', 'icache', 'arbiter') else \
                  ('narrow', 'cpu', 'nowait', 'free')
        if any(f not in allowed for f in flags) or ('cpu' in flags and 'free' in flags):
            die(f'unknown model {name}')
        if parts[1] == 'second':
            defs.append('-DFCACHE_SECOND')
        if 'narrow' in flags:
            defs.append('-DFCACHE_NARROW')
        if 'cpu' in flags:
            defs.append('-DFCACHE_CPU_DATA')
        if 'nowait' in flags:
            defs.append('-DFCACHE_WRITE_NOWAIT')
        if 'free' in flags:
            defs.append('-DFCACHE_FREE_DATA')
        need = ['rtl/cache/' + m + '.sv' for m in mods]
        for f in need:
            if f not in have:
                die(f'{f} not found in the source tree')
        files = pkgs + [iface] + [os.path.join(srcdir, f) for f in need] + \
                [os.path.join(here, 'harness', harness + '.sv')]
        top = harness
    raw = sv2v(['sv2v'] + defs + incs + files, os.path.join(out, name + '_sv2v.v'))
    text = raw
    if module_span(text, 'cache_ram') is not None:
        arr = array_name(text)
        tmpl = open(os.path.join(here, 'props/observe_ram.vh.in')).read()
        open(os.path.join(out, 'observe_ram.vh'), 'w').write(tmpl.replace('@ARRAY@', arr))
        line = '`include "observe_ram.vh"'
        new = insert_before_endmodule(text, 'cache_ram', line)
        check_one_line_added(text, new, line, name + ' (cache_ram)')
        text = new
    line = f'`include "{props}"'
    new = insert_before_endmodule(text, top, line)
    check_one_line_added(text, new, line, name + f' ({top})')
    text = new
    open(os.path.join(out, name + '.v'), 'w').write(text)
    print(f'{name}: {top}, ' + ' '.join(d for d in defs if d not in ('-DSYNTHESIS', '-DHADES_FORMAL')))


def main(argv):
    if len(argv) < 2:
        die(__doc__)
    cmd = argv[1]
    if cmd == 'gen':
        args = argv[2:]
        mutant_name = mutants_file = None
        if '--mutant' in args:
            i = args.index('--mutant')
            mutant_name = args[i + 1]
            del args[i:i + 2]
        if '--mutants' in args:
            i = args.index('--mutants')
            mutants_file = args[i + 1]
            del args[i:i + 2]
        src, here, out, models = args[0], args[1], args[2], args[3:]
        mutant = None
        if mutant_name:
            rows = [r for r in read_mutants(mutants_file) if r['name'] == mutant_name]
            if len(rows) != 1:
                die(f'mutant {mutant_name} not in {mutants_file}')
            mutant = rows[0]
        os.makedirs(out, exist_ok=True)
        have = copy_sources(src, here, out, mutant)
        header = snoop_header(os.path.join(out, 'src', 'rtl/mcu.sv'))
        open(os.path.join(out, 'snoop.svh'), 'w').write(header)
        print(header.split('\n')[0].replace('// generated by formal/cache/scripts/model.py: ', 'snoop: '))
        for m in models:
            gen_model(m, here, out, have)
    elif cmd == 'mask':
        mask, err = read_mask(argv[2])
        if mask is None:
            print('NO MASK: ' + err)
            return 1
        width, value, lit = mask
        print(f"{width}'b{value:0{width}b} (written {lit})")
    elif cmd == 'base':
        repo, commit, copy = argv[2], argv[3], argv[4]
        path, module = (argv[5], argv[6]) if len(argv) > 6 else \
            ('lib/wishbone/wishbone_interconnect.sv', 'wishbone_interconnect')
        r = subprocess.run(['git', '-C', repo, 'show', commit + ':' + path],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        if r.returncode != 0:
            print('UNAVAILABLE')
            return 0
        expect = re.sub(r'^module ' + re.escape(module) + r'\b', 'module ' + module + '_base',
                        r.stdout, count=1, flags=re.M)
        print('SAME' if expect == open(copy).read() else 'DIFFERENT')
    elif cmd == 'mutants':
        for r in read_mutants(argv[2]):
            print(f"{r['name']} {','.join(r['props'])} {'defined' if r['defined'] else 'NOT-DEFINED'}")
    elif cmd == 'snoop':
        print(snoop_header(argv[2]), end='')
    else:
        die(__doc__)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
