#!/usr/bin/env bash
# Full local reproduction: tests, fresh measurements, reports, and figures.
set -euo pipefail
cd "$(dirname "$0")/.."
REPORT_PYTHON="${REPORT_PYTHON:-python3}"
"$REPORT_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else "Plot reproduction requires Python 3.12+; set REPORT_PYTHON to its executable.")'
export CASES="${CASES:-100000}"
BENCH_CPU="${BENCH_CPU:-$(python3 -c 'import os; print(min(os.sched_getaffinity(0)))')}"
BENCH_SAMPLES="${BENCH_SAMPLES:-11}"
BENCH_DURATION_MS="${BENCH_DURATION_MS:-250}"
./scripts/test.sh
./scripts/build_baseline.sh
python3 scripts/bench.py --baseline-lib bench/baseline/lib --cpu "$BENCH_CPU" --samples "$BENCH_SAMPLES" --duration-ms "$BENCH_DURATION_MS"
"$REPORT_PYTHON" -m venv .venv-report
.venv-report/bin/python -m pip install --disable-pip-version-check -r scripts/requirements-report.txt
.venv-report/bin/python scripts/report.py
