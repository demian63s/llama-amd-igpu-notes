#!/bin/bash
# Sweep speculative-decoding (MTP) settings with llama-server: greedy completions of a few prompts,
# reporting generation speed and draft acceptance for each configuration.
#
# Usage: MODEL=model.gguf BIN=/path/to/bin ./mtp_sweep.sh
# Always keep an explicit moderate context (-c): some models default to huge contexts that reserve a lot of shared memory.
set -u
: "${MODEL:?set MODEL}" "${BIN:?set BIN}"
PORT=${PORT:-8101}
NPRED=${NPRED:-200}
PROMPTS=(
  "Write a Python function that implements quicksort, explain each step and add a usage example."
  "Explain in one long paragraph how photosynthesis works and why it matters for the climate."
  "Generate a JSON document with 15 fictional users with the fields id, name, email, city and age."
)
# name|extra llama-server flags
CFGS=(
  "none|"
  "mtp1|--spec-type draft-mtp --spec-draft-n-max 1"
  "mtp2|--spec-type draft-mtp --spec-draft-n-max 2"
  "mtp3|--spec-type draft-mtp --spec-draft-n-max 3"
)
for entry in "${CFGS[@]}"; do
  IFS='|' read -r name flags <<< "$entry"
  "$BIN/llama-server" -m "$MODEL" -ngl 99 -fa on -c 4096 -np 1 --port "$PORT" --host 127.0.0.1 $flags > "srv_$name.log" 2>&1 &
  SP=$!
  for _ in $(seq 1 240); do
    curl -s "localhost:$PORT/health" 2>/dev/null | grep -q ok && break
    kill -0 "$SP" 2>/dev/null || break
    sleep 2
  done
  res=""
  for p in "${PROMPTS[@]}"; do
    body=$(python3 -I -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"n_predict":int(sys.argv[2]),"temperature":0,"seed":1,"cache_prompt":False}))' "$p" "$NPRED")
    r=$(curl -s "localhost:$PORT/completion" -d "$body" | python3 -I -c '
import json,sys
t=json.load(sys.stdin).get("timings",{})
print(round(t.get("predicted_per_second",0),2),"t/s draft",t.get("draft_n",0),"accepted",t.get("draft_n_accepted",0))')
    res="$res | $r"
  done
  echo "$name $res"
  kill "$SP"; wait "$SP" 2>/dev/null; sleep 3
done
