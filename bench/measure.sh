#!/usr/bin/env bash
# Stage 1 measurements on the pinned Ripes build, using bench/fill.s.
#
#   host bytes per guest byte: peak RSS against N, slope over a small control
#   simulation rate:           --iret divided by --exectime, per processor
#
# Each configuration runs RUNS times; report the median.
# Usage: RIPES=/path/to/Ripes bench/measure.sh
set -eu

: "${RIPES:?set RIPES, e.g. source ../env.sh}"
RUNS=${RUNS:-3}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

with_n() {
    sed "s/^\.equ N, .*/.equ N, $1/" "$here/fill.s" >"$tmp/fill_$1.s"
    echo "$tmp/fill_$1.s"
}

run() { # proc n run
    local src
    src=$(with_n "$2")
    /usr/bin/time -v "$RIPES" --mode cli -t asm --src "$src" --proc "$1" \
        --iret --exectime 2>&1 |
        awk -v p="$1" -v n="$2" -v r="$3" '
            /instructions retired/ { getline; i = $1 }
            /execution time/       { getline; t = $1 }
            /Maximum resident/     { m = $NF }
            END { printf "%-8s N=%-8s run %s  iret=%-8s ms=%-6s rss_kb=%s\n",
                         p, n, r, i, t, m }'
}

for n in 4096 1048576 4194304; do
    for r in $(seq "$RUNS"); do run RV32_ISS "$n" "$r"; done
done
for r in $(seq "$RUNS"); do run RV32_5S 1048576 "$r"; done
