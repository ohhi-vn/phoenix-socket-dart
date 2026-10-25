# Design

## Context

See `proposal.md` — Why. Constraints that shape the approach:

- `PhoenixPresence` is a thin listener over `PhoenixChannel.messages`; it owns no transport and no join lifecycle. It is constructed before a channel joins and processes `presence_state` / `presence_diff` frames.
- The presence decoder currently funnels a wire diff through `_decodeDiffFromPayload`, which maps each group (`joins`, `leaves`) to a single-entry map via `.keys.first`. `_syncDiff` then consumes that internal `{joins: {...}, leaves: {...}}` shape, and `_syncState` builds the same shape itself from decoded state. The internal shape is therefore load-bearing and should stay.
- Existing socket/channel tests already drive real `PhoenixSocket`/`PhoenixChannel` instances over a fake `WebSocketChannel` (`test/channel_messaging_test.dart`), reading frames from a broadcast controller. There is no mock of `PhoenixChannel.messages`, and `PhoenixChannel` is not designed for stubbing its stream getter.
- The offline suite is the default `dart test` invocation; integration files self-skip when `localhost:4001` / Toxiproxy are absent. No coverage package or script exists today; nothing measures coverage in CI.
- `ResourceScope` and `PendingReplies` are library-internal but importable as `package:phoenix_socket/src/internal/...`; their failure branches (teardown errors, superseded waits) are hard to reach indirectly.

## Goals / Non-Goals

**Goals:**

- Every requirement in `specs/presence/spec.md` and `specs/test-suite/spec.md` is exercised by a test that fails if the behavior regresses.
- Overall instrumented line coverage rises from 76.9% (1039/1351) to at least 90%, with each targeted module at 85% or better: `presence.dart`, `events.dart`, `exceptions.dart`, `codec/message_decode_exception.dart`, `internal/resource_scope.dart`, `message.dart`, `internal/pending_replies.dart`.
- Presence is validated against the real example backend, not only against crafted payloads.
- Coverage becomes reproducible with one command and a documented number.

**Non-Goals:**

- A CI coverage gate, or any change to `.github/workflows/test.yaml`.
- Raising coverage of modules already above 90% (`socket.dart`, `channel.dart`, `push.dart`, `binary_codec.dart`, `message_serializer.dart`), beyond incidental gains.
- Turning presence into a channel-integrated API (for example a `channel.presence` getter) or changing presence's public types.
- Fixing defects that require public signature or type changes (for example making `PhoenixPresenceMeta.phxRef` nullable for payloads lacking `phx_ref`).
- Restructuring the existing `test/channel_messaging_test.dart` harness; only new tests use the extracted helper.

## Decisions

### Drive presence through a real channel over a fake transport

Presence tests construct a real `PhoenixSocket` with `webSocketChannelFactory` returning a mocked `WebSocketChannel`/`WebSocketSink`, join a `presence:lobby` channel, and push frames into the fake inbound controller — the pattern already proven in `test/channel_messaging_test.dart`. A minimal harness is extracted to `test/helpers/socket_harness.dart` for reuse, without touching the existing test file.

- **Why**: presence consumes the channel's filtered message stream (`_isVisibleMessage`) and `channel.joinRef`; mocking `PhoenixChannel` would require stubbing both and would not prove the real wiring.
- **Alternatives considered**: (a) Mock `PhoenixChannel` and stub `messages` — fast but bypasses join-ref and visibility filtering, the exact logic that decides pending-diff buffering; (b) call `channel.trigger()` directly — viable but still needs a channel instance and reads less like production; (c) make presence internals visible for tests — rejects the public surface being testable as shipped.

### Fix presence diffs at the decoding boundary

`_decodeDiffFromPayload` will map each group to a map containing **every** presence in that group, and keep ignoring empty groups. `_syncDiff`, `_syncState`, and the internal `{joins, leaves}` shape are unchanged.

- **Why**: the single-entry collapse is the defect; the sync logic already handles multi-entry maps (it iterates entries and merges metadata by `phx_ref`). Fixing the decoder leaves the callback/merge semantics and their existing expectations intact.
- **Alternatives considered**: (a) Rewrite `_syncDiff` to accept the wire payload — duplicates group handling already done in `_syncState`, which composes an internal diff for the same function; (b) Normalize in `_onMessage` — spreads wire-shape knowledge across two methods.

### Measure coverage with a shell script over lcov

Add `coverage` to `dev_dependencies`, then `tool/coverage.sh` runs `dart test --coverage=coverage` followed by `dart run coverage:format_coverage --lcov --report-on=lib --in=coverage --out=coverage/lcov.info`, and prints a per-file `LH/LF` table plus a total by reading the lcov blocks.

- **Why**: `dart test --coverage` needs a formatter, the `coverage` package is the canonical one, and lcov text is trivial to summarize without adding another dependency. The script exits non-zero when tests fail because the `dart test` step is not swallowed.
- **Alternatives considered**: (a) A Dart summarizer — more code to maintain for a contributor script; (b) `very_good_coverage` or similar — an extra CI-shaped tool for a request that explicitly excludes a CI gate; (c) committing generated coverage — noisy and platform-dependent.

### Presence integration tests live in their own service-gated file

`test/presence_integration_test.dart` checks backend availability directly (`ws://localhost:4001/socket/websocket`), mirrors the existing skip message pointing at `tool/integration_test.sh`, and uses two sockets with distinct `user_id` params against `presence:lobby`. It joins the second client after the first has received its snapshot, then disconnects the second to force a leave.

- **Why**: presence needs only the backend, not Toxiproxy; keeping it out of `channel_integration_test.dart` avoids proxy mutation state leaking into join assertions and keeps the skip reason accurate.
- **Alternatives considered**: (a) Append to `channel_integration_test.dart` — couples presence to proxy lifecycle for no benefit; (b) drive a third client to force a multi-entry diff — timing-dependent and flaky, so multi-entry behavior stays a unit test.

### Test internal bookkeeping helpers directly

`ResourceScope` and `PendingReplies` are tested with direct imports from `package:phoenix_socket/src/internal/`, using `fake_async` only where timer behavior matters.

- **Why**: their contracts are explicitly about teardown error isolation and superseded completers; reaching those branches through `PhoenixSocket` requires staging multiple failures and makes the assertion about the socket rather than the helper.
- **Alternatives considered**: exercising them only through socket lifecycle tests — leaves the post-close registration and error-isolation branches untested, which is the gap this change exists to close.

### Bug-fix policy

Only defects confirmed by a failing test and fixable without changing a public signature or documented behavior are fixed here; the presence diff collapse qualifies. Anomalies such as `PhoenixException.message` returning the same message for close and error events are characterized by tests and recorded as follow-ups.

## Risks / Trade-offs

- **Presence integration depends on the backend broadcasting `presence_diff`.** → Verify against the harness during apply; if the image does not broadcast diffs, assert the snapshot scenario and record the gap against the backend rather than mocking the wire format in the integration suite.
- **Diffs are timing-dependent** (second join must arrive after the first snapshot). → Sequence explicitly: await the first client's state, then join the second, polling with a bounded timeout instead of fixed sleeps.
- **Coverage percentages shift with the Dart SDK's instrumented line set.** → Record the SDK version alongside the measured number and set the target as a percentage, not an exact line count.
- **Fixing presence may expose further latent defects** (for example payloads without `phx_ref`). → Characterize them in tests; defer any fix that changes public types, as stated in the proposal.
- **Extracting a shared test harness can drift from the private one in `channel_messaging_test.dart`.** → Keep the helper minimal (connect, deliver frame, reply to join) and leave the existing private harness alone in this change; unify later if a third consumer appears.
- **Adding `coverage` changes `pubspec.lock`.** → Dev-only dependency; run `dart pub get` and confirm the lockfile diff is limited to coverage and its transitive deps.

## Migration Plan

- Patch-level library change: the only behavior change is that a `presence_diff` with several presences per group now applies all of them. Add a `CHANGELOG.md` entry noting the fix.
- Rollback is reverting the change; no data or protocol migration is involved.
- Verify with `dart analyze`, `dart test`, `tool/coverage.sh`, and `tool/integration_test.sh` before release.

## Open Questions

- None that affect the specs or the task breakdown. Whether presence should eventually be exposed as a channel-level API remains a separate proposal.

## Recorded Follow-ups

Defects found while writing these tests but deliberately left unfixed because the fix would change public types or documented behavior:

- `PhoenixException.message` returns the same `error` message for both close and error events. `test/exceptions_test.dart` pins the current behavior so a future fix is a deliberate change.
- `PhoenixPresenceMeta.phxRef` is non-nullable while the wire field is optional, so a metadata entry without `phx_ref` still fails to decode. Making it nullable would change an exported type, so it is out of scope here.
