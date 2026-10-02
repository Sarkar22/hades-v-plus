# ext: reference models of the Zbb, Zbs and Zicond instructions

The frozen golden models in `ref/` decode every Zbb, Zbs and Zicond instruction
as illegal, so they cannot check them. This directory holds the models that do,
written from the ratified ISA text (unprivileged manual, chapters "'B' Extension
for Bit Manipulation" and "'Zicond' Extension for Integer Conditional
Operations"), not from the RTL:

* **`ref.py`**: the reference model in Python, one function per instruction
  form, computing on 32-character bit strings (rotates are slices, `clz`/`ctz`
  search for the first or last `1`, `cpop` counts them). It also holds the
  encoding table of the 28 forms (MATCH/MASK as in riscv-opcodes) and the
  vector protocol below.
* **`ref_exh.c`**: the same instructions in C with bit tricks, fast enough to
  digest every 32-bit input of the eight unary forms (about 4-12 s per form).
* `test/trapsweep/iss.py` is the third model, on Python integers, used to
  check whole programs.

The three are written in different styles on purpose, so that one mistake is
unlikely to appear in all of them.

## The check of the RTL

```
make ext-check            # the quick vector set: 75 digest lines, under a minute
make ext-exhaustive       # every part, the unary forms over all 2^32 inputs [JOBS=4]
```

[`run.py`](run.py) (called by both targets, rules in [`ext.mk`](ext.mk)) builds the
harness, [`harness.sv`](harness.sv) and [`harness.cpp`](harness.cpp): the real
`instruction_decoder` feeding the real `execute_stage`, compiled with Verilator,
which receives the instruction word of each form (rd = x10, rs1 = x11, rs2 = x12
or the shift amount), drives the operand values and reads the result that Execute
forwards in the same cycle. It also builds `ref_exh`, runs both for each form (one
process each, `JOBS` at a time), and compares their digest lines. A form passes when
the lines are identical and the harness reports `violations=0`: every result valid
in Execute's own cycle, for rd = x10, without a stall. The run ends with
`EXT CHECK: PASS` or `EXT CHECK: FAIL`. The exhaustive run checks 34,376,492,288
vectors (2,091 digest lines) in about 14 minutes with 4 jobs
([record](../../results/bitmanip/2026-10-02_e75223e/RECORD.md)). `ref.py --selftest` checks them against each
other:

```
python3 test/ext/ref.py --selftest [--quick] [--jobs N]
```

* the protocol constants (corner set of 144 values, PRNG and digest known
  answers);
* the encodings: MATCH/MASK against the field table, every form re-assembled
  with the RISC-V assembler when it is installed (`czero.*` excepted: binutils
  2.39 does not know them), and 56 neighbouring words that must stay illegal
  (RV32-reserved `shamt[5]=1` forms, Zbc, Zbkb, Zbkx, RV64-only encodings,
  unused funct3/funct7 combinations, the illegal words of `zbaadv.s`,
  `fuzz.py` and `probes.py`);
* known answers from the specification and worked by hand, on the model and
  on `iss.py`;
* the expected new-instruction hits of the decoder sweeps A, B, D, E and F of
  `test/sv/test_zba_encoding_sweep.sv` (`ref.py --sweep-counts` prints them);
* `iss.py`: every OP and OP-IMM word of those sweeps is legal exactly when it
  is one of the 28 forms (or was legal before), and 10^5 random operand pairs
  per form (10^4 with `--quick`) give the model's result;
* `ref_exh`: identical digest lines for every part except the unary chunks,
  and value-by-value agreement on the corner set, on every `0x0000XXXX` and
  `0xFFFFXXXX` value and on 10^6 random values per unary form.

## Vector protocol

The RTL harness and `ref_exh` print one line per part,
`<mnemonic> <part> <vectors> <digest>`, with the digest as 16 lowercase hex
digits; the two outputs must be identical.

* **Forms** in this order: `andn orn xnor clz ctz cpop max maxu min minu sext.b
  sext.h zext.h rol ror rori orc.b rev8 bclr bclri bext bexti binv binvi bset
  bseti czero.eqz czero.nez` (form number 0..27).
* **Corner set C**: 0, `0xFFFFFFFF`, `1 << k`, `~(1 << k)`, `(1 << k) - 1`
  (k = 1..32), `0xFFFFFFFF << k` (k = 1..31) and 23 patterns (`0x55555555`,
  `0xDEADBEEF`, ...; see `CORNER` in `ref.py`), sorted, without duplicates:
  144 values.
* **PRNG**: splitmix64, one stream per form, starting at state
  `0x0123456789ABCDEF + form number`, consumed in part order.
* **Digest**: FNV-1a over 32-bit values, `h = (h ^ v) * 0x100000001B3 mod 2^64`
  from `0xCBF29CE484222325`.

| Part | Forms | Vectors (a = rs1 value, b = rs2 value) | Digested per vector |
|---|---|---|---|
| `corner` | register forms | a over C, b over C: 20,736 | a, b, rd |
| `random` | register forms | 2^20 × `z = next()`: a = low half, b = high half | a, b, rd |
| `amount` | rol ror bclr bext binv bset | a over C, s = 0..31: b = s with random bits 31:5 | a, b, rd |
| `zero` | czero.eqz czero.nez | 4,096 × random a, b = 0 | a, b, rd |
| `shamt` | immediate forms | s = 0..31: a over C, then 4,096 random a (rs2 value random) | s, a, rd |
| `c000`..`c255` | unary forms | x = N·2^24 .. N·2^24 + 2^24 − 1, rs2 value `0xA5A5A5A5` | rd |

The rs2 value of the immediate and unary forms is not part of their semantics;
it is driven with noise to show that it does not affect rd. A quick run prints
the unary chunks `c000 c127 c128 c255` only.

```
cc -O2 -o ref_exh test/ext/ref_exh.c
./ref_exh [--quick] [--no-chunks] [--form M]... [--part P]...
./ref_exh --dump M PART FIRST COUNT     # 'a b rd' of vectors FIRST.. of a part
./ref_exh --eval M                      # binary (a, b) pairs in, rd out, little-endian
```

For `--dump` of the `shamt` part, `a` is the shift amount and `b` the rs1
value, in the order they are digested.
