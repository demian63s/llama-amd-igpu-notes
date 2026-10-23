#!/bin/bash
# Interleaved A/B benchmark of two llama.cpp builds (reference, candidate, reference, candidate).
# Machine speed drifts a few % between runs (power, thermals), so only interleaved numbers are comparable.
#
# Usage: MODEL=model.gguf REF=/path/to/ref/bin NEW=/path/to/new/bin ./ab_bench.sh [rounds]
# If a build was copied out of its build directory, point LD_LIBRARY_PATH at the copy (RUNPATH is absolute).
set -u
: "${MODEL:?set MODEL}" "${REF:?set REF}" "${NEW:?set NEW}"
ROUNDS=${1:-2}
ARGS=${BENCH_ARGS:--ngl 99 -fa 1 -p 512 -n 128 -r 3}
run() {
  "$1/llama-bench" -m "$MODEL" $ARGS -o md 2>/dev/null \
    | grep -E '^\| ' | grep -E 'pp[0-9]+|tg[0-9]+' \
    | sed -E 's/.*\| +(pp[0-9]+|tg[0-9]+) +\| +([0-9.]+) .*/\1=\2/' | tr '\n' ' '
}
for i in $(seq 1 "$ROUNDS"); do
  echo "ref: $(LD_LIBRARY_PATH=${REF_LD:-} run "$REF")"
  echo "new: $(run "$NEW")"
done
