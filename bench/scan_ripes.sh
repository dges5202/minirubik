#!/usr/bin/env bash
# The instruction budget over every distance-11 state, measured on Ripes.
#
# Runs the CLI build of rubik.S (RV32_ISS, --iret) on each of the 2,644
# states in tests/d11_states.txt, JOBS at a time, and writes
# state,iret,exit,solution to OUT, most instructions first. A state fails if
# it exits non-zero (gate T5) or its path is not 11 moves long.
#
# tests/d11_states.txt lists the states at BFS distance 11 in index order,
# taken from the BFS in scan.c.
#
# Usage: source ../env.sh; bench/scan_ripes.sh [OUT]   (default bench/d11_iret.csv)
set -eu

: "${RIPES:?set RIPES, e.g. source ../env.sh}"
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
out=${1:-$here/d11_iret.csv}
jobs=${JOBS:-$(($(nproc) > 2 ? $(nproc) - 2 : 1))}
budget=50000000
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

one() {
    local st=$1 src=$tmp/$1.s out
    ${RV_PREFIX:-riscv64-unknown-elf-}cpp -P -x assembler-with-cpp \
        -DSTATE="\"$st\"" -DRENDER=0 -I"$root" "$root/rubik.S" -o "$src"
    out=$("$RIPES" --mode cli -t asm --src "$src" --proc RV32_ISS --iret 2>&1)
    rm -f "$src"
    printf '%s,%s,%s,%s\n' "$st" \
        "$(printf '%s\n' "$out" | awk '/instructions retired/ { getline; print $1 }')" \
        "$(printf '%s\n' "$out" | sed -n 's/.*exited with code: //p')" \
        "$(printf '%s\n' "$out" | sed -n 1p)"
}
export -f one
export RIPES root tmp

start=$(date +%s)
xargs -P "$jobs" -I{} bash -c 'one "$1"' _ {} <"$root/tests/d11_states.txt" |
    sort -t, -k2,2nr >"$tmp/rows"
{
    echo state,iret,exit,solution
    cat "$tmp/rows"
} >"$out"

awk -F, -v budget="$budget" -v secs=$(($(date +%s) - start)) -v jobs="$jobs" '
    { n++; sum += $2; split($4, mv, " ")
      if ($3 != 0 || length(mv) != 11) bad++
      if ($2 > budget) over++
      if ($2 > max) { max = $2; worst = $1 }
      if (min == "" || $2 < min) { min = $2; best = $1 } }
    END { printf "states %d, failed %d, over %d: %d\n", n, bad, budget, over
          printf "max %d (%s), mean %.0f, min %d (%s)\n", max, worst, sum / n, min, best
          printf "%d s with %d jobs\n", secs, jobs
          exit (bad || over) }' "$tmp/rows"
