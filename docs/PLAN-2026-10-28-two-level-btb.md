# PLAN 2026-10-28: a small BTB in the predictor's loop, the big one behind it

Status: built and board-gated with L1 at 64 rows (section 5). Timing met at +0.001 ns; GB5 on the
4 GiB board -0.29% cycles against 7f8f5a94; ChaCha20 26.09 cycles an iteration (34.09).
Tommy (2026-10-28), on the fetch windows missing timing: *"If the loop is too long, make it shorter
=> shrink the BTB. Make up the loss with a second full L2 BTB, coming in with late corrections and
training the L1 BTB."* And: *"if this allows us opportunity to grow the L2 BTB from the size of the
current BTB, then we should take it."*

## 1. Why

The fetch windows (docs/PLAN-2026-10-27-fetch-window.md) run ChaCha20 at 25 cycles an iteration and
pass every lockstep, but nine builds missed 166.67 MHz: the best -0.065 ns after two physopt
passes, the others -0.30 to -0.83. Every census puts the frontend first, and the predictor's loop
leads it: the BTB's block RAM clock-to-out, the tag compares, the end pick, the next window's rows
and the route back to the address pins of 16 block RAMs spread over two columns -- 5.88 ns in
context, 60% of it route. Main's own loop meets with +0.004 ns at 12-13 levels; the windows'
per-bank rows (each bank reads its pair's row or the pair after's) put it over.

## 2. The design

**L1: the stream's predictor, in the loop.** Eight halfword banks of R rows and 2 skewed ways in
distributed RAM, keyed as the BTB is today (a CTI's last halfword; tag `btag`), each entry today's
entry plus the L2 way it mirrors. It is read at the START of the cycle, at rows computed from the
stream's registers (`sa_q`, `sk_q`: bank b reads its pair's row or the pair after's), so the loop
is: the stream's registers -> the rows -> the distributed RAM's read -> the hits and the end pick
-> the next address -> the stream's registers. The next window's rows, the first-pair masks and the
skewed rows of every target (today's `rr0`, `rr1`, `rfp`, `mtk`, `t0`, `t1`) leave the loop
entirely. The marks, the window's end, the next address and the queue entries are L1's, as today's
are the BTB's.

**L2: today's BTB, 8K entries, out of the loop.** The same eight banks and 2 skewed ways in block
RAM, `BTBB` 11 -> 13 (512 rows a bank and way: the 16 block RAMs today hold 128 of their 512 rows).
It reads at the same rows in the same cycle, so its entries arrive a cycle later, when the same end
pick (a second instance, with the window's registers delayed a cycle) gives L2's view of the window:
its last position and its next address. They are compared with L1's, registered, and the verdict
acts the cycle after: two cycles behind the window.

**A correction** when the views differ (L1 lacks a taken CTI L2 has, ends elsewhere, or has a stale
entry):
- L1 is filled from L2 at that window: each bank L2 hit takes L2's entry; a bank where only L1 hit
  is cleared.
- The stream restarts at the window's own start with the history, RAS pointer and queue tail it had
  before the window, so the window is looked up again, now with L1 filled: three cycles.
- The ring drops that window's request and the one after it, keeping everything older: a FIFO of the
  requests in flight, each with its halfword count and a kill bit (answers come back in order, and
  an older request may still be waiting on a miss), so the reservation gives back the killed ones'
  halfwords and their answers are not written.
- A window that differs only in a not-taken mark L1 lacks is not corrected: L1 is filled, and the
  conditional goes unpredicted once (it falls through, as a BTB miss does today).

**Training** writes L2 as today (the details carry L2's way from the L1 entry), and L1 at the CTI's
own slot (the carried L1 way on a hit, a rotating way on an allocation).

## 3. Sizing (the L1BTB-SIM line of the Linux bench)

Shadow L1s of 8 to 64 rows a bank, 1 and 2 ways, beside today's BTB: each window's marked CTIs are
looked up and filled; a window ending at a taken CTI a shadow lacks is a correction.

| run | windows | taken ends | 16x2 | 32x2 | 64x2 |
|---|---|---|---|---|---|
| 20 M boot (lockstep) | 7,639,156 | 3,318,665 | 144,320 (4.3%) | 90,105 (2.7%) | 55,462 (1.7%) |
| GB5 SimPoints, 2K L2 (77 points, weighted) | 48.87 G taken ends | | 2.162 G (4.4%) | 1.199 G (2.5%) | 0.581 G (1.2%) |

Charged three cycles a correction with nothing hidden by the ring, that is 1.67%, 0.93% and 0.45% of
the single-core section's cycles; SQLite, Clang, HTML5 and Text Rendering carry most of it. The real
two levels on the same SimPoints, against the one-level predictor (2K in the loop):

| configuration | single-core cycles | SQLite | Clang |
|---|---|---|---|
| one level, 8K entries in the loop (does not close timing) | -0.49% | -1.47% | -17.10% |
| two levels, L1 32 rows | +0.21% | +9.90% | -9.66% |
| two levels, L1 64 rows | -0.03% | +5.44% | -11.51% |

## 4. Steps (all done)

1. The end pick becomes a module, instantiated once (cycle-identical).
2. L2 at 8K entries (`BTBB` 13): its own GB5 SimPoint price.
3. L1, the L2 stage, the correction and the ring's partial rollback; lockstep, ChaCha20, SimPoints.
4. The predictor out of context, then a build.

## 5. Outcome

- The first build hung every userspace lockstep at 22,327,587 retires: one window corrected every
  three cycles, L1 first-matching a stale copy in a way before L2's (L1's rows are not L2's, so an L2
  eviction can leave L1's copy). A fill now clears every other way that matched.
- The two-level builds came in at -0.05 to -0.4 ns after physopt, the frontend down to a third of
  the failing endpoints; the largest single family was the D$ response's wake chained through the
  scheduler's pick into wake-at-select. Reading wake-at-select the cycle after the issue removed it,
  cycle-identically.
- Built with ExtraNetDelay_high (-0.007 ns after two physopt passes), then the 46 failing paths'
  319 nets re-routed for delay and optimized again: +0.001 ns. The 4 GiB board's gate passes;
  ChaCha20 runs 26.09 cycles an iteration with its loop 6 bytes into a pair, as aligned code does;
  GB5 948.01 G cycles (IPC 1.338), -0.29% against 7f8f5a94.
