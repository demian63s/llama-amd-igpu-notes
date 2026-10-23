#!/bin/bash
# Quality check of a candidate build against a reference build on the same GGUF, with llama-perplexity:
# perplexity + KL divergence (candidate against the reference logits), HellaSwag and Winogrande.
# The patches in this repository are performance-only, so the expected result is "no difference".
#
# Usage: MODEL=model.gguf REF=/path/to/ref/bin NEW=/path/to/new/bin DATASETS=/path/to/datasets ./quality.sh
# Datasets come from the scripts in llama.cpp/scripts: get-wikitext-2.sh, get-hellaswag.sh, get-winogrande.sh.
# Note: with a 248K-token vocabulary the KL base file is ~127 MB per chunk of 512 tokens, so keep --chunks small.
set -u
: "${MODEL:?set MODEL}" "${REF:?set REF}" "${NEW:?set NEW}" "${DATASETS:?set DATASETS}"
COMMON="-m $MODEL -ngl 99 -fa on"
OUT=${OUT:-quality_out}; mkdir -p "$OUT"; cd "$OUT" || exit 1

echo "### perplexity + KL divergence (wiki.test, 20 chunks of 512 tokens)"
"$REF/llama-perplexity" $COMMON -f "$DATASETS/wikitext-2-raw/wiki.test.raw" -c 512 --chunks 20 --kl-divergence-base ref.kld > ppl_ref.log 2>&1
grep -E 'Final estimate' ppl_ref.log | sed 's/^/REF: /'
"$NEW/llama-perplexity" $COMMON -f "$DATASETS/wikitext-2-raw/wiki.test.raw" -c 512 --chunks 20 --kl-divergence-base ref.kld --kl-divergence > kld_new.log 2>&1
grep -E 'Mean +KLD|Maximum KLD|Same top p|Mean PPL\(Q\)  ' kld_new.log | sed 's/^/NEW: /'
rm -f ref.kld

echo "### HellaSwag (400 tasks)"
for w in REF NEW; do
  B=$([ $w = REF ] && echo "$REF" || echo "$NEW")
  "$B/llama-perplexity" $COMMON -f "$DATASETS/hellaswag_val_full.txt" --hellaswag --hellaswag-tasks 400 > "hs_$w.log" 2>&1
  echo -n "$w: "; grep -E '^400' "hs_$w.log" | tail -1
done

echo "### Winogrande (500 tasks)"
for w in REF NEW; do
  B=$([ $w = REF ] && echo "$REF" || echo "$NEW")
  "$B/llama-perplexity" $COMMON -f "$DATASETS/winogrande-debiased-eval.csv" --winogrande --winogrande-tasks 500 > "wg_$w.log" 2>&1
  echo -n "$w: "; grep -E 'Final Winogrande score' "wg_$w.log" | tail -1
done
