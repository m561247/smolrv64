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
data in the start cycle as the D$ would hold it (`data << 8*off[2:0]`) into the forward queue, two
deep, and the LSU presents the older as a response in the first cycle the D$ returns none
(`mem_rvalid_c` low): the same tag mux, formatting and landing as a D$ hit. A forward starts while
another waits; with both slots full the next waits (`fw_busy`, a register).

## Checks (always on)

- at a forward start: the store is the load's forwarding store -- live, data in, `conf` and `cov`;
- a forward starts only for a forwardable, idempotent, cached load, and a forwarded load never
  lands watched (so never replays);
- a forward never starts into a full queue, and lands only on a live fast tag (`o_v`).

## Verification

lint; riscv-tests; the queue benches with forwarding driven (the random bench checks every
forwarded value against its program-order model); 60 M / 300 M lockstep; glibc and sysd userspace
lockstep; memrand sweep; the interrupt storm; GB5 slices (cycles, FWD-SIM before/after); timing at
166.67 MHz; board gate; GB5.

## Measured

60 M lockstep +0.82% over SQ 32 with one forward register (351,419 forwards), +0.35% more with
the queue. GB5 slices, cycles, without forwarding -> one register -> the queue:

| slice | without | one register | the queue |
|---|---|---|---|
| Navigation | 42,234,909 | 40,987,984 (-2.95%) | 40,204,456 (-1.91% more) |
| HTML5 | 50,731,839 | 50,672,571 (-0.12%) | 50,662,476 |
| SQLite | 47,845,043 | 47,511,585 (-0.70%) | 47,533,897 |
| PDF Rendering | 37,956,859 | 37,814,406 (-0.38%) | 37,813,675 |

With one register, Navigation's forwardable loads (8.16 M load-cycles) waited for it in 2.77 M
(a forward lands in the first cycle the D$ returns nothing, and the next could not start until
it had) and for the port in 3.00 M; it started 952,794 forwards. With the queue they wait for a
full queue in 4 K, and it starts 1,381,490.

## What is left

FWD-SIM (Navigation / HTML5 / SQLite / PDF Rendering, load-cycles, with the queue):

- **An unknown address between the store and the load** (5.15 M / 1.34 M / 1.81 M / 0.28 M
  load-cycles): done as speculative forwarding. A load forwards past older unknown addresses when
  the dependence table lets it go ahead of them, counts as having reached memory, and is replayed if
  a store's address arrives that overlaps it; its forwarding store's overlap is set aside while it
  stands forwarded. Unknown stores older than the forwarding store cannot matter but are not told
  apart (almost none: 5 K / 35 K / 29 K / 63 K), so one of them overlapping replays the load. GB5
  slices, cycles: Navigation -0.71%, HTML5 -0.36%, SQLite -0.30%, PDF Rendering 0.00%. Training the
  table only on addresses that arrive after the load's own (the overlap with a store whose address
  was known first says nothing about the wait) speeds Navigation another 0.82% but costs the boot
  0.58% in more replays; not taken.
- **The port**: 5.33 M / 1.59 M / 1.82 M / 0.43 M load-cycles of forwardable loads waiting while
  another load starts, the drain has the port, or the LSU takes nothing; in the 300 M boot, 48.2 M,
  32.7 M of them behind the drain (a committed store at the queue head has the port first). A
  forward needs no D$ access; a start of its own beside the port's would take it out of that
  contention. Giving the port to a ready load first (a store refused once goes next) is worse:
  Navigation +6.7% cycles, HTML5 +1.4% -- a later drain holds back the loads that wait on it.
