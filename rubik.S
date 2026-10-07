// RV32I optimal solver for the 2x2x2 cube: IDA* over the factored
// (permutation, orientation) index pair, pruned by two pattern databases.
// ida.c is the reference this file follows.
//
// Built through the C preprocessor (make iret / make asm): STATE becomes the
// 14-character input string and RENDER selects the LED build. Use // comments
// so a comment can never be read as a preprocessor directive.



.data
pi: .zero 24
oi: .zero 24

#include "tables.s"

state:  .string STATE
p: .zero 7
o: .zero 7
s: .zero 7
path: .zero 11
next: .zero 12
face_of: .byte 0, 0, 0, 1, 1, 1, 2, 2, 2
turns_of: .byte 1, 2, 3, 1, 2, 3, 1, 2, 3

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

// TODO (design): search stack pi[], oi[], next[], path[], one entry per depth.
//   How wide is each element (.word / .half / .byte)? The width decides the
//   shift you need to turn a depth into an address.

// TODO: strings for output (move names, separator, newline, messages).

.text
main:
    // 1. Parse STATE into p[7] and o[7] (digits '1'.., subtract '1').
    //    ida.c: parse_state
    la s2, state 

    add s0, s2, x0 
    la s1, p

    addi t0, x0, 0
    addi t1, x0, 7

loop_p:
    lbu t2, 0(s0)
    addi t3, t2, -49

    sb t3, 0(s1)

    //mv a0, t3
    //li a7, 1
    //ecall

    //li a0, 32
    //li a7, 11
    //ecall


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
    addi t3, t2, -49

    sb t3, 0(s1)

    //mv a0, t3
    //li a7, 1
    //ecall

    //li a0, 32
    //li a7, 11
    //ecall


    addi t0, t0, 1
    addi s0, s0, 1
    addi s1, s1, 1
    bne t0, t1, loop_o



    // 2. pi = rank_perm(p), oi = rank_ori(o). No mul: shifts and adds.
    //    ida.c: rank_perm, rank_ori
    // s10 is rank_ori, s11 is rank_perm

//rank_ori
    la s1, o// s1 = o's first memory 

    addi t0, x0, 0 //t0 = i
    addi t1, x0, 6 //t1 = CUBIES - 1
    
    addi s10, x0, 0 // s10 = r 
loop_rank_o:
    lbu t2, 0(s1) //load s1's number
    slli t3, s10, 1 // t3 = (r<<1)
    add s10, s10, t3
    add s10, s10, t2

    addi t0, t0, 1
    addi s1, s1, 1

    bne t0, t1, loop_rank_o

    //mv a0, s10
    //li a7, 1
    //ecall


//rank_perm
    la s0, s //s0 is s's first memory
    la s1, p //s1 is p's first memory

    addi t0, x0, 0 // t0 = i
    addi t1, x0, 6 // t1 = CUBIES - 1
    addi t3, t1, 1 // t3 = CUBIES

loop_rank_p_out:
    addi t6, x0, 0 // t6 = smaller

    addi t2, t0, 1 // t2 = j = i + 1

    lbu t4, 0(s1) // t4 = number in p[i]
    addi s2, s1, 1 //p[j]'s memory state
loop_rank_p_in:
    lbu t5, 0(s2) // t5 = number in p[j]
    slt a0, t5, t4 // a0 = (p[j] < p[i])

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
    la s0, s //s0 is s's first memory
    lbu t0, 0(s0) // t0 = r = s[0]
    
    lbu t1, 1(s0) // t1 = s[1]
    slli t2, t0, 2 // t2 = r << 2
    slli t3, t0, 1 // t3 = r << 1
    add t0, t1, t2
    add t0, t0, t3

    lbu t1, 2(s0) // t1 = s[2]
    slli t2, t0, 2 // t2 = r << 2
    add t0, t0, t1
    add t0, t0, t2

    lbu t1, 3(s0) // t1 = s[3]
    slli t2, t0, 2 // t2 = r << 2
    add t0, t1, t2

    lbu t1, 4(s0) // t1 = s[4]
    slli t2, t0, 1 // t2 = r << 1
    add t0, t0, t1
    add t0, t0, t2

    lbu t1, 5(s0) // t1 = s[5]
    slli t2, t0, 1 // t2 = r << 1
    add t0, t1, t2

    mv s11, t0

    //li a0, 32
    //li a7, 11
    //ecall

    //mv a0, s11
    //li a7, 1
    //ecall

    // 3. Already solved (pi == 0 and oi == 0)? Print an empty line and exit.
//heuristic
    la s0, perm_dist // perm_dist[0]'s first memory
    la s1, ori_dist // ori_dist[0]'s first memory

    add t0, s0, s11 // perm_dist[pi]'s memory
    add t1, s1, s10 // ori_dist[oi]'s memory

    lbu t2, 0(t0) //perm_dist[pi]
    lbu t3, 0(t1) //ori_dist[oi]

    add s9, x0, t2
    bgeu t2, t3, greater_discision
    add s9, x0, t3
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
    add s0, x0, s9 // s0 = bound = heuristic(pi,oi)
    addi s1, x0, 11 //s1 = MAX_DEPTH = 11

    addi s6, x0, 9 // s6 = 9

loop_solve:
    addi s2, x0, 0 //s2 = g = 0
    
    la s3, pi // pi[0]'s memory
    sh s11, 0(s3) // store s11(rank_perm) to pi[0]

    la s4, oi // oi[0]'s memory
    sh s10, 0(s4) // store s10(rank_ori) to oi[0]

    la s5, next // next[0]'s memory
    sb x0, 0(s5) // store 0 to next[0]

    la s7, path // path[0]'s memory

    la s8, face_of //face_of[0]'s memory

    la a3, turns_of // turns_of[0]'s memory

    //li a0, 32
    //li a7, 11
    //ecall

    //mv a0, s0
    //li a7, 1
    //ecall

search_top:
    //if next[g] == 9
    add t1, s5, s2 // next[g]'s memory
    lbu t2, 0(t1) //t2 = next[g]

    bne t2, s6, child

    beq s2, x0, bound_failed

    addi s2, s2, -1 //s2 = g = g - 1


    j search_top


child:
    add a1, t2, x0 // a1 = m
    addi t2, t2, 1 //t2 = next[g]++
    sb t2, 0(t1) //store next[g]++



    add t3, s8, x0
    add t3, t3, a1 //face_of[m]'s memory
    lbu a5, 0(t3) //a5 = face_of[m]

    beq x0, s2, no_prev // if s2 = g == 0

    add t5, s7, s2 //path[g]'s memory
    addi t5, t5, -1 //path[g - 1]'s memory
    lbu t6, 0(t5) //t6 = path[g - 1]

    add t3, s8, t6 // face_of[path[g - 1]]*s memory
    lbu t5, 0(t3) // t5 = face_of[path[g - 1]]
    beq t5, a5, search_top

no_prev:


    add t0, a3, a1 //turns_of[m]'s memory
    lbu t1, 0(t0) //t1 = turns_of[m]

    addi t2, x0, 1

    add a6, s2, x0 // if turns_of[m] == 1; a6 = from = g

    beq t1, t2, no_prev_equal1
    addi a6, s2, 1 //if turns_of[m] != 1; a6 = from = g + 1

no_prev_equal1:
    //chose list
    la t0, perm_move_r //t0 = perm_move_r[0]'s memory
    la t1, ori_move_r //t1 = ori_move_r[0]'s memory
    beq a5, x0, selected // if face == 0; selected

    la t0, perm_move_b // t0 = perm_move_b[0]'s memory
    la t1, ori_move_b // t1 = ori_move_b[0]'s memory
    addi t2, x0, 1
    beq a5, t2, selected // if face == 1; selected

    la t0, perm_move_d // t0 = perm_move_d[0]'s memory
    la t1, ori_move_d // t1 = ori_move_d[0]'s memory


selected:
    //cp
    slli t5, a6, 1
    add t2, s3, t5 //t2 = pi[from]'s memory
    lhu t3, 0(t2) //t3 = pi[from]
    slli t4, t3, 1
    add t2, t4, t0 //t2 = perm_move_x[0]'s memory + pi[from]
    lhu t6, 0(t2) //t6 = perm_move[face_of[m]][pi[from]]

    //co
    add t2, s4, t5 //t2 = oi[from]'s memory
    lhu t3, 0(t2) //t3=oi[from]
    slli t4, t3, 1
    add t2, t4, t1 //t2 = ori_move_x[0]'s memory + oi[from]
    lhu t5, 0(t2) // t5 = ori_move[face_of[m]][oi[from]]

    //save
    addi t2, s2, 1 // t2 = g + 1
    slli t3, t2, 1 // t3 = t2 << 1

    add t4, s3, t3 //t4 = pi[g + 1]'s memory
    sh t6, 0(t4) // store perm_move[face_of[m]][pi[from]] to pi[g + 1]

    add t4, s4, t3//t4 = oi[g + 1]'s memory
    sh t5, 0(t4) // store ori_move[face_of[m]][oi[from]] to oi[g + 1]

    add t3, s7, s2 //t3 = path[g]'s memory
    sb a1, 0(t3) //store m to path[g]


    //if discision
    or t2, t5, t6 // t2 == t5 || t6
    beq t2, x0, found

    //heuristic
    la t0, perm_dist // perm_dist[0]'s first memory
    la t1, ori_dist // ori_dist[0]'s first memory

    add t2, t0, t6 // perm_dist[cp]'s memory
    add t3, t1, t5 // ori_dist[co]'s memory

    lbu t4, 0(t2) //perm_dist[cp]
    lbu a2, 0(t3) //ori_dist[co]

    add s9, x0, t4  // s9 = h
    bgeu t4, a2, greater_discision1
    add s9, x0, a2

greater_discision1:


    addi t0, s2, 1 //t0 = g + 1
    add t0, t0, s9 // t0 = g + 1 + h

    bltu s0, t0, search_top

    add t0, s5, s2
    addi t0, t0, 1

    sb x0, 0(t0) // store 0 to next[g + 1]

    addi s2, s2, 1 //++g

    j search_top


bound_failed:

    addi s0, s0, 1
    bleu s0, s1, loop_solve

found:

    // 5. One bounded depth-first pass with the explicit stack.
    //    ida.c: search
    //    Per child: same-face skip, one quarter turn (from parent or from the
    //    previous sibling), goal test, heuristic, prune, push.
    //    TODO (design): which values live in registers for the whole search
    //    (g, bound, table base addresses, ...)?
    //    TODO (design): how do you get the perm_move / ori_move table for a
    //    face without multiplying by the table size?

    // 6. Print the path as move names separated by spaces, then a newline.
    addi t0, x0, 0 //t0 = i = 0
    addi t1, s2, 1 //t1 = g + 1

    la t3, move_names //move_names[0]'s memory
    //s7 = path[0]'s memory

loop_print:
    add t2, s7, t0 // t2 = path[i]'s memory
    lbu t4, 0(t2) // t4 = path[i]
    slli t4, t4, 1 // t4 = t4*2

    add t6, t3, t4 // t3 = move_names[path[i]]'s memory
    lbu t5, 0(t6) // t5 = move_names[path[i]]

    beq t0, x0, print_equal

    li a0, 32
    li a7, 11
    ecall

print_equal:
    mv a0, t5
    li a7, 11
    ecall

    addi t6, t6, 1 // move_names[path[i + 1]]'s memory
    lbu t5, 0(t6) // t5 = move_names[path[i + 1]]

    beq t5, x0, print_equal2

    mv a0, t5
    li a7, 11
    ecall

print_equal2:


    addi t0, t0, 1

    bne t0, t1, loop_print




    // 7. Gate T5: replay the path with the move tables and check that it
    //    reaches (0, 0). On failure print a message and exit with code 1.

    // 8. Exit with code 0.
    li a7, 10
    ecall

#if RENDER
// LED matrix renderer: unfolded net, redrawn after every move of the path.
#endif
