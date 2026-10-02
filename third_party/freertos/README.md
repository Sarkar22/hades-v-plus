# FreeRTOS — vendored third-party sources

This directory contains unmodified copies of the [FreeRTOS](https://www.freertos.org) source
files that HaDes-V+ uses for its FreeRTOS programs ([`test/freertos/`](../../test/freertos),
guide: [docs/FREERTOS.md](../../docs/FREERTOS.md)). They are part of the repository so that a
clone builds and runs FreeRTOS as it stands, without a download step and without network
access.

These files are third-party software. They are not original work of the HaDes-V or HaDes-V+
authors, and they are distributed under their own MIT licence (see [Licence](#licence)).

## Provenance

| Vendored as | Upstream repository | Upstream path | Pinned commit |
|---|---|---|---|
| `FreeRTOS-Kernel/` | [FreeRTOS/FreeRTOS-Kernel](https://github.com/FreeRTOS/FreeRTOS-Kernel) | repository root | [`8be86d4a24fd4091f8f4192018423ab590f408db`](https://github.com/FreeRTOS/FreeRTOS-Kernel/tree/8be86d4a24fd4091f8f4192018423ab590f408db) (branch `main`, 2026-08-26; kernel version `V11.1.0+`) |
| `FreeRTOS/FreeRTOS/Demo/` | [FreeRTOS/FreeRTOS](https://github.com/FreeRTOS/FreeRTOS) | `FreeRTOS/Demo/` | [`f4fcc3b228643144727e9257ba12db1cb632b6e6`](https://github.com/FreeRTOS/FreeRTOS/tree/f4fcc3b228643144727e9257ba12db1cb632b6e6) (branch `main`, 2026-08-26) |
| `FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/` | [FreeRTOS/FreeRTOS](https://github.com/FreeRTOS/FreeRTOS) | `FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/` | `f4fcc3b228643144727e9257ba12db1cb632b6e6` (the same commit) |
| `FreeRTOS/LICENSE.md` | [FreeRTOS/FreeRTOS](https://github.com/FreeRTOS/FreeRTOS) | `LICENSE.md` | `f4fcc3b228643144727e9257ba12db1cb632b6e6` (the same commit) |

The layout mirrors the two upstream repositories: `FreeRTOS-Kernel/<path>` is `<path>` in
FreeRTOS-Kernel, and `FreeRTOS/<path>` is `<path>` in FreeRTOS/FreeRTOS. Every file can
therefore be compared with its original directly.

## Licence

All vendored files are distributed under the **MIT licence**, Copyright (C) Amazon.com, Inc.
or its affiliates. The licence texts are included verbatim:

* [`FreeRTOS-Kernel/LICENSE.md`](FreeRTOS-Kernel/LICENSE.md) — FreeRTOS-Kernel
* [`FreeRTOS/LICENSE.md`](FreeRTOS/LICENSE.md) — FreeRTOS/FreeRTOS (standard demo tasks, RegTest)
* [`FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/LICENSE_INFORMATION.txt`](FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/LICENSE_INFORMATION.txt) — FreeRTOS+CLI

Every vendored source file retains its upstream header with the copyright notice of
Amazon.com, Inc. or its affiliates and the MIT permission notice. `FreeRTOS-Kernel/tasks.c`
and `FreeRTOS-Kernel/include/task.h` additionally carry a copyright notice of Arm Limited
and/or its affiliates, under the same licence.

## The files are unmodified

No vendored file has been changed. [`MANIFEST`](MANIFEST) lists the SHA-256 checksum of every
vendored file; each equals the checksum of the same file in the upstream repository at the
pinned commit (equivalently, its git blob id equals the upstream one). To check the tree:

```bash
cd third_party/freertos && sha256sum -c MANIFEST
```

Everything specific to HaDes-V+ lives outside this directory: the kernel configuration
(`test/freertos/common/FreeRTOSConfig.h` and each program's `app_config.h`), the start-up
code, the linker script and the hooks the port calls (`test/freertos/common/`). Do not edit
the files here; a local change would no longer match `MANIFEST` or upstream.

`.gitattributes` disables end-of-line conversion for this directory, so a checkout on any
platform matches `MANIFEST`.

## How the build uses them

[`test/freertos/freertos.mk`](../../test/freertos/freertos.mk) sets `FREERTOS_HOME` to this
directory by default and derives from it:

| Variable | Default |
|---|---|
| `FREERTOS_KERNEL` | `$(FREERTOS_HOME)/FreeRTOS-Kernel` |
| `FREERTOS_DEMO` | `$(FREERTOS_HOME)/FreeRTOS/FreeRTOS/Demo` |
| `FREERTOS_PLUS_CLI` | `$(FREERTOS_HOME)/FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI` |

To build against an external checkout instead, set `FREERTOS_HOME` to a directory that
holds clones of both repositories side by side (`FreeRTOS-Kernel/` and `FreeRTOS/`), or set
the individual variables. Only the pinned commits are tested.

## Files

76 files, 2,091,517 bytes. The set was determined by building every configuration of every
program in `test/freertos/` (all variants of every `campaign.py` set, and every program at
each `HEAP`, `MARCH` and `OPT` value: 239 configurations) and collecting the compiler's
dependency files. That yields 64 files; the other 12 are the three licence files, FreeRTOS+CLI
(compiled only by the `shell` program, which was added after the set was determined), and
the kernel headers that no current configuration includes (see below).

**FreeRTOS-Kernel** (35 files)

| Files | Used by |
|---|---|
| `LICENSE.md` | licence |
| `tasks.c`, `queue.c`, `list.c` | every program |
| `timers.c`, `event_groups.c` | `full` (and any program that adds them to `APP_KERNEL_SRCS`) |
| `stream_buffer.c` | `full`, `brk` |
| `include/` — all 21 headers | every program. The complete public header set is vendored because `FreeRTOS.h` selects headers by configuration (for example `newlib-freertos.h` with `configUSE_NEWLIB_REENTRANT`) and programs may include any kernel header. 14 of them are included by the current programs; `atomic.h`, `croutine.h`, `mpu_prototypes.h`, `mpu_syscall_numbers.h`, `newlib-freertos.h`, `picolibc-freertos.h` and `StackMacros.h` are not. The directory's `CMakeLists.txt` and `stdint.readme` are not vendored. |
| `portable/GCC/RISC-V/port.c`, `portASM.S`, `portContext.h`, `portmacro.h` | every program (the official RISC-V port) |
| `portable/GCC/RISC-V/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions/freertos_risc_v_chip_specific_extensions.h` | every program (the only chip-specific extension the build selects) |
| `portable/MemMang/heap_1.c`, `heap_4.c` | the two heap implementations selected by `HEAP=1` / `HEAP=4` |

Not vendored: `croutine.c` (co-routines are not used), the other ports, the other heap
implementations, and upstream's build files, examples and documentation.

**FreeRTOS/FreeRTOS** (41 files)

| Files | Used by |
|---|---|
| `LICENSE.md` | licence |
| `FreeRTOS/Demo/Common/Minimal/` — 18 standard demo task sources | `full` |
| `FreeRTOS/Demo/Common/include/` — their 18 headers | `full` |
| `FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S` | `stress`, `full`, `mzba`, `brk` (register test tasks) |
| `FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/FreeRTOS_CLI.c`, `FreeRTOS_CLI.h`, `LICENSE_INFORMATION.txt` | FreeRTOS+CLI: `shell` (the interactive command shell, `test/freertos/shell/`) |

The complete list, as recorded in `MANIFEST`:

```text
FreeRTOS-Kernel/LICENSE.md
FreeRTOS-Kernel/event_groups.c
FreeRTOS-Kernel/include/FreeRTOS.h
FreeRTOS-Kernel/include/StackMacros.h
FreeRTOS-Kernel/include/atomic.h
FreeRTOS-Kernel/include/croutine.h
FreeRTOS-Kernel/include/deprecated_definitions.h
FreeRTOS-Kernel/include/event_groups.h
FreeRTOS-Kernel/include/list.h
FreeRTOS-Kernel/include/message_buffer.h
FreeRTOS-Kernel/include/mpu_prototypes.h
FreeRTOS-Kernel/include/mpu_syscall_numbers.h
FreeRTOS-Kernel/include/mpu_wrappers.h
FreeRTOS-Kernel/include/newlib-freertos.h
FreeRTOS-Kernel/include/picolibc-freertos.h
FreeRTOS-Kernel/include/portable.h
FreeRTOS-Kernel/include/projdefs.h
FreeRTOS-Kernel/include/queue.h
FreeRTOS-Kernel/include/semphr.h
FreeRTOS-Kernel/include/stack_macros.h
FreeRTOS-Kernel/include/stream_buffer.h
FreeRTOS-Kernel/include/task.h
FreeRTOS-Kernel/include/timers.h
FreeRTOS-Kernel/list.c
FreeRTOS-Kernel/portable/GCC/RISC-V/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions/freertos_risc_v_chip_specific_extensions.h
FreeRTOS-Kernel/portable/GCC/RISC-V/port.c
FreeRTOS-Kernel/portable/GCC/RISC-V/portASM.S
FreeRTOS-Kernel/portable/GCC/RISC-V/portContext.h
FreeRTOS-Kernel/portable/GCC/RISC-V/portmacro.h
FreeRTOS-Kernel/portable/MemMang/heap_1.c
FreeRTOS-Kernel/portable/MemMang/heap_4.c
FreeRTOS-Kernel/queue.c
FreeRTOS-Kernel/stream_buffer.c
FreeRTOS-Kernel/tasks.c
FreeRTOS-Kernel/timers.c
FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/FreeRTOS_CLI.c
FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/FreeRTOS_CLI.h
FreeRTOS/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI/LICENSE_INFORMATION.txt
FreeRTOS/FreeRTOS/Demo/Common/Minimal/AbortDelay.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/BlockQ.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/EventGroupsDemo.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/GenQTest.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/IntSemTest.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/MessageBufferDemo.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/PollQ.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/QueueOverwrite.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/QueueSet.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/StreamBufferDemo.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/StreamBufferInterrupt.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/TaskNotify.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/TimerDemo.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/blocktim.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/countsem.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/dynamic.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/recmutex.c
FreeRTOS/FreeRTOS/Demo/Common/Minimal/semtest.c
FreeRTOS/FreeRTOS/Demo/Common/include/AbortDelay.h
FreeRTOS/FreeRTOS/Demo/Common/include/BlockQ.h
FreeRTOS/FreeRTOS/Demo/Common/include/EventGroupsDemo.h
FreeRTOS/FreeRTOS/Demo/Common/include/GenQTest.h
FreeRTOS/FreeRTOS/Demo/Common/include/IntSemTest.h
FreeRTOS/FreeRTOS/Demo/Common/include/MessageBufferDemo.h
FreeRTOS/FreeRTOS/Demo/Common/include/PollQ.h
FreeRTOS/FreeRTOS/Demo/Common/include/QueueOverwrite.h
FreeRTOS/FreeRTOS/Demo/Common/include/QueueSet.h
FreeRTOS/FreeRTOS/Demo/Common/include/StreamBufferDemo.h
FreeRTOS/FreeRTOS/Demo/Common/include/StreamBufferInterrupt.h
FreeRTOS/FreeRTOS/Demo/Common/include/TaskNotify.h
FreeRTOS/FreeRTOS/Demo/Common/include/TimerDemo.h
FreeRTOS/FreeRTOS/Demo/Common/include/blocktim.h
FreeRTOS/FreeRTOS/Demo/Common/include/countsem.h
FreeRTOS/FreeRTOS/Demo/Common/include/dynamic.h
FreeRTOS/FreeRTOS/Demo/Common/include/recmutex.h
FreeRTOS/FreeRTOS/Demo/Common/include/semtest.h
FreeRTOS/FreeRTOS/Demo/RISC-V_RV32_QEMU_VIRT_GCC/build/gcc/RegTest.S
FreeRTOS/LICENSE.md
```

The other files in this directory belong to HaDes-V+, not to FreeRTOS: this `README.md`,
`MANIFEST`, `update.sh` and `.gitattributes`.

## Updating

[`update.sh`](update.sh) re-vendors the files from upstream. It fetches exactly the listed
files of both repositories at the given commits into a temporary directory (a shallow,
sparse fetch of one commit each), replaces `FreeRTOS-Kernel/` and `FreeRTOS/` here with
them, rewrites `MANIFEST`, and prints it together with any change against the previous
`MANIFEST`. It needs git 2.25 or newer, `sha256sum` (or `shasum`) and network access to
github.com. Building HaDes-V+ never runs it.

```bash
sh third_party/freertos/update.sh                       # the pinned commits: reproduces this tree exactly
sh third_party/freertos/update.sh <FreeRTOS-Kernel commit> <FreeRTOS commit>   # full 40-digit ids
```

To move to newer upstream commits:

1. Run `update.sh` with the new commit ids and review the result with `git diff`.
2. Build and test every program against them, at least `make freertos APP=<name>` for each
   program, `make freertos-compare APP=stress`, `make freertos-stress` and
   `python3 test/freertos/campaign.py --set standard`.
3. Record the new commits in `update.sh` (`KERNEL_PINNED`, `FREERTOS_PINNED`), in this
   file, in the header of `test/freertos/freertos.mk`, in `test/freertos/README.md` and in
   section 14 of `docs/FREERTOS.md`.

To vendor an additional file, add its upstream path to the matching list in `update.sh`,
run it, and add the file to the lists above.
