import 'dart:async';
import 'dart:convert';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'mocks.dart';

// ── Alternative codec A: Canonical JSON ───────────────────────────────────────
//
// Sorts object keys recursively before encoding. Produces the same values as
// dart:convert but in a deterministic key order — identical to what a library
// like `canonical_json` or a signing SDK would produce.

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final sorted = Map.fromEntries(
      (value.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => MapEntry(e.key, _sortKeys(e.value))),
    );
    return sorted;
  }
  if (value is List) return value.map(_sortKeys).toList();
  return value;
}

String _canonicalEncode(Object? value) => jsonEncode(_sortKeys(value));

// Decode is identical to dart:convert — canonical JSON is valid JSON.
dynamic _canonicalDecode(String raw) => jsonDecode(raw);

// ── Alternative codec B: Prefixed JSON ────────────────────────────────────────
//
// Prepends a "v1:" frame marker to every encoded message, simulating the wire
// format a versioned protocol or custom framing library would produce.
// A message encoded by this codec CANNOT be decoded by dart:convert alone —
// jsonDecode("v1:[...]") throws a FormatException.

const _framePrefix = 'v1:';

String _prefixedEncode(Object? value) => '$_framePrefix${jsonEncode(value)}';

dynamic _prefixedDecode(String raw) {
  if (!raw.startsWith(_framePrefix)) {
    throw FormatException(
      'Prefixed codec: expected "$_framePrefix" frame marker, got: '
      '${raw.length > 20 ? '${raw.substring(0, 20)}…' : raw}',
    );
  }
  return jsonDecode(raw.substring(_framePrefix.length));
}

// ── Registry setup ────────────────────────────────────────────────────────────

void _registerCodecs() {
  SerializerRegistry.instance
    ..register(
      'canonical',
      () => MessageSerializer(
        name: 'canonical',
        encoder: _canonicalEncode,
        decoder: _canonicalDecode,
      ),
    )
    ..register(
      'prefixed',
      () => MessageSerializer(
        name: 'prefixed',
        encoder: _prefixedEncode,
        decoder: _prefixedDecode,
      ),
    );
}

void _unregisterCodecs() {
  final reg = SerializerRegistry.instance;
  if (reg.has('canonical')) reg.unregister('canonical');
  if (reg.has('prefixed')) reg.unregister('prefixed');
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds a connectable mock WebSocket that echoes a heartbeat reply for
/// every heartbeat frame sent to it, so PhoenixSocket._connect() succeeds
/// on the first attempt and stays open afterwards.
///
/// [encoder] must match the codec used by the socket under test — the
/// heartbeat reply the mock emits is decoded by that socket's serializer,
/// so it must be encoded in the same format (e.g. prefixed for the prefixed
/// codec, plain JSON for all others).
({MockWebSocketChannel ws, MockWebSocketSink sink, List<dynamic> sent}) _makeWs(
    {EncoderCallback encoder = jsonEncode}) {
  final sink = MockWebSocketSink();
  final ws = MockWebSocketChannel();
  final sent = <dynamic>[];

  // Persistent incoming stream: every connection attempt subscribes to it,
  // and replies are pushed in response to frames captured in sink.add,
  // carrying the exact ref of the request they answer.
  final incoming = StreamController<String>.broadcast();

  when(ws.sink).thenReturn(sink);
  when(ws.ready).thenAnswer((_) async {});
  when(ws.stream).thenAnswer((_) => incoming.stream);

  when(sink.add(any)).thenAnswer((inv) {
    final frame = inv.positionalArguments.first as String;
    sent.add(frame);

    final raw = frame.startsWith(_framePrefix)
        ? frame.substring(_framePrefix.length)
        : frame;
    final parts = jsonDecode(raw) as List;

    if (parts[3] == 'heartbeat') {
      incoming.add(encoder(Message.heartbeat(parts[1] as String).encode()));
    }
  });

  return (ws: ws, sink: sink, sent: sent);
}

PhoenixSocket _makeSocket(
  String codec,
  MockWebSocketChannel ws,
) =>
    PhoenixSocket(
      'ws://localhost',
      socketOptions: PhoenixSocketOptions(codec: codec),
      webSocketChannelFactory: (_) => ws,
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(_registerCodecs);
  tearDownAll(_unregisterCodecs);

  // ── Canonical JSON codec ──────────────────────────────────────────────────

  group('Canonical JSON codec', () {
    late MessageSerializer s;

    setUp(() => s = SerializerRegistry.instance.resolve('canonical'));

    test('encodes with sorted keys', () {
      // z before a in insertion order — canonical must sort them.
      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {
          'z': 2,
          'a': 1,
          'm': {'y': 9, 'b': 3}
        },
      );

      final encoded = s.encode(msg) as String;
      // Decode and re-encode with dart:convert to normalise whitespace, then
      // check key ordering is alphabetical at every level.
      final parts = jsonDecode(encoded) as List;
      final payload = parts[4] as Map<String, dynamic>;

      expect(payload.keys.toList(), equals(['a', 'm', 'z']),
          reason: 'top-level keys must be sorted');
      expect((payload['m'] as Map).keys.toList(), equals(['b', 'y']),
          reason: 'nested keys must be sorted');
    });

    test('produces valid JSON that dart:convert can decode', () {
      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'b': 2, 'a': 1},
      );

      final encoded = s.encode(msg) as String;
      // canonical JSON is still valid JSON — no format-specific prefix.
      expect(() => jsonDecode(encoded), returnsNormally);
    });

    test('round-trips a message correctly', () {
      final original = Message(
        joinRef: '1',
        ref: '2',
        topic: 'room:lobby',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: {'z': 99, 'a': 1},
      );

      final decoded = s.decode(s.encode(original) as String);

      expect(decoded.joinRef, equals(original.joinRef));
      expect(decoded.ref, equals(original.ref));
      expect(decoded.topic, equals(original.topic));
      expect(decoded.event.value, equals(original.event.value));
      // Values survive the round-trip regardless of key order.
      expect(decoded.payload['a'], equals(1));
      expect(decoded.payload['z'], equals(99));
    });

    test('sorted output differs from default dart:convert for unordered input',
        () {
      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'z': 2, 'a': 1},
      );

      final canonical = _canonicalEncode(msg.encode());
      final standard = jsonEncode(msg.encode());

      // dart:convert preserves insertion order (z before a),
      // canonical always sorts (a before z) — they must differ.
      expect(canonical, isNot(equals(standard)));
    });
  });

  // ── Prefixed JSON codec ───────────────────────────────────────────────────

  group('Prefixed JSON codec', () {
    late MessageSerializer s;

    setUp(() => s = SerializerRegistry.instance.resolve('prefixed'));

    test('encoded output starts with the frame marker', () {
      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'foo': 1},
      );

      final encoded = s.encode(msg) as String;
      expect(encoded, startsWith(_framePrefix));
    });

    test('round-trips a message correctly', () {
      final original = Message(
        joinRef: '1',
        ref: '2',
        topic: 'room:lobby',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: {'foo': 'bar'},
      );

      final decoded = s.decode(s.encode(original) as String);

      expect(decoded.joinRef, equals(original.joinRef));
      expect(decoded.ref, equals(original.ref));
      expect(decoded.topic, equals(original.topic));
      expect(decoded.event.value, equals(original.event.value));
      expect(decoded.payload, equals({'foo': 'bar'}));
    });

    test('dart:convert cannot decode a prefixed frame', () {
      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {},
      );

      final prefixedFrame = s.encode(msg) as String;

      // This is the key isolation property: a frame from the prefixed codec
      // is not valid JSON as far as dart:convert is concerned.
      expect(
        () => jsonDecode(prefixedFrame),
        throwsA(isA<FormatException>()),
        reason: 'prefixed frames must not be decodable by dart:convert alone',
      );
    });

    test('prefixed decoder rejects a plain JSON frame', () {
      // If a plain-JSON frame arrives on a prefixed-codec socket the decoder
      // must reject it loudly rather than silently misparse it.
      const plainJson = '["0","1","t","e",{}]';

      expect(
        () => s.decode(plainJson),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains(_framePrefix),
        )),
      );
    });
  });

  // ── Cross-codec isolation ─────────────────────────────────────────────────

  group('Cross-codec isolation', () {
    test('canonical and prefixed codecs produce different wire formats', () {
      final canonical = SerializerRegistry.instance.resolve('canonical');
      final prefixed = SerializerRegistry.instance.resolve('prefixed');

      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'key': 'value'},
      );

      final canonicalFrame = canonical.encode(msg) as String;
      final prefixedFrame = prefixed.encode(msg) as String;

      expect(canonicalFrame, isNot(equals(prefixedFrame)));
      expect(prefixedFrame, startsWith(_framePrefix));
      expect(canonicalFrame, isNot(startsWith(_framePrefix)));
    });

    test('canonical socket and prefixed socket hold independent instances', () {
      final socketA = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'canonical'));
      final socketB = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'prefixed'));

      expect(socketA.serializer.name, equals('canonical'));
      expect(socketB.serializer.name, equals('prefixed'));
      expect(socketA.serializer, isNot(same(socketB.serializer)));

      socketA.dispose();
      socketB.dispose();
    });

    test('mutating one socket serializer does not affect the other', () {
      final socketA = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'canonical'));
      final socketB = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'canonical'));

      addTearDown(() {
        socketA.dispose();
        socketB.dispose();
      });

      // Replace socketA's encoder only.
      var aCalled = false;
      socketA.serializer.encoder = (v) {
        aCalled = true;
        return _canonicalEncode(v);
      };

      // Encode on socketB — must use the original, unmodified encoder.
      socketB.serializer.encode(Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {},
      ));

      expect(aCalled, isFalse,
          reason: "socketB must not use socketA's replaced encoder");
    });

    test(
        'two sockets with different codecs send differently encoded frames '
        'over the wire', () async {
      final mockA = _makeWs(encoder: _canonicalEncode);
      final mockB = _makeWs(encoder: _prefixedEncode);

      final socketA = _makeSocket('canonical', mockA.ws);
      final socketB = _makeSocket('prefixed', mockB.ws);

      await Future.wait([socketA.connect(), socketB.connect()]);

      addTearDown(() {
        socketA.dispose();
        socketB.dispose();
      });

      // The first frame each socket sends is a heartbeat.
      // canonical heartbeat: standard JSON, no prefix.
      // prefixed heartbeat: starts with "v1:".
      expect(mockA.sent, isNotEmpty,
          reason: 'canonical socket must have sent frames');
      expect(mockB.sent, isNotEmpty,
          reason: 'prefixed socket must have sent frames');

      final heartbeatA = mockA.sent.first as String;
      final heartbeatB = mockB.sent.first as String;

      expect(heartbeatA, isNot(startsWith(_framePrefix)),
          reason: 'canonical socket must NOT prepend frame marker');
      expect(heartbeatB, startsWith(_framePrefix),
          reason: 'prefixed socket MUST prepend frame marker');
      expect(heartbeatA, isNot(equals(heartbeatB)));
    });

    test('runtime codec swap on one socket does not affect the other',
        () async {
      final socketA = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'canonical'));
      final socketB = PhoenixSocket('ws://localhost',
          socketOptions: PhoenixSocketOptions(codec: 'canonical'));

      addTearDown(() {
        socketA.dispose();
        socketB.dispose();
      });

      // Swap socketA to prefixed at runtime.
      final prefixed = SerializerRegistry.instance.resolve('prefixed');
      socketA.serializer.update(
        encoder: prefixed.encoder,
        decoder: prefixed.decoder,
      );

      final msg = Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'k': 'v'},
      );

      final frameA = socketA.serializer.encode(msg) as String;
      final frameB = socketB.serializer.encode(msg) as String;

      expect(frameA, startsWith(_framePrefix),
          reason: 'socketA was swapped to prefixed — must have marker');
      expect(frameB, isNot(startsWith(_framePrefix)),
          reason: 'socketB still uses canonical — must NOT have marker');
    });
  });
}
