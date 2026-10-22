`default_nettype none
// ddr4_port_axi -- the DMA masters' AXI4 port (on ui_clk, after the device arbiters) as a requester
// of ddr4_ctl, until coherent DMA replaces it (docs/PLAN-2026-10-21-memory-system.md).
//
// Every transaction the masters make lies within one 64-byte line: axi_single_beat_master's one
// 8-byte beat (virtio-blk, virtio-net, virtio-input) and vga_scanout's eight-beat line. So a
// transaction is one line request, and anything else asserts. A read engine and a write engine
// each take one transaction at a time, each with its line buffer (tag 12: the read's, 14: the
// write's): a read's line lands in its buffer and its beats go back on R; a write's beats gather
// with their strobes into its buffer, the line goes as one masked write, and B goes back once the
// PHY has taken both halves.
module ddr4_port_axi (
   input  wire          clk,
   input  wire          reset,
   // ---- AXI4 slave, 64-bit data, 32-bit address in the DRAM window ----
   input  wire [2:0]    s_axi_awid,
   input  wire [31:0]   s_axi_awaddr,
   input  wire [7:0]    s_axi_awlen,
   input  wire [2:0]    s_axi_awsize,
   input  wire [1:0]    s_axi_awburst,
   input  wire          s_axi_awvalid,
   output wire          s_axi_awready,
   input  wire [63:0]   s_axi_wdata,
   input  wire [7:0]    s_axi_wstrb,
   input  wire          s_axi_wlast,
   input  wire          s_axi_wvalid,
   output wire          s_axi_wready,
   output reg  [2:0]    s_axi_bid,
   output wire [1:0]    s_axi_bresp,
   output wire          s_axi_bvalid,
   input  wire          s_axi_bready,
   input  wire [2:0]    s_axi_arid,
   input  wire [31:0]   s_axi_araddr,
   input  wire [7:0]    s_axi_arlen,
   input  wire [2:0]    s_axi_arsize,
   input  wire [1:0]    s_axi_arburst,
   input  wire          s_axi_arvalid,
   output wire          s_axi_arready,
   output reg  [2:0]    s_axi_rid,
   output wire [63:0]   s_axi_rdata,
   output wire [1:0]    s_axi_rresp,
   output wire          s_axi_rlast,
   output wire          s_axi_rvalid,
   input  wire          s_axi_rready,
   // ---- ddr4_ctl's request port ----
   output wire          rq_valid,
   input  wire          rq_ready,
   output wire          rq_we,
   output wire [25:0]   rq_line,
   output wire [3:0]    rq_buf,
   // ---- the PHY's data ----
   input  wire          rdDataEn,
   input  wire [4:0]    rdDataAddr,
   input  wire [255:0]  rdData,
   input  wire          wrDataEn,
   input  wire [4:0]    wrDataAddr,
   output reg           wd_mine,
   output reg  [255:0]  wd_data,
   output reg  [31:0]   wd_mask                 // 1: the byte is not written
);
   localparam [3:0] RBUF = 4'd12, WBUF = 4'd14;
   assign s_axi_bresp = 2'b00;
   assign s_axi_rresp = 2'b00;

   // ---- the read engine: idle, request, wait for the line, beats ----
   localparam [1:0] I = 2'd0, Q = 2'd1, W = 2'd2, S = 2'd3;
   reg  [1:0]   r_st;
   reg  [25:0]  r_line;
   reg  [2:0]   r_k;                            // the next beat's place in the line
   reg  [2:0]   r_left;                         // beats after this one
   reg  [511:0] r_buf;
   reg  [1:0]   r_got;
   assign s_axi_arready = (r_st == I);
   assign s_axi_rvalid  = (r_st == S);
   assign s_axi_rdata   = r_buf[r_k*64 +: 64];
   assign s_axi_rlast   = (r_left == 3'd0);

   // ---- the write engine: idle, beats, request, wait for the PHY to take it, B ----
   localparam [2:0] WI = 3'd0, WD = 3'd1, WQ = 3'd2, WW = 3'd3, WB = 3'd4;
   reg  [2:0]   w_st;
   reg  [25:0]  w_line;
   reg  [2:0]   w_k;
   reg  [511:0] w_buf;
   reg  [63:0]  w_strb;                         // the bytes written
   assign s_axi_awready = (w_st == WI);
   assign s_axi_wready  = (w_st == WD);
   assign s_axi_bvalid  = (w_st == WB);

   // ---- requests: the read engine's first ----
   wire r_rq = (r_st == Q);
   wire w_rq = (w_st == WQ);
   assign rq_valid = r_rq || w_rq;
   assign rq_we    = !r_rq;
   assign rq_line  = r_rq ? r_line : w_line;
   assign rq_buf   = r_rq ? RBUF : WBUF;
   wire rq_go = rq_valid && rq_ready;

   wire rd_mine = rdDataEn && (rdDataAddr[4:1] == RBUF);
   wire wr_mine = wrDataEn && (wrDataAddr[4:1] == WBUF);
   reg  w_sent;                                 // the PHY asked for the second half last cycle
   integer b;

   always @(posedge clk) begin
      if (rd_mine) r_buf[rdDataAddr[0]*256 +: 256] <= rdData;
      wd_mine <= wr_mine;
      wd_data <= w_buf[wrDataAddr[0]*256 +: 256];
      wd_mask <= ~w_strb[wrDataAddr[0]*32 +: 32];
      w_sent  <= wr_mine && wrDataAddr[0];
      if (reset) begin
         r_st <= I;  w_st <= WI;  w_sent <= 1'b0;
      end else begin
         case (r_st)
            I: if (s_axi_arvalid) begin
                  r_st <= Q;  r_line <= s_axi_araddr[31:6];  r_k <= s_axi_araddr[5:3];
                  r_left <= s_axi_arlen[2:0];  s_axi_rid <= s_axi_arid;  r_got <= 2'b00;
               end
            Q: if (rq_go) r_st <= W;
            W: begin
                  if (rd_mine) r_got[rdDataAddr[0]] <= 1'b1;
                  if (rd_mine && rdDataAddr[0]) r_st <= S;
               end
            S: if (s_axi_rready) begin
                  r_k <= r_k + 3'd1;  r_left <= r_left - 3'd1;
                  if (r_left == 3'd0) r_st <= I;
               end
         endcase
         case (w_st)
            WI: if (s_axi_awvalid) begin
                   w_st <= WD;  w_line <= s_axi_awaddr[31:6];  w_k <= s_axi_awaddr[5:3];
                   s_axi_bid <= s_axi_awid;  w_strb <= 64'd0;
                end
            WD: if (s_axi_wvalid) begin
                   w_buf[w_k*64 +: 64] <= s_axi_wdata;
                   w_strb[w_k*8 +: 8]  <= s_axi_wstrb;
                   w_k <= w_k + 3'd1;
                   if (s_axi_wlast) w_st <= WQ;
                end
            WQ: if (rq_go && !r_rq) w_st <= WW;
            WW: if (w_sent) w_st <= WB;
            WB: if (s_axi_bready) w_st <= WI;
            default: w_st <= WI;
         endcase
      end
   end

`ifndef SYNTHESIS
   always @(posedge clk) if (!reset) begin
      if (s_axi_arvalid && s_axi_arready &&
          (s_axi_arsize != 3'd3 || s_axi_arburst != 2'b01 || {1'b0, s_axi_araddr[5:3]} + s_axi_arlen[3:0] > 4'd7 || s_axi_arlen[7:3] != 5'd0))
         $fatal(1, "ddr4_port_axi: a read (addr %h len %0d size %0d burst %0d) that is not within one line",
                s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst);
      if (s_axi_awvalid && s_axi_awready &&
          (s_axi_awsize != 3'd3 || s_axi_awburst != 2'b01 || {1'b0, s_axi_awaddr[5:3]} + s_axi_awlen[3:0] > 4'd7 || s_axi_awlen[7:3] != 5'd0))
         $fatal(1, "ddr4_port_axi: a write (addr %h len %0d size %0d burst %0d) that is not within one line",
                s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst);
      if (rd_mine && r_st != W)               $fatal(1, "ddr4_port_axi: read data for a line not asked for");
      if (rd_mine && rdDataAddr[0] && !r_got[0]) $fatal(1, "ddr4_port_axi: the second burst before the first");
      if (wr_mine && w_st != WW)              $fatal(1, "ddr4_port_axi: the PHY asked for write data not queued");
   end
`endif
endmodule

`default_nettype wire
