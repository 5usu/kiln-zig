#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZIG_BIN="${ZIG:-$PWD/scripts/zig}"
mkdir -p bench/baseline/lib
"$ZIG_BIN" build-lib bench/baseline/src/c_api.zig -dynamic -lc -OReleaseFast -mcpu=native -femit-bin=bench/baseline/lib/libkiln.so
