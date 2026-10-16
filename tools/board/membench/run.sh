#!/bin/sh
# run.sh <tag>: the memory set on an idle board (after `make` here) -- chase2 (one chain over each
# footprint, then k chains over three), clamchowder's MemoryLatency (its c and tlb tests) and
# MemoryBandwidth (mb_rv64.s: read, write, add), and dsheffie's mem-lat; to
# /var/tmp/ubench/mb-<tag>.txt. Watch that file over NFS, never by ssh: a login starts a
# systemd --user that takes the core for seconds, which every tool here but chase2 (it counts
# its own user-mode cycles) reads as memory latency.
T=${1:?usage: run.sh <tag>}
D=$(cd "$(dirname "$0")" && pwd)
. "$D/../idle-wait.sh" > /dev/null
cd "$D" || exit 1
mkdir -p /var/tmp/ubench
{
   tr -d '\0' < /proc/device-tree/model; echo; date -u
   echo "== chase2, one chain"
   for kib in 16 64 128 192 256 512 1024 2048 4096 8192 16384 32768 65536; do ./chase2 $kib 1 1000000; done
   echo "== chase2, k chains: 256 KiB (64 pages, the dTLB's first level), 4 MiB (its second level), 32 MiB (a walk a load)"
   for kib in 256 4096 32768; do for k in 1 2 3 4 6 8 12 16; do ./chase2 $kib $k $((1000000 / k)); done; done
   echo "== MemoryLatency -test c (ns)"
   ./MemoryLatency -test c -maxsizemb 64 -iter 1000000 2>&1
   echo "== MemoryLatency -test tlb (ns over the reference)"
   ./MemoryLatency -test tlb -maxsizemb 64 -iter 1000000 2>&1
   for m in asm write add; do
      echo "== MemoryBandwidth -method $m (GB/s)"
      for s in 16 32 64 96 128 256 512 1024 4096 16384 65536; do ./MemoryBandwidth -method $m -sizekb $s -data 8 2>&1 | tail -1; done
   done
   echo "== mem-lat (mem_micro -m 23)"
   mem-lat/mem_micro -m 23 2>&1
   date -u
} > /var/tmp/ubench/mb-$T.txt 2>&1
echo "done $T"
