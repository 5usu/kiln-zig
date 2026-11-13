# Reproduce Kiln's tests, benchmarks, and images

The one-command route is `./scripts/reproduce.sh` from the repository root. It overwrites local reports with your new measurements. Python 3.12+ is needed for the pinned plotting environment; building/testing the parser itself needs Python 3.9+.

## 1. Build with the pinned compiler

```sh
./scripts/build.sh
```

`scripts/zig` uses an existing Zig 0.15.2, or downloads the official Linux x86-64 archive into `.tools/` and verifies its SHA-256. Set `ZIG=/path/to/zig` to select a compiler. The C baselines are built using the same compiler's `zig cc`, at `-O3 -march=native`, without LTO. Kiln uses ReleaseFast and a native CPU target.

## 2. Recreate and verify the inputs

```sh
python3 scripts/datasets.py --fetch-public
```

Four generated workloads are deterministic: telemetry, integers, ASCII strings, and escaped strings. The three public inputs are Twitter, Canada, and CITM from a pinned nativejson-benchmark revision. Downloaded bytes must match `bench/datasets.json`. Public input files and generated build artifacts are ignored by Git; their generation/download instructions and hashes are versioned.

## 3. Run the checks

```sh
CASES=100000 ./scripts/test.sh
```

This runs the unit tests in all three optimization/safety modes, then checks ReleaseFast and ReleaseSafe C API builds. In each build it runs 100,000 generated semantic cases, 100,000 mutation comparisons, and 100,000 arbitrary byte inputs, plus the required corpus, string boundaries, and workload comparisons. The finite-f64 policy is matched in the Python reference decoder.

The required JSONTestSuite fixtures are vendored, including invalid byte sequences; `.gitattributes` preserves them byte-for-byte. Exact counts are printed and saved in `tests/correctness*.json`. CI uses a smaller deterministic count for turnaround time; checked-in laptop reports retain the larger run.

## 4. Measure all four implementations

```sh
./scripts/build_baseline.sh
python3 scripts/bench.py --baseline-lib bench/baseline/lib --samples 11 --duration-ms 250 --cpu 0
```

Choose a logical CPU available to your process. List allowed CPUs on Linux with:

```sh
python3 -c 'import os; print(sorted(os.sched_getaffinity(0)))'
```

The benchmark includes current Kiln, the original version, cJSON, and yyjson. Order is randomized across rounds. Each case is warmed up and calibrated to a nominal 250 ms timed interval. Both parse + free and parse + traversal + free are recorded. Input file reads and process startup are outside the timer.

All parsers own their decoded strings and receive fresh document allocations. No reusable arena, in-situ mode, or pooled cJSON allocator is used. Memory instrumentation runs separately from timing. Keep power conditions and background load stable when comparing versions; the runner records initial/final power state and the governor.

`bench/results.json` contains every timing sample, memory counters, semantic checksums, source/dataset hashes, compiler text, CPU, and dependency revisions. Kiln stores numbers as f64; checksum comparison normalizes the C libraries' numbers to f64 too.

## 5. Regenerate the charts and report

```sh
python3 -m venv .venv-report
.venv-report/bin/python -m pip install -r scripts/requirements-report.txt
.venv-report/bin/python scripts/report.py
```

This writes `BENCHMARKS.md`, `bench/comparisons.json`, PNG/SVG figures, and a short post draft. Ratio intervals use 5,000 deterministic paired sample-round bootstrap resamples. They capture variation within the run, not systematic differences or performance on other hardware.

To redraw the published figures without rebenchmarking, run only this step against the checked-in results. To replace the data, run the measurement step first.

## What CI does

GitHub Actions checks out a fresh copy, provisions Python 3.12, runs parser/corpus/differential tests, builds the original baseline, exercises the benchmark on two workloads, and verifies that the published report can be rendered with the pinned dependencies. CI smoke timings are not used for the laptop performance claims.

The GitHub runner has different hardware and power management. Passing CI demonstrates that the project builds and the reproduction tools work there; it does not reproduce the laptop's absolute throughput.
