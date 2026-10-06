// RV32I optimal solver for the 2x2x2 cube: IDA* over the factored
// (permutation, orientation) index pair, pruned by two pattern databases.
// ida.c is the reference this file follows.
//
// Built through the C preprocessor (make iret / make asm): STATE becomes the
// 14-character input string and RENDER selects the LED build. Use // comments
// so a comment can never be read as a preprocessor directive.

#include "tables.s"

.data
state:  .string STATE
p: .zero 7
o: .zero 7
s: .zero 7

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
    mv a0, s9
    li a7, 1
    ecall

    // 4. IDA* outer loop: bound from h(root) up to 11.
    //    ida.c: solve

    // 5. One bounded depth-first pass with the explicit stack.
    //    ida.c: search
    //    Per child: same-face skip, one quarter turn (from parent or from the
    //    previous sibling), goal test, heuristic, prune, push.
    //    TODO (design): which values live in registers for the whole search
    //    (g, bound, table base addresses, ...)?
    //    TODO (design): how do you get the perm_move / ori_move table for a
    //    face without multiplying by the table size?

    // 6. Print the path as move names separated by spaces, then a newline.

    // 7. Gate T5: replay the path with the move tables and check that it
    //    reaches (0, 0). On failure print a message and exit with code 1.

    // 8. Exit with code 0.
    li a7, 10
    ecall

#if RENDER
// LED matrix renderer: unfolded net, redrawn after every move of the path.
#endif
