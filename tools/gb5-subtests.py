#!/usr/bin/env python3
"""Per-subtest counts from a Geekbench 5 run under tools/board/gb5-run.sh with IV=<ms>.

    IV=1000 /var/tmp/gb5-run.sh <rtl>                      # on the board: perf stat -I 1000
    tools/gb5-subtests.py gb5-<rtl>-perf.txt gb5-<rtl>-ts.log [--min-seconds 20]

The perf file holds one block of counts per interval, each line `<seconds> <count> <event>`
after a `# started on <date>` header (the board's clock is UTC); the ts log stamps every line
Geekbench prints with its epoch. Each "Running X" line opens a window that the next one closes,
and the intervals that end inside a window are summed into it. Every event is printed as a
share of the window's cycles when it counts cycles (the top-down, stall, frontend and memory
cycle events), else per 1000 instructions; docs/smolrv64-perf-events.json names them.
"""
import argparse, calendar, json, os, re, sys, time
from collections import defaultdict

ap = argparse.ArgumentParser()
ap.add_argument("perf"); ap.add_argument("ts")
ap.add_argument("--min-seconds", type=float, default=20.0)
a = ap.parse_args()

here = os.path.dirname(os.path.abspath(__file__))
names = {}
for path in (os.path.join(here, "..", "docs", "smolrv64-perf-events.json"), os.path.join(here, "smolrv64-perf-events.json")):
    if os.path.exists(path):
        names = {"r%04x" % int(e["EventCode"], 16): e["EventName"] for e in json.load(open(path))}
        break
CYCLE_EVENTS = ("TD_", "TDK_", "ST_", "FE_", "RD_WAIT", "DT_WALK", "MEM_HITSER", "MEM_STDOOR",
                "MEM_ALIAS", "MEM_DEVWAIT")

start, samples = None, defaultdict(dict)
for line in open(a.perf, errors="replace"):
    if line.startswith("# started on"):
        start = calendar.timegm(time.strptime(line[len("# started on"):].strip(), "%a %b %d %H:%M:%S %Y"))
        continue
    m = re.match(r"\s*([\d.]+)\s+([\d,]+)\s+(\S+)", line)
    if m and start is not None:
        ev = m.group(3)
        samples[start + float(m.group(1))][names.get(ev, ev)] = int(m.group(2).replace(",", ""))
if not samples:
    sys.exit("no interval counts in %s: was the run made with IV=<ms>?" % a.perf)
times = sorted(samples)

section, windows = None, []
for line in open(a.ts, errors="replace"):
    m = re.match(r"(\d+(?:\.\d+)?)\s+(.*)$", line.rstrip("\n"))
    if not m: continue
    t, txt = float(m.group(1)), m.group(2).strip()
    if txt in ("Single-Core", "Multi-Core"): section = txt[:2]
    elif txt.startswith("Running "):
        if windows and windows[-1][2] is None: windows[-1][2] = t
        windows.append(["%s %s" % (section or "??", txt[8:]), t, None])
    elif windows and windows[-1][2] is None and (txt.startswith("Uploading") or txt.startswith("Benchmark Summary")):
        windows[-1][2] = t
if windows and windows[-1][2] is None: windows[-1][2] = times[-1]

events = sorted({e for t in times for e in samples[t]} - {"cycles", "instructions"})
cyc_ev = [e for e in events if e.startswith(CYCLE_EVENTS)]
cnt_ev = [e for e in events if e not in cyc_ev]
hdr = "%-26s %6s %6s" % ("subtest", "secs", "IPC") + "".join(" %12s" % (e[:12] + "%") for e in cyc_ev) \
      + "".join(" %12s" % (e[:10] + "/K") for e in cnt_ev)
print(hdr)
for name, t0, t1 in windows:
    if t1 - t0 < a.min_seconds: continue
    tot = defaultdict(int)
    for t in times:
        if t0 < t <= t1:
            for k, v in samples[t].items(): tot[k] += v
    cyc, ins = tot["cycles"], tot["instructions"]
    if not cyc or not ins: continue
    print("%-26s %6.0f %6.3f" % (name, t1 - t0, ins / cyc)
          + "".join(" %12.2f" % (100.0 * tot[e] / cyc) for e in cyc_ev)
          + "".join(" %12.3f" % (1000.0 * tot[e] / ins) for e in cnt_ev))
