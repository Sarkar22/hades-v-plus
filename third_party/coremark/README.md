# CoreMark — vendored third-party sources

This directory contains unmodified copies of the CPU benchmark [CoreMark](https://www.eembc.org/coremark/)
of the Embedded Microprocessor Benchmark Consortium (EEMBC). HaDes-V+ runs it with the port in
[`test/coremark/`](../../test/coremark) (guide: [test/coremark/README.md](../../test/coremark/README.md),
`make coremark`). The files are part of the repository so that a clone builds and runs the benchmark
without a download step.

These files are third-party software. They are not original work of the HaDes-V or HaDes-V+ authors.
They are distributed under their own licence (see [Licence](#licence)), not under the MIT licence of the
rest of the repository.

## Provenance

| Vendored as | Upstream repository | Pinned commit |
|---|---|---|
| `core_list_join.c`, `core_main.c`, `core_matrix.c`, `core_state.c`, `core_util.c`, `coremark.h`, `LICENSE.md` | [eembc/coremark](https://github.com/eembc/coremark) | [`1f483d5b8316753a742cbf5590caf5bd0a4e4777`](https://github.com/eembc/coremark/tree/1f483d5b8316753a742cbf5590caf5bd0a4e4777) (branch `main`, 2025-05-01, "Merge pull request #55 from DeflateAwning/main"; CoreMark 1.0) |

The file names and contents are those of the root of the upstream repository at that commit, its
licence file `LICENSE.md` included (see [Licence](#licence)). Not vendored: the porting examples (`barebones/`, `simple/` and the others, which the HaDes-V+ port does
not use), the documentation, the build files and `coremark.md5` (its entry for `coremark.h` does not
match the file at this commit).

## Licence

Upstream's licence file, included unchanged as [`LICENSE.md`](LICENSE.md), has two parts:

* The **CoreMark Acceptable Use Agreement** (lines 1 to 45), a licence of the CoreMark trademark. EEMBC
  grants a personal, non-exclusive, royalty-free, revocable right to use and display the trademark
  "solely and exclusively in connection with" benchmarking with the software (Article 1.1); the trademark
  may not be used "in connection with any use of a modified, derivative, or otherwise altered copy of
  the Software" (Article 1.2); the rights are "non-assignable, and may not be sublicensed" (Article 4.3).
  This agreement is between EEMBC and each user who wants to use the name.
* The **Apache License, Version 2.0**, which licenses the software itself, from line 47. Every source
  file carries the header "Copyright 2018 Embedded Microprocessor Benchmark Consortium (EEMBC) —
  Licensed under the Apache License, Version 2.0".

The Apache licence allows copying and redistribution in source and object form provided that the
recipient gets a copy of the licence (this directory has it) and that the notices are kept (the files
are unmodified). It is compatible with keeping the rest of the repository under the MIT licence: the
files here stay under their own licence, as the FreeRTOS sources do. The trademark agreement is personal
to the user it is made with and does not pass to those who copy the repository: anyone who wants to use the
name CoreMark for results has to accept it for themselves.

CoreMark's own rules (upstream `README.md`, "Run Rules" and "Reporting rules") apply to scores that are
reported as CoreMark results: the benchmark has to run for at least 10 seconds, the sources may not be
changed apart from `core_portme*`, and the result has to be reported in the stated form. A simulation
cannot run for 10 seconds, so nothing that HaDes-V+ prints is a CoreMark score; the documentation calls
the figures CoreMark/MHz **estimates**.

CoreMark is a trademark of EEMBC and EEMBC is a registered trademark of the Embedded Microprocessor
Benchmark Consortium.

## The files are unmodified

No vendored source file has been changed. [`MANIFEST`](MANIFEST) lists the SHA-256 checksum of every
vendored file; the git blob id of each vendored file, `LICENSE.md` included, equals the one of the same file in
the upstream repository at the pinned commit. To check the tree:

```bash
cd third_party/coremark && sha256sum -c MANIFEST
```

Everything specific to HaDes-V+ lives outside this directory: the port (`core_portme.c`,
`core_portme.h`), the build rules and the checker are in [`test/coremark/`](../../test/coremark).
`.gitattributes` disables end-of-line conversion for this directory, so a checkout on any platform
matches `MANIFEST`.
