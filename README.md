# APB Slave Verification: UVM + SV Assertions + Functional Coverage

A UVM testbench that verifies an APB slave (4 registers, wait states, error responses).
Contains constrained-random stimulus, a scoreboard with a register model, SystemVerilog
assertions (SVA) for the APB protocol, and functional coverage (covergroups + crosses).

## What is verified (the DUT)
`rtl/apb_slave.sv` - APB slave, 32-bit registers:

| Address | Register | Access | Notes |
|---|---|---|---|
| 0x00 | CTRL | RW | bits [1:0] = number of wait cycles the slave inserts (0-3) |
| 0x04 | DATA | RW | |
| 0x08 | STATUS | RO | low 8 bits = number of successful writes |
| 0x0C | SCRATCH | RW | |
| other | - | - | PSLVERR = 1 |

Writing STATUS also gives PSLVERR = 1 and changes nothing. Async active-low reset clears everything.

## Testbench structure
```
sequence -> sequencer -> driver -> [APB slave] -> monitor -> scoreboard
                                       |                  \-> coverage
                              SVA assertions (in apb_if)
```
| File | Content |
|---|---|
| `sva/apb_if.sv` | interface + 11 SVA assertions + cover properties |
| `tb/apb_pkg.sv` | UVM: item, driver, monitor, scoreboard, coverage, agent, env, sequences, tests |
| `tb/apb_tb_top.sv` | clock, DUT, interface, `run_test` |
| `verilator_check/` | plain-SV twin of the testbench (no UVM) + script that runs correct and buggy DUTs |

Tests: `apb_directed_test` (hand-written checklist), `apb_rand_test` (checklist + 1000 constrained-random transfers, random resets).

### SVA assertions
setup->access, PENABLE needs PSEL, signals stable during wait, PENABLE drops after transfer,
no X on control signals, PSLVERR only at transfer end, bad address -> PSLVERR,
write to RO register -> PSLVERR, valid access -> no PSLVERR, max 3 wait cycles, no X in response.

### Functional coverage
Coverpoints: address (6 bins incl. unaligned/out-of-map), direction, error response, wait cycles (0-3), write data corner values, reset.
Crosses: address x direction, address x error, direction x wait cycles.

## Bug injection
Each bug is switched on with one define (`-d BUG_xxx` on the `xvlog` line). All runs use `apb_rand_test` (directed checklist + 1000 constrained-random transfers), Vivado 2024.2 xsim, UVM 1.2.

| Define | Bug | Scoreboard errors | SVA failures | Result |
|---|---|---|---|---|
| (none) | correct DUT | 0 (2401 checks) | 0 | TEST PASSED |
| BUG_PREADY_EARLY | slave answers a cycle early at 3 wait states | 139 | 0 | TEST FAILED |
| BUG_NO_ERR_BAD_ADDR | no PSLVERR on bad address | 175 | 175 | TEST FAILED |
| BUG_NO_ERR_RO_WRITE | no PSLVERR on write to STATUS | 74 | 74 | TEST FAILED |
| BUG_READ_WRONG | SCRATCH read returns DATA | 113 | 0 | TEST FAILED |
| BUG_WRITE_IN_SETUP | write happens in setup phase | 138 | 0 | TEST FAILED |
| BUG_RESET_SCRATCH | reset does not clear SCRATCH | 32 | 2 | TEST FAILED |

All 6 bugs are caught. The two PSLVERR bugs are caught by both the assertions and the scoreboard.

## How to run in Vivado 2024.2 (xsim)
Command line (Vivado command prompt, in the project folder):
```
xvlog -sv -L uvm rtl/apb_slave.sv sva/apb_if.sv tb/apb_pkg.sv tb/apb_tb_top.sv
xelab -L uvm -timescale 1ns/1ps apb_tb_top -s sim -debug typical
xsim sim -runall -testplusarg UVM_TESTNAME=apb_rand_test
```
Use `UVM_TESTNAME=apb_directed_test` for the directed test. Add `-d BUG_READ_WRONG` to the `xvlog` line to inject a bug.

Vivado GUI: add the 4 files as simulation sources, set `apb_tb_top` as top, then
Settings -> Simulation -> Compilation: `xsim.compile.xvlog.more_options` = `-L uvm`,
Elaboration: `xsim.elaborate.xelab.more_options` = `-L uvm`; run, then click Run All.

Expected last lines: `SCOREBOARD: N checks, 0 errors`, `FUNCTIONAL COVERAGE: ...`, `SVA assertion failures: 0`, `TEST PASSED`.

## Results (correct DUT, Vivado 2024.2 xsim)
| Test | Checks | Errors | SVA failures | Functional coverage |
|---|---|---|---|---|
| apb_directed_test | 78 | 0 | 0 | 99.0% |
| apb_rand_test | 2401 | 0 | 0 | 100.0% |

Coverage notes: the cross `address x error` excludes impossible combinations with `ignore_bins`
(a bad address can never answer OK; CTRL/DATA/SCRATCH can never answer ERROR).
The directed test reaches 99.0% because it never writes to an unaligned address; the random test fills that bin.

## Verification status
- Everything above was run in Vivado 2024.2 xsim (UVM 1.2): DUT, 11 SVA assertions, scoreboard, covergroups, both tests, all 6 bug injections.
- `verilator_check/` is an earlier plain-SV twin testbench (no UVM) used for a first sanity check.
