// chase2.c: dependent pointer chases over <kib> KiB -- one pointer per 64-byte line, every line in
// one random cycle -- by <k> chains walking that cycle n/k lines apart, so each step of a chain is
// one load whose address is the chain's previous load. The core's PMU counts the timed loop alone,
// in user mode: cycles, instructions, LOAD, DCMISS, DTLB_MISS, DT_WALK and MEM_LQOCC.
// usage: chase2 <kib> <k: 1-6, 8, 10, 12, 16> <steps per chain>
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <linux/perf_event.h>

static const struct { const char *name; uint32_t type; uint64_t config; } ev[] = {
   { "cycles",       PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES },
   { "instructions", PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS },
   { "LOAD",         PERF_TYPE_RAW,      0x0003 },
   { "DCMISS",       PERF_TYPE_RAW,      0x0102 },
   { "DTLB_MISS",    PERF_TYPE_RAW,      0x0104 },
   { "DT_WALK",      PERF_TYPE_RAW,      0x0318 },
   { "MEM_LQOCC",    PERF_TYPE_RAW,      0x0321 },
};
enum { NEV = sizeof ev / sizeof ev[0] };
static int fd[NEV], user_only = 1;

static int pmu_open1(int i, int excl) {
   struct perf_event_attr a;
   memset(&a, 0, sizeof a);
   a.size = sizeof a;
   a.type = ev[i].type;
   a.config = ev[i].config;
   a.disabled = 1;
   a.exclude_kernel = excl;
   a.exclude_hv = excl;
   a.read_format = PERF_FORMAT_TOTAL_TIME_ENABLED | PERF_FORMAT_TOTAL_TIME_RUNNING;
   return syscall(SYS_perf_event_open, &a, 0, -1, -1, 0);
}

static void pmu_open(void) {
   for (int i = 0; i < NEV; i++) {
      fd[i] = pmu_open1(i, user_only);
      if (fd[i] < 0 && user_only) {          // no mode filtering: count every mode instead
         user_only = 0;
         for (int j = 0; j < i; j++) close(fd[j]);
         i = -1;
         continue;
      }
      if (fd[i] < 0) { perror(ev[i].name); exit(1); }
   }
}

static void pmu_start(void) {
   for (int i = 0; i < NEV; i++) ioctl(fd[i], PERF_EVENT_IOC_RESET, 0);
   for (int i = 0; i < NEV; i++) ioctl(fd[i], PERF_EVENT_IOC_ENABLE, 0);
}

static int pmu_stop(uint64_t *v) {          // returns 1 when a counter was multiplexed
   int mux = 0;
   for (int i = 0; i < NEV; i++) ioctl(fd[i], PERF_EVENT_IOC_DISABLE, 0);
   for (int i = 0; i < NEV; i++) {
      uint64_t r[3] = { 0, 0, 0 };
      if (read(fd[i], r, sizeof r) != sizeof r) { perror("read"); exit(1); }
      v[i] = r[0];
      if (r[2] < r[1]) mux = 1;
   }
   return mux;
}

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
