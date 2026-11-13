#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG_BIN="${ZIG:-$PWD/scripts/zig}"
CC_CMD=("$ZIG_BIN" cc)
if [[ -n "${CC:-}" ]]; then CC_CMD=("$CC"); fi
"$ZIG_BIN" build -Doptimize=ReleaseFast -Dcpu=native -j2
mkdir -p bench/bin
"${CC_CMD[@]}" -std=c11 -O3 -march=native -Wall -Wextra -c vendor/cJSON/cJSON.c -o bench/bin/cjson.o
"${CC_CMD[@]}" -std=c11 -O3 -march=native -Wall -Wextra -c vendor/yyjson/yyjson.c -o bench/bin/yyjson.o
"${CC_CMD[@]}" -std=c11 -O3 -march=native -Wall -Wextra bench/benchmark.c bench/bin/cjson.o bench/bin/yyjson.o -Lzig-out/lib -lkiln -Wl,-rpath,'$ORIGIN/../../zig-out/lib' -lm -o bench/bin/benchmark
