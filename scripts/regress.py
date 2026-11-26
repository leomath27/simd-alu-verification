#!/usr/bin/env python3
"""Run the clean-RTL regression over many seeds and summarise."""
import concurrent.futures as cf, pathlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parent.parent
exe = ROOT / "build/sim/Vtb_top"
if not exe.exists(): subprocess.run(["make", "sim"], cwd=ROOT, check=True, capture_output=True)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20

def run(seed):
    o = subprocess.run([str(exe), f"+seed={seed}", "+cycles=6000", "+quiet"], capture_output=True, text=True).stdout
    g = lambda p: int(re.search(p, o).group(1))
    cov = float(re.search(r"TOTAL functional coverage\s*:\s*\d+ / \d+ bins\s*\(\s*([\d.]+)%", o).group(1))
    return seed, "RESULT: PASS" in o, g(r"transactions accepted\s*:\s*(\d+)"), g(r"outputs checked\s*:\s*(\d+)"), cov

with cf.ThreadPoolExecutor() as ex: res = list(ex.map(run, range(1, N + 1)))
tot_t = sum(r[2] for r in res); tot_c = sum(r[3] for r in res)
lines = ["| seed | result | txns accepted | outputs checked | func. coverage |", "|---|---|---|---|---|"]
lines += [f"| {s} | {'PASS' if p else 'FAIL'} | {t} | {c} | {cv:.1f}% |" for s, p, t, c, cv in res]
lines += ["", f"**{sum(r[1] for r in res)}/{N} seeds pass - {tot_t:,} transactions, {tot_c:,} outputs checked against the reference model.**"]
rep = "\n".join(lines); print(rep)
(ROOT / "results" / "regression_report.md").write_text(rep + "\n")
sys.exit(0 if all(r[1] for r in res) else 1)
