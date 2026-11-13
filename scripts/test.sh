#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG_BIN="${ZIG:-$PWD/scripts/zig}"
"$ZIG_BIN" build test -j2
"$ZIG_BIN" build test -Doptimize=ReleaseFast -j2
"$ZIG_BIN" build test -Doptimize=ReleaseSafe -j2
./scripts/build.sh
python3 scripts/datasets.py --fetch-public
python3 scripts/check.py --cases "${CASES:-50000}" | tee tests/correctness.json
"$ZIG_BIN" build -Doptimize=ReleaseSafe -Dcpu=native --prefix zig-out-safe -j2
KILN_LIB="$PWD/zig-out-safe/lib/libkiln.so" python3 scripts/check.py --cases "${CASES:-50000}" | tee tests/correctness-safe.json
