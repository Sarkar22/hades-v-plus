[HaDes-V+](../README.md) · **Docs** · [Building](BUILDING.md) · [FreeRTOS](FREERTOS.md) · [Shell](SHELL.md) · [Apps](APPS.md) · [Architecture](ARCHITECTURE.md) · [Extensions](EXTENSIONS.md) · [Verification](VERIFICATION.md)

# Documentation

The documentation of HaDes-V+, grouped by what you want to do. The [README](../README.md) gives the overview and the quick start. The figures that the documentation quotes are recorded under [results/](../results/README.md), whose index names the record of each one and the few approximate or unrecorded ones.

**Contents**

1. [Get Started](#get-started), with the [first commands](#first-commands)
2. [Use It](#use-it)
3. [Understand It](#understand-it)
4. [Check the Evidence](#check-the-evidence)

## Get Started

| Document | Contents |
|---|---|
| [docs/BUILDING.md](BUILDING.md) | Tools, build targets, waveforms, synthesis and timing, the screenshots, repository structure |
| [docs/FREERTOS.md](FREERTOS.md) | Running FreeRTOS: setup, the programs, comparison with the golden CPU, the stress campaign, writing a program, all settings, the files, troubleshooting, how the port works |

### First Commands

Every command runs from the repository root; the first run of each builds what it needs.

```bash
make freertos-shell                  # the interactive shell (guide: docs/SHELL.md)
make freertos-shell APP=loader       # the shell that loads and runs apps (guide: docs/APPS.md)
make test/asm/ops                    # every RV32I instruction, self-checking
make test/c/m_extension              # M hardware against libgcc's software routines
make test/sv/test_decode_exhaustive  # 11,026 checks against the golden Decode stage
make freertos APP=minimal            # boot FreeRTOS (guide: docs/FREERTOS.md)
make freertos-stress                 # the differential campaign against the golden CPU
make ext-check                       # Zbb, Zbs, Zicond, Zbkb, Zbkx, Zknh against a C model of the ISA texts
make formal                          # formal proofs of the M and EXT units; tools: formal/README.md
make check-results                   # re-run the recorded results and compare (results/README.md)
make synthesis                       # implement for the Basys3 (needs Vivado)
make help                            # the main targets and their settings
```

## Use It

| Document | Contents |
|---|---|
| [docs/SHELL.md](SHELL.md) | The interactive FreeRTOS shell: starting it, the commands, line editing, a terminal program on a pseudo-terminal, scripted sessions and their tests, settings, how it works, adding a command |
| [docs/APPS.md](APPS.md) | Programs built on the host and run from the shell: loading them by name, the example apps, the commands, writing an app with the SDK, the app API, sending files, the memory layout, what is contained, the tests |
| [test/freertos/sdk/README.md](../test/freertos/sdk/README.md) | The app SDK in brief: its files and make targets |

## Understand It

| Document | Contents |
|---|---|
| [docs/ARCHITECTURE.md](ARCHITECTURE.md) | The core: instruction set, pipeline, hazards; memory map, Wishbone fabric, peripherals, clocks; software runtime; the reference-library flow and the upstream course material |
| [docs/EXTENSIONS.md](EXTENSIONS.md) | M, Zba, Zicntr, Zifencei, the branch predictor, Zbb and Zbs (with Zba the B extension), Zicond, Zbkb, Zbkx and Zknh, and the claims of Zihintpause, Zihintntl, Zmmul and Zkt: design, verification, implementation notes; at the top, an overview of what HaDes-V+ adds and of its fixes to the upstream design |
| [test/freertos/loader/SPEC.md](../test/freertos/loader/SPEC.md) | The specification of the app loader: image format, load protocol, console pacing, run semantics, test plan |
| [test/freertos/README.md](../test/freertos/README.md) | The FreeRTOS programs and the differential campaign in depth |
| [third_party/freertos/README.md](../third_party/freertos/README.md) | Provenance and licence of the vendored FreeRTOS sources |

## Check the Evidence

| Document | Contents |
|---|---|
| [docs/VERIFICATION.md](VERIFICATION.md) | Approach, every self-checking suite with its result, test hierarchy, trap sweep, FreeRTOS campaigns, formal proofs, mutation testing, known divergences; at the top, the results at a glance |
| [results/README.md](../results/README.md) | The records of the figures quoted in the documentation, and how to re-run them |
| [formal/README.md](../formal/README.md) | The formal proofs of the multiply/divide unit and of the Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh unit in full |
| [test/trapsweep/README.md](../test/trapsweep/README.md) | The interrupt-offset sweeps and the independent ISA model |
| [test/bench/README.md](../test/bench/README.md) | The measurement programs behind the Zba, Zbb, SHA-256, M-unit and `FENCE.I` figures |
| [test/ext/README.md](../test/ext/README.md) | The reference models of Zbb, Zbs, Zicond, Zbkb, Zbkx and Zknh and the check of the RTL against them (`make ext-check`, `make ext-exhaustive`) |
