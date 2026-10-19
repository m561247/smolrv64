#!/usr/bin/env bash
# systemd --version through ld.so under lockstep (see Makefile). The Ubuntu kernel reaches /init at
# ~1.05 G cycles; the loader's work on 16 MB of libraries follows.  CYC=0 for unbounded.
# The run ends a million cycles after the test's PASS line (STOP_AFTER= to run the full CYC).
set -u
cd "$(dirname "$0")"
make -s || exit 1
INITRD=$(pwd)/tiny128-sysd.cpio OFF_INITRD=1e000000 DTB=$(pwd)/../tiny128/tiny128-cosim-sysd.dtb \
STOP_AFTER=${STOP_AFTER-"SYSD-TEST PASS"} CYC=${CYC:-1600000000} ../../core/run-cosim-linux.sh
