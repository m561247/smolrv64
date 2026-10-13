#!/bin/sh
# GB5 single-core for the hang probes: the idle gate (idle-wait.sh), no Top-Down perf stat around
# the benchmark (perflog.sh's system-wide counters are the measurement). Every "Running X" line
# also goes to the kernel console, so the UART log shows the subtest markers between the PERF
# lines. Usage: gb5-probe.sh <tag>; the pid file /var/tmp/gb5-probe-<tag>.pid guards relaunches.
RTL=$1
echo $$ > /var/tmp/gb5-probe-$RTL.pid
RAW=/var/tmp/gb5-$RTL-raw.log
rm -f "$RAW"
. "$(dirname "$0")/idle-wait.sh"
cd /var/tmp/gbroot/gb || exit 1
echo "=== gb5 probe start $(date) idle-wait=$(( $(date +%s) - t0 ))s load=$(cut -d' ' -f1 /proc/loadavg) tag=$RTL ===" >> "$RAW"
echo "GB5 probe $RTL start" > /dev/kmsg
./geekbench_riscv64 --cpu 2>&1 | while IFS= read -r line; do
   echo "$(date +%T) $line"
   case "$line" in *Running*) echo "GB5 $line" > /dev/kmsg;; esac
done >> "$RAW"
echo "=== gb5 probe end $(date) ===" >> "$RAW"
echo "GB5 probe $RTL end" > /dev/kmsg
