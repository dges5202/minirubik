// RV32I optimal solver for the 2x2x2 cube: IDA* over the factored
// (permutation, orientation) index pair, pruned by two pattern databases.
// ida.c is the reference this file follows.
//
// Built through the C preprocessor (make iret / make asm): STATE becomes the
// 14-character input string and RENDER selects the LED build. Use // comments
// so a comment can never be read as a preprocessor directive.
//
// Registers that live across the search (steps 4 and 5):
//   s0 = bound      s1 = MAX_DEPTH (11)   s2 = g          s6 = MOVES (9)
//   s3 = pi[]       s4 = oi[]             s5 = next[]     s7 = path[]
//   s8 = face_of[]  a3 = turns_of[]       s9 = h
//   s10 = oi of the root                  s11 = pi of the root

.data
// Search stack, one entry per depth 0..MAX_DEPTH:
//   unsigned pi[MAX_DEPTH + 1], oi[MAX_DEPTH + 1];
// .half: pi < 5040 and oi < 729 do not fit in a byte. They come first so they
// stay 2-byte aligned (tables.s ends at an odd offset).
pi: .zero 24
oi: .zero 24

#include "tables.s"

state:  .string STATE
// state_t s: p[7] and o[7] parsed from STATE. s[] holds the Lehmer digits,
// rp[]/ro[] are the scratch state r of the T5 replay.
p: .zero 7
o: .zero 7
s: .zero 7
rp: .zero 7
ro: .zero 7
// uint8_t path[MAX_DEPTH], next[MAX_DEPTH + 1];
path: .zero 11
next: .zero 12
// The three turns of each face stay adjacent and in the order 1, 2, 3.
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
    // s10 is rank_ori, s11 is rank_perm

//rank_ori
    // unsigned r = 0;
    // for (i = 0; i < CUBIES - 1; ++i)
    //     r = (r << 1) + r + o[i];
    la s1, o                        // s1 = o's first memory

    addi t0, x0, 0                  // t0 = i
    addi t1, x0, 6                  // t1 = CUBIES - 1

    addi s10, x0, 0                 // s10 = r
loop_rank_o:
    lbu t2, 0(s1)                   // load s1's number
    slli t3, s10, 1                 // t3 = (r<<1)
    add s10, s10, t3
    add s10, s10, t2

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

    mv s11, t0

    // 3. Already solved (pi == 0 and oi == 0)? Print an empty line and exit.
    //    h == 0 iff solved, so h(root) doubles as the solved test.
    //
    //    unsigned hp = perm_dist[pi], ho = ori_dist[oi];
    //    h = hp > ho ? hp : ho;
    //    if (h == 0) { putchar('\n'); exit(0); }
//heuristic
    la s0, perm_dist                // perm_dist[0]'s first memory
    la s1, ori_dist                 // ori_dist[0]'s first memory

    add t0, s0, s11                 // perm_dist[pi]'s memory
    add t1, s1, s10                 // ori_dist[oi]'s memory

    lbu t2, 0(t0)                   // perm_dist[pi]
    lbu t3, 0(t1)                   // ori_dist[oi]

    add s9, x0, t2                  // assume h = hp
    bgeu t2, t3, greater_discision
    add s9, x0, t3                  // correct: h = ho
greater_discision:

    bne s9, x0, skip_label1

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
    addi s1, x0, 11                 // s1 = MAX_DEPTH = 11

    addi s6, x0, 9                  // s6 = 9

loop_solve:
    addi s2, x0, 0                  // s2 = g = 0

    la s3, pi                       // pi[0]'s memory
    sh s11, 0(s3)                   // store s11(rank_perm) to pi[0]

    la s4, oi                       // oi[0]'s memory
    sh s10, 0(s4)                   // store s10(rank_ori) to oi[0]

    la s5, next                     // next[0]'s memory
    sb x0, 0(s5)                    // store 0 to next[0]

    la s7, path                     // path[0]'s memory

    la s8, face_of                  // face_of[0]'s memory

    la a3, turns_of                 // turns_of[0]'s memory

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
    add t1, s5, s2                  // next[g]'s memory
    lbu t2, 0(t1)                   // t2 = next[g]

    bne t2, s6, child

    beq s2, x0, bound_failed

    addi s2, s2, -1                 // s2 = g = g - 1

    j search_top

    //    unsigned m = next[g]++;
    //    if (g > 0 && face_of[m] == face_of[path[g - 1]])
    //        continue;
child:
    add a1, t2, x0                  // a1 = m
    addi t2, t2, 1                  // t2 = next[g]++
    sb t2, 0(t1)                    // store next[g]++

    add t3, s8, x0
    add t3, t3, a1                  // face_of[m]'s memory
    lbu a5, 0(t3)                   // a5 = face_of[m]

    beq x0, s2, no_prev             // if s2 = g == 0

    add t5, s7, s2                  // path[g]'s memory
    addi t5, t5, -1                 // path[g - 1]'s memory
    lbu t6, 0(t5)                   // t6 = path[g - 1]

    add t3, s8, t6                  // face_of[path[g - 1]]'s memory
    lbu t5, 0(t3)                   // t5 = face_of[path[g - 1]]
    beq t5, a5, search_top

    //    pi[g + 1] holds the previous sibling, so each child is one turn:
    //    unsigned from = turns_of[m] == 1 ? g : g + 1;
no_prev:

    add t0, a3, a1                  // turns_of[m]'s memory
    lbu t1, 0(t0)                   // t1 = turns_of[m]

    addi t2, x0, 1

    add a6, s2, x0                  // if turns_of[m] == 1; a6 = from = g

    beq t1, t2, no_prev_equal1
    addi a6, s2, 1                  // if turns_of[m] != 1; a6 = from = g + 1

    //    perm_move[face_of[m]], ori_move[face_of[m]]: pick the face's tables
no_prev_equal1:
    //chose list
    la t0, perm_move_r              // t0 = perm_move_r[0]'s memory
    la t1, ori_move_r               // t1 = ori_move_r[0]'s memory
    beq a5, x0, selected            // if face == 0; selected

    la t0, perm_move_b              // t0 = perm_move_b[0]'s memory
    la t1, ori_move_b               // t1 = ori_move_b[0]'s memory
    addi t2, x0, 1
    beq a5, t2, selected            // if face == 1; selected

    la t0, perm_move_d              // t0 = perm_move_d[0]'s memory
    la t1, ori_move_d               // t1 = ori_move_d[0]'s memory

    //    unsigned cp = perm_move[face_of[m]][pi[from]];
    //    unsigned co = ori_move[face_of[m]][oi[from]];
    //    pi[g + 1] = cp;
    //    oi[g + 1] = co;
    //    path[g] = m;
selected:
    //cp
    slli t5, a6, 1
    add t2, s3, t5                  // t2 = pi[from]'s memory
    lhu t3, 0(t2)                   // t3 = pi[from]
    slli t4, t3, 1
    add t2, t4, t0                  // t2 = perm_move_x[0]'s memory + pi[from]
    lhu t6, 0(t2)                   // t6 = perm_move[face_of[m]][pi[from]]

    //co
    add t2, s4, t5                  // t2 = oi[from]'s memory
    lhu t3, 0(t2)                   // t3=oi[from]
    slli t4, t3, 1
    add t2, t4, t1                  // t2 = ori_move_x[0]'s memory + oi[from]
    lhu t5, 0(t2)                   // t5 = ori_move[face_of[m]][oi[from]]

    //save
    addi t2, s2, 1                  // t2 = g + 1
    slli t3, t2, 1                  // t3 = t2 << 1

    add t4, s3, t3                  // t4 = pi[g + 1]'s memory
    sh t6, 0(t4)                    // store perm_move[face_of[m]][pi[from]] to pi[g + 1]

    add t4, s4, t3                  // t4 = oi[g + 1]'s memory
    sh t5, 0(t4)                    // store ori_move[face_of[m]][oi[from]] to oi[g + 1]

    add t3, s7, s2                  // t3 = path[g]'s memory
    sb a1, 0(t3)                    // store m to path[g]

    //    if (cp == 0 && co == 0) goto found;   /* length g + 1 */
    //if discision
    or t2, t5, t6                   // t2 = co | cp
    beq t2, x0, found

    //    unsigned h = heuristic(cp, co);
    //    if (g + 1 + h > bound) continue;
    //heuristic
    la t0, perm_dist                // perm_dist[0]'s first memory
    la t1, ori_dist                 // ori_dist[0]'s first memory

    add t2, t0, t6                  // perm_dist[cp]'s memory
    add t3, t1, t5                  // ori_dist[co]'s memory

    lbu t4, 0(t2)                   // perm_dist[cp]
    lbu a2, 0(t3)                   // ori_dist[co]

    add s9, x0, t4                  // s9 = h
    bgeu t4, a2, greater_discision1
    add s9, x0, a2

greater_discision1:

    addi t0, s2, 1                  // t0 = g + 1
    add t0, t0, s9                  // t0 = g + 1 + h

    bltu s0, t0, search_top         // bound < g + 1 + h: prune

    //    next[g + 1] = 0;
    //    ++g;
    add t0, s5, s2
    addi t0, t0, 1

    sb x0, 0(t0)                    // store 0 to next[g + 1]

    addi s2, s2, 1                  // ++g

    j search_top

    //    No path within bound: ++bound and search again (step 4).
bound_failed:

    addi s0, s0, 1
    bleu s0, s1, loop_solve

found:

    // 6. Print the path as move names separated by spaces, then a newline.
    //
    //    for (i = 0; i < len; ++i)            /* len = g + 1 */
    //        printf("%s%s", i ? " " : "", move_names[path[i]]);
    //    putchar('\n');
    addi t0, x0, 0                  // t0 = i = 0
    addi t1, s2, 1                  // t1 = g + 1

    la t3, move_names               // move_names[0]'s memory
    //s7 = path[0]'s memory

loop_print:
    add t2, s7, t0                  // t2 = path[i]'s memory
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

test_loop:
    add t2, s7, s0                  // t2 = path[i]'s memory
    lbu t3, 0(t2)                   // t3 = m = path[i]

    add t4, s8, t3                  // t4 = face_of[m]'s memory
    add t5, a3, t3                  // t5 = turns_of[m]'s memory

    lbu s3, 0(t4)                   // s3 = f = face_of[m]
    lbu s4, 0(t5)                   // s4 = t = turns_of[m]

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

    addi s4, s4, -1
    bne s4, x0, turn_loop

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
// LED matrix renderer: unfolded net, redrawn after every move of the path.
#endif
