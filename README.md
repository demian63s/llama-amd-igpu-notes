# llama.cpp en una iGPU AMD (Radeon 860M): notas de investigación

> **English summary.** Personal research notes (done together with an AI assistant, Claude Code) on getting more
> speed out of local LLMs with [llama.cpp](https://github.com/ggml-org/llama.cpp) on an AMD Ryzen AI 7 350 laptop with a
> Radeon 860M iGPU (Vulkan/RADV). Contents: measurements, profiles, a small set of experimental Vulkan patches
> (+8-10 % token generation on a MoE model, +4.6 % on a dense one, no change in model quality), and what did **not**
> work. The biggest win needs no code: multi-token-prediction (MTP) speculative decoding via flags. This is **not** a
> fork meant to compete with llama.cpp and the patches were **not** submitted upstream. Everything below is in Spanish.

## Intención y aviso

Este repositorio **no pretende competir ni sustituir al proyecto original de llama.cpp**. Es simplemente el registro de
una investigación entre una persona y un asistente de IA (Claude, en Claude Code) para **mejorar la ejecución de
modelos locales en un hardware concreto y modesto**. Se publica por si le sirve a alguien con un equipo parecido.

- Los parches son **experimentales**, hechos con ayuda de IA, **no han sido revisados por los mantenedores de llama.cpp**
  y **no se han enviado como pull request**. Úsalos bajo tu propio riesgo y sin garantías.
- Solo se midió en **un** equipo (RDNA3.5, controlador RADV). En otra GPU, controlador o modelo pueden no ayudar o
  incluso empeorar.
- El proyecto original tiene sus propias normas para contribuir (incluida su política sobre código generado con IA).
  Si algo de aquí te parece útil para llama.cpp, lo correcto es abrir primero una conversación allí.
- llama.cpp es MIT; los parches de este repositorio son obras derivadas y siguen la licencia del proyecto original. El
  resto (README y scripts) también es MIT, ver [`LICENSE`](LICENSE).

Las medidas se hicieron entre el 19 y el 23 de octubre de 2026 sobre el commit `9df0b73c7` de `master`.

## Hardware y software de las pruebas

| Elemento | Detalle |
|---|---|
| CPU | AMD Ryzen AI 7 350 (16 hilos lógicos, 16 MiB de L3) |
| GPU | AMD Radeon 860M integrada (RDNA3.5; Vulkan la reporta como `RADV KRACKAN1`) |
| Memoria | 26 GiB de RAM compartida con la GPU (UMA). La GPU ve ~17,7 GiB: 4 GiB de VRAM reservada + ~13,3 GiB de GTT |
| Vulkan | `uma: 1`, fp16, int dot, `KHR_coopmat`, warp size 64 reportado; Vulkan 1.4.335 |
| NPU | XDNA2 presente (módulo `amdxdna`), **no usada** (ver más abajo) |
| SO | Ubuntu 26.04.1 LTS, kernel 7.0.0-38, Mesa/RADV 26.0.8 |
| Compilación | GCC 15.2.0, CMake + Ninja, `glslc` 2026.1 (el binario "instalado" de referencia venía compilado con Clang 22.1.8) |
| Relojes observados (generación) | GPU ~3000 MHz, memoria 937 MHz (máximo), `fclk` 1200 MHz (el máximo ofrecido es 2000); GPU ~34-39 W, 71-87 °C |

Modelos (de [Unsloth](https://huggingface.co/unsloth)):

- **MoE:** `unsloth/Qwen3.6-35B-A3B-MTP-GGUF:UD-Q2_K_XL` (11,7 GiB; ~3 B parámetros activos; incluye cabeza MTP).
- **Denso:** `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` (12,2 GiB; arquitectura `qwen35`; el archivo también incluye la cabeza MTP).

## Resumen: qué conviene hacer

**1. La mejora más grande no necesita código: MTP.** Activa la decodificación especulativa con la cabeza MTP del propio modelo.

```bash
# MoE Qwen3.6-35B-A3B: 1 token de borrador
llama-server -m <modelo-moe>.gguf -ngl 99 -fa on -c 4096 --spec-type draft-mtp --spec-draft-n-max 1
# Denso Qwen3.8-27B: 2 tokens de borrador
llama-server -m <modelo-denso>.gguf -ngl 99 -fa on -c 4096 --spec-type draft-mtp --spec-draft-n-max 2
```

Conviene pasar siempre un `-c` explícito y moderado: algunos modelos declaran contextos por defecto enormes (cientos de
miles de tokens) que reservan mucha memoria compartida con la GPU.

| Modelo | Sin MTP | Con MTP | Mejor ajuste |
|---|---|---|---|
| MoE 35B-A3B Q2_K_XL | 33,0 t/s | 41,2 t/s (+25 %) | `n-max 1` (aceptación 91 %) |
| Denso 27B Q3_K_XL | 7,03 t/s | 10,63 t/s (+51 %) | `n-max 2` (aceptación 70-91 %) |

En el MoE MTP gana menos porque verificar tokens extra obliga a leer más expertos; en un denso se leen los pesos una
sola vez por paso y el beneficio es mayor. `n-max 3` empeora en ambos; `--spec-draft-p-min` y `ngram-mod` no ayudan.

**2. Parches de Vulkan para esta iGPU** (`patches/vulkan-igpu-improvements.patch`): mejoran la velocidad sin cambiar el
modelo. Resultados frente a un `master` limpio, medidos de forma intercalada el 23-oct (la máquina iba lenta ese día):

| Modelo | Generación (tg) | Prompt (pp512) |
|---|---|---|
| MoE 35B-A3B | **+8-9 %** (30,0/30,5 → 32,8/32,9 t/s) | **+5,5-6,3 %** (248,6/244,7 → 264,2/258,0 t/s) |
| Denso 27B | **+4,6 %** (6,28 → 6,57 t/s) | sin cambio (~72 t/s) |
| MoE, con el cambio 5 (wave32 de iq3_xxs, añadido después de estas medidas) | otro **+2 %** (36,0 → 36,8 t/s) | n/a |
| MoE, con el cambio 6 (fusión C, añadida después; frente al mismo binario sin ella) | otro **+2,1 %** (36,8 → 37,5 t/s) | sin cambio |
| Denso 27B, con el cambio 6 | +0,4 % (dentro del ruido) | n/a |
| MoE, con el cambio 7 (producto entero para iq2_xs; frente al mismo binario sin él) | otro **+1,5 %** (37,15 → 37,71 t/s) | sin cambio |
| MoE con MTP y el cambio 7 (`llama-server`, 3 rondas intercaladas, 3 prompts de 200 tokens) | `n-max 1`: **+3,5 %** (42,5 → 44,0 t/s); `n-max 2`: **+3,0 %** (44,9 → 46,3 t/s); sin MTP en el mismo test +1,4 % | n/a |
| MoE, con el cambio 8 (4 grupos de filas por grupo de trabajo en iq2_xs; frente al cambio 7, 3 rondas intercaladas) | otro **+0,7 %** (37,73 → 38,00 t/s) | sin cambio |

El 20-oct, con la máquina más rápida, el conjunto dio ~+10 % de generación sin MTP y +11-12 % de prompt en el MoE.
Con MTP la ganancia de los parches es menor (+4,4 % medido con MoE, `n-max 1`).

**3. Calidad: igual con lotes grandes; en generación hay diferencias de redondeo.** Con la medición habitual (lotes de
512 tokens: perplexity, KL-divergence, HellaSwag y Winogrande) los resultados son iguales a los de un `master` limpio
(tabla más abajo). En **generación token a token** los parches 1-8 dan diferencias de redondeo del mismo tamaño que
desactivar las fusiones en un llama.cpp sin modificar (KL media ~5e-3, misma predicción más probable 97-98 %): ver
"Calidad".

## Cómo reproducirlo

```bash
sudo apt install -y libvulkan-dev glslc spirv-headers ninja-build vulkan-tools   # Ubuntu
git clone https://github.com/ggml-org/llama.cpp && cd llama.cpp
git checkout 9df0b73c7
git apply /ruta/a/patches/vulkan-igpu-improvements.patch
cmake -B build -G Ninja -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF
cmake --build build -j
```

El parche se verificó con `git apply --check` sobre un `9df0b73c7` limpio. En commits posteriores puede necesitar ajustes.
`patches/experimental-mtp-rollback-identity.patch` es el mismo conjunto **más** un experimento descartado (ver
"Lo que no funcionó"); no lo recomiendo. Ese parche **no incluye los cambios 6, 7 y 8** (fusión C e iq2_xs entero): es el
conjunto anterior, y aplicar los dos a la vez no está probado.

Scripts en `scripts/` (todos parametrizados con variables de entorno, sin rutas personales):

| Script | Para qué |
|---|---|
| `ab_bench.sh` | Benchmark A/B **intercalado** de dos compilaciones (`llama-bench`) |
| `mtp_sweep.sh` | Barrido de configuraciones de MTP con `llama-server` (velocidad y aceptación) |
| `profile.sh` + `analizar.py` | Perfil por operación con `GGML_VK_PERF_LOGGER` |
| `lp_run.sh` + `lp_cmp.py` | Compara probabilidades por token entre dos ejecuciones (ver "Metodología") |
| `quality.sh` | Perplexity, KL-divergence, HellaSwag y Winogrande con `llama-perplexity` |

## Metodología (lo que aprendimos sobre medir)

- **La velocidad de la máquina varía entre sesiones** (hasta ~7 % en el mismo día y ~20 % entre días; el 20-oct el
  original daba ~312 t/s de prompt y el 23-oct ~245 t/s, sin que lo hayamos explicado). Por eso **solo se comparan
  ejecuciones intercaladas** (original, nuevo, original, nuevo) y se descartan mejoras de ±2 %.
- **El logger de rendimiento de Vulkan serializa las operaciones**, así que los tiempos absolutos por operación salen
  inflados; solo son útiles los porcentajes relativos.
- **Los modelos híbridos recurrentes (Qwen3.5/3.6/3.8, con capas "gated delta net") amplifican diferencias de redondeo.**
  Cualquier cambio de orden o de fusiones del grafo cambia las probabilidades por token (media ~4e-3, máximo ~6e-2 en
  el 27B, y el texto empieza a divergir hacia el token ~190) **incluso en el llama.cpp sin modificar**: basta con
  desactivar las fusiones (`GGML_VK_DISABLE_FUSION=1`) o cambiar el orden del optimizador. Verificar una optimización
  comparando 100-300 tokens de texto **no es suficiente**.
- Protocolo que sí funciona: comparar *en el mismo entorno* con el cambio activado y desactivado (por ejemplo con un
  interruptor temporal) y calibrar la diferencia contra ese ruido; para pruebas exactas, dejar activa solo la fusión bajo
  prueba. Los scripts `lp_run.sh`/`lp_cmp.py` implementan la comparación de probabilidades por token.
- Corrección honesta: durante el trabajo se afirmó que los cambios eran "idénticos bit a bit"; no es cierto en general.
  La fusión A, por sí sola, sí es exacta; la B cambia el grafo y, con ello, qué fusiones se forman (ruido de redondeo).

## La investigación, paso a paso

### 1. Línea base e instalación frente a clon

Con el binario instalado (build 11706, 19-oct) y el MoE: pp512 **312 t/s**, pp2048 305 t/s, tg128 **34,5 t/s**.
Compilar el clon del 20-oct tal cual (59 commits más, ninguno de Vulkan relevante para esta GPU) **no mejora nada**
(el tg salió ~3 % más bajo, posiblemente por GCC frente a Clang; no verificado).

### 2. Flags y variables de entorno: sin efecto (MoE)

| Variante | pp512 | tg128 |
|---|---|---|
| Base | 312 | 34,5 |
| `-ub 256` | 254 | 34,4 |
| `-ub 1024` | 311 | 34,8 |
| `-fa 0` | 309 | 34,8 |
| `GGML_VK_DISABLE_MMVQ` / `GGML_VK_FORCE_MMVQ` | 310 / 311 | 35,0 / 34,8 |
| `GGML_VK_DISABLE_COOPMAT` | 239 | 34,7 |
| `GGML_VK_DISABLE_FUSION` | 300 | 33,2 |
| `RADV_PERFTEST=cswave32` | 334 (frente a 349) | sin cambio |
| `RADV_PERFTEST=nogpl` | sin cambio | sin cambio |

La generación se queda en ~35 t/s con cualquier combinación: está limitada por el ancho de banda de la memoria compartida.

### 3. MTP (resultados completos)

MoE, servidor, 4 prompts de 300 tokens, `temperature 0` (media de t/s y aceptación de borradores):

| Configuración | Media | Aceptados |
|---|---|---|
| sin MTP | 33,0 | n/a |
| `n-max 1` | **41,2** | 91 % |
| `n-max 2` | 39,8 | 82 % |
| `n-max 2`, `p-min 0,7` | 38,7 | 95 % |
| `n-max 3`, `p-min 0,7` | 39,4 | 93 % |
| `n-max 4`, `p-min 0,85` | 39,4 | 97 % |
| `n-max 1` + `ngram-mod` | 38,7 | 91 % |

Denso 27B, 3 prompts de 200 tokens:

| Configuración | t/s | Aceptados |
|---|---|---|
| original, sin MTP | 6,70 | n/a |
| parches, sin MTP | 7,03 | n/a |
| parches, `n-max 1` | 9,76 (×1,39) | 79-97 % |
| parches, `n-max 2` | **10,63 (×1,51)** | 70-91 % |
| parches, `n-max 3` | 9,63 (×1,37) | 70-83 % |

En el MoE, un paso con MTP cuesta ~42 ms y produce ~1,84 tokens (~23 ms/token frente a ~29 ms sin MTP): verificar 2
tokens cuesta ~1,39× un token (los expertos pasan de ~6,3 a ~10,6 ms) y el paso de borrador ~5,3 ms (13 %).

### 4. Perfil por operación (`GGML_VK_PERF_LOGGER`)

- **MoE, generación (~29 ms/token):** `MUL_MAT_VEC` denso (q5_K/q6_K/q4_K de atención y capas compartidas) 51 % a
  ~86-104 GB/s efectivos, es decir, **cerca del techo de memoria**; expertos `MUL_MAT_ID` ~21 %; operaciones pequeñas
  (`CPY`, `GET_ROWS`, `GATED_DELTA_NET`) ~16 %. La GPU cubre el 102 % del tiempo por token: no hay cuello de CPU.
- **MoE, prompt:** `MUL_MAT_ID` 54,6 % del grafo, con los expertos iq2_xs/iq3_xxs a ~1 TFLOPS/s frente a 3,7-4,4 TFLOPS/s
  de las matmul densas. Una ablación del shader mostró que las cargas de A y B suman ~45-50 % del kernel.
- **Denso, generación (~156 ms/token):** 89 % `MUL_MAT_VEC` a 85-101 GB/s. Techo ~131 ms/token.

### 5. Cambios de código (`patches/vulkan-igpu-improvements.patch`)

| # | Cambio | Dónde | Efecto medido |
|---|---|---|---|
| 1 | El selector de tamaño de tile de `MUL_MAT_ID` usa los tokens **por experto** (no el total) si `m >= 2048` | `ggml_vk_mul_mat_id_q_f16` | iq3_xxs (m=2048) 366 → 243 ms; pp512 312 → ~334 t/s (+6,7 %). Con m=512 (iq2_xs) el tile pequeño empeora, por eso la condición |
| 2 | B en f16 para AMD con coopmat1 en la ruta de expertos (antes solo Intel) | mismo sitio | pp512 337,8 → 347,1 (+2,8 %) |
| 3 | **Fusión A:** `GATED_DELTA_NET` + el `CPY` que escribe el estado recurrente: el shader escribe directo en la caché | `gated_delta_net.comp` + patrón de fusión | `CPY` 60 → 30 por token; tg +3,5-5 % |
| 4 | **Fusión B:** si la copia de estado (`GET_ROWS`) es una identidad (una secuencia, sin reversión, sin estado nuevo), `build_rs` devuelve una **vista** de la caché | `llama-graph.cpp`, `llama-memory-recurrent.cpp` | `GET_ROWS` 62 → 2 por token; tg +5 %. **Solo si la caché está en buffers Vulkan** (no se pudieron probar otros backends) |
| 5 | `MUL_MAT_ID_VEC` de iq3_xxs con `k <= 512` como un único grupo de 32 hilos (wave32) | `ggml-vulkan.cpp` | kernel 65,5 → 50,8 µs (−22 %); tg MoE +2 % |
| 6 | **Fusión C:** `CONCAT`(estado de convolución, qkv) + `SSM_CONV` + `SILU` + el `CPY` que guarda el nuevo estado de convolución, en **un solo dispatch**: el shader lee estado y qkv sin materializar el concat y escribe el estado nuevo en la caché | `ssm_conv.comp` (variante `FUSE_CONV_CPY`), `ggml-vulkan.cpp` | `CONCAT`+`CPY`+`SSM_CONV_SILU` 18,5 → 6,15 µs por capa recurrente; tg MoE +2,1 %, denso +0,4 % (ruido). Solo con 1 token por secuencia, kernel de ancho 4, F32 y sin MTP |
| 7 | **Producto escalar entero para iq2_xs en los expertos** (`MUL_MAT_ID`, generación): nueva función `mmvq_dot_product` para `IQ2_XS` en el camino que cuantiza las activaciones a q8_1 y usa `dotPacked4x8EXT` (2 productos enteros por 8 pesos, en lugar de 8 `fma` con selección de signo); los signos se expanden a una máscara por byte y se aplican con `(grid ^ neg*0xFF) + neg` | `mul_mat_vecq_funcs.glsl`, `mul_mat_vecq.comp`, generador de shaders, `ggml-vulkan.cpp` | kernel iq2_xs (m=512, n=8, k=2048) 42,0 → 36,8 µs (−12,5 %); tg MoE +1,5 %. **Cambia la numérica** (activaciones en q8_1); en generación las diferencias son del tamaño del ruido propio del modelo (ver "Calidad"). Solo se usa donde la regla de Vulkan elige este camino (AMD: `k >= 2048`, o 2 o más tokens) |
| 8 | En el producto entero de iq2_xs (cambio 7), cada grupo de trabajo calcula **4 grupos de 4 filas uno tras otro** en lugar de uno: se lanzan 4 veces menos grupos y la rejilla de 4 KB se copia a memoria local 4 veces menos. Es una constante de especialización (`ROW_GROUPS`, por defecto 1) que el host pone a 4 solo en iGPU AMD RDNA3/4 | `mul_mat_vecq.comp`, `ggml-vulkan.cpp`, `test-backend-ops.cpp` | kernel iq2_xs 36,5 → 34,3 µs (−7 %); tg MoE +0,7 %. **Resultado idéntico bit a bit** al cambio 7 (cada fila se calcula igual) |

Detalles y trampas:

- Los cambios 3 y 4 componen: con B activa, el estado de entrada de la fusión A es la propia caché; el kernel carga todo
  el estado en registros antes de escribir, así que el alias exacto es seguro (hubo que permitirlo en la comprobación
  de solapamiento de Vulkan).
- El cambio 5 reutiliza la ranura de pipeline `DMMV_WG_SIZE_LARGE`, que en AMD nunca se selecciona; es un atajo
  comentado en el código. Una versión limpia añadiría un campo propio. Solo medido en RDNA3.
- Fusión C: los seis nodos (`CONCAT`, dos `VIEW`, `CPY`, `SSM_CONV`, `SILU`) **no son contiguos** en el grafo del modelo,
  porque `build_conv_state` expande el `CPY` antes de crear el `SSM_CONV`. El optimizador de grafos de Vulkan los agrupa
  (y fija una dependencia de asignación para que la salida del `SILU` no pise el qkv). Ese optimizador solo lo llama el
  planificador, no `test-backend-ops`, así que el test (`SSM_CONV_CONCAT_CPY`) construye un grafo con los nodos ya juntos.
- Fusión C: con una suma secuencial en el shader el texto divergía a temperatura 0 por el orden de las sumas en fp32; con
  el mismo `dot` de 4 elementos que usa el kernel sin fusionar, el texto sale **idéntico** (MoE 150 tokens, denso 60).
  Es otro ejemplo de por qué conviene calcular igual que el kernel original (ver "Metodología").
- Cambio 7: el **ajuste de filas por grupo de trabajo** (1/2/4/8 → 273/204/184/192 ms) ya estaba en su óptimo (4). El kernel
  queda a ~65 GB/s efectivos frente a ~100 GB/s de las matmul densas, así que no está en el techo de memoria; llegar ahí
  daría como mucho otro ~+4 % (estimación, no medida) y no he encontrado cómo. Los iq3_xxs de bajada (`k=512`) no
  pasan la regla `k >= 2048` en generación sin MTP y no tienen camino entero.
- Cambio 7: la comprobación habitual de perplexity con lotes de 512 **no ejercita este camino** (usa la matmul por
  bloques, no el mat-vec), así que da el mismo valor sin importar lo que se cambie. La calidad se midió token a token
  (`llama-perplexity -b 1 -ub 1`) y, para la referencia, con las bibliotecas del original (ver "Calidad").
- Cambio 8: sin la copia de la rejilla a memoria local (versión incorrecta, solo para cronometrar) el kernel baja a 31,9 µs:
  la copia cuesta ~5 µs de ~36. Agrupar filas lo reduce en parte. Con 2 grupos no cambia nada, 4 es el óptimo y 8 empeora:
  con m=512 y 8 expertos, 4 grupos dejan 256 grupos de trabajo por llamada, que encaja con los 8 CU de esta iGPU. En una
  GPU grande dejaría unidades ociosas, por eso solo se activa en iGPU (`uma`); no se probó en otras GPU.
- Cambio 8: los casos de iq2_xs que ya tenía `test-backend-ops` (`k <= 768`) **no pasan por el producto entero** en AMD;
  se añadieron 6 con `k = 2048` (m = 512/200/203, 1 y 2 tokens), que sí fallan si se rompe el reparto de filas a propósito.
  Comprobado además: perplexity token a token idéntica a la del cambio 7 (5,7276) y texto a temperatura 0 idéntico byte a byte.
- No hay prueba unitaria que cubra `build_rs`; la verificación es de extremo a extremo.

### 6. Lo que no funcionó (para no repetirlo)

- **Más filas por workgroup** (`NUM_ROWS` 8/16) en iq2_xs, iq3_xxs e iq3_s denso: sin mejora o peor.
- **wave32 en iq2_xs** o en iq3_xxs con `k >= 1024`: peor. **Tabla de rejilla en f16 en memoria local:** 1,8× más lento.
- Diagnóstico: iq2_xs, iq3_xxs (con k=2048) e iq3_s están **limitados por cálculo, no por memoria** (~80 operaciones de
  vector por cada 16 pesos). Llegar a 90-100 GB/s exigiría un shader nuevo con producto escalar entero (q8_1).
- **Afinar el producto entero de iq2_xs** (cambio 7), además de lo que quedó como cambio 8. Kernel de referencia ~36,5 µs:
  escalas combinadas en enteros, sin cambio; rejilla leída de un array constante en vez de memoria local, ~16 100 µs (RADV
  la materializa por invocación); wave32, ~43 µs; tabla de 128 máscaras de signo en memoria local, ~38,6 µs; rejilla de
  2 bits por peso (1 KB) decodificada con aritmética, ~50 µs. Lección: en este kernel cuesta tanto la ALU como cada lectura
  extra de memoria local.
- **El control "sin int-dot"** (`GGML_VK_DISABLE_INTEGER_DOT_PRODUCT`) no cambió nada, así que la ausencia de camino
  int8 no explicaba la lentitud de los expertos.
- **Atajo de identidad también con MTP** (`patches/experimental-mtp-rollback-identity.patch`): funciona y es exacto
  en un entorno controlado, pero alternar entre el grafo con copia y el grafo con vista obliga a reconstruir el grafo
  (~4-5 ms), más que lo que se ahorra (~1,5 ms). Hacen falta ≥4 pasos seguidos para compensar. Ganancia: +2,7-3 % en
  el MoE con texto predecible, 0 a −0,5 % en el denso. **Revertido.**
- **MTP:** `n-max 3`, `--spec-draft-p-min` y combinar con `ngram-mod` no mejoran.
- **Flags de RADV** (`cswave32`, `nogpl`): sin mejora.

### 7. Calidad (misma GGUF, `master` limpio frente a parches; `quality.sh`)

| Medida | MoE 35B-A3B Q2_K_XL | Denso 27B Q3_K_XL |
|---|---|---|
| Perplexity (WikiText-2, 20 trozos de 512) | 7,0841 → 7,0841 | 7,0804 → 7,0804 |
| KL-divergence media | ≈ 0 (máx. 5,6e-5) | ≈ 0 (máx. 6,3e-5) |
| Misma predicción más probable | 100,000 % | 100,000 % |
| HellaSwag (400 tareas) | 80,75 % → 80,75 % | 81,00 % → 81,00 % |
| Winogrande (500 tareas) | 73,20 ± 1,98 → igual | 77,00 ± 1,88 → igual |

Esta tabla se midió con los cambios 1-5 y con lotes de 512 tokens (el camino de procesamiento de prompt).

**Corrección (24-oct):** las medidas de calidad de la fusión C y del cambio 7 que publiqué antes eran inválidas: la
"referencia limpia" era una copia del binario original que, por tener la ruta de bibliotecas (`RUNPATH`) fijada a mi
carpeta de compilación, cargaba **las bibliotecas modificadas**, es decir, comparaba el código nuevo consigo mismo. Hay que
ejecutar las copias con `LD_LIBRARY_PATH=<su carpeta>` y comprobarlo con `ldd`. Repetido con una referencia realmente
limpia (`9df0b73c7` con sus propias bibliotecas), MoE, contexto de 512:

| Caso | PPL referencia | PPL candidato | KL media | KL máx. | Misma predicción | RMS de Δp |
|---|---|---|---|---|---|---|
| Parches 1-7, lotes de 512 (20 trozos) | 7,0841 | 7,0841 | ≈ 0 | 5,6e-5 | 100,000 % | 0,001 % |
| Parches 1-7, token a token (`-b 1 -ub 1`, 4 trozos) | 5,7092 | 5,7276 (+0,32 %) | 5,2e-3 | 0,51 | 97,8 % | 2,2 % |
| *Calibración:* `master` limpio con `GGML_VK_DISABLE_FUSION=1`, lotes de 512 | 7,0841 | 7,0788 | 5,3e-3 | 1,81 | 96,7 % | n/d |
| *Calibración:* `master` limpio con `GGML_VK_DISABLE_FUSION=1`, token a token | 5,7092 | 5,7140 | 4,3e-3 | 0,24 | 97,7 % | n/d |

Lectura: con lotes de 512 los parches 1-7 son **exactos** (idénticos al original). En generación token a token **no** lo
son: la KL media es ~5e-3 y la predicción más probable cambia en ~2 % de los tokens, igual que cuando solo se desactivan
las fusiones en el llama.cpp original (4-5e-3, 97-98 %). Es la sensibilidad numérica propia de este modelo (la
recurrencia amplifica el orden de las sumas), no un efecto de un cambio concreto; la perplexity cambia +0,3 % con una
incertidumbre de ~0,4 puntos. Lo que dije antes ("KL ≈ 0", "100 %" en generación) era falso. No se atribuyó la diferencia a
un cambio concreto, ni se repitió con el denso ni con HellaSwag/Winogrande.

Los valores mínimos de KL salen ligeramente negativos por la cuantización del fichero de referencia (ruido, no un error).
Con 400-500 tareas el error es de ~2 puntos: estas pruebas confirman que los parches no alteran el modelo, pero **no
distinguen** entre modelos de calidad parecida (la diferencia de 3,8 puntos en Winogrande entre el denso y el MoE está
dentro del error combinado).

### 8. Observaciones de hardware

- La generación depende del ancho de banda: la memoria va a su máximo (937 MHz) pero el `fclk` aparece a 1200 MHz de los
  2000 disponibles. **Hipótesis sin probar:** subir el perfil de energía (`platform_profile=performance`) y conectar el
  cargador podría ayudar. No se midió.
- La iGPU llegó a 87 °C en prompt largo; puede haber limitación térmica.

### 9. NPU y ROCm

- **NPU (XDNA2):** el controlador del kernel está cargado, pero **llama.cpp no tiene backend para la NPU de AMD** (los
  únicos con NPU son OpenVINO para Intel y Hexagon para Qualcomm). Existen proyectos aparte (FastFlowLM/Lemonade) con sus
  propios formatos y modelos pequeños, no probados aquí. La NPU comparte la misma memoria, así que en generación no
  puede superar el ancho de banda; su ventaja citada es el consumo.
- **ROCm/HIP:** Ubuntu 26.04 trae ROCm 7.1 y se instalaron los paquetes, pero **la prueba no se llegó a ejecutar**; el
  soporte oficial de gfx1152 (Krackan) no está confirmado y la evidencia externa favorece a Vulkan en generación.

### 10. Otra cuantización: expertos k-quant y el cambio 9 (propuesto, no implementado)

Hipótesis: los expertos IQ (iq2_xs, iq3_xxs) están limitados por cálculo en esta GPU, así que un fichero con expertos
k-quant, que usan el camino entero (MMVQ), podría generar más rápido. Se probó `bartowski/Qwen_Qwen3.6-35B-A3B-GGUF`
`Q2_K` (12,6 GiB): todos los expertos en q2_K/q3_K, ningún IQ, y **con cabeza MTP** (otros Q2_K, como el `i1-Q2_K` de
mradermacher, no la tienen). Antes de descargarlos se miraron los tipos de los tensores leyendo solo la cabecera GGUF.
Medido con los cambios 1-8 frente al `UD-Q2_K_XL` de unsloth:

| | bartowski `Q2_K` | unsloth `UD-Q2_K_XL` |
|---|---|---|
| Tamaño | 12,6 GiB | 11,7 GiB |
| tg128 (3 rondas intercaladas) | 34,9 t/s (−9,5 %) | 38,6 t/s |
| pp512 | 324 t/s | 323 t/s |
| Con MTP `n-max 1` / `n-max 2` (`llama-server`, 3 prompts, sin intercalar) | 46,7 / 50,0 t/s (acepta 87 / 85 %) | 47,0 / 49,9 t/s (86 / 76 %) |
| Perplexity WikiText-2 (20 trozos de 512) | 7,343 (+3,7 %) | 7,084 |
| HellaSwag (400 tareas) | 80,25 % | 80,75 % (dentro del error) |

**Conclusión: el `UD-Q2_K_XL` sigue siendo la mejor opción** (más pequeño, mejor calidad, más rápido sin MTP e igual con MTP).

El perfil explica por qué la hipótesis falló:
- **Gate/up** (k=2048): q2_K 36,3 µs por llamada frente a 34,1 µs de iq2_xs. Con los cambios 7 y 8 los IQ ya rinden igual.
- **Down** (m=2048, **k=512**): q3_K 157 µs y q2_K 115 µs frente a 51 µs de iq3_xxs. La regla de Vulkan solo elige el
  camino entero en AMD con `k >= 2048` o con 2 o más tokens. Con un token y k=512 los k-quant van por el mat-vec que
  descuantiza, que con tan pocos bloques por fila deja muchos hilos ociosos (~23 GB/s efectivos con q3_K).
- La cabeza de salida es q6_K en bartowski (4,3 ms por token) y q4_K en unsloth (2,8 ms).

**Cambio 9 (propuesto):** con `GGML_VK_FORCE_MMVQ=1`, que ya existe y obliga a usar el camino entero, el down baja a
70 µs (q3_K) y 47 µs (q2_K), y el `Q2_K` pasa de 34,9 a **38,9 t/s (+11 %)**, un 1,7 % por encima del `UD-Q2_K_XL`. Al
`UD-Q2_K_XL` forzarlo no le cambia nada (38,2 t/s), porque sus expertos down son iq3_xxs, que no tiene camino entero.
La propuesta es que la regla de selección (`ggml_vk_should_use_mmvq`) use el camino entero en `MUL_MAT_ID` para los
k-quant aunque `k < 2048` en AMD. Ayudaría a cualquier MoE con expertos k-quant y FFN de experto pequeña, pero **no
está en el parche**: falta medir en qué tipos y tamaños gana y si empeora algún caso denso (la variable de entorno afecta
a todos los mat-vec). Mientras tanto, quien use un MoE con expertos k-quant en una GPU AMD puede probar la variable.

## Limitaciones

- Un solo equipo, un solo controlador (RADV 26.0.8), dos modelos de la misma familia. Los números absolutos dependen del
  día (energía, temperatura) y solo las comparaciones intercaladas son fiables.
- Las demás arquitecturas recurrentes que comparten `build_rs` (mamba, rwkv, jamba, kimi…) solo se probaron con pesos
  aleatorios (`test-llama-archs`), no con modelos reales. Los demás backends (CUDA, Metal…) quedan **desactivados** para
  la fusión B por no poder probarse.
- Pruebas unitarias ejecutadas: `test-backend-ops` (`MUL_MAT_ID`, `MUL_MAT`, `GATED_DELTA_NET*`, `CPY`, `GET_ROWS`,
  `CONCAT`, `SSM_CONV*` y el nuevo `SSM_CONV_CONCAT_CPY`) y `test-llama-archs`, todas correctas con los ocho cambios.
- **Cambio 8** no se midió con MTP ni en el denso (el denso no tiene expertos, así que no le afecta).
- **Cambio 7 con MTP (solo MoE):** se midió la velocidad (tabla de arriba). La aceptación de borradores no cambia de forma
  apreciable (`n-max 1`: 84,2 % → 86,0 %; `n-max 2`: 76,1 % → 75,7 %). El texto a temperatura 0 diverge en algunos prompts
  entre activar y desactivar el cambio (primer carácter distinto entre el 138 y el 1156), igual que diverge entre MTP y sin
  MTP con el mismo código: es el ruido numérico recurrente que describe "Metodología", no se midió KL con MTP. No se midió
  en el denso.
- Estimaciones marcadas como tales en el texto no se midieron.

## Créditos

- [llama.cpp / ggml](https://github.com/ggml-org/llama.cpp) (MIT), de ggml-org y sus colaboradores.
- Modelos GGUF de [Unsloth](https://huggingface.co/unsloth) sobre los modelos Qwen.
- Investigación y parches hechos junto con Claude (Anthropic) mediante Claude Code.

## Autor y contacto

Damian Sanguino — <demian63s@gmail.com>

Si algo de estas notas te sirve, o si mides algo distinto en un equipo parecido (otra iGPU RDNA3.5, otro controlador),
me interesa saberlo.
