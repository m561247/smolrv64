`include "smolrv64_tags.vh"
`default_nettype none

// The fetch ring: RS halfword slots holding the instruction stream from the PC on, filled from
// the I$ one window (up to 16 bytes from any halfword) at a time along the path the predictor steers
// (docs/PLAN-2026-09-24-frontend-stage4.md, increment 1).
//
// Its head IS the PC: fetch reports how many halfwords it consumed each cycle (adv_hw), and the
// head advances by them. A predicted-taken branch does not empty the ring: the predictor already
// steered the stream to its target, so the target's halfwords follow the branch's in the ring. A
// restart (a redirect, or a prediction the aligner rejected) empties it and restarts the stream at
// the next PC, which the iMMU translates that cycle. The window fetch aligns is a rotation of the
// ring from its registered head, with a mark on each halfword that ends a CTI the predictor knows.
//
// THE STREAM. One window per accepted I$ request: up to eight halfwords from the stream's address,
// never across its 4 KiB page (smolrv64_predictor's w_one), answered by bank (halfword b at address
// bits [3:1] == b, as the predictor marks it) and appended in window order -- bank b at the tail plus
// its position, b minus the window's first halfword -- running ahead
// of the PC while the ring has room for a whole window and the predictor has room for the window's
// prediction. The predictor (smolrv64_predictor) holds the stream's address (sa, sk) and looks the
// window up as it is requested: a window ends at the first CTI it knows at or after the stream's
// address, and the stream goes on at the predicted next address.
// The stream stays inside the PC's enclosing page (4 KiB, or 2 MiB for a >= 2 MiB leaf), whose PA
// the iMMU holds for the PC; increment 1d translates on an I$ miss instead. Answers come back in
// order, and each request in flight is an entry of a small FIFO (fq_*) with its halfwords, its
// marks and a kill bit: a flush kills every one in flight, and a correction of the predictor's
// (cancel) the youngest one or two -- a window its first-level BTB mispredicted and the one after
// it -- whose halfwords the reservation and whose marks the count give back. A killed request's
// answer is not written; the generation in the tag only cross-checks a flush. A fence.i or a
// mapping change (freeze) empties the ring while it runs.
module smolrv64_fring
  #(parameter HW  = 8,                      // the window fetch aligns, in halfwords
    parameter PQB = 3,                      // the predictor's queue (for the mark count check)
    parameter PCW = 40)                     // a PC's bits (smolrv64_pc.vh); the I$ ports are 64
   (input  wire                    clk,
    input  wire                    reset,
    input  wire                    freeze,  // fence.i, an I$ invalidation, a mapping change, a rejected mark
    input  wire                    restart, // a redirect: empty and restart the stream at rst_a
    // what fetch consumed, and the prediction it took (for the head's VA)
    input  wire [$clog2(HW+2)-1:0] adv_hw,
    input  wire                    take,       // fetch took a taken prediction...
    input  wire                    drop,    // clear the head's mark
    input  wire [PCW-1:0]          take_tgt,   // ...to here: the head's VA jumps to it
    // the PC and its translation (the iMMU)
    input  wire [PCW-1:0]          pc_va,
    input  wire [PCW-1:0]          rst_a,   // where a restarted stream begins: the redirect's target, else the PC
    input  wire [PCW-1:0]          pc_pa,
    input  wire [1:0]              pc_lvl,  // leaf level: 0 = 4 KiB, else >= 2 MiB
    input  wire                    xlate_ok,
    // the window: HW halfwords from the head, and their marks
    output wire [HW*16-1:0]        win,
    output wire [HW-1:0]           mk,
    output wire [HW-1:0]           st,      // ...and which halfwords begin an instruction
    output wire [$clog2(HW+2)-1:0] avail,
    output wire                    ok,
    output wire [1:0]              lvl,     // page size of the bytes held
    // the predictor: the stream's window, where it ends, and the ring taking it
    input  wire [PCW-1:0]          sa,      // the window's first pair's first byte...
    input  wire [2:0]              sk,      // ...and the window's first halfword in it
    input  wire [7:0]              p_mk,       // the window's marked halfwords, by bank...
    input  wire [2:0]              p_end,      // ...and its last
    output wire                    pr_adv,
    input  wire                    pq_room,
    input  wire                    cancel,  // a correction: drop the youngest requests...
    input  wire [1:0]              cancel_n,   // ...this many (none taken this cycle)
    input  wire [PQB:0]            pq_cnt,
    // the I$ (rv_icache)
    output wire                    ic_req,
    output wire [63:0]             ic_va,
    output wire [63:0]             ic_pa,
    output wire [`SMOLRV64_ICTAG_W-1:0] ic_tag,
    output wire [2:0]              ic_last,    // the window's last halfword (rv_icache's rd_last)
    input  wire                    ic_ack,
    input  wire                    ic_valid,
    input  wire [127:0]            ic_data,
    input  wire [`SMOLRV64_ICTAG_W-1:0] ic_rtag,
    output wire [5:0]              err);      // its invariants, registered (the integrity log)

   localparam integer RS  = 32;                            // ring slots (halfwords): 64 bytes
   localparam integer RSB = $clog2(RS);
   localparam integer GW  = 3;                             // stream generation
   localparam integer AVW = $clog2(HW+2);
   // the halfwords and their start bits: a banked distributed RAM (u_rg below), one bank per halfword
   // of a window; the marks are flops, since fetch clears the head's (drop) as answers land
   reg  [RS-1:0]   rmk;                                    // the slot ends a known CTI
   reg             rg_cy;                                  // the last halfword appended began a 32-bit op
   reg  [RSB-1:0]  rg_head;
   reg  [RSB:0]    rg_cnt, rg_resv;                        // halfwords held; held + in flight
   reg  [GW-1:0]   rg_gen;
   reg  [1:0]      rg_lvl;                                 // page size of the bytes held
   reg  [PCW-1:0]  rg_hva;                                 // the head's VA (checked, never used)
   reg  [3:0]      rg_infl;                                // requests in flight
   reg  [PQB:0]    rg_mfl;                                 // marks in flight (checked)
   initial begin rg_head = 0; rg_cnt = 0; rg_resv = 0; rg_gen = 0;
                 rg_lvl = 2'd0; rg_infl = 0; rg_mfl = 0; rmk = 0; rg_cy = 1'b0; end
   wire            flush  = restart | freeze;

   // the request: the stream's window, inside the PC's enclosing page (a window never crosses 4 KiB,
   // whatever the page size: rv_icache takes both lines' physical tags from the request's frame)
   wire        big_pg  = (pc_lvl != 2'd0);
   wire        inpg    = big_pg ? (sa[PCW-1:21] == pc_va[PCW-1:21]) : (sa[PCW-1:12] == pc_va[PCW-1:12]);
   wire [3:0]  rq_n    = {1'b0, p_end} + 4'd1;                           // halfwords it appends
   wire [PCW-1:0] wa   = {sa[PCW-1:4], sk, 1'b0};                       // its first halfword
   // NOT gated by a restart: a restart comes out of the whole fetch cone (window -> aligner ->
   // fire), and the I$ door must not wait for it. A request taken in a restart's cycle belongs to
   // the old stream and is dropped by the count below like any other in flight. The room it asks
   // for is a whole window's, so the door does not wait for the prediction's cut either. The ring
   // holds two windows, so a bundle waiting for its bytes (the aligner's bytes_late) always leaves
   // room for the window that brings them.
   initial if (RS < HW + 8) $fatal(1, "smolrv64_fring: %0d slots cannot hold two %0d-halfword windows", RS, HW);
   assign ic_req = ~freeze & ~cancel & xlate_ok & inpg & pq_room & (rg_resv <= RS[RSB:0] - 5'd8);
   assign ic_va   = {25'b0, wa[38:0]};                     // VIRTUAL: canonical Sv39 VA (sign ext masked)
   assign ic_pa   = {{(64-PCW){1'b0}}, big_pg ? {pc_pa[PCW-1:21], wa[20:0]} : {pc_pa[PCW-1:12], wa[11:0]}};
   assign ic_last = p_end;
   assign ic_tag  = {p_mk, p_end, sk, rg_gen};
   initial if (`SMOLRV64_ICTAG_W != 8 + 3 + 3 + GW)
      $fatal(1, "smolrv64_fring: SMOLRV64_ICTAG_W is %0d, the tag's fields are %0d bits", `SMOLRV64_ICTAG_W, 8 + 3 + 3 + GW);
   function [3:0] ones8(input [7:0] x);
      integer i;
      begin ones8 = 4'd0; for (i = 0; i < 8; i = i + 1) ones8 = ones8 + {3'd0, x[i]}; end
   endfunction
   wire   rq_acc = ic_req & ic_ack;
   assign pr_adv = rq_acc;

   // the answer: the window's halfwords to its end, appended at the tail, each marked as the
   // window's prediction marked it. An answer landing in a restart's cycle belongs to the old
   // stream and is not written.
   // THE REQUESTS IN FLIGHT, oldest at fq_rp: each one's halfwords and marks, and its kill bit
   localparam integer FD = 8;
   reg  [3:0]    fq_n [0:FD-1];
   reg  [1:0]    fq_m [0:FD-1];
   reg  [FD-1:0] fq_k;
   reg  [2:0]    fq_rp, fq_wp;
   initial begin fq_rp = 3'd0;  fq_wp = 3'd0;  fq_k = {FD{1'b0}}; end
   wire [2:0]    yg0 = fq_wp - 3'd1, yg1 = fq_wp - 3'd2;  // the youngest two
   wire          c2  = cancel_n[1];
   wire [3:0]    rq_m = ones8(p_mk);                       // a request's marks (at most two)
   // what a correction gives back: the youngest one's halfwords and marks, and the next's when two
   wire [4:0]    gb_n = {1'b0, fq_n[yg0]} + (c2 ? {1'b0, fq_n[yg1]} : 5'd0);
   wire [2:0]    gb_m = {1'b0, fq_m[yg0]} + (c2 ? {1'b0, fq_m[yg1]} : 3'd0);
   // the answer at the head is kept unless it was killed, or a correction kills it now
   wire          hd_k = fq_k[fq_rp] | (cancel & (rg_infl <= {2'd0, cancel_n}));
   wire         rp_ok   = ic_valid & ~hd_k;
   wire [7:0]   rp_mk   = ic_rtag[GW+6 +: 8];              // the answer's marked halfwords, by bank
   wire [2:0]   rp_end  = ic_rtag[GW+3 +: 3];              // ...its last position
   wire [2:0]   rp_sk   = ic_rtag[GW +: 3];                // ...and its first halfword's bank
   wire [3:0]   rp_n    = rp_ok ? ({1'b0, rp_end} + 4'd1) : 4'd0;
   wire [RSB-1:0] tail  = rg_head + rg_cnt[RSB-1:0];
   wire [RSB:0]   adv_w = {{(RSB+1-AVW){1'b0}}, adv_hw};

   // the window: the ring from its head; a mark counts only on a halfword held
   wire [HW*17-1:0] rg_rd;
   genvar gw;
   generate for (gw = 0; gw < HW; gw = gw + 1) begin : wn
      wire [RSB-1:0] ix = rg_head + gw[RSB-1:0];
      assign win[gw*16 +: 16] = rg_rd[gw*17 + 1 +: 16];
      assign mk[gw]           = rmk[ix] & (rg_cnt > gw);
      assign st[gw]           = rg_rd[gw*17];
   end endgenerate
   assign avail = (rg_cnt >= HW[RSB:0]) ? HW[AVW-1:0] : rg_cnt[AVW-1:0];
   assign ok    = ~freeze & (rg_cnt != {(RSB+1){1'b0}});
   assign lvl   = rg_lvl;

   // THE START BITS, PREDECODED AS THE BYTES ARRIVE: a halfword begins an instruction unless the one
   // before it began a 32-bit op. The stream is the instruction stream in order (a predicted-taken
   // window ends at its CTI's last halfword), so the chain runs on from the last halfword appended
   // (rg_cy) and a restart begins it afresh at the PC. The aligner then needs no length scan. The
   // chain runs in window order (rp_st), and each bank takes its position's bit (rp_sb).
   reg [7:0] rp_st, rp_sb;
   reg       rp_cy;
   reg [2:0] sb;
   integer   sj;
   always @* begin
      rp_cy = rg_cy;
      for (sj = 0; sj < 8; sj = sj + 1) begin
         sb        = rp_sk + sj[2:0];
         rp_st[sj] = ~rp_cy;
         if (sj <= rp_end) rp_cy = rp_st[sj] & (ic_data[sb*16 +: 2] == 2'b11);
      end
      for (sj = 0; sj < 8; sj = sj + 1) begin sb = sj[2:0] - rp_sk;  rp_sb[sj] = rp_st[sb]; end
   end
   integer j;
   always @(posedge clk) begin
      // the requests in flight: a flush kills them all (a request taken in its cycle too), a
      // correction the youngest cancel_n
      rg_infl <= reset ? 4'd0 : rg_infl + {3'd0, rq_acc} - {3'd0, ic_valid};
      if (reset) begin
         fq_rp <= 3'd0;  fq_wp <= 3'd0;
      end else begin
         if (ic_valid) fq_rp <= fq_rp + 3'd1;
         if (rq_acc) begin
            fq_wp <= fq_wp + 3'd1;
            fq_n[fq_wp] <= rq_n;  fq_m[fq_wp] <= rq_m[1:0];
         end
         for (j = 0; j < FD; j = j + 1)
            if (flush | (cancel & ((j[2:0] == yg0) | (c2 & (j[2:0] == yg1))))) fq_k[j] <= 1'b1;
            else if (rq_acc & (j[2:0] == fq_wp)) fq_k[j] <= 1'b0;
      end
      if (reset | flush) begin
         rg_cnt <= 0;  rg_resv <= 0;  rg_head <= 0;  rg_mfl <= 0;  rg_cy <= 1'b0;
         rg_hva <= rst_a;
         if (flush) rg_gen <= rg_gen + 1'b1;
      end else begin
         rg_head <= rg_head + adv_w[RSB-1:0];
         rg_cnt  <= rg_cnt + {{(RSB-3){1'b0}}, rp_n} - adv_w;
         rg_resv <= rg_resv + (rq_acc ? {{(RSB-3){1'b0}}, rq_n} : {(RSB+1){1'b0}}) - adv_w
                            - (cancel ? {{(RSB-4){1'b0}}, gb_n} : {(RSB+1){1'b0}});
         rg_mfl  <= rg_mfl + (rq_acc ? {{(PQB+1-4){1'b0}}, ones8(p_mk)} : {(PQB+1){1'b0}})
                           - (rp_ok ? {{(PQB+1-4){1'b0}}, ones8(rp_mk)} : {(PQB+1){1'b0}})
                           - (cancel ? {{(PQB+1-3){1'b0}}, gb_m} : {(PQB+1){1'b0}});
         rg_hva  <= take ? take_tgt : rg_hva + {{(PCW-1-AVW){1'b0}}, adv_hw, 1'b0};
         if (rq_acc) rg_lvl <= pc_lvl;
         if (drop) rmk[rg_head] <= 1'b0;
         if (rp_ok) rg_cy <= rp_cy;
         for (j = 0; j < 8; j = j + 1)
            if (rp_wv[j]) rmk[rp_wp[j*RSB +: RSB]] <= rp_mk[j];
      end
   end
   // the answer's halfwords to its end, at the tail on in window order: one writer per bank
   wire [7:0]     rp_wv;
   wire [8*RSB-1:0] rp_wp;
   wire [8*17-1:0]  rp_wd;
   genvar ga;
   generate for (ga = 0; ga < 8; ga = ga + 1) begin : an
      wire [2:0] pos = ga[2:0] - rp_sk;                    // bank ga's position in the window
      assign rp_wv[ga] = ~reset & ~flush & rp_ok & (pos <= rp_end);
      assign rp_wp[ga*RSB +: RSB] = tail + {{(RSB-3){1'b0}}, pos};
      assign rp_wd[ga*17 +: 17] = {ic_data[ga*16 +: 16], rp_sb[ga]};
   end endgenerate
   wire [HW*3-1:0] rg_ro;                       // the window: HW consecutive halfwords
   generate for (ga = 0; ga < HW; ga = ga + 1) begin: ro
      assign rg_ro[ga*3 +: 3] = ga[2:0];
   end endgenerate
   smolrv64_bankq #(.W(17), .DEPTH(RS), .NW(8), .NR(HW), .NB(8)) u_rg
     (.clk(clk), .reset(reset), .wv(rp_wv), .wp(rp_wp), .wd(rp_wd), .rp(rg_head), .ro(rg_ro), .rd(rg_rd));
   // The ring's head is the PC, what it holds and has in flight fits, and every mark held or in
   // flight has its prediction queued.
   integer k;
   reg [PQB+1:0] n_mk;
   always @* begin
      n_mk = 0;
      for (k = 0; k < RS; k = k + 1)
         if (k < rg_cnt) n_mk = n_mk + {{(PQB+1){1'b0}}, rmk[rg_head + k[RSB-1:0]]};
   end
   wire chk     = ~reset & ~flush;
   wire e_head  = chk & (rg_cnt != 0) & (rg_hva != pc_va);
   wire e_over  = chk & ({1'b0, adv_hw} > rg_cnt);
   wire e_hold  = chk & (rg_cnt + rp_n > rg_resv);
   wire e_gen   = chk & rp_ok & (ic_rtag[GW-1:0] != rg_gen);
   // AN ANSWER TAKES TWO CYCLES (rv_icache: its banks, then its tags), so a correction two cycles
   // after a window, which kills its request and the next, always finds them in flight
   reg  acc_q;
   always @(posedge clk) acc_q <= ~reset & rq_acc;
   wire e_orph  = chk & ((ic_valid & ((rg_infl == 4'd0) | (acc_q & (rg_infl == 4'd1))))
                         | (cancel & (rg_infl < {2'd0, cancel_n})));
   wire e_marks = chk & (n_mk + {1'b0, rg_mfl} != {1'b0, pq_cnt});
   reg  [5:0] err_q;
   always @(posedge clk) err_q <= reset ? 6'd0 : {e_marks, e_orph, e_gen, e_hold, e_over, e_head};
   assign err = err_q;
   always @(posedge clk) begin
      if (e_head)  $fatal(1, "smolrv64_fring: the ring's head %h is not the PC %h", rg_hva, pc_va);
      if (e_over)  $fatal(1, "smolrv64_fring: fetch consumed %0d halfwords of a ring holding %0d", adv_hw, rg_cnt);
      if (e_hold)  $fatal(1, "smolrv64_fring: the ring holds more (%0d) than it reserved (%0d)", rg_cnt + rp_n, rg_resv);
      if (e_gen)   $fatal(1, "smolrv64_fring: a kept I$ answer is from generation %0d, the stream is %0d", ic_rtag[GW-1:0], rg_gen);
      if (e_orph)  $fatal(1, "smolrv64_fring: an I$ answer with none in flight or a cycle after its request, or a correction of %0d with %0d in flight",
                          cancel_n, rg_infl);
      if (e_marks) $fatal(1, "smolrv64_fring: %0d marks held and %0d in flight, but %0d predictions queued", n_mk, rg_mfl, pq_cnt);
   end
endmodule

`default_nettype wire
