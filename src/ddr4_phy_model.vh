// ddr4_phy_model -- a behavioural model of the DDR4 IP's PHY-only port (AMD PG150, "PHY Only
// Interface") and the DRAM behind it, for benches: included by a bench, never synthesized.
//
// It decodes the four command slots of every cycle and checks, in DRAM clocks (cycle*4 + slot),
// every rule the controller owns once calDone rises: tRCD, tRAS, tRP, tRC, tRRD_S/L, tFAW,
// tCCD_S/L, tWTR_S/L, read-to-write (PG150's RL + BL/2 - WL + 4), tRTP, write recovery, tRFC,
// tZQCS, the refresh rate (JEDEC: a REF every tREFI on average, at most eight owed), the 1N encoding (both bits of a
// slot equal), CAS only in slots 0 and 2 and only with mcRdCAS/mcWrCAS, and PG150's VT tracking
// (between gt_data_ready pulses a read CAS, read data back and three cycles with no read CAS;
// a pulse at least every GT_MAX cycles). A violation is a $fatal naming the rule.
//
// Data: a write CAS at cycle N raises wrDataEn with its winBuf at N+2 and takes wrData and
// wrDataMask (1: byte kept) at N+3; a read CAS at N returns its burst and winBuf on rdDataEn and
// rdDataAddr at N+RDLAT (per_rd_done when winInjTxn). Memory is sparse, bursts of 32 bytes keyed by
// {bank group, bank, row, column}; a byte never written reads as zero.
module ddr4_phy_model #(
   parameter integer RDLAT  = 16,       // CAS -> rdDataEn, cycles (the board's calibrated latency)
   parameter integer CAL    = 200,      // cycles to calDone
   parameter integer GT_MAX = 666       // the longest gap between gt_data_ready pulses (2 us)
) (
   input  wire          clk,
   input  wire          reset,
   output reg           calDone,
   input  wire [7:0]    mc_ACT_n,
   input  wire [135:0]  mc_ADR,
   input  wire [15:0]   mc_BA,
   input  wire [7:0]    mc_BG,
   input  wire [7:0]    mc_CS_n,
   input  wire [7:0]    mc_ODT,
   input  wire [7:0]    mc_CKE,
   input  wire          mcRdCAS,
   input  wire          mcWrCAS,
   input  wire [1:0]    mcCasSlot,
   input  wire          mcCasSlot2,
   input  wire [4:0]    winBuf,
   input  wire          winInjTxn,
   input  wire          winRmw,
   input  wire [1:0]    winRank,
   input  wire          gt_data_ready,
   input  wire [255:0]  wrData,
   input  wire [31:0]   wrDataMask,
   output reg           wrDataEn,
   output reg  [4:0]    wrDataAddr,
   output reg           rdDataEn,
   output reg  [4:0]    rdDataAddr,
   output reg  [255:0]  rdData,
   output reg           per_rd_done
);
   // DDR4-2666 at tCK 750 ps, CL19 CWL14 BL8, in DRAM clocks
   localparam integer tRCD = 19, tRP = 19, tRAS = 43, tRC = 62, tRRD_S = 8, tRRD_L = 9, tFAW = 40;
   localparam integer tCCD_S = 4, tCCD_L = 7, CWL = 14, CL = 19, tWTR_S = 4, tWTR_L = 10, tRTP = 10;
   localparam integer tWR = 20, tRFC = 734, tREFI = 10400, tZQCS = 128;
   localparam integer WR_RD_S = CWL + 4 + tWTR_S, WR_RD_L = CWL + 4 + tWTR_L;
   localparam integer RD_WR = CL + 4 - CWL + 4, WR_PRE = CWL + 4 + tWR;
   localparam longint NEVER = -64'sd1000000;

   longint cyc;
   // per bank {group, bank}: open row, and the times of its commands
   bit     b_open [0:7];
   bit [16:0] b_row [0:7];
   longint b_act [0:7], b_pre [0:7], b_rd [0:7], b_wr [0:7];
   longint act_g [0:1], cas_g [0:1], wr_g [0:1], rd_any, ref_t, zq_t;
   longint acts [$];                    // recent ACT times, for tFAW
   longint last_ref, cal_cyc;
   int     n_ref, n_rd, n_wr, n_act, n_pre, n_inj;
   bit [255:0] mem [bit [26:0]];        // {group, bank, row, col[9:3]}
   // the data pipelines
   bit         wpipe_v  [0:3];   bit [4:0] wpipe_t [0:3];   bit [26:0] wpipe_a [0:3];
   bit         rpipe_v  [0:63];  bit [4:0] rpipe_t [0:63];  bit [255:0] rpipe_d [0:63];  bit rpipe_i [0:63];
   // VT tracking since the last gt_data_ready
   bit  vt_rd, vt_data, vt_gap;  int vt_quiet;  longint vt_last;

   function automatic bit slot(input [7:0] lane, input int s);
      if (lane[2*s] != lane[2*s+1]) $fatal(1, "ddr4_phy_model: cycle %0d slot %0d: the two bits of a 1N slot differ (%b)", cyc, s, lane);
      return lane[2*s];
   endfunction
   function automatic void need(input longint t, input longint since, input int gap, input string what);
      if (t - since < gap) $fatal(1, "ddr4_phy_model: cycle %0d: %s -- %0d DRAM clocks, %0d needed", cyc, what, t - since, gap);
   endfunction

   initial begin
      cyc = 0; calDone = 0;
      for (int k = 0; k < 8; k++) begin b_open[k] = 0; b_act[k] = NEVER; b_pre[k] = NEVER; b_rd[k] = NEVER; b_wr[k] = NEVER; end
      for (int g = 0; g < 2; g++) begin act_g[g] = NEVER; cas_g[g] = NEVER; wr_g[g] = NEVER; end
      rd_any = NEVER; ref_t = NEVER; zq_t = NEVER; last_ref = -1;
      n_ref = 0; n_rd = 0; n_wr = 0; n_act = 0; n_pre = 0; n_inj = 0;
      for (int k = 0; k < 4; k++) wpipe_v[k] = 0;
      for (int k = 0; k < 64; k++) rpipe_v[k] = 0;
      vt_rd = 0; vt_data = 0; vt_gap = 0; vt_quiet = 0; vt_last = 0;
   end

   bit cas_seen, cas_rd;  int cas_slot;
   bit [255:0] o;
   always @(posedge clk) begin
      cas_seen = 0;  cas_rd = 0;  cas_slot = -1;
      cyc <= cyc + 1;
      calDone <= !reset && (cyc >= CAL);
      // data out: this cycle's write request and read return, from the pipelines
      wrDataEn <= wpipe_v[0];  wrDataAddr <= wpipe_t[0];      // CAS cycle + 2
      if (wpipe_v[2]) begin                         // N+3: the data (mask 1 keeps the byte)
         o = mem.exists(wpipe_a[2]) ? mem[wpipe_a[2]] : '0;
         for (int k = 0; k < 32; k++) if (!wrDataMask[k]) o[k*8 +: 8] = wrData[k*8 +: 8];
         mem[wpipe_a[2]] = o;
      end
      for (int k = 3; k > 0; k--) begin wpipe_v[k] = wpipe_v[k-1]; wpipe_t[k] = wpipe_t[k-1]; wpipe_a[k] = wpipe_a[k-1]; end
      wpipe_v[0] = 0;
      rdDataEn <= rpipe_v[RDLAT-1] && !rpipe_i[RDLAT-1];
      per_rd_done <= rpipe_v[RDLAT-1] && rpipe_i[RDLAT-1];
      rdDataAddr <= rpipe_t[RDLAT-1];  rdData <= rpipe_d[RDLAT-1];
      if (rpipe_v[RDLAT-1]) vt_data = vt_data | vt_rd;
      for (int k = 63; k > 0; k--) begin rpipe_v[k] = rpipe_v[k-1]; rpipe_t[k] = rpipe_t[k-1]; rpipe_d[k] = rpipe_d[k-1]; rpipe_i[k] = rpipe_i[k-1]; end
      rpipe_v[0] = 0;

      if (!calDone) begin
         if (mcRdCAS || mcWrCAS || gt_data_ready) $fatal(1, "ddr4_phy_model: a CAS or gt_data_ready before calDone");
      end else begin
         if (mc_CKE != 8'hFF) $fatal(1, "ddr4_phy_model: cycle %0d: CKE %b, not held high", cyc, mc_CKE);
         if (winRank != 0 || winRmw) $fatal(1, "ddr4_phy_model: winRank %0d winRmw %0d (one rank, no RMW)", winRank, winRmw);
         if ((mcRdCAS || mcWrCAS) && (mcCasSlot2 != mcCasSlot[1] || mcCasSlot[0]))
            $fatal(1, "ddr4_phy_model: cycle %0d: mcCasSlot %b with mcCasSlot2 %b", cyc, mcCasSlot, mcCasSlot2);
         for (int s = 0; s < 4; s++) begin
            automatic longint t = cyc * 4 + s;
            automatic bit cs = !slot(mc_CS_n, s), act = !slot(mc_ACT_n, s);
            automatic bit [16:0] a;
            automatic int g, bk;
            for (int p = 0; p < 17; p++) a[p] = slot(mc_ADR[p*8 +: 8], s);
            bk = {slot(mc_BG, s), slot(mc_BA[15:8], s), slot(mc_BA[7:0], s)};
            g  = bk >> 2;
            if (!cs) continue;
            if (act) begin                                      // ACT
               if (b_open[bk]) $fatal(1, "ddr4_phy_model: cycle %0d: ACT to open bank %0d", cyc, bk);
               need(t, b_pre[bk], tRP, "tRP (PRE -> ACT)");
               need(t, b_act[bk], tRC, "tRC (ACT -> ACT, one bank)");
               need(t, act_g[g], tRRD_L, "tRRD_L");  need(t, act_g[1-g], tRRD_S, "tRRD_S");
               need(t, ref_t, tRFC, "tRFC (REF -> ACT)");  need(t, zq_t, tZQCS, "tZQCS (ZQCS -> ACT)");
               if (acts.size() >= 4) need(t, acts[acts.size()-4], tFAW, "tFAW");
               acts.push_back(t);  if (acts.size() > 4) void'(acts.pop_front());
               b_open[bk] = 1;  b_row[bk] = a;  b_act[bk] = t;  act_g[g] = t;  n_act++;
            end else case (a[16:14])
               3'b101, 3'b100: begin                            // RD, WR
                  automatic bit rd = a[14];
                  if (s != 0 && s != 2) $fatal(1, "ddr4_phy_model: cycle %0d: a CAS in slot %0d", cyc, s);
                  if (cas_seen) $fatal(1, "ddr4_phy_model: cycle %0d: two CAS in one cycle", cyc);
                  cas_seen = 1;  cas_rd = rd;  cas_slot = s;
                  if (!b_open[bk]) $fatal(1, "ddr4_phy_model: cycle %0d: CAS to closed bank %0d", cyc, bk);
                  if (a[2:0] != 0) $fatal(1, "ddr4_phy_model: cycle %0d: a CAS to column %0d, not a BL8 boundary", cyc, a[9:0]);
                  need(t, b_act[bk], tRCD, "tRCD");
                  need(t, cas_g[g], tCCD_L, "tCCD_L");  need(t, cas_g[1-g], tCCD_S, "tCCD_S");
                  need(t, ref_t, tRFC, "tRFC (REF -> CAS)");
                  if (rd) begin
                     need(t, wr_g[g], WR_RD_L, "write to read, one group (CWL + BL/2 + tWTR_L)");
                     need(t, wr_g[1-g], WR_RD_S, "write to read, the other group (CWL + BL/2 + tWTR_S)");
                     rd_any = t;  b_rd[bk] = t;  n_rd++;
                     rpipe_v[0] = 1;  rpipe_t[0] = winBuf;  rpipe_i[0] = winInjTxn;  n_inj += winInjTxn;
                     rpipe_d[0] = mem.exists({bk[2:0], b_row[bk], a[9:3]}) ? mem[{bk[2:0], b_row[bk], a[9:3]}] : '0;
                  end else begin
                     need(t, rd_any, RD_WR, "read to write (RL + BL/2 - WL + 4)");
                     wr_g[g] = t;  b_wr[bk] = t;  n_wr++;
                     wpipe_v[0] = 1;  wpipe_t[0] = winBuf;  wpipe_a[0] = {bk[2:0], b_row[bk], a[9:3]};
                  end
                  cas_g[g] = t;
               end
               3'b010: begin                                    // PRE (A10: all)
                  for (int k = 0; k < 8; k++) if ((a[10] || k == bk) && b_open[k]) begin
                     need(t, b_act[k], tRAS, "tRAS (ACT -> PRE)");
                     need(t, b_rd[k], tRTP, "tRTP (RD -> PRE)");
                     need(t, b_wr[k], WR_PRE, "write recovery (CWL + BL/2 + tWR)");
                     b_open[k] = 0;  b_pre[k] = t;  n_pre++;
                  end
               end
               3'b001: begin                                    // REF
                  for (int k = 0; k < 8; k++) begin
                     if (b_open[k]) $fatal(1, "ddr4_phy_model: cycle %0d: REF with bank %0d open", cyc, k);
                     need(t, b_pre[k], tRP, "tRP (PRE -> REF)");
                  end
                  need(t, ref_t, tRFC, "tRFC (REF -> REF)");
                  if (last_ref >= 0 && t - last_ref > 9 * tREFI)
                     $fatal(1, "ddr4_phy_model: cycle %0d: %0d DRAM clocks since the last REF (9 tREFI: %0d)", cyc, t - last_ref, 9 * tREFI);
                  ref_t = t;  last_ref = t;  n_ref++;
               end
               3'b110: begin                                    // ZQCS (A10 low)
                  if (a[10]) $fatal(1, "ddr4_phy_model: cycle %0d: ZQCL after calibration", cyc);
                  for (int k = 0; k < 8; k++) if (b_open[k]) $fatal(1, "ddr4_phy_model: cycle %0d: ZQCS with bank %0d open", cyc, k);
                  need(t, ref_t, tRFC, "tRFC (REF -> ZQCS)");
                  zq_t = t;
               end
               default: $fatal(1, "ddr4_phy_model: cycle %0d slot %0d: command %b after calibration", cyc, s, a[16:14]);
            endcase
         end
         if (cas_seen != (mcRdCAS || mcWrCAS) || (cas_seen && (cas_rd != mcRdCAS || cas_slot != mcCasSlot)))
            $fatal(1, "ddr4_phy_model: cycle %0d: CAS slot %0d (read %0d) against mcRdCAS %0d mcWrCAS %0d mcCasSlot %0d",
                   cyc, cas_slot, cas_rd, mcRdCAS, mcWrCAS, mcCasSlot);
         if (last_ref >= 0 && cyc * 4 - last_ref > 9 * tREFI)
            $fatal(1, "ddr4_phy_model: cycle %0d: no REF for %0d DRAM clocks", cyc, cyc * 4 - last_ref);
         // the average rate: a REF every tREFI since calibration, at most eight owed
         if ((cyc - cal_cyc) * 4 / tREFI - n_ref > 8)
            $fatal(1, "ddr4_phy_model: cycle %0d: %0d REF in %0d DRAM clocks, %0d owed (JEDEC: at most 8)", cyc, n_ref,
                   (cyc - cal_cyc) * 4, (cyc - cal_cyc) * 4 / tREFI - n_ref);
         // VT tracking
         if (cas_seen && cas_rd) begin vt_rd = 1; vt_quiet = 0; end else if (vt_quiet < 3) vt_quiet++;
         if (vt_quiet == 3) vt_gap = 1;
         if (gt_data_ready) begin
            if (!vt_rd || !vt_data || !vt_gap)
               $fatal(1, "ddr4_phy_model: cycle %0d: gt_data_ready without a read (%0d), its data (%0d) and a gap (%0d)", cyc, vt_rd, vt_data, vt_gap);
            vt_rd = 0; vt_data = 0; vt_gap = 0; vt_last = cyc;
         end
         if (cyc - vt_last > GT_MAX && last_ref >= 0)
            $fatal(1, "ddr4_phy_model: cycle %0d: no gt_data_ready for %0d cycles", cyc, cyc - vt_last);
      end
      if (!calDone) begin vt_last = cyc; cal_cyc = cyc; end
   end

   function automatic void report();
      $display("ddr4_phy_model: %0d ACT, %0d PRE, %0d RD (%0d injected), %0d WR, %0d REF", n_act, n_pre, n_rd, n_inj, n_wr, n_ref);
   endfunction
endmodule
