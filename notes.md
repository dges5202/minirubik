# Assignment 1: Optimizations and RISC-V Assembly

## Environment

| Item | Value |
| :--- | :--- |
| Fork | https://github.com/dges5202/minirubik, forked from upstream commit `231796c` |
| Ripes | continuous build `v2.2.6-106-g5b8a616` (2026-08-18), CLI mode |
| Host | AMD Ryzen 7 9800X3D, Linux 6.6 (WSL2) |
| Toolchain | `riscv64-unknown-elf-gcc` (rv32i / ilp32) for the reference build only |

Conventions used throughout: *retired instructions* means Ripes `--iret` on `RV32_ISS`; *cycles* means Ripes `--cycles` on `RV32_5S`; *code size* means bytes of linked `.text` with the renderer compiled out (`make size`, `--no-relax`).

## Stage 1: Characterize the baseline

### What `solver.c` computes

The cube is modelled with one corner (front-upper-left) fixed, so only the R, B and D faces turn and whole-cube rotations disappear. The other seven corners are described by two arrays: `p[i]`, which cubie sits at position `i`, and `o[i]`, its twist (0, 1 or 2).

- Permutations: $7! = 5040$.
- Orientations: every row of the `twist` table sums to a multiple of 3, so $\sum o_i \bmod 3$ is invariant under every move. Six twists are free and the seventh is determined: $3^6 = 729$.
- State space: $5040 \times 729 = 3{,}674{,}160$, equal to $8! \cdot 3^7 / 24$.

A new `p` depends only on the old `p`, and a new `o` only on the old `o` plus a fixed twist, so permutation and orientation evolve independently. This is what makes factored transition tables possible.

On every query the baseline runs a full breadth-first search from the solved state over all 3,674,160 states, records one move toward solved per state, and then follows those moves back from the input. The half-turn-metric diameter is 11.

### Where its cost lies

| Allocation | Bytes |
| :--- | ---: |
| One move toward solved per state | 3,674,160 |
| BFS queue of 32-bit ranks | 14,696,640 |
| Factored quarter-turn transitions | 34,614 |
| Peak | 18,405,414 |

The build visits 33,067,440 edges and performs 66,134,880 transition updates, on the order of $10^9$ instructions on the target.

### Measurement 1: host bytes per guest byte

`bench/fill.s` stores N bytes one word at a time starting at `0x20000000`. Its retired-instruction count is $3N/4 + 5$ (three instructions per word, five outside the loop), which matched `--iret` exactly at every N. `bench/measure.sh` runs each configuration three times; the table shows medians of peak RSS from `/usr/bin/time -v`.

| N (bytes) | Peak RSS (KB) |
| ---: | ---: |
| 4,096 (control) | 32,488 |
| 1,048,576 | 76,364 |
| 4,194,304 | 209,820 |

Slope against the control: **43.0** (1 MiB) and **43.3** (4 MiB) host bytes per guest byte. The two agree, so the growth is linear. This fits one `unordered_map` node per guest byte: a next pointer, a 4-byte key and a 1-byte value padded to about 16 bytes, plus allocator overhead and an 8-byte bucket slot.

Projected onto the baseline's peak: $18{,}405{,}414 \times 43.3 \approx 798$ MB of host memory.

### Measurement 2: simulation rate

Same program, medians of three runs, using the largest N for each model so fixed overhead is negligible.

| Processor | Retired | Model time (ms) | Rate |
| :--- | ---: | ---: | ---: |
| `RV32_ISS` | 3,145,733 | 205 | 15.3 M/s |
| `RV32_5S` | 786,437 | 2,352 | 0.334 M/s |

`RV32_ISS` only executes each instruction's semantics. `RV32_5S` simulates the pipeline hardware every cycle (stage registers, multiplexers, forwarding and hazard units) and pays for stalls and flushes, so it is about 46 times slower.

| Workload | `RV32_ISS` | `RV32_5S` |
| :--- | ---: | ---: |
| Baseline, $10^9$ instructions | ~65 s | ~50 min |
| Budget, $5 \times 10^7$ instructions | ~3.3 s | ~2.5 min |

### Why my numbers differ from the assignment's table

My rates are 14 times (ISS) and 16 times (5S) higher than the table in the assignment. I attribute this mainly to hardware: the 9800X3D has a very large L3 cache, which helps the random accesses of a hash map. The Ripes build and the exact measurement loop may also differ.

This does not change the conclusion. The limits are rules rather than speeds: 128 KiB of static data, no heap, and $5 \times 10^7$ retired instructions. The baseline needs about 20 times the instruction budget, and its distance table alone is 28 times the data budget (still 14 times at 4 bits per state). A faster host moves the absolute times, not those ratios.

### Report section 7: keeping the full table as the verification artifact

On the host the argument holds: building the table takes well under a second, and it gives the exact distance of every state, so any answer can be checked.

On Ripes the same table costs about 798 MB of host memory and about $10^9$ simulated instructions, and it does not fit the rules at all. It is like the difference between training and deploying a neural network: training needs large data, many GPUs and a lot of memory, while deployment only needs the trained weights and far fewer resources.

So verification is split:

- **On the host, exhaustive:** gates H1–H4 check the heuristic and the search against the exact BFS table for every one of the 3,674,160 states (H3 took 3 min 45 s).
- **On the target, per answer:** gate T5 replays the returned path on the full seven-corner model, at most 11 moves and about 4,400 instructions, and checks that it reaches solved (stage 4).

## Stage 2: Representation and algorithm

### Why not BFS on the target

Stage 1 shows that the baseline fails on memory before it fails on time. BFS expands the space one layer at a time, so it must hold the whole frontier, and to answer one query it enumerates all 3,674,160 states: the queue alone is 14.7 MB, more than 100 times the 128 KiB budget. It cannot prune, because it has no notion of how far a state still is from solved. Bidirectional BFS has the same problem.

### IDA*: a depth-limited DFS guided by a lower bound

IDA* is a depth-first search with a move budget `bound`. It keeps only the current path, so its memory is one entry per depth: at most 12 states, independent of the size of the space. Each child at depth $g+1$ is pruned when

$$g + 1 + h(\text{child}) > \text{bound}$$

where $g+1$ is the number of moves already made and $h$ is a lower bound on the moves still needed. Any solution through that child needs at least $g+1+h$ moves, more than this iteration allows, so its whole subtree is skipped. If an iteration finds nothing, `bound` grows by one and the search restarts.

- **Start at $h(\text{root})$**: no solution is shorter than $h(\text{root})$, so smaller bounds cannot succeed.
- **The first bound that succeeds is the optimal length**: every smaller bound has already failed.
- **Stop at 11**: the BFS on the host proves the diameter is 11.

Restarting is cheap. With branching factor about 6, all earlier iterations together cost about $1/(6-1)$ of the last one; for `21345671111111` they cost 34,809 nodes against 158,589 in the last iteration (22%).

### Representation: a factored index pair

Because permutation and orientation evolve independently (stage 1), a state is the pair $(\text{pi}, \text{oi})$ with $\text{pi} \in [0, 5040)$, a Lehmer rank, and $\text{oi} \in [0, 729)$, a base-3 rank of the first six twists. The solved state is $(0, 0)$. A move is two table lookups, so the search never touches the `p[]` and `o[]` arrays.

### Heuristic: two pattern databases

Both tables are exact BFS distances, computed on the host, in an abstraction of the cube:

| Table | Abstraction | Entries | Max |
| :--- | :--- | ---: | ---: |
| `perm_dist` | positions only, twists ignored | 5,040 | 7 |
| `ori_dist` | twists only, positions ignored | 729 | 6 |

**Each table is admissible.** Projecting any solution of the real cube onto an abstraction gives a path of the same length to the abstract goal, so the real distance $d$ is at least the abstract one. Solving the cube means solving both halves.

**Max, not sum.** One move changes the permutation and the orientation at the same time, so the moves counted by the two tables can be the same moves. Adding them double-counts. Counterexample: after a single R, $h_p = 1$ and $h_o = 1$, so the sum is 2 while $d = 1$. Since $h_p \le d$ and $h_o \le d$, $\max(h_p, h_o) \le d$.

**$h = 0$ exactly at solved.** Each table is zero only at its solved index (gate H2), so the root test and the goal test need no extra case.

### Budget check

| Item | Bytes |
| :--- | ---: |
| `perm_move` (3 faces × 5,040 × 2) | 30,240 |
| `ori_move` (3 faces × 729 × 2) | 4,374 |
| `perm_dist` | 5,040 |
| `ori_dist` | 729 |
| Tables total | 40,383 (39.4 KiB) |

That is 31% of 128 KiB. Packing the distance tables into nibbles would cost about five extra instructions on every lookup to save 2.9 KB the program does not need, so I did not pack them.

### Evidence of optimality and cost

Host gates, using `scan.c`, which includes my `ida.c` unchanged:

- **H1**: $h \le d$ for all 3,674,160 states. Mean $h = 5.144$, mean $d = 8.756$; $h = d$ for only 17,108 states (0.47%).
- **H3**: the search returns a solution of exactly the BFS distance for every state. Wall clock 3 min 45 s.

Generated children for `21345671111111`:

| Version | Children | Change |
| :--- | ---: | :--- |
| $h = 0$, bound from 1 | 163,549,338 | – |
| $h = \max(h_p, h_o)$, bound from 1 | 234,015 | about 1/700 |
| bound from $h(\text{root}) = 7$ | 233,961 | −54 |

The heuristic does not make the tree narrower: each iteration still grows by about 6 times. It makes the tree shallower. With $h$ about 5 on average, the search behaves like brute force over roughly $11 - 5$ levels instead of 11.

Search cost varies a lot, so I scanned every distance-11 state:

| Range | States | Min | Mean | Max |
| :--- | ---: | ---: | ---: | ---: |
| distance 11 | 2,644 | 140,895 | 206,618 | **639,792** |
| distance 10 | 623,800 | 18,292 | 48,130 | 250,318 |

The worst case, `54721631111111`, generates 2.7 times as many children as `21345671111111`, so testing only the sample vector would underestimate the cost. The budget then gives

$$\frac{5 \times 10^7}{639{,}792} \approx 78 \text{ instructions per generated child}$$

which is the target for the assembly.

### Weakness

The hardest states have every twist correct (`1111111`). For them `ori_dist` is 0 and $h$ is carried by `perm_dist` alone, at most 7 against a true distance of 11, an underestimate of 4 moves that costs roughly $6^4 \approx 1300$ times. The real difficulty is placing the corners without disturbing their twists, and neither table sees that interaction. A table over positions plus some twists would see it, at the price of a larger table and a costlier index.

## Stage 3: Efficiency in C first

The node count is fixed by the algorithm, so this stage lowers the cost of each generated child. Each change keeps the search exactly the same: `21345671111111` still generates 233,961 children, and H3 still passes.

### Derive each sibling from the previous one

The transition tables store one quarter turn per face. X2 is two quarter turns and X' is three, so computing every child from its parent costs $1 + 2 + 3 = 6$ quarter turns for the three children of one face. But X2 is X turned once more, and X' is X2 turned once more:

```
P+R  = P     turned once
P+R2 = P+R   turned once
P+R' = P+R2  turned once
```

So each child costs exactly one quarter turn, 3 instead of 6 per face, and on average 1 instead of 2 per child. One quarter turn is two table lookups (permutation and orientation), so this removes two lookups per child on average.

```c
unsigned from = turns_of[m] == 1 ? g : g + 1;
unsigned cp = perm_move[face_of[m]][pi[from]];
unsigned co = ori_move[face_of[m]][oi[from]];
pi[g + 1] = cp;
oi[g + 1] = co;
```

Why `pi[g + 1]` still holds the previous sibling: only depth $g$ writes `pi[g + 1]`. Everything below it writes `pi[g + 2]` and deeper, so when the search comes back to depth $g$, `pi[g + 1]` is the last child this level produced.

Three details keep it correct:

- **Store before pruning.** R may be pruned by the bound, but R2 still has to start from R.
- **Same-face pruning skips whole faces.** If R is skipped because the previous move was also R-face, R2 and R' are skipped too, so no sibling ever reads a stale entry.
- **Move order is an invariant.** The three turns of a face must stay adjacent and in the order 1, 2, 3; otherwise `turns_of[m] == 1` no longer means "first of its face".

The node count does not change, because the same children are generated in the same order. Only the work per child goes down, which only `--iret` can show.

### Remove multiplies with shifts and adds

RV32I has no multiply or divide. A `*` in C does not become one instruction: `gcc -march=rv32i` calls the software routine `__mulsi3`, a shift-and-add loop over the bits of the multiplier, which the assignment also forbids. So every multiply has to be written as shifts and adds, or designed away.

- **In the search**, the only scaling is by element size: `.half` tables and arrays need `index << 1`. All strides are powers of two, so no multiply appears.
- **In the ranks**, the mixed-radix Lehmer code is unrolled by Horner's rule, so each step multiplies by a known constant:

```c
unsigned r = s[0];
r = (r << 2) + (r << 1) + s[1]; /* x6 */
r = (r << 2) + r + s[2];        /* x5 */
r = (r << 2) + s[3];            /* x4 */
r = (r << 1) + r + s[4];        /* x3 */
r = (r << 1) + s[5];            /* x2 */
```

The ×7 step disappears because $r = 0$ before it, and $s_6$ is always 0. The orientation rank is base 3, `r = (r << 1) + r + o[i]`.

The ranks run once per query, so the instructions saved there do not matter next to hundreds of thousands of children (Amdahl's law). The point is that the C version, compiled with `-O2 -march=rv32i`, contains no `__mulsi3` call and is a fair reference for the assembly. `scan.c` checks the new ranks by round-tripping all 5,040 permutations and 729 orientations.

## Stage 4: RV32I assembly, version 1

`rubik.S` follows `ida.c` step by step: parse, rank, root test, IDA* with an explicit stack, print, and replay (gate T5).

### Data layout

| Array | Element | Why |
| :--- | :--- | :--- |
| `pi[12]` | `.half` | ranks up to 5,039 do not fit in a byte |
| `oi[12]` | `.half` | ranks up to 728 do not fit in a byte either |
| `next[12]`, `path[11]` | `.byte` | move indices 0–9 |
| `source`, `twist` | `.byte`, rows padded from 7 to 8 | row `f` starts at `f << 3`, no multiply |
| `move_names` | 2 bytes per name | name `m` starts at `m << 1` |

`pi` and `oi` come first in `.data`, before the generated tables. They are accessed with `lhu`/`sh`, and so are the `.half` move tables. Each array is 24 bytes, an even size, so the tables after them stay 2-byte aligned. `tables.s` ends at an odd offset (`ori_dist` is 729 bytes), so placing `pi`/`oi` after it would misalign them. Ripes' ISS happens to accept a misaligned `lhu`, but RV32I allows the hardware to trap on one, so I do not rely on it.

### Recursion without calls

A recursive `search` in assembly would pay a call per node: `jal`, saving `ra` and the locals of this level on the `sp` stack, and restoring them on return. My version keeps the same stack as fixed arrays indexed by the depth `g`:

- `pi[g]`, `oi[g]`: the state at depth `g`;
- `next[g]`: the next move to try at depth `g`;
- `path[g]`: the move taken at depth `g`.

The parent is simply depth `g - 1`, and no return address is needed, because every return goes back to the same place, the top of the loop:

```
search_top:
    if next[g] == 9:              # all moves of this level tried
        if g == 0: goto bound_failed
        g--; goto search_top      # "return"
    m = next[g]++                 # stored back before anything else
    same-face skip, one quarter turn, store pi[g+1], oi[g+1], path[g]
    if (cp | co) == 0: goto found # solved, length g + 1
    if g + 1 + h > bound: goto search_top
    next[g+1] = 0; g++; goto search_top   # "call"
```

The C `return len` becomes two exits: `found` (length `g + 1`) and `bound_failed` (`bound++`, restart). Long-lived values stay in saved registers for the whole search: `bound`, `g`, the constant 9, the root `(pi, oi)`, and the bases of `pi`, `oi`, `next`, `path`, `face_of`, `turns_of`.

### Selecting a face's table

Version 1 chooses the move tables with branches, assume-then-correct: load the R tables, branch out if the face is R, otherwise load the B tables, and so on. One `la` is two instructions (`auipc` + `addi`), so selection costs 5, 11 or 15 instructions for R, B and D, about 10 on average. The two distance-table `la`s before the heuristic add 4 more. These addresses never change during the run, yet version 1 rebuilds them for every child: about 14 of its 76 instructions per child (about 19%). Adding a fixed offset instead is not free either: one `perm_move` table is $5040 \times 2 = 10{,}080$ bytes, not a power of two.

### Gate T5: replay on an independent model

There were two ways to check the answer on the target:

- **A**, replay with the move tables and check $(0, 0)$;
- **B**, replay on the full seven-corner model, `p[]`/`o[]` updated through `source`/`twist`, and check $p_i = i$, $o_i = 0$.

A is built on the same tables as the search, so if a table is wrong, the search and the check are wrong together and the check still passes. B depends only on two 3×7 tables that the search never reads, so it can catch a wrong table or a wrong search. I chose B. The replay applies each move `turns_of[m]` times; `o + twist` is at most 4, so mod 3 is one compare and one subtract.

**Experiment:** I swapped `1, 4` in the first row of `source` and ran `24513763133333`. The path was still printed, because the search does not use `source`, but the program then printed `T5 failed` and exited with code 1. With the table restored, all six test vectors pass with exit code 0.

### Version 1 results

| State | Path | Retired |
| :--- | :--- | ---: |
| `25314672313211` | R' | 1,270 |
| `25346712313322` | B' R' | 2,277 |
| `23745612123332` | D' B' R' | 3,489 |
| `24513763133333` | B' R2 B' R B2 D' R' D2 R' | 1,302,976 |
| `21345671111111` | R B' D2 R' B R' B' R D2 R B | 17,806,671 |
| `54721631111111` (worst) | B2 R' B R' D' B R2 B R B D' | **48,674,447** |

Every path is identical to the output of the C reference `ida.c`, whose lengths gate H3 checks against BFS for all states.

| Measure | Value |
| :--- | ---: |
| Code size (`.text`, `make size`, `--no-relax`) | 1,244 bytes (311 instructions) |
| Static data (`.data`) | 40,598 bytes (31% of 128 KiB) |
| Instructions per generated child | $48{,}674{,}447 / 639{,}792 \approx 76$ |
| Margin to $5 \times 10^7$ | 2.7% |
| Cost of T5 on the worst case | about 4,400 |

`make size` links with `--no-relax` so that every `la` stays two instructions, as Ripes executes it; with relaxation the same code is 1,152 bytes.

The number of children is fixed by the algorithm (stage 2), so version 1 is within budget only because the work per child is about 76 instructions, just under the 78 target. A 2.7% margin is too thin, so stage 5 lowers the work per child, starting with the table addresses rebuilt in every child.

## LED matrix mapping

The renderer runs inside gate T5: it draws the scrambled state once before the replay and again after every move of the path, so each frame comes from the solver's own `p[]`/`o[]`. Ripes' CLI has no LED matrix, so `LED_MATRIX_0_BASE` does not assemble there, and Ripes has no `.if`. I pass `rubik.S` through the C preprocessor instead: `make asm` produces `build/rubik-cli.s` (`-DRENDER=0`) and `build/rubik-gui.s` (`-DRENDER=1`) from the same source. **The two builds differ only in the renderer**: its tables, its code, and the calls to it. Every retired-instruction figure in this note comes from the CLI build.

### Where each facelet goes

The matrix is 35 LEDs wide and row-major, one 32-bit word per LED, so LED $(x, y)$ is at byte offset $4\,(35y + x)$ from `LED_MATRIX_0_BASE`. The 4 is the size of one word. A facelet is 4 LEDs wide and 3 tall, and a face of 2×2 facelets is 8×6. The net places the faces with one blank LED between neighbours:

```
x:     0         9         18        27
y = 0            +---U---+
y = 7  +---L---+ +---F---+ +---R---+ +---B---+
y = 14           +---D---+
```

Four faces across take $4 \times 8 + 3 = 35$ columns, and three faces down take $3 \times 6 + 2 = 20$ rows, which leaves 5 of the 25 rows unused. A face whose top-left LED is at $(f_x, f_y)$ has facelet $(c, r)$ at $(f_x + 4c,\ f_y + 3r)$. For example, the top-right facelet of F is at $(9 + 4,\ 7) = (13, 7)$, and its offset is $4\,(35 \cdot 7 + 13) = 1032$. `face_off[24]` stores these 24 offsets, precomputed, so the renderer does no multiply.

`draw_select` fills one facelet: three rows of four `sw`, moving 140 bytes (35 LEDs) between rows.

### Which sticker each facelet shows

Each facelet belongs to one corner position and shows one of that corner's three stickers. Two byte tables describe this:

- `fl_pos[i]`: the corner position (0–6, as in `p[]`). For example, the top-left facelet of U is position 6 (BUL), the corner touching both B and L.
- `fl_slot[i]`: which of the three stickers of that position. Slot 0 is the sticker on U or D, then slots 1 and 2 go clockwise as seen from outside the corner. U and D are the reference faces for orientation, so their facelets are all slot 0.

The solver tracks only seven corners. FUL never moves, so its facelets use `fl_pos = 7`, and the RENDER build sets `p[7] = 7` and `o[7] = 0` so the renderer needs no special case.

`corner_face[c][k]` gives the face color of sticker $k$ of cubie $c$ when solved (for example cubie 0, FUR: U, R, F). For facelet $i$, with `pos = fl_pos[i]`, `slot = fl_slot[i]`, `cubie = p[pos]` and `tw = o[pos]`:

$$k = (\text{slot} + \text{tw}) \bmod 3, \qquad \text{color} = \texttt{color6}[\texttt{corner\_face}[\text{cubie}][k]]$$

The cubie is the one now sitting at that position, and its twist shifts which of its stickers lands in this slot. With `tw = 0`, $k = \text{slot}$, which is how it looks when solved. RV32I has no `rem`, but `slot` and `tw` are both 0–2, so their sum is 0–4 and the mod is one `bltu` and one `addi -3`. Writing it as `slot - tw` instead would need a second case for negative results; in C, `-1 % 3` is `-1`, which would index outside the table.

### Checking the mapping

A solved state is not enough. All `tw` are 0 there, so it checks `face_off`, `fl_pos` and `fl_slot` (every face must be one color), but $(\text{slot} + \text{tw})$ and $(\text{slot} - \text{tw})$ draw the same picture. The direction of the twist only shows on a twisted state, so I also ran `25314672313211`, which is one R from solved (the solver answers `R'`).

The prediction comes from a physical cube: after R, the right columns of U, F and D become green, yellow and blue, and the column of B next to R becomes white. Take the top-left facelet of B, as seen from behind. It is position 3 (BUR), slot 1. After R, position 3 holds cubie 0 (FUR) with `o[3] = 2`. So $k = (1 + 2) \bmod 3 = 0$, and sticker 0 of FUR is U, white, as on the real cube. With the direction reversed, $k = (1 - 2) \bmod 3 = 2$, which is F, green: the error is visible in this frame and invisible in the solved one.

Both frames below come from one run of the RENDER build in the Ripes GUI. The first is drawn before the replay, and every facelet matches the physical cube: the right columns of U, F and D are green, yellow and blue, the left column of B is white, R is all red, and L is untouched. The second is drawn after `R'`, and every face is one color.

![One R from solved: 25314672313211 before the replay](https://raw.githubusercontent.com/dges5202/minirubik/84445c3dbcbb223bd89fb1cd2e2d7e0ef9309e5e/docs/led-one-r.png)

![After R': solved](https://raw.githubusercontent.com/dges5202/minirubik/84445c3dbcbb223bd89fb1cd2e2d7e0ef9309e5e/docs/led-solved.png)

### Cost

The tables take 144 bytes of `.data`, words first so the data after them stays aligned. To measure the code, I built the RENDER version with `LED_MATRIX_0_BASE` pointed at ordinary memory, which the CLI accepts, and compared it with the CLI build:

| State | Frames | `RENDER=0` | `RENDER=1` | Difference |
| :--- | ---: | ---: | ---: | ---: |
| `12345671111111` | 1 | 476 | 1,676 | 1,200 |
| `25314672313211` | 2 | 1,338 | 3,744 | 2,406 |
| `21345671111111` | 12 | 3,515,567 | 3,530,048 | 14,481 |

That is about 1,200 instructions per frame (24 facelets × about 50), and a path of length $n$ draws $n + 1$ frames. Even an 11-move path adds under 15,000 instructions, so it would not threaten the budget, but the graded counts exclude it anyway.

## Instruction-level walkthrough on the 5-stage pipeline

I stepped through the hot loop on Ripes' **5-stage processor** (the GUI model behind `--proc RV32_5S`, with forwarding and hazard detection), using the 4-move scramble `57432163231223` with the renderer compiled out, so the whole run is about 3,800 cycles. I loaded two builds: the current one (`c414451`) and the one before the store move (`8874a81`), and set a breakpoint on `sh x31, 2(x19)` at `0x270`. The five instructions I followed check one child against `perm_dist`:

```
0x26c  add  x7, x31, x24       # t2 = perm_dist + cp
0x270  sh   x31, 2(x19)        # pi[g + 1] = cp
0x274  lbu  x29, 0(x7)         # t4 = hp = perm_dist[cp]
0x278  sh   x30, 26(x19)       # oi[g + 1] = co
0x27c  bltu x26, x29, search_top   # r < hp: prune
```

Register names in Ripes are numeric: `x7` = t2, `x19` = s3, `x24` = s8, `x26` = s10 (r), `x29` = t4, `x30` = t5 (co), `x31` = t6 (cp).

### Five stages of one store: `sh x31, 2(x19)`

The pipeline works like an assembly line: an instruction is split into five steps, one new instruction enters every cycle, and each stage works on a different instruction, so five are in flight at once. They still finish in program order, one per cycle. The four grey bars (IF/ID, ID/EX, EX/MEM, MEM/WB) hold each instruction's values between stages.

| Stage | What `sh x31, 2(x19)` does | Values in the figures |
| :--- | :--- | :--- |
| IF | PC fetches the instruction word | PC = `0x270`, word `0x01f99123` |
| ID | Decode reads `x19` and `x31`; the immediate unit extracts `2` | `x19` = `0x10000000`, `x31` = `0x1196`, Imm = `2` |
| EX | ALU adds base and offset | `0x10000000 + 2 = 0x10000002` |
| MEM | Data memory writes the low 16 bits of `x31` | address `0x10000002`, data `0x1196` |
| WB | Nothing: a store has no destination register | register write enable = 0 |

*Figures: `sh` in IF, ID, EX, MEM, WB.*

### How memory is updated

`pi[]` is the first array in `.data`, so `pi[0]` is at `0x10000000` and `x19 = &pi[0]` means g = 0. The memory view shows the word at `0x10000000` before and after `sh` leaves MEM:

| Word at `0x10000000` | Byte 0 | Byte 1 | Byte 2 | Byte 3 |
| :--- | :---: | :---: | :---: | :---: |
| before `0x00000dee` | `ee` | `0d` | `00` | `00` |
| after `0x11960dee` | `ee` | `0d` | **`96`** | **`11`** |

- `pi[1]` (bytes 2 and 3) changed from 0 to `0x1196`, which is cp. It was 0 because `pi[]` starts as `.zero` and this is the first child of the root: R has one turn, so it starts from `pi[0]` and needs no sibling.
- `pi[0]` = `0x0dee` (the root's permutation index) did not change, because `sh` writes only the two bytes at `0x10000002` and `0x10000003`.
- RISC-V is little-endian: the low byte `0x96` is at the lower address.
- `oi[0]` = `0x0271` is at `0x10000018`, 24 bytes after `pi[0]`, which is why the code reads `oi[g]` as `Q + 24`.

*Figures: memory view before and after.*

### Control signals

Decode turns each instruction into a set of switches that travel with it down the pipeline:

| | Register write | Memory write | ALU operand 2 | Write-back source |
| :--- | :---: | :---: | :--- | :--- |
| `add x7, x31, x24` | 1 | 0 | register `x24` | ALU result |
| `lbu x29, 0(x7)` | 1 | 0 | immediate `0` | memory data |
| `sh x31, 2(x19)` | **0** | **1** | immediate `2` | (unused) |

- **Operand 2.** RV32I load and store addresses are only register + immediate; there is no register + register form. So `lbu` selects the immediate (with offset 11 it would select 11), while `add` adds two registers. This is also why every table lookup in `rubik.S` takes two instructions, `add t2, t6, s8` then `lbu t4, 0(t2)`.
- **Write-back source.** `lbu` must write the memory data. If it picked the ALU result, `x29` would get the address `0x1000ced8` instead of hp = 4, and the prune test would be wrong.
- **Why a store's register write must be 0.** In the WB figure the destination-register field of `sh` reads `0x02`. A store has no destination register, so RISC-V puts the low five bits of its immediate in bits 11:7, the place where other formats keep rd. The hardware passes those bits on as rd anyway, here 2 = `x2` (sp). If the write enable were 1, WB would write the ALU result `0x10000002` into sp, and `render`'s `sw ra, 0(sp)` would then overwrite the search data next to `pi[]`.

### Data hazards: forwarding and the load-use stall

A later instruction often needs a result that has not been written back yet.

**Forwarding.** `add x7, x29, x6` is followed directly by `lhu x30, 0(x7)`. The sum exists at the end of `add`'s EX, so when `lhu` reaches EX, the forwarding multiplexer takes `x7` from the EX/MEM register instead of the register file. No stall.

**Load-use stall.** A load's value exists only at the end of MEM, after the data memory is read. In the old build `bltu` directly follows `lbu x29, 0(x7)`:

| Cycle | IF | ID | EX | MEM | WB |
| :---: | :--- | :--- | :--- | :--- | :--- |
| 1 | `add x7, x30, x25` | `bltu` | `lbu`: address | | |
| 2 | `add` (held) | `bltu` (held) | **nop (stall)** | `lbu`: reads 4 | |
| 3 | | | `bltu`: compares with 4 | | `lbu`: writes `x29` |

In cycle 1 the hazard unit sees a load in EX whose destination `x29` is read by the instruction in ID. It disables the IF/ID register and PC (they hold) and clears ID/EX, which inserts the bubble. In cycle 3, `bltu` takes the 4 from MEM/WB by forwarding; in ID it had read the stale `0x4e2`. A single bubble is enough because the value exists at the end of MEM; if it existed only at the end of WB, two would be needed. Stores never cause this stall, since they produce no register value.

**The store move.** In the current build the two stores sit between the load and the branch. `sh x30, 26(x19)` fills the slot: when `bltu` reaches EX, `lbu` is already in WB, the value is in MEM/WB, and there is no bubble. The hardware would keep the result correct either way; reordering only saves time. It is my job to keep the program's meaning: the moved instruction must not write a register the others read, must not need a value that is not ready, and must be harmless if the branch is taken. The stores satisfy all three: they write memory only, cp and co are ready, and they ran for every child before the move too. With two independent instructions in between, `bltu` would be in ID while `lbu` is in WB, and the register file passes the value being written straight to the read port.

The worst case saves one cycle per generated child: 639,792 cycles, from 37,375,979 to 36,736,187 on RV32_5S.

*Figures: old build, hazard detected and `nop (stall)`; new build, no bubble.*

### Branches: flush

`bltu` is resolved in EX. Before that, IF and ID have already fetched the next two instructions, so the pipeline in effect predicts not taken. In the figure, `bltu` in EX compares r = 3 with hp = 4 (forwarded) and is taken. The ALU computes the target `0x27c + (−156) = 0x1e0`, which is `search_top`. In the next cycle IF/ID and ID/EX are cleared: `add x7, x30, x25` and `lbu x29, 0(x7)` become `nop (flush)`.

The flushed instructions cannot cause a wrong result: they only got as far as IF and ID, so they were read and decoded but never reached MEM (no memory write) or WB (no register write).

The cost matters for this program. On the worst case 83% of the children are pruned, so most prune branches are taken and each one discards two instructions. Pruning removed instructions but made taken branches more frequent, which is part of why the CPI went up after the early-exit prune (1.30 to 1.34).

*Figures: `bltu` in EX, then two `nop (flush)`.*

### Stalls still left

The walkthrough also shows two load-use stalls that the current code still pays:

- `lhu x28, 24(x16)` followed by `slli x29, x28, 1`, reading `oi[from]`; every child pays it.
- `lbu x29, 0(x7)` for `ori_dist` followed by `bltu`, paid by every child that passes the perm test.

*Figures: `nop (stall)` after `lhu x28`; `nop (stall)` after the ori `lbu`.*

Both are removed in stage 5 (commits `240a08a` and `496142d`).

## Stage 5: Iterative refinement

Every number in this stage is for the worst case of version 1, `54721631111111`, unless stated otherwise. To make the steps comparable I checked out each commit into its own worktree and measured it with the same commands: retired instructions on `RV32_ISS`, cycles on `RV32_5S`, `.text` and `.data` from `make size`.

| Commit | Change | Retired | Cycles | `.text` | `.data` |
| :--- | :--- | ---: | ---: | ---: | ---: |
| `15217c5` | version 1 (stage 4) | 48,674,447 | 59,240,948 | 1,244 | 40,598 |
| `cb5e3d2` | pad move tables to power-of-two strides | 48,674,389 | 59,240,890 | 1,276 | 54,386 |
| `4911692` | select a face's tables by shift | 44,625,739 | 54,338,482 | 1,232 | 54,386 |
| `59a9f48` | keep distance-table bases in registers | 42,066,575 | 51,779,318 | 1,216 | 54,386 |
| `bbe8d89` | walk a pointer to `path[g]` | 37,481,594 | 47,194,337 | 1,200 | 54,386 |
| `9b45f40` | walk a pointer to `pi[g]` | 32,576,500 | 42,289,243 | 1,152 | 54,386 |
| `569dab0` | store `path[g]` only when pushed or solved | 32,043,338 | 41,756,081 | 1,156 | 54,386 |
| `8874a81` | prune each table on its own | 27,792,303 | 37,375,979 | 1,152 | 54,386 |
| `c414451` | fill the `perm_dist` load-use slot | 27,792,303 | 36,736,187 | 1,152 | 54,386 |
| `05f5015` | third pattern database | 13,291,580 | 17,328,343 | 1,416 | 104,887 |
| `353e893` | skip a whole face at once | 12,373,649 | 15,885,880 | 1,428 | 104,887 |
| `0b31102` | `from_off` table instead of compare and branch | 11,674,149 | 15,273,810 | 1,416 | 104,896 |
| `509363d` | compute the c3 index only for survivors | 11,224,808 | 14,793,677 | 1,432 | 104,896 |
| `d2a440b` | keep the parent's face in `pface[g]` | 10,350,649 | 13,613,493 | 1,424 | 104,908 |
| `d986ea3` | load `next[g]` straight into `a1` | 10,044,624 | 13,307,468 | 1,420 | 104,908 |
| `24dd414` | fall-through layout of `search_top` | 10,088,335 | 12,170,790 | 1,420 | 104,908 |
| `240a08a` | separate three loads from their uses | 10,088,335 | 11,383,848 | 1,420 | 104,908 |
| `496142d` | fill the ori and c3 load-use slots | 10,155,651 | 11,185,663 | 1,420 | 104,908 |
| `a8aca9a` | push straight into `child` | 10,024,510 | 11,054,520 | 1,416 | 104,908 |
| `f5ab68f` | `same_face` straight into `child` | 9,849,666 | 10,821,400 | 1,412 | 104,908 |
| `bb9ccef` | `pop` falls into `search_top` | **9,805,966** | **10,690,300** | 1,412 | 104,908 |

Commits that only touch tooling (the renderer, the gcc build, the scan scripts, the host reference) change none of these numbers and are left out.

Overall: 4.96 times fewer instructions and 5.54 times fewer cycles than version 1. The work falls into four phases.

### Phase 1: stop rebuilding addresses (version 1 to `569dab0`)

Stage 4 found that version 1 rebuilds table addresses in every child, about 14 of its 76 instructions per child. Phase 1 removes that:

- **Power-of-two strides.** One `perm_move` table is 5,040 halfwords, 10,080 bytes. Padding each face to 8,192 entries (16 KiB) makes face $f$ start at `f << 14`, and padding `ori_move` to 1,024 entries makes it `f << 11`. The last face needs no padding, so the cost is $2 \times (8192 - 5040) \times 2 + 2 \times (1024 - 729) \times 2 = 13{,}788$ bytes, exactly the growth of `.data`. This commit alone changes nothing; it is what makes the next one possible.
- **Select by shift.** The branch tree of `la` instructions (5, 11 or 15 instructions) becomes `slli` + `add` from a base held in a register: −4.05 M.
- **Bases in saved registers.** `perm_dist` and `ori_dist` are loaded once, into `s8` and `s9`: −2.56 M.
- **Walk pointers.** Instead of computing `&path[g]` and `&pi[g]` from `g` in every child, `s4` points to `path[g]` and `s3` to `pi[g]`, moved by `±1` and `±2` on push and pop. `next[]`, `oi[]` and `turns_of[]` are reached at fixed offsets from them: −4.58 M and −4.91 M.
- **Store `path[g]` late.** Only pushed or solved children need it: −0.53 M.

Together: −34%, with `.text` slightly smaller.

### Phase 2: prune each table on its own (`8874a81`, `c414451`)

$g + 1 + \max(h_p, h_o) > \text{bound}$ is the same as $h_p > r$ or $h_o > r$ with $r = \text{bound} - g - 1$. Keeping $r$ in `s10` (it moves by one on push and pop) turns the max into two independent tests, and when the perm test prunes, the ori lookup is never made: −13%. `c414451` is the store move analysed in the pipeline walkthrough above, one cycle per child.

At this point the margin to $5 \times 10^7$ was 44%, but the stage 2 weakness was still there: on states with all twists solved, `ori_dist` is 0 and only `perm_dist` (max 7) bounds a true distance of 11.

### Phase 3: a third pattern database (`5829634`, `05f5015`)

The weakness says the two tables cannot see how positions and twists interact. A table over the positions **and** twists of some cubies can. With $k$ cubies it has $\frac{7!}{(7-k)!} \times 3^k$ entries; $k = 3$ gives $210 \times 27 = 5{,}670$ bytes of distances, which fits, and $k = 4$ gives $840 \times 81 = 68{,}040$, which with its move table does not. I chose cubies 0, 3 and 6.

- **Index.** `rank_c3` finds where cubies 0, 3, 6 sit, ranks those three positions among 7 (210 values) through a 343-entry `c3_pos` table indexed by $49a + 7b + c$, and appends their three twists in base 3. $49a$ and $7b$ are `(a << 5) + (a << 4) + a` and `(b << 3) - b`, so no multiply.
- **Moves.** `c3_move[face][index]` is generated on the host like the other tables, padded to `f << 14`. `scan.c` checks it against `rank_c3` of every state after every face turn.
- **Admissible** for the same reason as the other two (stage 2): any solution of the cube projects to a path of the same length in the abstraction. $h = \max(h_p, h_o, h_c)$.

Host gates with `scan.c`:

| | 2 tables | 3 tables |
| :--- | ---: | ---: |
| H1: mean $h$ over all states | 5.144 | 5.523 |
| H1: states with $h = d$ | 17,108 | 26,762 |
| distance 11: mean children per query | 206,618 | 88,140 |
| distance 11: max children per query | 639,792 | 268,110 |
| `54721631111111`: children | 639,792 | 262,314 |

H1 ($h \le d$) and H3 (every state solved at exactly its BFS distance) still pass for all 3,674,160 states; H3 now takes 3 min 10 s instead of 3 min 45 s.

Mean $h$ rises only by 0.38, but the gain is concentrated where it matters: the worst state generates 2.4 times fewer children. Instructions drop by 52% and cycles by 53%. The cost is memory: `.data` grows from 54,386 to 104,887 bytes, 80% of the 128 KiB budget.

### Phase 4: work per child in the three-table loop (`353e893` to `d986ea3`)

From here on the search is fixed: every version generates the same 262,314 children. Counting events in an instrumented copy of `ida.c` gives the frequencies each optimization works against (per query, all bounds):

| Event | Count |
| :--- | ---: |
| moves tried (`next[g]` read) | 306,025 |
| same-face skips | 43,711 |
| children generated | 262,314 |
| pass `perm_dist` | 111,032 |
| pass `perm_dist` and `ori_dist` | 77,233 |
| pass all three (pushed) | 43,716 |
| pops | 43,711 |

- **Skip a whole face (`353e893`).** If move `m` has the same face as the previous move, all three turns of that face are skipped, so `next[g] += 2` instead of testing the next two moves one by one: −0.92 M.
- **`from_off` (`0b31102`).** `from = turns_of[m] == 1 ? g : g + 1` was a compare and a branch. A 9-byte table `{0, 2, 2, 0, 2, 2, 0, 2, 2}` holds the byte offset of `pi[from]` from `pi[g]` instead: X starts from `pi[g]`, X2 from X, and X' from X2, so both X2 and X' read `pi[g + 1]`. −0.70 M instructions, but only −0.61 M cycles: the new `lbu` was used by the next instruction, a load-use stall in every child that `240a08a` later removed.
- **Lazy c3 index (`509363d`).** The first version computed the c3 index for every child, chained through siblings like `pi` and `oi`. But 71% of the children are pruned by `perm_dist` or `ori_dist` before `c3_dist` is ever needed. Now only the 77,233 survivors compute it, from the parent's `ci[g]`, turning it `turns_of[m]` times (1 to 3 lookups). The price is that c3 is no longer chained: X' costs three lookups instead of one. −0.45 M.
  - Why `ci[g + 1]` may be written even by a child that `c3_dist` then prunes, while `oi[g + 1]` must be written before *any* prune: X2 and X' read `oi[g + 1]` (the previous sibling), so a skipped store would hand them a stale value. Nobody at this depth reads `ci[g + 1]`; only the children of a pushed node read it as their `ci[g]`, and a node is pushed only after it wrote its own value.
- **`pface[g]` (`d2a440b`).** The same-face test needed `face_of[path[g - 1]]`, two dependent loads in every try. The parent's face is now stored once per push in `pface[g + 1]`, one load per try. `pface[0] = 3`, a face that does not exist, so the root never skips: −0.87 M.
- **`a1` straight from `next[g]` (`d986ea3`).** Removes one copy per try: exactly −306,025, the number of tries.

### Phase 5: scheduling for the 5-stage pipeline (`24dd414` to `bb9ccef`)

The pipeline walkthrough gives the cost model: a load whose result is used by the very next instruction costs one bubble; a taken branch or `j` costs two flushed instructions; a branch that is not taken costs nothing. So the goal is that the common case falls through every branch and never uses a load immediately. Instruction count is no longer the target: in this phase it went down by only 2.4%, while cycles went down by 19.7% and CPI from 1.325 to 1.090.

| Commit | Retired | Cycles | Where the cycles come from |
| :--- | ---: | ---: | :--- |
| `24dd414` | +43,711 | −1,136,678 | the taken `bne a1, s1, child` on every try becomes a not-taken `beq ... pop` (2 × 306,025 = 612,050), and the reordered loads remove stalls; loading `pface[g]` early is wasted on each of the 43,711 pops |
| `240a08a` | 0 | −786,942 | three load-use stalls in every child (`from_off`, `pi[from]`, `oi[from]`): 3 × 262,314 exactly |
| `496142d` | +67,316 | −198,185 | see below |
| `a8aca9a` | −131,141 | −131,143 | 3 instructions per push, 3 × 43,716 |
| `f5ab68f` | −174,844 | −233,120 | 4 instructions per same-face skip (4 × 43,711); the remaining 58,276 = 4 × 14,569 are the skips at m = 6 (about a third), which used to pay two taken branches (`j`, then `beq ... pop`) and now fall into `pop` |
| `bb9ccef` | −43,700 | −131,100 | the `j` of each pop: 1 instruction + 2 flushed = 3 cycles |

**Filling a slot can cost instructions (`496142d`).** The ori and c3 lookups each had a load-use stall before their prune branch, and the c3 loop used `ci[g]` right after loading it. The `ci[g]` load just moved up, which is free. The other two slots were filled with an instruction moved up from later:

| Filler | Stalls saved | Now also runs when pruned | Net |
| :--- | ---: | ---: | ---: |
| `add t0` (c3 table base) in the ori slot | 111,032 | +33,799 | −77,233 |
| `sh ci[g + 1]` in the c3 slot | 77,233 | +33,517 | −43,716 |
| `lhu ci[g]` moved up | 77,233 | 0 | −77,233 |

$265{,}498 - 67{,}316 = 198{,}182$, within 3 cycles of the measurement. A moved instruction is worth it only if it saves more stalls than the extra times it runs. My first attempt also moved the `oi[g + 1]` store below the perm prune; the test with 11 moves failed, because X2 then read a stale `oi[g + 1]` whenever X was pruned by `perm_dist`.

**Jumping past what is already known (`a8aca9a`, `f5ab68f`).** After a push, `search_top` would load `next[g] = 0` and `pface[g] = face_of[m]`, both already in registers. So the push sets `a1 = 0`, `t5 = face` and branches straight to `child`, which stores `next[g] = 1` itself, so `next[g + 1] = 0` is no longer needed. `pface[g + 1]` must still be stored, because `search_top` reloads it after every prune and pop. The goal test moved after the push, so one `bne` both loops back and lets `found` fall through; `found` now reports length `g`. A same-face skip knows `m + 3` and the same `pface` in the same way: it tests `m + 3 == MOVES` itself and either branches to `child` or falls into `pop`, placed right below it.

**Moving a cost from a hot path to a cold one (`bb9ccef`).** After a pop the parent's `next[g]` and `pface[g]` are in no register any more, so the loads stay; only the `j` can go. `same_face`, `pop` and `search_top` are now adjacent in that order and fall into each other. The bound setup in `loop_solve` would fall into them too, so it jumps over them: one `j` per bound (at most 11) instead of one per pop (43,711).

**What is left.** The remaining flushes are branches that really decide something: the three prune `bltu`s (most children are pruned, so they are mostly taken), the back edge `bne child` on every push, and the loop branch of the c3 turns. I kept the c3 loop rather than unrolling it, for readability. Removing it without unrolling would need a table per move instead of per face, `c3_move[m][index]`: $9 \times 5670 \times 2 = 102{,}060$ bytes, 68,040 more than now, which does not fit in 128 KiB, and even a separate half-turn table (+34,020) would bring `.data` to 138,928 bytes.

## Final results

### Correctness and budget

| State | Path | Retired |
| :--- | :--- | ---: |
| `25314672313211` | R' | 1,338 |
| `25346712313322` | B' R' | 2,171 |
| `23745612123332` | D' B' R' | 3,078 |
| `24513763133333` | B' R2 B' R B2 D' R' D2 R' | 362,464 |
| `21345671111111` | R B' D2 R' B R' B' R D2 R B | 3,515,567 |
| `54721631111111` | B2 R' B R' D' B R2 B R B D' | 9,805,966 |
| `41625372313211` | R' D R' B D B2 R' D B D2 B' | 9,869,511 |

Every run exits with code 0, so gate T5 passed. `make test-ripes` also checks the length against the BFS solver on `RV32_ISS` and `RV32_5S`.

`make scan-ripes` runs `rubik.S` on all 2,644 states at distance 11 (`bench/d11_iret.csv`): all solved optimally and pass T5; **max 9,869,511** (`41625372313211`), mean 3,300,766, min 2,035,322. The worst case uses 19.7% of the $5 \times 10^7$ budget. With three tables `54721631111111` is no longer the worst state, but within 1% of it.

### Memory

| Item | Bytes |
| :--- | ---: |
| `perm_move` (30,240 + 12,608 padding) | 42,848 |
| `ori_move` (4,374 + 1,180 padding) | 5,554 |
| `c3_move` (34,020 + 10,088 padding) | 44,108 |
| `perm_dist`, `ori_dist`, `c3_dist` | 11,439 |
| `c3_pos` | 686 |
| search stack, input, names, T5 tables | 273 |
| **`.data` total** (no `.bss`, no `.rodata`) | **104,908 (80.0% of 128 KiB)** |

Padding costs 23,876 bytes, 18% of the budget. It buys one `slli` instead of a multiply by 5,040, 729 or 5,670 in every lookup; the gcc build below shows what that multiply costs.

### Against `gcc -O2` on the same C algorithm

`make gcc-ref` compiles `ida.c` (without `main` and the node counters) with `riscv64-unknown-elf-gcc -O2 -march=rv32i -mabi=ilp32`, wrapped by `bench/gcc_ref.c`, and runs the ELF on Ripes.

| `54721631111111` | gcc -O2 | `rubik.S` | |
| :--- | ---: | ---: | :--- |
| Retired | 17,393,352 | 9,805,966 | −43.6% |
| Cycles | 19,970,352 | 10,690,300 | −46.5% |
| CPI | 1.148 | 1.090 | |
| Instructions per child | 66.3 | 37.4 | |
| `.text` | 1,240 | 1,412 | +13.9% |
| `.text` without gate T5 | 1,240 | 1,076 | −13.2% |

`41625372313211`: 17,544,648 against 9,869,511 retired; `21345671111111`: 6,227,962 against 3,515,567.

gcc is not naive: it also enters the child directly after a push, and a same-face skip continues straight with the next move. Reading its loop, the difference per child comes from:

- **Address arithmetic.** The C arrays are not padded, so gcc forms `face × 5040` and `face × 729` with chains of shifts, adds and subtracts in every child, and `face × 5670` for every c3 lookup. With padding this is one `slli` each.
- **`from`.** gcc compiles `turns_of[m] == 1 ? g : g + 1` into a load, a compare, a branch and moves; `from_off` is one load.
- **Goal test first.** `ida.c` tests `cp == 0 && co == 0` before pruning, in all 262,314 children; `rubik.S` tests it only for the 43,716 that are pushed.
- **Depth as an index.** gcc recomputes stack addresses from `g` after a prune; `rubik.S` walks `s3` and `s4`.

**Where `rubik.S` loses: code size.** `bench/gcc_ref.c` does not replay the path, while `rubik.S` contains gate T5: the replay on the seven-corner model and its failure message are 336 bytes (from the label addresses in `build/rubik-cli.elf`). Without them `rubik.S` is 1,076 bytes, 13% smaller than gcc. I keep T5 because it is the only check on the target that does not depend on the search's own tables (stage 4).

## AI usage

- Explanations and Socratic discussion of the state space, BFS, IDA* and pattern databases.
- C skeleton with blanks; I filled the BFS step, same-face pruning, goal test, pruning test, heuristic, bound start, sibling-derived turns and shift-add ranks.
- Host verification tools (`scan.c`), the preprocessor build, `make size` and `bench/measure.sh`.
- English structure and wording of this note, from my own explanations and measurements.
- Pipeline walkthrough: I have no computer engineering background, so AI explained the five stages, control signals, forwarding, stalls and flushes step by step, checked my answers, told me which instructions to trace and where to set the breakpoint, and checked Ripes' source for where branches resolve. I took the screenshots, read the values, and wrote the explanations in Chinese; AI corrected my mistakes in discussion and wrote the English.
- I wrote the RV32I assembly myself (`bench/fill.s` and `rubik.S`). AI gave the C reference for each step, explained RV32I and Ripes behavior, reviewed my errors (I fixed them), and ran the measurements.
- Stage 5: for each optimization AI gave the C code and guiding questions instead of answers (the third table's rank, the lazy c3 index, `from_off`, `pface`, and every scheduling step); I filled in the C and wrote the assembly, and AI found my bugs by running the tests and asking me to trace them (for example the `oi[g + 1]` store moved below a prune, and `bne t2` instead of `bne a1` in `same_face`). AI wrote the host check for `c3_move`, the event counters, the per-commit measurement script, tidied comments in `rubik.S`, and wrote the English of this stage from our discussions and the measurements.
- LED matrix mapping: AI asked the questions (why the offset is multiplied by 4, why the net is 35 by 20, what `fl_slot` means, what `(slot + tw) % 3` gives for each twist, how to check the colors), and I answered them in discussion; AI corrected my wrong answers, found the one-R test state, measured the renderer's cost, and wrote the English of the section. I ran the build in the Ripes GUI and took the screenshots.
- Video: AI drafted the outline and an English script from our discussions. I used the script only as a reference; the narration is in my own words and my own voice.
