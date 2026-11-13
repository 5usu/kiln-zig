# Draft post

Took Kiln, my native Zig JSON parser, further.

On my i3 laptop: 1.34× yyjson throughput on public citm_catalog.json. Owned strings, parse + free included.

Ahead on 2/7 workloads; yyjson wins the rest. Source, tests and every benchmark sample included.

## Evidence and follow-up notes

The main result is workload-specific. Use bench/versus-yyjson.png when posting so all wins and losses remain visible. The same-condition original-parser comparison is in BENCHMARKS.md.

A conservative SIMD punctuation count bounds node capacity. ASCII scanning and copying are fused; hot ASCII parsing is separated from escape/Unicode handling. Numbers are scanned once and use a credited Zig standard-library conversion helper. The owned DOM occupies one reserved storage block, which is retained until free.

Do not describe this as a general win over yyjson, or reuse the original 75%-less-memory claim: the allocation layout and measurements have changed.
