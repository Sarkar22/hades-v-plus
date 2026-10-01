# The full demo with time slicing off: the golden CPU failed 3 of 12 seeds

**Status: historical.** A development campaign of 2026-09-27, made before the configuration of
the `full` program was changed (partly because of this result); the current program differs, so
the figure would not necessarily repeat.

## Figure and where it is quoted

| Figure as quoted | Quoted at |
|---|---|
| "with `configUSE_TIME_SLICING=0` the demo's priority-0 tasks ... can starve for a whole check period or trip MessageBufferDemo's coherence assert, and the golden CPU failed 3 of 12 seeds that way" | test/freertos/README.md:137-141 |

## What the development log of 2026-09-27 records

A campaign of the variant `full.rv32i.Os.p1s0.t10000.h4` (the standard demo set, `-Os`,
preemption on, time slicing off, 10000-cycle tick, heap_4) with 12 seeds, `0001` to `000c`, on
the golden CPU and two development versions of the core (wall time 12,383 s). Golden column and
verdict, verbatim:

```text
| full.rv32i.Os.p1s0.t10000.h4 | 0005 | ... | **FAIL** 50.66M: demo task set reported an error or stalled (check period, tick) [Messa |
| full.rv32i.Os.p1s0.t10000.h4 | 0009 | ... | **FAIL** 50.66M: demo task set reported an error or stalled (check period, tick) [Messa |
| full.rv32i.Os.p1s0.t10000.h4 | 000a | ... | **FAIL** 29.84M: configASSERT [MessageBufferDemo.c] a=00000386 b=00000000 |
...
| golden | 12 | 9 | 3 | 0 | 0 | - | - |
...
- HARNESS CHECK FAILED: golden did not pass 3/12 runs (those variants are invalid as differential tests)
```

The other nine seeds passed on the golden CPU (`PASS 150.71M`).

## What changed afterwards

Before it was committed (6b19d41, 2026-09-28), the `full` program was changed: it runs in the
campaigns with time slicing on only, as the official demo does; MessageBufferDemo's "space available coherence" sub-test
(`configRUN_ADDITIONAL_TESTS`) is off (test/freertos/README.md:141-144); and its timeout scales
with the tick period.

## To look at it again

The variant can still be built by hand, for example for seed 5 on the golden CPU:

```bash
make test/freertos/full FRTOS_OPT=-Os FRTOS_SLICE=0 FRTOS_SEED=5 FRTOS_CPU=ref
```

but with the program as it is now, not as it was on 2026-09-27.

## Environment

- Date: 2026-09-27 (wall time of the campaign: 12,383 s).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: Verilator 5.042, `riscv32-unknown-elf-gcc` 12.2.0, Python 3.12.

## Caveats

- Recorded from the campaign summary in the development log; the run logs were not kept.
