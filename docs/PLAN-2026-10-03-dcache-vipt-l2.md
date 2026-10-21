# The data cache end state: an alias-free VIPT L1 and a 1.5 MiB L2

Status: direction decided and deferred (Tommy, 2026-10-03): the lanes plan's step 5 comes first.
Nothing below is built. This plan supersedes the
VHPR end state of the D$ plan (`PLAN-2026-09-25-dcache-vhpr.md`: increment 5c, phase 3 / increment
6b, decisions 1 and 5) and step 4 of the lanes plan. The memory path, the MSHRs, the write-back
buffer, the store port, NC, the CBOs and the coherent I$ that the D$ plan built all stay.

## Decision (Tommy, 2026-10-03)

- **The D$ is a VIPT cache with page-sized ways: 128 KiB, 32 ways of 4 KiB, 64 sets.** The set
  index is VA[11:6], inside the page offset, so it equals PA[11:6]: no synonyms, no epochs, no
  virtual stamps, no refusals for a stale stamp. The dTLB is read in parallel with the banks and a
  hit is a physical-tag compare.
- **The L2 is 1.5 MiB of UltraRAM** in the memory controller's 333 MHz clock domain.
- **Either may be scaled down** (fewer L1 ways, fewer L2 rows) only if timing or congestion forces
  it after real work, never for a measured IPC delta.
- The I$ is not part of this decision; this plan changes nothing above its memory port.

## Why

**VHPR as built lost to its PIPT base.** The 4b lockstep against the PIPT-skew D$ at the same tip
(retires, 60 M / 300 M):

| variant | 60 M | 300 M |
|---|---|---|
| VHPR, synonyms dropped and refetched | -2.20% | -10.55% |
| VHPR, synonyms moved inside the L1 | -1.46% | -5.68% |
| the dTLB read beside the virtual hit | -1.34% | -8.76% |
| the same, way 1 physical | -0.31% | -2.81% |

The losses are structural: refusals, synonym traffic between colours, and epoch scans.

**An alias-free VIPT loses nothing to VHPR in the L1, and the L2 absorbs the difference to a skew.**
Simmerv's whole-GB5 sampled model (172 windows, `wip/wset`), L1 misses per 1000 instructions, and
DRAM reads behind a physically indexed L2 that sees the L1's fetches:

| L1 | L1 misses: suite / without ML / ML | DRAM behind 512 KiB / 1 MiB / 2 MiB |
|---|---|---|
| 2-way, 64 KiB ways, straight index | 8.36 / 5.51 / 70.9 | 5.86 / 2.75 / 2.26 |
| PIPT, way 1 skewed (ships today) | 5.43 / 5.27 / 8.92 | 3.17 / 2.59 / 2.26 |
| VIPT 128 KiB, 32 ways | 8.17 / 5.30 / 70.9 | 5.83 / 2.75 / 2.26 |
| VIPT 64 KiB, 16 ways | 9.12 / 6.20 / 73.2 | 5.83 / 2.75 / 2.26 |
| VIPT 32 KiB, 8 ways | 11.55 / 8.29 / 82.9 | 5.84 / 2.75 / 2.26 |

- Outside Machine Learning, VIPT at 32 ways matches the skew (5.30 against 5.27).
- ML's SGEMM column walk sits in one or two sets at any index taken from bits below the page,
  however many ways: 70.9. Only a skew fixes it in the L1. Behind a 1 MiB L2 it costs 4.8 DRAM reads
  per 1000 instructions against 1.1 for the skew, and the rest are L2 hits.
- Behind any L2 of 1 MiB or more, DRAM traffic is the same for every L1 above.

**The hit path closes, and a small first-level dTLB takes it past 300 MHz.** Out of context at 6 ns
(`wip/l2-spike`, `smolrv64_vipt_spike.v`: a direct-mapped LUTRAM dTLB, the per-way tag LUTRAMs, the
compare into a registered one-hot hit, the select a cycle later):

| ways | dTLB entries | set index | Fmax | worst path |
|---|---|---|---|---|
| 8 | 2048 | one register | 280 MHz | dTLB read (7 levels) into the compare |
| 16 | 2048 | one register | 282 MHz | the same |
| 32 | 2048 | one register | 246 MHz | the set index into the 32 tag arrays: 928 loads, 3.05 ns of route |
| 32 | 2048 | 8 copies | 240 MHz | dTLB read into the compare, 4.14 ns |
| 16 | 64 | one register | 368 MHz | the data select |
| 32 | 64 | one register | 267 MHz | the set index's fanout |
| 32 | 64 | 8 copies | 330 MHz | the PPN into the 32 compares (32 loads) |

So the 32-way geometry costs nothing once the set index is replicated; what limits the clock is
the 2048-entry dTLB's read.

**The URAM fits.** 48 URAM288 out of context: +2.8 ns at 166.67 MHz, +0.1 ns at 333 MHz. Placed in
the full chip with the core, the default directive went from -0.026 to -0.120 ns and Explore from
+0.020 to -0.030 ns, and no URAM path is in the timing census.

## The L1

### Arrays

| array | shape | holds |
|---|---|---|
| data | 32 RAMB36 at 512 x 72, simple dual port | one 64-bit chunk per (set, chunk) per array, laid out diagonally (below) |
| tag | LUTRAM, 32 arrays of 64 x (PA tag + valid + dirty), one per way, read at VA[11:6] from a replicated set-index register | the line's PA[35:12] |
| store tag copy | the same, a second copy | the committed store's lookup in the same cycle as a load's |
| replacement | per set | not-recently-used, one bit per line (the model: 8.09 L1 misses per 1000 instructions on GB5, against 8.17 for true LRU and 8.09 for tree pseudo-LRU) |

The block-RAM count is today's: 128 KiB of data is 32 RAMB36 either way.

**The data layout is diagonal.** Chunk `c` (0-7) of way `w` lives in array `(w + c) mod 32`, at
address `{set, c}`. Then:

- a load reads `{set, c}` from all 32 arrays at one shared address, and gets chunk `c` of all 32
  ways, rotated by `c`;
- a line's eight chunks sit in eight different arrays, so a 128-bit fill beat writes two arrays in
  one cycle, and a whole line could write in one;
- a store writes one array.

The rotation is applied to the one-hot hit vector (32 bits), not to the 2048 bits of data.

### The hit pipeline

- **T:** the door accepts a load (registered accept, as today). Its VA reads, in parallel:
  - the 32 data arrays at `{VA[11:6], chunk}`;
  - the 32 tag arrays at VA[11:6];
  - the dTLB, by VPN.

  The dTLB's PPN is compared with the 32 tags; the one-hot hit, the permission check and the
  fault are registered.
- **T+1:** the arrays' outputs are selected by the rotated one-hot hit (an AND-OR of 32 x 64 bits)
  and the response is registered. The lanes' write-slot reservation happens here: the tag compare
  is known one cycle before the data.
- **T+2:** the response is visible, tagged.

A dTLB miss is not a cache miss: the load is refused, the walker (in the queues since 5b) fills the
dTLB, and the load asks again. A tag miss with a dTLB hit is a miss with its PA in hand, into the
MSHRs as today.

**Stores** carry their PA from translation into the store queue. At commit a store reads the store
tag copy at PA[11:6], compares its PA, and writes its chunk into the one array that holds it. No
dTLB read.

### Everything addressed by PA

The physical index is the virtual index, so every request that has only a PA is a normal lookup:

- the page-table walker's reads;
- the CBOs (`clean`, `flush`, `inval`, `zero`);
- the MSHRs' merge and the write-back buffer's match;
- a future DMA snoop.

`sfence.vma` and `satp` writes touch only the dTLB. Nothing in the L1 depends on the address space.

### What goes from `rv_dcache`

The virtual stamps, the epochs and their wrap scan, the per-(way, colour) physical tags, the
skewed way 1, the VA-alone asks and their refusals, and synonym handling of every kind.

### What stays from `rv_dcache`

The MSHRs and their waiter lists and store-merge buffers, the write-back buffer (demand reads
first), critical-chunk-first fills with early restart, NC without allocation, the CBO completion
on write done, the store port's one store per cycle, the integrity log and the Zihpm events.

## The L2

- **Geometry.** 24,576 lines of 64 bytes: 48 URAM288, eight wide (512 data bits, the spare 64 for
  ECC or tag bits later) by six deep in one cascade. A line is read or written whole in one
  access. Associativity and index (12 ways x 2048 sets, 24 x 1024, a hashed index or not) come
  from the model (step 0).
- **Measured (Simmerv, whole GB5, 172 windows; the L2 sees both L1s' fills and the D$'s dirty
  evictions).** DRAM reads per 1000 instructions, data + instructions:

  | L2 | whole suite | without ML | ML |
  |---|---|---|---|
  | 1 MiB 16-way, behind VIPT 128 KiB | 2.77 | 2.67 | 5.00 |
  | 1.5 MiB 6-way, behind VIPT 128 KiB | 2.42 | 2.52 | 0.47 |
  | 1.5 MiB 6-way, behind the skewed PIPT | 2.42 | 2.52 | 0.47 |

  At 1.5 MiB ML's SGEMM working set fits, so the L1's organisation stops mattering below it.
  6, 12 and 24 ways and a hashed index are within 1% of each other: **6 ways of 4096 sets**,
  one way per URAM in the cascade's depth. DRAM writes are 0.63 per 1000 instructions without
  ML.
- **Tags.** Block RAM, all of a set's ways read at once.
- **Place and clock.** Behind the core's memory port, in the memory controller's clock domain
  (333 MHz), between the asynchronous FIFOs and the AXI master. The L1s see it only as a faster
  memory: the port is already tagged, and its responses may already return out of order.
- **Policy.** Physically indexed and tagged, write-back, filled by both L1s' misses and L1
  write-backs. Not inclusive: nothing above it needs a reverse directory.
- **Non-blocking.** It takes the D$'s and the I$'s outstanding misses and sends its own misses
  through the AXI master's `NOUT`. An L2 hit answers behind an older L2 miss, matched by its id.
- **Coherence with DMA.** DMA reaches DRAM below the L2, so software coherence must reach through
  it: a CBO `clean`/`flush` cleans or flushes the L2's copy too, and `wr_cpl` still means the data
  is in DRAM. NC accesses bypass both levels. The virtio rings are NC today, so the protocol does
  not change; what changes is that a CBO has a second level to push through.


## Ports: a store beside every load, then a second load (2026-10-18)

**Where the memory path stands.** The load queue takes any free entry, a committed plain store
goes to the D$ through the LSU's store register instead of the load port, and the D$ lookup takes
a load before a queued store unless the store is urgent (SmolRV64-Spec §8, §9; wip/memport). On
the GB5 checkpoint slices that is -7.27% of their cycles. What is left is the D$'s one lookup a
cycle, shared by loads and stores: every cycle a ready load now waits for memory is a D$ door
cycle, 12% (Navigation, HTML5, Camera) to 40% (PDF Rendering) of the slices' cycles, and a store
that waits behind loads fills the store queue (PDF's `be:sq-full` 12%).

**What more ports would find to do** (the testbench's `PORTS-SIM`, GB5's 77 SimPoints weighted per
subtest, main 6f2bbf1f): two or more loads ready for memory in 19-25% of the cycles of HTML5,
Ray Tracing, PDF Rendering, SQLite, AES-XTS and Navigation, 8-16% of most of the rest, 3-6% of
Machine Learning, Face Detection and Image Inpainting; a ready load and a committed store together
in 6-12% of the integer subtests' cycles.

**The L1's ports.**
- **A store lookup beside the load lookup** (step 1 of the revised order below): the store tag copy (above) answers the
  committed store's way at its PA's set; the store writes its chunk with byte enables into the one
  array that holds it (the diagonal layout puts a line's chunks in eight arrays), so it never reads
  the data and never takes a load's cycle. A fill beat writes two arrays through the same write
  ports; a store to one of them waits that cycle. A load to a line with a store not yet written
  waits for it, as today.
- **A second load port** (step 4 of the revised order): a second copy of the 32 data arrays (32 more RAMB36; the chip
  uses about a quarter of its 480), each copy's read port a load's and its write port taking the
  same stores and fill beats as the first; a third tag copy and a second dTLB read port (LUTRAM
  read ports are copies). In the core: the load queue offers its two oldest ready entries, the LSU
  starts two fast loads a cycle, and two land a cycle through the lanes' write slots (a load lands
  in its own lane's slot, so two from one lane take two cycles).

## Order

Every step is measured or modelled first, then gated by riscv-tests, the unit benches, lint, the
60 M / 300 M Linux lockstep, the glibc and sysd lockstep, a build, the board and GB5.

0. **Park VHPR.** Commit 4a, 4b and the in-L1 synonym move on their branches as the record.
   **Model** in Simmerv (`wip/wset`):
   - done: the L2's geometry (6 ways) and the L1's replacement (NRU), above;
   - the dTLBs: the first level (32 or 64 entries; direct-mapped, 2-way, 4-way, fully
     associative) by its second-level lookups, and a large second level (2K, 8K, 32K entries;
     direct-mapped, 4-way, 2-way skewed, 2-way cuckoo) by its walks. Both are ASID-tagged with
     global pages, and `sfence.vma` flushes by its address and ASID operands;
   - the ASID width: Linux uses ASIDs only when there are more than two per hart, and when it
     runs out it flushes everything. So the cost of a narrow ASID scales with how many address
     spaces a workload creates (the boot, systemd), not with its instructions (GB5's one
     process). The guest must see the same width as the hardware, since `satp.ASID` is WARL.

   The workloads are GB5, SPEC CPU2006 for footprint (rebuilt first with every extension
   SmolRV64 implements; the existing build is RV64GC), and a make/gcc build for process churn.
1. **The L2, below today's caches.** The D$ and the I$ do not change. Its own bench first, then the
   SoC. The lockstep needs the L2 under the testbench's memory model, so the bench gains the second
   clock and the crossing it sits behind on the board.
2. **The VIPT geometry, with translation where it is.** `rv_dcache` at 32 ways of 4 KiB, diagonal
   data, the 32 tag compares and the chosen replacement; the skewed way 1 goes. The core still
   translates before the D$ and the D$ is handed a PA, which is exact because the index is inside
   the page offset. This step measures the hit rate and the 32-way compare and select in the full
   chip at 166.67 MHz, apart from the cycle.
3. **The dTLB in the access cycle.** The D$ takes the VA and owns the dTLB's lookup; a dTLB miss
   refuses, the walker fills, the load asks again. The LSU/LQ half of 4b (`wip/dc-5c-4b`: VA-first
   asks, refusal, the walk only after a refusal, the re-ask) is the starting point. M's translate
   pass for loads goes, and with it the cycle. It lands with or before the lanes' memory unit
   (lanes step 5.2), whichever is first.

## Order (revised 2026-10-18)

The store path comes before the L2, since the D$'s shared lookup is now the integer subtests'
largest memory stall:

1. **The VIPT geometry with a store lookup** -- steps 2 above and the store port at once: `rv_dcache`
   at 32 ways of 4 KiB, the diagonal data, the 32 tag compares, the store tag copy, byte-enabled
   one-array store writes. Translation stays where it is.
2. **The dTLB in the access cycle** (step 3 above).
3. **The L2** (step 1 above), below both caches.
4. **The second load port**, measured on the SimPoints against the end state, not today's.

## Step 2: the access in M's cycle (design, 2026-10-19)

Tommy, 2026-10-19: load-use 4 first, then load-hit speculation for 3.

**Where the cycles are.** A lane generates a load's address at E. M takes it at E+1 (from the
lane, or from the arrival RAM if it waited), reads the dTLB's second lookup, fills the load-queue
entry and computes the store queue's alias row. A load with no older store live starts early: the
LSU's port register takes it, the D$ takes it at E+2 (T), compares at E+3 and answers at E+4, and
the dependent's address is E+5. Any other load goes the queue's way: its registered block is read
at E+2, the port register at E+3 is the D$'s T, and the dependent's address is E+6. The index is in
the page offset, so the arrays never needed the translation; only the tag compare at T+1 does,
and it reads a registered PA.

**Which loads take which path** (`LDPATH-SIM`, 94070582; GB5's 77 SimPoints weighted per subtest,
the 60 M boot and Dhrystone; "start in M's cycle" is the first three columns, the loads the design
below starts):

| loads, % | start early today | older store live: all clear | ...one unknown, goes ahead | ...one overlaps | ...one unknown, waits | untranslated, device, busy | start in M's cycle | waited for M |
|---|---|---|---|---|---|---|---|---|
| AES-XTS | 68.7 | 24.4 | 3.6 | 2.7 | 0.3 | 0.4 | 96.7 | 44 |
| Text Compression | 43.7 | 38.7 | 8.4 | 2.0 | 0.2 | 7.0 | 90.8 | 38 |
| Image Compression | 15.0 | 66.5 | 9.8 | 1.8 | 0.5 | 6.5 | 91.3 | 36 |
| Navigation | 12.0 | 44.5 | 22.9 | 13.0 | 3.2 | 4.4 | 79.4 | 50 |
| HTML5 | 12.3 | 49.6 | 19.5 | 12.5 | 2.2 | 3.9 | 81.4 | 55 |
| SQLite | 16.3 | 52.8 | 14.9 | 8.3 | 1.1 | 6.6 | 84.0 | 52 |
| PDF Rendering | 12.7 | 64.6 | 12.5 | 4.1 | 0.6 | 5.5 | 89.8 | 54 |
| Text Rendering | 18.3 | 56.5 | 13.6 | 6.3 | 0.6 | 4.7 | 88.4 | 53 |
| Clang | 32.8 | 39.7 | 7.0 | 9.0 | 1.0 | 10.6 | 79.5 | 50 |
| Camera | 6.0 | 83.2 | 6.4 | 2.7 | 0.3 | 1.4 | 95.6 | 27 |
| N-Body Physics | 5.8 | 72.6 | 0.5 | 17.7 | 1.5 | 1.8 | 78.9 | 34 |
| Rigid Body Physics | 25.4 | 54.6 | 7.7 | 5.6 | 0.5 | 6.1 | 87.7 | 46 |
| Gaussian Blur | 0.7 | 97.0 | 1.3 | 0.6 | 0.3 | 0.1 | 99.0 | 6 |
| Face Detection | 82.9 | 6.6 | 1.1 | 2.0 | 0.2 | 7.3 | 90.6 | 40 |
| Horizon Detection | 15.1 | 79.5 | 1.2 | 0.7 | 0.1 | 3.6 | 95.8 | 17 |
| Image Inpainting | 67.8 | 18.3 | 4.4 | 1.6 | 0.7 | 7.1 | 90.5 | 14 |
| HDR | 26.8 | 53.2 | 16.1 | 1.2 | 0.2 | 2.5 | 96.1 | 38 |
| Ray Tracing | 33.3 | 54.1 | 2.1 | 4.8 | 0.1 | 5.7 | 89.5 | 31 |
| Structure from Motion | 9.5 | 84.8 | 3.5 | 1.7 | 0.1 | 0.4 | 97.8 | 26 |
| Speech Recognition | 59.4 | 19.9 | 7.8 | 2.0 | 0.3 | 10.6 | 87.1 | 22 |
| Machine Learning | 82.7 | 13.3 | 0.5 | 0.7 | 0.0 | 2.7 | 96.5 | 4 |
| Linux boot, 60 M cycles | 22.7 | 47.4 | 10.5 | 8.4 | 4.3 | 6.6 | 80.6 | 51 |
| Dhrystone | 22.0 | 38.1 | 18.1 | 13.3 | 1.9 | 6.5 | 78.2 | 52 |

**The design: every translated DRAM load starts in M's cycle, and the alias test cancels it.**
- **The start.** M presents the load to the D$ directly: the arrays read at M's address bits
  [11:3] (T = E+1), and the page number from the dTLB lookup M already makes is registered into
  the lookup's PA for the compare at T+1. The answer is at E+3 and the dependent's address at E+4.
  The start is gated by the dTLB alone (a hit, its permissions, the page in DRAM, no page
  crossing) and by the D$'s registered word that it takes a load this cycle; never by the store
  queue. A load not started goes the queue's way as today (the walker fills its entry, the queue
  sends its PA).
- **The cancel.** The alias test stays where it is and registered: M's address reaches the
  filling load's block bit in 5.62 ns, 0.117 ns of slack on 039314ad's routed checkpoint, so it
  cannot gate a start in the same cycle (`smolrv64_core.v` says as much at `lq_b_early`). Its
  register, one bit for the load M started, voids the lookup at T+1: no answer, no fill, no
  wait. The entry's `sent` and the LSU's outstanding bit for its tag are cleared in that cycle,
  and the load goes the queue's way blocked, to forward or wait, as today. Until the cancel
  has passed, the store queue's ordering check must not count the started load as having read
  memory, or a store arriving at E+2 replays a load that never did. A cancelled start costs the
  lookup its cycle (the overlapping loads: 0.6-17.7%, N-Body the most), and the load must reach
  the queue's forward or wait no later than it does today.
- **One lookup, two users.** M's fill and the D$'s take read the same dTLB output in the same
  cycle, so they agree by construction; there is no refusal protocol.
- **Never queued at the door.** The fast load is presented only when the D$ takes it in that
  cycle (no read waits at the door, no replay, no urgent store, the port register not
  presenting: registered), so the cancel only ever finds it in the lookup. A store lookup yields
  to a registered hint (M holds a load), so the arrays' read address is M's address bits through
  registered selects; the late valid drives the lookup's valid, the per-tag outstanding bit and
  the entry's `sent` alone.
- **The DRAM test moves into the dTLB entry**: a bit computed at the fill (the whole page lies in
  DRAM), so the start's late term is the dTLB's hit and permission check, as the early start's
  is today.
- **Timing (039314ad's routed checkpoint).** Today M's address reaches the port register's enable
  through the dTLB read (113 LUTRAM loads on its address) and the tag compare in 4.85 ns, 0.875 ns
  of slack; that decision now drives a few flops at the D$ instead of 64 enables. The port
  register's own path into the arrays (the device decode, the take, the address: 0.234 ns, the
  D$'s worst) is not on the new source.
- **What it gives.** A started load's dependent issues at E+4: one cycle sooner for the loads
  that start early today, two for those behind a live older store that neither overlaps them
  nor holds them (78-99% of the loads start in M's cycle; the integer subtests' 12-18% early
  starts today become 79-90%). The one-cycle price, measured by answering every load a cycle
  late: GB5 SimPoints +1.44% cycles, the 60 M boot -1.49% retires.

**Built 2026-10-19 (wip/dtlb), as designed.** GB5's 77 SimPoints -1.70% of the single-core cycles
against 039314ad (every subtest; SQLite -3.13%, HTML5 -2.82%, Navigation -2.28%, AES-XTS -0.14%),
the 60 M boot +1.66% retires, Dhrystone -0.86% and CoreMark -8.37% cycles. What stops a start now
(`LDPATH-SIM`, % of loads): the D$ takes no load in M's cycle 2-12 (a read waiting at the door,
the port register presenting, a replay or an urgent store), the dTLB does not hold the page 0.4-12
(N-Body 12.1, Speech 9.7, Navigation 6.8), and a cancel 0.6-19 (N-Body 19.1, Navigation 14.3,
HTML5 12.2). The core's slow-load landing index took M's index on every early start, right only
while that start needed the state machine idle: the first lockstep landed a slow load in the entry
M had just started, and that write is gone.

**Then: loads leave M's funnel.** A load stage beside M with its own pick (the oldest waiting load,
else a lane's), its own dTLB read port (a LUTRAM copy, written by the same fills), the queue fill
and the alias row; M keeps stores, AMOs, LR/SC and CBOs. 36-55% of the integer subtests' loads
wait in the arrival RAM for M today (the last column), 0.5 to 1.9 cycles a memory op
(`MFUN-SIM`). The store queue's alias row already compares a filling load with a store arriving
in the same cycle (`fill_row`), a case M's one op a cycle never exercises today. The load queue's searched fields keep one writer, the load
stage (two with the second load port), never the lanes.

## Step 3a: address generators speculate on a load's hit (design, 2026-10-20)

Tommy, 2026-10-19: load-use 3 by load-hit speculation, after 4 (which landed as da5d52b3).

**What a speculative wake would buy, and which consumers it is** (`HITSPEC-SIM`, da5d52b3, GB5's 77
SimPoints, per load lookup in its compare cycle): a wake as if every lookup hit is right for 67%
(N-Body) to 98% (Horizon Detection) of the lookups; it would issue 0.26 (Inpainting) to 0.75
(Navigation) waiting consumers a cycle sooner and wake 0.01 to 0.27 wrongly. Every lane op does its
effects at select (its own dependents' wake, the pending clear, the store queue's snoop, the ROB's
completion), so replaying an ALU consumer means holding its entry past issue, deferring its
completion and masking a cycle's shadow of its dependents: a change across the lanes, the ROB and
every scheduler. A load or store issuing in a lane only generates its address -- it writes no
register, wakes nothing and completes nothing -- so its one effect, the address it delivers, is the
one to cancel. Address generators are 21-35% of the consumers a right wake releases in Navigation,
HTML5, SQLite and Rigid Body (CoreMark 24%, the boot 10%, the FP kernels 1-5%), and they sit on
the serial chains where a cycle is runtime: the pointer chase, `chase2`'s 4 cycles.

**The design: an 8-byte integer load M starts in its own cycle wakes the address generators waiting
on it at its compare (T+1); the D$'s registered verdict at T+2 lets their addresses stand or
cancels them.**
- **The wake, from flops** (rule I12). M knows at T which load it starts (`f_go`), its queue entry's
  destination and size; for an 8-byte integer load with a destination it registers {valid, prd} as
  the speculative wake, broadcast at T+1 to the lanes' schedulers as one more wake port that only
  an address-generating entry (a bit written at dispatch, `e_ag`) may match, and only on its
  address source. Doors, replays and the walker's reads never wake early: they are not M's.
- **The issue.** An address generator picked on that wake keeps its scheduler entry, marked issued
  and no candidate, for one more cycle (`e_sp`); its select register records that its base comes
  from the D$'s answer.
- **The data.** At T+2 the base is the D$'s answer register (`rd_data`), an aligned doubleword
  needing no shift or extension, through one more input of the lane's operand mux into the address
  adder. On 039314ad's routed checkpoint the answer reaches a lane's write register through the
  formatting in 5.12 ns (0.767 ns of slack) and a forwarded operand reaches M's address register
  through the adder in 4.33 ns (1.200 ns); the new path is the first's route without its formatting
  and the second's adder: an estimated 4.8-5.3 ns.
- **The verdict, a flop at T+2**: the D$ answered the started load (its answer at T+1, registered).
  Right: the address goes to M and the arrival RAM as any lane's does, and the entry frees. Wrong (a
  miss, a wait, the cancel): the lane's delivery that cycle is suppressed (one AND of a flop on its
  `l_lm`, which feeds the arrival RAM's write enable and M's bypass select -- an enable, never an
  address, rule I6) and the entry is a candidate again, its address source still waiting for the
  real landing's wake. An address generator wakes nothing, so there is no shadow to mask.
- **Load-use 3 for a load feeding an address**: the load's address at E, the D$ at E+1, the
  consumer picked at E+2, its address at E+3. Every other consumer keeps 4.

**Checks**: every speculatively issued entry is resolved at T+2 (asserted); a suppressed delivery
never reaches M or the arrival RAM; `HITSPEC-SIM` and `LDPATH-SIM` count the speculation's right
and wrong wakes; the lockstep, the userspace locksteps and the storm as for step 2; `chase2` 3.0
cycles on the board.

**Built 2026-10-20 (wip/hitspec), as designed**, the verdict being the D$'s registered word that its
answer is the started load's (`rd_f`). A bare-metal chase 3.00 cycles a load in the lockstep;
CoreMark -3.48% cycles, Dhrystone -2.59%, the 60 M lockstep +0.19% retires, GB5's 77 SimPoints
-0.13% (Text Compression -0.38%, SQLite -0.31%; the FP kernels flat). 83-89% of the speculative
issues stand (`SPEC-SIM`). Small on GB5 because address generators are at most 35% of the consumers
a right wake would release (1-5% in the FP kernels); the rest are ALU ops, which wait for load-hit
speculation with replay.

## Open

- **Where a store translates** once M is gone: a second dTLB read port (LUTRAM read ports are
  copies), or the load port's idle cycles.
- **What store-to-load ordering compares**, VA or PA, once loads carry only a VA until the D$
  answers.
- **A small first-level dTLB** in the hit path, the 2048 entries behind it, if the clock goes past
  about 240 MHz: at 64 entries the 32-way hit path runs at 330 MHz out of context. It joins the
  future TLB plan.
- **Fills straight into the L1 from the 333 MHz domain** (a block RAM's two ports may sit in two
  clock domains). The data arrays' write port also takes the stores, which are in the core's
  clock, so this needs either the stores on the read port's cycles or a different split of the
  ports.
- **The L2's hit latency** in core cycles, through both crossings, from step 1's bench.

## Deferred: what the board measures today (Tommy, 2026-10-16: important, after the core work)

`tools/board/membench` on 2ed18026 (docs/SmolRV64-Spec.md §9.2 and §14 give the figures; the
board gate prints the first two on every PASS):

- **The DDR port's clock crossings: 4.5 of a D$ miss's 46.6 cycles.** `ddr_port_cdc`'s FIFOs treat
  their clocks as unrelated, so every request and response pays `CDC_SYNC_STAGES` of
  synchronizers (42.1 cycles with the clocks related, 258ef1fd). The clocks are related:
  probe_clk is ui_clk / 2 from one MMCM. A synchronous 2:1 crossing -- a register on each side and
  a two-ui_clk multicycle path, not a FIFO's pointer crossing -- would take the 4.5 back without
  the zero-slack pointer paths that made the FIFOs unrelated. The L2 in front of the port hides
  the same cycles on its hits; the crossing stays for its misses.
- **The dTLB's first level: 5 to 9 cycles a load outside its 64 pages** (256 KiB) that the
  second level holds, a replay through the walker's `L2LK` cycle. A wider first level (block RAM,
  read a cycle early, or 128 to 256 entries of LUTRAM) or a second-level hit that answers the
  waiting load without the replay. The future TLB plan's large 4 KiB and 2 MiB levels sit behind
  it either way.
- **A sequential stream keeps under two lines in flight**: eight 8-byte loads hold a line in the
  16-entry load queue, so a DRAM read stream takes 2.4 bytes a cycle while the 8 MSHRs idle.
  Load-queue entries that wait per line instead of per load, or the D$'s next-line stream buffer
  (built, `PREFETCH(0)`: it corrupted memory on the board under real DMA, a mechanism still
  unnamed, which must be named before it goes back on).
- **One page walker**: a footprint that walks on every load keeps 2.4 loads in flight against
  7 to 8 when the dTLB translates them. A second walker, or walks that overlap their PTE reads.

## Deferred: recovery after a mispredict (Tommy, 2026-10-19: important)

**What it costs today.** A mispredict resolved before the ROB head walks the rename map back from
the tail to the branch, a row a cycle, racing the branch to the head, where a squash and the sweep
of dirty registers restore it instead. `RECOV-SIM` (the Linux bench) counts the cycles of that
restore beyond the frontend's refetch, which runs alongside it: over GB5's single-core section as
its 77 SimPoints (039314ad), 0.96% of the cycles -- N-Body Physics 5.6%, Text Compression 3.4%,
Navigation 2.4%, Speech Recognition 2.2%, most of the FP subtests under 0.5%; Dhrystone 4.2%, its
strcmp exit resolving about 15 rows from the tail once the VIPT D$ made its loads faster. The
share grows with the window: a wider machine and faster loads put more rows behind a branch.

**The models measured** (the share of the single-core cycles still exposed):

| restore | exposed |
|---|---|
| as built (the walk racing the head squash) | 0.96% |
| a forward rebuild: the committed map, then the rows from the head to the branch | 0.86% |
| three map checkpoints every 8 rows (4 rows: 0.34%, 16: 0.33%) | 0.18% |
| three checkpoints right after weakly predicted conditionals | 0.51% |
| a compressed walk: each register renamed after the branch restored once, IW a cycle | at most 0.39% |

Weakly predicted conditionals are 14% of the boot's mispredicts and 41% of Navigation's, but 98%
of Dhrystone's, which the weak checkpoints all but zero. The compressed walk restores 5 to 8
distinct registers where the walk crosses 7 to 16 rows; it was credited only where the walk, not
the head squash, ended the restart, so its figure is an upper bound.

**The constraints.** A checkpoint is a map version, and on this FPGA a version is a write port: the
map's copies and their live-value selector widen with each one (four is already a stretch and puts
IW=4 at risk), and the map in flops is worse. Full checkpoint-based recovery without a ROB (CPR) was
this repo's first out-of-order design and failed on its coarse atomic regions.

**The evaluation, at the end state** (IW=4, the L2 in): checkpoints after weakly predicted
conditionals -- one to three map versions held by the oldest unresolved weak branches, so a
confident misprediction costs the walk -- against the compressed walk, which needs no version:
the first rename of each register after the branch, found without a CAM, restored IW a cycle
through the existing ports, with the new path renaming while it finishes (lazy recovery) as a
possible second step. Score both with `RECOV-SIM` over the SimPoints, the compressed walk credited
in the restarts the head squash wins too, and weigh each against `smolrv64_rename`'s out-of-context
timing and size with its ports.
