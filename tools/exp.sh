#!/usr/bin/env bash
# One command for a performance experiment: the standard measurements of a tree, spread over the
# simulation hosts, compared with the baseline's.
#
#   tools/exp.sh <tag> [<tree>]     # measure <tree> (default: this checkout) as <tag>
#   tools/exp.sh main               # the baseline: run it once per main commit, on main's tree
#   BASE=<tag> tools/exp.sh ...     # compare against another tag (default: main-<main's hash>)
#   tools/exp.sh -t <tag> [<base>]  # print a finished experiment's table again
#   SET=sp tools/exp.sh <tag> ...   # GB5's single-core section as SimPoints instead (fastmac only)
#   RUNS='pdf boot60m' tools/exp.sh <tag> ...   # only the named runs of the set
#
# The set: the 60 M Linux lockstep (retires; the lockstep is the correctness check), Dhrystone and
# CoreMark in lockstep (workloads/rvbench, cycles), the four pi checkpoint slices and the five GB5
# checkpoint slices (20 M retires warm, 50 M measured; cycles). M5 runs the locksteps and pi,
# fastmac the GB5 slices. SET=sp runs workloads/gb5/simpoints.txt's 77
# points instead (the same 20 + 50 M each), and the table totals them into each subtest's cycles.
# All runs start together, at most J at a time per kind, the kinds side by side: the runners build
# a stale model once under their build lock and then run from it together. The tree is copied
# with rsync (tracked and untracked-not-ignored files, no platforms/), so an uncommitted edit is
# measured as it stands. Results land in ~/exp-results/<tag>/ on coffee: a
# log per run, and the table in table.txt.
set -u
here=${EXP_HERE:-$(cd "$(dirname "$0")/.." && pwd)}
# It runs from a private copy: bash reads a script as it executes, and an edit to this file would
# reach the experiments still waiting in it. The copy deletes itself (the open file stays readable).
if [ -z "${EXP_HERE:-}" ]; then c=$(mktemp); cp "$0" "$c"; EXP_HERE=$here exec bash "$c" "$@"; fi
case $0 in /tmp/*|"${TMPDIR:-/tmp}"/*) rm -f "$0" ;; esac
R=$HOME/exp-results
O="-o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=20"
M5_OPT="$O -o HostKeyAlias=192.168.1.110"; M5_IP=$(getent hosts M5.local | awk '{print $1; exit}')
FM_OPT="$O"; FM_IP=192.168.1.135
M5_ROOT=exp; FM_ROOT=/Volumes/tommy/exp          # M5's under its $HOME
M5_CK='$HOME/gb5ck'; FM_CK=/Volumes/tommy/gb5ck   # the checkpoints: <ckpt>.ckpt, pi/ck/<n>.ckpt

table() { python3 "$here/tools/exp-table.py" "$R/$1" ${2:+"$R/$2"}; }
if [ "${1:-}" = "-t" ]; then table "${2:?tag}" "${3:-}"; exit; fi
tag=${1:?usage: tools/exp.sh <tag> [<tree>]}
tree=$(cd "${2:-$here}" && pwd)
if [ "$tag" = main ]; then tag=main-$(git -C "$tree" rev-parse --short=8 HEAD); fi
base=${BASE:-main-$(git -C "$here" rev-parse --short=8 origin/main)}
mkdir -p "$R/$tag"
echo "exp $tag: $tree at $(git -C "$tree" rev-parse --short=8 HEAD)$( [ -n "$(git -C "$tree" status --porcelain -- core src | grep -v '^??')" ] && echo ' with edits')"

# the tree, to both hosts, with the rvbench binaries built here (the hosts have no RISC-V toolchain)
list=$(mktemp)
(cd "$tree" && git ls-files -co --exclude-standard | grep -v '^platforms/') > "$list"
make -s -C "$tree/workloads/rvbench" dhrystone.bin coremark.bin > /dev/null || exit 1
echo workloads/rvbench/dhrystone.bin >> "$list";  echo workloads/rvbench/coremark.bin >> "$list"
tohost() { riscv64-linux-gnu-nm "$tree/workloads/rvbench/$1.elf" | awk '$3 == "tohost" {print $1}'; }
rsync -a --files-from="$list" -e "ssh $M5_OPT" "$tree/" "$M5_IP:$M5_ROOT/$tag/" || exit 1
rsync -a --files-from="$list" -e "ssh $FM_OPT" "$tree/" "$FM_IP:$FM_ROOT/$tag/" || exit 1
rm -f "$list"

runner() {   # <tree> <out> <ckpt dir> <parallel runs> <runs: name:kind:arg ...>
   local t=$1 o=$2 ck=$3 j=$4 k r n kk a rs; shift 4
   cat <<'HEAD'
#!/bin/bash
export PATH=/opt/homebrew/bin:$HOME/.cargo.arm64-darwin/bin:$PATH
run() {   # <name> <kind> <arg>
   case $2 in
      boot) CYC=$3 ./run-cosim-linux.sh ;;
      rvb)  FW=$T/workloads/rvbench/${3%,*}.bin INITRD= CYC=400000000 VDEFS=-DSMOLRV64_IW=3 \
               PLUSARGS="+tohost=${3#*,}" ./run-cosim-linux.sh ;;
      pi)   CKPT=$CK/pi/ck/$3.ckpt CYC=0 ./run-linux.sh +measure_from=20000000 +max_retires=70000000 ;;
      gb5)  CKPT=$CK/$3.ckpt MEM_LG2=31 CYC=0 ./run-linux.sh +measure_from=20000000 +max_retires=70000000 ;;
   esac > $O/$1.log 2>&1; echo "rc=$?" >> $O/$1.log
}
kind() {  # <kind> <name:arg ...>: the runs in parallel, J at a time
   local k=$1 n a r; shift
   for r in "$@"; do
      IFS=: read n a <<< "$r"
      while [ $(jobs -pr | wc -l) -ge $J ]; do sleep 10; done
      run $n $k $a &
   done
   wait
}
HEAD
   echo "T=$t; O=$o; CK=$ck; J=$j; mkdir -p \$O; cd \$T/core || exit 1"
   for k in boot rvb pi gb5; do
      rs=""
      for r in "$@"; do IFS=: read n kk a <<< "$r"; [ "$kk" = "$k" ] && rs="$rs $n:$a"; done
      [ -n "$rs" ] && echo "kind $k$rs &"
   done
   echo 'wait'
   echo 'echo EXP-DONE > $O/done'
}
m5_runs="boot60m:boot:60000000 dhry:rvb:dhrystone,$(tohost dhrystone) coremark:rvb:coremark,$(tohost coremark) pi450:pi:450000000 pi700:pi:700000000 pi950:pi:950000000 pi1150:pi:1150000000"
fm_runs="nav:gb5:140000000000 html5:gb5:154500000000 sqlite:gb5:161000000000 pdf:gb5:171000000000 camera:gb5:202000000000"
if [ "${SET:-}" = sp ]; then   # a point's checkpoint is sp/<instret>.ckpt
   m5_runs=""
   fm_runs=$(awk -F'\t' '$1 == "point" {printf " sp%s:gb5:sp/%s", $5, $5}' "$here/workloads/gb5/simpoints.txt")
fi
if [ -n "${RUNS:-}" ]; then   # only the runs named
   keep() { local r o=""; for r in $1; do [[ " $RUNS " == *" ${r%%:*} "* ]] && o="$o $r"; done; echo "$o"; }
   m5_runs=$(keep "$m5_runs");  fm_runs=$(keep "$fm_runs")
fi
runner "\$HOME/$M5_ROOT/$tag" "\$HOME/$M5_ROOT/$tag.out" "$M5_CK" 9 $m5_runs |
   ssh $M5_OPT $M5_IP "rm -rf $M5_ROOT/$tag.out; cat > $M5_ROOT/$tag.sh; chmod +x $M5_ROOT/$tag.sh; (nohup $M5_ROOT/$tag.sh > /dev/null 2>&1 < /dev/null &)" || exit 1
runner "$FM_ROOT/$tag" "$FM_ROOT/$tag.out" "$FM_CK" 12 $fm_runs |
   ssh $FM_OPT $FM_IP "rm -rf $FM_ROOT/$tag.out; cat > $FM_ROOT/$tag.sh; chmod +x $FM_ROOT/$tag.sh; (nohup $FM_ROOT/$tag.sh > /dev/null 2>&1 < /dev/null &)" || exit 1
echo "exp $tag: running on M5 and fastmac ($(date +%H:%M))"

# wait for both, never silently (tools/watch-remote.sh), then fetch the logs and print the table
"$here/tools/watch-remote.sh" M5 "test -f $M5_ROOT/$tag.out/done && echo DONE" 10800 60 > /dev/null ||
   { echo "exp $tag: M5 did not finish"; exit 1; }
"$here/tools/watch-remote.sh" fastmac "test -f $FM_ROOT/$tag.out/done && echo DONE" 10800 60 > /dev/null ||
   { echo "exp $tag: fastmac did not finish"; exit 1; }
rsync -a -e "ssh $M5_OPT" "$M5_IP:$M5_ROOT/$tag.out/" "$R/$tag/"
rsync -a -e "ssh $FM_OPT" "$FM_IP:$FM_ROOT/$tag.out/" "$R/$tag/"
[ -d "$R/$base" ] && [ "$base" != "$tag" ] || base=""
table "$tag" "$base" | tee "$R/$tag/table.txt"
