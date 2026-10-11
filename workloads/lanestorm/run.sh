#!/bin/bash
# lanestorm on the core bench: build the image, run tb_core (core/run-vl.sh builds it),
# print the verdict. A landing lost to a full buffer trips the always-on overflow assertion
# in smolrv64_core (a %Error line), or wedges the core (RISCV-TEST TIMEOUT).
#   ./run.sh [+plusargs...]      CYC=<cycles> (default 20 M)
set -u
cd "$(dirname "$0")"
make -s lanestorm.hex || exit 1
BIN=../../core/obj_dir_core/tb_core
[ -x "$BIN" ] || { echo "no $BIN: build it with core/run-vl.sh"; exit 1; }
"$BIN" +hex="$PWD/lanestorm.hex" +tohost=80010000 +cycles=${CYC:-20000000} "$@" 2>&1 \
   | grep -E 'RISCV-TEST|%Error|Error|fatal' | head -5
