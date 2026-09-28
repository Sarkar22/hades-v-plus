// Reads "op a b" hex triples on stdin, prints "y_m y_ref" hex pairs.
#include "Vspec_top.h"
#include "verilated.h"
#include <cstdio>
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vspec_top t;
    unsigned op, a, b;
    while (scanf("%x %x %x", &op, &a, &b) == 3) {
        t.op = op; t.a = a; t.b = b; t.eval();
        printf("%08x %08x\n", (unsigned)t.y_m, (unsigned)t.y_ref);
    }
    return 0;
}
