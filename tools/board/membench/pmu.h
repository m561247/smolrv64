// pmu.h: the core's own counters around a timed loop, in user mode when the kernel allows it (else
// every mode, which the caller reports): cycles, instructions, LOAD, DCMISS, DTLB_MISS, DT_WALK and
// MEM_LQOCC. pmu_stop returns 1 when a counter was multiplexed (the count is then scaled, not exact).
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
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

