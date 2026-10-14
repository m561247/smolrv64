`default_nettype none

// smolrv64_lq -- the load queue.
//
// WHY. docs/Area-Efficient-Scalar-OoO.md 11.1: ISSUE is free, ACCESS is ordered. The store
// buffer applied that to stores. This applies it to loads, and without it the ordering test
// has nowhere to live but the translate path:
//
//   smolrv64_lsu used to gate `start_ok` on smolrv64_sq's ld_block, which is computed from the
//   MMU's t_paddr. So a blocked load sat in S_IDLE re-translating every cycle, holding the
//   whole LSU, with an adder and two 57-bit magnitude compares hanging off the end of the
//   dTLB lookup. It was correct and it was the wrong shape: translate and access were
//   fused, which is exactly the conflation 11.1 exists to undo.
//
// Here the address is REGISTERED into an entry when translation completes, and the alias
// test reads that flop. The compare starts at the top of a cycle instead of at the end of
// the translate path, and the LSU is free the moment the address is known.
//
// SHAPE, deliberately the same as smolrv64_sq's, because they are the same idea applied to the
// two directions:
//   allocate  at DISPATCH, in program order. Not at fill: allocating at fill would make
//             entry order depend on ISSUE order, and u_iq_l is meant to stop being in-order
//             (spec 15). Program order is what the ROB index and the store-seqno mean.
//   fill      when the load's address is translated. M releases it here -- from this point
//             the access cannot fault (smolrv64_lsu decides faults before it leaves S_IDLE), so
//             the load is architecturally guaranteed to complete.
//   access    the oldest filled entry that no older store can alias. One at a time: the D$
//             has one port, so exactly one entry needs testing per cycle and the queue needs
//             exactly one disambiguation query port into smolrv64_sq.
//   land      data returns, writes back, completes the ROB slot.
//
// FILL AND ACCESS COLLAPSE when there is nothing to disambiguate against. The SELECT cycle
// exists to read a registered address into the alias test; a load with no store older than
// it still live has no alias test to run, so the core starts its access in the same pass
// that fills the entry (a_sent) and the entry goes straight to `sent`. Everything else is
// unchanged -- the entry is still filled, M is still released here, and the data still lands
// through l_*. That last part is the point: an earlier attempt let M keep the load through
// its access instead, and giving up the early release cost more than the cycles it saved
// (ldbench 6.00 -> 7.00 cyc/load). The queue's two cycles are not pure overhead.
//
// FLUSH IS WHOLESALE for the same reason as smolrv64_sq's: `redirect` is gated by head_block,
// so it fires only with the redirecting instruction at the ROB head, and everything still
// live here is younger than that. A load already ACCESSED but not yet landed is younger
// too -- a load has no side effect, so discarding its result is free.
module smolrv64_lq
  #(parameter NENT  = 4,
    parameter IDXB  = 2,               // $clog2(NENT)
    parameter PAW   = 56,
    parameter PBITS = 9,
    parameter ROBB  = 4,
    parameter SQIB  = 3,               // store-seqno width (smolrv64_sq's IDXB)
    parameter VAW   = 39,              // Sv39: the VA an entry keeps beside its PA
    parameter SEQW  = 8,               // the op's sequence number (a trap restarts fetch at it)
    parameter PCHB  = 8,               // bits of the load's PC the wait table is indexed by (PC[PCHB:1])
    // The memory map, for the D12 cross-check below only (smolrv64_lsu's LSU_DRAM_BASE / LRAM_*).
    // A unit bench with synthetic addresses declares everything memory: DRAM_BASE = 0.
    parameter [55:0] DRAM_BASE = 56'h8000_0000,
    parameter [63:0] LRAM_BASE = 64'h7000_0000,
    parameter        LRAM_LG2  = 18)
   (input  wire                  clk,
    input  wire                  reset,

    // ---- allocate: at dispatch, program order, one per cycle ----
    input  wire                  d_alloc,
    input  wire [ROBB-1:0]       d_rob,
    input  wire [PBITS-1:0]      d_prd,
    input  wire [5:0]            d_rd,
    input  wire                  d_rd_v,
    input  wire [SQIB-1:0]       d_sqtag,     // store-seqno captured at the same dispatch
    input  wire                  d_wt,        // the load's wait bit: it waits for older stores' unknown addresses
    input  wire [VAW-1:0]        d_pc,        // the load's PC and seq, for a trap from its translation
    input  wire [SEQW-1:0]       d_seq,
    output wire                  d_ready,
    output wire                  d_ready2,    // room for two (the dispatch credit's)
    output wire [IDXB-1:0]       d_idx,

    // ---- fill: the address is translated; M lets go here ----
    // a_sent says the SAME cycle also handed the access to memory (see the header). The
    // entry goes straight to `sent` -- it never becomes a candidate, because it has already
    // been what a candidate is for.
    input  wire                  a_v,
    input  wire                  a_sent,
    input  wire [IDXB-1:0]       a_idx,
    input  wire [PAW-1:0]        a_pa,        // ...its PA, when a_tv
    input  wire [VAW-1:0]        a_va,        // the VA, always: the alias test and the walker read it
    input  wire                  a_tv,        // M's lookup translated it (else the walker will)
    input  wire                  a_flt,       // ...or its address alone faults (a_tv is then set)
    input  wire [3:0]            a_fc,
    input  wire [1:0]            a_size,
    input  wire                  a_signed,
    input  wire                  a_fp,
    input  wire                  a_unc,       // Svpbmt NC/IO: decided by the translation, travels with the entry
    input  wire                  a_mem,       // the PA is DRAM/LRAM (idempotent) -> may access speculatively
    input  wire                  a_bare,      // the address was not translated (M-mode or satp Bare)

    // ---- disambiguation: a BIT PER ENTRY, maintained by smolrv64_sq -----------------------
    // The entries are exported so smolrv64_sq can run the alias test where an ADDRESS ARRIVES
    // and hand back a flop. Asking it at issue instead put the candidate at the head of a 36-level,
    // 12x CARRY8 cone ending at the frontend's redirect register: WNS -1.698 ns at
    // 166.67 MHz, 18 670 failing endpoints, all five worst paths sourced here. Moving the
    // address off the TRANSLATE path -- this module's original purpose -- left the compare
    // itself, and its whole downstream tail, exactly where they were.
    output wire [NENT*12-1:0]    e_off,       // page offsets: VA[11:0] = PA[11:0]
    output wire [NENT*(VAW-11)-1:0] e_vpn,    // ...and the page, {bare, VA[VAW-1:12]}, for forwarding (smolrv64_sq cov)
    output wire [NENT*2-1:0]     e_size,
    output wire [NENT*SQIB-1:0]  e_tag,
    output wire [NENT-1:0]       e_av,
    output wire [NENT*PCHB-1:0]  e_pch,       // each entry's PC hash (the wait table's index)
    output wire [NENT-1:0]       e_wt,        // each entry's wait bit...
    output wire [NENT-1:0]       e_acc,       // ...and whether it has reached memory (sent, or landed and watched)
    input  wire [NENT-1:0]       unk_q,       // smolrv64_sq: an older store's address is still unknown (registered)
    input  wire [NENT-1:0]       viol,        // smolrv64_sq: it went ahead of an older store that overlaps it
    input  wire [NENT-1:0]       e_block,     // per entry: an older store aliases it
    // ...and it can take its bytes from that store instead (smolrv64_sq, registered): the store
    // covers them, has its data, and every older store's address is known. Forwards wait for their
    // landing in the LSU, two deep; fw_busy says both are waiting.
    input  wire [NENT-1:0]       e_fwd,
    input  wire                  fw_busy,
    output wire                  x_block,     // ...and the candidate is one, held right now
    output wire                  x_devwait,   // the candidate is a device load waiting to be the head (counters only)
    // ...and the seqno of the entry being tested, for smolrv64_sq's ld_older. That one is
    // pointer arithmetic against head, with no address and no adder in it.
    output wire [SQIB-1:0]       q_tag,

    // ---- early start: may the core collapse fill and access for the entry M holds? ----
    // A load with no older live store has nothing to be ordered against (loads reach memory in
    // the order they are ready, see the candidate below), so it may start in its own fill pass.
    input  wire [IDXB-1:0]       b_idx,       // the entry M's load owns
    output wire                  b_ok,        // ...and it is live and not yet filled

    // ---- access: hand the D$ the oldest entry that is clear ----
    output wire                  x_v,
    output wire [IDXB-1:0]       x_idx,       // the entry being offered -- the response's tag
    output wire [PAW-1:0]        x_pa,
    output wire [1:0]            x_size,
    output wire                  x_signed,
    output wire                  x_fp,
    output wire                  x_unc,
    output wire                  x_head,      // the candidate's op is the ROB head (index compare; the core adds ~rob_empty)
    output wire                  x_fwd,       // the candidate is held by a store and takes its bytes from it
    input  wire                  x_take,      // the LSU accepted it

    // ---- land: data back for an entry that was sent to memory ----
    // The response names its ENTRY by the tag the requester allocated (rule B1), not by
    // age: the D$ answers out of order. l_idx is the landing entry; its payload is read at
    // both of the entries it can be, the D$ response's tag (l_tg) and the other candidate
    // (l_alt), each a register, and l_rsp (the D$'s response lands) picks the answer, so
    // the late pick reaches no array's index (rule I6). l_idx is l_rsp ? l_tg : l_alt.
    input  wire                  l_v,
    input  wire [IDXB-1:0]       l_idx,
    input  wire [IDXB-1:0]       l_tg,
    input  wire [IDXB-1:0]       l_alt,
    input  wire                  l_rsp,
    output wire [PBITS-1:0]      l_prd,
    output wire [5:0]            l_rd,
    output wire                  l_rd_v,
    output wire [ROBB-1:0]       l_rob,
    // The landing load's OWN address, for the cosim's memory-effect record. It has to come
    // from the entry that owns the load: the shared lsu_cos_* pair is whatever access ran
    // LAST, and since b9dbdd0 a queued load's access starts in its translate pass, a store
    // can and does start between a load's start and its landing.
    output wire [PAW-1:0]        l_pa,

    // ---- the walker: the candidate, when it has no translation yet ----
    output wire                  k_v,
    output wire [IDXB-1:0]       k_idx,
    output wire [VAW-1:0]        k_va,
    input  wire                  w_v,         // the walker's answer for entry w_idx
    input  wire [IDXB-1:0]       w_idx,
    input  wire [PAW-1:0]        w_pa,
    input  wire                  w_unc,
    input  wire                  w_mem,
    input  wire                  w_flt,
    input  wire [3:0]            w_fc,
    // ---- a translation that faulted, at the candidate: it traps at the ROB head ----
    output wire                  f_v,
    output wire [IDXB-1:0]       f_idx,       // the entry it is: the oldest one whose translation faulted or that must replay
    output wire                  f_rp,        // ...a replay (it read before an older store that overlaps it), not a fault
    output wire [ROBB-1:0]       f_rob,
    output wire [3:0]            f_fc,
    output wire [VAW-1:0]        f_pc,
    output wire [SEQW-1:0]       f_seq,

    output wire [IDXB:0]         occupancy,
    output wire                  av_any,      // an entry with a known address: a load older than M's op, not landed (rule C5)
    output wire [NENT*PBITS-1:0] e_dprd,      // each live entry's destination, 0 when free (the stall counters)
    output wire                  uf_any,      // an entry that is not filled yet (live, no address in)
    // M's pick: the oldest live entry whose address has ARRIVED (ar: the core holds it for M) but
    // that M has not filled yet. M fills in arrival order, not program order.
    input  wire [NENT-1:0]       ar,
    output wire                  pk_v,
    output wire [IDXB-1:0]       pk_idx,
    output wire [SEQW-1:0]       pk_seq,
    input  wire [ROBB-1:0]       rob_head,    // head-gate an uncached (device) load's access (non-speculative)
    input  wire                  flush,
    // the kill (smolrv64_rob kd): the entries of ops younger than a mispredicted branch die.
    // They are the youngest, so the tail steps back to the oldest of them. kmask names every
    // slot whose op is dead while the kill holds, live or not (nothing allocates meanwhile): the
    // LSU drops their responses by tag, a load among them starting now included.
    input  wire                  kd_v,
    input  wire [(1 << ROBB)-1:0] kd,
    output wire [NENT-1:0]       kmask);

   // A tail pointer and a per-entry `sent` bit. Entries wait to go to memory in any order they
   // become ready; what is sent is outstanding or already landed. Pointers are what make flush a reset.
   reg [NENT-1:0]        v, av;              // live / address known
   reg [PAW-1:0]         pa   [0:NENT-1];
   reg [VAW-1:0]         va   [0:NENT-1];
   reg [VAW-1:0]         pc   [0:NENT-1];
   reg [SEQW-1:0]        sqn  [0:NENT-1];
   reg [NENT-1:0]        tv, flt;             // translated / ...and the translation faulted
   reg [3:0]             fc   [0:NENT-1];
   reg [1:0]             sz   [0:NENT-1];
   // EVERY ATTRIBUTE THE ACCESS NEEDS TRAVELS WITH THE ENTRY. `unc` was missing: a queued
   // load went to the LSU with the uncached bit hardwired to 0 (smolrv64_core's pt_unc), so a
   // Svpbmt NC load whose access came from the queue -- rather than the early start, which
   // reads the MMU's bit directly -- was cached, the line stayed resident, and every later
   // read of it hit stale data. Linux's virtio rings live in exactly such memory: "id 0 is
   // not a head!" on the board, 2026-09-04, with no simulation able to see it (the cosim's
   // guest maps nothing NC). The store queue had carried its own bit all along.
   reg [NENT-1:0]        sgn, isfp, unc;
   reg [NENT-1:0]        mem;                 // PA is DRAM/LRAM (idempotent): may access speculatively
   reg [NENT-1:0]        bare;                // the address was not translated (smolrv64_sq a_bare)
   reg [PBITS-1:0]       prd  [0:NENT-1];
   reg [5:0]             rdn  [0:NENT-1];
   reg [NENT-1:0]        rdv;
   reg [ROBB-1:0]        rob  [0:NENT-1];
   reg [SQIB-1:0]        sqt  [0:NENT-1];
   // `sent` replaces a HEAD pointer, which could only say "the OLDEST entry is outstanding".
   // That stops being the same question once an entry can reach memory without ever being
   // the candidate (a_sent). Per entry it is exact, and it is what the landing assertion
   // below actually wants to know.
   reg [NENT-1:0]        sent;                // handed to memory, data not back yet (or landed and watched)
   reg [NENT-1:0]        wt;                  // the load waits for older stores' unknown addresses
   reg [NENT-1:0]        lnd;                 // landed, and still here: an older store's address is unknown
   reg [NENT-1:0]        rpl;                 // sticky: it read before an older store that overlaps it
   reg [NENT-1:0]        fwd;                 // sent as a forward: it read a store, not memory
   reg [IDXB-1:0]        tail;
   reg [IDXB:0]          cnt;

   initial begin v = {NENT{1'b0}}; av = {NENT{1'b0}}; sent = {NENT{1'b0}};
                 wt = {NENT{1'b0}}; lnd = {NENT{1'b0}}; rpl = {NENT{1'b0}}; fwd = {NENT{1'b0}};
                 tail = {IDXB{1'b0}}; cnt = {(IDXB+1){1'b0}}; end

   // PROGRAM ORDER IS THE RING READ FROM THE TAIL: the slot at the tail is the oldest position,
   // the one before it the youngest. Every "oldest of these" below is ring_oldest(.., tail), with
   // no pointer to keep in step with entries that land and free out of order.
`include "smolrv64_ring.vh"

   // THE SLOT AT THE TAIL MUST BE FREE, not merely "the queue is not full". Loads land out of
   // order once they are pipelined (the tagged fast path; the random bench lands them in any
   // order), so the ring can wrap round to a slot whose load is still in flight while cnt
   // says there is room. Allocating there overwrote the entry and its landing then found
   // "an entry that was never sent" (2026-09-04). Waiting on that one slot is head-of-line
   // blocking at a miss; at NENT=4 the pointer ring is the right size for it.
   assign d_ready   = (cnt != NENT[IDXB:0]) & ~v[tail];
   wire [IDXB-1:0] tail1 = tail + 1'b1;
   assign d_ready2  = (cnt <= NENT[IDXB:0] - 2) & ~v[tail] & ~v[tail1];
   assign d_idx     = tail;
   assign occupancy = cnt;
   assign av_any    = |(v & av & ~lnd);
   genvar gd;
   generate
      for (gd = 0; gd < NENT; gd = gd + 1) begin : g_dprd
         assign e_dprd[gd*PBITS +: PBITS] = (v[gd] & ~lnd[gd]) ? prd[gd] : {PBITS{1'b0}};
      end
   endgenerate
   assign uf_any    = |(v & ~av);
   wire [NENT-1:0] pk_m = v & ~av & ar;
   assign pk_v      = |pk_m;
   assign pk_idx    = ring_oldest(pk_m, tail);
   assign pk_seq    = sqn[pk_idx];

   // THE ACCESS CANDIDATE is the oldest entry that may go to memory now: filled and translated,
   // not faulting, not yet sent, no older store aliasing it (e_block, a register per entry; an
   // older store whose address is unknown counts), and either idempotent memory or, for a device
   // load, its op at the ROB head. Loads reach memory in the order they become ready, not in
   // program order: a single hart sees no difference between two loads in either order, a store
   // never commits ahead of an older load that has not landed (the irrevocable pointer), and
   // device loads wait for the head, which orders them against everything older.
   // ...and NOT already sent: with every entry taken and none landed the ring wraps round to a
   // live, translated entry IN FLIGHT, and `v & av` would offer it a second time.
   // "ITS OP IS THE ROB HEAD" IS A FLOP PER ENTRY (hd), compared against the head register as
   // it stands: a device load goes the cycle after the head reaches it, and the flag is never
   // set for an entry that is not the head -- a live entry at the head stays there until it
   // lands, and a slot freed and refilled in one cycle is unfilled (av) for longer than the
   // flag's one-cycle lag. The head register is otherwise in front of the candidate pick, and
   // through the LSU's start, in front of M's completion and every scheduler's wake.
   wire [NENT-1:0] cand_m;
   wire [NENT-1:0] head_m;
   reg  [NENT-1:0] hd;
   initial hd = {NENT{1'b0}};
   genvar gc;
   generate for (gc = 0; gc < NENT; gc = gc + 1) begin : g_cand
      assign cand_m[gc] = v[gc] & av[gc] & ~sent[gc] & tv[gc] & ~flt[gc];
      assign head_m[gc] = (rob[gc] == rob_head);
   end endgenerate
   always @(posedge clk) hd <= reset ? {NENT{1'b0}} : (v & head_m);
   always @(posedge clk) if (!reset && |(cand_m & hd & ~head_m))
      $fatal(1, "smolrv64_lq: a candidate's head flag is set while its op is not the head (hd=%b head_m=%b cand=%b)", hd, head_m, cand_m);
   // A held load is ready too when it can forward: idempotent memory only (a device or uncached
   // load reads the device), and while no other forward is in flight.
   wire [NENT-1:0] fwd_m = e_fwd & mem & ~unc & {NENT{~fw_busy}};
   wire [NENT-1:0] rdy_m = cand_m & (~e_block | fwd_m) & (mem | hd);
   // THE WALKER AND THE TRAP READ THE OLDEST ENTRY THAT NEEDS THEM: an untranslated filled load
   // is walked oldest first, and a load whose translation faulted is never sent: it traps when
   // its op reaches the ROB head.
   wire [NENT-1:0] wlk_m = v & av & ~sent & ~tv;
   wire [NENT-1:0] flt_m = (v & av & ~sent & tv & flt) | (v & rpl);
   assign k_v   = |wlk_m;
   assign k_idx = ring_oldest(wlk_m, tail);
   assign k_va  = va[k_idx];
   wire [IDXB-1:0] fi = ring_oldest(flt_m, tail);
   assign f_v   = |flt_m;
   assign f_idx = fi;
   assign f_rp  = rpl[fi];
   assign f_rob = rob[fi];
   assign f_fc  = fc[fi];
   assign f_pc  = pc[fi];
   assign f_seq = sqn[fi];
   // M's load can start its access in its fill pass whenever the entry is live and unfilled
   assign b_ok = v[b_idx] & ~av[b_idx];
   // the older-store query is about M's load when it holds an unfilled one, else the oldest filled
   // entry still waiting to go to memory
   wire [IDXB-1:0] qi = b_ok ? b_idx : ring_oldest(v & av & ~sent, tail);
   assign q_tag   = sqt[qi];
   genvar ge;
   generate
      for (ge = 0; ge < NENT; ge = ge + 1) begin : g_exp
         assign e_off [ge*12   +: 12  ] = va [ge][11:0];
         assign e_vpn [ge*(VAW-11) +: VAW-11] = {bare[ge], va[ge][VAW-1:12]};
         assign e_size[ge*2    +: 2   ] = sz [ge];
         assign e_tag [ge*SQIB +: SQIB] = sqt[ge];
      end
   endgenerate
   assign e_av = av;
   assign e_wt = wt;
   generate for (gd = 0; gd < NENT; gd = gd + 1) begin : g_pch
      assign e_pch[gd*PCHB +: PCHB] = pc[gd][PCHB:1];
   end endgenerate
   // A forwarded load counts as having reached memory: a store older than it whose address arrives
   // and overlaps it flags it for replay. Its forwarding store does not (the store queue sets that
   // overlap aside while the load stands forwarded).
   assign e_acc = v & sent;
   wire [IDXB-1:0] xi = ring_oldest(rdy_m, tail);
   assign x_head  = hd[xi];
   assign x_v     = |rdy_m;
   assign x_block = |(cand_m & e_block);   // instrumentation only
   assign x_devwait = |(cand_m & ~e_block & ~mem & ~hd) & ~x_v;   // instrumentation only
   assign x_idx   = xi;
   assign x_fwd   = e_block[xi];
   assign x_pa    = pa[xi];
   assign x_size  = sz[xi];
   assign x_signed= sgn[xi];
   assign x_fp    = isfp[xi];
   assign x_unc   = unc[xi];

   // The landing entry's payload, read at both candidates and picked by l_rsp.
   assign l_prd  = l_rsp ? prd[l_tg] : prd[l_alt];
   assign l_rd   = l_rsp ? rdn[l_tg] : rdn[l_alt];
   assign l_rd_v = l_rsp ? rdv[l_tg] : rdv[l_alt];
   assign l_rob  = l_rsp ? rob[l_tg] : rob[l_alt];
   assign l_pa   = l_rsp ? pa[l_tg]  : pa[l_alt];


   // THE KILL. The dead entries are the youngest live ones (the ring is program order), so the
   // tail steps back to the oldest of them, kd0: the slots after it are dead or landed. The
   // candidate pointer goes there too unless it names a live, unsent entry that survives (an
   // older load still waiting): at the tail with nothing waiting it can name an earlier lap's
   // load in flight, which is not one.
   reg  [NENT-1:0] kmk, kds;
   integer         kq, kw;
   always @* begin
      for (kq = 0; kq < NENT; kq = kq + 1) begin
         kds[kq] = kd_v & kd[rob[kq]];
         kmk[kq] = kds[kq] & v[kq];
      end
   end
   // the oldest dead entry
   wire [IDXB-1:0]   kd0 = ring_oldest(kmk, tail);
   assign kmask = kds;
   wire          k_any = |kmk;
   // WATCHING. A load that landed while an older store's address was still unknown stays (lnd,
   // address valid) until that store's address is in and showed no overlap; one flagged for replay
   // stays until it replays. Everything else leaves at its landing.
   wire            lwatch = l_v & (unk_q[l_idx] | rpl[l_idx] | viol[l_idx]);
   wire [NENT-1:0] wfree  = v & lnd & ~unk_q & ~rpl & ~viol;
   // the entries that leave the live set this cycle (one popcount, so an entry counts once)
   reg  [NENT-1:0] gone;
   reg  [IDXB:0]   gone_n;
   integer         gn;
   always @* begin
      gone = wfree | kmk;
      if (l_v & ~lwatch) gone[l_idx] = 1'b1;
      gone_n = {(IDXB+1){1'b0}};
      for (gn = 0; gn < NENT; gn = gn + 1) gone_n = gone_n + {{IDXB{1'b0}}, gone[gn]};
   end

   always @(posedge clk) begin
      if (reset) begin
         v <= {NENT{1'b0}}; av <= {NENT{1'b0}}; sent <= {NENT{1'b0}};
         lnd <= {NENT{1'b0}}; rpl <= {NENT{1'b0}};
         tail <= {IDXB{1'b0}};
         cnt <= {(IDXB+1){1'b0}};
      end else begin
         // Retiring the entry frees its slot; slot REUSE is governed by cnt and tail, so an
         // out-of-order response simply leaves the slot dead until tail comes round to it.
         if (l_v & ~lwatch) begin v[l_idx] <= 1'b0; av[l_idx] <= 1'b0; sent[l_idx] <= 1'b0; fwd[l_idx] <= 1'b0; end
         if (l_v & lwatch)  lnd[l_idx] <= 1'b1;
         for (kw = 0; kw < NENT; kw = kw + 1) begin
            if (wfree[kw]) begin v[kw] <= 1'b0; av[kw] <= 1'b0; sent[kw] <= 1'b0; lnd[kw] <= 1'b0; fwd[kw] <= 1'b0; end
            if (viol[kw] & v[kw]) rpl[kw] <= 1'b1;
         end
         if (x_v & x_take) begin sent[x_idx] <= 1'b1;  fwd[x_idx] <= x_fwd; end
         if (d_alloc & d_ready) begin
            v[tail] <= 1'b1; av[tail] <= 1'b0; sent[tail] <= 1'b0;  lnd[tail] <= 1'b0;  rpl[tail] <= 1'b0;  wt[tail] <= d_wt;
            fwd[tail] <= 1'b0;
            rob[tail] <= d_rob; prd[tail] <= d_prd; rdn[tail] <= d_rd;
            rdv[tail] <= d_rd_v; sqt[tail] <= d_sqtag;  pc[tail] <= d_pc;  sqn[tail] <= d_seq;
            tail <= tail + 1'b1;
         end
         cnt <= cnt + {{IDXB{1'b0}}, (d_alloc & d_ready)} - gone_n;

         if (a_v) begin
            pa[a_idx] <= a_pa;  va[a_idx] <= a_va;  sz[a_idx] <= a_size;
            sgn[a_idx] <= a_signed;  isfp[a_idx] <= a_fp;  unc[a_idx] <= a_unc;  mem[a_idx] <= a_mem;  av[a_idx] <= 1'b1;
            bare[a_idx] <= a_bare;
            tv[a_idx] <= a_tv;  flt[a_idx] <= a_flt;  fc[a_idx] <= a_fc;
         end
         // the walker's answer: the PA and its classes, or the fault the load traps with at the head
         if (w_v) begin
            pa[w_idx] <= w_pa;  unc[w_idx] <= w_unc;  mem[w_idx] <= w_mem;  flt[w_idx] <= w_flt;  fc[w_idx] <= w_fc;
            tv[w_idx] <= 1'b1;
         end
         // Filled AND already gone. It cannot collide with x_take above: that one needs a filled
         // entry, and a_sent is asserted only for one that is not filled yet (b_ok).
         if (a_v & a_sent) sent[a_idx] <= 1'b1;
         // The kill, after every other arm (a dead entry landing, filled or sent now dies all the
         // same; a dead entry landing now is counted once) and before the flush. Nothing
         // allocates while it holds (asserted).
         if (k_any) begin
            for (kw = 0; kw < NENT; kw = kw + 1)
               if (kmk[kw]) begin v[kw] <= 1'b0;  av[kw] <= 1'b0;  sent[kw] <= 1'b0;  lnd[kw] <= 1'b0;  rpl[kw] <= 1'b0;  fwd[kw] <= 1'b0; end
            tail <= kd0;
         end
         // The flush, ordered LAST: it wins over an allocation made in its cycle (dispatch
         // is not gated on the redirect since gate V3, 2026-09-05). Nothing older than the
         // redirecting op is in flight, so every entry is younger and dies.
         if (flush) begin
            v <= {NENT{1'b0}}; av <= {NENT{1'b0}}; sent <= {NENT{1'b0}};
            lnd <= {NENT{1'b0}}; rpl <= {NENT{1'b0}}; fwd <= {NENT{1'b0}};
            tail <= {IDXB{1'b0}};
            cnt <= {(IDXB+1){1'b0}};
         end
      end
   end

   // D12 (2026-09-17): the "DRAM, idempotent, may issue speculatively" bit names the entry's OWN
   // address. smolrv64_lsu derives it from the translate; here it is recomputed from the PA the
   // entry stores, so a fill that took ANOTHER access's classification (the port's, the day
   // the board's NIC died) dies at the fill, in every cosim, on the first device load of a
   // boot -- not on the board hours later.
   // (a_pa >= DRAM_BASE as a borrow, so a bench's DRAM_BASE = 0 is not a constant compare)
   wire [PAW:0] a_dram_off = {1'b0, a_pa} - {1'b0, DRAM_BASE};
   wire a_mem_chk = ~a_dram_off[PAW] | (a_pa[PAW-1:LRAM_LG2] == LRAM_BASE[PAW-1:LRAM_LG2]);
   wire [PAW:0] w_dram_off = {1'b0, w_pa} - {1'b0, DRAM_BASE};
   wire w_mem_chk = ~w_dram_off[PAW] | (w_pa[PAW-1:LRAM_LG2] == LRAM_BASE[PAW-1:LRAM_LG2]);
   always @(posedge clk) if (!reset && w_v && ~w_flt && (w_mem != w_mem_chk))
      $fatal(1, "smolrv64_lq: the walker classifies pa=%h for entry %0d as %0s, its region says %0s (rule D12)",
             w_pa, w_idx, w_mem ? "memory" : "device", w_mem_chk ? "memory" : "device");
   always @(posedge clk) if (!reset && a_v && a_tv && ~a_flt && (a_mem != a_mem_chk))
      $fatal(1, "smolrv64_lq: fill %0d classifies pa=%h as %0s, its region says %0s (rule D12)",
             a_idx, a_pa, a_mem ? "memory" : "device", a_mem_chk ? "memory" : "device");

   // Invariants (docs/rtl-rules.md A1). Every one of these is something the queue would
   // otherwise do silently and wrongly.
   integer ia;
   always @(posedge clk) if (!reset) begin
      if (d_alloc & ~d_ready)
         $fatal(1, "smolrv64_lq: allocate into a full queue");
      if (d_alloc & kd_v & ~flush)
         $fatal(1, "smolrv64_lq: an allocation while the kill holds");
      if (d_alloc & d_ready & v[tail])
         $fatal(1, "smolrv64_lq: allocate into slot %0d while its load is in flight", tail);
      if (a_v & ~v[a_idx])
         $fatal(1, "smolrv64_lq: address written to a slot with no live entry (idx %0d)", a_idx);
      if (a_v & av[a_idx])
         $fatal(1, "smolrv64_lq: address written twice to slot %0d", a_idx);
      if (l_v & (l_idx != (l_rsp ? l_tg : l_alt)))
         $fatal(1, "smolrv64_lq: the landing entry %0d is not the payload's pick (tag %0d, other %0d, response %b)",
                l_idx, l_tg, l_alt, l_rsp);
      if (l_v & ~v[l_idx])
         $fatal(1, "smolrv64_lq: data landed for a slot with no live entry (idx %0d)", l_idx);
      if (l_v & ~sent[l_idx])
         $fatal(1, "smolrv64_lq: data landed for an entry that was never sent to memory (idx %0d)", l_idx);
      if (x_v & x_take & (~av[x_idx] | sent[x_idx]))
         $fatal(1, "smolrv64_lq: started an access for entry %0d with no address or already sent", x_idx);
      if (a_v & a_sent & ~b_ok)
         $fatal(1, "smolrv64_lq: entry %0d started early but is not a live unfilled entry", a_idx);
      if (a_v & a_sent & x_v & x_take)
         $fatal(1, "smolrv64_lq: an early start and a candidate start in the same cycle");
      if (a_v & a_sent & ~a_tv)
         $fatal(1, "smolrv64_lq: entry %0d started early without a translation", a_idx);
      if (x_v & x_take & ~tv[x_idx])
         $fatal(1, "smolrv64_lq: the candidate started without a translation");
      if (x_v & x_take & x_fwd & ~(e_fwd[x_idx] & mem[x_idx] & ~unc[x_idx] & ~fw_busy))
         $fatal(1, "smolrv64_lq: entry %0d forwards without a forwarding store (fwd=%b mem=%b unc=%b busy=%b)",
                x_idx, e_fwd[x_idx], mem[x_idx], unc[x_idx], fw_busy);
      if (w_v & ~(v[w_idx] & av[w_idx] & ~tv[w_idx]))
         $fatal(1, "smolrv64_lq: the walker's answer for entry %0d is not for a live untranslated entry", w_idx);
      if (w_v & a_v & (a_idx == w_idx))
         $fatal(1, "smolrv64_lq: entry %0d filled and translated in one cycle", w_idx);
   end
endmodule
`default_nettype wire
