# FreeRTOS differential campaign: validate

| variant | seed | dut | golden |
|---|---|---|---|
| minimal.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 5.17M | PASS 5.17M |
| minimal.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 5.16M | PASS 5.16M |
| mzba.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 6.07M | PASS 6.07M |
| mzba.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 5.98M | PASS 5.98M |
| stress.noyield.rv32i.O0.p1s1.t10000.h4 | 0001 | PASS 5.22M | PASS 5.22M |
| stress.noyield.rv32i.O0.p1s1.t10000.h4 | 0002 | PASS 5.22M | PASS 5.21M |
| stress.noyield.rv32i.O2.p0s1.t10000.h4 | 0001 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.O2.p0s1.t10000.h4 | 0002 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.noyield.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 4.95M | PASS 4.95M |
| stress.noyield.rv32i.Os.p1s1.t5000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.noyield.rv32i.Os.p1s1.t5000.h4 | 0002 | PASS 4.96M | PASS 4.96M |
| stress.rv32i.O2.p1s1.t10000.h4 | 0001 | PASS 4.96M | PASS 4.96M |
| stress.rv32i.O2.p1s1.t10000.h4 | 0002 | PASS 4.96M | PASS 4.96M |

## Summary

| target | runs | PASS | FAIL | of which UART transcript only | HANG | CRASH | vs golden: runs with a golden twin | diverged |
|---|---|---|---|---|---|---|---|---|
| dut | 14 | 14 | 0 | 0 | 0 | 0 | 14 | 0 |
| golden | 14 | 14 | 0 | 0 | 0 | 0 | - | - |

### Failure signatures

### Verdict

- harness check: golden passed all 14 runs
- dut: 14/14 runs passed

(wall time 37 s; logs under $HADES_BUILD_DIR/freertos-campaign/validate)

CAMPAIGN RESULT: PASS (28 runs: 0 DUT run(s) not passed, 0 golden run(s) not passed, 0 build failure(s))
