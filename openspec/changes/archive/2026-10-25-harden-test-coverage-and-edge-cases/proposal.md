# Proposal

## Why

`PhoenixPresence` is exported from the package but has no tests at all (0% line coverage) and carries a source comment admitting it is an "untested port"; around it sit modules whose failure paths are barely exercised — `codec/message_decode_exception.dart` (22%), `events.dart` (45%), `exceptions.dart` (53%), `internal/resource_scope.dart` (55%), `message.dart` (68%) and `internal/pending_replies.dart` (78%). The suite currently covers 76.9% of instrumented library lines (1039/1351), and nothing in the repository measures coverage, so a regression in an error path is invisible to review and to CI. Presence is also the one public feature whose documented usage cannot be validated end-to-end against the example backend.

## What Changes

- Add unit tests for the lowest-coverage modules, covering the edge cases their public contracts imply: equality/hash/`toString` and factory validation in `events.dart`; `PhoenixException`/`ChannelTimeoutException`/`ChannelClosedError`/`PushSupersededException` in `exceptions.dart`; envelope validation, factories and equality in `message.dart`; `toString` variants of `MessageDecodeException`; release ordering, idempotency, post-close registration and error isolation in `ResourceScope`; supersede/complete/`completeAllWithError`/discard semantics in `PendingReplies`.
- Add `PhoenixPresence` unit tests covering state sync, diff sync, pending-diff buffering while out of sync, `onJoin`/`onLeave`/`onSync` callbacks, `eventNames` customization, `list()` with and without a chooser, `dispose()`, clone semantics, and malformed/empty payloads.
- Fix the presence diff decoder: `_decodeDiffFromPayload` keeps only the first entry of each `joins`/`leaves` group (`.keys.first`), so a `presence_diff` carrying more than one presence silently loses entries. Diffs must apply every presence in the frame.
- Extend the integration suite with presence scenarios against the example backend's `presence:lobby` channel: an initial `presence_state`, a second socket producing a join diff, and a leave diff after disconnect, asserting the client's `state` converges and membership is not lost.
- Add a documented coverage command: a `coverage` dev dependency plus `tool/coverage.sh` that runs the suite and prints a per-file line-coverage summary. No CI threshold gate is added; the script is for contributors and for verifying this change.
- Repair only unambiguous defects the new tests surface. Any suspected defect whose fix would change a public API signature or documented behavior is recorded as a follow-up, not fixed here.
- **No breaking changes**: no public signatures are removed or re-typed; the presence fix corrects output for inputs that are currently mishandled.

## Capabilities

### New Capabilities

- `presence`: how `PhoenixPresence` keeps client state in sync with the server — state/diff application (including multiple entries per frame), pending-diff buffering across join-ref changes, join/leave/sync callbacks, event-name customization, `list()` projection, clone isolation, and disposal.
- `test-suite`: the contributor-facing contract for the project's Dart test suite — what must be verifiable without external services, how integration-only behavior is gated behind the Toxiproxy/backend harness, and how per-file coverage is measured and reported.

### Modified Capabilities

<!-- openspec/specs is empty; there are no main specs to modify. The in-flight
     harden-core-lifecycle-and-codec change is not archived, so its capability
     deltas are not yet part of this project's spec inventory. -->

None.

## Impact

- Library: `lib/src/presence.dart` (multi-entry diff decoding only); no other `lib/` file is expected to change, but a verified defect in `message.dart`, `events.dart`, `exceptions.dart`, `internal/pending_replies.dart` or `internal/resource_scope.dart` may be fixed if the fix is local and behavior-preserving for valid inputs.
- Tests: new `test/presence_test.dart`, extended `test/serializer_test.dart` (or a new `test/message_edge_cases_test.dart`), `test/push_test.dart`/`test/socket_lifecycle_test.dart` for internal registries, and presence additions to the integration suite.
- Tooling and dependencies: `coverage` added to `dev_dependencies`; new `tool/coverage.sh`; `README.md` gains the coverage command alongside `dart test`.
- CI: unchanged — the existing `ci-test` job keeps running `dart analyze` and `dart test` with no threshold.
- Out of scope: adding a CI coverage gate, sweeping modules already above 90% (`socket.dart`, `channel.dart`, `push.dart`, `binary_codec.dart`, `message_serializer.dart`), restructuring presence into a channel-integrated API, and fixing defects that require public API changes.
