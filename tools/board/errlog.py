#!/usr/bin/env python3
"""The SoC's integrity log over /dev/mem (rv_soc_top's rv_errlog window at 0x1000_E000):
+0 magic 'ERRL' (low 32 bits), +8 the sticky vector (one bit per invariant, see rv_soc_top.v's
BIT ASSIGNMENT: [15:0] D$, [31:16] I$, [47:32] LSU, [63:48] frontend), +0x10 {first_idx[7:0],
first_cyc[47:0]} of the first one that fired. Prints one line; `--watch N` repeats every N s
and prints only when the vector changes (to stdout and /dev/kmsg, so the UART log keeps it)."""
import mmap, os, struct, sys, time
BASE = 0x1000E000
def read():
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, 4096, offset=BASE)
    # one 8-byte slice per register: a wider copy is done bytewise and a byte read of this window
    # returns the word's low byte for every address
    magic, sticky, first = (struct.unpack('<Q', m[o:o + 8])[0] for o in (0, 8, 16))
    m.close(); os.close(fd)
    return magic, sticky, first
def fmt(sticky, first):
    bits = [i for i in range(64) if sticky >> i & 1]
    unit = lambda i: ('D$', 'I$', 'LSU', 'FE')[i >> 4] + f'[{i & 15}]'
    s = f"errlog sticky={sticky:#018x} bits={[unit(i) for i in bits]}"
    if sticky: s += f" first={unit((first >> 48) & 0xff)} at cycle {first & ((1 << 48) - 1)}"
    return s
magic, sticky, first = read()
if magic & 0xffffffff != 0x4552524c: sys.exit(f"no ERRL magic at {BASE:#x}: {magic:#x}")
print(fmt(sticky, first)); sys.stdout.flush()
if len(sys.argv) > 2 and sys.argv[1] == '--watch':
    last = sticky
    while True:
        time.sleep(float(sys.argv[2]))
        _, sticky, first = read()
        if sticky != last:
            line = fmt(sticky, first); print(line); sys.stdout.flush()
            try: open('/dev/kmsg', 'w').write('ERRLOG ' + line + '\n')
            except OSError: pass
            last = sticky
