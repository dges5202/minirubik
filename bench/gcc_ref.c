/* gcc reference build of the C algorithm, for comparison with rubik.S
 * (riscv64-unknown-elf-gcc -O2 -march=rv32i -mabi=ilp32, run on Ripes).
 *
 * build/ida_core.c is ida.c with main and the node counters removed (see the
 * Makefile), so the search and the ranks are exactly ida.c's. This file adds
 * what rubik.S does around them without libc: parse STATE, solve, print the
 * moves through Ripes ecalls, exit through ecall 93. Like rubik.S it does no
 * input validation; unlike rubik.S it does not replay the path (gate T5).
 */
#include "ida_core.c"

static const char in[] = STATE;

static void put_char(int c)
{
    register int a0 asm("a0") = c;
    register int a7 asm("a7") = 11;
    asm volatile("ecall" : : "r"(a0), "r"(a7));
}

int main(void)
{
    state_t s;
    uint8_t path[MAX_DEPTH];
    for (unsigned i = 0; i < CUBIES; ++i) {
        s.p[i] = (uint8_t) (in[i] - '1');
        s.o[i] = (uint8_t) (in[CUBIES + i] - '1');
    }
    int len = solve(rank_perm(s.p), rank_ori(s.o), path);
    for (int k = 0; k < len; ++k) {
        const char *n = move_names[path[k]];
        if (k)
            put_char(' ');
        while (*n)
            put_char(*n++);
    }
    put_char('\n');
    return 0;
}

/* No crt0: Ripes starts at the ELF entry with sp already set. */
void __attribute__((naked)) _start(void)
{
    asm volatile("call main\n\tli a7, 93\n\tecall");
}
