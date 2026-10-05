# Stage 1 measurement: store N bytes, one word at a time, starting at BASE.
#
# Run against a small N (control) and large N to get Ripes' host memory per
# guest byte, and read --iret with --exectime for the simulation rate.
#
# --iret = 3 * N/4 + 5: three instructions per word stored, and five outside
# the loop (each li is a single lui, since both constants have zero low bits).

.equ N, 1048576          # bytes to write
.equ BASE, 0x20000000    # outside .text and .data

.text
main:
    li t0, BASE          # t0: next address to store
    li t2, N
    add t1, t0, t2       # t1: end address, BASE + N

loop:
    sw t0, 0(t0)
    addi t0, t0, 4
    bne t0, t1, loop

    addi a7, x0, 10      # exit
    ecall
