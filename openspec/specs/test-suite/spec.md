# test-suite Specification

## Purpose

Defines the contributor-facing guarantees of the project's test suite: which behavior must be verifiable without external services, how service-dependent scenarios stay isolated, and how per-file coverage is measured and reported.

## Requirements

### Requirement: The default test command requires no external services

Running the project's default test command SHALL pass using only the Dart SDK and dev dependencies, and every scenario that needs the example backend or Toxiproxy SHALL be skipped with a reason naming the harness that provides them.

#### Scenario: Offline run passes

- **WHEN** the default test command runs with no backend and no proxy available
- **THEN** the suite passes and reports the service-dependent scenarios as skipped
- **AND** each skip message names the harness script that starts the services

#### Scenario: Harness run executes skipped scenarios

- **WHEN** the harness has started the backend and proxy
- **THEN** the previously skipped scenarios execute instead of being skipped

### Requirement: Wire value-object contracts are covered offline

The offline suite SHALL verify the observable contracts of socket and channel events, socket exceptions, message envelopes, and typed decode errors, including equality, hashing, string forms, factory validation, and rejection of malformed envelopes.

#### Scenario: Event value objects behave consistently

- **WHEN** the tests compare two events with the same payload fields
- **THEN** they are equal and share a hash code
- **AND** differing payload fields make them unequal
- **AND** the string form includes the payload fields

#### Scenario: Unknown protocol event names are rejected

- **WHEN** a protocol event is constructed from an unrecognized name
- **THEN** the construction fails with an argument error

#### Scenario: Malformed message envelopes are rejected

- **WHEN** an envelope has the wrong element count or a non-string field where a string is required
- **THEN** decoding fails with a format error that names the offending field or count

#### Scenario: Decode errors report their stage

- **WHEN** a typed decode error is created with a stage and frame details
- **THEN** its string form includes the stage and the supplied frame details

#### Scenario: Socket exceptions expose their diagnostics

- **WHEN** a socket exception wraps a close event or an error event
- **THEN** its string form and associated message reflect the wrapped condition
- **AND** an unset exception reports the socket-closed condition

### Requirement: Owned-resource and reply bookkeeping are covered offline

The offline suite SHALL verify teardown ordering, idempotency, post-close registration, and error isolation for owned resources, and supersede, completion, and fail-all semantics for pending replies.

#### Scenario: Releases run in registration order

- **WHEN** a scope with several registered releases is closed
- **THEN** the releases run in the order they were registered
- **AND** closing again runs nothing

#### Scenario: Registration after close releases immediately

- **WHEN** a release is registered on an already closed scope
- **THEN** that release runs without requiring another close

#### Scenario: A failing release does not block the others

- **WHEN** one registered release throws
- **THEN** the remaining releases still run
- **AND** the failure is reported to the scope's error handler

#### Scenario: Superseded waits fail instead of hanging

- **WHEN** a new wait is registered for a reference that already has an unfinished waiter
- **THEN** the earlier waiter fails with a state error
- **AND** the new waiter remains pending

#### Scenario: Fail-all completes every pending waiter

- **WHEN** all pending replies are failed
- **THEN** every waiting future completes with that error
- **AND** no references remain pending

#### Scenario: Completing an unknown reference is a no-op

- **WHEN** a completion or failure is reported for a reference that is not pending
- **THEN** the operation reports that nothing was completed
- **AND** no error is thrown

### Requirement: Presence is verified end-to-end in the integration suite

The integration suite SHALL exercise presence against the example backend's presence channel, covering the initial snapshot, a join diff caused by a second client, and a leave diff caused by a client disconnecting.

#### Scenario: Initial snapshot is received

- **WHEN** a client joins the presence channel
- **THEN** its presence state eventually contains the joining user

#### Scenario: Second client produces a join

- **WHEN** a second client joins the same presence channel
- **THEN** the first client's presence state includes the second user without losing the first

#### Scenario: Disconnect produces a leave

- **WHEN** a joined client disconnects
- **THEN** the remaining client's presence state drops that user

### Requirement: Coverage is measured with a documented command

The repository SHALL provide a documented command that runs the offline suite with coverage and reports line coverage per library file, and that command SHALL NOT be wired into CI as a pass/fail threshold.

#### Scenario: Coverage report lists library files

- **WHEN** the coverage command completes successfully
- **THEN** it reports a line-coverage percentage for each instrumented file under the library source tree

#### Scenario: Test failure propagates

- **WHEN** a test fails during the coverage run
- **THEN** the command exits unsuccessfully instead of reporting partial results as success

#### Scenario: CI does not gate on coverage

- **WHEN** the continuous integration workflow runs
- **THEN** it runs analysis and tests without applying a coverage threshold
