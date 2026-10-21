// chase.c: tools/board/membench/chase2.c's dependent chase, one chain over 16 KiB (a D$ hit every load),
// bare metal, so the lockstep bench counts a load whose value is the next load's address
#include <stdint.h>
#define N (16 * 1024 / 64)
static char buf[N * 64] __attribute__((aligned(64)));
static unsigned perm[N];

int main(void) {
   uint32_t x = 1;
   for (unsigned i = 0; i < N; i++) perm[i] = i;
   for (unsigned i = N - 1; i > 0; i--) {                  // xorshift, a random cycle of the lines
      x ^= x << 13; x ^= x >> 17; x ^= x << 5;
      unsigned j = x % (i + 1), t = perm[i]; perm[i] = perm[j]; perm[j] = t;
   }
   for (unsigned i = 0; i < N; i++) *(char **)(buf + perm[i] * 64) = buf + perm[(i + 1) % N] * 64;
   char **p = (char **)(buf + perm[0] * 64);
   for (unsigned i = 0; i < N; i++) p = (char **)*p;       // warm
   unsigned long c0, c1;
   asm volatile("csrr %0, mcycle" : "=r"(c0));
   for (int s = 0; s < 100000; s++) p = (char **)*p;
   asm volatile("csrr %0, mcycle" : "=r"(c1));
   printf("chase: %lu cycles for 100000 dependent loads (%lu.%02lu a load) %p\\n", c1 - c0,
          (c1 - c0) / 100000, ((c1 - c0) % 100000) / 1000, (void *)p);
   return 0;
}
