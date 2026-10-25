# Spec Delta

## Purpose

Defines how channels join and leave a Phoenix topic, how pushes are buffered, correlated with replies, retried, and timed out, and how channel or socket failures reach caller futures without stranding them.

## ADDED Requirements

### Requirement: Join completes or fails explicitly

A channel join SHALL be attempted only after the socket is open. Joining before the socket connects MUST defer the attempt until the socket opens, and the join push MUST complete with the backend response, fail with the transport error when the socket fails, or complete as a timeout when no reply arrives. Joining the same channel a second time MUST fail with a `StateError` in every build mode.

#### Scenario: Join before socket is open

- **WHEN** a channel joins while the socket is still connecting
- **THEN** the join push completes once the socket opens and the backend acknowledges the join

#### Scenario: Join rejected by backend

- **WHEN** the backend replies with an error status
- **THEN** the join push completes with that error response and the channel enters the errored state

#### Scenario: Join timeout

- **WHEN** no join reply arrives within the configured timeout
- **THEN** the join push completes with a timeout response and a rejoin is scheduled when the socket is connected

#### Scenario: Double join

- **WHEN** join is called on a channel that has already joined once
- **THEN** the call throws a `StateError` in debug and release builds

### Requirement: Pushes on a joined channel receive exactly one reply

A push sent on a joined channel MUST complete its future exactly once with the matching reply. Reply correlation MUST use the push reference, duplicate or late replies MUST be ignored, and status callbacks registered for the reply's status MUST run once.

#### Scenario: Successful reply

- **WHEN** the backend replies with an `ok` status
- **THEN** the push future completes with that response and the `ok` callbacks run once

#### Scenario: Duplicate reply

- **WHEN** a second reply arrives for an already completed push
- **THEN** the existing future result is unchanged and no callback runs again

#### Scenario: Late reply after timeout

- **WHEN** a reply arrives after the push has already timed out
- **THEN** the timeout outcome for that push is preserved

### Requirement: Pushes buffer until the channel joins

Pushes issued while the channel is joining, errored, or awaiting rejoin SHALL be buffered and sent in submission order after a successful join. Buffered pushes MUST be discarded and their futures completed with an error when the channel closes or the socket is disposed.

#### Scenario: Buffer is flushed in order

- **WHEN** multiple pushes are issued before the join completes and the join succeeds
- **THEN** the pushes are sent in submission order

#### Scenario: Buffer is discarded on close

- **WHEN** the channel closes while pushes are buffered
- **THEN** those pushes are removed from the buffer and their futures complete with an error

### Requirement: Push timeout is terminal for awaiting callers

Each push SHALL schedule a timeout for its configured duration. When it expires, the awaiting future MUST fail with a timeout exception and the `timeout` callbacks MUST run. The timer MUST be cancelled when a reply arrives, when the push is reset, and when the channel closes.

#### Scenario: Timeout expires

- **WHEN** no reply arrives within the push timeout
- **THEN** the push future throws a channel timeout exception

#### Scenario: Reply before timeout

- **WHEN** the reply arrives before the timeout expires
- **THEN** the timeout timer is cancelled and no timeout exception is produced

#### Scenario: Close during pending push

- **WHEN** the channel closes while a push timeout is scheduled
- **THEN** the timer is cancelled and the pending future does not remain unresolved

### Requirement: Channel failures never strand waiters

Channel errors, channel closures, socket errors, and socket disposal MUST transition the channel to a terminal or recoverable state and MUST complete every registered waiter future with either the failure or a replacement outcome. Rejoin scheduling MUST keep at most one pending timer per channel.

#### Scenario: Backend channel error

- **WHEN** the backend sends a channel error event
- **THEN** registered waiters complete with an error and at most one rejoin timer is scheduled

#### Scenario: Socket closes with pending channel waiters

- **WHEN** the socket closes while channel waiters are registered
- **THEN** those waiters complete with an error instead of hanging

#### Scenario: Repeated errors

- **WHEN** multiple channel error events arrive in quick succession
- **THEN** only one rejoin attempt is scheduled

### Requirement: Leaving removes the channel exactly once

Leave SHALL send a leave message when the channel is joined and normalise the outcome on `ok` or `timeout`. When the channel is not joined, or the socket is disconnected, leave MUST complete locally. In all cases the channel MUST be closed, removed from the socket, its buffered pushes cancelled, its waiters completed, and repeated leave calls MUST be no-ops.

#### Scenario: Leave while joined

- **WHEN** leave is called on a joined channel and the backend replies with `ok`
- **THEN** the channel closes and is removed from the socket

#### Scenario: Leave while disconnected

- **WHEN** leave is called while the socket is disconnected
- **THEN** the channel closes locally without waiting for a backend reply

#### Scenario: Repeated leave

- **WHEN** leave is called twice
- **THEN** the second call does not resend a leave message or throw

### Requirement: Closed channels reject pushes

A push attempted on a closed or errored channel MUST fail with a channel-closed error before any bytes are written or buffered.

#### Scenario: Push on closed channel

- **WHEN** a push is issued on a closed channel
- **THEN** the call throws a channel-closed error and nothing is buffered

#### Scenario: Push after leave

- **WHEN** a push is issued after the channel has left
- **THEN** the call throws a channel-closed error

### Requirement: Channel message streams stay filtered

The channel message stream SHALL emit application messages and replies addressed to the channel's current join, and MUST NOT emit raw reply envelopes for other references or internal status messages that are not channel replies.

#### Scenario: Reply envelopes are not leaked

- **WHEN** a push reply arrives for a reference belonging to another channel
- **THEN** the channel message stream does not emit it

#### Scenario: Channel reply is forwarded

- **WHEN** a reply tagged for the channel is received
- **THEN** the channel message stream emits the channel reply form

#### Scenario: Application message is forwarded

- **WHEN** a non-status broadcast message arrives for the topic
- **THEN** the channel message stream emits it unchanged
