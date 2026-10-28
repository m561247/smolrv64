# PLAN 2026-10-27: fetch 16 bytes at any halfword

Status: steps 1-3 on `wip/fwin`, with today's 64-byte ring and windows stopping only at the page.
Tommy (2026-10-27, on ChaCha's 25 cycles): *"I want the 25 cycle Chacha20 no matter what GB5
shows."* Tommy (2026-10-27), on the ChaCha pipe trace: *"What I would
have expected from the I$ was an odd and an even 128-bit (16B) bank, each with a tag read port, so
we can always fetch 16B regardless of alignment as long as the lines are present."*

## 1. Why

ChaCha20 (Tommy's `crypt.c`, 256 double rounds of 100 ops), lockstep on main (RTL 7f8f5a94).
The IW=4 lanes take the four quarter-round chains one each, and every op executes three cycles after
fetch. What is left is the frontend: the bundle register gets four ops three cycles in four.

| run | cycles per iteration | kernel | IPC |
|---|---|---|---|
| main, loop at `0x8000276c` (12 bytes into a pair) | 34.00 (9 `bytes-late`) | 8,919 | 2.88 |
| main, loop aligned to 16 bytes (`-falign-loops=16`) | **25.00** (4 ops in 3,187 of 3,200 cycles) | 6,643 | 3.86 |
| a 128-byte ring (`RS` 64), as built | 26.00 (one `bytes-late`) | 6,880 | 3.73 |
| **step 3's windows, the 64-byte ring** | **25.00** | 6,649 | 3.86 |
| step 3's windows and a 128-byte ring | 25.00 | 6,653 | 3.86 |

**The cause.** `rv_icache` reads one 16-byte-aligned pair a cycle, and alignment is left to the
64-byte fetch ring (`smolrv64_fring`). The ring asks for a pair only when it has room for a whole
one (`rg_resv <= RS - 8`). The I$ answers the next cycle, so at 16 bytes a cycle the reservation
round trip uses the ring exactly. When the stream is 12 bytes into a pair, every bundle spans two
pairs, and each pair's last 4 bytes wait a cycle for the next one. The reservation then overshoots
and every fourth request is skipped: 12 bytes a cycle. At IW=3, which takes at most 12 bytes a
cycle, it never showed.

**Two fixes, measured (§7).** Windows fix it with today's ring: every request is the next 16 bytes
of the stream, so after a taken branch the windows line up with the bundles, and ChaCha runs at the
aligned code's 25 cycles. A 128-byte ring instead gets to 26: the ring then holds enough to ride out
the straddles, and the one cycle left is the target's pair, which holds only the bytes after the
target.

## 2. Does the ring go? No: fetch at the PC does not close

An I$ that reads 16 bytes at any halfword invites deleting the ring: fetch at the PC, and take the
next PC from this cycle's answer (PC + consumed, or the predicted target). That deletes the ring, the
prediction queue, the stream address and the rejected-mark restarts. It also puts every one of these
into a one-cycle loop:

- the block RAM read and the tag compare;
- the way select;
- the 16:1 rotation;
- the start-bit scan;
- the BTB's marks;
- the aligner;
- the next-PC mux;
- the fan-out to about 50 block RAMs' addresses.

Measured out of context at 6.000 ns (`~/smolrv64-attic/2026-10-27/fetchpc/`; the shipped I$
geometry, `src/aligner.v` at IW=4, the predictor's 8 x 2 BTB banks): **WNS -0.948 ns**, 21 levels
(2.65 ns logic, 3.88 ns route), from the tag RAM through the compare, the hold-on-miss select and
the aligner to the RAMs' address. The data RAM's own path is -0.877. For comparison, the ring's loop
alone is +0.159 out of context and 0.000 in the full build, so this one would be worse integrated.

The ring therefore stays, for the two jobs that have nothing to do with alignment:
- **It covers the I$'s latency.** The next address goes out before this answer is aligned.
- **It holds what a bundle leaves.** Four 2- or 4-byte instructions take 8 to 16 bytes, while
  fetch brings 16.

What goes is the third job, alignment -- while the windows stay in step with the bundles. A
window that ends early (at a not-taken mark that is the M-th, or at its page's end) restarts the
stream where the cut left it while the bundles go on where they were, and then the 64-byte ring is
short again: the first version of step 3 stopped windows at every 2 KiB block and ran ChaCha at 31
cycles (§7). The GB5 SimPoints with and without the 128-byte ring say how often that matters.

## 3. The I$: even and odd 16-byte banks

**Data.** Each way has an **even bank** (pairs 0 and 2 of every line) and an **odd bank** (pairs 1 and
3). Each bank is 128 bits wide, with row = {set, pair[1]}, built from two 64-bit RAMs on one
address. `smolrv64_sdpram` refuses wider: a 128-bit bank once passed every simulation and fetched
garbage on the board. The bits are today's, but each 2,048-row RAM takes four 2K x 18 primitives,
so the data uses 32 RAMB36 where today's 4,096-row RAMs pack into 30 (step 1, out of context).

**A request** is a window: a halfword-aligned VA and its length *n* (1 to 8 halfwords; the tag
carries the end, as today's `p_end` does). Let *p* be the window's pair in its line:

| p | even bank row | odd bank row |
|---|---|---|
| 0 | {set, 0} (pair 0) | {set, 0} (pair 1) |
| 1 | {set, 1} (pair 2) | {set, 0} (pair 1) |
| 2 | {set, 1} (pair 2) | {set, 1} (pair 3) |
| 3 | **{set + 1, 0}** (the next line's pair 0) | {set, 1} (pair 3) |

Only the even bank ever reads the next line, and only when the window starts in pair 3.

**Tags.** The window's line is compared as today (port B of each way's tag RAM). **The next line's tag
is read through port A, the fill's.** A tag write never shares a cycle with a bank read (asserted
today, `e_col`), so port A is idle on every lookup cycle. Each way gets a second compare, against
the next line's virtual tag (VA[38:6] + 1, computed beside the request).

**The answer.**
- The even half takes its own line's hit way, and the odd half the window line's.
- The two pairs are put in stream order (the window's first pair, then the other parity's), and an
  **8:1 halfword rotation by VA[3:1]** gives the window.
- The ring then writes eight halfwords from its tail with no skip.

**Hit and miss.**
- A window hits when its line hits and, **only if it reaches the next line** (*p* = 3 and VA[3:1] + *n* > 8),
  the next line hits too: its valid bits are a second read of the valid arrays. A window cut before
  the line's end never misses on the next line, so it never fills a line nobody asked for.
- A miss fills the first of its lines that misses, and the request replays through today's skid
  and replay. The two lines are in different sets, so the second fill cannot evict the first. The
  next line's reconcile probe is a cycle later (`S_RCN`), through the lookup's own read of the
  physical tags, which is free while the door is shut: a second read port there cost 768 LUTs.
- The next line's physical address (for reconcile and the fill) is the request's PA plus 64. It
  never leaves the 4 KiB page: a window stops at its page's end.

Built (step 2), out of context at 6 ns: **+0.950 ns**, 4,325 LUTs (+650 over step 1: the second
compare and the rotation), 34 block RAM tiles, the tag RAMs one each (port A takes one address,
the fill's set or the next line's).

## 4. The stream: windows instead of pairs

The predictor's stream registers keep their names: `sa_q` is the window's first pair, `sk_q` the
window's first halfword in it. The window covers bank *b* in the first pair when *b* >= `sk_q`, else
in the pair after it (`sa16`).

- **The BTB.**
  - **Rows:** bank *b* reads row(p) or row(p+1), picked by a mask of the banks at or after the next
    window's offset. Today one row serves all eight banks of a way.
  - **row(p+1):** the BTB row is `a[10:4] ^ hash(a[17:11])`. For the window 16 bytes on, and for
    the halfword after a mark, both rows are `bslot` of sums of registers, so they are exact. For a
    target, the RAS top and a restart, row(p+1) is `(a[10:4] + 1) ^ hash(...)`. That is exact unless
    `a[10:4]` wraps, and then that window's second pair reads a wrong row: a missed or false hint,
    never a wrong result.
  - **Tags:** each bank compares its own pair's tag: `btag(sa_q)`, or `btag(sa16)` for the second
    pair, both from registers.
  - **Next rows:** every candidate is still skewed before the one-hot pick, now with its second row
    beside it, and each bank takes one of the two after the pick: one level on the predictor's loop.
- **The corrector needs no row change.** It is read ahead, at the previous window's address and
  the history (`yr ^ yh`), and that index rides to training. Only its tag check changes: for a
  second-pair position it takes `sa16`'s bits.
- **Order, without a rotation:**
  - "Before" for bank *k* is a mask of the banks from `sk_q` round to *k*, a function of the register
    alone. The end pick (`coh`) and the marks use it in place of today's constant masks, so the
    depth from the RAM to the next rows is today's.
  - The marks and `p_end` go to the ring by window position. The queue takes the first two marks by
    position.
  - The halfword after a mark is the ending bank's pair plus the bank (or the next pair's start),
    from registers, so no adder sits behind the mark. The RAS's return address is the same value.
- **A window stops at its page's end** (the last pair of a 4 KiB page, at a non-zero offset).
- **Training is unchanged:** a CTI's entry belongs to its last halfword, at row(its pair), in
  bank `[3:1]`.

**The ring.**
- A request is the window's first halfword and its last position (`ic_last`, a new port through
  the frontend, the core and the SoC to the I$'s `rd_last`).
- An answer is written as halfwords from the tail; `rp_skip` and its subtraction are gone.
- The start-bit predecode and the room rule (`RS - 8`) stay as they are.
- The I$ tag loses its 3 skip bits (`SMOLRV64_ICTAG_W` 17 -> 14).

## 5. Timing: where to look first

1. **The I$ answer stage**: measured, +0.950 ns out of context (§3).
2. **The predictor's loop** (out of context at +0.624 ns before this change). It gains the per-bank
   row pick after the one-hot pick and a 7-bit increment beside each target's row. This is the risk.
3. **The ring's loop** gets shorter: no skip on the write path.

## 6. Order of work

Each step is lint clean, riscv-tests 240/0, the unit benches (`run-icache-tb.sh`; the predictor and
ring through the lockstep), the Linux lockstep, then the board.

1. **The I$ banks** -- done: cycle-identical to main (the I$ bench's counts, ChaCha, the 60 M boot).
2. **The I$ window** -- done: the bench issues windows at every halfword and length and checks each
   answer by line; the core still asks for aligned pairs and is cycle-identical.
3. **The stream** -- built: riscv-tests 240/0, ChaCha 25 cycles an iteration, the predictor out of
   context +0.108 ns (§4). Then the GB5 SimPoints for the record, the userspace locksteps, the
   build and the board gate.

**Invariants (always on):**
- a window never crosses its page (the I$'s `e_page`);
- a request needs the next line only when its window reaches it;
- an answer's halfwords are the window's;
- each bank reads the row of the pair it holds (unless the +1 row wraps);
- a window never ends outside itself;
- every existing `smolrv64_fring` and `smolrv64_predictor` check, restated for windows.

## 7. Measured: step 3 on ChaCha20 (2026-10-27)

Step 3, lockstep-clean, riscv-tests 240/0:

| ChaCha, cycles an iteration | 64-byte ring (`RS` 32) | 128-byte ring (`RS` 64) |
|---|---|---|
| pairs (main) | 34.00 | 26.00 |
| windows stopping at every 2 KiB block (step 3's first version) | 31.00 | 26.00 |
| **windows stopping at the page** | **25.00** | 25.00 |
| the loop aligned to 16 bytes (pairs) | 25.00 | -- |

The first version stopped a window at the last pair of every 2 KiB block, so that the next pair's
row would always be this one's plus one. The loop crosses `0x80002800`: there the window stopped,
the next one started 16-byte aligned while the bundles stayed 12 bytes into each pair, and the
64-byte ring was back to three requests in four for the rest of the iteration. Stopping only at
the page, with each bank's own pair's tag, the windows stay in step with the bundles and the
kernel runs as aligned code does.

The GB5 price decides what lands: the 77 SimPoints of the 128-byte ring alone (`fw-rs64`), the
windows (`fw-win`) and both (`fw-winrs64`), against `cut1b-sp` (the SimPoints of 7f8f5a94).
