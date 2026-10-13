# Board-side scripts

These run on a board from its `/var/tmp`, which is on its NFS root (coffee's
`/srv/ubuntu-root-2g/var/tmp` and `/srv/ubuntu-root-4g/var/tmp`): copy them to both. `gb5-run.sh <rtl>` is the measured Geekbench 5 run
(`IV=<ms>` adds per-interval counts), `gb5-probe.sh <tag>` the hang probe that runs beside
`perflog.sh`, `quiet-board.sh` masks what a benchmark machine does not need, and `errlog.py`
reads the SoC's integrity log. Both runners wait for an idle machine (`idle-wait.sh`).
