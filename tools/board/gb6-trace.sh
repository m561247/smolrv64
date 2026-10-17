#!/bin/sh
# GB6's single-core pass with gb5-run.sh's counter set sampled every 10 s (perf stat -I, CSV), and
# every line Geekbench prints stamped with the same clock, so each subtest's window can be cut out
# of the samples (tools/board/gb6-split.py, on coffee). The single-core switch is Geekbench 6 Pro's,
# so the full suite runs and Geekbench is stopped as the multi-core pass begins (its 17th "Running"
# line); perf keeps its counts when its child exits (never signal perf). The kernel truncates a
# command name to 15 characters, which is what pgrep -x matches. Usage: gb6-trace.sh <rtl>. Starts
# only on an idle machine (idle-wait.sh).
RTL=$1
RAW=/var/tmp/gb6-trace-$RTL-raw.log
CSV=/var/tmp/gb6-trace-$RTL-perf.csv
TS=/var/tmp/gb6-trace-$RTL-ts.log
rm -f "$RAW" "$CSV" "$TS"
. "$(dirname "$0")/idle-wait.sh"
cd /home/tommy/Geekbench-6.7.1-LinuxRISCVPreview || exit 1
EV=cycles,instructions,r0401,r0407,r0402,r0408,r0403,r0404,r0405,r0406,r0317,r0006,r0007,r0102,r0112
echo "$(date +%s.%N) === gb6 trace start rtl=$RTL idle-wait=$(( $(date +%s) - t0 ))s load=$(cut -d' ' -f1 /proc/loadavg) ===" >> "$TS"
perf stat -x, -I 10000 -e "$EV" -o "$CSV" ./geekbench_riscv64 --cpu 2>&1 |
   { n=0
     while IFS= read -r l || [ -n "$l" ]; do
        echo "$l" >> "$RAW"; echo "$(date +%s.%N) $l" >> "$TS"
        case "$l" in *Running*) n=$((n + 1))
           if [ $n -eq 17 ]; then
              echo "$(date +%s.%N) === single-core pass done: stopping Geekbench ===" >> "$TS"
              kill $(pgrep -x geekbench_riscv) 2>/dev/null
           fi ;;
        esac
     done; }
echo "$(date +%s.%N) === gb6 trace end ===" >> "$TS"
