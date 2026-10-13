#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""model.py -- build the formal models of formal/hpm from the RTL of a source tree.

  model.py gen <src> <here> <out> [--mutant NAME --mutants FILE] MODEL...
      Copies the sources a model needs from <src> to <out>/src/<MODEL>, applies the named mutant of the mutant table (an exact text
      that must occur exactly once, replaced), converts the model with sv2v (SYNTHESIS and
      HADES_FORMAL defined) and inserts the include line of its properties before the final
      endmodule of its top module. Writes <out>/<MODEL>.v. MODEL:
        unit_n<N>w<W>  the counter unit (rtl/hpm_events.sv and rtl/hpm.sv, harness/unit_top.sv)
                       built with HADES_HPM_COUNTERS=N and HADES_HPM_WIDTH=W; the observer
                       props/observe_hpm.svh is inserted before the final endmodule of the copy
                       of rtl/hpm.sv;
        decoder        rtl/instruction_decoder.sv against base/instruction_decoder_base.sv
                       (harness/decoder_top.sv), with the ISS's legal CSR set
                       (test/trapsweep/iss.py, CSR_VALID) written to iss_csr_legal.svh;
        writeback      rtl/writeback_stage.sv (with rtl/hpm.sv and rtl/hpm_events.sv when they
                       exist) against base/writeback_stage_base.sv; the top module writeback_top
                       is written from the two port lists, which Yosys reads from the sv2v output.
      The package files are the defines/*.sv lines of <src>/sim/files.txt, in that order.
  model.py base <repo> <commit> <copy> <path> <module>
      Checks <copy> against `git show <commit>:<path>` with only the module name <module>
      changed to <module>_base. Prints SAME, DIFFERENT or UNAVAILABLE.
  model.py mutants <file>
      Lists the mutant table: name, properties, defined (exact texts given) or campaign.
  model.py legal <iss.py>
      Prints the ISS's legal CSR set, one address per line.
"""
import ast, json, os, re, shutil, subprocess, sys

DEFAULT_PACKAGES = ['csr.sv', 'op.sv', 'instruction.sv', 'pipeline_status.sv', 'constants.sv',
                    'forwarding.sv', 'clk_params.sv', 'bpredict.sv', 'hpm.sv']
WB_STATE = {'mstatus_mpie': 1, 'mstatus_mie': 1, 'mtvec': 32, 'mie_meie': 1, 'mie_mtie': 1,
            'mip_meip_reg': 1, 'mip_mtip_reg': 1, 'mepc': 32, 'mcause': 32, 'mscratch': 32,
            'mcycle': 64, 'minstret': 64, 'bp_control': 32, 'int_jump_reg': 1,
            'imm_jump_reg': 1, 'int_next_pc_reg': 32}
WB_FIELDS = ['csr:12', 'rs1:5', 'is_csr_op', 'is_set_clear', 'is_valid', 'is_ecall', 'is_load',
             'is_store', 'is_branch', 'is_jump', 'is_mul', 'is_div', 'is_bitmanip', 'is_crypto',
             'is_mret', 'is_fence_i', 'bp_valid', 'bp_predicted_taken', 'bp_was_taken']


def die(msg):
    sys.exit('model.py: ' + msg)


def run(cmd, out=None, cwd=None):
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    if r.returncode != 0:
        die(f'{cmd[0]} failed ({r.returncode}): {r.stderr.strip()[-2000:]}')
    if out:
        with open(out, 'w') as f:
            f.write(r.stdout)
    return r.stdout


# ---- the mutant table ------------------------------------------------------------------------
def unescape(text):
    return text.replace('\\n', '\n').replace('\\t', '\t')


def read_mutants(path):
    """name | properties | file | exact original text | replacement | description. Several rows
    with one name are one mutant; a mutant is defined when every row gives an original text."""
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
def packages(src):
    fl = os.path.join(src, 'sim', 'files.txt')
    pk = []
    if os.path.isfile(fl):
        for line in open(fl):
            t = line.strip()
            if re.fullmatch(r'defines/[A-Za-z0-9_]+\.sv', t):
                pk.append(t)
    if not pk:
        pk = ['defines/' + p for p in DEFAULT_PACKAGES]
    return [p for p in pk if os.path.isfile(os.path.join(src, p))]


def module_span(text, name):
    m = re.search(r'^[ \t]*module[ \t]+' + re.escape(name) + r'\b', text, re.M)
    if not m:
        return None
    e = re.compile(r'^[ \t]*endmodule\b', re.M).search(text, m.end())
    return (m.start(), e.start()) if e else None


def insert_before_endmodule(text, name, line):
    span = module_span(text, name)
    if span is None:
        die(f'module {name} or its endmodule not found')
    return text[:span[1]] + line + '\n' + text[span[1]:]


def copy_sources(src, dst, files, mutant):
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    os.makedirs(dst)
    for f in files:
        s = os.path.join(src, f)
        if not os.path.isfile(s):
            die(f'{f} not found in {src}')
        os.makedirs(os.path.dirname(os.path.join(dst, f)), exist_ok=True)
        shutil.copyfile(s, os.path.join(dst, f))
    if mutant:
        for c in mutant['changes']:
            p = os.path.join(dst, c['file'])
            if not os.path.isfile(p):
                continue           # this model does not read the mutated file
            text = open(p).read()
            n = text.count(c['old'])
            if n != 1:
                die(f'mutant {mutant["name"]}: the text must occur exactly once in {c["file"]} '
                    f'(found {n} times)')
            open(p, 'w').write(text.replace(c['old'], c['new']))


def sv2v(here, dst, files, defines, out, incdirs=()):
    cmd = ['sv2v', '-DSYNTHESIS', '-DHADES_FORMAL'] + ['-D' + d for d in defines]
    for i in [os.path.join(here, 'harness'), os.path.join(here, 'props')] + list(incdirs):
        cmd += ['-I', i]
    cmd += files
    run(cmd, out=out, cwd=dst)


def mutant_files(mutant):
    return {c['file'] for c in mutant['changes']} if mutant else set()


# ---- the ISS's legal CSR set -------------------------------------------------------------------
def iss_legal(iss_path):
    """CSR_VALID of test/trapsweep/iss.py, read from the source without running it: the
    assignment's expression may use only set(), list(), range(), literals and +."""
    tree = ast.parse(open(iss_path).read())
    expr = None
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'CSR_VALID'
                                                for t in node.targets):
            expr = node.value
    if expr is None:
        die(f'{iss_path}: no CSR_VALID assignment')
    for node in ast.walk(expr):
        if isinstance(node, ast.Call):
            if not (isinstance(node.func, ast.Name) and node.func.id in ('set', 'list', 'range')):
                die(f'{iss_path}: CSR_VALID uses a call other than set, list or range')
        elif not isinstance(node, (ast.Constant, ast.List, ast.Tuple, ast.BinOp, ast.Add, ast.Load,
                                   ast.Name, ast.expr_context)):
            die(f'{iss_path}: CSR_VALID uses an unsupported expression ({type(node).__name__})')
    val = eval(compile(ast.Expression(expr), iss_path, 'eval'),
               {'__builtins__': {}}, {'set': set, 'list': list, 'range': range})
    return sorted(int(v) for v in val)


def write_legal_svh(addrs, path):
    lines = ['// written by formal/hpm/scripts/model.py from test/trapsweep/iss.py (CSR_VALID)',
             'function automatic logic f_iss_csr_legal(input logic [11:0] a);',
             '    case (a)']
    for i in range(0, len(addrs), 8):
        lines.append('        ' + ', '.join(f"12'h{a:03X}" for a in addrs[i:i + 8]) +
                     (':' if i + 8 >= len(addrs) else ','))
    lines[-1] += ' f_iss_csr_legal = 1\'b1;'
    lines += ['        default: f_iss_csr_legal = 1\'b0;', '    endcase', 'endfunction']
    open(path, 'w').write('\n'.join(lines) + '\n')


# ---- the models ---------------------------------------------------------------------------------
def gen_unit(src, here, out, name, mutant):
    m = re.fullmatch(r'unit_n(\d)w(\d+)', name)
    if not m:
        die(f'unknown model {name}')
    n, w = int(m.group(1)), int(m.group(2))
    dst = os.path.join(out, 'src', name)
    pk = packages(src)
    rtl = ['rtl/hpm.sv', 'rtl/hpm_events.sv']
    copy_sources(src, dst, pk + rtl, mutant)
    p = os.path.join(dst, 'rtl/hpm.sv')
    text = open(p).read()
    open(p, 'w').write(insert_before_endmodule(text, 'hpm', '`include "observe_hpm.svh"'))
    raw = os.path.join(out, name + '_sv2v.v')
    sv2v(here, dst, pk + rtl + [os.path.join(here, 'harness/unit_top.sv')],
         [f'HADES_HPM_COUNTERS={n}', f'HADES_HPM_WIDTH={w}'], raw)
    text = open(raw).read()
    span = module_span(text, 'unit_top')
    top = text[span[0]:span[1]]
    for par, local, want in (('COUNTERS', 'F_N', n), ('WIDTH', 'F_W', w)):
        got = re.search(r'localparam\s+(?:signed\s+)?(?:\[[^]]*\]\s*)?' + local +
                        r'\s*=\s*([^;]+);', top)
        val = got.group(1).strip() if got else None
        if val is not None and not re.fullmatch(r'\d+', val):
            g2 = re.search(r'localparam\s+(?:signed\s+)?(?:\[[^]]*\]\s*)?' + re.escape(val) +
                           r'\s*=\s*(\d+)\s*;', top)
            val = g2.group(1) if g2 else None
        if val is None or int(val) != want:
            die(f'{name}: hpm_pkg::{par} is {val}, not {want}: the package must take '
                f'`HADES_HPM_{par} (the configuration cannot be built)')
    text = insert_before_endmodule(text, 'unit_top', '`include "unit_props.vh"')
    open(os.path.join(out, name + '.v'), 'w').write(text)


def gen_decoder(src, here, out, mutant):
    dst = os.path.join(out, 'src', 'decoder')
    pk = packages(src)
    copy_sources(src, dst, pk + ['rtl/instruction_decoder.sv', 'test/trapsweep/iss.py'], mutant)
    write_legal_svh(iss_legal(os.path.join(dst, 'test/trapsweep/iss.py')),
                    os.path.join(dst, 'iss_csr_legal.svh'))
    raw = os.path.join(out, 'decoder_sv2v.v')
    sv2v(here, dst, pk + ['rtl/instruction_decoder.sv',
                          os.path.join(here, 'base/instruction_decoder_base.sv'),
                          os.path.join(here, 'harness/decoder_top.sv')], [], raw, incdirs=[dst])
    text = insert_before_endmodule(open(raw).read(), 'decoder_top', '`include "decoder_props.vh"')
    open(os.path.join(out, 'decoder.v'), 'w').write(text)


def yosys_json(vfile, out_json):
    run(['yosys', '-q', '-p', f'read_verilog -sv {vfile}; proc; write_json {out_json}'])
    return json.load(open(out_json))


def port_list(mod):
    ports = []
    for pname, p in mod['ports'].items():
        ports.append((pname, p['direction'], len(p['bits'])))
    return ports


def declared_range(text, module, port):
    span = module_span(text, module)
    if span is None:
        return None
    m = re.search(r'^\s*input\s+wire\s+(?:\[(\d+):(\d+)\]\s+)?' + re.escape(port) + r'\s*;',
                  text[span[0]:span[1]], re.M)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2))) if m.group(1) else (0, 0)


def gen_writeback(src, here, out, mutant):
    dst = os.path.join(out, 'src', 'writeback')
    pk = packages(src)
    rtl = ['rtl/writeback_stage.sv'] + [f for f in ('rtl/hpm.sv', 'rtl/hpm_events.sv')
                                        if os.path.isfile(os.path.join(src, f))]
    copy_sources(src, dst, pk + rtl, mutant)
    raw = os.path.join(out, 'writeback_sv2v.v')
    sv2v(here, dst, pk + rtl + [os.path.join(here, 'base/writeback_stage_base.sv'),
                                os.path.join(here, 'harness/wb_fields.sv')], [], raw)
    text = open(raw).read()
    js = yosys_json(raw, os.path.join(out, 'writeback_ports.json'))
    mods = js['modules']
    for mname in ('writeback_stage', 'writeback_stage_base'):
        if mname not in mods:
            die(f'module {mname} not found in the sv2v output')
    new, base = mods['writeback_stage'], mods['writeback_stage_base']
    bports, nports = port_list(base), {p[0]: p for p in port_list(new)}
    report = []
    # internal names the properties read
    nets_new = new.get('netnames', {})
    for sname, width in WB_STATE.items():
        got = nets_new.get(sname)
        if got is None:
            die(f'writeback_stage has no signal {sname}: the miter compares it by that name')
        if len(got['bits']) != width:
            die(f'writeback_stage: {sname} has {len(got["bits"])} bits, the base stage {width}')
    has_hpm = 'i_hpm' in new.get('cells', {})
    ev_rng = trap_rng = None
    if has_hpm:
        hmod = new['cells']['i_hpm']['type']
        hname = 'hpm' if hmod not in mods else hmod
        ev_rng = declared_range(text, 'hpm', 'ev_a')
        trap_rng = declared_range(text, 'hpm', 'trap_raw')
        if ev_rng is None or trap_rng is None:
            die('the counter unit (module hpm) has no input ev_a or trap_raw')
        if not (ev_rng[0] >= 20 and ev_rng[1] <= 2 and ev_rng[0] <= 31):
            die(f'hpm.ev_a is [{ev_rng[0]}:{ev_rng[1]}]: the class-A codes 2-20 must be bits 2-20')
        if trap_rng not in ((5, 0), (26, 21)):
            die(f'hpm.trap_raw is [{trap_rng[0]}:{trap_rng[1]}], not [5:0] or [26:21]')
        report.append(f'writeback_stage instantiates the counter unit as i_hpm ({hname}); '
                      f'ev_a [{ev_rng[0]}:{ev_rng[1]}], trap_raw [{trap_rng[0]}:{trap_rng[1]}]')
    else:
        report.append('writeback_stage has no instance i_hpm: the miter without the counter unit '
                      '(no inhibit invariant, no event check)')
    # the top module
    decl, conn_b, conn_n = [], [], []
    shared = []
    for pname, d, w in bports:
        rng = f'[{w - 1}:0] ' if w > 1 else ''
        if pname in ('clk', 'rst'):
            conn_b.append(f'.{pname}({pname})')
            if pname in nports:
                conn_n.append(f'.{pname}({pname})')
            continue
        if d == 'input':
            decl.append(f'    input wire {rng}in_{pname};')
            shared.append(f'in_{pname}')
            conn_b.append(f'.{pname}(in_{pname})')
            if pname in nports:
                if nports[pname][2] != w or nports[pname][1] != 'input':
                    die(f'port {pname}: {nports[pname]} in the new stage, input of {w} bits in the base')
                conn_n.append(f'.{pname}(in_{pname})')
            else:
                report.append(f'the base input {pname} is not an input of the new stage')
        else:
            if pname not in nports or nports[pname][1] != 'output' or nports[pname][2] != w:
                die(f'output {pname} ({w} bits) of the base stage is missing or different in the new one')
            decl.append(f'    wire {rng}b_{pname};')
            decl.append(f'    wire {rng}n_{pname};')
            conn_b.append(f'.{pname}(b_{pname})')
            conn_n.append(f'.{pname}(n_{pname})')
    bnames = {p[0] for p in bports}
    extra = []
    for pname, (pn, d, w) in nports.items():
        if pname in bnames:
            continue
        rng = f'[{w - 1}:0] ' if w > 1 else ''
        if d == 'input':
            decl.append(f'    input wire {rng}x_{pname};')
            extra.append(f'x_{pname}')
            conn_n.append(f'.{pname}(x_{pname})')
            report.append(f'new input {pname} ({w} bits): free')
        else:
            report.append(f'new output {pname} ({w} bits): not compared')
    for fld in WB_FIELDS:
        nm, _, w = fld.partition(':')
        decl.append(f'    wire {"[" + str(int(w) - 1) + ":0] " if w else ""}f_{nm};')
    fconn = ', '.join(f'.{f.partition(":")[0]}(f_{f.partition(":")[0]})' for f in WB_FIELDS)
    top = ['', '// ---- written by formal/hpm/scripts/model.py: the Writeback miter ----',
           'module writeback_top (clk, in_rst' + ''.join(', ' + s for s in shared + extra) + ');',
           '    input wire clk;', '    input wire in_rst;'] + decl + [
           '    reg f_first = 1\'b1;', '    always @(posedge clk) f_first <= 1\'b0;',
           '    wire rst = in_rst || f_first;',
           '    writeback_stage_base wb_base (' + ', '.join(conn_b) + ');',
           '    writeback_stage wb_new (' + ', '.join(conn_n) + ');',
           f'    wb_fields f (.instruction_in(in_instruction_in), .status_in(in_status_forwards_in), '
           f'.bp_in(in_bp_feedback_in), {fconn});']
    if has_hpm:
        top += ['`define F_HAS_HPM', f'`define F_EV_A_HI {ev_rng[0]}', f'`define F_EV_A_LO {ev_rng[1]}',
                f'`define F_TRAP_HI {trap_rng[0]}', f'`define F_TRAP_LO {trap_rng[1]}']
    top += ['`include "writeback_props.vh"', 'endmodule', '']
    open(os.path.join(out, 'writeback.v'), 'w').write(text + '\n'.join(top))
    for r in report:
        print('    ' + r)


def cmd_gen(argv):
    if len(argv) < 4:
        die('gen <src> <here> <out> [--mutant NAME --mutants FILE] MODEL...')
    src, here, out = (os.path.abspath(a) for a in argv[:3])
    rest = argv[3:]
    mutant = None
    if rest[:1] == ['--mutant']:
        name, table = rest[1], rest[3]
        rest = rest[4:]
        found = [m for m in read_mutants(table) if m['name'] == name]
        if not found:
            die(f'mutant {name} is not in {table}')
        mutant = found[0]
        if not mutant['defined']:
            die(f'mutant {name} has no text in {table}')
    os.makedirs(out, exist_ok=True)
    for model in rest:
        if model.startswith('unit_'):
            gen_unit(src, here, out, model, mutant)
        elif model == 'decoder':
            gen_decoder(src, here, out, mutant)
        elif model == 'writeback':
            gen_writeback(src, here, out, mutant)
        else:
            die(f'unknown model {model}')
        print(f'    {model}.v')


def cmd_base(argv):
    repo, commit, copy, path, module = argv
    r = subprocess.run(['git', '-C', repo, 'show', f'{commit}:{path}'], stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True)
    if r.returncode != 0:
        print('UNAVAILABLE')
        return
    want = re.sub(r'^(\s*module\s+)' + re.escape(module) + r'\b', r'\g<1>' + module + '_base',
                  r.stdout, count=1, flags=re.M)
    print('SAME' if open(copy).read() == want else 'DIFFERENT')


def main():
    if len(sys.argv) < 2:
        die(__doc__)
    c, argv = sys.argv[1], sys.argv[2:]
    if c == 'gen':
        cmd_gen(argv)
    elif c == 'base':
        cmd_base(argv)
    elif c == 'mutants':
        for m in read_mutants(argv[0]):
            print(m['name'], ','.join(m['props']), 'defined' if m['defined'] else 'campaign')
    elif c == 'legal':
        for a in iss_legal(argv[0]):
            print(f'0x{a:03X}')
    else:
        die(f'unknown command {c}')


if __name__ == '__main__':
    main()
