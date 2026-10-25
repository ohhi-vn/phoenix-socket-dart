# presence Specification

## Purpose

Keeps an application's local copy of Phoenix Presence membership in sync with the server so clients can render who is online, joins or leaves, and per-presence metadata without hand-parsing presence frames.

## Requirements

### Requirement: State snapshots replace local presence state

A state event SHALL be treated as the authoritative membership snapshot: it replaces the previous state, removes members absent from the snapshot, and completes before sync observers are notified.

#### Scenario: First snapshot populates state

- **WHEN** a state message arrives with two presence keys
- **THEN** the client state contains exactly those two keys with their metadata
- **AND** `onSync` is invoked once

#### Scenario: Snapshot removes absent members

- **WHEN** the state holds keys A and B
- **AND** a state message arrives containing only A
- **THEN** B is removed from state
- **AND** `onLeave` is invoked for B with its previous presence

#### Scenario: Empty snapshot clears state

- **WHEN** a state message arrives with an empty payload
- **THEN** the client state becomes empty
- **AND** `onLeave` is invoked for each previously tracked presence
- **AND** `onSync` is invoked once

### Requirement: Diff frames apply every presence in the frame

A diff event SHALL apply every entry of its joins and leaves groups, including frames carrying more than one presence in the same group, rather than only the first entry.

#### Scenario: Multiple joins in one frame

- **WHEN** a diff message joins A and B in the same frame
- **THEN** both A and B are present in state
- **AND** `onJoin` is invoked once per presence

#### Scenario: Multiple leaves in one frame

- **WHEN** state holds A and B
- **AND** a diff message leaves both A and B in the same frame
- **THEN** both are removed from state
- **AND** `onLeave` is invoked once per presence

#### Scenario: Join adds metadata to an existing presence

- **WHEN** state holds A with one metadata entry
- **AND** a diff joins A with an additional entry that has a different reference
- **THEN** A retains its earlier metadata and includes the new entry

#### Scenario: Leave removes only the listed metadata

- **WHEN** A holds two metadata entries
- **AND** a diff leaves A with one of those entries
- **THEN** A remains in state with the other entry
- **AND** `onLeave` reports the removed entry

#### Scenario: Leaving the last metadata removes the presence

- **WHEN** A holds a single metadata entry
- **AND** a diff leaves A with that entry
- **THEN** A is removed from state

### Requirement: Diffs received before a snapshot are buffered

While the client is not in sync with the channel's current join, diff events SHALL be queued and applied in arrival order immediately after the next state snapshot.

#### Scenario: Diff before the first snapshot

- **WHEN** a diff message arrives before any state message
- **THEN** state is unchanged and the diff is queued
- **AND** when a state message arrives, the queued diff is applied after the snapshot
- **AND** `onSync` is invoked once for the combined update

#### Scenario: Diff after a rejoin

- **WHEN** the channel's join reference changes
- **AND** a diff message arrives before the matching state message
- **THEN** the diff is queued and applied after that state message

### Requirement: Sync state follows the channel join reference

`inPendingSyncState` SHALL be true until a state snapshot has been processed for the channel's current join reference, and false afterwards.

#### Scenario: Before any snapshot

- **WHEN** no state message has been processed
- **THEN** `inPendingSyncState` is true

#### Scenario: After a matching snapshot

- **WHEN** a state message has been processed for the channel's current join reference
- **THEN** `inPendingSyncState` is false

### Requirement: Presence events notify join, leave and sync observers

The client SHALL invoke `onJoin` for each joining presence with the key, the prior presence (or null) and the joining presence; `onLeave` for each leaving presence with the key, the remaining presence and the leaving presence; and `onSync` once after each applied update.

#### Scenario: Join callback arguments

- **WHEN** a presence joins
- **THEN** `onJoin` receives the presence key, null as the prior presence, and the joining presence

#### Scenario: Leave callback arguments

- **WHEN** a presence leaves a key that no longer has metadata
- **THEN** `onLeave` receives the presence key, the remaining presence, and the leaving presence

#### Scenario: Sync notifies once per update

- **WHEN** a single diff message applies one join and one leave
- **THEN** `onSync` is invoked once

### Requirement: Presence event names are configurable

The client SHALL accept a map overriding the state and diff event names and SHALL fall back to `presence_state` and `presence_diff` for names it does not override.

#### Scenario: Custom names are honored

- **WHEN** the client is constructed with custom state and diff names
- **THEN** messages using those names update state

#### Scenario: Partial override keeps the default

- **WHEN** only the state name is overridden
- **THEN** diff messages using `presence_diff` still update state

#### Scenario: Unrelated channel messages are ignored

- **WHEN** a channel message uses an event name that is not a configured presence event
- **THEN** state and callbacks are unchanged

### Requirement: Presence list projection

The client SHALL expose a list projection returning one entry per presence, projecting each entry through an optional chooser and returning the presence itself when no chooser is supplied.

#### Scenario: Default projection

- **WHEN** the projection is called without a chooser over two presences
- **THEN** it returns the two presence objects

#### Scenario: Custom chooser

- **WHEN** the projection is called with a chooser
- **THEN** it returns the chooser result for each presence key

#### Scenario: Empty state

- **WHEN** the projection is called over an empty map
- **THEN** it returns an empty list

### Requirement: Presence metadata exposes raw fields and reference

Each metadata entry SHALL expose the server-provided reference and the full raw field map, and cloning a presence or metadata entry SHALL produce an independent copy with the same data.

#### Scenario: Metadata fields are accessible

- **WHEN** a presence is decoded from a payload entry containing a reference and custom fields
- **THEN** its metadata exposes the reference and the custom fields

#### Scenario: Clone isolation

- **WHEN** a presence is cloned and the clone's metadata is modified
- **THEN** the original presence and its metadata are unchanged

### Requirement: Client state is isolated from later updates

Applying a state snapshot or diff SHALL NOT mutate presence maps or presence objects previously returned to callers.

#### Scenario: Captured state is stable

- **WHEN** a caller captures the client state
- **AND** a later diff changes membership
- **THEN** the captured map and the metadata of its presences are unchanged

### Requirement: Disposal stops presence processing

After disposal the client SHALL stop consuming channel messages and SHALL no longer mutate state or invoke callbacks.

#### Scenario: Messages after disposal

- **WHEN** the client has been disposed
- **AND** the channel emits a presence state message
- **THEN** state and callbacks are unchanged
