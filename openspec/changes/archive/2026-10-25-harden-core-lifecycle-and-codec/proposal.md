# Proposal

## Why

The 0.8.0 core has several lifecycle and framing defects that can leave consumer futures pending forever, leak stream controllers, or silently corrupt binary messages, while its hot paths allocate avoidable work. The library is published and used by Flutter apps, so these defects surface as unexplained hangs and reconnects rather than as clear errors, and they cannot be fixed by consumers.

## What Changes

- Make socket shutdown and connection failure deterministic: every pending completer is completed (value or error), `connect()` never returns a future that can hang, and disposal closes/awaits owned resources exactly once.
- Fix resource leaks and ordering races in topic routing, heartbeat scheduling, reconnect backoff, and `PhoenixRawSocket`'s raw stream.
- Repair binary framing: honor `Uint8List.offsetInBytes`, validate lengths/bounds, reject frames that cannot be parsed instead of truncating or throwing `RangeError`, and report unsupported payloads as typed errors.
- Replace `assert`-guarded invariants with runtime validation so release builds reject invalid socket/channel configuration and illegal lifecycle calls.
- Reduce hot-path cost: avoid eager log interpolation, redundant stream hops, per-message allocations, and buffer copies in the dispatch and codec paths.
- Split the wire codec out of `MessageSerializer` into an explicit binary codec module and reduce `message`/`channel`/`socket` import cycles without changing the public entry point.
- Introduce additive replacement APIs (`disposeAsync`, `waitForReply`, raw-socket stream access, typed decode errors) and `@Deprecated` annotations plus CHANGELOG migration notes for the APIs they supersede. Existing public signatures keep working.
- Add deterministic unit tests for every fixed behavior, and a documented local harness that starts Toxiproxy plus the example Phoenix backend so the existing integration suite runs with one command instead of skipping.
- **No breaking changes**: public APIs are deprecated, not removed or re-typed.

## Capabilities

### New Capabilities
- `connection-lifecycle`: socket state transitions, connect/dispose semantics, reconnection and backoff, heartbeat health, event stream ordering, and guaranteed completion/cleanup of owned resources.
- `channel-messaging`: channel join/leave/push behavior, reply correlation and timeout, push buffering and rejoin, and how channel/push failures reach caller futures.
- `wire-codec`: message encoding/decoding for JSON and binary frames, framing validation and error typing, serializer selection, and custom codec extension points.
- `local-test-harness`: the contributor-facing command that provisions the Toxiproxy proxy and Phoenix backend required by the integration suite, and its degraded behavior when those services are absent.

### Modified Capabilities
<!-- No existing specs: openspec/specs is empty. -->

## Impact

- Library: `lib/src/socket.dart`, `channel.dart`, `push.dart`, `message.dart`, `message_serializer.dart`, `serializer_registry.dart`, `socket_options.dart`, `exceptions.dart`, `events.dart`, `raw_socket.dart`, `utils/binary_decoder.dart`, plus new codec/error modules.
- Public API: additive members only; `@Deprecated` annotations on superseded members; `CHANGELOG.md` migration notes. No removals or signature changes.
- Behavior: error/failure paths complete instead of hanging; malformed binary frames now surface typed errors; validation that previously relied on `assert` now runs in release builds.
- Tests and tooling: new unit tests under `test/`, harness script/compose file, README/CUSTOM_CODEC_GUIDE updates where they contradict the code.
- Dependencies: no new runtime dependencies expected; harness may add a dev-only compose file.
