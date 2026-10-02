// SPDX-License-Identifier: MIT
// ---------------------------------------------------------------------------------------------
// test/ext/harness.cpp -- runs the vectors of the Zbb, Zbs and Zicond check through the RTL
// (test/ext/harness.sv: instruction_decoder -> execute_stage) and prints one digest line per
// part, in the format the reference model prints, so that the two outputs can be compared
// line by line.
//
//   harness [--quick] [--form <mnemonic>]... [--dump <mnemonic> <part> <first> <count>]
//
//   --quick   of the unary forms' 256 chunks, run only c000, c127, c128 and c255
//   --form    run only the named forms (repeatable); default: all 28, in the order of the
//             ISA tables
//   --dump    instead of digests, print the vectors <first> .. <first>+<count>-1 of one part
//             as hex triples "a b rd": a = rs1 value, b = rs2 value (for the part 'shamt', b is
//             the shift amount; for a unary chunk, b is the rs2 value driven, 0xa5a5a5a5)
//
// Output: "<mnemonic> <part> <vectors> <digest>" per part (digest: 16 lowercase hex digits),
// then "violations=<n>". A violation is a vector whose result Execute does not forward as
// valid, for rd = x10, in the same cycle, without stalling. The exit status is 0 only when
// there are none.
//
// The vector set (the same in the reference model):
//   corner set C: 144 values (0, -1, 1<<k, ~(1<<k), (1<<k)-1, -1<<k, byte/half patterns)
//   PRNG: splitmix64, one stream per form, seeded 0x0123456789ABCDEF + the form's index
//   digest: FNV-1a over 32-bit values (offset 0xCBF29CE484222325, prime 0x100000001B3)
//   parts:  corner  (register forms) a over C, b over C; digest a, b, rd
//           random  (register forms) 1,048,576 x z: a = z mod 2^32, b = z >> 32; digest a, b, rd
//           amount  (rol ror bclr bext binv bset) a over C, s = 0..31: b = s | ((z mod 2^27) << 5)
//           zero    (czero.eqz, czero.nez) 4,096 x a = z mod 2^32, b = 0
//           shamt   (immediate forms) s = 0..31: a over C (rs2 0xA5A5A5A5), then 4,096 x z:
//                   a = z mod 2^32, rs2 = z >> 32; digest s, a, rd
//           c000 .. c255 (unary forms) x = N * 2^24 .. N * 2^24 + 2^24 - 1, rs2 0xA5A5A5A5;
//                   digest rd
//
// Build (from the repository root; the order of the packages matters):
//   verilator --cc --exe --build -O3 --x-assign fast --x-initial fast -Wno-fatal \
//     -CFLAGS -O2 -Mdir <dir> --top-module harness \
//     defines/csr.sv defines/op.sv defines/instruction.sv defines/pipeline_status.sv \
//     defines/constants.sv defines/forwarding.sv defines/clk_params.sv defines/bpredict.sv \
//     rtl/instruction_decoder.sv rtl/execute_stage.sv test/ext/harness.sv test/ext/harness.cpp
// ---------------------------------------------------------------------------------------------
#include "Vharness.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

enum Kind { REG, IMM, UNARY };

struct Form {
    const char* name;
    uint32_t    match;
    Kind        kind;
};

// The 28 forms in the order of the ISA tables (rd, rs1, rs2/shamt fields zero in MATCH).
const Form FORMS[28] = {
    {"andn", 0x40007033, REG},  {"orn", 0x40006033, REG},     {"xnor", 0x40004033, REG},
    {"clz", 0x60001013, UNARY}, {"ctz", 0x60101013, UNARY},   {"cpop", 0x60201013, UNARY},
    {"max", 0x0A006033, REG},   {"maxu", 0x0A007033, REG},    {"min", 0x0A004033, REG},
    {"minu", 0x0A005033, REG},  {"sext.b", 0x60401013, UNARY}, {"sext.h", 0x60501013, UNARY},
    {"zext.h", 0x08004033, UNARY}, {"rol", 0x60001033, REG},  {"ror", 0x60005033, REG},
    {"rori", 0x60005013, IMM},  {"orc.b", 0x28705013, UNARY}, {"rev8", 0x69805013, UNARY},
    {"bclr", 0x48001033, REG},  {"bclri", 0x48001013, IMM},   {"bext", 0x48005033, REG},
    {"bexti", 0x48005013, IMM}, {"binv", 0x68001033, REG},    {"binvi", 0x68001013, IMM},
    {"bset", 0x28001033, REG},  {"bseti", 0x28001013, IMM},
    {"czero.eqz", 0x0E005033, REG}, {"czero.nez", 0x0E007033, REG},
};

const uint32_t RS2_IDLE = 0xA5A5A5A5u;  // rs2 value for forms that do not read rs2

bool has_amount(const std::string& n) {
    return n == "rol" || n == "ror" || n == "bclr" || n == "bext" || n == "binv" || n == "bset";
}
bool is_czero(const std::string& n) { return n == "czero.eqz" || n == "czero.nez"; }

std::vector<uint32_t> corner_set() {
    std::vector<uint32_t> c = {0u, 0xFFFFFFFFu};
    for (int k = 0; k < 32; k++) {
        c.push_back(1u << k);
        c.push_back(~(1u << k));
    }
    for (int k = 1; k <= 32; k++) c.push_back(uint32_t((uint64_t(1) << k) - 1));
    for (int k = 1; k < 32; k++) c.push_back(0xFFFFFFFFu << k);
    const uint32_t extra[] = {0x55555555, 0xAAAAAAAA, 0x33333333, 0xCCCCCCCC, 0x0F0F0F0F, 0xF0F0F0F0,
                              0x00FF00FF, 0xFF00FF00, 0x01010101, 0x80808080, 0x7F7F7F7F, 0xFEFEFEFE,
                              0x00010001, 0x80000001, 0x7FFFFFFE, 0x12345678, 0x87654321, 0xDEADBEEF,
                              0x0000FF00, 0x00FF0000, 0xFFFFFF80, 0xFFFF8000, 0x000000FF};
    for (uint32_t v : extra) c.push_back(v);
    std::sort(c.begin(), c.end());
    c.erase(std::unique(c.begin(), c.end()), c.end());
    return c;
}

struct SplitMix {
    uint64_t state;
    uint64_t next() {
        state += 0x9E3779B97F4A7C15ull;
        uint64_t z = state;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
};

struct Digest {
    uint64_t h = 0xCBF29CE484222325ull;
    void add(uint32_t v) { h = (h ^ v) * 0x100000001B3ull; }
};

struct Run {
    Vharness*   top;
    uint64_t    violations = 0;
    // --dump: which part and vectors to print (empty part: digest mode)
    std::string dump_part;
    uint64_t    dump_first = 0, dump_count = 0;

    uint32_t exec(uint32_t word, uint32_t a, uint32_t b) {
        top->instr     = word;
        top->rs1_value = a;
        top->rs2_value = b;
        top->eval();
        if (!top->rd_valid || top->rd_address != 10 || !top->ready) violations++;
        return top->rd_value;
    }
};

// One part: 'fn(i, word&, a&, b&, digest-values)' produces vector i.
struct Part {
    std::string name;
    uint64_t    vectors = 0;
    Digest      d;
};

void finish(const Form& f, Part& p, const Run& r) {
    if (r.dump_part.empty())
        printf("%s %s %llu %016llx\n", f.name, p.name.c_str(), (unsigned long long)p.vectors,
               (unsigned long long)p.d.h);
}

bool dumping(const Run& r, const Part& p) {
    return !r.dump_part.empty() && r.dump_part == p.name && p.vectors >= r.dump_first &&
           p.vectors < r.dump_first + r.dump_count;
}

void run_form(int index, Run& r, const std::vector<uint32_t>& C, bool quick) {
    const Form& f = FORMS[index];
    const std::string n = f.name;
    SplitMix rng{0x0123456789ABCDEFull + uint64_t(index)};
    const uint32_t base = f.match | (11u << 15) | (10u << 7);
    const bool want_dump = !r.dump_part.empty();

    auto vec3 = [&](Part& p, uint32_t word, uint32_t a, uint32_t b, uint32_t first) {
        uint32_t rd = r.exec(word, a, b);
        if (dumping(r, p)) printf("%08x %08x %08x\n", a, b, rd);
        p.d.add(first);
        p.d.add(f.kind == IMM ? a : b);
        p.d.add(rd);
        p.vectors++;
    };

    if (f.kind == REG) {
        const uint32_t word = base | (12u << 20);
        Part corner{"corner"};
        if (!want_dump || r.dump_part == "corner") {
            for (uint32_t a : C)
                for (uint32_t b : C) vec3(corner, word, a, b, a);
            finish(f, corner, r);
        }
        Part random{"random"};
        for (int i = 0; i < 1048576; i++) {
            uint64_t z = rng.next();
            if (!want_dump || r.dump_part == "random") vec3(random, word, uint32_t(z), uint32_t(z >> 32), uint32_t(z));
        }
        if (!want_dump) finish(f, random, r);
        if (has_amount(n)) {
            Part amount{"amount"};
            for (uint32_t a : C)
                for (uint32_t s = 0; s < 32; s++) {
                    uint64_t z = rng.next();
                    uint32_t b = s | (uint32_t(z & ((1u << 27) - 1)) << 5);
                    if (!want_dump || r.dump_part == "amount") vec3(amount, word, a, b, a);
                }
            if (!want_dump) finish(f, amount, r);
        }
        if (is_czero(n)) {
            Part zero{"zero"};
            for (int i = 0; i < 4096; i++) {
                uint32_t a = uint32_t(rng.next());
                if (!want_dump || r.dump_part == "zero") vec3(zero, word, a, 0, a);
            }
            if (!want_dump) finish(f, zero, r);
        }
    } else if (f.kind == IMM) {
        Part p{"shamt"};
        for (uint32_t s = 0; s < 32; s++) {
            const uint32_t word = base | (s << 20);
            for (uint32_t a : C) {
                uint32_t rd = r.exec(word, a, RS2_IDLE);
                if (dumping(r, p)) printf("%08x %08x %08x\n", a, s, rd);
                p.d.add(s); p.d.add(a); p.d.add(rd);
                p.vectors++;
            }
            for (int i = 0; i < 4096; i++) {
                uint64_t z = rng.next();
                uint32_t a = uint32_t(z), b = uint32_t(z >> 32);
                uint32_t rd = r.exec(word, a, b);
                if (dumping(r, p)) printf("%08x %08x %08x\n", a, s, rd);
                p.d.add(s); p.d.add(a); p.d.add(rd);
                p.vectors++;
            }
        }
        finish(f, p, r);
    } else {
        for (uint32_t c = 0; c < 256; c++) {
            if (quick && c != 0 && c != 127 && c != 128 && c != 255) continue;
            char name[8];
            snprintf(name, sizeof name, "c%03u", c);
            if (want_dump && r.dump_part != name) continue;
            Part p{name};
            const uint32_t first = c << 24;
            if (want_dump) {
                for (uint64_t i = r.dump_first; i < r.dump_first + r.dump_count && i < (1u << 24); i++) {
                    uint32_t x = first + uint32_t(i);
                    printf("%08x %08x %08x\n", x, RS2_IDLE, r.exec(base, x, RS2_IDLE));
                }
                continue;
            }
            for (uint32_t i = 0; i < (1u << 24); i++) p.d.add(r.exec(base, first + i, RS2_IDLE));
            p.vectors = 1u << 24;
            finish(f, p, r);
            fflush(stdout);
        }
    }
    fflush(stdout);
}

int usage() {
    fprintf(stderr, "usage: harness [--quick] [--form <mnemonic>]... "
                    "[--dump <mnemonic> <part> <first> <count>]\n");
    return 2;
}

}  // namespace

int main(int argc, char** argv) {
    bool quick = false;
    std::vector<std::string> only;
    Run r;
    std::string dump_form;
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--quick") quick = true;
        else if (a == "--form" && i + 1 < argc) only.push_back(argv[++i]);
        else if (a == "--dump" && i + 4 < argc) {
            dump_form    = argv[++i];
            r.dump_part  = argv[++i];
            r.dump_first = strtoull(argv[++i], nullptr, 0);
            r.dump_count = strtoull(argv[++i], nullptr, 0);
        } else if (a.rfind("+verilator", 0) == 0) continue;
        else return usage();
    }
    if (!dump_form.empty()) only = {dump_form};
    for (const std::string& n : only) {
        bool known = false;
        for (const Form& f : FORMS) known = known || n == f.name;
        if (!known) {
            fprintf(stderr, "harness: unknown form '%s'\n", n.c_str());
            return 2;
        }
    }

    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);
    Vharness top(&ctx);
    r.top = &top;

    // One reset cycle, then Execute idles with the default (VALID, READY) handshake.
    top.instr = 0x00000013;  // addi x0, x0, 0
    top.rs1_value = top.rs2_value = 0;
    top.rst = 1;
    top.clk = 0; top.eval();
    top.clk = 1; top.eval();
    top.clk = 0; top.eval();
    top.rst = 0;
    top.eval();

    const std::vector<uint32_t> C = corner_set();
    if (C.size() != 144) {
        fprintf(stderr, "harness: the corner set has %zu values, not 144\n", C.size());
        return 2;
    }
    for (int i = 0; i < 28; i++) {
        if (!only.empty() && std::find(only.begin(), only.end(), FORMS[i].name) == only.end()) continue;
        run_form(i, r, C, quick);
    }
    printf("violations=%llu\n", (unsigned long long)r.violations);
    top.final();
    return r.violations == 0 ? 0 : 1;
}
