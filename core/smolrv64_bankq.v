`default_nettype none

// A circular array of DEPTH entries in NB distributed-RAM banks (entry p in bank p % NB, at index
// p / NB), written up to NW entries a cycle and read NR CONSECUTIVE entries a cycle from rp.
//
// WHY. A queue that takes several entries a cycle, held in flops, pays a mux at EVERY entry (which
// writer lands here?) and a DEPTH:1 mux per read; both are the size of the array (rule I7). Banked,
// the writes of one cycle go to distinct banks, each bank takes one write (one write statement per
// LUTRAM bank), and a bank's single read is the entry at or after rp, so the muxes are one per BANK.
//
// THE WRITES. Writer j writes wd[j] at position wp[j] when wv[j]; the positions of one cycle's
// writers are distinct mod NB (consecutive positions of a push, a queue's tail plus a rank), which
// is asserted. A bank's write is its one matching writer, chosen by an index, so the data side is
// an NW:1 mux per bank and bit.
//
// THE READS. rd[k] is the entry at rp + k, combinational, the value before this cycle's writes.
// NR <= NB, so the NR entries are in distinct banks, and bank b is read at the entry at or after
// rp in it. rp must be a register's value or close to it: it is every bank's read address (rule I6).
module smolrv64_bankq
  #(parameter W     = 16,                 // entry width
    parameter DEPTH = 32,                 // entries, a multiple of NB
    parameter NW    = 8,                  // writers a cycle
    parameter NR    = 8,                  // consecutive entries read a cycle
    parameter NB    = 8,                  // banks: a power of two, at least NW and NR
    parameter AB    = $clog2(DEPTH))
   (input  wire               clk,
    input  wire               reset,      // only the invariant checks: the array has no reset
    input  wire [NW-1:0]      wv,
    input  wire [NW*AB-1:0]   wp,         // writer j's position at [j*AB +: AB]
    input  wire [NW*W-1:0]    wd,
    input  wire [AB-1:0]      rp,
    output wire [NR*W-1:0]    rd);

   localparam integer BB = $clog2(NB);
   localparam integer BD = DEPTH / NB;    // entries a bank
   localparam integer IB = (BD > 1) ? $clog2(BD) : 1;
   localparam integer JB = (NW > 1) ? $clog2(NW) : 1;
   initial if ((1 << BB) != NB || NB < NW || NB < NR || DEPTH % NB != 0 || BD < 1 || (1 << AB) != DEPTH)
      $fatal(1, "smolrv64_bankq: DEPTH=%0d NB=%0d NW=%0d NR=%0d AB=%0d: NB is a power of two >= NW, NR, dividing DEPTH = 2**AB",
             DEPTH, NB, NW, NR, AB);

   wire [W-1:0] brd [0:NB-1];             // each bank's entry at or after rp
   genvar gb, gk;
   generate for (gb = 0; gb < NB; gb = gb + 1) begin: bank
      reg [W-1:0] mem [0:BD-1];
      integer i;
      initial for (i = 0; i < BD; i = i + 1) mem[i] = {W{1'b0}};
      // its writer: the one whose position is in this bank
      reg [NW-1:0] m;
      reg [JB-1:0] sel;
      integer j;
      always @* begin
         sel = {JB{1'b0}};
         for (j = 0; j < NW; j = j + 1) begin
            m[j] = wv[j] & (wp[j*AB +: BB] == gb[BB-1:0]);
            if (m[j]) sel = j[JB-1:0];
         end
      end
      wire [AB-1:0] wpos = wp[sel*AB +: AB];
      wire [IB-1:0] widx = (BD > 1) ? wpos[AB-1 -: IB] : {IB{1'b0}};
      always @(posedge clk) if (|m) mem[widx] <= wd[sel*W +: W];
      always @(posedge clk) if (!reset & ((m & (m - 1'b1)) != {NW{1'b0}}))
         $fatal(1, "smolrv64_bankq: writers %b all land in bank %0d", m, gb);
      // its read: the entry at or after rp
      wire [BB-1:0] off  = gb[BB-1:0] - rp[BB-1:0];
      wire [AB-1:0] rpos = rp + {{(AB-BB){1'b0}}, off};
      wire [IB-1:0] ridx = (BD > 1) ? rpos[AB-1 -: IB] : {IB{1'b0}};
      assign brd[gb] = mem[ridx];
   end endgenerate
   generate for (gk = 0; gk < NR; gk = gk + 1) begin: rk
      localparam [AB-1:0] K = gk;
      wire [AB-1:0] pos = rp + K;
      assign rd[gk*W +: W] = brd[pos[BB-1:0]];
   end endgenerate
endmodule

`default_nettype wire
