# Spec Delta

## Purpose

Defines how a client socket establishes, maintains, observes, and tears down a Phoenix WebSocket connection, including reconnection, heartbeat health, routing resource cleanup, and raw-frame access.

## ADDED Requirements

### Requirement: Connection attempts always resolve

Every `connect` call SHALL complete its returned future with either a connected socket, the outcome of a scheduled reconnection attempt, or an error, and SHALL NOT remain pending after the attempt ends or the socket is disposed. Errors raised synchronously while building the mount point or creating the underlying channel MUST be delivered through that future rather than escaping an error zone.

#### Scenario: Channel construction fails

- **WHEN** the configured channel factory throws while the connection attempt starts
- **THEN** the future returned by `connect` completes with an error or with the result of the scheduled reconnection
- **AND** no unhandled asynchronous error is emitted

#### Scenario: Disposed while connecting

- **WHEN** the socket is disposed while a connection attempt or reconnect delay is in progress
- **THEN** the pending `connect` future completes with `null` instead of hanging

#### Scenario: Connected after dispose is rejected

- **WHEN** `connect` is called after the socket has been disposed
- **THEN** the returned future completes with a `StateError`

### Requirement: Connection state and events are ordered

`isConnected` SHALL report true only for an open connection that has completed its initial heartbeat round-trip. Open, error, and close events MUST be emitted in protocol order: an error event precedes the close event for the same failure, an open event is emitted once per established connection, and no event is emitted after disposal.

#### Scenario: Successful open

- **WHEN** the transport is ready and the initial heartbeat is acknowledged
- **THEN** exactly one open event is emitted and `isConnected` is true

#### Scenario: Failure ordering

- **WHEN** the transport reports an error that closes the connection
- **THEN** an error event is emitted before the close event for that failure

#### Scenario: Silent after disposal

- **WHEN** the socket has been disposed
- **THEN** no further open, error, or close events are emitted

### Requirement: Disposal is deterministic and idempotent

Disposal SHALL close the sink, cancel heartbeat and reconnect timers, cancel all subscriptions, close all channel and topic controllers, and complete every pending message or push future with an error. The asynchronous disposal operation MUST complete only after those resources are released, and calling it more than once MUST be a no-op. The existing synchronous disposal entry point SHALL remain available and delegate to the asynchronous operation.

#### Scenario: Pending push during disposal

- **WHEN** a push is awaiting a reply and the socket is disposed
- **THEN** the awaiting future completes with an error instead of remaining pending

#### Scenario: Repeated disposal

- **WHEN** disposal is invoked twice
- **THEN** the second invocation completes without throwing and without duplicating close work

#### Scenario: Resources are released

- **WHEN** asynchronous disposal completes
- **THEN** the underlying sink is closed, timers are cancelled, and no topic or channel controller remains open

### Requirement: Reconnection is bounded, jittered, and non-overlapping

Reconnection SHALL follow the configured delay sequence, use the final delay once the sequence is exhausted, and add jitter so clients do not retry simultaneously. At most one reconnect attempt may be pending or in flight, the delay index MUST reset after a successful open, and no reconnect may be scheduled after disposal.

#### Scenario: Delay sequence advances

- **WHEN** consecutive connection attempts fail
- **THEN** each retry waits for the next configured delay, capped at the final delay once the sequence is exhausted

#### Scenario: No overlapping retries

- **WHEN** a connection failure occurs while a reconnect delay is already pending
- **THEN** only one reconnect attempt is performed

#### Scenario: Reset after success

- **WHEN** a connection opens successfully after previous failures
- **THEN** the next failure starts again at the first configured delay

#### Scenario: Disposed during delay

- **WHEN** the socket is disposed while a reconnect delay is pending
- **THEN** no new connection attempt is started

### Requirement: Heartbeat detects unresponsive connections

The socket SHALL send a heartbeat at each configured interval and treat the connection as failed when a heartbeat reply does not arrive within the configured heartbeat timeout. A failed heartbeat MUST complete the pending heartbeat wait with an error, close the transport, emit the appropriate error and close events, and trigger reconnection according to policy. Heartbeat and timeout timers MUST be cancelled on close and disposal and MUST NOT be duplicated across reconnects.

#### Scenario: Heartbeat acknowledged

- **WHEN** a heartbeat reply arrives within the timeout
- **THEN** the connection remains open and no error event is emitted

#### Scenario: Heartbeat unanswered

- **WHEN** no heartbeat reply arrives within the configured heartbeat timeout
- **THEN** the transport is closed with a heartbeat-timeout indication and a reconnection is scheduled
- **AND** the pending heartbeat wait completes with an error

#### Scenario: No timer accumulation

- **WHEN** the socket closes and reopens repeatedly
- **THEN** at most one heartbeat timer is active at any time

### Requirement: Topic routing releases resources

Each topic subscription SHALL own a routing controller that is released when its last subscriber cancels or when the owning channel is removed. Removing one topic MUST NOT remove or disturb subscriptions for other topics.

#### Scenario: Last subscriber cancels

- **WHEN** the only subscriber for a topic cancels its subscription
- **THEN** the routing controller for that topic is removed from the socket

#### Scenario: Channel removal

- **WHEN** a channel is removed from the socket
- **THEN** both the stream registration and the routing controller for its topic are released

#### Scenario: Independent topics

- **WHEN** one topic's subscriber cancels
- **THEN** messages for other topics continue to be delivered

### Requirement: Raw socket exposes received frames

The raw socket variant SHALL expose a stream of undecoded received frames for consumers that bypass Phoenix message decoding. The stream MUST deliver both text and byte frames, MUST close when the socket is disposed, and MUST report an unsupported frame type as an error rather than throwing from the socket's data callback.

#### Scenario: Frames are forwarded

- **WHEN** the raw socket receives a text or byte frame
- **THEN** the raw frame stream emits that frame unchanged

#### Scenario: Stream closes on disposal

- **WHEN** the raw socket is disposed
- **THEN** its raw frame stream closes

#### Scenario: Unsupported frame type

- **WHEN** the raw socket receives a frame that is neither text nor bytes
- **THEN** the error is reported through the socket error surface

### Requirement: Public APIs evolve additively

Members superseded by this change SHALL remain functional, SHALL be annotated as deprecated with replacement guidance, and MUST NOT be removed or re-typed. Replacement members MUST be additive and documented. A consumer that ignores the deprecation warnings MUST observe unchanged behavior.

#### Scenario: Deprecated wait API still works

- **WHEN** a consumer calls the deprecated message-waiting API
- **THEN** it behaves as before and the analyzer reports a deprecation hint pointing at the replacement

#### Scenario: Asynchronous disposal is additive

- **WHEN** a consumer upgrades without changing code and calls synchronous disposal
- **THEN** the call compiles and disposes the socket as before
