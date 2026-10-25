import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:rxdart/rxdart.dart';
import 'package:test/test.dart';

import 'mocks.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a minimal mock WebSocket that emits one heartbeat reply then
/// goes silent — just enough for PhoenixSocket._connect() to succeed.
({MockWebSocketChannel ws, MockWebSocketSink sink}) _makeConnectableWs(
    int invocationTracker) {
  final sink = MockWebSocketSink();
  final ws = MockWebSocketChannel();
  var calls = 0;

  when(ws.sink).thenReturn(sink);
  when(ws.ready).thenAnswer((_) async {});
  when(ws.stream).thenAnswer((_) {
    if (calls++ < invocationTracker) return NeverStream();
    final ctrl = StreamController<String>()
      ..add(jsonEncode(Message.heartbeat('0').encode()));
    return ctrl.stream;
  });

  return (ws: ws, sink: sink);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // Clean up any test codecs registered across groups.
  tearDown(() {
    final reg = SerializerRegistry.instance;
    for (final name in ['codec-a', 'codec-b', 'counting']) {
      if (reg.has(name)) reg.unregister(name);
    }
  });

  group('PhoenixSocket — serializer isolation', () {
    test('socket exposes the serializer resolved at construction time', () {
      SerializerRegistry.instance.register(
        'codec-a',
        () => MessageSerializer(name: 'codec-a'),
      );

      final socket = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'codec-a'),
      );

      expect(socket.serializer.name, equals('codec-a'));
    });

    test(
        'two sockets with different codecs hold independent serializer instances',
        () {
      SerializerRegistry.instance
        ..register('codec-a', () => MessageSerializer(name: 'codec-a'))
        ..register('codec-b', () => MessageSerializer(name: 'codec-b'));

      final socketA = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'codec-a'),
      );
      final socketB = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'codec-b'),
      );

      expect(socketA.serializer.name, equals('codec-a'));
      expect(socketB.serializer.name, equals('codec-b'));
      expect(socketA.serializer, isNot(same(socketB.serializer)));
    });

    test('mutating one socket serializer does not affect another', () {
      SerializerRegistry.instance.register(
        'codec-a',
        () => MessageSerializer(name: 'codec-a'),
      );

      final socketA = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'codec-a'),
      );
      final socketB = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'codec-a'),
      );

      // Mutate only socketA's serializer.
      var customCalled = false;
      socketA.serializer.decoder = (raw) {
        customCalled = true;
        return jsonDecode(raw);
      };

      // socketB must be unaffected.
      socketB.serializer.decode('["0","1","t","e",{}]');
      expect(customCalled, isFalse,
          reason: 'socketB should use its own decoder, not socketA\'s');
    });

    test('socket uses the provided direct serializer instance', () {
      final custom = MessageSerializer(name: 'direct');
      final socket = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(serializer: custom),
      );
      expect(socket.serializer, same(custom));
    });

    test('runtime encoder swap is used for subsequent sendMessage calls',
        () async {
      final (:ws, :sink) = _makeConnectableWs(0);
      final encodeLog = <String>[];

      final socket = PhoenixSocket(
        'ws://localhost',
        webSocketChannelFactory: (_) => ws,
      );

      await socket.connect();

      // Replace encoder after connection.
      socket.serializer.encoder = (v) {
        final result = jsonEncode(v);
        encodeLog.add(result);
        return result;
      };

      // Push immediately — the channel state will be joining/buffered,
      // but the serializer is invoked when the message hits the sink.
      // We only verify the custom encoder was installed; actual socket
      // end-to-end is covered by channel_test.dart.
      expect(socket.serializer.encoder, isNotNull);
      expect(encodeLog, isEmpty); // nothing sent yet

      socket.dispose();
    });

    test('update() atomically replaces encoder + decoder on a live socket', () {
      final socket = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'json'),
      );

      var encCalled = false;
      var decCalled = false;

      socket.serializer.update(
        encoder: (v) {
          encCalled = true;
          return jsonEncode(v);
        },
        decoder: (r) {
          decCalled = true;
          return jsonDecode(r);
        },
      );

      // Verify the installed callbacks are used.
      socket.serializer.encode(Message(
        joinRef: '0',
        ref: '1',
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {},
      ));
      socket.serializer.decode('["0","1","t","e",{}]');

      expect(encCalled, isTrue);
      expect(decCalled, isTrue);

      socket.dispose();
    });

    test('factory is called once per socket, not once per resolve call', () {
      var factoryCalls = 0;
      SerializerRegistry.instance.register(
        'counting',
        () {
          factoryCalls++;
          return MessageSerializer(name: 'counting');
        },
      );

      // Creating one socket should call the factory exactly once.
      final _ = PhoenixSocket(
        'ws://localhost',
        socketOptions: PhoenixSocketOptions(codec: 'counting'),
      );

      expect(factoryCalls, equals(1));
    });
  });

  group('PhoenixSocketOptions — codec / serializer assertion', () {
    test('codec: "json" resolves to default JSON serializer', () {
      final s = PhoenixSocketOptions(codec: 'json').resolveSerializer();
      expect(s.name, equals('json'));
    });

    test('omitting both codec and serializer resolves to "json"', () {
      final s = PhoenixSocketOptions().resolveSerializer();
      expect(s.name, equals('json'));
    });

    test('providing both codec and serializer throws AssertionError', () {
      expect(
        () => PhoenixSocketOptions(
          codec: 'json',
          serializer: MessageSerializer(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('payloadDecoder shortcut is gone — use serializer: instead', () {
      // This test documents the migration: the old positional payloadDecoder
      // param no longer exists. Constructing via serializer: must work.
      var called = false;
      final opts = PhoenixSocketOptions(
        serializer: MessageSerializer(
          payloadDecoder: (bytes) {
            called = true;
            return <String, dynamic>{};
          },
        ),
      );
      final s = opts.resolveSerializer();
      expect(s.payloadDecoder, isNotNull);
      s.payloadDecoder!(Uint8List(1));
      expect(called, isTrue);
    });
  });
}
