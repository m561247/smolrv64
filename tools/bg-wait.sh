#!/usr/bin/env bash
# Wait for a tools/bg.sh job: `tools/bg-wait.sh <name> [poll-seconds]`; prints the log's last
# lines when the PID is gone. Exact: the PID is the launched command's, so the wait ends when
# it does, whatever the log says.
set -u
name=${1:?name}; poll=${2:-60}
pid=$(cat "/tmp/bg-$name.pid") || exit 1
while kill -0 "$pid" 2>/dev/null; do sleep "$poll"; done
echo "bg $name: done at $(date +%H:%M)"
tail -n ${TAIL:-3} "/tmp/bg-$name.log"
