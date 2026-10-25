# Design

## Context

See `proposal.md` for motivation. Current state that shapes the approach:

- One published Dart package (`0.8.0`), public surface exported from `lib/phoenix_socket.dart`; `dart analyze lib test` is clean and the unit suite passes, so existing behavior is the compatibility baseline.
- Core is ~2.7k lines across `socket.dart` (654), `channel.dart` (430), `presence.dart` (321), `push.dart` (309), `message*` (~310), and `utils/binary_decoder.dart` (189).
- `socket.dart` owns connection state, heartbeat, reconnect timing, topic routing, pending messages, channels, and disposal in one class. `channel.dart` routes through two stream controllers. `push.dart` swaps completers on reset.
- Public `SocketState` is a closed enum; adding a value would break exhaustive consumer switches.
- Binary framing is used by a custom codec path and by the BTON magic-prefixed envelope; `BinaryDecoder` is not exported from the barrel but is imported internally.
- Integration tests are gated by availability checks for Toxiproxy (`localhost:8474`), the direct backend (`localhost:4001`), and the proxied backend (`localhost:4004`); `example/backend/compose.yaml` already defines the backend and proxy containers.
- No existing capability specs exist, so every spec in this change is additive.

## Goals / Non-Goals

**Goals:**

- Make every returned future complete exactly once, on every path, including disposal and decode failure.
- Give the socket one authoritative teardown path with owned, ordered, idempotent resource release.
- Make binary framing correct for offset views and validated before slicing, with typed failures.
- Enforce configuration and lifecycle invariants in release builds.
- Reduce per-message allocation and stream hopping without changing observable message content.
- Cut import cycles and isolate the wire codec behind a dedicated module.
- Make the integration suite reproducible with one documented command while keeping the skip fallback.
- Ship with deprecations only: no removed or re-typed public members.

**Non-Goals:**

- Rewriting presence state synchronisation; `presence.dart` is untouched by this change.
- Changing the Phoenix wire protocol, version negotiation, or adding new frame kinds.
- Reworking example applications, the demo backend, or the public README beyond the harness command and deprecated-API notes.
- Adding runtime dependencies or changing the minimum Dart SDK.
- Changing `SocketState` or any other public enum's value set.
- Optimising reconnect scheduling with an injectable clock in production code.

## Decisions

### 1. One owned teardown path, additive async disposal

Introduce an internal `Teardown`/resource-registry owned by `PhoenixSocket` that holds subscriptions, timers, controllers, the sink, and child channels in release order. `Future<void> disposeAsync()` runs it once, guarded by an idempotency flag, and awaits cancellations/close where the API returns futures. The existing `void dispose()` stays and delegates via `unawaited(disposeAsync())`, so current callers compile and behave as before.

- *Alternative:* change `dispose()` to `Future<void>` — source-compatible for statement callers but breaks tear-offs and violates the additive-only constraint.
- *Alternative:* keep ad-hoc cleanup and add missing branches — rejected: this is where the leaks and drop-without-completing bugs live.

### 2. Replace the error-swallowing zone with explicit completion

`connect()` becomes a plain async method that owns a `Completer` only where required, with `try/catch` around mount-point building, channel construction, readiness, and initial heartbeat. The `runZonedGuarded` wrapper is removed; every early exit either completes the future with a value, completes it with an error, or hands off to the reconnection path whose result is awaited and returned. A `_completerCompleted` guard prevents double completion.

- *Alternative:* keep the zone and complete the completer from its error callback — works, but keeps ordering ambiguous and hides stack traces behind a second completion path.

### 3. Internal connection phase, public enum untouched

The socket keeps the public `SocketState` for consumers and adds a private lifecycle phase (`idle`, `connecting`, `open`, `closing`, `disposed`) plus generation counters. Transitions go through one method that also enforces ordering: transport listeners are attached before readiness is awaited, `connecting` is published before the attempt, and close/error emission is derived from the transition rather than from ad-hoc checks. Reconnect state (`_reconnecting`, attempt index) is owned by a small `BackoffPolicy`-style internal object so a disposal or success can reset it atomically.

- *Alternative:* add `SocketState.disposed` — rejected (exhaustive-switch break).
- *Alternative:* keep boolean flags — rejected: the current boolean combination is what permits overlapping reconnects and stuck `_reconnecting`.

### 4. Ref-keyed pending replies with no completer replacement

`Push` and socket-level waits use one registry keyed by reference, with an owner tag and a generation. A push that is reset or resent completes its previous generation with a dedicated `PushSupersededException` (new, additive) instead of silently swapping the completer and stranding listeners. Socket `_pendingMessages` and channel `_waiters` are drained through the same helper on close/error/dispose, so no path can clear a map without completing it.

- *Alternative:* complete superseded futures with `ChannelClosedError` — reuses an existing type but loses the distinction between "channel closed" and "this attempt was superseded".
- *Alternative:* keep `onPushReply` event-keyed waiters — rejected: reply events are derived from refs and can collide; the public method stays deprecated but functional.

### 5. One routing hop and one channel controller

`PhoenixSocket` keeps an O(1) topic→channel map and delivers each decoded message directly to the channel's single broadcast controller, which both feeds `messages` and drives internal handling. The socket-level topic controller table is retained only to back the public `streamForTopic` compatibility API, and entries are released on last cancel and on channel removal. `messages` is a cached filtered view rather than a new `where` stream per access.

- *Alternative:* keep the socket topic stream as the transport for channels — preserves today's shape but keeps the double hop and the extra allocation per message.
- *Alternative:* remove `streamForTopic` — public API, cannot remove.

### 6. Codec module with a validating, view-aware reader

Add `lib/src/codec/` containing a binary frame reader/encoder and the decode exception type. Decoding reads through `ByteData`/`Utf8Decoder` ranges relative to `offsetInBytes`, validates kind and declared lengths before access, and exposes the payload as a `Uint8List.sublistView` instead of copying. Encoding checks field lengths against the one-byte width before writing. `MessageSerializer` becomes orchestration only (text vs binary vs magic envelope, payload post-processing) and keeps its public callbacks and `update`/`copyWith` behavior. The old `utils/binary_decoder.dart` becomes a thin deprecated facade so internal/third-party imports keep compiling.

- *Alternative:* patch `BinaryDecoder` in place — smaller diff but keeps offset and validation logic entangled with the serializer, and leaves no seam for unit testing framing independently.
- *Alternative:* copy payload bytes for safety — rejected for the hot path; a view is valid because each frame has its own buffer and the payload is consumed by the message, not retained by the socket.

### 7. Typed, isolated decode failures

`MessageSerializer.decode` throws `MessageDecodeException extends FormatException` (carrying stage, frame kind, and length). The socket consumes raw frames with an explicit `listen(onData, onError: ...)` and decodes inside a `try/catch` rather than through a `map`, so a malformed frame emits a non-fatal error event, is dropped, and the subscription survives. Successful decodes are pushed into a broadcast message controller.

- *Alternative:* let the stream error propagate — rejected: with no error handler it becomes an unhandled zone error and can cancel the transport subscription.
- *Alternative:* close the socket on decode failure — rejected: one bad frame should not tear down an otherwise healthy connection and can amplify reconnects.

### 8. Release-mode validation with the same error types

`assert`-only invariants become runtime checks: mutually exclusive `codec`/`serializer` and `params`/`dynamicParams` throw `ArgumentError` at construction; double `join`, `join`/`push` ordering, and disposal-time connect throw `StateError` subclasses. Valid configurations keep identical behavior; the only visible change is that invalid configurations now fail in release builds too.

- *Alternative:* keep asserts — rejected: the exact failure mode this change exists to remove.
- *Alternative:* throw only in debug via `assert(() { throw ...; }())` — rejected: leaves release builds permissive.

### 9. Hot-path allocation cuts

- Replace eager interpolation in trace logs with lazy `() => ...` messages.
- Reuse event constants for heartbeat/reply/status strings instead of constructing in conditionals.
- Cache the channel `messages` view and the message encode list allocation where ownership allows.
- Keep single-pass dispatch (decision 5) and view-based payloads (decision 6).
- Reset the reconnect index on open and on a fresh `connect()` rather than relying on the heartbeat observer.

Measured guard: no behavior change, no new timers; improvements validated by targeted micro-benchmark-style tests asserting allocation-sensitive paths (e.g. no `sublist` copy via identical buffer identity) and by existing suite parity.

### 10. Deprecation mapping (additive, with replacements)

| Deprecated | Replacement |
|---|---|
| `PhoenixSocket.waitForMessage(Message)` | `PhoenixSocket.waitForReply(String ref)` |
| `PhoenixChannel.onPushReply(PhoenixChannelEvent)` | `Push.future` / `Push.onReply` |
| `Push.clearReceivers()` | none needed — lifecycle is automatic |
| `Push.startTimeout()` | automatic on `Push.send()` |
| `Push.cleanUp()` | none needed — lifecycle is automatic |
| `BinaryDecoder` (facade) | new codec API (internal; facade kept for compatibility) |

Each deprecation carries a `@Deprecated` message with the replacement and is listed in `CHANGELOG.md`. No member is removed or re-typed.

### 11. Test strategy and harness

- Unit tests use the existing mockito channel mocks plus `fake_async` (dev-only) for timers, covering: connect completion after factory throw/dispose, ordered events, single reconnect, heartbeat timeout, pending completion on dispose, topic cleanup, binary offset/truncation/length overflow, decode isolation, release-mode validation (tests run in both modes where feasible), and push reset/duplicate/late reply.
- Harness: `tool/test-compose.yaml` (backend build context `../example/backend` + `ghcr.io/shopify/toxiproxy`) and `tool/integration_test.sh` that starts services, polls `localhost:4001` and `localhost:8474/proxies` for readiness with a deadline, runs `dart test`, tears down in a `trap`, and propagates the test exit code. The script fails fast with the service name and a hint when the runtime or a port is missing.
- Existing availability checks remain the fallback; their skip messages are updated to name the harness command. CI keeps using service containers, unchanged.

## Risks / Trade-offs

- **Release-mode validation now rejects previously tolerated misconfiguration** → Document in `CHANGELOG.md` and the `ArgumentError` message; treat as a bug fix, not a breaking API change.
- **Completing superseded push futures with an error can surface new errors** → Use a dedicated `PushSupersededException` and document handling; apps that ignored the old hanging future will now see an actionable error.
- **View-backed binary payloads alias the frame buffer** → Each frame buffer is message-local and not reused, so aliasing is safe; document that consumers must copy if they retain payloads beyond the callback.
- **Removing the zone can surface errors that were previously swallowed** → Every former zone path is converted to `try/catch` with a completion; a test asserts no unhandled async errors via `runZonedGuarded` in the test harness.
- **Two-channel routing change may alter delivery order** → Socket dispatch stays synchronous in receive order; tests assert order across channels.
- **`fake_async` and harness add dev-only surface** → Guarded by dev dependencies; `pubspec` runtime deps unchanged and CI analysis stays scoped to `lib/` and `test/`.
- **Harness is Docker-specific** → Script detects compose availability and exits with guidance; integration tests still skip cleanly for contributors without containers.

## Migration Plan

1. Land codec module and framing fixes first (no lifecycle dependency), keeping the deprecated facade.
2. Land lifecycle/teardown and completion changes, then channel routing and push registry.
3. Add deprecations and CHANGELOG migration notes in the same release; keep old members delegating.
4. Add harness and update skip messages/docs.
5. Validate with `dart analyze lib test`, `dart test`, and the harness command; roll back by reverting the release commit (no data or protocol migration involved).
