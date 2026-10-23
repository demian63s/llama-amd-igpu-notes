#!/usr/bin/env python3
"""Compare per-token logprobs of two lp_run.sh outputs: python3 -I lp_cmp.py a.json b.json"""
import json, math, sys
def load(p):
    d = json.load(open(p)); out = []
    for e in d.get('completion_probabilities', []):
        lp = e['logprob'] if 'logprob' in e else (math.log(max(e['probs'][0]['prob'], 1e-30)) if e.get('probs') else None)
        out.append((e.get('content', e.get('token', '')), lp))
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
div = None; ds = []
for i, (x, y) in enumerate(zip(a, b)):
    if x[0] != y[0] and div is None: div = i
    if x[0] == y[0] and x[1] is not None and y[1] is not None: ds.append(abs(x[1] - y[1]))
if not ds: sys.exit('no comparable tokens')
print(f"tokens={len(a)}/{len(b)} first_diff_token={div} mean|dlp|={sum(ds)/len(ds):.2e} max|dlp|={max(ds):.2e} n(>1e-4)={sum(1 for d in ds if d>1e-4)}")
