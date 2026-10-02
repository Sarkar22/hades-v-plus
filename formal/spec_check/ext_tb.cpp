// Reads "id rs1 rs2 shamt" hex quadruples on stdin, prints y in hex.
#include "Vext_spec_top.h"
#include "verilated.h"
#include <cstdio>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vext_spec_top t;
    unsigned id, a, b, s;
    while (scanf("%x %x %x %x", &id, &a, &b, &s) == 4) {
        t.id = id; t.rs1 = a; t.rs2 = b; t.shamt = s; t.eval();
        printf("%08x\n", (unsigned)t.y);
    }
    return 0;
}
