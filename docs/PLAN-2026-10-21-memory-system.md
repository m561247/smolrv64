# The memory system: our DDR4 controller, the L2 and coherent DMA (plan, 2026-10-21)

Tommy, 2026-10-21, on the Xilinx DDR4 controller: "it's huge ... it's slow ... it's bloated ... it's
inflexible (doesn't support returning data out of order as it arrives) ... it's wasteful (includes its
own core for calibration)". His controller: as simple as possible, every access an aligned 64-byte line
(writes byte-masked), minimal buffering (the receiver is ready), feeding the L2 and the DMA engines
(ethernet, video, SD card, sound) at the DRAM's full rate. Then: "I would include cache coherent DMA in
this DDR4/L2 rework ... all DMA clients should have [at least] two 64B buffers." "I would love 64B
everywhere but I'm worried about area ... we try it and fall back if it cannot fit." "The trend today
is relaxed inclusive; that is, a line may or may not be in both caches at the same time."

This plan joins `PLAN-2026-10-03-dcache-vipt-l2.md`'s L2 to a controller of our own and to coherent DMA.

## Decisions (Tommy, 2026-10-21)

- **Our controller on the DDR4 IP's "Physical Layer Only" mode**: Xilinx's PHY and its calibration stay
  (about 5K LUTs, 7K flops and 24 block RAMs), everything above them is ours. Option 1 (the IP
  reconfigured: native 256-bit interface, a synchronous crossing) "solves only the bandwidth"; option 3
  (our PHY, calibration in firmware) is the highest risk for the calibration's area alone.
- **Cache-coherent DMA**, in 64-byte units; every DMA client keeps at least two 64-byte buffers, one
  draining while the other fills.
- **64 bytes wide everywhere, 32 bytes only if 64 cannot fit.**
- **The L2 is relaxed inclusive**: a line may be in the L1, the L2, or both.

## What is there today (414eda07)

- **The path.** `rv_mem_arbiter` (the caches' one tagged line port: a request {id, we, line, byte mask,
  data}, read data as four 128-bit beats, a write done; responses by id) -> `ddr_port_cdc` (three
  asynchronous block-RAM FIFOs into ui_clk) -> `ddr_port_axi` (a 64-bit AXI master, 8 reads and 8
  writes in flight, one id) -> `axi_two_master_arbiter` (the DMA masters on its second port) -> the
  DDR4 IP (its AXI shim and upsizer, controller, PHY and calibration).
- **The memory.** DDR4-2666, 32 bits wide (two x16 16 Gb parts, 4 GiB), CL19: 10.67 GB/s raw. A
  64-byte line is two BL8 bursts of 32 bytes; at the PHY's 4:1 ratio a burst is one ui_clk (333 MHz),
  so a line is two ui_clks, one core cycle (the core's clock is ui_clk/2, from the same MMCM).
- **Bandwidth.** The 64-bit AXI port at ui_clk caps the path at 2.67 GB/s, a quarter of the DRAM's;
  the IP's native interface for x32 at 4:1 is 256 bits a ui_clk.
- **Latency.** `ddr_hpm` at the line port, from acceptance: reads 35.2, writes 21.3 core cycles mean
  (210 and 128 ns), against the DRAM's ~31.5 ns for a closed row (tRCD + CL + the burst). A dependent
  load that misses the D$ is 45 cycles. The rest is the crossing both ways, the bridge, the arbiter,
  the IP's AXI shim and upsizer, and its controller's queues and in-order return.
- **Area.** `u_ddr4_0`: 11,561 LUTs, 14,215 flops, 25 block RAMs (5.3% of the device's LUTs, 7.8% of
  the design's): calibration ~5.0K LUTs (`u_ddr_cal_top`, the MicroBlaze in `u_ddr_cal_riu`), the AXI
  shim 2.1K (1.3K its upsizer), the controller and its UI ~3.6K, the PHY's logic 281. Ours beside it:
  `ddr_port_cdc` 832 LUTs and 11 block RAMs, `ddr_port_axi` 298, the arbiter 198.
- **DMA.** virtio-blk, virtio-net and the VGA scanout are AXI masters beside the core, not coherent:
  Linux keeps them right with CBOs around every buffer, and two defects lived in that gap (the next-line
  prefetch's corruption under DMA; wrong-path CBOs).

## What a faster path is worth (measured)

GB5's 77 SimPoints with the testbench's DDR model calibrated to the board (`+ddr_cut=N`, every draw N
cycles shorter; `docs/SmolRV64-Spec.md` §11.2), main's RTL, no L2:

| port read latency, core cycles | single-core cycles | the largest |
|---|---|---|
| 35 (the board today) | | |
| 25 | -4.31% | Gaussian Blur -8.3%, Clang -7.8%, N-Body -6.7%, Speech -5.6%, ML -5.2%, Navigation -5.2% |
| 15 | -7.74% | Clang -15.1%, Gaussian Blur -14.4%, N-Body -12.8%, Speech -10.6%, Navigation -9.1% |

About 4% per 10 cycles. Behind the 1.5 MiB L2 GB5's DRAM reads fall about fourfold (2.42 per 1000
instructions, the L2 plan's model, against ~9.5 line fills today), so on GB5 the prize shrinks with it;
the same structural latency sits on every L2 access if the L2 stays behind the asynchronous crossing,
and larger-footprint workloads (Tommy is adding them) keep more of it.

## The design

### The controller (built: `src/ddr4_ctl.v`, `ddr4_mem.v`, its bench `tb_ddr4_mem.v`)

- **The PHY-only interface** (PG150's "PHY Only Interface"; the generated IP's `mc_*` port, which its
  own controller drives today). The IP keeps the PHY, the calibration and its MicroBlaze; before
  `calDone` they reset, program the mode registers (fixed by the IP's parameters), ZQCL and train the
  DRAM. After it every command is ours: four command slots a ui_clk, CAS only in slots 0 and 2, one BL8
  burst (32 bytes) a cycle each way. A write CAS at cycle N gets `wrDataEn` with its tag at N+2 and
  wants the data at N+3 (the PHY holds none); a read CAS returns its burst and tag at a fixed,
  calibrated latency (about 15-16 cycles), in CAS order, with no back-pressure. The controller also
  owes refresh, ZQCS, ODT on writes and the PHY's VT tracking: in every microsecond a read, three
  cycles with no read CAS and then a `gt_data_ready` pulse. The free budget: the IP's AXI shim,
  controller and UI, 5,656 LUTs and 6,475 flops.
- **Clocking.** The controller runs on ui_clk (333 MHz), as the PHY requires. The first landing keeps
  `ddr_port_cdc`'s asynchronous FIFOs to the core; the synchronous 2:1 crossing (probe_clk is a
  BUFGCE_DIV of ui_clk, about 2.7 ns behind it: registers held two ui_clks, a multicycle path) is its
  own step after.
- **Requesters own the data.** A request is {line, read or write, the requester's buffer}; the PHY's
  tag is {buffer, half}, so a read's bursts land straight in that buffer and a write's data is read
  from it the cycle after `wrDataEn`. The caches' line port (`ddr4_port_line`) has eight read and four
  write buffers and streams a landed line back as today's four 128-bit beats; the DMA masters' AXI port
  (`ddr4_port_axi`, until coherent DMA) takes one transaction at a time, each within one line (the
  virtio masters' single beats, the scanout's line reads), and goes first.
- **Address map** (`line` = the DRAM window's line index): a line lives in one bank, its two bursts at
  columns c and c+8 of one row (tCCD_L apart, one ACT a line); consecutive lines alternate bank
  groups, so a stream keeps the bus busy; then the line in the row, the bank, the row
  (`line[0]` group, `[6:1]` column, `[25:9]` row, bank `[8:7] ^ row[1:0] ^ row[3:2]`).
- **Scheduling.** One queue of eight. Column commands go in queue order, so data comes back in
  request order; rows open and close ahead: each bank's owner is its oldest queued request, and only
  the owner precharges or activates it (the oldest owner first). Banks stay open (open page) until
  another row's owner or a refresh closes them. Reads ahead of writes and write batching wait for a
  measurement that wants them.
- **Timing.** Each rule a down-counter in cycles for the fixed slots (CAS 0, ACT 1, PRE/REF/ZQCS 3),
  each with a registered zero flag. The bench's DRAM model (`src/ddr4_phy_model.vh`) checks every rule
  in DRAM clocks. The column commands' counters are at their exact minimum (tRCD, tCCD_L, tWTR_S/L,
  read to write: one cycle less fails in the model); PRE and ACT are chosen a cycle before their
  slots, so the row rules carry that cycle (tRP, tRRD, tRFC fail at two cycles less; tFAW cannot
  bind, ACTs being three cycles apart at least), as do tRAS, tRTP and write recovery against a PRE.
  The bench also fails a slow refresh rate, swapped write or DMA read halves and a missing VT read.
- **VT tracking.** A read is injected when none has issued by cycle 200 of an interval (the head's
  own line, or an open bank's row), and a refresh waits for its interval's read.

### Coherent DMA

- **DMA goes through the coherent side** in 64-byte lines, each client double-buffered: a read lands
  whole in its free buffer; a write is presented whole with its byte mask when its buffer is full.
  Scanout at 1080p60 is about one line every 21 core cycles, under 5% of the DRAM's peak.
- **The L2 is relaxed inclusive, so the D$ is snooped.** A third tag copy in the D$ (beside the
  lookup's and the store lookup's), read at the set PA[11:6] for each DMA line: a DMA read that hits a
  dirty line takes it (or has it written back first); a DMA write that hits invalidates the line,
  merging the D$'s dirty bytes for a partial write. The I$ stays non-coherent (Linux issues
  `fence.i` after loading code).
- **Linux**: the device tree marks the DMA masters `dma-coherent`, and the CBOs around their buffers go.

### 64 bytes wide, and the fallback

- **The L2**: its line is eight URAM288s wide already (512 data bits), one access a line.
- **The D$'s fills**: its data is diagonal (a line's eight 8-byte chunks in eight RAMB36 arrays,
  rotated by way), so a 64-byte fill writes all eight arrays in one cycle and the load path does not
  change; the cost is a 512-bit rotate by way on the fill's write data (~1K LUTs). Today a beat writes
  two arrays.
- **The I$** (odd/even banks) is looked at separately.
- **The fallback** at 32 bytes is two beats a line everywhere, the controller's own burst width.

## Order

Every step is measured or modelled first, then gated as today (riscv-tests, the unit benches, lint, the
60 M / 300 M lockstep, the glibc, sysd and storm locksteps, a build, the board, GB5).

0. **What the model still misses -- DONE 2026-10-21.** The copy's gap was the comparison: the
   calibration ran its kernels bare metal in the lockstep and under Linux on the board. One binary
   read `ddr_hpm` in-process around its timed passes, and under Linux in the RTL (from a Simmerv
   checkpoint) it copies at 4.53 cycles an element against the board's 4.64, with the same lines and
   read latencies of 38.4 against 36.8. Bare metal, the same RTL copies at 3.77: translation costs
   that copy 20% (a core item, not the memory's). The model errs slow on a read stream (open-row hits
   it lacks: 36.9 against the board's 31.9), which the bank-aware model below brings. The FP
   subtests' back end (twice the sim's on the board) stays open for that model to answer.
1. **The controller, in its own bench first**: our controller against a DDR4 timing-checking model
   behind a PHY-interface model, every timing rule asserted; then on the board in place of the IP's
   controller and its AXI path, below today's line port, with the synchronous crossing. Measured with
   `ddr_hpm`, the membench and GB5. The lockstep keeps its line-port model, recalibrated to the new
   latencies from `ddr_hpm`.
2. **Coherent DMA**: the D$'s snoop tag copy, the DMA clients on the coherent side with two buffers
   each, the device tree's `dma-coherent`.
3. **The L2** (the L2 plan's step), relaxed inclusive, 64 bytes wide, in the clock the step 1
   measurements favour.
4. **64-byte fills into the D$.**

## Open

- **Where the L2 sits**: in ui_clk next to the controller (a line in two half-beats, the plan's
  original place) or in the core's clock (a line a cycle, no crossing on an L2 hit).
- **The write path's buffering**: whether "the controller takes write data from the client's buffer
  when its burst needs it" meets timing at 333 MHz, or needs one line of staging.
- **Ordering between a DMA write and the core**: a DMA write visible to the core after its snoop, and
  the device's completion interrupt after both; the PLIC's ordering against the snoop.
