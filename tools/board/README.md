# Board-side scripts

These run on a board from its `/var/tmp`, which is on its NFS root (coffee's
`/srv/ubuntu-root-2g/var/tmp` and `/srv/ubuntu-root-4g/var/tmp`): copy them to both. `gb5-run.sh <rtl>` is the measured Geekbench 5 run
(`IV=<ms>` adds per-interval counts), `gb5-probe.sh <tag>` the hang probe that runs beside
`perflog.sh`, `quiet-board.sh` masks what a benchmark machine does not need, and `errlog.py`
reads the SoC's integrity log. Both runners wait for an idle machine (`idle-wait.sh`).
`gb6-trace.sh <rtl>` is GB6's single-core pass with the counters sampled every 10 s beside the stamped console, and `gb6-split.py` (on coffee) cuts the samples into per-subtest Top-Down rows. `membench/` is the memory set (`make` there, then `./run.sh <tag>`): `chase2`, a pointer chase that
reads the core's own counters around its timed loop, with clamchowder's MemoryLatency and
MemoryBandwidth and dsheffie's mem-lat, all built on the board with the full `-march`.
