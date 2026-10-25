import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/internal/backoff.dart';
import 'package:phoenix_socket/src/internal/heartbeat.dart';
import 'package:test/test.dart';

import 'mocks.dart';

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Message _message({
  String topic = 'topic',
  String event = 'event',
  String? ref,
}) =>
    Message(
      topic: topic,
      event: PhoenixChannelEvent.custom(event),
      payload: const {},
      ref: ref,
    );

/// Mock transport that acknowledges heartbeats automatically.
class _Harness {
  _Harness({Future<void>? readyFuture})
      : readyFuture = readyFuture ?? Future<void>.value() {
    when(channel.stream).thenAnswer((_) => incoming.stream);
    when(channel.sink).thenReturn(sink);
    when(channel.ready).thenAnswer((_) => this.readyFuture);
    when(sink.close()).thenAnswer((_) async {});
    when(sink.close(any, any)).thenAnswer((_) async {});
    when(sink.add(any)).thenAnswer((invocation) {
      final data = invocation.positionalArguments.first;
      if (data is! String) return;
      final dynamic decoded;
      try {
        decoded = jsonDecode(data);
      } on FormatException {
        return;
      }
      if (decoded is List && decoded.length == 5 && decoded[3] == 'heartbeat') {
        incoming.add(jsonEncode([
          null,
          decoded[1],
          'phoenix',
          'phx_reply',
          {
            'status': 'ok',
            'response': <String, dynamic>{},
          },
        ]));
      }
    });
  }

  final MockWebSocketChannel channel = MockWebSocketChannel();
  final MockWebSocketSink sink = MockWebSocketSink();
  final StreamController<dynamic> incoming =
      StreamController<dynamic>.broadcast();
  final Future<void> readyFuture;

  PhoenixSocket create({
    List<Duration> reconnectDelays = const [Duration.zero],
    Duration? timeout,
  }) =>
      PhoenixSocket(
        'ws://localhost/socket/websocket',
        socketOptions: PhoenixSocketOptions(
          reconnectDelays: reconnectDelays,
          timeout: timeout,
        ),
        webSocketChannelFactory: (_) => channel,
      );
}

void main() {
  group('disposal', () {
    test('completes pending replies and closes resources once', () async {
      final harness = _Harness();
      final socket = harness.create();
      await socket.connect();

      final pending = socket.sendMessage(_message(ref: 'pending-1'));
      final pendingExpectation =
          expectLater(pending, throwsA(isA<PhoenixException>()));

      final first = socket.disposeAsync();
      final second = socket.disposeAsync();
      expect(identical(first, second), isTrue);

      await first;
      await pendingExpectation;

      expect(socket.channels, isEmpty);
      verify(harness.sink.close()).called(1);
      await harness.incoming.close();
    });

    test('resolves an in-flight connect with null', () async {
      final ready = Completer<void>();
      final harness = _Harness(readyFuture: ready.future);
      final socket = harness.create(timeout: const Duration(milliseconds: 50));

      final connectFuture = socket.connect();
      await Future<void>.delayed(Duration.zero);
      await socket.disposeAsync();

      expect(await connectFuture, isNull);
      await harness.incoming.close();
    });

    test('rejects connect and addChannel after disposal', () async {
      final harness = _Harness();
      final socket = harness.create();
      await socket.disposeAsync();

      expect(socket.connect(), throwsStateError);
      expect(() => socket.addChannel(topic: 'late'), throwsStateError);
      await harness.incoming.close();
    });

    test('fails pending replies when the transport errors', () async {
      final harness = _Harness();
      final socket = harness.create();
      await socket.connect();

      final pending = socket.sendMessage(_message(ref: 'pending-2'));
      final pendingExpectation =
          expectLater(pending, throwsA(isA<Exception>()));

      harness.incoming.addError(Exception('boom'));
      await pendingExpectation;

      await socket.disposeAsync();
      await harness.incoming.close();
    });
  });

  group('connection completion', () {
    test('coalesces concurrent connect attempts', () async {
      final harness = _Harness();
      var attempts = 0;
      final socket = PhoenixSocket(
        'ws://localhost/socket/websocket',
        webSocketChannelFactory: (_) {
          attempts++;
          return harness.channel;
        },
      );
      addTearDown(socket.disposeAsync);

      final first = socket.connect();
      final second = socket.connect();
      expect(identical(first, second), isTrue);

      expect(await first, same(socket));
      expect(attempts, 1);
      await harness.incoming.close();
    });

    test('retries after a synchronous factory failure', () async {
      var attempts = 0;
      final harness = _Harness();
      final socket = PhoenixSocket(
        'ws://localhost/socket/websocket',
        socketOptions: PhoenixSocketOptions(
          reconnectDelays: const [Duration.zero],
        ),
        webSocketChannelFactory: (_) {
          attempts++;
          if (attempts == 1) {
            throw StateError('factory failure');
          }
          return harness.channel;
        },
      );
      addTearDown(socket.disposeAsync);

      expect(await socket.connect(), same(socket));
      expect(attempts, 2);
      await harness.incoming.close();
    });

    test('emits one open per connection and keeps event order', () async {
      final harness = _Harness();
      final socket = harness.create();
      addTearDown(socket.disposeAsync);

      final opens = <PhoenixSocketOpenEvent>[];
      final order = <String>[];
      socket.openStream.listen(opens.add);
      socket.errorStream.listen((_) => order.add('error'));
      socket.closeStream.listen((_) => order.add('close'));

      await socket.connect();
      expect(opens, hasLength(1));

      // A second connect on an open socket must not re-emit open.
      await socket.connect();
      expect(opens, hasLength(1));

      harness.incoming.addError(Exception('transport failure'));
      await _waitUntil(() => order.length >= 2);
      expect(order, ['error', 'close']);

      await socket.disposeAsync();
      final eventsAfterDispose = order.length;
      harness.incoming.addError(Exception('late failure'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(order.length, eventsAfterDispose);
      await harness.incoming.close();
    });
  });

  group('topic routing', () {
    test('releases a topic when its last subscriber cancels', () async {
      final harness = _Harness();
      final socket = harness.create();
      addTearDown(socket.disposeAsync);

      final stream = socket.streamForTopic('alpha');
      expect(identical(stream, socket.streamForTopic('alpha')), isTrue);

      final subscription = stream.listen((_) {});
      await subscription.cancel();

      expect(identical(stream, socket.streamForTopic('alpha')), isFalse);
      await harness.incoming.close();
    });

    test('keeps topics independent and preserves delivery order', () async {
      final harness = _Harness();
      final socket = harness.create();
      addTearDown(socket.disposeAsync);

      final alpha = <Message>[];
      final beta = <Message>[];
      final alphaSub = socket.streamForTopic('alpha').listen(alpha.add);
      final betaSub = socket.streamForTopic('beta').listen(beta.add);

      socket.onSocketDataCallback(
        jsonEncode([null, null, 'alpha', 'one', <String, dynamic>{}]),
      );
      socket.onSocketDataCallback(
        jsonEncode([null, null, 'beta', 'two', <String, dynamic>{}]),
      );
      await _waitUntil(() => alpha.length == 1 && beta.length == 1);

      await alphaSub.cancel();
      socket.onSocketDataCallback(
        jsonEncode([null, null, 'alpha', 'three', <String, dynamic>{}]),
      );
      socket.onSocketDataCallback(
        jsonEncode([null, null, 'beta', 'four', <String, dynamic>{}]),
      );
      await _waitUntil(() => beta.length == 2);

      expect(alpha.map((m) => m.event.value), ['one']);
      expect(beta.map((m) => m.event.value), ['two', 'four']);

      await betaSub.cancel();
      await harness.incoming.close();
    });

    test('removes routing state when a channel is removed', () async {
      final harness = _Harness();
      final socket = harness.create();
      addTearDown(socket.disposeAsync);

      final channel = socket.addChannel(topic: 'gamma');
      final stream = socket.streamForTopic('gamma');
      channel.join();
      channel.close();

      expect(socket.channels.containsKey('gamma'), isFalse);
      expect(identical(stream, socket.streamForTopic('gamma')), isFalse);
      await harness.incoming.close();
    });
  });

  group('raw socket', () {
    test('forwards text and byte frames and closes on disposal', () async {
      final harness = _Harness();
      final raw = PhoenixRawSocket(
        'ws://localhost/socket/websocket',
        webSocketChannelFactory: (_) => harness.channel,
      );

      final received = <Object>[];
      final subscription = raw.rawMessages.listen(received.add);
      raw.onSocketDataCallback('hello');
      raw.onSocketDataCallback(Uint8List.fromList([1, 2]));
      await _waitUntil(() => received.length == 2);
      expect(received[0], 'hello');
      expect(received[1], [1, 2]);
      await subscription.cancel();

      final errors = <PhoenixSocketErrorEvent>[];
      final errorSub = raw.errorStream.listen(errors.add);
      raw.onSocketDataCallback(123);
      await _waitUntil(() => errors.length == 1);
      expect(errors.single.error, isA<ArgumentError>());
      await errorSub.cancel();

      final done = expectLater(raw.rawMessages, emitsDone);
      await raw.disposeAsync();
      await done;
      await harness.incoming.close();
    });
  });

  group('backoff and heartbeat', () {
    test('advances, caps, and resets the delay sequence', () {
      final policy = BackoffPolicy(
        const [Duration(seconds: 1), Duration(seconds: 2)],
        random: Random(7),
      );

      Duration jitter(Duration delay, Duration base) => delay - base;

      expect(jitter(policy.next(), const Duration(seconds: 1)),
          lessThan(const Duration(seconds: 1)));
      expect(jitter(policy.next(), const Duration(seconds: 2)),
          lessThan(const Duration(seconds: 1)));
      expect(jitter(policy.next(), const Duration(seconds: 2)),
          lessThan(const Duration(seconds: 1)));

      policy.reset();
      expect(jitter(policy.next(), const Duration(seconds: 1)),
          lessThan(const Duration(seconds: 1)));
    });

    test('heartbeat scheduler keeps a single timer', () {
      fakeAsync((async) {
        var ticks = 0;
        final heartbeat = HeartbeatScheduler(
          interval: const Duration(seconds: 30),
          onTick: () => ticks++,
        );

        heartbeat.start();
        async.elapse(const Duration(seconds: 30));
        expect(ticks, 1);

        heartbeat.start();
        async.elapse(const Duration(seconds: 30));
        expect(ticks, 2);

        heartbeat.stop();
        async.elapse(const Duration(minutes: 2));
        expect(ticks, 2);
      });
    });

    test('disposal during a reconnect delay stops further attempts', () {
      fakeAsync((async) {
        var attempts = 0;
        final channel = MockWebSocketChannel();
        final sink = MockWebSocketSink();
        when(channel.sink).thenReturn(sink);
        when(channel.stream).thenAnswer((_) => const Stream<dynamic>.empty());
        when(channel.ready)
            .thenAnswer((_) => Future<void>.error(Exception('nope')));
        when(sink.close()).thenAnswer((_) async {});
        when(sink.close(any, any)).thenAnswer((_) async {});

        final socket = PhoenixSocket(
          'ws://localhost/socket/websocket',
          socketOptions: PhoenixSocketOptions(
            reconnectDelays: const [Duration(seconds: 5)],
          ),
          webSocketChannelFactory: (_) {
            attempts++;
            return channel;
          },
        );

        socket.connect().ignore();
        async.flushMicrotasks();
        expect(attempts, 1);

        async.elapse(const Duration(milliseconds: 500));
        unawaited(socket.disposeAsync());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 20));

        expect(attempts, 1);
      });
    });
  });

  group('release-mode validation', () {
    test('rejects params and dynamicParams together', () {
      expect(
        () => PhoenixSocketOptions(
          params: const {'a': 'b'},
          dynamicParams: () async => const {'a': 'b'},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects double join and pushing before join', () async {
      final harness = _Harness();
      final socket = harness.create();
      addTearDown(socket.disposeAsync);

      final channel = socket.addChannel(topic: 'delta');
      channel.join();
      expect(() => channel.join(), throwsStateError);

      final other = socket.addChannel(topic: 'epsilon');
      expect(
        () => other.push('event', const {}),
        throwsA(isA<StateError>()),
      );
      await harness.incoming.close();
    });
  });
}
