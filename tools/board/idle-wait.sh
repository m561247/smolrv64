# Sourced by the board's benchmark runners: returns once the machine is idle -- boot finished,
# none of the post-boot jobs (apt, man-db, snapd, cloud-init, sysstat ...) alive, and the CPU
# idle for a whole 20 s window -- or after 900 s, saying why it gave up. t0 is when it started.
cpu_idle_pct() {   # idle share of the CPU over the next 20 s, in whole percent: 100 minus the
   # busy ticks (user+nice+system+irq+softirq+steal) over the wall-clock ticks. This kernel
   # accounts the idle loop as iowait (/proc/stat's idle column barely moves), so a share taken
   # from the idle column reads 0 on an idle board and the gate only ever expires.
   set -- $(head -1 /proc/stat); a_busy=$(( $2+$3+$4+$7+$8+$9 ))
   sleep 20
   set -- $(head -1 /proc/stat); b_busy=$(( $2+$3+$4+$7+$8+$9 ))
   busy=$(( 100 * (b_busy - a_busy) / (20 * $(getconf CLK_TCK)) ))
   echo $(( busy > 100 ? 0 : 100 - busy ))
}
t0=$(date +%s)
while :; do
   if [ $(( $(date +%s) - t0 )) -ge 900 ]; then echo "idle wait expired after 900 s: $st / $busy / idle ${idle}%"; break; fi
   st=$(systemctl is-system-running 2>/dev/null)
   busy=$(pgrep -l -f 'apt|dpkg|mandb|unattended|snapd|cloud-init|sysstat|/sa1|fstrim|e2scrub|logrotate|motd-news|update-notifier' | grep -v pgrep | head -3 | tr '\n' ' ')
   idle=$(cpu_idle_pct)
   case "$st" in running|degraded) ;; *) echo "waiting: system $st"; continue;; esac
   [ -z "$busy" ] || { echo "waiting: $busy"; continue; }
   [ "$idle" -ge 98 ] || { echo "waiting: cpu idle ${idle}%"; continue; }
   break
done
