#!/usr/bin/env python3
"""Turn `perf stat` output from the SmolRV64 core into a top-down breakdown or a CPI stack + MPKI.

TOP-DOWN (the `td` set, or any run with the TD_* events): the core charges every cycle to exactly
one of bad speculation (TD_BS), front-end (TD_FE), back-end (TD_BE) or dispatching (the rest), by
one classifier (smolrv64_core td_k, SmolRV64-Spec 11.2) -- the same one the simulator's TOPDOWN-SIM
prints -- so the four buckets are cycles by construction, and the depth events are subsets of
their parent. DPATCH (instructions dispatched) gives the slot view against IW x cycles. The TDK_*
events are td_k itself, one per TOPDOWN-SIM bucket: the tdbe set counts the back-end's ten causes
(they sum to TD_BE), the tdfe set bad speculation's and the front-end's and the dispatch width.

    tools/perf-smol.sh td   CMD 2>&1 | tools/perf-cpi-stack.py    # levels 1 and 2
    tools/perf-smol.sh tdbe CMD 2>&1 | tools/perf-cpi-stack.py    # the back-end's causes
    tools/perf-smol.sh tdfe CMD 2>&1 | tools/perf-cpi-stack.py    # bad speculation, front-end, width

The wait-cycle view below reads the ST_* events: they overlap (a cycle waits on several things
at once) and are depth, never a partition.

A dispatch stall is the queue head holding an instruction it has no credit for (hd_wait,
SmolRV64-Spec 3.2): ST_DSP and ST_ROB, and ST_IQ..ST_SRZ beneath ST_DSP, all describe the head.
ST_MUL and ST_DIV are occupancy (a multiply in flight in a lane, the MD stage holding a divide),
not stalls, and are reported apart. SmolRV64-Spec 11, "Reading the report", says what each line
points at.

Event names come from docs/smolrv64-perf-events.json, which tools/gen-perf-events.py
generates from src/csr_file.v and src/lint.sh verifies -- so this cannot drift from the
RTL.  Do not hardcode codes here.

Usage (13 programmable counters -- one set per run, never the union, see perf-smol.sh):
    tools/perf-smol.sh cpi CMD 2>&1 | tools/perf-cpi-stack.py     # the stack + ROB-full,
                                                                  # drain, redirects, D$ misses
    tools/perf-smol.sh br  CMD 2>&1 | tools/perf-cpi-stack.py     # redirects by cause
    tools/perf-smol.sh mem CMD 2>&1 | tools/perf-cpi-stack.py     # D$/I$ traffic, loads/stores
    tools/perf-cpi-stack.py saved-perf-output.txt
    tools/perf-cpi-stack.py --width 2 ...        # a narrower build than the shipping IW=3

The wait-cycle view's arithmetic: dispatch is WIDTH instructions per cycle (3, the shipping IW), so
    cycles = instructions/WIDTH + sum(wait cycles) + frontend bubbles + UNATTRIBUTED
and "unattributed" is what no event names, including every cycle that dispatches fewer than
WIDTH. A run with only the FE_* events names no back-end wait: every one lands in unattributed,
and the tool says so. The wait events overlap (a cycle blocked on a load AND on ROB space counts
in both), so a negative unattributed is overlap, not an error.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
# This script is meant to be COPIED to the board, where there is no repo and no ../docs.
# Search, in order: an explicit override, next to the script (copy the .json along with
# it), the repo layout, and the cwd.  Never fall back to a built-in table -- a silently
# stale event map is exactly what this file exists to prevent.
CANDIDATES = [os.environ.get("SMOLRV_PERF_EVENTS"),
              os.path.join(HERE, "smolrv64-perf-events.json"),
              os.path.join(HERE, "..", "docs", "smolrv64-perf-events.json"),
              os.path.join(os.getcwd(), "smolrv64-perf-events.json")]

# The wait events (they overlap); ST_DIV and ST_MUL are occupancies, printed apart.
BACKEND = [("ST_MEM", "a head op in M, or a wait on an integer load"), ("ST_FPU", "stage F held, or a wait on an FP result"),
           ("ST_DSP", "queue head without a credit (scheduler / rename / queues / serializing)"),
           ("ST_ROB", "queue head without ROB room")]
OCCUPANCY = [("ST_DIV", "a divide in the MD stage"), ("ST_MUL", "a multiply in flight in a lane")]
# ST_IQ..ST_SRZ are the disjoint parts of ST_DSP (the `hold` set): a breakdown underneath it.
DSP_SUB = [("ST_IQ", "lane A's scheduler, the FP queue, the head-op register or the divide credit"),
           ("ST_RN", "rename: a shard below LOWAT"),
           ("ST_SQ", "no store-queue credit"), ("ST_LQ", "no load-queue credit"),
           ("ST_SRZ", "serialising, a CSR op or a CBO waiting")]
# The memory events: cycle counts printed as shares of all cycles (they overlap ST_MEM and each
# other), the per-1k counts, the mean queue occupancies, and the fast-load latency.
MEM_SUB = [("MEM_HITSER", "a ready load the LSU port did not take"),
           ("MEM_STDOOR", "a write at the D$ door with no room"),
           ("MEM_ALIAS_UNK", "load blocked: an older store's address unknown"),
           ("MEM_ALIAS_OVL", "load blocked: a known older store overlaps"),
           ("MEM_DEVWAIT", "a device load waiting for the head"),
           ("DT_WALK", "dMMU walker busy (second level or walk)")]
MEM_CNT = [("MEM_REORD", "loads taken with an older store live"),
           ("MEM_WPKILL", "load landings dropped by a kill")]
FE_SUB  = [("FE_MMU", "iMMU cannot translate"), ("FE_IC", "no fetch bytes"),
           ("FE_ALN", "bytes, but no whole instruction"), ("FE_QUE", "an instruction not yet in the IR")]
REDIR_SUB = [("RED_BR", "conditional branch"), ("RED_JLR", "indirect jump (jalr)"),
             ("RED_TRP", "exception / interrupt / fault / replay")]
# td_k's causes (TDK_*), under their level-1 parent; each parent's list is all of its causes.
TDK = {"bad speculation": [("TDK_REDIRECT", "a redirect"), ("TDK_DRAIN", "a resolved restart waiting")],
       "front-end": [("TDK_FE_IMMU", "the iMMU"), ("TDK_FE_ICACHE", "no fetch bytes"),
                     ("TDK_FE_ALIGN", "bytes, no whole instruction"), ("TDK_FE_QUEUE", "an instruction not yet in the IR")],
       "back-end": [("TDK_BE_MMEM", "M holds a head op"), ("TDK_BE_ROB", "no ROB room"),
                    ("TDK_BE_DEPLD", "a wait on an integer load / AMO / CSR read"),
                    ("TDK_BE_DEPFP", "a wait on an FP / FP-load / divide result"),
                    ("TDK_BE_IQ", "no scheduler credit"), ("TDK_BE_RN", "rename below LOWAT"),
                    ("TDK_BE_SQ", "no store-queue credit"), ("TDK_BE_LQ", "no load-queue credit"),
                    ("TDK_BE_SER", "serialising / CSR / CBO"), ("TDK_BE_HELD", "the IR held after a redirect or resteer")],
       "dispatching": [("TDK_OK1", "1 instruction"), ("TDK_OK2", "2"), ("TDK_OK3", "3"), ("TDK_OK4", "4")]}

def load_names():
    path = next((p for p in CANDIDATES if p and os.path.exists(p)), None)
    if path is None:
        sys.exit("error: smolrv64-perf-events.json not found. Copy it next to this script,\n"
                 "       or set SMOLRV_PERF_EVENTS=/path/to/smolrv64-perf-events.json.\n"
                 "       Looked in: %s" % ", ".join(p for p in CANDIDATES if p))
    with open(path) as f:
        cat = json.load(f)
    # "0x0300" -> "r0300", matching how perf echoes a raw event back
    return {"r%04x" % int(e["EventCode"], 16): e["EventName"] for e in cat}

def parse(text, names):
    """Pull counts out of perf's columnar output, and each event's trailing multiplex
    percentage.  Tolerates thousands separators, '<not counted>' and '<not supported>'."""
    vals, unknown, mux = {}, [], {}
    for line in text.splitlines():
        pm = re.search(r"\((\d[\d.]*)%\)\s*$", line)     # the multiplex share ends the line
        line = line.split("#")[0]                      # drop perf's derived-metric comment
        m = re.match(r"\s*([\d,.]+|<[^>]+>)\s+([A-Za-z_][\w.:-]*)\s*(\(\d[\d.]*%\))?\s*$", line)
        if not m:
            continue
        raw, ev = m.group(1), m.group(2)
        if pm:
            mux[ev] = float(pm.group(1))
        if raw.startswith("<"):
            vals[ev] = None
            continue
        if "seconds" in ev:
            continue
        n = int(raw.replace(",", "").split(".")[0])
        key = {"cycles": "CYCLES", "instructions": "INSTRET"}.get(ev) or names.get(ev.lower())
        if key is None:
            unknown.append(ev); continue
        vals[key] = n
    return vals, unknown, mux

def topdown(v, width):
    """The closing top-down report. Returns False if the run has no TD_* events."""
    if v.get("TD_BE") is None or v.get("TD_FE") is None or v.get("TD_BS") is None:
        return False
    g = lambda k: (v.get(k) or 0)
    cyc, ins = g("CYCLES"), g("INSTRET")
    bs, fe, be = g("TD_BS"), g("TD_FE"), g("TD_BE")
    disp = cyc - bs - fe - be
    pc = lambda n: 100.0 * n / cyc
    print("  cycles %-16d instructions %-16d IPC %.3f   (%d-wide)" % (cyc, ins, ins / cyc, width))
    print("\n  TOP-DOWN, level 1 (every cycle charged to exactly one; SmolRV64-Spec 11.2)")
    for name, n in (("dispatching", disp), ("bad speculation", bs), ("front-end", fe), ("back-end", be)):
        print("    %-34s %6.2f%%" % (name, pc(n)))
    if disp < 0 or min(bs, fe, be) < 0:
        sys.exit("error: the level-1 buckets exceed the cycles -- the event map is wrong (docs/smolrv64-perf-events.json)")
    def sub(parent, rows):
        rest = parent
        for label, k in rows:
            if v.get(k) is not None:
                print("      %-32s %6.2f%%" % ("- " + label, pc(g(k))))
                rest -= g(k)
        if any(v.get(k) is not None for _, k in rows):
            print("      %-32s %6.2f%%" % ("- the rest", pc(rest)))
    tdk(v, {"bad speculation": bs, "front-end": fe, "back-end": be, "dispatching": disp}, pc)
    print("\n  level 2")
    print("    %-34s %6.2f%%" % ("bad speculation", pc(bs)))
    if v.get("RD_WAIT") is not None:
        drain = min(g("RD_WAIT"), bs)
        print("      %-32s %6.2f%%" % ("- a resolved restart waiting (drain)", pc(drain)))
        print("      %-32s %6.2f%%" % ("- the redirect itself", pc(bs - drain)))
    print("    %-34s %6.2f%%" % ("front-end", pc(fe)))
    sub(fe, [("latency: iMMU walk / no fetch bytes", "TD_FE_LAT")])
    print("    %-34s %6.2f%%" % ("back-end", pc(be)))
    sub(be, [("memory: a head op in M / an integer-load wait", "TD_BE_MEM"),
             ("no ROB room", "TD_BE_ROB"),
             ("no scheduler / load / store queue room", "TD_BE_IQ")])
    if v.get("DPATCH") is not None:
        slots = width * cyc
        print("\n  slots (%d x cycles)" % width)
        print("    %-34s %6.2f%%" % ("dispatched", 100.0 * g("DPATCH") / slots))
        print("    %-34s %6.2f%%" % ("retired", 100.0 * ins / slots))
        print("    %-34s %6.2f%%" % ("dispatched, squashed (wrong path)", 100.0 * (g("DPATCH") - ins) / slots))
    rows = [("conditional branch", "RED_BR"), ("indirect jump", "RED_JLR"), ("exception / interrupt / fault / replay", "RED_TRP"),
            ("D$ line fills", "DCMISS"), ("I$ misses", "ICMISS"), ("dMMU walker starts", "DTLB_MISS")]
    got = [(l, k) for l, k in rows if v.get(k) is not None]
    if got:
        print("\n  per 1000 instructions")
        for l, k in got:
            print("    %-34s %10.3f" % (l, 1000.0 * g(k) / ins))
    return True

def tdk(v, parents, pc):
    """td_k's causes under their level-1 parent, as far as the run counted them; a parent whose
    every cause was counted is checked to close (td_k is one cause per cycle)."""
    if not any(v.get(k) is not None for rows in TDK.values() for k, _ in rows):
        return
    print("\n  level 3 (td_k, the TOPDOWN-SIM buckets)")
    for parent, rows in TDK.items():
        got = [(k, l) for k, l in rows if v.get(k) is not None]
        if not got:
            continue
        print("    %-34s %6.2f%%" % (parent, pc(parents[parent])))
        for k, l in got:
            print("      %-32s %6.2f%%" % ("- " + l, pc(v[k])))
        if len(got) == len(rows):
            tot = sum(v[k] for k, _ in rows)
            if abs(tot - parents[parent]) > 0.001 * max(parents[parent], 1):
                print("      %-32s %6.2f%%   <-- does not close: %d counted, %d the parent"
                      % ("- the causes' sum", pc(tot), tot, parents[parent]))

def main():
    args, width = sys.argv[1:], 3
    if "--width" in args:
        i = args.index("--width"); width = int(args[i + 1]); del args[i:i + 2]
    text = open(args[0]).read() if args else sys.stdin.read()
    names = load_names()
    v, unknown, mux = parse(text, names)
    g = lambda k: (v.get(k) or 0)
    # The events of one set fit the PMU (cycle, instret and 13 counters), so a share under 100%
    # means another perf session held counters: the counts are scaled estimates and the
    # rotation's SBI calls slowed the run (a loop beside `perf stat -a`: -19%, instructions +9%).
    shared = [p for p in mux.values() if p < 98.0]
    if shared:
        print("  WARNING: %d events multiplexed (counted %.0f-%.0f%% of the run): every count is perf's\n"
              "  scaled estimate, and the run shared the PMU with another perf session -- not\n"
              "  comparable with an unshared run.\n" % (len(shared), min(shared), max(shared)))

    # FE_BUB is the sum of the FE_* causes.  perf-smol.sh's "cpi" set omits it to stay
    # inside 13 counters, so reconstruct it rather than reporting a hole.
    if v.get("FE_BUB") is None and any(v.get(k) is not None for k, _ in FE_SUB):
        v["FE_BUB"] = sum(v.get(k) or 0 for k, _ in FE_SUB)
        v["_FE_BUB_DERIVED"] = True

    cyc, ins = g("CYCLES"), g("INSTRET")
    if not cyc or not ins:
        sys.exit("error: need both cycles and instructions; got %s" % sorted(v))
    if topdown(v, width):
        if unknown:
            print("\n  ignored unrecognised events: %s" % ", ".join(sorted(set(unknown))))
        return

    cpi, per_k = cyc / ins, lambda n: 1000.0 * n / ins
    fe_bub = g("FE_BUB")
    named  = sum(g(k) for k, _ in BACKEND) + fe_bub      # ST_DIV / ST_MUL are occupancies: not here
    floor  = ins / width                  # the dispatch floor: every cycle full
    unattr = cyc - floor - named          # cycles beyond the floor that nothing names
    no_backend = not any(v.get(k) is not None for k, _ in BACKEND)

    print("  cycles %-16d instructions %-16d IPC %.3f   CPI %.3f" % (cyc, ins, ins/cyc, cpi))
    print("  (the wait-cycle view: its events overlap, so it is depth, not a partition -- the td sets close)")
    print("\n  wait cycles per instruction (dispatch is %d per cycle, so %.3f is the floor)"
          % (width, 1.0 / width))
    print("    %-30s %10.3f  %5.1f%%" % ("dispatch floor (%d per cycle)" % width, 1.0 / width, 100.0*floor/cyc))
    for k, label in BACKEND:
        if v.get(k) is not None and g(k):
            print("    %-30s %10.3f  %5.1f%%" % ("stall: " + label, g(k)/ins, 100.0*g(k)/cyc))
            # the memory events sit beside ST_MEM, not inside it: each is its own condition
            if k == "ST_MEM" and any(v.get(kk) is not None for kk, _ in MEM_SUB + MEM_CNT + [("MEM_LDINFL", "")]):
                for kk, ll in MEM_SUB:
                    if v.get(kk) is not None:
                        print("      %-28s %10.3f  %5.1f%%" % ("~ " + ll, g(kk)/ins, 100.0*g(kk)/cyc))
                if v.get("MEM_LDINFL") is not None:
                    print("      %-28s %10.2f loads" % ("~ mean fast loads in flight", g("MEM_LDINFL")/cyc))
                    if g("MEM_LDSENT"):
                        print("      %-28s %10.2f cycles" % ("~ mean fast-load latency", g("MEM_LDINFL")/g("MEM_LDSENT")))
                for kk, ll in MEM_CNT:
                    if v.get(kk) is not None:
                        print("      %-28s %10.3f per 1k insns" % ("~ " + ll, per_k(g(kk))))
                for kk, ll in (("MEM_LQOCC", "load queue"), ("MEM_SQOCC", "store queue")):
                    if v.get(kk) is not None:
                        print("      %-28s %10.2f entries" % ("~ mean %s occupancy" % ll, g(kk)/cyc))
            # ST_DSP's disjoint parts (the `hold` set): a breakdown, never added alongside it.
            if k == "ST_DSP" and any(v.get(kk) is not None for kk, _ in DSP_SUB):
                for kk, ll in DSP_SUB:
                    if g(kk):
                        print("      %-28s %10.3f  %5.1f%%" % ("- " + ll, g(kk)/ins, 100.0*g(kk)/cyc))
    for k, label in OCCUPANCY:
        if v.get(k) is not None:
            print("    %-30s %10.3f  %5.1f%%   (occupancy, not in the sum)" % (label, g(k)/ins, 100.0*g(k)/cyc))
    if fe_bub:
        tag = " (derived)" if v.get("_FE_BUB_DERIVED") else ""
        print("    %-30s %10.3f  %5.1f%%%s" % ("frontend bubble", fe_bub/ins, 100.0*fe_bub/cyc, tag))
        other = fe_bub - sum(g(k) for k, _ in FE_SUB)
        for k, label in FE_SUB:
            if g(k):
                print("      %-28s %10.3f  %5.1f%%" % ("- " + label, g(k)/ins, 100.0*g(k)/cyc))
        # FE_MMU + FE_IC + FE_ALN + FE_QUE = FE_BUB in the RTL: a remainder is a broken event map
        if abs(other) > 0.0005 * cyc:
            print("      %-28s %10.3f  %5.1f%%   <-- unattributed"
                  % ("- other", other/ins, 100.0*other/cyc))
    flag = ""
    if unattr > 0.005 * cyc:
        flag = ("   <-- no backend events in this run: use perf-smol.sh cpi" if no_backend
                else "   <-- a cause with no counter (or events dropped from the set)")
    elif unattr < -0.005 * cyc:
        flag = "   (events overlap: a cycle blocked on two units counts in both)"
    print("    %-30s %10.3f  %5.1f%%%s" % ("unattributed", unattr/ins, 100.0*unattr/cyc, flag))

    mpki = []
    if any(v.get(k) is not None for k, _ in REDIR_SUB):
        tot = g("REDIR")
        for k, label in REDIR_SUB:
            if v.get(k) is not None:
                mpki.append("    %-30s %10.3f" % ("redirect: " + label, per_k(g(k))))
        if tot:
            rest = tot - sum(g(k) for k, _ in REDIR_SUB)
            mpki.append("    %-30s %10.3f   (xRET, sfence.vma, CSR-write redirects, fence.i, jal)" % ("redirect: other", per_k(rest)))
    if v.get("RD_WAIT") is not None:
        # a mispredict's restart, from its resolve to its release or its squash at the head
        mpki.append("    %-30s %10.3f   (%.1f%% of cycles: a resolved mispredict's restart)"
                    % ("redirect drain, cycles/insn", g("RD_WAIT")/ins, 100.0*g("RD_WAIT")/cyc))
    if v.get("DTLB_MISS") is not None:
        per_walk = "" if not g("DTLB_MISS") or v.get("DT_WALK") is None else "     (%.1f busy cycles per start)" % (g("DT_WALK")/g("DTLB_MISS"))
        mpki.append("    %-30s %10.3f%s" % ("dMMU walker starts", per_k(g("DTLB_MISS")), per_walk))
    for code, label, acc in (("REDIR", "pipeline redirects", None),
                             ("DCMISS", "D$ line fills", "DCACC"),
                             ("ICMISS", "I$ misses", "ICACC")):
        if v.get(code) is None:
            continue
        rate = "" if not acc or not g(acc) else "     (%.3f%% of %s accesses)" % (
            100.0*g(code)/g(acc), acc[:2])
        mpki.append("    %-30s %10.3f%s" % (label, per_k(g(code)), rate))
    if mpki:
        print("\n  MPKI (per 1000 instructions)")
        print("\n".join(mpki))
    else:
        print("\n  MPKI: no redirect / miss / drain events in this run (perf-smol.sh cpi, br, mem)")

    for code, label in (("LOAD", "loads"), ("STORE", "stores")):
        if g(code):
            print("  %-8s %12d  (%.1f%% of instructions)" % (label, g(code), 100.0*g(code)/ins))
    if unknown:
        print("\n  ignored unrecognised events: %s" % ", ".join(sorted(set(unknown))))

main()
