#!/usr/bin/env python3
"""The table of a tools/exp.sh experiment, against a baseline's when one is given.

    tools/exp-table.py ~/exp-results/<tag> [~/exp-results/<base>]

A run's log is <name>.log. The boot lockstep reports its retires at the cycle bound (more is
faster); a checkpoint slice reports the cycles its 50 M measured retires took (fewer is faster).
A run that did not end with rc=0, or whose lockstep diverged, prints FAIL instead of a number.
The SimPoint runs (SET=sp, named sp<checkpoint>) print as subtests instead: a subtest's cycles are
its instructions times its points' CPIs weighted (workloads/gb5/simpoints.txt).
"""
import os, re, sys

ORDER = ["boot60m", "dhry", "coremark", "pi450", "pi700", "pi950", "pi1150", "nav", "html5", "sqlite", "pdf", "camera"]
GROUPS = [("pi", ["pi450", "pi700", "pi950", "pi1150"]),
          ("GB5", ["nav", "html5", "sqlite", "pdf", "camera"])]

def read(d):
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not f.endswith(".log"): continue
        name, text = f[:-4], open(os.path.join(d, f), errors="replace").read()
        rc = re.findall(r"^rc=(\d+)", text, re.M)
        bad = (not rc or rc[-1] != "0") and not (name.startswith("boot") and "COSIM-PERF FAIL" in text)
        bad = bad or re.search(r"Diverg|%Fatal|BUILD FAILED", text) is not None
        m = re.search(r"MEASURE window: (\d+) retires in (\d+) cycles", text)
        b = re.findall(r"TIMEOUT after \d+ cycles \(retires=(\d+)", text)
        r = re.search(r"^mcycle = (\d+)|^Total ticks\s*: (\d+)", text, re.M)   # an rvbench's own count
        if r and name in ("dhry", "coremark"):
            bad = bad or "TOHOST exit=0 " not in text or re.search(r"ERROR! [a-z]+ crc", text) is not None
            out[name] = ("cycles", int(r.group(1) or r.group(2)), bad, 0)
        elif m: out[name] = ("cycles", int(m.group(2)), bad, int(m.group(1)))
        elif b: out[name] = ("retires", int(b[-1]), bad, 0)
        else: out[name] = ("?", None, True, 0)
    return out

SP = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "workloads", "gb5", "simpoints.txt")
def subtests(runs):   # {subtest: estimated cycles, or None when a point failed}, in the file's order
    rng, pts = {}, {}
    for line in open(SP):
        f = line.rstrip("\n").split("\t")
        if f[0] == "range": rng[f[1]] = int(f[3]) - int(f[2])
        elif f[0] == "point": pts.setdefault(f[1], []).append((float(f[3]), "sp" + f[4]))
    out = {}
    for t, ps in pts.items():
        if any(n not in runs or runs[n][2] or runs[n][0] != "cycles" for _, n in ps): out[t] = None; continue
        out[t] = rng[t] * sum(w * runs[n][1] / runs[n][3] for w, n in ps) / sum(w for w, _ in ps)
    return out

exp = read(sys.argv[1])
base = read(sys.argv[2]) if len(sys.argv) > 2 else {}
names = [n for n in ORDER if n in exp] + sorted(n for n in exp if n not in ORDER and not n.startswith("sp"))
print(f"{os.path.basename(sys.argv[1])}" + (f" against {os.path.basename(sys.argv[2])}" if base else ""))
print(f"{'run':10s} {'measure':8s} {'value':>14s} {'baseline':>14s} {'change':>8s}")
for n in names:
    kind, v, bad, _ = exp[n]
    if bad or v is None:
        print(f"{n:10s} {kind:8s} {'FAIL':>14s}"); continue
    bk, bv, bbad, _ = base.get(n, (None, None, True, 0))
    d = ""
    if bv and not bbad:
        pct = 100.0 * (v - bv) / bv
        d = f"{pct:+.2f}%"
    print(f"{n:10s} {kind:8s} {v:>14,} {(f'{bv:,}' if bv else ''):>14s} {d:>8s}")
for g, members in GROUPS:
    if all(m in exp and not exp[m][2] for m in members):
        tot = sum(exp[m][1] for m in members)
        line = f"{g + ' sum':10s} {'cycles':8s} {tot:>14,}"
        if all(m in base and not base[m][2] for m in members):
            bt = sum(base[m][1] for m in members)
            line += f" {bt:>14,} {100.0 * (tot - bt) / bt:+7.2f}%"
        print(line)
if any(n.startswith("sp") for n in exp):
    est, bst = subtests(exp), subtests(base) if base else {}
    print(f"{'subtest':22s} {'cycles':>16s} {'baseline':>16s} {'change':>8s}")
    for t, c in est.items():
        if c is None: print(f"{t:22s} {'FAIL':>16s}"); continue
        b = bst.get(t)
        print(f"{t:22s} {c:>16,.0f} {(f'{b:,.0f}' if b else ''):>16s} {(f'{100.0 * (c - b) / b:+7.2f}%' if b else ''):>8s}")
    if all(c is not None for c in est.values()):
        tot = sum(est.values())
        line = f"{'single-core':22s} {tot:>16,.0f}"
        if bst and all(b is not None for b in bst.values()):
            bt = sum(bst.values()); line += f" {bt:>16,.0f} {100.0 * (tot - bt) / bt:+7.2f}%"
        print(line)
