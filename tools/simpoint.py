#!/usr/bin/env python3
"""Pick representative slices of a run from Simmerv's basic-block vectors (simmerv-cli --bbv).

    tools/simpoint.py <file.bbv> [--from N] [--to N] [--kmax 10] [--warm 20000000]

A line of the .bbv file is one interval: the retired count at its end, the instructions counted in
it, and its block vector projected to 15 dimensions (Simmerv projects; SimPoint's random projection,
done where the counts are). This normalises each vector by its instructions, runs k-means for
k = 1..kmax from several seeds, scores each k by the BIC and keeps the smallest k whose score
reaches 90% of the range (SimPoint 3's rule), and prints one point per cluster: the interval
nearest its centroid, its weight (the cluster's share of the instructions), and the checkpoint
to take for it -- `warm` instructions before the interval starts. The estimate of the whole
range's CPI is the weighted sum of the points' CPIs.

--from/--to keep the intervals ending inside [N, M] (a phase or a subtest, by retired count).
Pure Python: no numpy on the hosts, and thousands of 15-dimensional points do not need it.
"""
import argparse, math, random, sys

ap = argparse.ArgumentParser()
ap.add_argument("bbv")
ap.add_argument("--from", dest="lo", type=float, default=0)
ap.add_argument("--to", dest="hi", type=float, default=float("inf"))
ap.add_argument("--kmax", type=int, default=10)
ap.add_argument("--seeds", type=int, default=5)
ap.add_argument("--warm", type=int, default=20_000_000)
a = ap.parse_args()

ends, sizes, vecs = [], [], []
for line in open(a.bbv):
    f = line.split()
    end, n = int(f[0]), int(f[1])
    if not (a.lo <= end <= a.hi) or n == 0: continue
    ends.append(end); sizes.append(n); vecs.append([float(x) / n for x in f[2:]])
if not vecs: sys.exit("no intervals in range")
N, D = len(vecs), len(vecs[0])
every = max(1, round(sum(sizes) / N))

def dist2(p, q): return sum((x - y) * (x - y) for x, y in zip(p, q))

def kmeans(k, seed):
    rnd = random.Random(seed)
    cent = [vecs[i][:] for i in rnd.sample(range(N), k)]          # k distinct starting points
    assign = [0] * N
    for _ in range(100):
        moved = False
        for i, v in enumerate(vecs):
            j = min(range(k), key=lambda c: dist2(v, cent[c]))
            if j != assign[i]: assign[i] = j; moved = True
        for c in range(k):
            members = [vecs[i] for i in range(N) if assign[i] == c]
            if members: cent[c] = [sum(col) / len(members) for col in zip(*members)]
        if not moved: break
    sse = sum(dist2(vecs[i], cent[assign[i]]) for i in range(N))
    return sse, assign, cent

def bic(k, sse, assign):
    # SimPoint's BIC for spherical Gaussians with a shared variance (Pelleg and Moore's X-means)
    if N <= k: return -math.inf
    var = sse / (D * (N - k)) if sse > 0 else 1e-12
    ll = 0.0
    for c in range(k):
        n = sum(1 for x in assign if x == c)
        if n == 0: continue
        ll += n * math.log(n / N) - n * D / 2 * math.log(2 * math.pi * var) - (n - 1) * D / 2
    return ll - (k * (D + 1)) / 2 * math.log(N)

runs = {}
for k in range(1, min(a.kmax, N) + 1):
    runs[k] = min((kmeans(k, s) for s in range(a.seeds)), key=lambda r: r[0])
scores = {k: bic(k, r[0], r[1]) for k, r in runs.items()}
lo, hi = min(scores.values()), max(scores.values())
k = min(k for k, s in scores.items() if hi == lo or s >= lo + 0.9 * (hi - lo))
sse, assign, cent = runs[k]

total = sum(sizes)
print(f"# {N} intervals of ~{every:,} instructions ({ends[0] - sizes[0]:,} .. {ends[-1]:,}), k = {k}")
print("# start            weight   checkpoint")
pts = []
for c in range(k):
    members = [i for i in range(N) if assign[i] == c]
    if not members: continue
    rep = min(members, key=lambda i: dist2(vecs[i], cent[c]))
    w = sum(sizes[i] for i in members) / total
    start = ends[rep] - sizes[rep]
    pts.append((start, w))
for start, w in sorted(pts):
    print(f"{start:<16d} {w:8.5f}   {max(0, start - a.warm)}")
