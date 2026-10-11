/* Host-side generator for the RV32I solver's read-only data.
 *
 * Builds the factored quarter-turn transition tables and three pattern
 * databases (permutation-only, orientation-only, and the positions and
 * twists of cubies 0, 3, 6), checks them, and writes them out as C
 * (tables.h) and Ripes assembly (tables.s).
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum {
    CUBIES = 7,
    NPERM = 5040,
    NORI = 729,
    /* Cubies 0, 3, 6 with the fixed cubie 7 make up the U face: their
     * positions (7 * 6 * 5 = 210 ordered triples) times their twists (27).
     */
    NC3 = 210 * 27,
    FACES = 3,
    UNSEEN = 0xFF,
    /* Byte distance between consecutive faces' tables in tables.s. Powers
     * of two, so the assembly reaches face f's table with one shift.
     * C3_STRIDE equals PERM_STRIDE, so both share face << 14.
     */
    PERM_STRIDE = 1 << 14,
    ORI_STRIDE = 1 << 11,
    C3_STRIDE = 1 << 14,
    QUEUE = NC3 > NPERM ? NC3 : NPERM,
};

_Static_assert(PERM_STRIDE >= 2 * NPERM, "perm_move stride too small");
_Static_assert(ORI_STRIDE >= 2 * NORI, "ori_move stride too small");
_Static_assert(C3_STRIDE >= 2 * NC3, "c3_move stride too small");

/* The three cubies the third table follows, in index order. */
static const uint8_t c3_cubie[3] = {0, 3, 6};

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
static uint16_t c3_move[FACES][NC3];
static uint8_t c3_dist[NC3];
/* c3_pos[a * 49 + b * 7 + c] = rank_pos3(a, b, c) * 27, the position part of
 * the root's index, for the assembly. Unused entries (a repeated position)
 * are 0xFFFF and never read.
 */
static uint16_t c3_pos[343];

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

/* Rank of three distinct positions a, b, c (each 0 .. 6) as 0 .. 209, where
 * a, b, c are where cubies 0, 3, 6 are. The solved triple (0, 3, 6) must
 * rank 0, so that bfs() starts from the solved index.
 */
static unsigned rank_pos3(unsigned a, unsigned b, unsigned c)
{
    /* TODO 2:
     * 1. Relabel the positions so the solved triple becomes (0, 1, 2):
     *    0 -> 0, 3 -> 1, 6 -> 2, and the rest (1, 2, 4, 5) -> 3, 4, 5, 6.
     * 2. Rank the relabeled (a, b, c) the way you count the choices:
     *    a has 7 choices, b has 6 left, c has 5 left. Before multiplying,
     *    b and c must be shifted down past the positions already used.
     */
     static const unsigned rel[7] = {0, 3, 4, 1, 5, 6, 2};
     a = rel[a];
     b = rel[b];
     c = rel[c];

     if (a < b)
     {
        b--;
     }
     if (a < c)
     {
        c--;
     }
     if (b < c)
     {
        c--;
     }

    return a * 30 + b * 5 + c;
}

/* Index of the third coordinate: rank_pos3(...) * 27 + the three twists in
 * base 3, so solved is 0. 0 .. NC3 - 1.
 */
static unsigned rank_c3(const state_t *s)
{
    /* TODO 3:
     * 1. p[i] is the cubie at position i. Find pos[k], the position of
     *    cubie c3_cubie[k], for k = 0, 1, 2.
     * 2. The twist of that cubie is o[pos[k]].
     * 3. Combine them into the index described above.
     */
     unsigned pos[3];
     for (unsigned i = 0; i < CUBIES; ++i)
     {
        for (unsigned j = 0; j < 3; ++j)
        {
            if (s->p[i] == c3_cubie[j])
            {
                pos[j] = i;
                break;
            }
        }
     }
     unsigned tw = s->o[pos[0]] * 9 + s->o[pos[1]] * 3 + s->o[pos[2]];
     return rank_pos3(pos[0], pos[1], pos[2]) * 27 + tw;
}

/* Every index from a state with cubies 0, 3, 6 at a, b, c and twists tw;
 * the other positions get the remaining cubies, twist 0 (the third table
 * never reads them).
 */
static void build_c3_moves(void)
{
    for (unsigned a = 0; a < CUBIES; ++a)
        for (unsigned b = 0; b < CUBIES; ++b)
            for (unsigned c = 0; c < CUBIES; ++c) {
                c3_pos[a * 49 + b * 7 + c] = 0xFFFF;
                if (a == b || a == c || b == c)
                    continue;
                c3_pos[a * 49 + b * 7 + c] =
                    (uint16_t) (rank_pos3(a, b, c) * 27);
                for (unsigned tw = 0; tw < 27; ++tw) {
                    state_t s;
                    unsigned next = 0;
                    memset(&s, 0, sizeof s);
                    for (unsigned i = 0; i < CUBIES; ++i) {
                        if (i == a || i == b || i == c)
                            continue;
                        while (next == 0 || next == 3 || next == 6)
                            ++next;
                        s.p[i] = (uint8_t) next++;
                    }
                    s.p[a] = c3_cubie[0], s.o[a] = (uint8_t) (tw / 9);
                    s.p[b] = c3_cubie[1], s.o[b] = (uint8_t) (tw / 3 % 3);
                    s.p[c] = c3_cubie[2], s.o[c] = (uint8_t) (tw % 3);
                    unsigned x = rank_c3(&s);
                    for (unsigned f = 0; f < FACES; ++f) {
                        state_t t = quarter_turn(&s, f);
                        c3_move[f][x] = (uint16_t) rank_c3(&t);
                    }
                }
            }
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
    uint16_t queue[QUEUE];
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
    emit_c_u16(h, "c3_move", &c3_move[0][0], FACES, NC3);
    emit_c_u8(h, "c3_dist", c3_dist, NC3);
    emit_c_u16(h, "c3_pos", c3_pos, 1, 343);

    /* Halfword tables first so they stay 2-byte aligned. Face f's table
     * starts at perm_move_r + f * PERM_STRIDE (ori_move_r + f * ORI_STRIDE);
     * the last face needs no padding after it.
     */
    fputs("# Generated by gen_tables.c. Do not edit.\n.data\n", s);
    for (unsigned f = 0; f < FACES; ++f) {
        snprintf(label, sizeof label, "perm_move_%s", face_names[f]);
        emit_s(s, label, ".half", perm_move[f], 2, NPERM);
        if (f + 1 < FACES)
            fprintf(s, "    .zero %u\n", PERM_STRIDE - 2 * NPERM);
    }
    for (unsigned f = 0; f < FACES; ++f) {
        snprintf(label, sizeof label, "ori_move_%s", face_names[f]);
        emit_s(s, label, ".half", ori_move[f], 2, NORI);
        if (f + 1 < FACES)
            fprintf(s, "    .zero %u\n", ORI_STRIDE - 2 * NORI);
    }
    for (unsigned f = 0; f < FACES; ++f) {
        snprintf(label, sizeof label, "c3_move_%s", face_names[f]);
        emit_s(s, label, ".half", c3_move[f], 2, NC3);
        if (f + 1 < FACES)
            fprintf(s, "    .zero %u\n", C3_STRIDE - 2 * NC3);
    }
    emit_s(s, "c3_pos", ".half", c3_pos, 2, 343);
    emit_s(s, "perm_dist", ".byte", perm_dist, 1, NPERM);
    emit_s(s, "ori_dist", ".byte", ori_dist, 1, NORI);
    emit_s(s, "c3_dist", ".byte", c3_dist, 1, NC3);

    return fclose(h) == 0 && fclose(s) == 0;
}

int main(void)
{
    build_moves();
    build_c3_moves();
    if (!check_moves(&perm_move[0][0], NPERM, "perm_move") ||
        !check_moves(&ori_move[0][0], NORI, "ori_move") ||
        !check_moves(&c3_move[0][0], NC3, "c3_move"))
        return 1;

    unsigned reached = bfs(&perm_move[0][0], NPERM, perm_dist);
    if (!check_dist(perm_dist, NPERM, reached, "perm_dist"))
        return 1;
    reached = bfs(&ori_move[0][0], NORI, ori_dist);
    if (!check_dist(ori_dist, NORI, reached, "ori_dist"))
        return 1;
    reached = bfs(&c3_move[0][0], NC3, c3_dist);
    if (!check_dist(c3_dist, NC3, reached, "c3_dist"))
        return 1;

    if (!write_tables())
        return 1;
    fprintf(stderr, "tables: %zu bytes total\n",
            sizeof perm_move + sizeof ori_move + sizeof perm_dist +
                sizeof ori_dist + sizeof c3_move + sizeof c3_dist +
                sizeof c3_pos);
    return 0;
}
