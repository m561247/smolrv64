`default_nettype none

// An array of DEPTH entries that NW writers write at any entries the same cycle, read at NR
// entries: a distributed-RAM bank per WRITER and a live-value table (lvt) naming, per entry, the
// writer that wrote it last.
//
// WHY. A RAM's copies buy read ports, never write ports; sharding by writer is what buys write
// ports (docs/rtl-rules.md, "no cheap write ports"). Held in flops instead, the array pays an
// NW:1 write mux and an enable at EVERY entry and a DEPTH:1 read mux per reader, both the size of
// the array (rule I7); here those are one bank write per writer and a read of each bank, and only
// the lvt (log2(NW) bits an entry) is flops.
//
// Two writers never write one entry in a cycle (asserted). rd[r] is the entry at ra[r] as it was
// before this cycle's writes, combinational; ra is every bank's read address (rule I6).
module smolrv64_mwram
  #(parameter W     = 64,                 // entry width
    parameter DEPTH = 32,
    parameter NW    = 3,                  // writers
    parameter NR    = 1,                  // readers
    parameter AB    = $clog2(DEPTH))
   (input  wire               clk,
    input  wire               reset,      // only the invariant checks: the array has no reset
    input  wire [NW-1:0]      wv,
    input  wire [NW*AB-1:0]   wa,         // writer j's entry at [j*AB +: AB]
    input  wire [NW*W-1:0]    wd,
    input  wire [NR*AB-1:0]   ra,
    output wire [NR*W-1:0]    rd);

   localparam integer LB = (NW > 1) ? $clog2(NW) : 1;
   initial if ((1 << AB) < DEPTH) $fatal(1, "smolrv64_mwram: AB=%0d cannot address %0d entries", AB, DEPTH);

   // the live-value table: per entry, its last writer
   reg [LB-1:0] lvt [0:DEPTH-1];
   integer i, j;
   initial for (i = 0; i < DEPTH; i = i + 1) lvt[i] = {LB{1'b0}};
   always @(posedge clk)
      for (j = 0; j < NW; j = j + 1)
         if (wv[j]) lvt[wa[j*AB +: AB]] <= j[LB-1:0];
   always @(posedge clk) if (!reset)
      for (i = 0; i < NW; i = i + 1)
         for (j = i + 1; j < NW; j = j + 1)
            if (wv[i] & wv[j] & (wa[i*AB +: AB] == wa[j*AB +: AB]))
               $fatal(1, "smolrv64_mwram: writers %0d and %0d both write entry %0d", i, j, wa[i*AB +: AB]);

   // a bank per writer: its one write, and every reader's read
   wire [W-1:0] bv [0:NW*NR-1];             // writer j's bank at reader r's entry: [j*NR + r]
   genvar gj, gr;
   generate for (gj = 0; gj < NW; gj = gj + 1) begin: wb
      reg [W-1:0] mem [0:DEPTH-1];
      integer k;
      initial for (k = 0; k < DEPTH; k = k + 1) mem[k] = {W{1'b0}};
      always @(posedge clk) if (wv[gj]) mem[wa[gj*AB +: AB]] <= wd[gj*W +: W];
      for (gr = 0; gr < NR; gr = gr + 1) begin: r
         assign bv[gj*NR + gr] = mem[ra[gr*AB +: AB]];
      end
   end endgenerate
   generate for (gr = 0; gr < NR; gr = gr + 1) begin: rp
      wire [LB-1:0] w = lvt[ra[gr*AB +: AB]];
      assign rd[gr*W +: W] = bv[w*NR + gr];
   end endgenerate
endmodule

`default_nettype wire
