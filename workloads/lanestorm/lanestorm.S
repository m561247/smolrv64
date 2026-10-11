# lanestorm: two landing streams into one lane.
#
# A lane's landing buffer takes the LD stream (an integer load's result, by its register's
# shard) and the FE stream (an FP op's integer result: FLT/FEQ/FLE, FCVT, FMV.X, a divide), and
# drains one entry a cycle. Loads dispatched one per group all sit in column 0, so a run of them
# lands in lane 0; the compares of the loop below write a2 from column 0 too. The shape is
# Geekbench 5's N-Body inner loop with its function epilogue: four compare blocks whose exit is
# predicted while the compares are still in the FPU, and behind the predicted exit a run of
# loads that fills the load queue and then dispatches one a cycle.
#
# Runs on the core bench: tb_core +hex=lanestorm.hex +tohost=0x80010000. Every call runs the
# loop six times and leaves through the fourth block's branch, which the predictor learns from
# the history, so the epilogue is dispatched while the last iteration's compares are in the
# FPU; a load per block keeps the load queue near full, as on the board. tohost takes 1 on
# success, else (call number << 1) | 1 for the first call whose checksum of the restored
# registers differs from the first call's.
        .globl _start
        .section .text.startup
_start: li   sp, 0x80100000
        li   t0, 0x2000                  # mstatus.FS = Initial
        csrs mstatus, t0
        la   s3, data
        flw  fs0, 0(s3)                  # the threshold (0.5)
        flw  ft2, 16(s3)                 # burst's operands: 1.0 and 1.1 pairs
        flw  ft3, 32(s3)
        flw  ft4, 20(s3)
        flw  ft5, 36(s3)
        flw  ft6, 24(s3)
        flw  ft7, 40(s3)
        li   s6, 4000                    # calls
        li   s8, 0                       # the expected checksum (set by the first call)
        li   s10, 1                      # the call number
call_loop:
        la   s9, data+32                 # ft1 operands
        la   s4, index                   # the particle index by iteration
        li   s7, 16                      # the particle stride
        li   a1, 0
        li   a0, 8                       # the iteration bound (never reached)
        jal  ra, func
        mv   s1, a0
        jal  ra, burst
        add  a0, a0, s1
        bnez s8, 1f
        mv   s8, a0
1:      beq  a0, s8, 2f
        slli a1, s10, 1
        ori  a1, a1, 1
        j    fail
2:      addi s10, s10, 1
        addi s6, s6, -1
        beqz s6, pass
        # vary the alignment: a few ALU ops of different count between calls
        andi t0, s6, 7
        beqz t0, call_loop
        nop
        andi t0, s6, 3
        beqz t0, call_loop
        nop
        nop
        j    call_loop
pass:   li   a1, 1
fail:   li   t0, 0x80010000
        sd   a1, 0(t0)
3:      j    3b

        # func: the N-Body shape. a0 = the iteration bound, a1 = block 4's data offset (the
        # iteration at which its difference crosses the threshold), s0/s9 the operand arrays,
        # fs0 the threshold. Blocks 1-3 never exit (their differences are below the threshold).
        # Every call leaves through block 4's branch, so it trains taken and the epilogue is
        # dispatched behind it while the four compares are in flight -- the board's run-up.
func:   addi sp, sp, -256
        sd   ra, 248(sp)
        sd   s0, 240(sp)
        sd   s1, 232(sp)
        sd   s2, 224(sp)
        sd   s3, 216(sp)
        sd   s4, 208(sp)
        sd   s5, 200(sp)
        sd   s6, 192(sp)
        sd   s7, 184(sp)
        sd   s8, 176(sp)
        sd   s9, 168(sp)
        sd   s10, 160(sp)
        sd   s11, 152(sp)
        fsd  fs0, 144(sp)
        mv   s5, a0
        mv   s6, a1
        li   s11, 1                      # the iteration count
loop:
        # the particle's base, late: an index loaded by the iteration, scaled, added to a loaded
        # array base (the board's lw -> mul -> add), so the four ft0 loads wait for it together
        # and the four fsub.s then issue back to back
        slli a1, s11, 2
        add  a1, a1, s4
        lw   a2, 0(a1)
        mul  a2, a2, s7
        ld   a3, 8(s3)
        add  s0, a3, a2
        flw  ft0, 8(s0)
        flw  ft1, 0(s9)
        fsub.s ft0, ft1, ft0
        flt.s  a2, fs0, ft0
        bnez a2, exit
        flw  ft0, 12(s0)
        flw  ft1, 4(s9)
        fsub.s ft0, ft1, ft0
        flt.s  a2, fs0, ft0
        bnez a2, exit
        flw  ft0, 0(s0)
        flw  ft1, 8(s9)
        fsub.s ft0, ft0, ft1
        flt.s  a2, fs0, ft0
        bnez a2, exit
        flw  ft0, 4(s0)
        flw  ft1, 12(s9)
        fsub.s ft0, ft0, ft1
        flt.s  a2, fs0, ft0
        bnez a2, exit
        addi s11, s11, 1
        bne  s11, s5, loop
        li   a0, 0x55                    # never: the data must exit through block 4
        j    ret_
exit:
        # the epilogue: 13 restores and 20 more loads, 33 loads in a row -- past the load
        # queue's 16, so the tail dispatches one a cycle into column 0
        ld   t0, 0(sp)
        ld   t1, 8(sp)
        ld   t2, 16(sp)
        ld   t3, 24(sp)
        ld   t4, 32(sp)
        ld   t5, 40(sp)
        ld   t6, 48(sp)
        ld   a1, 56(sp)
        ld   a3, 64(sp)
        ld   a4, 72(sp)
        ld   a5, 80(sp)
        ld   a6, 88(sp)
        ld   a7, 96(sp)
        ld   t0, 104(sp)
        ld   t1, 112(sp)
        ld   t2, 120(sp)
        ld   t3, 128(sp)
        ld   t4, 136(sp)
        fld  fs0, 144(sp)
        ld   s11, 152(sp)
        ld   s10, 160(sp)
        ld   s9, 168(sp)
        ld   s8, 176(sp)
        ld   s7, 184(sp)
        ld   s6, 192(sp)
        ld   s5, 200(sp)
        ld   s4, 208(sp)
        ld   s3, 216(sp)
        ld   s2, 224(sp)
        ld   s1, 232(sp)
        ld   s0, 240(sp)
        ld   ra, 248(sp)
        ld   t5, 0(sp)
        ld   t6, 8(sp)
        # the checksum: the restored registers that are the same on every call
        mv   a0, s0
        add  a0, a0, s2
        add  a0, a0, s3
        add  a0, a0, s4
        add  a0, a0, s5
        add  a0, a0, s7
        add  a0, a0, s9
        add  a0, a0, s11
        add  a0, a0, ra
        add  a0, a0, t5
        add  a0, a0, t6
        add  a0, a0, a2
        add  a0, a0, t0
        add  a0, a0, t1
        add  a0, a0, t2
        add  a0, a0, t3
        add  a0, a0, t4
        xor  a0, a0, a4
ret_:   addi sp, sp, 256
        ret

        # burst: sixteen loads whose base waits on a divide (a backlog the LSU then drains one a
        # cycle, each load heading its group: column 0, lane A, an ALU op heading the group after
        # it -- lane A's, so its execute cycle can hold the buffer's drain), and four compares
        # whose differences wait on the same divide, so the FPU returns them in consecutive cycles
        # and their integer results (each FLT heads its group: column 0, lane A) land one a cycle
        # on top of the loads. None of the branches is taken. a0: the loads' checksum (zeros).
        # On the core before the FE stream's gate this fills lane A's buffer (4 of 4); the gate
        # holds it at 3, and the core asserts a push past the gate.
burst:  la   a1, scratch
        fdiv.s ft2, ft3, ft5             # 1.0 / 1.1: the late value
        fclass.s a3, ft2                 # 0x40 (a positive normal), late by the divide
        mul  a3, a3, zero                # ...and six cycles more
        mul  a3, a3, zero
        add  a3, a3, a1                  # the backlog's base, late
        ld   t0, 0(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t1, 8(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t2, 16(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t3, 24(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t4, 32(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t5, 40(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t6, 48(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t0, 56(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t1, 64(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t2, 72(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t3, 80(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t4, 88(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t5, 96(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t6, 104(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t0, 112(a3)
        nop
        nop
        addi a6, a6, 1
        ld   t1, 120(a3)
        nop
        nop
        addi a6, a6, 1
        fsub.s ft0, ft2, ft3             # every difference is below the threshold
        fsub.s ft1, ft2, ft4
        fsub.s ft8, ft2, ft5
        fsub.s ft9, ft2, ft6
        flt.s  a2, fs0, ft0
        bnez a2, bfail
        flt.s  a3, fs0, ft1
        bnez a3, bfail
        flt.s  a4, fs0, ft8
        bnez a4, bfail
        flt.s  a5, fs0, ft9
        bnez a5, bfail
        ld   t0, 128(a1)
        ld   t1, 136(a1)
        ld   t2, 144(a1)
        ld   t3, 152(a1)
        ld   t4, 160(a1)
        ld   t5, 168(a1)
        ld   t6, 176(a1)
        ld   t0, 184(a1)
        ld   t1, 192(a1)
        ld   t2, 200(a1)
        ld   t3, 208(a1)
        ld   t4, 216(a1)
        ld   t5, 224(a1)
        ld   t6, 232(a1)
        ld   t0, 240(a1)
        ld   t1, 248(a1)
        ld   t2, 128(a1)
        ld   t3, 136(a1)
        ld   t4, 144(a1)
        ld   t5, 152(a1)
        add  a0, t0, t1
        add  a0, a0, t2
        add  a0, a0, t3
        add  a0, a0, t4
        add  a0, a0, t5
        add  a0, a0, t6
        add  a0, a0, a2
        add  a0, a0, a3
        add  a0, a0, a4
        add  a0, a0, a5
        ret
bfail:  li   a1, 0x57
        j    fail

        .section .data
        .balign 16
data:   .float 0.5, 0.0                  # [0] fs0 = 0.5
        .dword particles                 # +8: the particle array's base (ld a3, 8(s3))
        .float 1.0, 1.0, 1.0, 1.0        # +16: burst's ft2/ft4/ft6
        .float 1.1, 1.1, 1.1, 1.1        # +32: s9's ft1 operands: differences of 0.1 (< 0.5)
index:  .word 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11   # the particle by iteration (iteration 1 reads [1])
        .balign 16
particles:                               # {f0, f1, f2, f3}: the blocks read 8, 12, 0, 4; block 4's
        .float 1.0, 1.0, 1.0, 1.0        # [0]   f1 at 4 crosses the threshold on particle 6 only
        .float 1.0, 1.0, 1.0, 1.0        # [1]
        .float 1.0, 1.0, 1.0, 1.0        # [2]
        .float 1.0, 1.0, 1.0, 1.0        # [3]
        .float 1.0, 1.0, 1.0, 1.0        # [4]
        .float 1.0, 1.0, 1.0, 1.0        # [5]
        .float 1.0, 9.0, 1.0, 1.0        # [6]
        .float 1.0, 9.0, 1.0, 1.0        # [7]
        .float 1.0, 9.0, 1.0, 1.0        # [8]
        .float 1.0, 9.0, 1.0, 1.0        # [9]
        .float 1.0, 9.0, 1.0, 1.0        # [10]
        .float 1.0, 9.0, 1.0, 1.0        # [11]
        .section .bss
        .balign 16
scratch: .skip 256
