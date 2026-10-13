# Store-to-load forwarding

Status: built 2026-10-13, the store queue's second step after `SQ_N` = 32, written and measured
overnight while Tommy asked for autonomous progress. The next step is below (What is left).

## Why

A load whose bytes overlap an older store still in the store queue waits today until that store
COMMITS (the irrevocable pointer reaches it: everything older is done) and DRAINS to the D$, and
then reads the D$. There is no forwarding. With the queue at 32 entries, `be:sq-full` is gone and
the waiting moved: in GB5 Navigation a load is held by an older store in 35% of cycles, and the
ROB fills behind those loads (`be:rob-full` 0 -> 10.7%).

FWD-SIM (a testbench count, 50 M-retire GB5 slices from Simmerv checkpoints, SQ 32) classifies
every held load in every cycle by what holds it:

| slice | held load-cycles | the youngest older overlapping store covers it, data in | ...data not in yet | an older address unknown | partial overlap |
|---|---|---|---|---|---|
| Navigation | 27.9 M | 60% | 29% | 11% | 0% |
| HTML5 | 9.0 M | 46% | 32% | 16% | 6% |
| SQLite | 11.9 M | 70% | 16% | 13% | 0.4% |
| PDF Rendering | 5.5 M | 38% | 54% | 7% | 0.1% |

So the simple case -- one store covering the load -- is 78-92% of the waiting. Where the store's
data is not in yet (PDF Rendering: an FP result), the load takes it the cycle it arrives instead of
after the store's commit and drain.

## What

A load held only by older stores whose addresses are all known, where exactly ONE older store
overlaps it, covers all of its bytes and has its data, takes that store's bytes instead of waiting
for the drain. FWD-SIM finds one overlapping store in 99.6-100% of the forwardable cycles of all
four slices, so the store is the one-hot overlap row's encode: no priority select. Nothing else
changes: partial overlaps, unknown older addresses (memory-dependence speculation as today),
device and uncached accesses, and straddles keep their paths.

## How

**The store queue keeps a coverage matrix beside `conf`**, `cov`, written at the same sites (an
address arriving, never at access time): store g holds every byte of load i --

- **the same address, not only the same page offset.** `conf` compares page offsets (synonyms must
  never miss each other), so a store to another page at the same offset "overlaps"; forwarding
  from it would be wrong. `cov` compares the page too, as `{bare, VA[38:12]}`: everything in the
  queues shares one address space (satp writes and sfence.vma drain them), and `bare` -- the access
  was not translated, M-mode or satp Bare -- separates a user store's VA from an M-mode load's PA of
  the same value: a committed store survives a trap's flush and can still be draining when the
  M-mode handler runs. A synonym blocks, as today;
- the store sits inside one doubleword, and its bytes cover the load's.

`l_fwd[i]` (registered) = exactly one older live store overlaps the load & `cov` & its data in &
translated, cached, not faulting & no older store's address unknown, cleared in the edge that store
drains -- so the slot it names never outlives the store (rule: a slot name carries its tag or is
pinned). The store's index, the encode of the one-hot row, is registered beside it.

**The load queue offers a forwardable load like a clear one**: `rdy_m` admits `~e_block | l_fwd`,
and the offer says which (`x_fwd`). It is sent as today (`sent`, `x_take`) and lands by its tag.
A forwarded load does not count as having reached memory (`e_acc` excludes it): it read a store,
not the cache, and with every older address known no store can arrive to violate it.

**The LSU starts a forwarded load like a fast load** -- the same per-tag formatting state (`o_v`,
`o_nb`, `o_boff`, `o_sgn`, `o_fp`) -- but sends no D$ read. The store queue reads the candidate's
data in the start cycle as the D$ would hold it (`data << 8*off[2:0]`) into one forward register,
and the LSU presents it as a response in the first cycle the D$ returns none (`mem_rvalid_c` low):
the same tag mux, formatting and landing as a D$ hit. One forward in flight; the next waits.

## Checks (always on)

- at a forward start: the store is the load's forwarding store -- live, data in, `conf` and `cov`;
- a forward starts only for a forwardable, idempotent, cached load, and a forwarded load never
  lands watched (so never replays);
- the forward register never holds two, and lands only on a live fast tag (`o_v`).

## Verification

lint; riscv-tests; the queue benches with forwarding driven (the random bench checks every
forwarded value against its program-order model); 60 M / 300 M lockstep; glibc and sysd userspace
lockstep; memrand sweep; the interrupt storm; GB5 slices (cycles, FWD-SIM before/after); timing at
166.67 MHz; board gate; GB5.

## Measured

60 M lockstep +0.82% over SQ 32 (351,419 forwards). GB5 slices, cycles: Navigation -2.95%, HTML5
-0.12%, SQLite -0.70%, PDF Rendering -0.38%.

## What is left

The rule "every older store's address known" turns away 17-37% of the forwardable cycles. A load
that would forward past an older store with an unknown address can do it speculatively, as loads
already go ahead of unknown addresses, if the store's address arriving and overlapping flags the
forwarded load for replay like a load that read memory (`e_acc` would then include it, and the
check against the forwarding store itself must exclude it).
