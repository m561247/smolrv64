// chase2.c: dependent pointer chases over <kib> KiB -- one pointer per 64-byte line, every line in
// one random cycle -- by <k> chains walking that cycle n/k lines apart, so each step of a chain is
// one load whose address is the chain's previous load. The core's PMU counts the timed loop alone,
// in user mode: cycles, instructions, LOAD, DCMISS, DTLB_MISS, DT_WALK and MEM_LQOCC.
// usage: chase2 <kib> <k: 1-6, 8, 10, 12, 16> <steps per chain>
#define _GNU_SOURCE
#include <stdlib.h>
#include <time.h>

#include "pmu.h"

static inline __attribute__((always_inline)) void walk(char **p[], int k, long steps) {
   char **q[16];
   for (int j = 0; j < k; j++) q[j] = p[j];
   for (long s = 0; s < steps; s++) {
#pragma GCC unroll 16
      for (int j = 0; j < k; j++) q[j] = (char **)*q[j];   // unrolled: every chain in a register
   }
   for (int j = 0; j < k; j++) p[j] = q[j];
}

int main(int argc, char **argv) {
   if (argc < 4) { fprintf(stderr, "usage: chase2 <kib> <k: 1-6, 8, 10, 12, 16> <steps per chain>\n"); return 2; }
   size_t kib = strtoul(argv[1], 0, 0), n = kib * 1024 / 64;
   int k = atoi(argv[2]);
   long steps = strtol(argv[3], 0, 0);
   char *buf = aligned_alloc(4096, kib * 1024);
   size_t *perm = malloc(n * sizeof *perm);
   if (!buf || !perm || n < 16) { fprintf(stderr, "chase2: no memory for %zu KiB\n", kib); return 1; }
   for (size_t i = 0; i < n; i++) perm[i] = i;
   srand(1);
   for (size_t i = n - 1; i > 0; i--) { size_t j = (size_t)rand() % (i + 1), t = perm[i]; perm[i] = perm[j]; perm[j] = t; }
   for (size_t i = 0; i < n; i++) *(char **)(buf + perm[i] * 64) = buf + perm[(i + 1) % n] * 64;
   char **p[16];
   for (int j = 0; j < k && j < 16; j++) p[j] = (char **)(buf + perm[(size_t)j * n / k] * 64);
   free(perm);
   char **w = p[0];
   for (size_t i = 0; i < n; i++) w = (char **)*w;   // warm: one lap, back at p[0]
   p[0] = w;

   uint64_t v[NEV];
   struct timespec t0, t1;
   pmu_open();
   clock_gettime(CLOCK_MONOTONIC, &t0);
   pmu_start();
   switch (k) {
   case 1: walk(p, 1, steps); break;
   case 2: walk(p, 2, steps); break;
   case 3: walk(p, 3, steps); break;
   case 4: walk(p, 4, steps); break;
   case 5: walk(p, 5, steps); break;
   case 6: walk(p, 6, steps); break;
   case 8: walk(p, 8, steps); break;
   case 10: walk(p, 10, steps); break;
   case 12: walk(p, 12, steps); break;
   case 16: walk(p, 16, steps); break;
   default: fprintf(stderr, "chase2: k=%d is not built\n", k); return 2;
   }
   int mux = pmu_stop(v);
   clock_gettime(CLOCK_MONOTONIC, &t1);

   double ns = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / steps;
   double loads = (double)k * steps;
   printf("%6zu KiB k=%-2d %7.2f cycles/step %7.2f ns/step | per load: %5.3f LOAD %5.3f DCMISS"
          " %5.3f DTLB_MISS %6.2f DT_WALK cycles | load queue holds %5.2f | %.3f insns/load | %ld steps%s%s (%p)\n",
          kib, k, (double)v[0] / steps, ns, v[2] / loads, v[3] / loads, v[4] / loads, v[5] / loads,
          (double)v[6] / v[0], v[1] / loads, steps, user_only ? "" : " ALL MODES", mux ? " MULTIPLEXED" : "",
          (void *)p[0]);
   return 0;
}
