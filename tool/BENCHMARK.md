# Codec benchmark

Run with:

```bash
dart run tool/benchmark_codec.dart
```

Fixture: one `new_msg` message with a nested map payload (text) and a 64-byte
payload (binary). 5,000 warmup iterations, 100,000 measured iterations, Dart
3.13.5 on macOS arm64.

## Results (2026-10-25)

| Path | Before | After | Change |
| --- | ---: | ---: | ---: |
| text encode | 443,760 ops/s | 913,584 ops/s | +106% |
| text decode | 1,643,764 ops/s | 1,522,371 ops/s | -7% |
| binary encode | 4,678,144 ops/s | 6,064,281 ops/s | +30% |
| binary decode | 2,848,435 ops/s | 7,668,124 ops/s | +169% |

"Before" was measured from `HEAD` before this change using the same fixtures and
the old `BinaryDecoder`. The text decode difference is the cost of validating the
five-element envelope and rejecting malformed frames with a typed error; binary
gains come from view-based payloads (no `sublist` copies) and avoiding the extra
`ByteData`/header copies.
