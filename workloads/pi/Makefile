# pi under Simmerv and the cosim: the Ubuntu root's `pi` (CLN over GMP, the board's binary and
# libraries) overlaid on the tiny128 initramfs, with an init hook that computes 100,000 digits.
# Its inner loops are GMP's mpn_addmul_1, mpn_submul_1, mpn_add_n and mpn_sub_n, so a checkpoint
# taken inside the run (simmerv-cli --ckpt-at) is a slice of those kernels for the RTL
# (CKPT=<dir> core/run-linux.sh +measure_from=...; +kanata=... for the pipe trace).
#
#   make            # tiny128-pi.cpio + ../tiny128/tiny128-cosim-pi.dtb
R    ?= /srv/ubuntu-root-4g
LIBD  = usr/lib/riscv64-linux-gnu
LIBS  = libc.so.6 ld-linux-riscv64-lp64d.so.1 libm.so.6 libgcc_s.so.1 libstdc++.so.6 libgmp.so.10 libcln.so.6
START = 0x9f000000

all: tiny128-pi.cpio ../tiny128/tiny128-cosim-pi.dtb

tiny128-pi.cpio: S98pi Makefile $(R)/usr/bin/pi $(addprefix $(R)/$(LIBD)/,$(LIBS))
	rm -rf ov && mkdir -p ov/usr/bin ov/$(LIBD) ov/lib ov/etc/init.d
	cp $(R)/usr/bin/pi ov/usr/bin/
	for l in $(LIBS); do cp -L $(R)/$(LIBD)/$$l ov/$(LIBD)/; done
	# the ELF interpreter path and glibc's default library directory, both under /lib
	ln -s ../$(LIBD)/ld-linux-riscv64-lp64d.so.1 ov/lib/ld-linux-riscv64-lp64d.so.1
	ln -s ../$(LIBD) ov/lib/riscv64-linux-gnu
	cp S98pi ov/etc/init.d/S98pi
	chmod +x ov/usr/bin/* ov/etc/init.d/S98pi
	cd ov && find . | cpio -o -H newc > ../overlay.cpio 2>/dev/null
	# the compressed first archive padded to 4 before the overlay (see ../glibc/Makefile)
	cat ../tiny128/tiny128.cpio > $@; truncate -s $$(( ($$(wc -c < $@) + 3) / 4 * 4 )) $@; cat overlay.cpio >> $@

# tiny128's cosim device tree with the initrd window moved to START and its end stamped from the
# archive's exact size
../tiny128/tiny128-cosim-pi.dtb: tiny128-pi.cpio ../tiny128/tiny128-cosim.dts
	@sz=$$(wc -c < tiny128-pi.cpio); end=$$(printf '0x%x' $$(($(START) + sz))); \
	 [ $$(($(START) + sz)) -le $$((0x9ff00000)) ] || { echo "the archive runs into the DTB at 0x9ff00000"; exit 1; }; \
	 sed -e "s|linux,initrd-start = <0 0x[0-9a-f]*>;|linux,initrd-start = <0 $(START)>;|" \
	     -e "s|linux,initrd-end   = <0 0x[0-9a-f]*>;.*|linux,initrd-end   = <0 $$end>; /* exact: tiny128-pi.cpio ($$sz B, auto-stamped) */|" \
	     ../tiny128/tiny128-cosim.dts > ../tiny128/tiny128-cosim-pi.dts; \
	 dtc -I dts -O dtb -o $@ ../tiny128/tiny128-cosim-pi.dts 2>/dev/null; \
	 echo "initrd: $(START) .. $$end ($$sz B)"

clean:
	rm -rf ov overlay.cpio tiny128-pi.cpio ../tiny128/tiny128-cosim-pi.dts ../tiny128/tiny128-cosim-pi.dtb
