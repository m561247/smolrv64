# Dispatch groups: a full row of any kind (plan, 2026-10-20)

Tommy, 2026-10-20: "mark the dispatch rules as a major pain point in need of a thorough review. I
have many microbenchmarks showing lower than expected performance that can all be explained by
suboptimal dispatch. We need to find alternatives to cutting groups for the common case." And: "I explicitly
said we should be able to absorb at least one full row of FP insns. In general we should avoid
cutting except for system ops which absolutely have to break."

**How the FP rule came about.** Lanes 5.3b (1cc1c686, 2026-10-04) formed groups at the queue head
when `u_iq_f` took one op a cycle, and wrote "at most one for u_iq_l and one for u_iq_f" into the
group rule. The 8-entry FIFO ahead of `u_iq_f` (2026-10-13) was built with one push a cycle behind
that rule, so it never absorbed a row, and the rule was not revisited when it went in.

## The rule

`smolrv64_frontend` `rule[k]`: a group is the IR's first `IW` instructions up to the first one that
may not join it, and that one cuts itself and everything behind it. A slot may not join a group
beside a non-plain op (alone), behind a CTI that redirects fetch at decode (resteer), or as the
group's second load, second store or second *unit op* (an FP-class op, an int-to-FP op, a divide,
a system op). A slot that joins still needs its credits (its lane's scheduler, the LQ, the SQ, the
FP queue, the divide credit), and one it misses cuts it the same way.

## What it costs (DISP-SIM, f644696c, GB5's 77 SimPoints)

Per subtest: the cycles a slot (B or C) is cut while the slot ahead of it dispatches, as % of the
cycles, by cause; and the instructions the dispatching groups would take with a rule relaxed (the
bench's copy of the rules, asserted equal to the frontend's with none relaxed), as % more than they
took with any number of that kind a group -- an upper bound, since the extra instructions'
credits count as room for any number.

| subtest | cut: 2nd load | 2nd store | unit | lane credit | more: loads | stores | units | all three | ok:1+ok:2 |
|---|---|---|---|---|---|---|---|---|---|
| AES-XTS | 9.8 | 1.7 | 0.0 | 14.2 | 7.8 | 1.4 | 0.0 | 9.3 | 26.1 |
| Text Compression | 10.1 | 2.6 | 0.0 | 5.8 | 8.2 | 2.4 | 0.0 | 10.6 | 18.9 |
| Image Compression | 11.1 | 2.7 | 0.0 | 9.3 | 8.7 | 2.1 | 0.0 | 10.8 | 24.1 |
| Navigation | 11.1 | 10.6 | 0.1 | 3.2 | 12.7 | 14.2 | 0.1 | 27.0 | 26.7 |
| HTML5 | 14.1 | 10.7 | 0.0 | 3.2 | 14.1 | 11.0 | 0.0 | 25.0 | 30.5 |
| SQLite | 15.9 | 7.1 | 0.0 | 2.0 | 15.8 | 7.9 | 0.0 | 23.7 | 30.1 |
| PDF Rendering | 13.8 | 14.6 | 2.6 | 6.0 | 13.7 | 18.7 | 3.3 | 35.7 | 38.2 |
| Text Rendering | 9.3 | 4.0 | 0.0 | 3.8 | 8.3 | 3.9 | 0.0 | 12.3 | 21.6 |
| Clang | 11.3 | 8.6 | 0.0 | 1.1 | 18.2 | 14.5 | 0.0 | 32.7 | 23.5 |
| Camera | 6.0 | 1.8 | 16.2 | 5.2 | 4.7 | 1.8 | 14.8 | 21.3 | 30.6 |
| N-Body Physics | 11.5 | 5.7 | 15.6 | 0.1 | 20.7 | 13.0 | 30.2 | 63.9 | 33.6 |
| Rigid Body Physics | 14.3 | 5.0 | 31.4 | 0.6 | 18.8 | 6.8 | 44.5 | 70.1 | 51.8 |
| Gaussian Blur | 7.1 | 0.3 | 40.6 | 0.8 | 4.2 | 0.3 | 31.7 | 36.1 | 49.5 |
| Face Detection | 3.3 | 1.3 | 23.4 | 7.9 | 3.5 | 1.8 | 23.8 | 29.1 | 36.5 |
| Horizon Detection | 4.3 | 0.5 | 13.4 | 8.0 | 3.4 | 0.5 | 15.9 | 19.8 | 27.1 |
| Image Inpainting | 21.4 | 0.6 | 25.9 | 2.3 | 24.2 | 0.7 | 41.7 | 66.6 | 53.2 |
| HDR | 11.7 | 1.3 | 7.8 | 9.3 | 8.4 | 1.6 | 9.2 | 19.2 | 30.9 |
| Ray Tracing | 11.4 | 4.1 | 15.6 | 3.3 | 10.7 | 4.8 | 16.9 | 32.4 | 36.3 |
| Structure from Motion | 6.1 | 0.6 | 32.0 | 1.9 | 3.7 | 0.6 | 28.4 | 32.7 | 40.9 |
| Speech Recognition | 10.4 | 3.1 | 11.1 | 2.7 | 10.0 | 3.5 | 11.6 | 25.1 | 29.4 |
| Machine Learning | 18.7 | 0.3 | 17.8 | 0.1 | 15.7 | 0.3 | 11.6 | 27.5 | 38.8 |

The machine is dispatch-bound: TOPDOWN's back-end causes are 5-22% of the cycles (N-Body 41%), while
the cycles that dispatch one or two instructions are 19-53%. The integer subtests are cut by their
second load and second store about equally (Navigation, HTML5, PDF, Clang 25-36% more instructions
a group with both relaxed); the FP kernels by their second unit op, which is their second FP op
(Gaussian Blur 40.6% of the cycles, SfM 32.0%, Rigid Body 31.4%), and their loads. The other causes
are small: alone 0.01-0.3%, resteer under 0.2%. The lane credit (AES 14.2%) is the static lane
assignment, outside this plan. On the board the same shape is `bw r 32`'s 5.79
bytes a cycle: eight back-to-back loads dispatch one a group with nothing beside them.

## What each one-a-group rule protects (2026-10-20 survey of f644696c)

- **A second load**: the LQ's allocation (`smolrv64_lq`: the lowest free slot `fs`; the entry's
  fields and the 16x16 age matrix are flops, `pcm[fs]` the load's PC), the load's dispatch record
  `spl_ld` (16 x {ROB slot, payload}, written at `lq_d_idx`), the one-load mux `gld_*`, the
  wait table's one read (`mdw[gld_pc]`, 256x2 distributed RAM), the one `lq_d_idx` stamped into
  every slot's payload, `ld_sqtag` (+0 or +1 store), and the credit `cr_ld` (room for one beyond
  the IR's at most one).
- **A second store**: the SQ's ring tail (fields flops; `pc`, `sqn`), its allocation snoop (one
  data-register compare), the store's seqno `d_tag`, `spl_st` (32 x {ROB slot, payload}), the one
  `sq_d_idx`, and `cr_st`.
- **A second unit op**: the FP side's one push (the stage register `stg_*_f`, else the FIFO
  `fsq_mem`, 8 x {preg, payload} distributed RAM, ring tail), and the FP destination shard SH_FF's
  one pop a group (`smolrv64_rename`: one free list per shard, four banks that already read
  entries h..h+3 in parallel). A divide shares neither: its credit is its own (`dt_v`), so a divide
  beside an FP op is cut for nothing; a system op is never plain, so the rule's `G_S` term is dead.
- **M fills one load or store a cycle** whatever dispatch does: the queues decouple the two.

## The design: a group is cut only where it must be

A group is the IR's first `IW` instructions, cut only beside a non-plain op (a system op, a CSR
access, a fence, an AMO, LR/SC or CBO: they serialise or wait for the ROB head) and behind a CTI
that redirects fetch at decode (what follows it is the wrong path). Every class takes a full row:
`IW` loads, `IW` stores, `IW` FP ops in one group. What remains is room: a credit a slot misses
still cuts it, and the credits count a group's members per class. Every structure written once a
cycle today is banked four ways (`IW` <= 4) so that a row's members land in distinct banks.
- **LQ: four banks of four slots (slot mod 4), free-slot allocation within a bank.** A group's loads
  take banks in ring order from a bank pointer (a flop, advanced by the group's load count), each
  the lowest free slot of its bank (a 4-entry encoder, shorter than today's 16). `spl_ld` and `pcm`
  become four banks, one write each (the fill reads all four at `idx[3:2]` and picks by `idx[1:0]`).
  The age matrix (flops) writes a row per load: each includes the live entries and the group's
  older loads. Each slot's payload takes its own load's index; each load's `ld_sqtag` adds the
  stores ahead of it in the group. The wait table gets `IW` read ports, copies. The j-th load of the
  head group needs room in its bank beyond the IR group's loads there: per-bank free counts (flops).
- **SQ: tail .. tail+IW-1.** The ring's row of allocations is consecutive, so `spl_st`, `pc` and
  `sqn` bank by `idx mod 4` with one write each; the flop fields take `IW` writes; `IW` allocation
  snoops; seqnos `tail+j`; the credit counts the IR's stores and the head group's.
- **FP side: a row of pushes.** The stage register takes the first FP op when it and the FIFO are
  empty, the FIFO the rest, its ring banked by `idx mod 4`; `u_iq_f` still takes one a cycle from
  them and the FPU issues one a cycle, so the FIFO is what absorbs a row. The FP destination shards
  pop `IW` a group, SH_FF (FP ops, int-to-FP ops) and SH_FL (FP loads): the free list's four banks
  already read entries h..h+3, so each slot takes its own output mux; LOWAT goes to two groups'
  worth, 2 x `IW`. The credit counts the IR's FP ops and the head group's against the FIFO's room.
- **Divides**: the MD stage keeps two in flight; the rule's term goes and the divide credit counts
  the group's divides (a third in a group waits for room). The `G_S` term goes (dead).
- **The frontend's rule** keeps only plain and DCR; the credits arrive per slot (the k-th load,
  store or FP op of the head group), sums over flops (rule I12), so the take chain gains no
  arithmetic on live signals.
- **M fills one load or store a cycle** as today: the queues decouple it from dispatch, and a row of
  loads fills over `IW` cycles.

## Order and measurement

1. The FP side (your full row of FP; Gaussian Blur, SfM, Rigid Body, Inpainting).
2. Loads and stores (the integer subtests, `bw r`, the microbenchmarks).
Each measured on the 77 SimPoints, `bwread.c`, Dhrystone, CoreMark and the 60 M lockstep against
the 3a tree, each its own commit and gate. Timing to watch: the frontend's take chain (shorter: the
class terms go), the per-slot credits (flops), the banks' write enables.

## Checks

The lockstep and the userspace locksteps; the LQ/SQ unit benches drive two allocations a cycle
(random); asserted: a row's allocations never share a slot or a bank, a group's later load is younger
than its earlier ones in the age matrix, `ld_sqtag` equals the stores dispatched ahead of the load,
a group is cut only beside a non-plain op, behind a DCR CTI, or by a credit it misses.

## Built (2026-10-20, wip/disp)

- **The FP queue's kill (a3b322f9, rule D19).** The FP row exposed a latent bug: `smolrv64_iq`'s
  kill tested an entry's stored ROB slot, and an entry the F stage filled while a kill held still
  stored its previous occupant's, so a live op vanished (a PDF SimPoint hung 770 K cycles in). The
  entry being filled is now tested by its incoming op.
- **FP ops fill a group (d3dd7b52).** As designed; divides keep one a group. GB5's 77 SimPoints
  -2.48% of the single-core cycles (Structure from Motion -5.42%, Gaussian Blur -5.00%, Camera
  -2.74%, Rigid Body -1.67%, Horizon -1.42%, HDR -1.18%, N-Body -1.01%; integer within 0.06%). The free lists hand a
  row's registers out in program order, not slot order: the committed head and the walk move in
  program order, and slot order reused a committed register after a squash inside a row.
- **Loads and stores fill a group.** As designed. The F FIFO, `spl_ld`, `spl_st` and the LQ's
  `pcm` are `smolrv64_bankq`s (its `PICK` mode: one read at any entry); `rdn` is flops (16 x 6, read
  at two entries the landing picks after the read). The LQ's `d_ready` is room in the bank the
  next load takes. The random LQ/SQ bench dispatches rows of two (both queues `NW=2`, the LQ in 2
  banks of 2). Bare-metal `bwread.c` in lockstep: 338,469 -> 272,474 cycles (~7.7 bytes a cycle).
