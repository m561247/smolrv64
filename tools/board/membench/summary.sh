#!/bin/sh
# summary.sh: the memory figures that go beside every Geekbench run, in core cycles (each program
# counts its own user-mode cycles, so the machine's other work does not move them): a dependent
# load's latency at four footprints, and sequential read and write bandwidth at three: 32 KiB inside
# the D$, 512 KiB beyond it (DRAM: there is no L2 yet, and an L2 would hold it) and 64 MiB. Builds
# chase2 and bw here first (gcc, the full -march). ~1 min on an idle board.
#   sh summary.sh > /var/tmp/gb5-<rtl>-mem.txt
# The footprints name the level that serves the load: 16 KiB the D$ (load-use); 256 KiB beyond it,
# its 64 pages in the dTLB's first level (DRAM: there is no L2 yet, and an L2 would serve it);
# 4 MiB, 1024 pages, the dTLB's second level as well; 64 MiB a page walk on every load.
D=$(cd "$(dirname "$0")" && pwd)
make -s -C "$D" chase2 bw > /dev/null || { echo "membench: build failed"; exit 1; }
tr -d '\0' < /proc/device-tree/model 2>/dev/null; echo; date -u
echo "== latency: chase2, one chain"
for kib in 16 256 4096 65536; do "$D/chase2" $kib 1 1000000; done | tee /tmp/mb-lat.$$
echo "== bandwidth: bw, sequential 8-byte accesses"
{ for m in r w; do "$D/bw" $m 32 2000; "$D/bw" $m 512 128; "$D/bw" $m 65536 4; done; } | tee /tmp/mb-bw.$$
echo "== summary"
awk '{ c[$1] = $4 } END {
        printf "latency, cycles a dependent load: D$ hit (load-use) %.1f | beyond the D$ (no L2: DRAM) %.1f | + the dTLB second level %.1f | + a page walk %.1f\n",
               c[16], c[256], c[4096], c[65536] }' /tmp/mb-lat.$$
awk '{ b[$1 " " $3] = $4 } END {
        printf "bandwidth, bytes a cycle: read 32 KiB %.2f, 512 KiB %.2f, 64 MiB %.2f | write 32 KiB %.2f, 512 KiB %.2f, 64 MiB %.2f\n",
               b["32 read"], b["512 read"], b["65536 read"], b["32 write"], b["512 write"], b["65536 write"] }' /tmp/mb-bw.$$
rm -f /tmp/mb-lat.$$ /tmp/mb-bw.$$
