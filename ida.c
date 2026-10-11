/* Host reference for the RV32I solver.
 *
 * IDA* over the factored (permutation, orientation) index pair, pruned by the
 * pattern databases from gen_tables.c. A third index, cubies 0, 3, 6 with
 * their twists, is carried along only for its pattern database. The search and the rank of the input
 * obey the target's rules: no heap, no recursion, no multiply or divide.
 * Only parsing and the host-side checks still use host arithmetic.
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
/* The three turns of each face must stay adjacent and in the order 1, 2, 3:
 * search() derives each sibling from the previous one by one more turn.
 */
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

/* Each table is an exact distance in an abstraction, so each is admissible,
 * and so is their max. Their sum is not: one move changes all at once.
 * Each table is zero only at its solved index, so h == 0 iff solved.
 */
static unsigned heuristic(unsigned pi, unsigned oi, unsigned ci)
{
    unsigned h = perm_dist[pi];
    if (ori_dist[oi] > h)
        h = ori_dist[oi];
    if (c3_dist[ci] > h)
        h = c3_dist[ci];
    return h;
}

/* One depth-first pass limited to `bound` moves. Written as a loop over an
 * explicit per-depth stack so it maps onto RV32I without recursion.
 * Returns the solution length, or -1 if none fits within bound.
 */
static int search(unsigned pi0, unsigned oi0, unsigned ci0, unsigned bound,
                  uint8_t path[MAX_DEPTH])
{
    unsigned pi[MAX_DEPTH + 1], oi[MAX_DEPTH + 1], ci[MAX_DEPTH + 1];
    uint8_t next[MAX_DEPTH + 1]; /* next move to try at each depth */
    unsigned g = 0;

    pi[0] = pi0;
    oi[0] = oi0;
    ci[0] = ci0;
    next[0] = 0;
    for (;;) {
        if (next[g] == MOVES) {
            if (g == 0)
                return -1;
            --g;
            continue;
        }
        unsigned m = next[g]++;

        /* Two turns of the same face in a row merge or cancel. Moves are
         * tried in order, so m is the face's first turn here: skip all
         * three at once. The sibling chain below then never starts from a
         * stale entry.
         */
        if (g > 0 && face_of[m] == face_of[path[g - 1]]) {
            next[g] += 2;
            continue;
        }

        /* pi[g + 1] holds the previous sibling: deeper levels only write
         * from pi[g + 2] on. Each child then costs one quarter turn.
         */
        unsigned from = turns_of[m] == 1 ? g : g + 1;
        unsigned cp = perm_move[face_of[m]][pi[from]];
        unsigned co = ori_move[face_of[m]][oi[from]];
        pi[g + 1] = cp;
        oi[g + 1] = co;
        path[g] = (uint8_t) m;
        ++nodes_at_bound[bound];

        if (cp == 0 && co == 0)
            return (int) g + 1;

        /* max(hp, ho, hc) > r iff one of them is, so each table prunes on
         * its own. A child kept here is unsolved, so hp or ho >= 1 and
         * g + 1 < bound <= 11: the stack never grows past MAX_DEPTH and
         * needs no guard.
         */
        unsigned r = bound - g - 1;
        if (perm_dist[cp] > r || ori_dist[co] > r)
            continue;

        /* ci is not chained through siblings: a pruned sibling never
         * computes its cc. Only children that survive the first two tables
         * turn the parent's ci[g] turns_of[m] times, and only a pushed
         * child, whose children read it, stores ci[g + 1].
         */
        unsigned cc = ci[g];
        for (unsigned t = 0; t < turns_of[m]; ++t)
            cc = c3_move[face_of[m]][cc];
        if (c3_dist[cc] > r)
            continue;

        ci[g + 1] = cc;
        next[g + 1] = 0;
        ++g;
    }
}

static int solve(unsigned pi, unsigned oi, unsigned ci,
                 uint8_t path[MAX_DEPTH])
{
    if (pi == 0 && oi == 0)
        return 0;

    /* h never overestimates, so no bound below h(root) can succeed, and
     * the first bound that does is the optimal length. The diameter is 11,
     * so a valid state always succeeds by MAX_DEPTH.
     */
    for (unsigned bound = heuristic(pi, oi, ci); bound <= MAX_DEPTH; ++bound) {
        int len = search(pi, oi, ci, bound, path);
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

/* Lehmer code in mixed radix 7, 6, ..., 1, with each multiply unrolled into
 * shifts and adds since RV32I has none. These run once per query, so
 * clarity matters more than their few instructions.
 */
static unsigned rank_perm(const uint8_t p[CUBIES])
{
    unsigned s[CUBIES - 1]; /* the last digit is always 0 */
    for (unsigned i = 0; i < CUBIES - 1; ++i) {
        unsigned smaller = 0;
        for (unsigned j = i + 1; j < CUBIES; ++j)
            smaller += p[j] < p[i];
        s[i] = smaller;
    }

    unsigned r = s[0];
    r = (r << 2) + (r << 1) + s[1]; /* x6 */
    r = (r << 2) + r + s[2];        /* x5 */
    r = (r << 2) + s[3];            /* x4 */
    r = (r << 1) + r + s[4];        /* x3 */
    r = (r << 1) + s[5];            /* x2 */
    return r;
}

/* Base 3 over the first six orientations; the seventh is implied. */
static unsigned rank_ori(const uint8_t o[CUBIES])
{
    unsigned r = 0;
    for (unsigned i = 0; i < CUBIES - 1; ++i)
        r = (r << 1) + r + o[i];
    return r;
}

/* c3_pos[a*49 + b*7 + c] is rank_pos3(a, b, c) * 27 for cubies 0, 3, 6 at
 * positions a, b, c, so only their twists are added here.
 */
static unsigned rank_c3(const uint8_t p[CUBIES], const uint8_t o[CUBIES])
{
    unsigned a = 0, b = 0, c = 0;
    for (unsigned i = 0; i < CUBIES; ++i) {
        if (p[i] == 0)
            a = i;
        if (p[i] == 3)
            b = i;
        if (p[i] == 6)
            c = i;
    }
    unsigned idx = (a << 5) + (a << 4) + a + (b << 3) - b + c; /* x49, x7 */
    unsigned tw = (o[a] << 3) + o[a] + (o[b] << 1) + o[b] + o[c]; /* x9, x3 */
    return c3_pos[0][idx] + tw;
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
    unsigned pi = rank_perm(s.p), oi = rank_ori(s.o), ci = rank_c3(s.p, s.o);
    int len = solve(pi, oi, ci, path);
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
