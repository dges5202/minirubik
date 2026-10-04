/* Host-side generator for the RV32I solver's read-only data.
 *
 * Builds the factored quarter-turn transition tables and two pattern
 * databases (permutation-only and orientation-only distances to solved),
 * checks them, and writes them out as C (tables.h) and Ripes assembly
 * (tables.s).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    CUBIES = 7,
    NPERM = 5040,
    NORI = 729,
    FACES = 3,
    UNSEEN = 0xFF,
};

typedef struct {
    uint8_t p[CUBIES], o[CUBIES];
} state_t;

/* Same cube model as solver.c. */
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

static uint16_t perm_move[FACES][NPERM];
static uint16_t ori_move[FACES][NORI];
static uint8_t perm_dist[NPERM];
static uint8_t ori_dist[NORI];

static state_t quarter_turn(const state_t *s, unsigned face)
{
    state_t r;
    for (unsigned i = 0; i < CUBIES; ++i) {
        unsigned from = source[face][i];
        r.p[i] = s->p[from];
        r.o[i] = (uint8_t) ((s->o[from] + twist[face][i]) % 3);
    }
    return r;
}

/* Lehmer code: 0 .. 5039, solved permutation is 0. */
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

/* First six twists in base 3: 0 .. 728. The seventh is implied. */
static unsigned rank_ori(const uint8_t o[CUBIES])
{
    unsigned r = 0;
    for (unsigned i = 0; i < CUBIES - 1; ++i)
        r = r * 3 + o[i];
    return r;
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

static void build_moves(void)
{
    state_t s;
    memset(&s, 0, sizeof s);
    for (unsigned r = 0; r < NPERM; ++r) {
        unrank_perm(r, s.p);
        for (unsigned f = 0; f < FACES; ++f) {
            state_t t = quarter_turn(&s, f);
            perm_move[f][r] = (uint16_t) rank_perm(t.p);
        }
    }
    for (unsigned r = 0; r < NORI; ++r) {
        unrank_ori(r, s.o);
        for (unsigned f = 0; f < FACES; ++f) {
            state_t t = quarter_turn(&s, f);
            ori_move[f][r] = (uint16_t) rank_ori(t.o);
        }
    }
}

/* Four quarter turns of one face must be the identity on every index. */
static int check_moves(const uint16_t *move, unsigned n, const char *name)
{
    for (unsigned f = 0; f < FACES; ++f)
        for (unsigned x = 0; x < n; ++x) {
            unsigned y = x;
            for (unsigned t = 0; t < 4; ++t)
                y = move[f * n + y];
            if (y != x) {
                fprintf(stderr, "%s: face %u is not of order 4 at %u\n", name,
                        f, x);
                return 0;
            }
        }
    return 1;
}

/* Breadth-first search from index 0 (solved) over one factored coordinate.
 * move[face * n + x] is the index reached from x by one quarter turn of face.
 * Returns how many indices were reached.
 */
static unsigned bfs(const uint16_t *move, unsigned n, uint8_t *dist)
{
    uint16_t queue[NPERM];
    unsigned head = 0, tail = 0;

    memset(dist, UNSEEN, n);
    dist[0] = 0;
    queue[tail++] = 0;
    while (head < tail) {
        unsigned x = queue[head++];
        for (unsigned face = 0; face < FACES; ++face) {
            unsigned y = x;
            for (unsigned turn = 0; turn < 3; ++turn) {
                y = move[face * n + y];
                /* TODO 1: if y has not been seen yet, record its distance
                 * and append it to the queue.
                 */
                 if (dist[y] == UNSEEN) 
                 {
                    dist[y] = dist[x] + 1;
                    queue[tail++] = y;
                 }
            }
        }
    }
    return tail;
}

/* Gate H2: fully populated, solved entry is 0 and is the only 0. */
static int check_dist(const uint8_t *dist, unsigned n, unsigned reached,
                      const char *name)
{
    unsigned count[16] = {0}, max = 0;

    if (reached != n) {
        fprintf(stderr, "%s: reached %u of %u entries\n", name, reached, n);
        return 0;
    }
    for (unsigned i = 0; i < n; ++i) {
        if (dist[i] >= 16) {
            fprintf(stderr, "%s: entry %u is %u\n", name, i, dist[i]);
            return 0;
        }
        ++count[dist[i]];
        if (dist[i] > max)
            max = dist[i];
    }
    if (dist[0] != 0 || count[0] != 1) {
        fprintf(stderr, "%s: solved entry is not the unique 0\n", name);
        return 0;
    }
    fprintf(stderr, "%s: %u entries, max %u\n", name, n, max);
    for (unsigned d = 0; d <= max; ++d)
        fprintf(stderr, "  distance %2u: %5u\n", d, count[d]);
    return 1;
}

static void emit_c_u16(FILE *f, const char *name, const uint16_t *v,
                       unsigned rows, unsigned n)
{
    fprintf(f, "static const uint16_t %s[%u][%u] = {\n", name, rows, n);
    for (unsigned r = 0; r < rows; ++r) {
        fputs("    {", f);
        for (unsigned i = 0; i < n; ++i)
            fprintf(f, "%s%u", i ? (i % 12 ? ", " : ",\n     ") : "",
                    v[r * n + i]);
        fputs("},\n", f);
    }
    fputs("};\n", f);
}

static void emit_c_u8(FILE *f, const char *name, const uint8_t *v, unsigned n)
{
    fprintf(f, "static const uint8_t %s[%u] = {\n    ", name, n);
    for (unsigned i = 0; i < n; ++i)
        fprintf(f, "%s%u", i ? (i % 16 ? ", " : ",\n    ") : "", v[i]);
    fputs("\n};\n", f);
}

static void emit_s(FILE *f, const char *label, const char *directive,
                   const void *v, unsigned width, unsigned n)
{
    fprintf(f, "%s:\n", label);
    for (unsigned i = 0; i < n; ++i) {
        unsigned x = width == 2 ? ((const uint16_t *) v)[i]
                                : ((const uint8_t *) v)[i];
        if (i % 16 == 0)
            fprintf(f, "%s    %s %u", i ? "\n" : "", directive, x);
        else
            fprintf(f, ", %u", x);
    }
    fputc('\n', f);
}

static int write_tables(void)
{
    static const char *const face_names[FACES] = {"r", "b", "d"};
    FILE *h = fopen("tables.h", "w"), *s = fopen("tables.s", "w");
    char label[32];

    if (!h || !s) {
        perror("tables");
        return 0;
    }

    fputs("/* Generated by gen_tables.c. Do not edit. */\n", h);
    emit_c_u16(h, "perm_move", &perm_move[0][0], FACES, NPERM);
    emit_c_u16(h, "ori_move", &ori_move[0][0], FACES, NORI);
    emit_c_u8(h, "perm_dist", perm_dist, NPERM);
    emit_c_u8(h, "ori_dist", ori_dist, NORI);

    /* Halfword tables first so they stay 2-byte aligned. */
    fputs("# Generated by gen_tables.c. Do not edit.\n.data\n", s);
    for (unsigned f = 0; f < FACES; ++f) {
        snprintf(label, sizeof label, "perm_move_%s", face_names[f]);
        emit_s(s, label, ".half", perm_move[f], 2, NPERM);
    }
    for (unsigned f = 0; f < FACES; ++f) {
        snprintf(label, sizeof label, "ori_move_%s", face_names[f]);
        emit_s(s, label, ".half", ori_move[f], 2, NORI);
    }
    emit_s(s, "perm_dist", ".byte", perm_dist, 1, NPERM);
    emit_s(s, "ori_dist", ".byte", ori_dist, 1, NORI);

    return fclose(h) == 0 && fclose(s) == 0;
}

int main(void)
{
    build_moves();
    if (!check_moves(&perm_move[0][0], NPERM, "perm_move") ||
        !check_moves(&ori_move[0][0], NORI, "ori_move"))
        return 1;

    unsigned reached = bfs(&perm_move[0][0], NPERM, perm_dist);
    if (!check_dist(perm_dist, NPERM, reached, "perm_dist"))
        return 1;
    reached = bfs(&ori_move[0][0], NORI, ori_dist);
    if (!check_dist(ori_dist, NORI, reached, "ori_dist"))
        return 1;

    if (!write_tables())
        return 1;
    fprintf(stderr, "tables: %zu bytes total\n",
            sizeof perm_move + sizeof ori_move + sizeof perm_dist +
                sizeof ori_dist);
    return 0;
}
