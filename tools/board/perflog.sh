#!/bin/sh
# Per-second cycle/instruction counts on the UART (/dev/ttyS0, so the console log on coffee keeps
# them past a silent hang): where in the instruction stream a hang sits. For hang hunting only,
# never during a measured run: its system-wide counters take PMU counters from gb5-run.sh's
# perf stat, whose 15 events then multiplex -- a CPU-bound loop ran 19% slower and its counts
# came out biased (instructions +9%) -- and the kernel log would cost 8% more (every line goes
# to the framebuffer console too; the UART alone costs 0.6%). Only a previous logger (its pid in
# /var/tmp/perflog.pid) is stopped: killing the runner's perf kills the benchmark. Run as root,
# BEFORE the workload starts.
[ -f /var/tmp/perflog.pid ] && kill $(cat /var/tmp/perflog.pid) 2>/dev/null
echo "PERFLOG start $(date +%T)" > /dev/ttyS0
nohup sh -c 'perf stat -a -x, -I 1000 -e cycles,instructions,instructions:u 2>&1 | while read l; do echo "PERF $l" > /dev/ttyS0; done' > /dev/null 2>&1 < /dev/null &
echo $! > /var/tmp/perflog.pid
echo "perflog running"
