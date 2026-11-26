#!/usr/bin/env python3
"""Mutation check: build the DUT with one injected RTL bug at a time and confirm the
testbench (scoreboard and/or SVA) catches it.  Also reruns every mutant with +nobias
(pure uniform-random operands) to show what the corner-biased generator buys."""
import concurrent.futures as cf, os, re, subprocess, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = "rtl/simd_defs_pkg.sv tb/simd_tb_pkg.sv rtl/simd_lane.sv rtl/simd_alu.sv sva/simd_alu_sva.sv tb/tb_top.sv".split()
FLAGS = "--binary --timing --assert -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY --top-module tb_top -O1".split()

MUTANTS = [
 ("BUG_CARRY16",     "segmented adder: 16-bit lane mask wrong (carry crosses lanes)"),
 ("BUG_ADDU_SAT",    "ADDU 16-bit saturates to 0x7FFF instead of 0xFFFF"),
 ("BUG_SAR32",       "SAR on 32-bit lanes is logical, not arithmetic"),
 ("BUG_MINS8",       "MINS on 8-bit lanes uses unsigned compare"),
 ("BUG_ABSD_SGN",    "ABSDU on 8-bit lanes uses signed compare"),
 ("BUG_CMPGT16",     "CMPGT on 16-bit lanes returns 1 instead of all-ones mask"),
 ("BUG_SHAMT8",      "8-bit shift amount not wrapped mod 8 (uses b[3:0])"),
 ("BUG_OVF64",       "ADD overflow flag missing for 64-bit lane"),
 ("BUG_ILLEGAL",     "opcode 19 executes as ADD, illegal flag not raised"),
 ("BUG_STALL",       "result register keeps updating while stalled"),
 ("BUG_STALL_ACCEPT","pipeline accepts an instruction while stalled"),
 ("BUG_RST",         "reset does not clear stage-1 valid (stale instruction survives reset)"),
 ("BUG_CORNER",      "64-bit ADDS of MIN+MIN wraps to 0 instead of saturating (rare corner)"),
]

def sh(cmd, cwd=ROOT, **kw):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, **kw)

def parse(out):
    d = {}
    m = re.search(r"scoreboard errors\s*:\s*(\d+)", out); d["sb"] = int(m.group(1)) if m else -1
    m = re.search(r"SVA failures\s*:\s*(\d+)", out);      d["sva"] = int(m.group(1)) if m else -1
    d["sva_names"] = re.findall(r"\[SVA FAIL\] (\w+)", out)
    d["pass"] = "RESULT: PASS" in out
    m = re.search(r"cycles=(\d+)", out); d["cycles"] = int(m.group(1)) if m else 0
    return d

def build_and_run(name):
    mdir = ROOT / "build" / f"mut_{name}"
    r = sh(["verilator", *FLAGS, f"-D{name}", "-Mdir", str(mdir), *SRC])
    if r.returncode: return name, None, None, r.stderr[-500:]
    outs = []
    for extra in ([], ["+nobias"]):
        r = sh([str(mdir / "Vtb_top"), "+seed=1", "+cycles=6000", "+quiet", *extra])
        outs.append(parse(r.stdout))
    return name, outs[0], outs[1], ""

def how(d):
    if d["pass"]: return "MISSED"
    parts = []
    if d["sb"]:  parts.append("scoreboard")
    if d["sva"]: parts.append("SVA")
    return "+".join(parts)

def main():
    (ROOT / "build").mkdir(exist_ok=True)
    # sanity: clean RTL must pass
    r = sh(["verilator", *FLAGS, "-Mdir", "build/mut_CLEAN", *SRC]); assert r.returncode == 0, r.stderr[-800:]
    clean = parse(sh(["build/mut_CLEAN/Vtb_top", "+seed=1", "+cycles=6000", "+quiet"]).stdout)
    assert clean["pass"], "clean RTL does not pass"
    rows = []
    with cf.ThreadPoolExecutor(max_workers=max(2, (os.cpu_count() or 2))) as ex:
        for res in ex.map(build_and_run, [m[0] for m in MUTANTS]):
            rows.append(res)
    desc = dict(MUTANTS)
    lines = ["| # | Injected bug | Caught (corner-biased) | Caught (pure random) | First SVA that fired |",
             "|---|---|---|---|---|"]
    caught = caught_nb = 0
    for i, (name, b, nb, err) in enumerate(rows, 1):
        if b is None:
            lines.append(f"| {i} | {desc[name]} | BUILD ERROR {err!r} | | |"); continue
        cb, cn = how(b), how(nb)
        caught += cb != "MISSED"; caught_nb += cn != "MISSED"
        lines.append(f"| {i} | {desc[name]} | {cb} | {cn} | {', '.join(b['sva_names'][:2]) or '-'} |")
    lines.append("")
    lines.append(f"**{caught}/{len(rows)} mutants caught with the corner-biased generator; "
                 f"{caught_nb}/{len(rows)} with pure uniform-random operands.** Clean RTL passes.")
    rep = "\n".join(lines)
    print(rep)
    (ROOT / "results" / "mutation_report.md").write_text(rep + "\n")
    sys.exit(0 if caught == len(rows) else 1)

if __name__ == "__main__":
    main()
