# How Kiln works

Read `Document.parse()` and then `Parser.value()` in `src/root.zig`. The public API returns an owned document; parsing never stores pointers into the caller's input.

## Storage layout

One allocation contains a node region followed by string storage. Nodes are 16-byte `extern struct` values: a 64-bit payload, 32-bit `next` index, and 32-bit tag. The payload contains:

- Number: bits of a finite IEEE-754 double.
- String: byte offset in the low 32 bits, length in the high 32 bits.
- Array/object: element/member count.
- Null/boolean: the tag supplies the value.

Nodes are preorder. `next` identifies the first node after a value's entire subtree; a scalar's `next` is its index plus one. Object keys are string nodes immediately before their value.

For `{"a":[1,2],"b":true}`, the tape is object, key `a`, array, number 1, number 2, key `b`, true. Following the array's `next` jumps to key `b`. `get()` demonstrates how to walk object members; arrays use the same subtree-skipping idea.

## Why the reservation bound is safe

The root needs one node. Every additional node is introduced by an opening `[`, opening `{`, comma, or colon: the first array element follows `[`, the first object key follows `{`, subsequent elements/keys follow commas, and object values follow colons.

Counting those bytes across the complete raw input therefore bounds the number of nodes. Counting punctuation inside strings, or the start of an empty container, only overestimates the count. No string-state machine is needed for the reservation scan. A 32-byte SIMD comparison and popcount implement it.

The node allocation uses checked multiplication/addition. The parser validates complete JSON grammar afterward; the capacity count is not a validity test. Appending a node has a debug assertion against the reserved capacity. Since each real node takes at least a byte and input length is limited to u32, real node indices also fit u32.

Decoded strings never occupy more bytes than their raw source: plain UTF-8 is copied as-is, simple escapes shrink, and Unicode escapes emit at most four bytes from at least six source bytes. Source length is therefore a conservative bound for total decoded string storage.

## Allocation trade-off

The allocator receives one aligned storage request. `nodes` and `strings` are ArrayList-shaped views into that block; they never grow and must not be deinitialized separately. `Document.deinit()` frees the single block. The C API separately allocates its small document wrapper, so its measured parse/free workload uses two allocations.

Capacity is retained until destruction rather than shrunk at parse completion. This removes growth, copies caused by reallocating buffers, and shrink/system-call overhead, but increases retained requested memory on some inputs. The benchmark includes the unused capacity in its memory figures.

The original two-buffer, compact-after-parse design is preserved in `bench/baseline/src/`. The interleaved original-parser benchmark makes the speed/memory trade-off measurable under the same power conditions.

## String hot path

`scanAscii()` checks 32 bytes at a time for quotes, backslashes, controls, and non-ASCII bytes. A bit cast converts comparison lanes into a u32 mask; `@ctz()` locates the first special byte. A clean ASCII vector is copied directly to output while scanning, so the string is not scanned and then separately copied.

The bounds check precedes every vector load. A short-copy helper uses overlapping first/last loads entirely within the actual run. A scalar tail handles the last bytes without requiring input padding. Short ASCII keys finish in the hot parser; Unicode/escape handling is a separate function.

Raw UTF-8 is validated using the standard library. Hex escapes use a nibble table and validate surrogate pairing. A decoded Unicode escape uses a four-byte store within the private reserved output buffer, then advances by its actual encoded length. This is safe because it consumes at least six source bytes while emitting at most four; it never writes past the source-sized allocation. Unused stored bytes are outside the logical string and are overwritten or ignored. Raw UTF-8 input is copied only for its validated byte length—there is no speculative input overread.

## Number conversion

Grammar validation and digit accumulation share one pass. Leading plus signs/zeroes and missing fractional/exponent digits are rejected. For sufficiently long fractional runs, SWAR validates and accumulates eight digits at a time. The digit scanner has exhaustive single-byte validation checks and randomized conversion checks.

Pure integer values of at most 19 digits convert exactly accumulated u64 digits to correctly rounded f64. Values fitting i64 use the simpler signed conversion instruction. Short decimals use Clinger's fast path only when the significand and power of ten are exact f64 operands; division uses the exact power of ten rather than an approximate reciprocal.

Other at-most-19-digit numbers go directly to the Eisel–Lemire converter copied, without modification, from Zig 0.15.2's standard library. The parser supplies its already-scanned mantissa and exponent, avoiding the standard float parser's lexical rescan. That helper returns no result for ambiguous cases. Those cases and longer numbers use `std.fmt.parseFloat` as the exact fallback. Non-finite results are rejected; underflow can round to zero. The sign is applied so negative zero is preserved.

See `src/float/ORIGIN.md` and its MIT license. The float algorithm and cached table are reused Zig code, not an original Kiln contribution.

## Correctness and measurement

`errdefer` frees storage on every error. Injected allocator failures verify the cleanup paths. Unit tests cover string ownership, lookup, structure, diagnostics, signed zero, float conversion boundaries, reservation bounds, and Unicode boundaries/random scalar values.

The independent C API checks reconstruct the whole document and compare it with Python, configured to match the finite-f64 policy. This is stronger structural evidence than the benchmark checksum alone. SIMD/string boundary cases exercise transitions around vector loads. Required-valid/invalid JSONTestSuite cases are checked separately from implementation-defined cases.

The benchmark includes allocation and freeing for all libraries. Cross-library checksums visit every decoded string byte and normalize numbers to f64. Parse-plus-traversal also measures each representation's traversal code. Bootstrap intervals describe the current run's sample variation; they do not remove systematic effects or establish performance on other hardware.

Memory is allocator-requested bytes, including reserved capacity and the C wrapper. It excludes shared input, bookkeeping, fragmentation, and any hidden transient allocation inside libc realloc. It is not RSS. All three libraries use libc-backed allocations during timing, with instrumentation in a separate pass.

A speed result here compares data layout and parser design. cJSON/yyjson provide mutation, serialization, and other functionality that Kiln does not implement. Any wins must be stated for their measured workloads.
