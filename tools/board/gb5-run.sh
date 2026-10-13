#!/bin/sh
# Full GB5 on the board for a score, with the Top-Down counters; the raw output is kept whole
# (a grep whitelist once discarded the result URL). Usage: gb5-run.sh <rtl>
# The run starts only on an idle machine (idle-wait.sh).
RTL=$1
RAW=/var/tmp/gb5-$RTL-raw.log
OUT=/var/tmp/gb5-$RTL-perf.txt
TS=/var/tmp/gb5-$RTL-ts.log
rm -f "$RAW" "$OUT" "$TS"
. "$(dirname "$0")/idle-wait.sh"
cd /var/tmp/gbroot/gb || exit 1
echo "=== gb5 full start $(date) epoch=$(date +%s.%N) idle-wait=$(( $(date +%s) - t0 ))s load=$(cut -d' ' -f1 /proc/loadavg) rtl=$RTL ===" >> "$RAW"
# EV picks the events, the Top-Down set by default. At most cycles, instructions and 13 more:
# that fills the PMU, and one event over multiplexes every count. IV=<ms> has the same perf
# session print every interval as well (no second session, no counter more), and every line
# Geekbench prints is stamped in $TS, so the counts split by subtest.
EV=${EV:-cycles,instructions,r0401,r0407,r0402,r0408,r0403,r0404,r0405,r0406,r0317,r0006,r0007,r0102,r0112}
perf stat ${IV:+-I $IV} -e "$EV" -o "$OUT" ./geekbench_riscv64 --cpu 2>&1 |
   while IFS= read -r l || [ -n "$l" ]; do echo "$l" >> "$RAW"; echo "$(date +%s.%N) $l" >> "$TS"; done
echo "=== gb5 full end $(date) ===" >> "$RAW"
