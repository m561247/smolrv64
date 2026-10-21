// bwread.c: tools/board/membench/bw.c's read kernel over 32 KiB, bare metal, so the lockstep bench's
// counters can say where a D$-resident stream of 8-byte loads spends its cycles
#include <stdint.h>
#define N (32 * 1024 / 8)
static uint64_t buf[N] __attribute__((aligned(64)));

static uint64_t rd(const uint64_t *p, long n) {
   uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0, s5 = 0, s6 = 0, s7 = 0;
   for (long i = 0; i < n; i += 8) {
      s0 += p[i];     s1 += p[i + 1]; s2 += p[i + 2]; s3 += p[i + 3];
      s4 += p[i + 4]; s5 += p[i + 5]; s6 += p[i + 6]; s7 += p[i + 7];
   }
   return s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7;
}

int main(void) {
   for (long i = 0; i < N; i++) buf[i] = (uint64_t)i;
   uint64_t s = 0;
   for (int r = 0; r < 64; r++) s += rd(buf, N);
   return s == 0;
}
