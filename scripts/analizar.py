#!/usr/bin/env python3
"""Resume la salida de GGML_VK_PERF_LOGGER (stderr de llama bench).

Uso: python3 -I analizar.py <perf.err> <etiqueta> [tok_por_s_medido]

Formato de cada linea del logger:
  <clave>: <N> x <media> us = <total> us [(<X> GFLOPS/s)]
Cada bloque empieza en "Vulkan Timings:" y termina en "Total time: <X> us.".
"""
import re
import statistics
import sys
from collections import defaultdict

LINE = re.compile(r"^(?P<key>.+?): (?P<n>\d+) x (?P<avg>[0-9.]+(?:[eE][+-]?[0-9]+)?) us = (?P<tot>[0-9.]+(?:[eE][+-]?[0-9]+)?) us(?: \((?P<gf>[0-9.]+) GFLOPS/s\))?\s*$")
TOTAL = re.compile(r"^Total time: ([0-9.]+(?:[eE][+-]?[0-9]+)?) us\.")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    path, label = sys.argv[1], sys.argv[2]
    tok_s = float(sys.argv[3]) if len(sys.argv) > 3 else None

    by_key = defaultdict(lambda: [0, 0.0, None])  # llamadas, us totales, GFLOPS/s
    by_op = defaultdict(lambda: [0, 0.0])
    block_totals = []
    in_block = False

    with open(path, errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if line.startswith("Vulkan Timings:"):
                in_block = True
                continue
            m = TOTAL.match(line)
            if m:
                block_totals.append(float(m.group(1)))
                in_block = False
                continue
            if not in_block:
                continue
            m = LINE.match(line)
            if not m:
                continue
            n, tot = int(m.group("n")), float(m.group("tot"))
            entry = by_key[m.group("key")]
            entry[0] += n
            entry[1] += tot
            if m.group("gf") and entry[2] is None:
                entry[2] = float(m.group("gf"))
            op = re.match(r"[A-Z0-9_]+", m.group("key"))
            op = op.group(0) if op else m.group("key").split()[0]
            by_op[op][0] += n
            by_op[op][1] += tot

    grand = sum(v[1] for v in by_op.values())
    print(f"===== {label} =====")
    if not block_totals or grand == 0:
        print("No se encontraron bloques 'Vulkan Timings' en", path)
        return
    med = statistics.median(block_totals)
    print(f"Bloques (grafos) registrados: {len(block_totals)}")
    print(f"Tiempo GPU por grafo (mediana): {med / 1000:.2f} ms")
    if tok_s:
        wall = 1000.0 / tok_s
        print(f"Tiempo real por token ({tok_s:.2f} t/s): {wall:.2f} ms")
        print(f"  -> la suma de ops en GPU cubre el {100 * med / 1000 / wall:.0f}% del tiempo por token")
        print("     (si es mucho menor que 100%, hay espera de CPU/lanzamiento/sincronizacion)")
    print()
    print("Por tipo de operacion (todo el perfil):")
    print(f"{'op':<24}{'llamadas':>10}{'tiempo ms':>12}{'%':>8}")
    for op, (n, tot) in sorted(by_op.items(), key=lambda kv: -kv[1][1])[:15]:
        print(f"{op:<24}{n:>10}{tot / 1000:>12.1f}{100 * tot / grand:>8.1f}")
    print()
    print("Top 12 variantes (con forma/tipo):")
    for key, (n, tot, gf) in sorted(by_key.items(), key=lambda kv: -kv[1][1])[:12]:
        extra = f"  {gf:.0f} GFLOPS/s" if gf else ""
        print(f"{100 * tot / grand:5.1f}%  {tot / 1000:9.1f} ms  x{n:<7} {key[:110]}{extra}")
    print()


if __name__ == "__main__":
    main()
