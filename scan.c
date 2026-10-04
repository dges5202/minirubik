/* Host gates against an exact BFS distance table.
 *
 * H1: the heuristic never exceeds the true distance, over every state.
 * Then, over every state at one distance (default 11), or over all states
 * with "all" (gate H3), the IDA* in ida.c must return a path of exactly the
 * BFS length which replays to solved. The largest node count is the worst
 * case the RV32I instruction budget has to cover.
 *
 * ida.c is reused unchanged; its main is renamed out of the way.
 */
#define main ida_main
#include "ida.c"
#undef main

#include <stdlib.h>

enum { NPERM = 5040, NORI = 729, NSTATES = NPERM * NORI, UNSEEN = 0xFF };
enum { TOP = 5 };

static uint8_t dist[NSTATES];
static uint32_t queue[NSTATES];

static void bfs(void)
{
    unsigned head = 0, tail = 0;
    memset(dist, UNSEEN, sizeof dist);
    dist[0] = 0;
    queue[tail++] = 0;
    while (head < tail) {
        uint32_t x = queue[head++];
        for (unsigned m = 0; m < MOVES; ++m) {
            unsigned cp = x / NORI, co = x % NORI;
            apply_move(&cp, &co, m);
            uint32_t y = cp * NORI + co;
            if (dist[y] == UNSEEN) {
                dist[y] = (uint8_t) (dist[x] + 1);
                queue[tail++] = y;
            }
        }
    }
}

static void unrank_perm(unsigned r, uint8_t p[CUBIES])
{
    static const unsigned fact[CUBIES] = {720, 120, 24, 6, 2, 1, 1};
    uint8_t avail[CUBIES] = {0, 1, 2, 3, 4, 5, 6};
    for (unsigned i = 0; i < CUBIES; ++i) {
        unsigned q = r / fact[i];
        r %= fact[i];
        p[i] = avail[q];
        for (unsigned j = q; j + 1 < CUBIES - i; ++j)
            avail[j] = avail[j + 1];
    }
}

static void unrank_ori(unsigned r, uint8_t o[CUBIES])
{
    unsigned sum = 0;
    for (unsigned i = CUBIES - 1; i-- > 0;) {
        o[i] = (uint8_t) (r % 3);
        sum += o[i];
        r /= 3;
    }
    o[CUBIES - 1] = (uint8_t) ((3 - sum % 3) % 3);
}

static void format_state(const state_t *s, char out[2 * CUBIES + 1])
{
    for (unsigned i = 0; i < CUBIES; ++i) {
        out[i] = (char) ('1' + s->p[i]);
        out[CUBIES + i] = (char) ('1' + s->o[i]);
    }
    out[2 * CUBIES] = '\0';
}

/* Gate H1: h(s) <= d(s) on every state. Also reports how tight h is. */
static int check_admissible(void)
{
    unsigned long sum_h = 0, sum_d = 0, exact = 0;
    for (unsigned x = 0; x < NSTATES; ++x) {
        unsigned h = heuristic(x / NORI, x % NORI);
        if (h > dist[x]) {
            fprintf(stderr, "H1 fails at index %u: h %u > d %u\n", x, h,
                    dist[x]);
            return 0;
        }
        sum_h += h;
        sum_d += dist[x];
        exact += h == dist[x];
    }
    printf("\nH1: h <= d on all %d states; mean h %.3f, mean d %.3f, "
           "h == d on %lu\n",
           NSTATES, (double) sum_h / NSTATES, (double) sum_d / NSTATES, exact);
    return 1;
}

int main(int argc, char **argv)
{
    /* "all" runs gate H3 over every state; a number scans one distance. */
    int all = argc == 2 && strcmp(argv[1], "all") == 0;
    int want = argc > 1 && !all ? atoi(argv[1]) : MAX_DEPTH;
    if (argc > 2 || (!all && (want < 1 || want > MAX_DEPTH))) {
        fprintf(stderr, "usage: %s [all | distance 1..%d]\n", argv[0],
                MAX_DEPTH);
        return 2;
    }

    bfs();
    unsigned long hist[MAX_DEPTH + 1] = {0};
    for (unsigned x = 0; x < NSTATES; ++x) {
        if (dist[x] > MAX_DEPTH) {
            fprintf(stderr, "state %u unreached or beyond %d\n", x, MAX_DEPTH);
            return 1;
        }
        ++hist[dist[x]];
    }
    printf("BFS distance histogram (HTM):\n");
    for (int d = 0; d <= MAX_DEPTH; ++d)
        printf("  %2d: %lu\n", d, hist[d]);

    if (!check_admissible())
        return 1;

    unsigned long count = 0, sum = 0, min = (unsigned long) -1;
    unsigned long top_nodes[TOP] = {0};
    char top_state[TOP][2 * CUBIES + 1] = {{0}};
    unsigned long max_at[MAX_DEPTH + 1] = {0};

    for (unsigned x = 0; x < NSTATES; ++x) {
        if (!all && dist[x] != want)
            continue;
        int d = dist[x];
        unsigned pi = x / NORI, oi = x % NORI;
        state_t s;
        unrank_perm(pi, s.p);
        unrank_ori(oi, s.o);

        memset(nodes_at_bound, 0, sizeof nodes_at_bound);
        nodes_total = 0;
        uint8_t path[MAX_DEPTH];
        int len = solve(pi, oi, path);

        char name[2 * CUBIES + 1];
        format_state(&s, name);
        if (len != d || !replay_solves(s, path, len)) {
            fprintf(stderr, "%s: got length %d, expected %d\n", name, len, d);
            return 1;
        }

        ++count;
        sum += nodes_total;
        if (nodes_total > max_at[d])
            max_at[d] = nodes_total;
        if (nodes_total < min)
            min = nodes_total;
        for (unsigned k = 0; k < TOP; ++k) {
            if (nodes_total <= top_nodes[k])
                continue;
            for (unsigned j = TOP - 1; j > k; --j) {
                top_nodes[j] = top_nodes[j - 1];
                memcpy(top_state[j], top_state[j - 1], sizeof top_state[j]);
            }
            top_nodes[k] = nodes_total;
            memcpy(top_state[k], name, sizeof name);
            break;
        }
    }

    if (all) {
        printf("\nH3: all %lu states solved optimally\n", count);
        printf("max nodes per distance:\n");
        for (int d = 0; d <= MAX_DEPTH; ++d)
            printf("  %2d: %lu\n", d, max_at[d]);
    } else {
        printf("\n%lu states at distance %d, all solved optimally\n", count,
               want);
    }
    printf("nodes per query: min %lu, mean %.0f, max %lu\n", min,
           (double) sum / (double) count, top_nodes[0]);
    printf("hardest states:\n");
    for (unsigned k = 0; k < TOP && top_nodes[k]; ++k)
        printf("  %s  %lu nodes\n", top_state[k], top_nodes[k]);
    return 0;
}
