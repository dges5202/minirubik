// RV32I optimal solver for the 2x2x2 cube: IDA* over the factored
// (permutation, orientation) index pair, pruned by two pattern databases.
// ida.c is the reference this file follows.
//
// Built through the C preprocessor (make iret / make asm): STATE becomes the
// 14-character input string and RENDER selects the LED build. Use // comments
// so a comment can never be read as a preprocessor directive.
//
// Registers that live across the search (steps 4 and 5):
//   constants and state   s0 = bound          s1 = MOVES (9)      s2 = g
//                         s10 = r = bound - g - 1 (moves left below a child)
//   depth pointers        s3 = Q = &pi[g]     s4 = P = &path[g]   s5 = face_of[]
//   tables                s6 = perm_move_r    s7 = ori_move_r
//                         s8 = perm_dist      s9 = ori_dist
//   per child (scratch)   t0-t6, a1 = m, a5 = face, a6 = F = &pi[from]
//   unused                s11, a0, a2, a3, a4, a7 (ecall only), ra, sp, gp, tp
// g, P, Q and r move together: push is g++, P += 1, Q += 2, r--; pop the
// reverse.
// Neighbouring arrays are reached by fixed offsets, so their order in .data
// matters: next[g] = P + 11, oi[g] = Q + 24, turns_of[m] = &face_of[m] + 9.
// The root (pi, oi) is stored once in pi[0], oi[0]: the search only writes
// depth g + 1 >= 1, so they survive every bound.

.data
#if RENDER
// LED renderer tables (step 8). 144 bytes, words first, so everything after
// keeps its alignment.
//
// color6[face]: 0xRRGGBB of each face, U=0 L=1 F=2 R=3 B=4 D=5.
color6:
    .word 0xFFFFFF, 0xFF8000, 0x00FF00, 0xFF0000, 0x0000FF, 0xFFFF00
// face_off[i]: byte offset of facelet i's top-left LED from
// LED_MATRIX_0_BASE, 4 * (y * 35 + x). Faces U L F R B D; within a face
// top-left, top-right, bottom-left, bottom-right.
face_off:
    .half 36, 52, 456, 472, 980, 996, 1400, 1416, 1016, 1032, 1436, 1452
    .half 1052, 1068, 1472, 1488, 1088, 1104, 1508, 1524, 1996, 2012, 2416, 2432
// fl_pos[i]: corner position of facelet i (0-6 as p[], 7 = fixed corner).
// fl_slot[i]: which sticker of that corner, 0 = U/D, then clockwise seen
// from outside. fl_slot must directly follow fl_pos: read as &fl_pos[i] + 24.
fl_pos:
    .byte 6, 3, 7, 0,   6, 7, 5, 2,   7, 0, 2, 1,   0, 3, 1, 4,   3, 6, 4, 5,   2, 1, 5, 4
fl_slot:
    .byte 0, 0, 0, 0,   1, 2, 2, 1,   1, 2, 2, 1,   1, 2, 2, 1,   1, 2, 2, 1,   0, 0, 0, 0
// corner_face[c][k]: face of cubie c's sticker k when solved.
corner_face:
    .byte 0, 3, 2                   // cubie 0 (FUR): U R F
    .byte 5, 2, 3                   // cubie 1 (FDR): D F R
    .byte 5, 1, 2                   // cubie 2 (FDL): D L F
    .byte 0, 4, 3                   // cubie 3 (BUR): U B R
    .byte 5, 3, 4                   // cubie 4 (BDR): D R B
    .byte 5, 4, 1                   // cubie 5 (BDL): D B L
    .byte 0, 1, 4                   // cubie 6 (BUL): U L B
    .byte 0, 2, 1                   // cubie 7 (FUL, fixed): U F L
#endif
// Search stack, one entry per depth 0..MAX_DEPTH:
//   unsigned pi[MAX_DEPTH + 1], oi[MAX_DEPTH + 1];
// .half: pi < 5040 and oi < 729 do not fit in a byte. They come first so they
// stay 2-byte aligned (tables.s ends at an odd offset). oi must directly
// follow pi: the search reads oi[g] as &pi[g] + 24.
pi: .zero 24
oi: .zero 24

#include "tables.s"

state:  .string STATE
// state_t s: p[7] and o[7] parsed from STATE. s[] holds the Lehmer digits,
// rp[]/ro[] are the scratch state r of the T5 replay.
// With RENDER, p[7] = 7 and o[7] = 0 stand for the fixed corner, and the
// renderer reads o[pos] as &p[pos] + 8.
#if RENDER
p: .zero 7
    .byte 7
o: .zero 8
#else
p: .zero 7
o: .zero 7
#endif
s: .zero 7
rp: .zero 7
ro: .zero 7
// uint8_t path[MAX_DEPTH], next[MAX_DEPTH + 1];
// next must directly follow path: the search reads next[g] as &path[g] + 11.
path: .zero 11
next: .zero 12
// The three turns of each face stay adjacent and in the order 1, 2, 3.
// turns_of must directly follow face_of: it is read as &face_of[m] + 9.
face_of: .byte 0, 0, 0, 1, 1, 1, 2, 2, 2
turns_of: .byte 1, 2, 3, 1, 2, 3, 1, 2, 3

message: .string "T5 failed"

// move_names[MOVES] = {"R", "R2", "R'", "B", "B2", "B'", "D", "D2", "D'"}
// Two bytes per name (name m starts at m << 1); Ripes has no char literals:
// 'R' = 82, 'B' = 66, 'D' = 68, '2' = 50, '\'' = 39.
move_names:
    .byte 82,  0
    .byte 82, 50
    .byte 82, 39
    .byte 66,  0
    .byte 66, 50
    .byte 66, 39
    .byte 68,  0
    .byte 68, 50
    .byte 68, 39

// source[FACES][CUBIES], twist[FACES][CUBIES]: independent cube model, used
// only by gate T5. Each row is padded to 8 bytes so row f starts at f << 3.
source:
    .byte 1, 4, 2, 0, 3, 5, 6, 9
    .byte 0, 1, 2, 4, 5, 6, 3, 9
    .byte 0, 2, 5, 3, 1, 4, 6, 9

twist:
    .byte 1, 2, 0, 2, 1, 0, 0, 9
    .byte 0, 0, 0, 1, 2, 1, 2, 9
    .byte 0, 0, 0, 0, 0, 0, 0, 9

.text
main:
    // 1. Parse STATE into p[7] and o[7] (digits '1'.., subtract '1').
    //    ida.c: parse_state
    //
    //    for (i = 0; i < CUBIES; ++i) p[i] = in[i] - '1';
    //    for (i = 0; i < CUBIES; ++i) o[i] = in[CUBIES + i] - '1';
    la s2, state

    add s0, s2, x0
    la s1, p

    addi t0, x0, 0
    addi t1, x0, 7

loop_p:
    lbu t2, 0(s0)
    addi t3, t2, -49                // t3 = in[i] - '1'

    sb t3, 0(s1)

    addi t0, t0, 1
    addi s0, s0, 1
    addi s1, s1, 1
    bne t0, t1, loop_p

//o_map
    la s1, o

    addi t0, x0, 0
    addi t1, x0, 7
loop_o:
    lbu t2, 0(s0)
    addi t3, t2, -49                // t3 = in[CUBIES + i] - '1'

    sb t3, 0(s1)

    addi t0, t0, 1
    addi s0, s0, 1
    addi s1, s1, 1
    bne t0, t1, loop_o

    // 2. pi = rank_perm(p), oi = rank_ori(o). No mul: shifts and adds.
    //    ida.c: rank_perm, rank_ori
    // a6 = rank_ori, a5 = rank_perm

//rank_ori
    // unsigned r = 0;
    // for (i = 0; i < CUBIES - 1; ++i)
    //     r = (r << 1) + r + o[i];
    la s1, o                        // s1 = o's first memory

    addi t0, x0, 0                  // t0 = i
    addi t1, x0, 6                  // t1 = CUBIES - 1

    addi a6, x0, 0                  // a6 = r
loop_rank_o:
    lbu t2, 0(s1)                   // load s1's number
    slli t3, a6, 1                  // t3 = (r<<1)
    add a6, a6, t3
    add a6, a6, t2

    addi t0, t0, 1
    addi s1, s1, 1

    bne t0, t1, loop_rank_o

//rank_perm
    // for (i = 0; i < CUBIES - 1; ++i) {
    //     unsigned smaller = 0;
    //     for (j = i + 1; j < CUBIES; ++j)
    //         smaller += p[j] < p[i];
    //     s[i] = smaller;
    // }
    la s0, s                        // s0 is s's first memory
    la s1, p                        // s1 is p's first memory

    addi t0, x0, 0                  // t0 = i
    addi t1, x0, 6                  // t1 = CUBIES - 1
    addi t3, t1, 1                  // t3 = CUBIES

loop_rank_p_out:
    addi t6, x0, 0                  // t6 = smaller

    addi t2, t0, 1                  // t2 = j = i + 1

    lbu t4, 0(s1)                   // t4 = number in p[i]
    addi s2, s1, 1                  // p[j]'s memory state
loop_rank_p_in:
    lbu t5, 0(s2)                   // t5 = number in p[j]
    slt a0, t5, t4                  // a0 = (p[j] < p[i])

    add t6, t6, a0

    addi t2, t2, 1
    addi s2, s2, 1

    bne t2, t3, loop_rank_p_in

    sb t6, 0(s0)

    addi t0, t0, 1
    addi s0, s0, 1
    addi s1, s1, 1

    bne t0, t1, loop_rank_p_out

//r_shift
    // unsigned r = s[0];
    // r = (r << 2) + (r << 1) + s[1];  /* x6 */
    // r = (r << 2) + r + s[2];         /* x5 */
    // r = (r << 2) + s[3];             /* x4 */
    // r = (r << 1) + r + s[4];         /* x3 */
    // r = (r << 1) + s[5];             /* x2 */
    la s0, s                        // s0 is s's first memory
    lbu t0, 0(s0)                   // t0 = r = s[0]

    lbu t1, 1(s0)                   // t1 = s[1]
    slli t2, t0, 2                  // t2 = r << 2
    slli t3, t0, 1                  // t3 = r << 1
    add t0, t1, t2
    add t0, t0, t3

    lbu t1, 2(s0)                   // t1 = s[2]
    slli t2, t0, 2                  // t2 = r << 2
    add t0, t0, t1
    add t0, t0, t2

    lbu t1, 3(s0)                   // t1 = s[3]
    slli t2, t0, 2                  // t2 = r << 2
    add t0, t1, t2

    lbu t1, 4(s0)                   // t1 = s[4]
    slli t2, t0, 1                  // t2 = r << 1
    add t0, t0, t1
    add t0, t0, t2

    lbu t1, 5(s0)                   // t1 = s[5]
    slli t2, t0, 1                  // t2 = r << 1
    add t0, t1, t2

    mv a5, t0

    // 3. Already solved (pi == 0 and oi == 0)? Print an empty line and exit.
    //    h == 0 iff solved, so h(root) doubles as the solved test.
    //
    //    unsigned hp = perm_dist[pi], ho = ori_dist[oi];
    //    h = hp > ho ? hp : ho;
    //    if (h == 0) { putchar('\n'); exit(0); }
//heuristic
    la s0, perm_dist                // perm_dist[0]'s first memory
    la s1, ori_dist                 // ori_dist[0]'s first memory

    add t0, s0, a5                  // perm_dist[pi]'s memory
    add t1, s1, a6                  // ori_dist[oi]'s memory

    lbu t2, 0(t0)                   // perm_dist[pi]
    lbu t3, 0(t1)                   // ori_dist[oi]

    add s9, x0, t2                  // assume h = hp
    bgeu t2, t3, greater_discision
    add s9, x0, t3                  // correct: h = ho
greater_discision:

    bne s9, x0, skip_label1

#if RENDER
    jal ra, render                  // show the solved cube
#endif
    li a0, 10
    li a7, 11
    ecall

    li a7, 10
    ecall

skip_label1:

    // 4. IDA* outer loop: bound from h(root) up to 11.
    //    ida.c: solve
    //
    //    for (bound = h(root); bound <= MAX_DEPTH; ++bound) {
    //        g = 0;
    //        pi[0] = pi_root; oi[0] = oi_root; next[0] = 0;
    //        search (step 5)
    //    }
    add s0, x0, s9                  // s0 = bound = heuristic(pi,oi)
    addi s1, x0, 9                  // s1 = const = 9


    la s3, pi                       // Q = &pi[0]
    la s4, path                     // P = &path[0]
    la s5, face_of                  // face_of[0]'s memory

    la s6, perm_move_r              // perm_move_r[0]'s memory
    la s7, ori_move_r               // ori_move_r[0]'s memory

    la s8, perm_dist                // perm_dist[0]'s memory
    la s9, ori_dist                 // ori_dist[0]'s memory

    sh a5, 0(s3)                    // store a5(rank_perm) to pi[0]
    sh a6, 24(s3)                   // oi[0] = root oi (oi[0] = Q + 24)


loop_solve:

    addi s2, x0, 0                  // s2 = g = 0
    addi s10, s0, -1                // s10 = bound - 1
    sb x0, 11(s4)                   // next[0] = 0 (next[0] = P + 11)

    // 5. One bounded depth-first pass with the explicit stack.
    //    ida.c: search
    //    Every "return" goes back to search_top, so no return address is
    //    needed: pop is g--, push is g++.
    //
    //    if (next[g] == MOVES) {
    //        if (g == 0) goto bound_failed;
    //        --g;
    //        continue;
    //    }
search_top:
    //if next[g] == 9
    lbu t2, 11(s4)                  // t2 = next[g] = *(P + 11)

    bne t2, s1, child

    beq s2, x0, bound_failed

    addi s2, s2, -1                 // s2 = g = g - 1
    addi s4, s4, -1                 // P = &path[g - 1]
    addi s3, s3, -2                 // Q = &pi[g - 1]
    addi s10, s10, 1                // s10 = bound -1 - (g - 1)

    j search_top

    //    unsigned m = next[g]++;
    //    if (g > 0 && face_of[m] == face_of[path[g - 1]])
    //        continue;
child:
    add a1, t2, x0                  // a1 = m
    addi t2, t2, 1                  // t2 = next[g]++
    sb t2, 11(s4)                   // next[g] = m + 1

    add t3, s5, a1                  // face_of[m]'s memory
    lbu a5, 0(t3)                   // a5 = face_of[m]

    beq x0, s2, no_prev             // if s2 = g == 0


    lbu t6, -1(s4)                  // t6 = path[g - 1] = *(P - 1)

    add t4, s5, t6                  // face_of[path[g - 1]]'s memory
    lbu t5, 0(t4)                   // t5 = face_of[path[g - 1]]

    beq t5, a5, search_top

    //    pi[g + 1] holds the previous sibling, so each child is one turn:
    //    unsigned from = turns_of[m] == 1 ? g : g + 1;
no_prev:

    lbu t1, 9(t3)                   // t1 = turns_of[m] = *(&face_of[m] + 9)

    addi t2, x0, 1

    add a6, s3, x0                  // assume turns_of[m] == 1: F = Q = &pi[g]

    beq t1, t2, no_prev_equal1
    addi a6, s3, 2                  // otherwise F = Q + 2 = &pi[g + 1]

    //    perm_move[face_of[m]], ori_move[face_of[m]]: pick the face's tables
no_prev_equal1:
    //chose list
    slli t0, a5, 14                 // t0 = face << 14 = face * 16384
    add t0, t0, s6                  // t0 = perm_move_r + face * 16384

    slli t1, a5, 11                 // t1 = face << 11 = face * 2048
    add t1, t1, s7                  // t1 = ori_move_r + face * 2048


    //    unsigned cp = perm_move[face_of[m]][pi[from]];
    //    unsigned co = ori_move[face_of[m]][oi[from]];
    //    pi[g + 1] = cp;
    //    oi[g + 1] = co;
    //    path[g] = m;
selected:
    //cp
    lhu t3, 0(a6)                   // t3 = pi[from] = *F

    slli t4, t3, 1
    add t2, t4, t0                  // t2 = perm_move_x[0]'s memory + pi[from]
    lhu t6, 0(t2)                   // t6 = perm_move[face_of[m]][pi[from]]

    //co
    lhu t3, 24(a6)                  // t3 = oi[from] = *(F + 24)

    slli t4, t3, 1
    add t2, t4, t1                  // t2 = ori_move_x[0]'s memory + oi[from]
    lhu t5, 0(t2)                   // t5 = ori_move[face_of[m]][oi[from]]

    //    g + 1 + max(hp, ho) > bound is hp > r || ho > r with
    //    r = bound - g - 1, so each table can prune on its own and the
    //    second load is skipped whenever the first one prunes:
    //
    //    if (perm_dist[cp] > r) continue;
    //    if (ori_dist[co] > r) continue;
    //    if (cp == 0 && co == 0) goto found;   /* length g + 1 */
    //
    //    The goal test can come last: the solved state has hp = ho = 0 and
    //    r >= 0, so it is never pruned.
    //
    //    The two stores run for every child, pruned or not, so they can sit
    //    between the lbu and the bltu that uses t4: on a pipelined model that
    //    slot would otherwise be a load-use stall.
    add t2, t6, s8                  // perm_dist[cp]'s memory
    sh t6, 2(s3)                    // pi[g + 1] = cp (Q + 2)
    lbu t4, 0(t2)                   // t4 = hp = perm_dist[cp]
    sh t5, 26(s3)                   // oi[g + 1] = co (Q + 26)
    bltu s10, t4, search_top        // r < hp: prune

    add t2, t5, s9                  // ori_dist[co]'s memory
    lbu t4, 0(t2)                   // t4 = ho = ori_dist[co]
    bltu s10, t4, search_top        // r < ho: prune

    or t2, t5, t6                   // t2 = co | cp
    beq t2, x0, found               // solved: length g + 1



    //    next[g + 1] = 0;
    //    ++g;

    sb a1, 0(s4)                    // path[g] = m
    sb x0, 12(s4)                   // next[g + 1] = 0 (P + 12)

    addi s2, s2, 1                  // ++g
    addi s4, s4, 1                  // P = &path[g + 1]
    addi s3, s3, 2                  // Q = &pi[g + 1]
    addi s10, s10, -1               // s10 = bound - 1 - (g + 1)

    j search_top

    //    No path within bound: ++bound and search again (step 4).
bound_failed:

    addi s0, s0, 1
    addi t0, x0, 11                 // t0 = MAX_DEPTH = 11
    bleu s0, t0, loop_solve

found:

    sb a1, 0(s4)                    // path[g] = m

    // 6. Print the path as move names separated by spaces, then a newline.
    //
    //    for (i = 0; i < len; ++i)            /* len = g + 1 */
    //        printf("%s%s", i ? " " : "", move_names[path[i]]);
    //    putchar('\n');
    addi t0, x0, 0                  // t0 = i = 0
    addi t1, s2, 1                  // t1 = g + 1

    la t3, move_names               // move_names[0]'s memory

    sub s4, s4, s2                  // s4 return to path[0]'s memory

loop_print:


    add t2, s4, t0                  // t2 = path[i]'s memory
    lbu t4, 0(t2)                   // t4 = path[i]
    slli t4, t4, 1                  // t4 = t4*2

    add t6, t3, t4                  // t6 = move_names[path[i]]'s memory
    lbu t5, 0(t6)                   // t5 = first char of move_names[path[i]]

    beq t0, x0, print_equal

    li a0, 32
    li a7, 11
    ecall

print_equal:
    mv a0, t5
    li a7, 11
    ecall

    addi t6, t6, 1                  // second char's memory
    lbu t5, 0(t6)                   // t5 = second char, 0 if none

    beq t5, x0, print_equal2

    mv a0, t5
    li a7, 11
    ecall

print_equal2:

    addi t0, t0, 1

    bne t0, t1, loop_print

    li a0, 10
    li a7, 11
    ecall

    // 7. Gate T5: replay the path on the independent cube model (source,
    //    twist) and check that it reaches solved. On failure print a
    //    message and exit with code 1.
    //    ida.c: replay_solves
    //
    //    for (k = 0; k < len; ++k)
    //        for (t = 0; t < turns_of[path[k]]; ++t) {
    //            f = face_of[path[k]];
    //            for (j = 0; j < CUBIES; ++j) {
    //                rp[j] = p[source[f][j]];
    //                ro[j] = (o[source[f][j]] + twist[f][j]) % 3;
    //            }
    //            p = rp; o = ro;
    //        }

    addi s0, x0, 0                  // s0 = i = 0
    addi s1, s2, 1                  // s1 = len = g + 1

    la a3, turns_of                 // turns_of[0]'s memory
    la s8, face_of                  // face_of[0]'s memory
    la a5, source                   // source[0]'s memory
    la a6, twist                    // twist[0]'s memory
    la a1, rp                       // rp[0]'s memory
    la a2, ro                       // ro[0]'s memory
    la s10, p                       // p[0]'s memory
    la s11, o                       // o[0]'s memory

    addi s9, x0, 3                  // s9 = 3

#if RENDER
    jal ra, render                  // show the scrambled state
#endif

test_loop:
    add t2, s4, s0                  // t2 = path[i]'s memory
    lbu t3, 0(t2)                   // t3 = m = path[i]

    add t4, s8, t3                  // t4 = face_of[m]'s memory
    add t5, a3, t3                  // t5 = turns_of[m]'s memory

    lbu s3, 0(t4)                   // s3 = f = face_of[m]
    lbu s7, 0(t5)                   // s7 = t = turns_of[m]

turn_loop:

    addi t2, x0, 0                  // t2 = j = 0
    addi t3, x0, 7                  // t3 = 7

test_loop_inner:
    //source 1 line is 8 byte, source[f][j] == source's memory + (f << 3) + j
    slli a4, s3, 3                  // a4 = f << 3
    add t6, t2, a4                  // t6 = (f << 3) + j
    add t0, a5, t6                  // t0 = source[f][j]'s memory
    lbu t1, 0(t0)                   // t1 = k = source[f][j]

    add t0, s10, t1                 // t0 = p[k]'s memory
    lbu t5, 0(t0)                   // t5 = p[k]

    add t4, a1, t2                  // t4 = rp[j]'s memory
    sb t5, 0(t4)                    // store p[k] to rp[j]

    //t0, t4, t5 can be used
    add t4, s11, t1                 // o[k]'s memory
    lbu t5, 0(t4)                   // t5 = o[k]

    add t0, a6, t6                  // t0 = twist[f][j]'s memory
    lbu t1, 0(t0)                   // t1 = twist[f][j]

    add t0, t5, t1                  // t0 = o[k] + twist[f][j] = sum

    // sum <= 4, so sum % 3 is one compare and one subtract
    bltu t0, s9, test_smaller_disc  // if sum < 3, jump to test_smaller_disc

    addi t0, t0, -3                 // t0 = sum - 3

test_smaller_disc:
    add t5, a2, t2                  // t5 = ro[j]'s memory
    sb t0, 0(t5)                    // store sum to ro[j]

    addi t2, t2, 1
    bne t2, t3, test_loop_inner

    // p = rp; o = ro;
    addi t2, x0, 0                  // t2 = j = 0

test_loop_inner2:
    add t0, a1, t2                  // t0 = rp[j]'s memory
    lbu t1, 0(t0)                   // t1 = rp[j]

    add t0, s10, t2                 // t0 = p[j]'s memory
    sb t1, 0(t0)                    // store rp[j] to p[j]

    add t0, a2, t2                  // t0 = ro[j]'s memory
    lbu t1, 0(t0)                   // t1 = ro[j]

    add t0, s11, t2                 // t0 = o[j]'s memory
    sb t1, 0(t0)                    // store ro[j] to o[j]

    addi t2, t2, 1
    bne t2, t3, test_loop_inner2

    addi s7, s7, -1
    bne s7, x0, turn_loop

#if RENDER
    jal ra, render                  // redraw after move path[i]
#endif

    addi s0, s0, 1
    bne s0, s1, test_loop

//------------------------------------------------------
    //    for (i = 0; i < CUBIES; ++i)
    //        if (p[i] != i || o[i] != 0) goto t5_failed;

    addi s0, x0, 0                  // s0 = i = 0
    addi s1, s0, 7                  // s1 = 7

test_loop2:
    //p[i] == i && o[i] == 0, pass
    add t0, s0, s10                 // t0 = p[i]'s memory
    lbu t1, 0(t0)                   // t1 = p[i]

    bne t1, s0, t5_failed

    add t0, s0, s11                 // t0 = o[i]'s memory
    lbu t1, 0(t0)                   // t1 = o[i]

    bne t1, x0, t5_failed

    addi s0, s0, 1
    bne s0, s1, test_loop2

    // 8. Exit with code 0.
    li a7, 10
    ecall

    //    puts("T5 failed"); exit(1);
t5_failed:

    la t0, message                  // t0 = message's memory

    li a7, 4
    mv a0, t0
    ecall

    li a7, 11
    li a0, 10
    ecall

    li a7, 93
    li a0, 1
    ecall

#if RENDER
//------------------------------------------------------
// 8. LED matrix renderer: unfolded net of the cube in p[], o[], redrawn
//    before the replay and after every move of the path.
//
//    for (i = 0; i < 24; ++i) {
//        pos = fl_pos[i], slot = fl_slot[i];
//        cubie = p[pos], tw = o[pos];
//        k = (slot + tw) % 3;
//        draw_select(color6[corner_face[cubie][k]],
//                    LED_MATRIX_0_BASE + face_off[i]);
//    }
//
//    Called from T5 with live values in s0-s11 and a1-a6, so it saves and
//    restores every register it writes except t0-t6. ra is saved too: the
//    jal to draw_select overwrites it.
render:
    addi sp, sp, -64
    sw ra, 0(sp)
    sw s1, 4(sp)
    sw s2, 8(sp)
    sw s4, 12(sp)
    sw s5, 16(sp)
    sw s6, 20(sp)
    sw s7, 24(sp)
    sw s8, 28(sp)
    sw a0, 32(sp)
    sw a1, 36(sp)
    sw a2, 40(sp)
    sw a3, 44(sp)
    sw a4, 48(sp)
    sw a5, 52(sp)
    sw a6, 56(sp)

    li s1, LED_MATRIX_0_BASE        // s1 = LED (0, 0)'s memory
    la s2, face_off                 // s2 = &face_off[i], .half entries
    la s4, fl_pos                   // s4 = &fl_pos[i]; fl_slot[i] = 24(s4)
    la s5, p                        // s5 = p[0]'s memory; o[pos] = 8(p + pos)
    la s6, corner_face              // s6 = corner_face[0][0]'s memory
    la s7, color6                   // s7 = color6[0]'s memory
    addi s8, x0, 3                  // s8 = 3

    addi a0, x0, 0                  // a0 = i = 0
    addi a1, x0, 24                 // a1 = 24 facelets

loop_faces:
    lhu t1, 0(s2)                   // t1 = face_off[i]
    add t1, t1, s1                  // t1 = facelet i's top-left LED's memory

    lbu a2, 0(s4)                   // a2 = fl_pos[i] = pos
    lbu a3, 24(s4)                  // a3 = fl_slot[i] = slot

    add a4, s5, a2                  // a4 = p[pos]'s memory
    lbu a5, 0(a4)                   // a5 = p[pos] = cubie
    lbu a6, 8(a4)                   // a6 = o[pos] = p[pos + 8]

    add a3, a3, a6                  // a3 = slot + tw
    bltu a3, s8, smaller_disc       // if slot + tw < 3, jump to smaller_disc
    addi a3, a3, -3                 // a3 = k = (slot + tw) % 3

smaller_disc:
    mv a2, a5                       // a2 = cubie (pos no longer needed)
    slli a5, a5, 1                  // a5 = cubie * 2
    add a5, a5, a2                  // a5 = cubie * 3

    add a5, a5, a3                  // a5 = cubie * 3 + k

    add a3, s6, a5                  // a3 = corner_face[cubie*3 + k]'s memory
    lbu a4, 0(a3)                   // a4 = corner_face[cubie*3 + k] = face

    slli a4, a4, 2                  // a4 = face * 4, .word entries
    add a5, s7, a4                  // a5 = color6[face]'s memory
    lw t0, 0(a5)                    // t0 = color6[face]

    jal ra, draw_select             // draw facelet i

    addi a0, a0, 1                  // ++i
    addi s2, s2, 2                  // next .half
    addi s4, s4, 1                  // next fl_pos
    bne a0, a1, loop_faces

    lw ra, 0(sp)
    lw s1, 4(sp)
    lw s2, 8(sp)
    lw s4, 12(sp)
    lw s5, 16(sp)
    lw s6, 20(sp)
    lw s7, 24(sp)
    lw s8, 28(sp)
    lw a0, 32(sp)
    lw a1, 36(sp)
    lw a2, 40(sp)
    lw a3, 44(sp)
    lw a4, 48(sp)
    lw a5, 52(sp)
    lw a6, 56(sp)
    addi sp, sp, 64
    jalr x0, ra, 0                  // return

//------------------------------------------------------
// draw_select: fill one facelet, 4 LEDs wide and 3 rows tall.
//   in:  t0 = color, t1 = top-left LED's memory
//   uses t2, t5, t6; leaves t0 and t1 unchanged
//
//   for (dy = 0; dy < 3; ++dy) {
//       p[0] = p[1] = p[2] = p[3] = color;
//       p += 35;                      // next row: 35 LEDs = 140 bytes
//   }
draw_select:
    addi t5, x0, 0                  // t5 = dy = 0
    addi t6, x0, 3                  // t6 = 3 rows
    mv t2, t1                       // t2 = p, so t1 survives the call

draw_label:
    sw t0, 0(t2)                    // 4 LEDs of this row
    sw t0, 4(t2)
    sw t0, 8(t2)
    sw t0, 12(t2)

    addi t2, t2, 140                // next row

    addi t5, t5, 1
    bne t5, t6, draw_label

    jalr x0, ra, 0                  // return
#endif
