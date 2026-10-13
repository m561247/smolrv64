// ckpt_dpi -- load an architectural checkpoint's memory into the testbench's DDR array.
//
// <dir>/mem.zst is a zstd stream of records {u64 physical address (little-endian), 4096 bytes},
// one per non-zero 4 KiB page (docs/PLAN-2026-09-25-arch-checkpoints.md). Each non-zero 64-byte
// line is handed to the testbench's exported ckpt_line(line index from DDR base, data), so only
// touched memory is written and the rest of the array keeps its zero initial value.
#include <zstd.h>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "svdpi.h"

extern "C" void ckpt_line(long long idx, const svBitVecVal* data);

extern "C" long long ckpt_load(const char* dir, long long base, long long nlines) {
   std::string path = std::string(dir) + "/mem.zst";
   FILE* f = fopen(path.c_str(), "rb");
   if (!f) { fprintf(stderr, "ckpt: cannot open %s\n", path.c_str()); return -1; }
   ZSTD_DStream* ds = ZSTD_createDStream();
   ZSTD_initDStream(ds);
   std::vector<uint8_t> in(ZSTD_DStreamInSize()), out(ZSTD_DStreamOutSize()), rec;
   const size_t RECB = 8 + 4096;
   long long pages = 0, lines = 0;
   size_t n;
   while ((n = fread(in.data(), 1, in.size(), f)) > 0) {
      ZSTD_inBuffer ib = {in.data(), n, 0};
      while (ib.pos < ib.size) {
         ZSTD_outBuffer ob = {out.data(), out.size(), 0};
         size_t r = ZSTD_decompressStream(ds, &ob, &ib);
         if (ZSTD_isError(r)) {
            fprintf(stderr, "ckpt: %s: %s\n", path.c_str(), ZSTD_getErrorName(r));
            fclose(f); ZSTD_freeDStream(ds); return -1;
         }
         rec.insert(rec.end(), out.data(), out.data() + ob.pos);
         size_t done = 0;
         for (; rec.size() - done >= RECB; done += RECB) {
            uint64_t pa = 0;
            for (int k = 0; k < 8; k++) pa |= uint64_t(rec[done + k]) << (8 * k);
            const uint8_t* pg = &rec[done + 8];
            if (pa & 0xfff) { fprintf(stderr, "ckpt: page address %llx not page aligned\n", (unsigned long long)pa); return -1; }
            if (pa < uint64_t(base) || ((pa - base) >> 6) + 64 > uint64_t(nlines)) {
               fprintf(stderr, "ckpt: page %llx outside the DDR array\n", (unsigned long long)pa); return -1;
            }
            for (int l = 0; l < 64; l++) {
               const uint8_t* ln = pg + 64 * l;
               bool nz = false;
               for (int k = 0; k < 64; k++) if (ln[k]) { nz = true; break; }
               if (!nz) continue;
               svBitVecVal w[16];
               for (int k = 0; k < 16; k++)
                  w[k] = uint32_t(ln[4*k]) | uint32_t(ln[4*k+1]) << 8 | uint32_t(ln[4*k+2]) << 16 | uint32_t(ln[4*k+3]) << 24;
               ckpt_line((long long)(((pa - base) >> 6) + l), w);
               lines++;
            }
            pages++;
         }
         rec.erase(rec.begin(), rec.begin() + done);
      }
   }
   fclose(f);
   ZSTD_freeDStream(ds);
   if (!rec.empty()) { fprintf(stderr, "ckpt: %s ends inside a record (%zu bytes left)\n", path.c_str(), rec.size()); return -1; }
   fprintf(stderr, "[ckpt: %s: %lld pages, %lld non-zero lines]\n", path.c_str(), pages, lines);
   return pages;
}
