# The memory set, built on the board (gcc 14) with every extension SmolRV64 implements:
#   make             fetch clamchowder's Microbenchmarks and dsheffie's mem-lat at the commits
#                    below, build them and chase2
#   ./run.sh <tag>   measure on an idle board: /var/tmp/ubench/mb-<tag>.txt
# Neither suite's RISC-V code may use V: MemoryLatency's draft-0.7 vector routine (stlftest128)
# becomes two 8-byte stores here, and MemoryBandwidth links mb_rv64.s instead of its own kernels.
MARCH = rv64imafdc_zicbom_zicbop_zicboz_zicntr_zicond_zicsr_zifencei_zihpm_zca_zcd_zba_zbb_zbs_svpbmt
CB    = 13159d44086d8b042e1c56218cfbfa24ae940899
ML    = 28573fa55374f794279dacceaa3da4c56704b86d

all: chase2 MemoryLatency MemoryBandwidth mem-lat/mem_micro

chase2: chase2.c
	gcc -O2 -march=$(MARCH) -Wall $< -o $@

Microbenchmarks:
	git clone -q https://github.com/clamchowder/Microbenchmarks $@ && git -C $@ checkout -q $(CB)

mem-lat:
	git clone -q https://github.com/dsheffie/mem-lat $@ && git -C $@ checkout -q $(ML)

ml_rv64.s: | Microbenchmarks
	sed -e 's|^ *vsetvli .*$$||' -e 's|^\( *\)vsw\.v v0, (t0)|\1sd x0, (t0)\n\1sd x0, 8(t0)|' \
	    Microbenchmarks/MemoryLatency/MemoryLatency_riscv.s > $@
	! grep -E 'vsetvli|\bv[a-z]+\.[vx]\b' $@

MemoryLatency: ml_rv64.s
	gcc -O3 -march=$(MARCH) Microbenchmarks/MemoryLatency/MemoryLatency.c $< -o $@ -lm

MemoryBandwidth: mb_rv64.s | Microbenchmarks
	gcc -O3 -march=$(MARCH) -Wno-error=incompatible-pointer-types \
	    Microbenchmarks/MemoryBandwidth/MemoryBandwidth.c $< -o $@ -lm -lpthread

mem-lat/mem_micro: | mem-lat
	$(MAKE) -C mem-lat CXX=g++ OPT="-O2 -march=$(MARCH)"

clean:
	rm -rf chase2 MemoryLatency MemoryBandwidth ml_rv64.s Microbenchmarks mem-lat

.PHONY: all clean
