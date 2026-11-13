# Original Kiln baseline

`src/` preserves the initial Kiln implementation from this session, before the yyjson optimization work. It uses two growable buffers and compacts them after parsing. The C API is ABI-compatible with the current benchmark harness.

The original battery-powered measurements are retained for historical reference. Their absolute throughput should not be compared with later AC-powered results.

To compare both implementations under the same current conditions:

```sh
./scripts/build.sh
./scripts/build_baseline.sh
python3 scripts/bench.py --baseline-lib bench/baseline/lib --samples 11 --duration-ms 250 --cpu 0
```

The benchmark interleaves the original Kiln shared library (`kiln_v1`), current Kiln, cJSON, and yyjson. Every implementation uses fresh owned documents and includes freeing them in the timer. The original parser source is MIT licensed under the project's LICENSE.
