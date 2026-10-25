# Tasks

## 1. Wire codec module

- [x] 1.1 Add `lib/src/codec/message_decode_exception.dart` with a `MessageDecodeException extends FormatException` carrying stage, frame kind, and frame length; verify unit tests assert the subtype, message, and fields for text and binary failures.
- [x] 1.2 Add a frame reader/encoder in `lib/src/codec/` that reads relative to `offsetInBytes`/`length` and decodes push, reply, and broadcast frames; verify tests show a frame at a non-zero buffer offset decodes identically to the same frame in a standalone buffer.
- [x] 1.3 Validate kind and every declared length before reading, and reject truncated or inconsistent frames with `MessageDecodeException`; verify tests cover truncated topic, short meta header, and unknown kind with no `RangeError`.
- [x] 1.4 Validate encode field lengths against the one-byte width before writing and throw `ArgumentError` for oversized fields; verify tests assert no frame is returned and a full encode/decode round trip matches for all three frame kinds.
- [x] 1.5 Rewire `MessageSerializer` to delegate text and binary parsing to the codec module while keeping public callbacks, `update`, `copyWith`, BTON envelope handling, and payload post-processing (string-key maps, passthrough bytes, wrapped values, missing-decoder error); verify existing serializer/codec-switching tests pass and new payload-normalisation tests pass.
- [x] 1.6 Replace `lib/src/utils/binary_decoder.dart` with a deprecated facade over the new codec and remove duplicated envelope construction from `Message.fromJson`/`MessageSerializer.decode`; verify `dart analyze lib test` is clean of deprecation warnings inside `lib/` and decode-parity tests pass for text and binary inputs.

## 2. Socket lifecycle and completion

- [x] 2.1 Add an internal teardown registry plus `Future<void> disposeAsync()` that releases sink, timers, subscriptions, topic controllers, and channels in order and is idempotent; verify tests assert the sink is closed, timers are cancelled, repeated calls are no-ops, and synchronous `dispose()` still delegates.
- [x] 2.2 Replace the `runZonedGuarded` connection wrapper with explicit completion covering mount-point building, channel construction, readiness, and initial heartbeat; verify tests cover a synchronous factory throw, disposal mid-attempt returning `null`, and `connect()` after disposal returning a `StateError`.
- [x] 2.3 Route every failure path (socket error, close, channel error, disposal) through one pending-reply registry that completes all entries with an error instead of clearing them; verify tests fail if any future is still pending after the failure, using a bounded timeout.
- [x] 2.4 Extract reconnect/backoff and heartbeat into internal collaborators with an internal lifecycle phase, ensuring one attempt at a time, delay capping with jitter, index reset after open, and no reconnect after disposal; verify `fake_async` tests cover overlapping failures, sequence advancement, reset, and disposal during a delay.
- [x] 2.5 Implement heartbeat acknowledgement and timeout handling through the pending-reply registry, cancelling and never duplicating timers across reconnects; verify tests cover ack, unanswered timeout closing the transport, and repeated close/reopen cycles yielding a single active timer.
- [x] 2.6 Emit open/error/close events in protocol order from lifecycle transitions and suppress all events after disposal; verify tests assert error-before-close for one failure, one open per established connection, and zero events after disposal.
- [x] 2.7 Route decoded messages directly to channels with one internal topic table that backs `streamForTopic`, releasing both entries on last cancel and channel removal; verify tests cover last-subscriber cleanup, channel removal, independent topics, and preserved delivery order.
- [x] 2.8 Add `PhoenixRawSocket.rawMessages` delivering undecoded text and byte frames, closing on disposal, and reporting unsupported frame types through the error surface; verify tests cover text, bytes, close, and unsupported type.
- [x] 2.9 Replace `assert`-only invariants in socket construction and connection (`codec`+`serializer`, `params`+`dynamicParams`, connect after dispose) with `ArgumentError`/`StateError`, in release too; verify constructor tests throw and `grep -n "assert(" lib/src/socket*.dart` shows no lifecycle guards remaining.

## 3. Channel and push messaging

- [x] 3.1 Replace event-keyed reply waiters with the ref-keyed registry and keep one completer per push generation, completing a superseded generation with a new additive `PushSupersededException`; verify tests cover reset/resent pushes, duplicate replies, and late replies after timeout.
- [x] 3.2 Deliver channel messages through a single cached broadcast stream while keeping `messages` filtering semantics; verify tests assert application messages, channel replies, filtered foreign replies, and unchanged ordering.
- [x] 3.3 Implement join gating on socket open, single rejoin timer, and explicit `StateError` for double join in release; verify tests cover join before open, backend error, timeout scheduling one rejoin, and double join throwing.
- [x] 3.4 Complete all channel waiters, cancel buffered pushes, and clear timers on `phx_error`, `phx_close`, socket close, and disposal; verify tests assert no waiter or buffered push future remains pending after each path.
- [x] 3.5 Make leave idempotent with local completion when unjoined or disconnected, removal from the socket, and waiter completion; verify tests cover joined leave with `ok`, disconnected leave, repeated leave, and push-after-leave throwing `ChannelClosedError`.
- [x] 3.6 Add `@Deprecated` annotations with replacement messages for `PhoenixSocket.waitForMessage`, `PhoenixChannel.onPushReply`, `Push.clearReceivers`, `Push.startTimeout`, and `Push.cleanUp`, plus the new `waitForReply(String ref)` member; verify tests exercise the replacements, deprecated APIs still behave, and `dart analyze lib test` shows no internal deprecation use.
- [x] 3.7 Add a `CHANGELOG.md` section listing fixes, new members, deprecations with migration guidance, and the release-mode validation note; verify the changelog matches the implemented public surface by cross-checking `lib/phoenix_socket.dart` exports.

## 4. Performance

- [x] 4.1 Convert hot-path log calls (`message`, `push`, `socket`, `channel` encode/decode/send paths) to lazy message callbacks; verify `grep -nE "_logger\.[a-z]+\('[^']*\\\$" lib/src` returns no eager interpolation on those paths and the suite still passes.
- [x] 4.2 Remove per-access stream allocation and redundant per-message object construction (cached `messages` view, reused status/event constants, no duplicate envelope parsing); verify tests assert identical stream instances where cached and unchanged message content/order.
- [x] 4.3 Add `tool/benchmark_codec.dart` exercising text encode/decode and binary decode on fixed fixtures; verify it runs via `dart run tool/benchmark_codec.dart` and record before/after numbers in the change notes.

## 5. Modularity and docs

- [x] 5.1 Remove doc-comment-only imports that create `message`/`events`/`exceptions` → `socket`/`channel` cycles; verify `dart analyze lib test` is clean and a grep shows those files import only what they use.
- [x] 5.2 Extract socket internals (backoff, heartbeat, teardown, pending replies) into `lib/src/internal/` and keep `PhoenixSocket` as orchestration; verify `dart analyze lib test` and all unit tests pass with no public API change (`git diff --stat lib/phoenix_socket.dart` unchanged exports).
- [x] 5.3 Document the new codec module, additive members, and deprecated replacements in `CUSTOM_CODEC_GUIDE.md` (including fixing the `EncoderCallback` signature mismatch) and the README harness section; verify each documented snippet compiles against the documented API and the harness command in the README matches the script name.

## 6. Local integration harness

- [x] 6.1 Add `tool/test-compose.yaml` with the example backend build context and the Toxiproxy image exposing ports 4001, 4002, 4004, and 8474; verify `docker compose -f tool/test-compose.yaml config` succeeds.
- [x] 6.2 Add `tool/integration_test.sh` that starts services, polls `localhost:4001` and `localhost:8474/proxies` with a deadline, runs the suite, tears down via `trap`, and propagates the test exit code; verify a passing run exits 0, a forced failing test exits non-zero, and services are gone afterwards.
- [x] 6.3 Add fail-fast diagnostics for a missing compose runtime, a bound port, and a backend that exits before readiness; verify each case exits non-zero and names the service plus a remediation hint.
- [x] 6.4 Update integration availability skip messages to name the harness command and keep partial availability precise; verify running `dart test` without services reports actionable skips while unit tests run.
- [x] 6.5 Add `.pubignore` entries for harness artifacts and confirm no runtime dependency was added; verify `dart pub publish --dry-run` lists no harness files and `pubspec.yaml` runtime dependencies are unchanged.

## 7. Integration verification

- [x] 7.1 Run `dart analyze lib test` and `dart test`; verify clean analysis and all unit tests passing with integration tests either passing under the harness or skipping with the documented reason.
- [x] 7.2 Run `tool/integration_test.sh` with services available; verify the full suite (unit and integration) passes and the command tears everything down.
- [x] 7.3 Verify the public API diff is additive only by comparing `lib/phoenix_socket.dart` exports and `dart analyze` deprecation hints with the changelog; confirm no removed or re-typed member.

## Workflow follow-up

- Archive the change after review and after the harness runs green.
- Verify the archived specs and the updated capability list with `openspec validate`.
