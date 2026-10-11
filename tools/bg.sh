#!/usr/bin/env bash
# Run a long command detached, keeping its PID: `tools/bg.sh <name> <command...>` writes
# /tmp/bg-<name>.log and /tmp/bg-<name>.pid. `tools/bg-wait.sh <name>` waits on that PID and
# nothing else -- never on a process-name pattern, which a watcher's own shell can match.
set -u
name=${1:?name}; shift
nohup "$@" > "/tmp/bg-$name.log" 2>&1 < /dev/null &
echo $! > "/tmp/bg-$name.pid"
echo "bg $name: pid $! log /tmp/bg-$name.log"
