`default_nettype none
// smolrv64_uram_be: a 512-bit-wide UltraRAM array with a write enable per byte, two ports. Port A
// only writes; port B, when enabled, reads, or writes (its output then holds). Both ports' inputs
// are registered here first: 32 K lines is all 64 URAM288 of the XCKU5P, its one URAM column, which
// runs the die's full height (eight cascades of eight, one per 64 bits), so every path into it starts
// at a flop. A read's line comes out RL cycles after its address, that register included. The two
// ports must not touch one line in one cycle (the URAM orders A before B; the model refuses it, so a
// design that leans on the order fails in simulation).
module smolrv64_uram_be #(
   parameter integer ADDR_WIDTH = 15,
   parameter integer RL         = 5
) (
   input  wire                  clock,
   input  wire                  b_en,
   input  wire [ADDR_WIDTH-1:0] a_addr,
   input  wire [63:0]           a_be,
   input  wire [511:0]          a_wdata,
   input  wire [ADDR_WIDTH-1:0] b_addr,
   input  wire [63:0]           b_be,
   input  wire [511:0]          b_wdata,
   output wire [511:0]          b_rdata
);
   initial if (RL < 3) $fatal(1, "smolrv64_uram_be %m: a read latency of %0d leaves the cascade under 2 stages", RL);
   reg [ADDR_WIDTH-1:0] aq, bq;
   reg [63:0]           abe, bbe;
   reg [511:0]          ad, bd;
   reg                  ben;
   always @(posedge clock) begin
      aq <= a_addr;  abe <= a_be;  ad <= a_wdata;
      bq <= b_addr;  bbe <= b_be;  bd <= b_wdata;  ben <= b_en;
   end
`ifdef SYNTHESIS
   xpm_memory_tdpram #(
      .ADDR_WIDTH_A        ( ADDR_WIDTH ),
      .ADDR_WIDTH_B        ( ADDR_WIDTH ),
      .AUTO_SLEEP_TIME     ( 0 ),
      .BYTE_WRITE_WIDTH_A  ( 8 ),
      .BYTE_WRITE_WIDTH_B  ( 8 ),
      .CASCADE_HEIGHT      ( 0 ),
      .CLOCKING_MODE       ( "common_clock" ),
      .ECC_MODE            ( "no_ecc" ),
      .MEMORY_INIT_FILE    ( "none" ),
      .MEMORY_INIT_PARAM   ( "" ),
      .MEMORY_OPTIMIZATION ( "true" ),
      .MEMORY_PRIMITIVE    ( "ultra" ),
      .MEMORY_SIZE         ( 512 * (1 << ADDR_WIDTH) ),
      .MESSAGE_CONTROL     ( 0 ),
      .READ_DATA_WIDTH_A   ( 512 ),
      .READ_DATA_WIDTH_B   ( 512 ),
      .READ_LATENCY_A      ( RL - 1 ),
      .READ_LATENCY_B      ( RL - 1 ),
      .READ_RESET_VALUE_A  ( "0" ),
      .READ_RESET_VALUE_B  ( "0" ),
      .RST_MODE_A          ( "SYNC" ),
      .RST_MODE_B          ( "SYNC" ),
      .SIM_ASSERT_CHK      ( 0 ),
      .USE_EMBEDDED_CONSTRAINT( 0 ),
      .USE_MEM_INIT        ( 0 ),
      .WAKEUP_TIME         ( "disable_sleep" ),
      .WRITE_DATA_WIDTH_A  ( 512 ),
      .WRITE_DATA_WIDTH_B  ( 512 ),
      .WRITE_MODE_A        ( "no_change" ),
      .WRITE_MODE_B        ( "no_change" )
   ) xpm_memory_tdpram_inst (
      .dbiterra       ( ),
      .dbiterrb       ( ),
      .douta          ( ),
      .doutb          ( b_rdata ),
      .sbiterra       ( ),
      .sbiterrb       ( ),
      .addra          ( aq ),
      .addrb          ( bq ),
      .clka           ( clock ),
      .clkb           ( clock ),
      .dina           ( ad ),
      .dinb           ( bd ),
      .ena            ( 1'b1 ),
      .enb            ( ben ),
      .injectdbiterra ( 1'b0 ),
      .injectdbiterrb ( 1'b0 ),
      .injectsbiterra ( 1'b0 ),
      .injectsbiterrb ( 1'b0 ),
      .regcea         ( 1'b1 ),
      .regceb         ( 1'b1 ),
      .rsta           ( 1'b0 ),
      .rstb           ( 1'b0 ),
      .sleep          ( 1'b0 ),
      .wea            ( abe ),
      .web            ( bbe )
   );
`else
   reg [511:0] mem [0:(1 << ADDR_WIDTH) - 1];
   reg [511:0] q   [0:RL-2];
   reg [511:0] am, bm;
   integer i;
   always @* for (i = 0; i < 64; i = i + 1) begin
      am[8*i +: 8] = {8{abe[i]}};
      bm[8*i +: 8] = {8{bbe[i]}};
   end
   always @(posedge clock) begin
      if (|abe) mem[aq] <= (mem[aq] & ~am) | (ad & am);
      if (ben && |bbe) mem[bq] <= (mem[bq] & ~bm) | (bd & bm);
      else if (ben)    q[0] <= mem[bq];
      for (i = 1; i < RL - 1; i = i + 1) q[i] <= q[i-1];
      if (|abe && ben && aq == bq)
         $fatal(1, "smolrv64_uram_be %m: port A writes line %h while port B touches it", aq);
   end
   assign b_rdata = q[RL-2];
`endif
endmodule
`default_nettype wire
