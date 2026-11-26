# SIMD ALU - Constrained-Random Verification with Assertions

> **At a glance:** 20/20 seeds pass (1.6 M+ instructions checked) | **100% functional coverage** (3,272 bins) |
> **13/13 injected RTL bugs caught** | ~30 SVA properties (~330 generated instances) | open-source Verilator flow

**Highlights**
- Constrained-random, self-checking SystemVerilog testbench with an independent reference model and 18 stimulus phases.
- Bound SVA suite covering the pipeline handshake, stall/reset behavior and per-lane invariants (no carry leakage, saturation rails).
- Mutation harness showing corner-biased stimulus catches a 64-bit saturation corner that pure random misses.

Verification of a 64-bit, 2-stage pipelined **SIMD ALU** (8x8 / 4x16 / 2x32 / 1x64 lanes, 19 opcodes,
per-lane overflow/saturation flags, stall + synchronous reset) using a self-checking
**SystemVerilog constrained-random testbench**, an independent **reference model**, a bound
**SVA suite (~30 properties, ~330 generated assertion instances)**, hand-built **functional coverage**, and a
**mutation-testing harness**. Runs on open-source Verilator (no commercial simulator needed).

## Results (clean RTL)
| Metric | Result |
|---|---|
| Regression | **20/20 seeds pass** - 1.63 M instructions accepted, 1.62 M outputs checked vs. reference model |
| Functional coverage | **3272/3272 bins (100%)**: opcode x element-width (80), opcode x width x operand-class(a) x class(b) (2736), back-to-back opcode transitions (400), flag set/clear per op x width (48), pipeline scenarios (8) |
| Mutation testing | **13/13 injected RTL bugs caught** (the scoreboard and the SVA suite each flag all 13 independently) |
| Corner-bias value | A pure uniform-random run (no directed/corner phases) **misses 1/13** mutants: a 64-bit `MIN+MIN` saturation corner (probability ~2^-128 per instruction); caught by the corner-biased generator |

Full tables: `results/mutation_report.md`, `results/regression_report.md`, `results/sample_run_seed1.txt`.

## Architecture
```
 phased generator ──► driver ──► simd_alu (DUT) ──► monitor ──► scoreboard (FIFO + ref_model)
 (18 scenarios,         │             │ bind                         │      cycle-accurate valid model
  corner-biased        stall/reset    ▼                              └─► functional coverage
  operands, bubbles)   injection   simd_alu_sva (assertions)
```
* `rtl/simd_alu.sv` - segmented SWAR add/sub (carry kill at lane boundaries) + per-lane execute (`simd_lane.sv`).
* `tb/simd_tb_pkg.sv` - xorshift PRNG (reproducible across simulators), golden model (128-bit integer math per lane,
  deliberately a different formulation from the RTL), operand generators, coverage database.
* `tb/tb_top.sv` - driver, monitor, scoreboard, 18 stimulus phases (directed sweep, exhaustive class-cross sweep,
  corner-heavy, saturation, shifts, width thrash, bubbles, stall storms, illegal opcodes, reset mid-stream, ...).
* `sva/simd_alu_sva.sv` - `bind`-attached assertions: reset, accept/bubble/advance handshake, fixed 2-cycle
  latency, stall-hold of stage-1 and outputs, illegal-opcode decode, flag legality, and lane-level algebraic
  invariants (no carry leakage across lanes, saturation rails, min/max ordering, compare masks, shift-mod-width,
  overflow-flag equations) generated for every lane of every element width.
* `scripts/mutants.py` - builds the DUT 13 times with one injected bug each and checks the bench flags it.

## Run it
```
sudo apt install verilator g++ make python3     # Verilator >= 5.020
make sim SEED=7            # one run + coverage report
make regress               # 20 seeds in parallel
make mutants               # mutation check (~4 min)
```
Plusargs: `+seed=N +cycles=N +nobias +quiet`.

## Design notes / honest limits
* Verilator has no `covergroup`, no UVM and no constraint solver, so coverage bins and "constraints" are hand-written
  (weighted generators with a deterministic PRNG). The structure ports directly to a UVM/covergroup flow.
* Verilator is 2-state: X-propagation checks are out of scope.
* `stall` freezes the whole pipe and inputs offered while stalled must be ignored (the bench deliberately offers
  instructions during stalls to check this).
