/* Scalar RV64 kernels for clamchowder's MemoryBandwidth.c, the entry points of its
   MemoryBandwidth_riscv.s (draft-0.7 vector; SmolRV64 has no V): eight 8-byte accesses per
   64-byte line, the array swept whole `iterations` times. a0 = arr, a1 = arr_length (floats),
   a2 = iterations, a3 = start (unused, as in the vector version). Returns arr[0] in fa0. */
.text
.global asm_read
.global asm_write
.global asm_cflip
.global asm_copy
.global asm_add
.global flush_icache
.global readbankconflict
.global readbankconflict128

asm_read:
  slli a1, a1, 2
  add  a1, a1, a0
  addi a1, a1, -64      /* a1 = the last whole line */
  mv   t3, x0
asm_read_pass:
  mv   t1, a0
asm_read_line:
  ld   t0, 0(t1)
  ld   t2, 8(t1)
  ld   t4, 16(t1)
  ld   t5, 24(t1)
  ld   t6, 32(t1)
  ld   a4, 40(t1)
  ld   a5, 48(t1)
  ld   a6, 56(t1)
  addi t1, t1, 64
  bleu t1, a1, asm_read_line
  addi t3, t3, 1
  blt  t3, a2, asm_read_pass
  flw  fa0, (a0)
  ret

asm_write:
  slli a1, a1, 2
  add  a1, a1, a0
  addi a1, a1, -64
  ld   t0, (a0)
  mv   t3, x0
asm_write_pass:
  mv   t1, a0
asm_write_line:
  sd   t0, 0(t1)
  sd   t0, 8(t1)
  sd   t0, 16(t1)
  sd   t0, 24(t1)
  sd   t0, 32(t1)
  sd   t0, 40(t1)
  sd   t0, 48(t1)
  sd   t0, 56(t1)
  addi t1, t1, 64
  bleu t1, a1, asm_write_line
  addi t3, t3, 1
  blt  t3, a2, asm_write_pass
  flw  fa0, (a0)
  ret

/* read-modify-write: each 8-byte word gets 1 added */
asm_add:
  slli a1, a1, 2
  add  a1, a1, a0
  addi a1, a1, -64
  mv   t3, x0
asm_add_pass:
  mv   t1, a0
asm_add_line:
  ld   t0, 0(t1)
  ld   t2, 8(t1)
  ld   t4, 16(t1)
  ld   t5, 24(t1)
  addi t0, t0, 1
  addi t2, t2, 1
  addi t4, t4, 1
  addi t5, t5, 1
  sd   t0, 0(t1)
  sd   t2, 8(t1)
  sd   t4, 16(t1)
  sd   t5, 24(t1)
  ld   t0, 32(t1)
  ld   t2, 40(t1)
  ld   t4, 48(t1)
  ld   t5, 56(t1)
  addi t0, t0, 1
  addi t2, t2, 1
  addi t4, t4, 1
  addi t5, t5, 1
  sd   t0, 32(t1)
  sd   t2, 40(t1)
  sd   t4, 48(t1)
  sd   t5, 56(t1)
  addi t1, t1, 64
  bleu t1, a1, asm_add_line
  addi t3, t3, 1
  blt  t3, a2, asm_add_pass
  flw  fa0, (a0)
  ret

/* unimplemented in the vector version too */
asm_copy:
asm_cflip:
flush_icache:
readbankconflict:
readbankconflict128:
  ret
