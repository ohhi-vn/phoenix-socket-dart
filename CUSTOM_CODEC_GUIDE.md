# Custom codec integration guide

`phoenix_socket` decouples wire encoding from the socket lifecycle through
`MessageSerializer` and `SerializerRegistry`. Any library that can turn a
`List` into a `String` (and back) can be used as a drop-in codec.

---

## Concepts

| Class | Role |
|---|---|
| `MessageSerializer` | Holds the three codec callbacks for one socket. Mutable at runtime. |
| `SerializerRegistry` | Global factory registry. Each socket gets a **fresh instance** from the registered factory. |
| `PhoenixSocketOptions(codec:)` | Selects a codec by name at socket-creation time. |
| `PhoenixSocketOptions(serializer:)` | Bypasses the registry; you supply the instance directly. |

The three callbacks inside `MessageSerializer`:

```dart
// Encodes a List (the Phoenix v2 wire array) to a String.
typedef EncoderCallback = String Function(Object? data);

// Decodes a String back to a List.
typedef DecoderCallback = dynamic Function(String rawData);

// Post-processes binary payloads after the Phoenix binary envelope is unpacked.
// Only needed when the server sends Uint8List payloads (e.g. MessagePack body).
typedef PayloadDecoderCallback = dynamic Function(Uint8List payload);
```

---

## Quick start

### 1. Register your codec once at app startup

```dart
import 'package:phoenix_socket/phoenix_socket.dart';

void setupCodecs() {
  SerializerRegistry.instance.register(
    'my_codec',
    () => MessageSerializer(
      name: 'my_codec',
      encoder: myLibrary.encode,
      decoder: myLibrary.decode,
    ),
  );
}

void main() {
  setupCodecs();
  // ...
}
```

### 2. Pass the codec name to every socket that should use it

```dart
final socket = PhoenixSocket(
  'wss://example.com/socket/websocket',
  socketOptions: PhoenixSocketOptions(codec: 'my_codec'),
);
```

Each socket gets its own independent `MessageSerializer` instance. Mutations
on one socket never affect another.

---

## Example integrations

### dart:convert (default — no setup needed)

The `'json'` codec is pre-registered. Omitting `codec:` is equivalent to
`codec: 'json'`.

```dart
// These three are identical:
PhoenixSocketOptions()
PhoenixSocketOptions(codec: 'json')
PhoenixSocketOptions(serializer: MessageSerializer())
```

---

### dart:convert with sorted keys (canonical JSON)

Useful when payloads must be signed or hashed — sorted keys produce a
deterministic byte sequence regardless of insertion order.

```dart
import 'dart:convert';

Object? _sortKeys(Object? v) {
  if (v is Map) {
    return Map.fromEntries(
      (v.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => MapEntry(e.key, _sortKeys(e.value))),
    );
  }
  if (v is List) return v.map(_sortKeys).toList();
  return v;
}

SerializerRegistry.instance.register(
  'canonical',
  () => MessageSerializer(
    name: 'canonical',
    encoder: (v) => jsonEncode(_sortKeys(v)),
    decoder: jsonDecode, // canonical JSON is still valid JSON
  ),
);
```

---

### json_serializable / built_value

These libraries generate `toJson` / `fromJson` helpers but ultimately call
`dart:convert` under the hood. Wire them up the same way:

```dart
// pubspec.yaml
// dependencies:
//   json_annotation: ^4.8.1
// dev_dependencies:
//   build_runner: ^2.4.0
//   json_serializable: ^6.7.0

SerializerRegistry.instance.register(
  'json_serializable',
  () => MessageSerializer(
    name: 'json_serializable',
    // JsonEncoder / JsonDecoder from dart:convert accept custom toEncodable
    // hooks that delegate to generated toJson() methods.
    encoder: (v) => JsonEncoder((o) => o is JsonSerializable ? o.toJson() : o)
        .convert(v),
    decoder: jsonDecode,
  ),
);
```

---

### msgpack_dart (binary MessagePack)

MessagePack serializes to `Uint8List` rather than `String`. The Phoenix
text-frame envelope still carries a JSON wrapper, so the pattern is:
JSON-encode the envelope array as usual and put the MessagePack bytes as
the payload — or use the Phoenix **binary frame** path by passing a
`Uint8List` payload directly and providing a `payloadDecoder`.

**Option A — binary payload (recommended for large payloads)**

```dart
// pubspec.yaml
// dependencies:
//   msgpack_dart: ^0.2.0

import 'package:msgpack_dart/msgpack_dart.dart';

SerializerRegistry.instance.register(
  'msgpack',
  () => MessageSerializer(
    name: 'msgpack',
    // Text-frame codec stays as JSON (Phoenix envelope).
    encoder: jsonEncode,
    decoder: jsonDecode,
    // Binary payloads inside Phoenix binary frames are decoded with MessagePack.
    payloadDecoder: (bytes) => deserialize(bytes),
  ),
);
```

On the sending side, pass a `Uint8List` as the push payload and the
`BinaryDecoder` envelope path is used automatically:

```dart
channel.push('upload', serialize({'file': data})); // Uint8List payload
```

**Option B — encode the entire envelope as MessagePack**

Only viable if your Phoenix backend is also configured to speak MessagePack
frames. The encoder and decoder must be symmetric:

```dart
SerializerRegistry.instance.register(
  'msgpack_full',
  () => MessageSerializer(
    name: 'msgpack_full',
    // The encoder receives a List (the Phoenix v2 array).
    // Cast to String via base64 to satisfy EncoderCallback's return type,
    // then decode on the other side.
    encoder: (v) => base64.encode(serialize(v)),
    decoder: (raw) => deserialize(base64.decode(raw)),
  ),
);
```

---

### TOON (or any custom binary-text codec)

Replace the three stubs below with the real TOON API once the package is
available:

```dart
// Stubs — replace with real TOON API:
String _toonEncode(Object? value) => ToonCodec.encode(value);
dynamic _toonDecode(String raw)   => ToonCodec.decode(raw);
dynamic _toonDecodePayload(Uint8List bytes) => ToonCodec.decodeBinary(bytes);

SerializerRegistry.instance.register(
  'toon',
  () => MessageSerializer(
    name: 'toon',
    encoder: _toonEncode,
    decoder: _toonDecode,
    payloadDecoder: _toonDecodePayload,
  ),
);
```

---

## Running multiple codecs simultaneously

Each `PhoenixSocket` is isolated — different sockets on the same app can use
different codecs at the same time:

```dart
setupCodecs(); // register all codecs once

final jsonSocket = PhoenixSocket(url,
    socketOptions: PhoenixSocketOptions(codec: 'json'));

final toonSocket = PhoenixSocket(url,
    socketOptions: PhoenixSocketOptions(codec: 'toon'));

final msgpackSocket = PhoenixSocket(url,
    socketOptions: PhoenixSocketOptions(codec: 'msgpack'));

await Future.wait([
  jsonSocket.connect(),
  toonSocket.connect(),
  msgpackSocket.connect(),
]);
```

---

## Swapping a codec at runtime

The serializer is mutable after the socket is created. Changes take effect
on the very next message processed.

```dart
// Swap both encoder and decoder atomically (no message slips through
// with mismatched encoder/decoder between the two setter calls).
socket.serializer.update(
  encoder: newLib.encode,
  decoder: newLib.decode,
);

// Swap only the binary payload decoder (e.g. after auth reveals the format).
socket.serializer.payloadDecoder = newLib.decodeBinary;

// Remove binary payload decoder (raw Uint8List passes through unchanged).
socket.serializer.update(clearPayloadDecoder: true);

// Inspect the current codec name for logging / debugging.
print(socket.serializer); // MessageSerializer(name: toon)
```

---

## Writing your own codec

Implement two functions and register a factory:

```dart
// 1. Encoder — receives the Phoenix v2 wire array:
//    [join_ref, ref, topic, event, payload]
//    Must return a String.
String myEncode(Object? value) { ... }

// 2. Decoder — receives the raw String from the WebSocket.
//    Must return a List with 5 elements in the same order.
dynamic myDecode(String raw) { ... }

// 3. (Optional) payload decoder — receives Uint8List from binary frames.
//    Return Map<String,dynamic>, Uint8List, or wrap in {'data': value}.
dynamic myPayloadDecode(Uint8List bytes) { ... }

// 4. Register.
SerializerRegistry.instance.register(
  'my_codec',
  () => MessageSerializer(
    name: 'my_codec',
    encoder: myEncode,
    decoder: myDecode,
    payloadDecoder: myPayloadDecode, // optional
  ),
);
```

### Rules your codec must follow

| Rule | Why |
|---|---|
| `encoder` input is always a `List` | Phoenix v2 protocol — the wire array `[join_ref, ref, topic, event, payload]` |
| `decoder` output must be a `List` with exactly 5 elements | `Message.fromJson` reads positional indices 0–4 |
| `encoder` must return `String` | `WebSocketChannel.sink.add` accepts `String` or `List<int>`, but Phoenix text frames are `String` |
| Round-trip must be lossless | `decode(encode(msg))` must reproduce the original field values |
| Stateless | The same instance is shared across reconnects; callbacks must not accumulate state |

### Testing your codec

Use the helpers from `test/codec_switching_test.dart` as a template.
The minimum test surface:

```dart
test('round-trips a message', () {
  final s = SerializerRegistry.instance.resolve('my_codec');
  final original = Message(
    joinRef: '1', ref: '2', topic: 'room:1',
    event: PhoenixChannelEvent.custom('msg'),
    payload: {'key': 'value'},
  );
  final decoded = s.decode(s.encode(original) as String);

  expect(decoded.joinRef, equals(original.joinRef));
  expect(decoded.ref,     equals(original.ref));
  expect(decoded.topic,   equals(original.topic));
  expect(decoded.event.value, equals(original.event.value));
  expect(decoded.payload, equals(original.payload));
});

test('is not decodable by dart:convert (if using custom format)', () {
  final s = SerializerRegistry.instance.resolve('my_codec');
  final encoded = s.encode(someMessage) as String;
  expect(() => jsonDecode(encoded), throwsA(isA<FormatException>()));
});
```

---

## API reference summary

```dart
// Register a codec (call once at startup).
SerializerRegistry.instance.register('name', () => MessageSerializer(...));

// Unregister (cannot unregister 'json').
SerializerRegistry.instance.unregister('name');

// Check registration.
SerializerRegistry.instance.has('name'); // bool

// List all registered codecs.
SerializerRegistry.instance.registeredNames; // Set<String>

// Select codec for a socket.
PhoenixSocketOptions(codec: 'name')           // looked up from registry
PhoenixSocketOptions(serializer: myInstance)  // direct — bypasses registry

// Access the live serializer on a connected socket.
socket.serializer.name
socket.serializer.encoder
socket.serializer.decoder
socket.serializer.payloadDecoder

// Atomic multi-field update.
socket.serializer.update(encoder: e, decoder: d, payloadDecoder: p);
socket.serializer.update(clearPayloadDecoder: true);

// Derive a new serializer from an existing one (non-mutating).
final copy = socket.serializer.copyWith(encoder: newEncoder);
```
