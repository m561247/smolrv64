#!/usr/bin/env python3
"""Generate the restore stub for an architectural checkpoint (docs/PLAN-2026-09-25-arch-checkpoints.md).

  tools/ckpt-stub.py <dir>.ckpt        # reads <dir>/state.txt, writes <dir>/stub.S, stub.bin, stub.hex

The stub runs in M-mode from the boot SRAM (0x7000_0000) at reset and restores, in order: the
devices over MMIO (CLINT, PLIC, UART), the CSRs, the FP state, mstatus with MIE = 0, MPP = the
checkpoint's privilege and MPIE = its MIE, mepc = pc, then mtime, mcycle and minstret, then x1..x31
from a table with x31 as the base (its own load last), and mret. The mret leaves mepc, MPP and MPIE
different from the checkpoint's; below M-mode those are dead, because every way into M-mode is a
trap that writes them first, and Simmerv takes checkpoints only below M-mode.

state.txt: one `key value` per line, value hex; a key that is absent keeps its reset value.
The checkpoint must be quiescent: no PLIC interrupt pending or claimed, the UART's transmitter
empty, no LR/SC open, and mstatus.MPRV = 0 (the stub's table loads follow the mstatus write).
"""
import os, subprocess, sys

RV = 'riscv64-elf-' if os.uname().sysname == 'Darwin' else 'riscv64-linux-gnu-'   # as workloads/*/Makefile
CLINT, PLIC, UART = 0x0200_0000, 0x0C00_0000, 0x1000_0000
# CSRs restored by csrw, in this order (satp first: it redirects, and later CSRs do not care)
CSRS = [('satp', 0x180), ('stvec', 0x105), ('sepc', 0x141), ('scause', 0x142), ('stval', 0x143),
        ('sscratch', 0x140), ('mtvec', 0x305), ('mcause', 0x342), ('mtval', 0x343),
        ('mscratch', 0x340), ('medeleg', 0x302), ('mideleg', 0x303), ('mie', 0x304),
        ('mip', 0x344), ('mcounteren', 0x306), ('scounteren', 0x106), ('menvcfg', 0x30A),
        ('senvcfg', 0x10A), ('mstateen0', 0x30C), ('stimecmp', 0x14D), ('mnstatus', 0x744),
        ('mcountinhibit', 0x320)] + \
       [(f'mhpmevent{i}', 0x320 + i) for i in range(3, 16)] + \
       [(f'mhpmcounter{i}', 0xB00 + i) for i in range(3, 16)]
MSTATUS, MEPC, FCSR, MCYCLE, MINSTRET = 0x300, 0x341, 0x003, 0xB00, 0xB02
MIE_BIT, MPIE_BIT, MPP_SHIFT, MPRV_BIT, FS_SHIFT = 1 << 3, 1 << 7, 11, 1 << 17, 13

def read_state(path):
    st = {}
    for line in open(path):
        line = line.split('#')[0].strip()
        if line:
            k, v = line.split()
            st[k] = int(v, 16)
    return st

def main():
    d = sys.argv[1]
    st = read_state(os.path.join(d, 'state.txt'))
    for k in ('pc', 'priv'):
        if k not in st: sys.exit(f'ckpt-stub: state.txt has no {k}')
    if st.get('mstatus', 0) & MPRV_BIT:
        sys.exit('ckpt-stub: mstatus.MPRV is set; the checkpoint is not quiescent')
    tbl, code = [], []
    def slot(v):                                   # a table entry; returns its byte offset
        tbl.append(v & (2**64 - 1)); return 8 * (len(tbl) - 1)
    def li(reg, v): code.append(f'  ld {reg}, {slot(v)}(x31)')
    def mmio(addr, v, op):
        li('x29', addr); li('x30', v); code.append(f'  {op} x30, 0(x29)')
    code.append('  lla x31, tbl')
    # 1. devices
    if 'clint.mtimecmp' in st: mmio(CLINT + 0x4000, st['clint.mtimecmp'], 'sd')
    if 'clint.msip' in st:     mmio(CLINT + 0x0000, st['clint.msip'], 'sw')
    for k, v in sorted(st.items()):
        if k.startswith('plic.prio.'):
            mmio(PLIC + 4 * int(k.split('.')[2]), v, 'sw')
    if 'plic.enable' in st:    mmio(PLIC + 0x2080, st['plic.enable'], 'sd')
    if 'plic.threshold' in st: mmio(PLIC + 0x201000, st['plic.threshold'], 'sw')
    for name, off in (('uart.lcr', 3), ('uart.fcr', 2), ('uart.mcr', 4), ('uart.scr', 7), ('uart.ier', 1)):
        if name in st: mmio(UART + off, st[name], 'sb')
    # 2. CSRs
    for name, num in CSRS:
        if name in st:
            li('x30', st[name]); code.append(f'  csrw {num:#x}, x30')
    # 3. FP: FS non-Off to allow the writes, then fcsr and f0..f31
    fregs = [st[f'f{i}'] for i in range(32) if f'f{i}' in st]
    if 'fcsr' in st or fregs:
        code.append(f'  li x30, {1 << FS_SHIFT:#x}'); code.append('  csrs 0x300, x30')
        if 'fcsr' in st: li('x30', st['fcsr']); code.append(f'  csrw {FCSR:#x}, x30')
        for i in range(32):
            if f'f{i}' in st: code.append(f'  fld f{i}, {slot(st[f"f{i}"])}(x31)')
    # 4. mstatus with MIE = 0, MPP = priv and MPIE = MIE, which the mret turns into priv and MIE
    ms = st.get('mstatus', 0)
    ms = ms & ~(MIE_BIT | MPIE_BIT | 3 << MPP_SHIFT) | st['priv'] << MPP_SHIFT | (MPIE_BIT if ms & MIE_BIT else 0)
    li('x30', ms); code.append(f'  csrw {MSTATUS:#x}, x30')
    # 5. mepc = pc
    li('x30', st['pc']); code.append(f'  csrw {MEPC:#x}, x30')
    # time and the counters, as late as possible
    if 'clint.mtime' in st: mmio(CLINT + 0xBFF8, st['clint.mtime'], 'sd')
    if 'mcycle' in st: li('x30', st['mcycle']); code.append(f'  csrw {MCYCLE:#x}, x30')
    tail = 31 + 1                                  # after the minstret write: 31 loads, the mret
    if 'minstret' in st:
        li('x30', st['minstret'] - tail); code.append(f'  csrw {MINSTRET:#x}, x30')
    # 6. x1..x31, x31 (the base) last; 7. mret
    for i in range(1, 32):
        code.append(f'  ld x{i}, {slot(st.get(f"x{i}", 0))}(x31)')
    code.append('  mret')
    src = ['  .section .text', '  .globl _start', '_start:'] + code + \
          ['  .balign 8', 'tbl:'] + [f'  .dword {v:#018x}' for v in tbl]
    S = os.path.join(d, 'stub.S'); elf = os.path.join(d, 'stub.elf'); b = os.path.join(d, 'stub.bin')
    open(S, 'w').write('\n'.join(src) + '\n')
    subprocess.check_call([RV + 'gcc', '-nostdlib', '-march=rv64gc_zicsr', '-mabi=lp64d',
                           '-Wl,-Ttext=0x70000000', '-Wl,--build-id=none', '-o', elf, S])
    subprocess.check_call([RV + 'objcopy', '-O', 'binary', '-j', '.text', elf, b])
    data = open(b, 'rb').read()
    with open(os.path.join(d, 'stub.hex'), 'w') as f:
        for i in range(0, len(data), 64):
            f.write(data[i:i+64].ljust(64, b'\0')[::-1].hex() + '\n')
    print(f'ckpt-stub: {d}: {len(code)} instructions, {len(tbl)} table words, {len(data)} bytes')

if __name__ == '__main__':
    main()
