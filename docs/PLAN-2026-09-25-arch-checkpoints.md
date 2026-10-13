# Architectural checkpoints and SimPoints

Status: APPROVED (Tommy, 2026-09-25). Steps 1-4 built; step 5 (SimPoints) is open. Supersedes the order of
`docs/PLAN-cosim-checkpoint.md`. That plan (a Verilator `--savable` snapshot of one RTL binary)
stays valid for its narrower use, rerunning a divergence many times on the same binary, and
comes after this.

## Why

- **Bugs:** run a few million instructions around the point where a failure appears, instead of
  a whole boot and hours of guest time.
- **Performance:** measure CPI stacks and pipe traces on representative slices of long workloads
  (SPEC, Geekbench subtests) in RTL simulation, on any RTL version.
- **SimPoints:** pick those slices by clustering basic-block vectors, so a handful of points
  stands for the whole run.

The checkpoint is **architectural**: registers, CSRs, device registers and memory, captured by
Simmerv. It is restored into the RTL of any version by ordinary instructions and MMIO. It holds
no microarchitectural state, so it never goes stale when the RTL changes; caches, TLBs and
predictors are warmed by running a warm-up window before measuring.

## The checkpoint format

A directory `<name>.ckpt/`:

- **`sim.snap`:** Simmerv's own snapshot of the same state, exact down to the device models.
  Simmerv and the lockstep restore from it; the RTL restores from the other two files.
- **`state.txt`:** one `key value` per line, values in hex. The keys:
  - `pc`, `priv`, `x1`..`x31`, `f0`..`f31`;
  - every CSR by name (the list in "The restore stub" below);
  - `clint.mtime`, `clint.mtimecmp`, `clint.msip`;
  - `plic.prio.<src>`, `plic.enable`, `plic.threshold`;
  - `uart.ier`, `uart.lcr`, `uart.mcr`, `uart.scr`, `uart.fcr`;
  - `instret` (instructions executed up to the checkpoint; the `minstret` CSR is a key of its
    own, since Simmerv's counts `wfi` cycles too);
  - provenance as `#` comment lines: the workload, the Simmerv commit, when it was taken.
- **`mem.zst`:** a zstd stream of `{u64 physical address, 4096 bytes}` records, one per non-zero
  4 KiB page, in address order. Only touched memory costs disk, and zstd makes those pages
  small. Both sides already have zstd: Simmerv's CLI links the `zstd` crate, and the host has
  `libzstd`.

## The restore stub (RTL side)

A small M-mode program, generated from `state.txt` by `tools/ckpt-stub.py`, assembled at the
boot SRAM (0x7000_0000), with its data table after it. The testbench build for checkpoints resets
there. In order:

1. **Devices over MMIO:**
   - CLINT `mtimecmp` and `msip`;
   - PLIC priorities, enables and threshold;
   - UART IER/LCR/MCR/SCR/FCR.
2. **CSRs, with interrupts still disabled** (`mstatus.MIE` is 0 from reset):
   - satp; the S and M trap registers (tvec, epc, cause, tval, scratch);
   - medeleg/mideleg, mie, mip's software bits, m/scounteren, m/senvcfg, mstateen0, stimecmp;
   - mhpmevent and mhpmcounter, mcountinhibit.
3. **FP:** set `mstatus.FS` non-Off, then fcsr and f0..f31.
4. **`mstatus`:** the checkpoint's value with `MIE` = 0, `MPP` = the checkpoint privilege and
   `MPIE` = its `MIE`. It is written after the FP restore so FS comes back exactly as saved.
5. **`mepc`** = the checkpoint PC. Then `mtime` over MMIO, and `mcycle`/`minstret`, the latter
   corrected by the few instructions that follow it.
6. **x1..x31** from the table, using x31 as the base, whose own load comes last.
7. **`mret`.**

**No hardware addition.** The `mret` leaves `mepc`, `MPP` and `MPIE` different from the
checkpoint's. Below M-mode those three are dead: only M-mode reads them, and every way into
M-mode is a trap that writes all three first. Simmerv therefore takes checkpoints only below
M-mode, and the restore is architecturally exact with ordinary instructions. Dromajo restored
through debug mode's `dret` because it also checkpointed inside M-mode; skipping those points is
cheaper than a debug mode or a custom CSR. Simmerv never runs the stub: it restores `sim.snap`.

**Known deviations**, all acceptable:
- An LR/SC reservation is not restored. The checkpoint taker avoids points inside an LR/SC pair.
- The CLINT's prescaler phase is not writable, so time may land up to one tick apart.
- `mepc`/`sepc`/`mtval`/`stval` round-trip exactly only when canonical. A real checkpoint's are.

**Quiescence:** the PLIC's pending and in-service state cannot be recreated by MMIO alone. So a
checkpoint is taken only where:
- no PLIC source is pending (Simmerv's PLIC keeps a claimed source pending until it is completed,
  so this also excludes a claim in progress);
- the UART holds no received byte and its divisor latch is closed (Simmerv transmits at once);
- no LR reservation is open and the hart is not in `wfi`;
- `mstatus.MPRV` is clear (the stub's own loads follow its `mstatus` write);
- the hart is below M-mode.

Simmerv advances, in its own batches and up to 100 M instructions, to the next such point.

## RTL testbench changes (`core/tb_smolrv64_linux.v`, the runners)

- **`+ckpt=<dir>`:** a C++ DPI loader streams `mem.zst` and writes each non-zero line into the DDR
  array (a Verilog-exported `ckpt_line(index, data)`, `src/ckpt_dpi.cpp`). The rest of the array stays zero.
  `+fw/+dtb/+initrd` are not needed.
- **`+lram=<hex>`:** the boot SRAM is loaded at run time (the stub). Today it can only be loaded at
  compile time (`SOC_BOOT_HEX`).
- **The checkpoint build:** `TB_RESET_PC = 0x7000_0000`, selected by a runner flag. The runners
  already keep one binary per configuration.
- **`+measure_from=<retires>`**: the testbench's statistics count only from the cycle the retire
  count reaches it, and the report divides by that window's cycles and retires (the core's own
  sim counters, WALK-SIM and MEMDEP, stay whole-run). **`+max_retires=<n>`** ends the run.
- **Lockstep:** the bridge gets `simmerv_load_ckpt(ctx, dir)` in the cosim C API, which loads the
  same directory. It ignores retires while the PC is in
  the boot SRAM, so the stub is never compared, and compares from the first retire at the
  checkpoint PC.

## Simmerv changes (`~/simmerv`)

- **`--ckpt-at N[,N...]:<dir>`** in the CLI: at each instruction count N, advance to the next
  quiescent point and write `<dir>/<N>.ckpt/`; the run ends after the last one.
  - Simmerv takes interrupts only at the end of a batch of blocks, and the batches depend on its
    uop cache, which a restore starts cold. So the writer continues the run from its own
    snapshot: a run with checkpoints goes on exactly as a run restored from its latest one.
  - The snapshot carries the retired-instruction count (`seqno`, format `SIMMERVC12`), so a
    restored run numbers instructions as the original did.
- **`--insn-time K`**: the CLINT frozen, `mtime` = instructions retired / K. Simmerv's CLINT otherwise
  follows the host's wall clock, so a run -- and its timer interrupts -- would differ each time. With
  it, a run and its checkpoints are reproducible; K ~ 100 matches the RTL's pace (one tick per 332
  cycles at an IPC around 0.3).
- **`simmerv_load_ckpt(ctx, dir)`** in the cosim crate: loads `<dir>/sim.snap`.
- **`--bbv <interval>:<file>`**: one line per interval of basic-block counts (block start PC, the
  instructions executed in it), for SimPoints.

## SimPoints (`tools/simpoint.py`)

1. Read the BBV file.
2. Random-project each interval's normalized vector to 15 dimensions.
3. Run k-means for k = 1..K, several seeds each, and pick k by BIC.
4. Output each cluster's interval nearest the centroid, with its weight.

This is pure Python; the host has no numpy, and the sizes (thousands of intervals, 15
dimensions) do not need it. The points go to `--ckpt-at` at (interval start − warm-up). The
estimate is CPI ≈ Σ weight × CPI(point).

## Steps, each with its own test

1. **The RTL restore, without Simmerv.** The testbench changes and `tools/ckpt-stub.py`, plus a
   hand-made checkpoint: tiny128's reset state (PC 0x8000_0000, a1 = the DTB, memory = firmware +
   DTB + initrd), written by a small script into the checkpoint format.
   - Test: the restored run boots and prints the same console as a normal run, and its retire
     count differs from the normal run's only by the stub's length.
   - DONE: 30 M cycles of tiny128 from its restored reset state print the same 19 console lines,
     timestamps included, 72 retires behind the normal boot (the stub's cycles).
2. **Simmerv export and load.** `--ckpt-at`, quiescence, `simmerv_load_ckpt`.
   - Test: in Simmerv alone, a run restored from `N.ckpt` retires the same stream (a running hash
     of PC, instruction, destination and value) as a straight run, at three N on tiny128 and one
     on the Geekbench image past the kernel boot.
   - DONE on tiny128 (Simmerv ckpt branch): restored at 20 M or at 60 M, the state and memory at
     the 150 M checkpoint are identical to the straight run's. A final-state comparison stands in
     for the stream hash. The Geekbench image is still to do.
3. **Lockstep from a checkpoint.**
   - Test: tiny128 checkpointed at N = 20 M instructions and restored under lockstep runs clean
     for 20 M more.
   - Negative control: a corrupted `state.txt` register diverges.
   - DONE: from the 20 M checkpoint, 60 M cycles (15.19 M retires) lockstep clean; sp off by
     16 diverges at retire 14. A corrupted s1 did not diverge within 1 M retires, because s1 is
     dead at that point.
   - Usage: `simmerv-cli -n -m 512 --insn-time 100 --ckpt-at 20M:<dir> <images>`, then
     `CKPT=<dir>/20000000.ckpt core/run-cosim-linux.sh` (or `core/run-linux.sh` without
     the lockstep).
4. **Measurement windows.** `+measure_from` and `+max_retires`, and a first study: CPI stacks at a
   few points of the Geekbench image.
   - DONE (2026-09-27): Simmerv checkpoints in the middle of AES-XTS, Camera, Gaussian Blur,
     Structure from Motion and Machine Learning, 20 M warm retires then 50 M measured.
5. **SimPoints.** `--bbv`, `tools/simpoint.py`, checkpoints at the chosen points.
   - Validation: on a workload short enough to run whole in RTL (the glibc harness), the weighted
     estimate against the full run's CPI.
