#!/bin/bash
# Per-operation GPU profile of a model on the Vulkan backend (token generation and prompt processing)
# using the built-in GGML_VK_PERF_LOGGER, summarised with analizar.py.
#
# Usage: MODEL=model.gguf BIN=/path/to/bin ./profile.sh
# The logger serialises every op, so absolute per-op times are inflated; compare relative shares.
set -u
: "${MODEL:?set MODEL}" "${BIN:?set BIN}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT=${OUT:-profile_out}; mkdir -p "$OUT"
for mode in tg pp; do
  if [ $mode = tg ]; then ARGS="-p 0 -n 64"; else ARGS="-p 512 -n 0"; fi
  GGML_VK_PERF_LOGGER=1 "$BIN/llama-bench" -m "$MODEL" -ngl 99 -fa 1 $ARGS -r 1 --no-warmup -o md \
    > "$OUT/$mode.out" 2> "$OUT/$mode.err"
  python3 -I "$HERE/analizar.py" "$OUT/$mode.err" "$mode"
done
