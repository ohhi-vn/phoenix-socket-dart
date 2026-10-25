# Tasks

## 1. Coverage tooling and baseline

- [x] 1.1 Add `coverage` to `dev_dependencies` in `pubspec.yaml` and run `dart pub get`; verify `git diff pubspec.lock` shows only coverage and its transitive packages added.
- [x] 1.2 Create executable `tool/coverage.sh` that runs the offline suite with coverage, formats it to lcov restricted to `lib/`, and prints a per-file `LH/LF` percentage table plus a total; verify it runs end-to-end and reports the pre-change baseline (`lib/src/presence.dart` at 0.0%, total around 76.9%).
- [x] 1.3 Make the script propagate failures: verify it exits non-zero when a test fails by adding a temporary failing test file, running the script, then deleting the file (`set -euo pipefail` must not swallow the `dart test` status).
- [x] 1.4 Document the coverage command in `README.md` next to the existing `dart test` instructions; verify the documented command works exactly as written.

## 2. Presence diff fix and unit tests

- [x] 2.1 Create `test/helpers/socket_harness.dart` with a minimal fake-transport harness (connect a real `PhoenixSocket`, add and join a channel, deliver an inbound frame, reply to a join) modeled on the private harness in `test/channel_messaging_test.dart`; verify `dart analyze test/` passes and a throwaway smoke test using it joins a channel.
- [x] 2.2 Add state-snapshot tests to `test/presence_test.dart`: first snapshot populates state and fires `onSync` once, a snapshot removes absent members and fires `onLeave`, and an empty snapshot clears state; verify the tests pass.
- [x] 2.3 Add diff tests to `test/presence_test.dart` for multiple joins in one frame, multiple leaves in one frame, metadata merge on join, partial metadata leave, and removal when the last metadata leaves; verify the multi-entry cases fail for the expected reason against the current decoder (only the first presence per group is kept).
- [x] 2.4 Fix `_decodeDiffFromPayload` in `lib/src/presence.dart` to decode every presence in each `joins`/`leaves` group while leaving empty groups empty; verify the tests from 2.3 now pass and `dart test` stays green.
- [x] 2.5 Add tests for buffered diffs before the first snapshot and after a join-ref change, `inPendingSyncState` before and after a snapshot, `onJoin`/`onLeave`/`onSync` arguments and counts, custom and partial `eventNames` overrides, unrelated messages being ignored, `list()` with and without a chooser, clone isolation, captured-state stability, and messages after `dispose()`; verify all pass.
- [x] 2.6 Drop the obsolete "non-tested port" comment in `lib/src/presence.dart`; verify `grep -n "non-tested" lib/src/presence.dart` returns nothing and the file still analyzes cleanly.
- [x] 2.7 Add a `CHANGELOG.md` entry describing the presence diff fix (multiple presences per diff are now applied); verify the entry appears above the current release and describes only behavior a consumer can observe.

## 3. Wire value-object edge cases

- [x] 3.1 Create `test/events_test.dart` covering close/error event equality, hashing, and string forms, differing payload fields, `PhoenixChannelEvent.replyFor`/`custom` factories, unknown protocol names throwing `ArgumentError`, `isReply`/`isChannelReply`, `statuses`, and `heartbeat`; verify the tests pass and none reach into private members.
- [x] 3.2 Create `test/exceptions_test.dart` covering `PhoenixException.toString` with an error event and without one, its `message` getter for closed/error/unset cases, `ChannelTimeoutException` carrying its response, `ChannelClosedError` being a `StateError`, and `PushSupersededException` string forms with and without a ref; verify the tests pass.
- [x] 3.3 Create `test/message_edge_cases_test.dart` covering envelope rejection (wrong length, non-string `joinRef`/`ref`/`topic`, non-string event) with the offending field or count in the message, `Message.heartbeat`/`timeoutFor`/`binary` factories, `encode()` round-tripping through `fromJson`, equality and hashing, `isReply`, and `asReplyEvent`; verify the tests pass.
- [x] 3.4 Create `test/message_decode_exception_test.dart` covering stage/kind/frame-length fields, the string form with and without optional frame details, and continued catchability as `FormatException`; verify the tests pass.

## 4. Internal bookkeeping edge cases

- [x] 4.1 Create `test/resource_scope_test.dart` covering release ordering, idempotent `close()`, immediate release of registrations made after close (sync and async), one failing release not blocking later ones, async release failures reaching `onError`, and `isClosed`; verify the tests pass without unhandled zone errors.
- [x] 4.2 Create `test/pending_replies_test.dart` covering `length`/`refs`/`contains`/`futureFor`/`ownerOf`, re-registering a ref failing the earlier waiter with a `StateError`, `complete`/`completeError` removing entries, `completeAllWithError` failing every waiter and clearing owners, `discard` not completing the waiter, and completing an unknown ref returning false without throwing; verify the tests pass.

## 5. Presence integration coverage

- [x] 5.1 Create `test/presence_integration_test.dart` with the same availability check style as the existing integration files (skip reason naming `tool/integration_test.sh`), join `presence:lobby` with a distinct `user_id`, and assert the initial snapshot includes the joining user; verify it runs via `tool/integration_test.sh test/presence_integration_test.dart` and skips with the expected reason when services are down.
- [x] 5.2 Add the multi-client scenarios: a second socket joining adds that user without dropping the first, and disconnecting the second removes it; verify both against the harness using bounded polling instead of fixed sleeps.
- [x] 5.3 Confirm the offline suite still needs no services: run `dart test` with no harness and verify the presence integration scenarios are reported as skipped with the actionable reason while everything else passes.

## 6. Integration checks

- [x] 6.1 Run `dart analyze --fatal-infos lib/` and `dart analyze test/`; verify both are clean.
- [x] 6.2 Run `tool/coverage.sh`; verify overall line coverage is at least 90% and every targeted module (`presence.dart`, `events.dart`, `exceptions.dart`, `codec/message_decode_exception.dart`, `internal/resource_scope.dart`, `message.dart`, `internal/pending_replies.dart`) is at 85% or better, recording the Dart SDK version used.
- [x] 6.3 Run `tool/integration_test.sh`; verify the whole suite passes with the backend and Toxiproxy running.
- [x] 6.4 Review `git diff lib/` and verify no public signature or exported type changed, that `lib/src/presence.dart` is the only intended production change, and that any additional defect was recorded as a follow-up rather than fixed silently.

## Workflow follow-up

- Archive the change after review so `presence` and `test-suite` become main specs under `openspec/specs/`.
- Verify the archived specs contain the presence diff requirement and the coverage-command requirement.
