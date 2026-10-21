// bw.c: sequential bandwidth over <kib> KiB -- 8-byte loads into eight independent sums (r), or
// 8-byte stores (w), front to back, <passes> times after one untimed pass that faults the pages in
// and leaves a buffer that fits the cache resident. The core's PMU counts the timed passes alone, in
// user mode, so the figure is bytes a core cycle whatever else the machine does; MB/s is that at
// <mhz> (the core clock, 166.67 by default).
// usage: bw <r|w> <kib> <passes> [mhz]
#define _GNU_SOURCE
#include "pmu.h"

static uint64_t rd(const uint64_t *p, size_t n) {
   uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
   for (size_t i = 0; i < n; i += 8) {
      s0 += p[i];     s1 += p[i + 1]; s2 += p[i + 2]; s3 += p[i + 3];
      s4 += p[i + 4]; s5 += p[i + 5]; s6 += p[i + 6]; s7 += p[i + 7];
   }
   return s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7;
}

static void wr(uint64_t *p, size_t n, uint64_t v) {
   for (size_t i = 0; i < n; i += 8) {
      p[i] = v;     p[i + 1] = v; p[i + 2] = v; p[i + 3] = v;
      p[i + 4] = v; p[i + 5] = v; p[i + 6] = v; p[i + 7] = v;
   }
}

int main(int argc, char **argv) {
   if (argc < 4 || (argv[1][0] != 'r' && argv[1][0] != 'w')) {
      fprintf(stderr, "usage: bw <r|w> <kib> <passes> [mhz]\n"); return 2;
   }
   int w = argv[1][0] == 'w';
   size_t kib = strtoul(argv[2], 0, 0), n = kib * 1024 / 8;
   long passes = strtol(argv[3], 0, 0);
   double mhz = argc > 4 ? strtod(argv[4], 0) : 166.67;
   uint64_t *buf = aligned_alloc(4096, kib * 1024);
   if (!buf || n < 8 || passes < 1) { fprintf(stderr, "bw: no memory for %zu KiB\n", kib); return 1; }
   for (size_t i = 0; i < n; i++) buf[i] = i;                 // the untimed pass
   volatile uint64_t sink = 0;
   uint64_t v[NEV];
   pmu_open();
   pmu_start();
   for (long r = 0; r < passes; r++) {
      if (w) wr(buf, n, (uint64_t)r);
      else   sink += rd(buf, n);
   }
   int mux = pmu_stop(v);
   double bytes = (double)kib * 1024 * passes, accesses = bytes / 8;
   printf("%6zu KiB %-5s %6.3f bytes/cycle %8.1f MB/s at %.2f MHz | per access: %5.3f DCMISS %5.3f DTLB_MISS"
          " %.3f insns | %ld passes%s%s (%llu)\n",
          kib, w ? "write" : "read", bytes / v[0], bytes / v[0] * mhz, mhz, v[3] / accesses, v[4] / accesses,
          v[1] / accesses, passes, user_only ? "" : " ALL MODES", mux ? " MULTIPLEXED" : "",
          (unsigned long long)sink);
   return 0;
}
