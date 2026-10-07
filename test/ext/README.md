# ext: reference models of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh instructions

The frozen golden models in `ref/` decode every Zbb, Zbs, Zicond, Zbkb, Zbkx
and Zknh instruction as illegal, so they cannot check them. This directory holds
the models that do, written from the ratified ISA text (unprivileged manual,
chapters "'B' Extension for Bit Manipulation", "'Zicond' Extension for Integer
Conditional Operations" and "Cryptography Extensions", whose scalar part is also
published as *RISC-V Cryptography Extensions Volume I*, Version 1.0.1), not
from the RTL:

* **`ref.py`**: the reference model in Python, one function per instruction
  form, computing on 32-character bit strings (rotates are slices, `clz`/`ctz`
  search for the first or last `1`, `cpop` counts them, `zip` interleaves the
  two halves, `xperm` indexes a list of slices). It also holds the encoding
  table of the 45 forms (MATCH/MASK as in riscv-opcodes) and the vector
  protocol below.
* **`ref_exh.c`**: the same instructions in C with bit tricks (shuffle masks
  for `zip` and `unzip`, three swaps for `brev8`, the SHA-512 halves as halves
  of the 64-bit functions of FIPS 180-4), fast enough to digest every 32-bit
  input of the fifteen unary forms (about 4-12 s per form).
* `test/trapsweep/iss.py` is the third model, on Python integers, used to
  check whole programs.

The three are written in different styles on purpose, so that one mistake is
unlikely to appear in all of them.

## The check of the RTL

```
make ext-check            # the quick vector set: 125 digest lines
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
`EXT CHECK: PASS` or `EXT CHECK: FAIL`. The quick run checks 1,034,153,728
vectors (125 digest lines); the exhaustive run 64,452,030,208 vectors (3,905
digest lines). The 28 forms of Zbb, Zbs and Zicond took about 14 minutes with 4
jobs ([record](../../results/bitmanip/2026-10-02_e75223e/RECORD.md)).
`ref.py --selftest` checks the models against each other and against FIPS 180-4:

```
python3 test/ext/ref.py --selftest [--quick] [--jobs N]
```

* the protocol constants (corner set of 144 values, PRNG and digest known
  answers);
* the encodings: MATCH/MASK against the field table, every form re-assembled
  with the RISC-V assembler when it is installed (`czero.*` excepted: binutils
  2.39 does not know them), and 92 neighbouring words that must stay illegal
  (RV32-reserved `shamt[5]=1` forms, Zbc, Zbkc, Zkne, Zknd, Zksed and Zksh
  forms, RV64-only encodings such as `sha512sum0` and `packw`, unused
  funct3/funct7 and rs2-field values, the illegal words of `zbaadv.s`,
  `fuzz.py` and `probes.py`). `zext.h` is `pack rd, rs1, x0` (same result):
  the table names that word `zext.h`, the first match in form order;
* known answers from the specification and worked by hand, on the model and
  on `iss.py`;
* the expected new-instruction hits of the decoder sweeps A, B, D, E and F of
  `test/sv/test_zba_encoding_sweep.sv` (`ref.py --sweep-counts` prints them);
* FIPS 180-4: the four `sha256*` forms against the SHA-256 functions σ0, σ1,
  Σ0, Σ1, and the SHA-512 functions built from pairs of `sha512*` forms (high
  half from rs1 = high word, low half with the operands swapped) against the
  64-bit ones, on 10^5 random values (10^4 with `--quick`); then SHA-256 and
  SHA-512 hashes computed with those forms reproduce the NIST examples (also
  checked against Python's `hashlib`);
* `zip`/`unzip` inverse to each other and `brev8` its own inverse;
* `iss.py`: every OP and OP-IMM word of those sweeps is legal exactly when it
  is one of the 45 forms (or was legal before); with Zbkb alone, exactly the
  twelve Zbkb instructions are; and 10^5 random operand pairs per form (10^4
  with `--quick`) give the model's result;
* `ref_exh`: identical digest lines for every part except the unary chunks,
  and value-by-value agreement on the corner set, on every `0x0000XXXX` and
  `0xFFFFXXXX` value and on 10^6 random values per unary form; without
  `--quick`, also `ref_exh --identities` (the inverse pairs over all 2^32
  inputs).

## Vector protocol

The RTL harness and `ref_exh` print one line per part,
`<mnemonic> <part> <vectors> <digest>`, with the digest as 16 lowercase hex
digits; the two outputs must be identical.

* **Forms** in this order: `andn orn xnor clz ctz cpop max maxu min minu sext.b
  sext.h zext.h rol ror rori orc.b rev8 bclr bclri bext bexti binv binvi bset
  bseti czero.eqz czero.nez pack packh brev8 zip unzip xperm4 xperm8 sha256sig0
  sha256sig1 sha256sum0 sha256sum1 sha512sig0h sha512sig0l sha512sig1h
  sha512sig1l sha512sum0r sha512sum1r` (form number 0..44).
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
| `index` | xperm4 xperm8 | a over C, then 256 × `z = next()`: b = high half of z masked with `0xFFFFFFFF` (xperm4) or `0x83838383` (xperm8), so that half of the indices are out of range | a, b, rd |
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
./ref_exh --identities                  # zip/unzip and brev8 inverses over all 2^32 inputs
```

For `--dump` of the `shamt` part, `a` is the shift amount and `b` the rs1
value, in the order they are digested.
