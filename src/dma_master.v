`timescale 1ns / 1ps
`default_nettype none

// dma_master -- a device's DMA port: one command at a time, an 8-byte access (the address's low three
// bits dropped, the bytes placed by the strobes), answered by a one-cycle rsp_valid.
//
// A command is a STREAM access or not (cmd_stream). A stream is a device's payload -- a sector's or a
// frame's sequential words, which nothing else touches while the device moves them -- and it moves
// through the line buffer a line at a time:
//   - a stream read is answered from the buffer when it holds the word's line as read; otherwise the
//     line is read into it whole, one 8-beat burst;
//   - a stream write is merged into the buffer under its strobes and answered at once; the buffer's
//     bytes go out as one masked 8-beat burst before any command that is not a stream write to the
//     same line.
// Anything else -- a ring's index, a descriptor, a used-ring entry, a status byte -- is one beat to
// memory as it was asked, answered when memory has answered, after the buffer's bytes have gone out
// and with its read line dropped. So a device's payload is in memory before its used-ring write is
// answered (and so before its interrupt), and nothing but a payload is ever read from a copy.
//
// Below (ddr4_port_axi) every transaction is a D$ snoop and a DRAM access: a stream costs one a line
// where single beats cost eight.
module dma_master(
    input  wire        clock,
    input  wire        reset,

    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_write,
    input  wire        cmd_stream,
    input  wire [31:0] cmd_addr,
    input  wire [63:0] cmd_wdata,
    input  wire [ 7:0] cmd_wstrb,
    output reg         rsp_valid,
    output reg  [63:0] rsp_rdata,
    output reg         rsp_error,

    output wire [ 2:0] m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [ 7:0] m_axi_awlen,
    output wire [ 2:0] m_axi_awsize,
    output wire [ 1:0] m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [ 3:0] m_axi_awcache,
    output wire [ 2:0] m_axi_awprot,
    output wire [ 3:0] m_axi_awqos,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [63:0] m_axi_wdata,
    output wire [ 7:0] m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [ 2:0] m_axi_bid,
    input  wire [ 1:0] m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    output wire [ 2:0] m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [ 7:0] m_axi_arlen,
    output wire [ 2:0] m_axi_arsize,
    output wire [ 1:0] m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [ 3:0] m_axi_arcache,
    output wire [ 2:0] m_axi_arprot,
    output wire [ 3:0] m_axi_arqos,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [ 2:0] m_axi_rid,
    input  wire [63:0] m_axi_rdata,
    input  wire [ 1:0] m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);
   // S_GO decides the command S_IDLE took; S_RD and S_WR are one burst each, a line or the command's
   // one beat. A write burst that sent the buffer ahead of a command goes back to S_GO.
   localparam [1:0] S_IDLE = 2'd0, S_GO = 2'd1, S_RD = 2'd2, S_WR = 2'd3;

   function [63:0] bytes(input [7:0] m);          // a byte mask as a bit mask
      integer b;
      for (b = 0; b < 8; b = b + 1) bytes[b*8 +: 8] = {8{m[b]}};
   endfunction

   reg [1:0]  state;
   reg        q_write, q_stream;                  // the command
   reg [28:0] q_wa;                               // its word address
   reg [63:0] q_wdata;
   reg [ 7:0] q_wstrb;
   wire [25:0] q_ln = q_wa[28:3];
   wire [ 2:0] q_bt = q_wa[2:0];
   reg [63:0] lb [0:7];                           // the line buffer: a line read, or bytes to write
   reg [ 7:0] lm [0:7];                           // the bytes to write; all zero unless lb_w
   reg        lb_r, lb_w;                         // it holds line lb_ln as read / bytes of it to write
   reg [25:0] lb_ln;
   reg        one;                                // the burst is the command's one beat, not a line
   reg        a_pend;                             // the burst's address is not yet taken
   reg        w_done;                             // the burst's last beat is sent
   reg [2:0]  bt;                                 // the beat
   integer    i;

   wire same   = lb_ln == q_ln;
   wire go_wr  = (state == S_GO) & q_write & ~(lb_w & ~(q_stream & same));
   wire [2:0] la = (state == S_GO) ? q_bt : bt;   // the buffer's one address
   wire [63:0] lb_q = lb[la];
   wire r_beat = (state == S_RD) & m_axi_rvalid;
   wire w_beat = m_axi_wvalid & m_axi_wready;

   // one write statement: a read beat lands, or a command's bytes merge
   always @(posedge clock)
      if (r_beat | go_wr) lb[la] <= r_beat ? m_axi_rdata : (lb_q & ~bytes(q_wstrb)) | (q_wdata & bytes(q_wstrb));

   assign cmd_ready = state == S_IDLE;

   always @(posedge clock) begin
      rsp_valid <= 1'b0;
      if (reset) begin
         state <= S_IDLE;  lb_r <= 1'b0;  lb_w <= 1'b0;  a_pend <= 1'b0;  w_done <= 1'b0;
         rsp_rdata <= 64'd0;  rsp_error <= 1'b0;
         for (i = 0; i < 8; i = i + 1) lm[i] <= 8'd0;
      end else begin
         case (state)
            S_IDLE: if (cmd_valid) begin
               q_write <= cmd_write;  q_stream <= cmd_stream;  q_wa <= cmd_addr[31:3];
               q_wdata <= cmd_wdata;  q_wstrb <= cmd_wstrb;  rsp_error <= 1'b0;  state <= S_GO;
            end
            S_GO:
               if (lb_w & ~(q_stream & q_write & same)) begin
                  // the buffer's bytes go out first
                  one <= 1'b0;  bt <= 3'd0;  a_pend <= 1'b1;  w_done <= 1'b0;  state <= S_WR;
               end else if (q_write) begin
                  // into the buffer: a stream write is answered now, anything else goes out alone
                  lm[q_bt] <= lm[q_bt] | q_wstrb;  lb_w <= 1'b1;  lb_r <= 1'b0;  lb_ln <= q_ln;
                  if (q_stream) begin rsp_valid <= 1'b1;  rsp_rdata <= 64'd0;  state <= S_IDLE; end
                  else begin one <= 1'b1;  bt <= q_bt;  a_pend <= 1'b1;  w_done <= 1'b0;  state <= S_WR; end
               end else if (q_stream & lb_r & same) begin
                  rsp_valid <= 1'b1;  rsp_rdata <= lb_q;  state <= S_IDLE;
               end else begin
                  // a stream's line, or anything else's one beat
                  lb_r <= 1'b0;  lb_ln <= q_ln;  one <= ~q_stream;  bt <= q_stream ? 3'd0 : q_bt;
                  a_pend <= 1'b1;  state <= S_RD;
               end
            S_RD: begin
               if (m_axi_arvalid & m_axi_arready) a_pend <= 1'b0;
               if (r_beat) begin
                  bt <= bt + 3'd1;
                  if (bt == q_bt) rsp_rdata <= m_axi_rdata;
                  if (m_axi_rresp != 2'b00) rsp_error <= 1'b1;
                  if (m_axi_rlast) begin
                     lb_r <= ~one & ~rsp_error & (m_axi_rresp == 2'b00);
                     rsp_valid <= 1'b1;  state <= S_IDLE;
                  end
               end
            end
            S_WR: begin
               if (m_axi_awvalid & m_axi_awready) a_pend <= 1'b0;
               if (w_beat) begin bt <= bt + 3'd1;  w_done <= m_axi_wlast; end
               if (m_axi_bvalid) begin
                  lb_w <= 1'b0;
                  for (i = 0; i < 8; i = i + 1) lm[i] <= 8'd0;
                  if (one) begin rsp_valid <= 1'b1;  rsp_rdata <= 64'd0;  rsp_error <= m_axi_bresp != 2'b00;  state <= S_IDLE; end
                  else state <= S_GO;
               end
            end
            default: $fatal(1, "dma_master: undefined state %0d", state);
         endcase
      end
   end

   always @(posedge clock) if (!reset) begin
      if (state == S_IDLE && cmd_valid && cmd_write && cmd_wstrb == 8'd0)
         $fatal(1, "dma_master: a write of no bytes at %h", cmd_addr);
      if (r_beat && m_axi_rlast != (one | bt == 3'd7))
         $fatal(1, "dma_master: a read burst's last beat at beat %0d (one %b)", bt, one);
      if (state == S_WR && m_axi_bvalid && !w_done)
         $fatal(1, "dma_master: a write answered before its last beat");
      if (state == S_WR && m_axi_bvalid && !one && m_axi_bresp != 2'b00)
         $fatal(1, "dma_master: the buffer's bytes for line %h came back bresp=%b: answered writes are lost",
                {lb_ln, 6'd0}, m_axi_bresp);
   end

   // a burst's address: the line's, or the command's word; a write's beats go with it
   wire [31:0] ax_addr = {lb_ln, one ? q_bt : 3'b000, 3'b000};
   assign m_axi_arvalid = (state == S_RD) & a_pend;
   assign m_axi_araddr  = ax_addr;
   assign m_axi_arlen   = one ? 8'd0 : 8'd7;
   assign m_axi_arsize  = 3'b011;
   assign m_axi_arburst = 2'b01;
   assign m_axi_arid    = 3'b000;   // 0: the platform's arbiter tree stamps the bits above (rk_xcku5p.v)
   assign m_axi_arlock  = 1'b0;
   assign m_axi_arcache = 4'b0011;
   assign m_axi_arprot  = 3'b000;
   assign m_axi_arqos   = 4'd0;
   assign m_axi_rready  = state == S_RD;

   assign m_axi_awvalid = (state == S_WR) & a_pend;
   assign m_axi_awaddr  = ax_addr;
   assign m_axi_awlen   = one ? 8'd0 : 8'd7;
   assign m_axi_awsize  = 3'b011;
   assign m_axi_awburst = 2'b01;
   assign m_axi_awid    = 3'b000;
   assign m_axi_awlock  = 1'b0;
   assign m_axi_awcache = 4'b0011;
   assign m_axi_awprot  = 3'b000;
   assign m_axi_awqos   = 4'd0;
   assign m_axi_wvalid  = (state == S_WR) & ~w_done;
   assign m_axi_wdata   = lb_q;
   assign m_axi_wstrb   = lm[bt];
   assign m_axi_wlast   = one | bt == 3'd7;
   assign m_axi_bready  = state == S_WR;

   wire unused_axi_inputs = &{1'b0, m_axi_bid, m_axi_rid, cmd_addr[2:0]};
endmodule

`default_nettype wire
