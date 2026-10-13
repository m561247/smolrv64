#!/bin/sh
# Quiet the test board (NFS root): disable, mask and stop every service, socket and timer a
# headless benchmark machine does not need, so a measurement starts on an idle system and
# nothing wakes up during it. Kept: ssh, systemd-networkd/resolved/timesyncd, journald,
# remote-fs, getty. The masks persist on the NFS root, so this is a no-op after the first
# boot (the sentinel is cron.service's mask). Every systemctl call here uses --no-reload: a
# daemon-reload re-reads every unit file over NFS and takes ~30 s at 111 MHz with PID 1 at
# 100%, and a series of them blocked ssh logins for an hour. Run as root on the board.
set -u
if [ -L /etc/systemd/system/cron.service ]; then echo "already quiet (masks in place)"; exit 0; fi
TIMERS="anacron apport-autoreport apt-daily-upgrade apt-daily dpkg-db-backup e2scrub_all fstrim \
        fwupd-refresh logrotate man-db motd-news snapd.snap-repair ua-timer \
        update-notifier-download update-notifier-motd"
SERVICES="ModemManager anacron apport avahi-daemon blueman-mechanism bluetooth cron cups-browsed cups \
          e2scrub_reap grub-common grub-initrd-fallback nethack-common networkd-dispatcher pollinate \
          postfix rsyslog snapd.apparmor snapd.autoimport snapd.core-fixup snapd.recovery-chooser-trigger \
          snapd.seeded snapd sysstat ua-reboot-cmds ubuntu-advantage ufw unattended-upgrades whoopsie \
          wpa_supplicant cloud-init-local cloud-init cloud-config cloud-final fwupd udisks2 packagekit"
OTHER="cups.path cups.socket lxd-installer.socket snapd.socket whoopsie.path avahi-daemon.socket"
units=""
for t in $TIMERS;   do units="$units $t.timer"; done
for u in $OTHER;    do units="$units $u"; done
for s in $SERVICES; do units="$units $s.service"; done
systemctl --no-reload disable $units 2>/dev/null
systemctl --no-reload mask $units 2>/dev/null
systemctl stop --no-block $units 2>/dev/null
systemctl daemon-reload
echo "timers left: $(systemctl list-timers --all --no-legend 2>/dev/null | grep -v -c '^$')"
echo "running services: $(systemctl list-units --type=service --state=running --no-legend | wc -l)"
systemctl list-units --type=service --state=running --no-legend | awk '{print $1}' | tr '\n' ' '; echo
