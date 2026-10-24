# simmem.sh -- a host's memory, booked by the simulations it runs. Sourced by core/run-linux.sh and
# core/run-cosim-linux.sh.
#
# A Linux run's footprint is known before it starts -- its DDR array, 2^MEM_LG2 bytes, the cosim's
# simmerv a second copy, and the model -- but the kernel hands the pages out as the guest touches
# them. So "is memory free now?" admits a run that later grows into the runs started after it, and
# the kernel kills the largest: two 4 GiB disk locksteps on mercury, beside three SimPoint sets
# that each started with 4 GiB to spare (2026-10-24). Instead each run books its whole footprint in
# a ledger, one file per run named by its PID, and starts only when the host holds it beside every
# booking still alive (SIMMEM_SPARE MiB, 4096 by default, stay for everything else) AND that much
# is free now (what runs outside the ledger).
#
#   simmem_book <MiB>   waits, then books <MiB> for this shell's PID, which the run keeps: the
#                       runner execs the binary, or waits on it
simmem_mib() {   # <total|free>: the host's physical or available memory, MiB
   if [ -r /proc/meminfo ]; then
      awk -v k="$([ "$1" = total ] && echo MemTotal || echo MemAvailable):" '$1 == k {print int($2 / 1024)}' /proc/meminfo
   elif [ "$1" = total ]; then
      echo $(( $(sysctl -n hw.memsize) / 1048576 ))
   else
      vm_stat | awk '/page size of/ {ps = $8} /^Pages (free|inactive|speculative):/ {gsub(/\./, "", $NF); p += $NF}
                     END {print int(p * ps / 1048576)}'
   fi
}
simmem_book() {
   local need=$1 d=/tmp/simmem-$(id -un) f used said=""
   local room=$(( $(simmem_mib total) - ${SIMMEM_SPARE:-4096} ))
   [ "$need" -le "$room" ] || { echo "simmem: $need MiB never fits this host ($room MiB to book)"; return 1; }
   mkdir -p "$d"
   while :; do
      exec 7>"$d/.lock"; flock -x 7
      used=0
      for f in "$d"/[0-9]*; do
         [ -e "$f" ] || continue
         if kill -0 "${f##*/}" 2>/dev/null; then used=$((used + $(cat "$f"))); else rm -f "$f"; fi
      done
      if [ $((used + need)) -le "$room" ] && [ "$need" -le "$(simmem_mib free)" ]; then
         echo "$need" > "$d/$$"; exec 7>&-
         echo "simmem: booked $need MiB (with $used MiB booked before, of $room)"
         return 0
      fi
      exec 7>&-
      [ -n "$said" ] || { echo "simmem: waiting to book $need MiB ($used of $room MiB booked, $(simmem_mib free) MiB free)"; said=1; }
      sleep 20
   done
}
