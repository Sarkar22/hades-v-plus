# The vendored FreeRTOS file set: 239 configurations, 64 files used

**Status: historical.** The determination was made once, when FreeRTOS was vendored (commit
6bf71d4); it could be repeated by building every configuration again and collecting the
compiler's dependency files, but there is no command for it.

## Figures and where they are quoted

| Figure as quoted | Quoted at | Status |
|---|---|---|
| 76 files, 2,091,517 bytes | third_party/freertos/README.md:74 | repeatable: `results/tests/2026-10-01_03386fd/` (76 files, `sha256sum -c MANIFEST` all OK, 2,091,517 bytes) |
| determined by building "every program at each `HEAP`, `MARCH` and `OPT` value: 239 configurations" | third_party/freertos/README.md:75-76 | historical, this record |
| "That yields 64 files; the other 12 are the three licence files, FreeRTOS+CLI ..., and the kernel headers that no current configuration includes" | third_party/freertos/README.md:77-79 | historical, this record |
| 14 of the 21 kernel headers are included by the current programs | third_party/freertos/README.md:89 | historical, this record |

## What the development log of 2026-09-30 records

The vendoring work (evening of 2026-09-30) built every configuration twice, once against the
vendored files and once against external clones of the pinned commits:

```text
239 configurations, 30 failed builds, 209 images, 64 used upstream files
...
--- used files (vendored run) vs (external run): used-file sets identical
--- init.mem hashes per configuration: all 209 init.mem images identical
```

The 64 files: 27 of FreeRTOS-Kernel (`tasks.c`, `queue.c`, `list.c`, `timers.c`,
`event_groups.c`, `stream_buffer.c`, `heap_1.c`, `heap_4.c`, the four files of the RISC-V port,
its chip-specific header, and 14 headers of `include/`: `FreeRTOS.h`,
`deprecated_definitions.h`, `event_groups.h`, `list.h`, `message_buffer.h`, `mpu_wrappers.h`,
`portable.h`, `projdefs.h`, `queue.h`, `semphr.h`, `stack_macros.h`, `stream_buffer.h`,
`task.h`, `timers.h`), 18 standard demo sources and their 18 headers, and `RegTest.S`. The other
12 vendored files: the three licence files, `FreeRTOS_CLI.c` and `FreeRTOS_CLI.h` (used only by
the shell, added later in cbae9b9), and 7 kernel headers.

## Environment

- Date: 2026-09-30 (evening, local time).
- Host: Intel Core Ultra 7 165H, 22 threads, Linux.
- Tools: `riscv32-unknown-elf-gcc` 12.2.0 (dependency files), Verilator 5.042.

## Caveats

- 30 of the 239 configurations did not build (for example `brk` with `HEAP=1`, which lacks
  `xPortGetMinimumEverFreeHeapSize`); the 64 files come from the 209 that did. The README does not
  mention the failed builds.
- The set was determined before the shell program existed; the shell adds FreeRTOS+CLI, which
  is vendored.
