# Float conversion attribution

These three Zig source files are copied without modification from the Zig 0.15.2 standard library, `lib/std/fmt/parse_float/`. Their MIT license is preserved here. They implement the Eisel–Lemire conversion described in Daniel Lemire, “Number Parsing at a Gigabyte per Second”: https://arxiv.org/abs/2101.11408.

Kiln supplies an already-validated significand and decimal exponent directly to `convertEiselLemire`, avoiding a second scan by `std.fmt.parseFloat`. Difficult/ambiguous cases and numbers with more than 19 digits still go through `std.fmt.parseFloat` for exact fallback conversion. This code is reused from Zig, not an original Kiln floating-point algorithm.

Pinned upstream source: https://github.com/ziglang/zig/tree/0.15.2/lib/std/fmt/parse_float
