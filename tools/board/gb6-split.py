#!/usr/bin/env python3
"""Per-subtest Top-Down from a gb6-trace.sh run: gb6-split.py <ts.log> <perf.csv> [Name=score,...]

Each subtest's window runs from its "Running" line to the next one's (the last to the single-core
pass's end), on the console's clock; perf's -I times are seconds from the trace's start line. A
10 s sample that straddles two windows is split between them by its overlap. With the scores (the
result page's single-core subtest scores), the spread splits into its two factors: score = K x IPC
x work per instruction, so against the geometric means, log(score) = log(IPC) + log(work per
instruction), the core's share and the instruction stream's.
"""
import collections, math, sys

ts_path, csv_path = sys.argv[1], sys.argv[2]
t0, marks = None, []
for l in open(ts_path, errors='replace'):
    p = l.rstrip('\n').split(' ', 1)
    if len(p) < 2:
        continue
    t, s = float(p[0]), p[1]
    if 'gb6 trace start' in s:
        t0 = t
    elif s.strip().startswith('Running '):
        marks.append((t - t0, s.strip()[len('Running '):]))
    elif 'single-core pass done' in s:
        marks.append((t - t0, None))
win = [(marks[i][1], marks[i][0], marks[i + 1][0]) for i in range(len(marks) - 1) if marks[i][1]][:16]

samp = collections.OrderedDict()
for l in open(csv_path):
    if l.startswith('#') or not l.strip():
        continue
    f = l.split(',')
    try:
        c = float(f[1])
    except ValueError:
        c = 0.0
    samp.setdefault(float(f[0]), {})[f[3]] = c
acc = {n: collections.Counter() for n, _, _ in win}
prev = 0.0
for t, ev in samp.items():
    for n, a, b in win:
        ov = min(t, b) - max(prev, a)
        if ov > 0:
            for e, c in ev.items():
                acc[n][e] += c * ov / (t - prev)
    prev = t

print('%-22s %6s %7s %7s %5s | %5s %5s %5s %5s | %5s %5s %5s %5s | %5s %5s %5s %5s %5s' % (
    'subtest', 'wall s', 'G insn', 'G cyc', 'IPC', 'disp', 'bs', 'fe', 'be', 'mem', 'rob', 'iq', 'rest',
    'Dfill', 'Imiss', 'cbr', 'jalr', 'rdw'))
ipc = {}
for n, a, b in win:
    c = acc[n]
    cyc, ins = c['cycles'], c['instructions']
    bs, fe, be = c['r0401'], c['r0407'], c['r0402']
    mem, rob, iq = c['r0403'], c['r0404'], c['r0405']
    k = ins / 1000
    ipc[n] = ins / cyc
    pc = lambda x: 100 * x / cyc
    print('%-22s %6.0f %7.1f %7.1f %5.2f | %5.1f %5.1f %5.1f %5.1f | %5.1f %5.1f %5.1f %5.1f | %5.2f %5.2f %5.2f %5.2f %5.1f' % (
        n, b - a, ins / 1e9, cyc / 1e9, ipc[n], pc(cyc - bs - fe - be), pc(bs), pc(fe), pc(be),
        pc(mem), pc(rob), pc(iq), pc(be - mem - rob - iq),
        c['r0102'] / k, c['r0112'] / k, c['r0006'] / k, c['r0007'] / k, c['r0317'] / k))
print('(% of cycles; Dfill, Imiss, cbr, jalr: D$ fills, I$ misses, conditional and jalr redirects per 1k '
      'instructions; rdw: restart-wait cycles per 1k instructions)')
if len(sys.argv) < 4:
    sys.exit(0)

S = {n: float(v) for n, v in (x.split('=') for x in sys.argv[3].split(','))}
W = {n: S[n] / ipc[n] for n in ipc}
gm = lambda d: math.exp(sum(math.log(v) for v in d.values()) / len(d))
gS, gI, gW = gm(S), gm(ipc), gm(W)
print('\n%-22s %5s %5s | %8s %7s %8s' % ('subtest', 'score', 'IPC', 'score/gm', 'IPC/gm', 'work/insn'))
for n in sorted(ipc, key=lambda n: S[n]):
    print('%-22s %5.0f %5.2f | %7.2fx %6.2fx %7.2fx' % (n, S[n], ipc[n], S[n] / gS, ipc[n] / gI, W[n] / gW))
print('best/worst: score %.0fx, IPC %.2fx, work per instruction %.1fx' % (
    max(S.values()) / min(S.values()), max(ipc.values()) / min(ipc.values()), max(W.values()) / min(W.values())))
