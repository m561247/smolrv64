#!/usr/bin/env python3
"""Make an architectural checkpoint by hand from raw images: the state at a boot's first instruction.

  tools/ckpt-make.py <dir>.ckpt --load <file>@<hex addr> [...] --pc <hex> [--reg x11=<hex> ...]

Writes <dir>/state.txt (pc, priv = M, the given registers) and <dir>/mem.zst (the images' non-zero
4 KiB pages as {u64 address, 4096 bytes} records, zstd). This is the checkpoint format's reference
producer and the restore path's first test: the reset state of a normal boot, restored, must boot
the same way (docs/PLAN-2026-09-25-arch-checkpoints.md, step 1).
"""
import argparse, os, struct, subprocess

ap = argparse.ArgumentParser()
ap.add_argument('dir')
ap.add_argument('--load', action='append', default=[], help='file@hexaddr')
ap.add_argument('--pc', required=True)
ap.add_argument('--reg', action='append', default=[], help='xN=hex')
a = ap.parse_args()
os.makedirs(a.dir, exist_ok=True)
pages = {}
for spec in a.load:
    path, addr = spec.rsplit('@', 1)
    addr = int(addr, 16)
    data = open(path, 'rb').read()
    pos = 0
    while pos < len(data):
        pa = (addr + pos) & ~0xfff
        lo = (addr + pos) - pa
        n = min(4096 - lo, len(data) - pos)
        pg = pages.setdefault(pa, bytearray(4096))
        pg[lo:lo + n] = data[pos:pos + n]
        pos += n
raw = os.path.join(a.dir, 'mem.raw')
with open(raw, 'wb') as f:
    for pa in sorted(pages):
        if any(pages[pa]):
            f.write(struct.pack('<Q', pa)); f.write(pages[pa])
subprocess.check_call(['zstd', '-q', '-f', '--rm', raw, '-o', os.path.join(a.dir, 'mem.zst')])
with open(os.path.join(a.dir, 'state.txt'), 'w') as f:
    f.write(f'# made by tools/ckpt-make.py from {" ".join(a.load)}\n')
    f.write(f'pc {int(a.pc, 16):x}\npriv 3\n')
    for r in a.reg:
        k, v = r.split('=')
        f.write(f'{k} {int(v, 16):x}\n')
print(f'ckpt-make: {a.dir}: {len(pages)} pages')
