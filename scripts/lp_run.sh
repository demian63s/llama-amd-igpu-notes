#!/bin/bash
# Usage: lp_run.sh <model.gguf> <bin-dir> <out.json> <n_predict> [VAR=VALUE ...]   (server args via $EXTRA_ARGS, port via $PORT)
# Starts llama-server (explicit -c 4096, one slot), requests a greedy completion with per-token probabilities, saves JSON.
# For binaries copied out of build-vk run with LD_LIBRARY_PATH=<that-dir> among the VAR=VALUE words.
M="$1"; BIN="$2"; OUT="$3"; N="$4"; shift 4
PORT=${PORT:-8120}
P="${PROMPT:-Escribe en Python una funcion que implemente quicksort con explicacion paso a paso, y un ejemplo de uso.}"
env "$@" $BIN/llama-server -m "$M" -ngl 99 -fa on -c 4096 -np 1 --port $PORT --host 127.0.0.1 $EXTRA_ARGS > "$OUT.srv.log" 2>&1 &
SP=$!
ok=0; for i in $(seq 1 240); do curl -s localhost:$PORT/health 2>/dev/null | grep -q ok && { ok=1; break; }; kill -0 $SP 2>/dev/null || break; sleep 2; done
[ $ok -eq 1 ] || { echo "server did not start (see $OUT.srv.log)"; kill $SP 2>/dev/null; exit 1; }
body=$(python3 -I -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"n_predict":int(sys.argv[2]),"temperature":0,"seed":1,"cache_prompt":False,"n_probs":1}))' "$P" "$N")
curl -s localhost:$PORT/completion -d "$body" > "$OUT"
kill $SP; wait $SP 2>/dev/null; sleep 3
