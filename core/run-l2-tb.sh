#!/bin/bash
# rv_l2's bench (tb_rv_l2.v): random reads, whole-line and partial writes against a golden memory,
# over in-order and reordering memory, several seeds -- on a 16-set build (evictions, and lookups
# waiting on MSHRs and write-backs, in every run) and on the shipping 4096 sets.
#   ./run-l2-tb.sh [seeds...]
set -u
cd "$(dirname "$0")"
build() {   # <obj dir> [verilator flags]
   verilator --binary --timing -j 0 -sv -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
      -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-PROCASSINIT \
      -I../src --top-module tb --Mdir "$1" -o tb_l2 "${@:2}" \
      rv_l2.v smolrv64_uram_be.v ../src/smolrv64_sdpram.v tb_rv_l2.v > "$1.build.log" 2>&1 \
      || { echo "BUILD FAILED ($1)"; grep -m10 '%Error' "$1.build.log"; exit 1; }
}
build obj_dir_l2
build obj_dir_l2_big -GSB=12
# Each seed runs over both memory orders and seven shapes: the default, a slow memory (every MSHR
# busy), a fast one with no gaps between beats (fills racing hits for the channel up), beats with
# long gaps, three requests outstanding, a pool eight times the cache (mostly misses, write-backs
# below), and a pool smaller than a way's sets with partial writes half the writes.
CFGS=("" "+latmin=100 +latmax=300" "+latmin=4 +latmax=12 +gaps=0" "+gaps=70" "+maxout=3"
      "+lines=4096 +writes=50" "+lines=48 +partial=50")
rc=0; n=0; bad=0
run() {     # <binary> <args...>
   local out
   out=$("$1" "${@:2}" 2>&1)
   n=$((n + 1))
   if ! grep -q 'L2-TB PASS' <<< "$out"; then
      bad=$((bad + 1)); rc=1
      echo "---- ${*:2}"; grep -iE 'FAIL|fatal|Error' <<< "$out" | head -5
   elif [ "${#@}" -le 2 ]; then
      grep 'L2-TB PASS' <<< "$out"
   fi
}
for s in ${@:-1 2 3 4}; do
   for mode in "" "+reorder"; do
      for cfg in "${CFGS[@]}"; do
         run ./obj_dir_l2/tb_l2 +seed=$s $mode $cfg
      done
      run ./obj_dir_l2_big/tb_l2 +seed=$s $mode +lines=40000 +cycles=400000
   done
done
echo "L2-TB: $((n - bad)) of $n runs pass"
exit $rc
