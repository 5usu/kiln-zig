# Validation record

Validated locally on the Intel i3-1305U laptop, 14 November 2026 (India time), with Zig 0.15.2.

- Ten Zig unit-test groups pass in Debug, ReleaseFast, and ReleaseSafe. They cover input ownership, lookup/traversal, malformed inputs, diagnostics, allocation failures, numeric rounding/signed zero, randomized exact float comparisons, eight-digit scanning, Unicode boundary/random scalar encoding, and reservation bounds.
- Both C API builds accept all 95 required-valid JSONTestSuite inputs and reject all 188 required-invalid inputs. The remaining 35 inputs are implementation-defined: five accepted, 30 rejected.
- Each C API build passes 100,000 generated semantic comparisons and 100,000 ASCII-mutation validity/semantic comparisons against Python's JSON decoder configured to reject non-JSON constants and non-finite floats. This matches the documented finite-f64 policy; Python's default decoder accepts float overflow as infinity.
- Each build processes 100,000 additional arbitrary byte inputs without a crash. These are robustness tests, not semantic differential tests.
- Each build passes 1,028 SIMD/string-boundary comparisons and reconstructs/compares the complete documents of all seven benchmark workloads.
- The final benchmark records 616 samples: seven workloads × four implementations (current Kiln, original Kiln, cJSON, yyjson) × two modes × 11 rounds. Every cross-library checksum matches within its dataset. AC power was present at both the start and end.
- Current parser/helper sources, C API/header, build definition, harness, build script, and original baseline sources match the SHA-256 fingerprints recorded with the measurements. The original library was recompiled with the same toolchain for this run.
- A clean extraction of the updated source archive builds successfully. Its CLI runs, and its C API passes the required corpus, 1,000 cases in each randomized category, vector-boundary checks, and four locally generated workload comparisons.
- The three float-converter source files are unmodified copies of the Zig 0.15.2 standard library, with their MIT license and provenance preserved.

The JSON reports hold exact randomized counts and the reference policy. Tests are bounded deterministic checks, not a proof of correctness on all inputs or a production audit. ReleaseSafe provides Zig runtime checks; no AddressSanitizer or Valgrind run is claimed. Bootstrap intervals describe this benchmark run's sample variation, not all hardware or systematic bias.

The workflow configuration is in `.github/workflows/ci.yml`; live CI status is available from the repository Actions tab. The performance figures in this record are local laptop measurements, not GitHub runner benchmarks.
