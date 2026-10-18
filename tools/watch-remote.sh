#!/usr/bin/env bash
# Wait for a job on a sim host, and never silently:
#
#   tools/watch-remote.sh <host> '<probe>' <deadline-seconds> [poll-seconds]
#
# Ends when the probe prints a line that is exactly DONE (exit 0), when the probe has failed 5
# times running -- the host unreachable, the probe broken (exit 2) -- or at the deadline (exit 3),
# saying which, with the probe's last output. Only the probe's OUTPUT counts, never its exit
# status: a `grep -c` that counts zero exits 1, and a loop gated on one ran four hours past its
# job on 2026-10-17. Set the deadline to about twice the run's expected length.
# <host> is M5 (resolved at every poll: its DHCP address moves), fastmac, or any ssh destination.
#   tools/watch-remote.sh M5 'grep -q ALL-DONE ~/gb5ck/rc-run.out && echo DONE' 7200
set -u
host=${1:?host}; probe=${2:?probe}; deadline=${3:?deadline seconds}; poll=${4:-60}
end=$(( $(date +%s) + deadline )); fails=0; out=""
while :; do
   case $host in
      M5)      dest="-o HostKeyAlias=192.168.1.110 $(getent hosts M5.local | awk '{print $1; exit}')" ;;
      fastmac) dest=192.168.1.135 ;;
      *)       dest=$host ;;
   esac
   out=$(ssh -n -o ControlMaster=no -o BatchMode=yes -o ConnectTimeout=20 $dest "$probe; echo PROBE-END" 2>&1)
   if [[ $out == *PROBE-END* ]]; then
      fails=0
      out=${out%PROBE-END*}
      if grep -qx DONE <<<"$out"; then echo "watch-remote $host: done at $(date +%H:%M)"; printf '%s' "$out"; exit 0; fi
   else
      fails=$((fails + 1))
      if [ $fails -ge 5 ]; then echo "watch-remote $host: the probe failed $fails times running, at $(date +%H:%M): $out"; exit 2; fi
   fi
   if [ "$(date +%s)" -ge $end ]; then echo "watch-remote $host: deadline at $(date +%H:%M), not done: $out"; exit 3; fi
   sleep "$poll"
done
