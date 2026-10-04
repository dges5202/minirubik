/* Host reference for the RV32I solver.
 *
 * IDA* over the factored (permutation, orientation) index pair, pruned by the
 * pattern databases from gen_tables.c. The search obeys the target's rules:
 * no heap, no recursion, no multiply or divide. Parsing and the one-off rank
 * of the input still use host arithmetic.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "tables.h"

enum { CUBIES = 7, FACES = 3, MOVES = 9, MAX_DEPTH = 11 };

typedef struct {
    uint8_t p[CUBIES], o[CUBIES];
} state_t;

static const char *const move_names[MOVES] = {"R",  "R2", "R'", "B", "B2",
                                              "B'", "D",  "D2", "D'"};
static const uint8_t face_of[MOVES] = {0, 0, 0, 1, 1, 1, 2, 2, 2};
static const uint8_t turns_of[MOVES] = {1, 2, 3, 1, 2, 3, 1, 2, 3};

/* Independent cube model, used only to validate returned paths. */
static const uint8_t source[FACES][CUBIES] = {
    {1, 4, 2, 0, 3, 5, 6},
    {0, 1, 2, 4, 5, 6, 3},
    {0, 2, 5, 3, 1, 4, 6},
};
static const uint8_t twist[FACES][CUBIES] = {
    {1, 2, 0, 2, 1, 0, 0},
    {0, 0, 0, 1, 2, 1, 2},
    {0, 0, 0, 0, 0, 0, 0},
};

/* Children generated, per bound and in total. */
static unsigned long nodes_at_bound[MAX_DEPTH + 1], nodes_total;

static unsigned heuristic(unsigned pi, unsigned oi)
{
    /* TODO 2: combine perm_dist[pi] and ori_dist[oi] into one lower bound
     * that never exceeds the true distance. Returning 0 is admissible but
     * prunes nothing.
     */

    return (perm_dist[pi] > ori_dist[oi]) ? perm_dist[pi] : ori_dist[oi];
    
     
    (void) pi;
    (void) oi;
    return 0;
}

static void apply_move(unsigned *pi, unsigned *oi, unsigned m)
{
    unsigned f = face_of[m];
    for (unsigned t = 0; t < turns_of[m]; ++t) {
        *pi = perm_move[f][*pi];
        *oi = ori_move[f][*oi];
    }
}

/* One depth-first pass limited to `bound` moves. Written as a loop over an
 * explicit per-depth stack so it maps onto RV32I without recursion.
 * Returns the solution length, or -1 if none fits within bound.
 */
static int search(unsigned pi0, unsigned oi0, unsigned bound,
                  uint8_t path[MAX_DEPTH])
{
    unsigned pi[MAX_DEPTH + 1], oi[MAX_DEPTH + 1];
    uint8_t next[MAX_DEPTH + 1]; /* next move to try at each depth */
    unsigned g = 0;

    pi[0] = pi0;
    oi[0] = oi0;
    next[0] = 0;
    for (;;) {
        if (next[g] == MOVES) {
            if (g == 0)
                return -1;
            --g;
            continue;
        }
        unsigned m = next[g]++;

        /* TODO 3: skip m if it turns the same face as the move that led
         * here, path[g - 1]. The root (g == 0) has no previous move.
         */
        if(g > 0 && face_of[m] == face_of[path[g - 1]])
        {
            continue;
        } 

        unsigned cp = pi[g], co = oi[g];
        apply_move(&cp, &co, m);
        ++nodes_at_bound[bound];
        unsigned h = heuristic(cp, co);
        path[g] = (uint8_t) m;

        /* TODO 4: goal test. How do you recognise the solved state from
         * (cp, co), or from h? What should be returned?
         */
        if(cp == 0 && co == 0)
        {
            return g + 1; 
        }
        /* TODO 5: prune. The child is at depth g + 1 and needs at least h
         * more moves. Skip it if that cannot fit within bound.
         */
        if(g + 1 + h > bound)
        {
            continue;
        }

        if (g + 1 >= MAX_DEPTH) /* array guard until TODO 5 is filled */
            continue;
        pi[g + 1] = cp;
        oi[g + 1] = co;
        next[g + 1] = 0;
        ++g;
    }
}

static int solve(unsigned pi, unsigned oi, uint8_t path[MAX_DEPTH])
{
    if (pi == 0 && oi == 0)
        return 0;

    /* TODO 6: where should the bound start, and why is it safe to stop
     * after MAX_DEPTH? Starting at 1 is correct but wastes passes.
     */
     
    for (unsigned bound = heuristic(pi, oi); bound <= MAX_DEPTH; ++bound) {
        int len = search(pi, oi, bound, path);
        nodes_total += nodes_at_bound[bound];
        if (len >= 0)
            return len;
    }
    return -1;
}

static int parse_state(const char *in, state_t *s)
{
    unsigned seen = 0, sum = 0;
    for (unsigned i = 0; i < 2 * CUBIES; ++i) {
        unsigned limit = i < CUBIES ? CUBIES : 3;
        if (in[i] < '1' || (unsigned) (in[i] - '0') > limit)
            return 0;
        unsigned v = (unsigned) (in[i] - '1');
        if (i < CUBIES) {
            if (seen & (1U << v))
                return 0;
            seen |= 1U << v;
            s->p[i] = (uint8_t) v;
        } else {
            sum += v;
            s->o[i - CUBIES] = (uint8_t) v;
        }
    }
    return in[2 * CUBIES] == '\0' && sum % 3 == 0;
}

/* TODO 7: these run once per query. On RV32I the multiplies by 7..1 and by
 * 3 have to become shifts and adds; work out each sequence.
 */
static unsigned rank_perm(const uint8_t p[CUBIES])
{
    unsigned r = 0;
    for (unsigned i = 0; i < CUBIES; ++i) {
        unsigned smaller = 0;
        for (unsigned j = i + 1; j < CUBIES; ++j)
            smaller += p[j] < p[i];
        r = r * (CUBIES - i) + smaller;
    }
    return r;
}

static unsigned rank_ori(const uint8_t o[CUBIES])
{
    unsigned r = 0;
    for (unsigned i = 0; i < CUBIES - 1; ++i)
        r = r * 3 + o[i];
    return r;
}

/* Gate T5 on the host: replay the path on the full model. */
static int replay_solves(state_t s, const uint8_t *path, int len)
{
    for (int k = 0; k < len; ++k)
        for (unsigned t = 0; t < turns_of[path[k]]; ++t) {
            state_t r;
            unsigned f = face_of[path[k]];
            for (unsigned i = 0; i < CUBIES; ++i) {
                r.p[i] = s.p[source[f][i]];
                r.o[i] = (uint8_t) ((s.o[source[f][i]] + twist[f][i]) % 3);
            }
            s = r;
        }
    for (unsigned i = 0; i < CUBIES; ++i)
        if (s.p[i] != i || s.o[i] != 0)
            return 0;
    return 1;
}

int main(int argc, char **argv)
{
    state_t s;
    uint8_t path[MAX_DEPTH];

    if (argc != 2 || !parse_state(argv[1], &s)) {
        fprintf(stderr, "usage: %s PPPPPPPOOOOOOO\n", argv[0]);
        return 2;
    }
    unsigned pi = rank_perm(s.p), oi = rank_ori(s.o);
    int len = solve(pi, oi, path);
    if (len < 0) {
        fputs("no solution within 11 moves\n", stderr);
        return 1;
    }
    for (int k = 0; k < len; ++k)
        printf("%s%s", k ? " " : "", move_names[path[k]]);
    putchar('\n');

    for (unsigned b = 0; b <= MAX_DEPTH; ++b)
        if (nodes_at_bound[b])
            fprintf(stderr, "bound %2u: %lu nodes\n", b, nodes_at_bound[b]);
    fprintf(stderr, "total: %lu nodes, length %d\n", nodes_total, len);

    if (!replay_solves(s, path, len)) {
        fputs("returned path does not solve the cube\n", stderr);
        return 1;
    }
    return 0;
}
