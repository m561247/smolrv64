# PLAN 2026-10-28: a small BTB in the predictor's loop, the big one behind it

Status: designed; L1 sized on the GB5 SimPoints (section 3); RTL on `wip/fwtrim`.
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
| GB5 SimPoints, 2K L2 | | | | | |
| GB5 SimPoints, 8K L2 | | | | | |

## 4. Steps

1. The end pick becomes a module, instantiated once (cycle-identical).
2. L2 at 8K entries (`BTBB` 13): its own GB5 SimPoint price.
3. L1, the L2 stage, the correction and the ring's partial rollback; lockstep, ChaCha20, SimPoints.
4. The predictor out of context, then a build.
