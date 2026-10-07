# Zbkb, Zbkx and Zknh tests: 2026-10-02, bd800d8

**Status: repeatable**, apart from the sections marked as checks made once. `make check-results CHECK_ARGS=crypto` re-runs every command below and compares the stored lines, the per-program tables and the forms in the app's two builds exactly.

The tests that cover these instructions together with Zbb, Zbs and Zicond (the decoder sweep, `test_ext_execute`, `make ext-check`, `make ext-exhaustive` and `zkt.s`) are recorded, with dated updates, in [bitmanip/2026-10-02_e75223e](../../bitmanip/2026-10-02_e75223e/RECORD.md) and [tests/2026-10-01_03386fd](../../tests/2026-10-01_03386fd/RECORD.md); the formal proof in [formal/2026-10-02_bd800d8](../../formal/2026-10-02_bd800d8/RECORD.md); `make bench-sha256` in [sha256/2026-10-02_bd800d8](../../sha256/2026-10-02_bd800d8/RECORD.md).

## The figures and where they are quoted

| Quoted | Where | Section |
|---|---|---|
| `zbkb.s` 212 assertions, `zbkx.s` 166, `zknh.s` 347 (the `Test pass!` lines plus the deliberate initial-test assertion, as for `zba.s`) | docs/EXTENSIONS.md; docs/VERIFICATION.md | [assembly tests](#assembly-tests) |
| 1,000 of 1,000 random programs with the 17 instructions consistent with the instruction-set model (fuzz variant k) | README.md; docs/VERIFICATION.md; docs/EXTENSIONS.md | [random programs](#random-programs) |
| 27 interrupt probes, 3 of 3 programs consistent (`--fam crypto`) | docs/VERIFICATION.md; docs/EXTENSIONS.md | [interrupt probes](#interrupt-probes) |
| the app `sha256`: self-test 4 of 4 in both builds on HaDes-V+ and in the `rv32i` build on the golden CPU, which refuses the Zknh build; the digests of Python's `hashlib`; the four `sha256` forms in its Zknh build, none of the 17 in its `rv32i` build | README.md; docs/APPS.md; docs/VERIFICATION.md; docs/EXTENSIONS.md | [the app sha256](#the-app-sha256) |
| mutation testing of the decoder and of Part 2d; the decode of all 2^32 words; GCC's images with the new `-march` | docs/EXTENSIONS.md; docs/VERIFICATION.md (Mutation Testing) | [mutation testing](#mutation-testing), [checks made once](#checks-made-once) |

## Commands

From the repository root (`{jobs}` is `--jobs` of `results/check.sh`, 4 by default, and `{out}` an output directory):

```
make test/asm/zbkb
make test/asm/zbkx
make test/asm/zknh
python3 test/trapsweep/sweep.py fuzz --seeds 2001-3000 --variant k --targets dut --jobs {jobs} --out {out}
python3 test/trapsweep/sweep.py run --fam crypto --targets dut --jobs {jobs} --out {out}
make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-crypto.txt
make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-crypto.txt CPU=golden
```

## Inputs and environment

- Base commit `bd800d8`, with the Zbkb, Zbkx and Zknh changes not yet committed: [`inputs.sha256`](inputs.sha256) lists the sha256 of every file that these commands use and that differs from the base commit, other than documentation.
- Date: 2026-10-02. Host: Intel Core Ultra 7 165H, 22 threads, Linux. Tools: Verilator 5.042 2025-11-02 rev v5.042; riscv32-unknown-elf-gcc () 12.2.0 with GNU Binutils 2.39; Python 3.12.3; GNU Make 4.3. Workers: 4.
- Wall time: fuzz variant k 53.9 s, the probe family 1.0 s, `session-crypto.txt` 19.6 s on HaDes-V+ and 22.5 s on the golden CPU, the assembly tests under a second each.

## Assembly tests

The count of `Test pass!` lines and the verdict line of each (verbatim):

```
asm/zbkb: 211 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/zbkx: 165 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
asm/zknh: 346 'Test pass!' lines; All tests passed! (# Errors: 1 = initial test)
```

## Random programs

`sweep.py fuzz --variant k` generates programs that mix the 17 instructions (register and one-operand forms, dependent chains, results to `x0`, use as a load address and a branch operand) with the 28 forms of Zbb, Zbs and Zicond, RV32IM, Zba, loads, stores and branches; each run on HaDes-V+ is replayed by `test/trapsweep/iss.py`. Seeds 2001 to 3000 (the seeds of variant b are 1001 to 2000):

```
DUT: 1000/1000 programs ISS-consistent
```

The per-program results (program, consistent with the model, cycles on HaDes-V+) are in [`fuzz-k.csv`](fuzz-k.csv).

## Interrupt probes

The probe family `crypto` (27 probes: every form, dependent chains into and out of them, a load result used at once, a branch operand, a store address, a `jalr` base, `ecall` and `mret` next to them, results to `x0`, nested use in the handler, illegal neighbours that must keep trapping), swept over every interrupt offset with the external interrupt, the timer and both:

```
crypto_ext_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
crypto_timer_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
crypto_both_0 | dut:done | ISS[dut] groups_bad=0 violations=0 notes=0
DUT: 3/3 programs ISS-consistent
```

Per program: [`crypto-family.csv`](crypto-family.csv).

## The app sha256

`make freertos-shell-test APP=loader SCRIPT=test/freertos/loader/session-crypto.txt`: the verdict, the expectation count, and the transcript's lines that start with `loaded `, `sha256: `, `app: `, `error: ` or `cpu: ` (verbatim). On HaDes-V+:

```
FREERTOS SHELL RESULT: PASS  app=loader cpu=dut isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=23377699
  typed lines: 11, prompts: 11, expectations met: 34/34
cpu:       M yes, Zba yes, Zbb yes, Zbs yes, Zicntr yes, Zicond yes, Zbkb yes, Zbkx yes, Zknh yes
loaded sha256: 4220 bytes at 0x00060000, entry 0x00060040, CRC32 0xb6478d14
sha256: self-test 4 of 4 NIST vectors: PASS (C)
sha256: 4096 bytes in 355950 cycles, 86.9 cycles per byte (C)
app: sha256 exited with code 0 after 486555 cycles
sha256: self-test 4 of 4 NIST vectors: PASS (C)
sha256: 4096 bytes in 356137 cycles, 86.9 cycles per byte (C)
sha256: type lines; an empty line ends
app: sha256 exited with code 0 after 540903 cycles
loaded sha256: 3768 bytes at 0x00060000, entry 0x00060040, CRC32 0xc6f91489
sha256: self-test 4 of 4 NIST vectors: PASS (Zknh)
sha256: 4096 bytes in 210991 cycles, 51.5 cycles per byte (Zknh)
app: sha256 exited with code 0 after 326453 cycles
sha256: self-test 4 of 4 NIST vectors: PASS (Zknh)
sha256: 4096 bytes in 210988 cycles, 51.5 cycles per byte (Zknh)
app: sha256 exited with code 0 after 330006 cycles
```

On the golden CPU (`CPU=golden`):

```
FREERTOS SHELL RESULT: PASS  app=loader cpu=golden isa=rv32i opt=-Os tick=10000 bpred=0 seed=0 cycles=22603337
  typed lines: 11, prompts: 11, expectations met: 31/31
cpu:       M no, Zba no, Zbb no, Zbs no, Zicntr no, Zicond no, Zbkb no, Zbkx no, Zknh no
loaded sha256: 4220 bytes at 0x00060000, entry 0x00060040, CRC32 0xb6478d14
sha256: self-test 4 of 4 NIST vectors: PASS (C)
sha256: 4096 bytes in 355855 cycles, 86.9 cycles per byte (C)
app: sha256 exited with code 0 after 486309 cycles
sha256: self-test 4 of 4 NIST vectors: PASS (C)
sha256: 4096 bytes in 356032 cycles, 86.9 cycles per byte (C)
sha256: type lines; an empty line ends
app: sha256 exited with code 0 after 541558 cycles
loaded sha256: 3768 bytes at 0x00060000, entry 0x00060040, CRC32 0xc6f91489
error: sha256 was built for rv32im_zba_zbb_zbkb_zbkx_zbs_zknh, but this CPU has no M, no Zba, no Zbb, no Zbkb, no Zbkx, no Zbs and no Zknh
error: sha256 was built for rv32im_zba_zbb_zbkb_zbkx_zbs_zknh, but this CPU has no M, no Zba, no Zbb, no Zbkb, no Zbkx, no Zbs and no Zknh
```

The digests that the session expects (`abc`, `hello world`, `HaDes-V+`, `HaDes-V+ runs SHA-256`) are those of Python's `hashlib`. The forms in the app's two builds, counted with `CRYPTO_FORMS` of `test/bench/bench.py` in the SDK's disassembly:

```
sha256-rv32im_zba_zbb_zbkb_zbkx_zbs_zknh   4 words,  4 forms: sha256sig0=1 sha256sig1=1 sha256sum0=1 sha256sum1=1
sha256-rv32i                   0 words,  0 forms: -
```

The Zknh build also contains `rev8` (a Zbb instruction, which `sha256.h` uses for the message words); the other Zbkb and Zbkx instructions do not occur in SHA-256.

## Mutation testing

**Historical: made once during development, in copies of the tree outside the repository; not re-run by `make check-results`.** Two campaigns checked that the tests can fail.

- **During the implementation**, 22 faults were planted one at a time in the decoder and in Part 2d and run against the tests that should catch them: the decoder accepting `zip` for any `rs2` field, the `sha256` group for `rs2` fields 4 to 7, `brev8` with bit 25 set, the `sha512` arms for the two unused `funct7` slots, `xperm8` under `funct3` 101, the `pack` payload for `zext.h`, the `zip` and `unzip` payloads swapped; in Part 2d, `pack` with its halves swapped, `packh` taking `rs2[15:8]`, `brev8` computing `rev8`, `zip` sending the low half to the odd bits, `xperm4` wrapping out-of-range indices, `xperm8`'s range test ignoring index bit 2, `xperm` with `rs1` and `rs2` swapped, `sha256sig0` rotating by 3, `sha256sig1` and `sha256sum1` swapped, `sha512sig0l` computing `sig0h`, `sha512sig1h` computing `sig1l`, `sha512sum0r` with its operand roles swapped, the cryptography half never selected, its result not forwarded from Execute, and `zext.h` reading `rs2` into the high half. All 22 were caught: the decode faults by the decoder sweep, the others by `make ext-check` and the matching assembly test.
- **An independent review** planted 46 more faults, in the same categories and some new ones (rotate and shift amounts off by one, high and low halves swapped through the decoder or `op.sv`, `xperm` index width, the bytes of `packh`, the bit order of `brev8`, sub-operation codes colliding, a stall for one operand value, decode faults that depend on the register fields), each run against every test: the decoder sweep, `test_ext_execute`, the assembly tests of Zbb, Zbs, Zbkb, Zbkx, Zknh and Zkt, `zbaadv.s`, the quick `make ext-check` on all 45 forms and the exhaustive decode check below. 43 were caught; the other three cannot change anything the core does (an arithmetic shift of an unsigned value, which is a logical one, and two changes to the value of sub-operation codes that the decoder never produces) and are equivalent. Two observations, neither a defect: a fault that stalls a cryptography instruction for one value of `rs1[31:24]` passes `zkt.s` (which samples values) and is caught by `test_ext_execute`, `make ext-check` and the formal property X3; and decode faults that depend on the register fields (`zip` illegal when `rs1` is `x0`, `sha512sum0r` illegal when `rd` = `rs1`) pass the sweep, which uses two register pairs, and are caught by `zbkb.s`, `zknh.s` and the exhaustive decode check.

## Checks made once

**Historical: made once on this tree, outside the repository's commands.**

- **Every instruction word decoded.** The decoder of the base commit and the new one were run side by side on all 2^32 instruction words. The 333,824 words of the 17 forms decode to `op::EXT` with exactly their payload (all of them were illegal instructions before); each of the other 4,294,633,472 words gives a bit-identical decoded instruction in both, the 663,552 words of the 28 forms of Zbb, Zbs and Zicond included; no other word decodes to `op::EXT`. A table of the 45 forms written from the ratified encodings agreed with the binutils 2.39 disassembler on all 17 new forms.
- **GCC does not use the new instructions from C.** The five FreeRTOS programs of the campaign set `bitmanip` (`brk` without Zbs, as there) built at `-O2`, `-Os` and `-O0` with `-march=rv32im_zba_zbb_zbkb_zbkx_zbs_zknh` and with `-march=rv32im_zba_zbb_zbs`: 15 of 15 image pairs byte-identical. So the bitmanip campaign also stands for the new `-march`, and C reaches the new instructions only through inline assembly.
- **More random programs.** Fuzz variant k with seeds 3001 to 4000 (1,000 of 1,000 consistent, about 188,000 instructions of the 17 forms in their sources, each form 9,600 to 12,800 times) and seeds 4001 to 4500 with 50 segments per program (500 of 500).
- **Under FreeRTOS.** A FreeRTOS program that uses all 17 instructions through inline assembly, in its quiet check, its interrupt handler and two tasks with random and special operands, together with SHA-256 and SHA-512 kernels, and compares them with the same computations in RV32I C: it passed at `-O2`, `-Os` and `-O0` and with preemption and the branch predictor varied, and its RV32I build passed on both CPUs. With the fault `sha512sum1r` shifting by 13 instead of 14 it failed its quiet check.
- **`make ext-exhaustive`**, run separately with 3 jobs, gave the 3,905 digest lines and 64,452,030,208 vectors that [the bitmanip record](../../bitmanip/2026-10-02_e75223e/RECORD.md) stores, in 2,864 s.

## Caveats

- `zkt.s` times sampled operand values; the claim that the latency does not depend on the data for all values rests on the formal proof (X1, X3) and the per-vector checks of `test_ext_execute` and `make ext-check` ([docs/EXTENSIONS.md](../../../docs/EXTENSIONS.md#zkt-data-independent-latency)).
- The cycle counts in the transcripts are those of the Verilator model of the RTL of this working tree; the RTL has not been implemented on an FPGA since the Zbb, Zbs and Zicond unit, nor since its cryptography half.
