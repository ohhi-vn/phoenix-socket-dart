# wire-codec Specification

## Purpose

Defines the wire contract for outbound and inbound messages: the JSON envelope, binary framing and validation, payload post-processing, codec selection, and how malformed frames are reported without corrupting state or hanging callers.

## Requirements

### Requirement: Text frames follow the Phoenix v2 envelope

A text frame SHALL encode exactly five positional elements in order: join reference, reference, topic, event name, and payload. Absent references MUST round-trip as `null`, the payload MUST be preserved without reinterpretation, and decoding a frame that is not a five-element array or cannot be parsed MUST fail with a `FormatException` subtype that identifies the stage that failed.

#### Scenario: Round trip

- **WHEN** a message with a join reference, reference, topic, event, and map payload is encoded and decoded
- **THEN** every field is identical and absent references are `null`

#### Scenario: Invalid JSON

- **WHEN** a text frame is not valid per the configured decoder
- **THEN** decoding fails with a `FormatException` subtype and does not throw a `TypeError`

#### Scenario: Wrong envelope shape

- **WHEN** a decoded array has fewer or more than five elements
- **THEN** decoding fails with a `FormatException` subtype naming the envelope problem

### Requirement: Binary framing honors the source buffer view

Binary decoding SHALL read relative to the frame's own start offset and length, so a frame that is a view into a larger buffer decodes identically to the same bytes held in a standalone buffer.

#### Scenario: Non-zero offset view

- **WHEN** a valid frame is embedded at a non-zero offset of a larger byte buffer and decoded as a view
- **THEN** the decoded references, topic, event, and payload equal those of the standalone frame

#### Scenario: Offset in a push frame

- **WHEN** a push frame is supplied as an offset view
- **THEN** the join reference, topic, event, and payload are decoded without reading neighbouring bytes

### Requirement: Binary frames are validated before access

Binary decoding SHALL validate the message kind and every declared length against the available bytes before reading. Truncated frames, inconsistent lengths, and unknown kinds MUST fail with a `FormatException` subtype, MUST NOT raise `RangeError`, and MUST NOT return partially populated messages. Encoding MUST reject any reference, topic, or event whose UTF-8 length exceeds the single-byte length field with an `ArgumentError` before writing any bytes.

#### Scenario: Truncated frame

- **WHEN** a binary frame declares a topic length longer than the remaining bytes
- **THEN** decoding fails with a `FormatException` subtype and no message is produced

#### Scenario: Unknown kind

- **WHEN** the first byte of a binary frame is not a known message kind
- **THEN** decoding fails with a `FormatException` subtype that reports the kind

#### Scenario: Oversized field

- **WHEN** a field to encode exceeds the single-byte length limit
- **THEN** encoding throws an `ArgumentError` and no frame is returned

#### Scenario: Valid encode round trip

- **WHEN** a push, reply, or broadcast frame is encoded and then decoded
- **THEN** the decoded kind and fields match the encoded input

### Requirement: Binary payload post-processing is opt-in and type-safe

A configured payload decoder SHALL be applied only to binary payloads. Map results MUST be normalised to string keys recursively, byte results MUST pass through unchanged, and other results MUST be wrapped under a stable key. A frame carrying a codec-specific binary envelope MUST fail with a configuration error when no matching binary decoder is configured.

#### Scenario: Payload decoder configured

- **WHEN** a binary payload is decoded and a payload decoder is configured
- **THEN** the decoded value is passed through the documented normalisation rules

#### Scenario: No payload decoder

- **WHEN** a binary payload is decoded without a payload decoder
- **THEN** the raw bytes are returned unchanged

#### Scenario: Missing binary decoder for envelope

- **WHEN** a frame carries the codec-specific binary envelope and no binary decoder is configured
- **THEN** decoding fails with a configuration error naming the serializer

### Requirement: Codec configuration is validated in every build mode

Serializer selection SHALL reject mutually exclusive configuration and unknown codec names at socket construction with an `ArgumentError` rather than an assertion, in debug and release builds alike. Each socket MUST receive an independent serializer instance, the default codec MUST be JSON, and registration of a blank codec name MUST be rejected.

#### Scenario: Codec and serializer together

- **WHEN** both a codec name and a serializer instance are provided
- **THEN** socket construction throws an `ArgumentError`

#### Scenario: Unknown codec name

- **WHEN** a codec name that is not registered is provided
- **THEN** socket construction throws an `ArgumentError` listing the registered names

#### Scenario: Independent instances

- **WHEN** two sockets are created from the same registry entry
- **THEN** mutating one socket's serializer does not affect the other

#### Scenario: Unregister built-in codec

- **WHEN** removal of the built-in JSON codec is attempted
- **THEN** the operation throws a `StateError`

### Requirement: Inbound decode failures are isolated

A malformed inbound frame SHALL be reported through the socket error surface with the decode error and MUST be dropped. The socket SHALL remain usable, subsequent valid frames MUST be delivered, and no pending message or push future may be left unresolved because of a decode failure.

#### Scenario: Malformed frame then valid frame

- **WHEN** a malformed frame is followed by a valid frame
- **THEN** an error event is emitted for the malformed frame and the valid frame is delivered normally

#### Scenario: No stranded waiters

- **WHEN** a malformed frame arrives while a push reply is pending
- **THEN** the pending future is unaffected by the decode failure and completes on its own timeout or later reply

#### Scenario: Decode failure does not throw from the listener

- **WHEN** a malformed frame is received
- **THEN** the error is surfaced through the error stream rather than escaping the transport listener
