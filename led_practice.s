# LED matrix practice: draw the solved cube as an unfolded net.
# Load this file directly into Ripes (Editor -> Assembly) with an LED Matrix
# of width 35 and height 25 added in the I/O tab.
#
# Net layout in pixels (each facelet is 4 wide, 3 tall; faces are 8 x 6,
# with one blank column/row between faces):
#
#   x:       0       8 9      16 17 18     25 26 27     34
#   y 0-5    .........UUUUUUUU..........................
#   y 7-12   LLLLLLLL.FFFFFFFF.RRRRRRRR.BBBBBBBB
#   y 14-19  .........DDDDDDDD..........................
#
# LED (x, y) lives at LED_MATRIX_0_BASE + 4 * (y * 35 + x).

.data

# Byte offset of each facelet's top-left LED from LED_MATRIX_0_BASE,
# 4 * (y * 35 + x).  Faces in order U L F R B D, and within a face
# top-left, top-right, bottom-left, bottom-right (+0, +16, +420, +436).
face_off:
    .half 36, 52, 456, 472, 980, 996, 1400, 1416, 1016, 1032, 1436, 1452, 1052, 1068, 1472, 1488, 1088, 1104, 1508, 1524, 1996, 2012, 2416, 2432

# Color of each facelet as 0xRRGGBB, same order as face_off (solved cube).
# Used by the current loop; becomes unused once colors come from p and o.
face_color:
    .word 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFF8000, 0xFF8000, 0xFF8000, 0xFF8000, 0x00FF00, 0x00FF00, 0x00FF00, 0x00FF00, 0xFF0000, 0xFF0000, 0xFF0000, 0xFF0000, 0x0000FF, 0x0000FF, 0x0000FF, 0x0000FF, 0xFFFF00, 0xFFFF00, 0xFFFF00, 0xFFFF00

# Color of each face, indexed by face number U=0 L=1 F=2 R=3 B=4 D=5.
# U white, L orange, F green, R red, B blue, D yellow.
color6:
    .word 0xFFFFFF, 0xFF8000, 0x00FF00, 0xFF0000, 0x0000FF, 0xFFFF00

# Corner positions use rubik.S numbering: 0-6 are the moving positions
# (report positions 1-7) and 7 is the fixed front-upper-left corner
# (report position 0), so p[pos] and o[pos] need no -1 and no branch.
#
# Corner position of each facelet, same order as face_off.
fl_pos:
    .byte 6, 3, 7, 0,   6, 7, 5, 2,   7, 0, 2, 1,   0, 3, 1, 4,   3, 6, 4, 5,   2, 1, 5, 4
# Which of that corner's stickers the facelet is: 0 = the U/D sticker,
# then clockwise seen from outside.  Must follow fl_pos: fl_slot[i] = fl_pos[i] + 24.
fl_slot:
    .byte 0, 0, 0, 0,   1, 2, 2, 1,   1, 2, 2, 1,   1, 2, 2, 1,   1, 2, 2, 1,   0, 0, 0, 0

# corner_face[c][k]: face of cubie c's sticker k when solved.
corner_face:
    .byte 0, 3, 2                   # cubie 0 (FUR): U R F
    .byte 5, 2, 3                   # cubie 1 (FDR): D F R
    .byte 5, 1, 2                   # cubie 2 (FDL): D L F
    .byte 0, 4, 3                   # cubie 3 (BUR): U B R
    .byte 5, 3, 4                   # cubie 4 (BDR): D R B
    .byte 5, 4, 1                   # cubie 5 (BDL): D B L
    .byte 0, 1, 4                   # cubie 6 (BUL): U L B
    .byte 0, 2, 1                   # cubie 7 (FUL, fixed): U F L

# Test state: one R turn from solved (25314672313211, solved by R').
# Entry 7 is the fixed corner: always cubie 7 with twist 0.
# Must stay adjacent: o[pos] = p[pos] + 8.
p:
    .byte 1, 4, 2, 0, 3, 5, 6, 7
o:
    .byte 1, 2, 0, 2, 1, 0, 0, 0



.text

# for (i = 0; i < 24; ++i)
#     draw_select(face_color[i], LED_MATRIX_0_BASE + face_off[i]);


    li s1, LED_MATRIX_0_BASE        # s1 = LED (0, 0)'s memory

    la s2, face_off                 # s2 = &face_off[i], .half entries
    la s3, face_color               # s3 = &face_color[i], .word entries

    la s4, fl_pos                   # s4 = &fl_pos[i]; fl_slot[i] = 24(s4)
    la s5, p                        # s5 = p[0]'s memory; o[pos] = 8(p + pos)
    la s6, corner_face              # s6 = corner_face[0][0]'s memory
    la s7, color6                   # s7 = color6[0]'s memory
    addi s8, x0, 3                  # s8 = 3

    addi a0, x0, 0                  # a0 = i = 0
    addi a1, x0, 24                 # a1 = 24 facelets

loop_faces:
    lhu t1, 0(s2)                   # t1 = face_off[i]
    add t1, t1, s1                  # t1 = facelet i's top-left LED's memory

    lbu a2, 0(s4)                   # a2 = fl_pos[i] = pos
    lbu a3, 24(s4)                  # a3 = fl_slot[i] = slot

    add a4, s5, a2                  # a4 = p[pos]'s memory
    lbu a5, 0(a4)                   # a5 = p[pos] = cubie
    lbu a6, 8(a4)                   # a6 = o[pos] = p[pos + 8]


    add a3, a3, a6                  # a3 = slot + tw
    bltu a3, s8, smaller_disc       # if slot + tw < 3, jump to smaller_disc
    addi a3, a3, -3                 # a3 = k = (slot + tw) % 3

smaller_disc:
    mv a2, a5                       # a2 = cubie (pos no longer needed)
    slli a5, a5, 1                  # a5 = cubie * 2
    add a5, a5, a2                  # a5 = cubie * 3

    add a5, a5, a3                  # a5 = cubie * 3 + k

    add a3, s6, a5                  # a3 = corner_face[cubie*3 + k]'s memory
    lbu a4, 0(a3)                   # a4 = corner_face[cubie*3 + k] = face

    slli a4, a4, 2                  # a4 = face * 4, .word entries
    add a5, s7, a4                  # a5 = color6[face]'s memory
    lw t0, 0(a5)                   # t0 = color6[face]






    jal ra, draw_select             # draw facelet i

    addi a0, a0, 1                  # ++i
    addi s2, s2, 2                  # next .half
    addi s3, s3, 4                  # next .word
    addi s4, s4, 1                  # next fl_pos
    bne a0, a1, loop_faces

    li a7, 10                       # exit
    ecall



#------------------------------------------------------
# draw_select: fill one facelet, 4 LEDs wide and 3 rows tall.
#   in:  t0 = color, t1 = top-left LED's memory
#   uses t2, t5, t6; leaves t0 and t1 unchanged
#
#   for (dy = 0; dy < 3; ++dy) {
#       p[0] = p[1] = p[2] = p[3] = color;
#       p += 35;                      // next row: 35 LEDs = 140 bytes
#   }

draw_select:

    addi t5, x0, 0                  # t5 = dy = 0
    addi t6, x0, 3                  # t6 = 3 rows
    mv t2, t1                       # t2 = p, so t1 survives the call

draw_label:

    sw t0, 0(t2)                    # 4 LEDs of this row
    sw t0, 4(t2)
    sw t0, 8(t2)
    sw t0, 12(t2)

    addi t2, t2, 140                # next row

    addi t5, t5, 1
    bne t5, t6, draw_label

    jalr x0, ra, 0                  # return
