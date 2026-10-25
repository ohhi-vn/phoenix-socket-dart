import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
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

class _ChannelHarness {
  _ChannelHarness() {
    when(channel.stream).thenAnswer((_) => incoming.stream);
    when(channel.sink).thenReturn(sink);
    when(channel.ready).thenAnswer((_) async {});
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
      if (decoded is! List) return;
      sent.add(decoded.cast<dynamic>());
      if (decoded[3] == 'heartbeat') {
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
  final List<List<dynamic>> sent = [];

  late final PhoenixSocket socket = PhoenixSocket(
    'ws://localhost/socket/websocket',
    socketOptions: PhoenixSocketOptions(
      reconnectDelays: const [Duration(hours: 1)],
    ),
    webSocketChannelFactory: (_) => channel,
  );

  Future<void> connect() async {
    await socket.connect();
  }

  List<List<dynamic>> sentOf(String event) =>
      sent.where((message) => message[3] == event).toList(growable: false);

  void replyTo(
    List<dynamic> request, {
    String status = 'ok',
    dynamic response = const <String, dynamic>{},
  }) {
    incoming.add(jsonEncode([
      request[0],
      request[1],
      request[2],
      'phx_reply',
      {'status': status, 'response': response},
    ]));
  }

  void deliver(
    String topic,
    String event,
    dynamic payload, {
    String? joinRef,
    String? ref,
  }) {
    incoming.add(jsonEncode([joinRef, ref, topic, event, payload]));
  }
}

Future<PhoenixChannel> _joinedChannel(
  _ChannelHarness harness, {
  String topic = 'room',
}) async {
  final channel = harness.socket.addChannel(topic: topic);
  final join = channel.join();
  await _waitUntil(() => harness.sentOf('phx_join').isNotEmpty);
  harness.replyTo(harness.sentOf('phx_join').last);
  await join.future;
  return channel;
}

void main() {
  late _ChannelHarness harness;

  setUp(() async {
    harness = _ChannelHarness();
    await harness.connect();
  });

  tearDown(() async {
    await harness.socket.disposeAsync();
    await harness.incoming.close();
  });

  group('join', () {
    test('defers join until the socket opens', () async {
      final other = _ChannelHarness();
      addTearDown(() async {
        await other.socket.disposeAsync();
        await other.incoming.close();
      });

      final channel = other.socket.addChannel(topic: 'late-room');
      final join = channel.join();
      expect(channel.state, PhoenixChannelState.errored);

      await other.connect();
      await _waitUntil(() => other.sentOf('phx_join').isNotEmpty);
      other.replyTo(other.sentOf('phx_join').last);
      await join.future;

      expect(channel.state, PhoenixChannelState.joined);
    });

    test('rejects double join in any build mode', () async {
      final channel = await _joinedChannel(harness);
      expect(() => channel.join(), throwsStateError);
    });

    test('surfaces a backend join error', () async {
      final channel = harness.socket.addChannel(topic: 'rejected');
      final join = channel.join();
      await _waitUntil(() => harness.sentOf('phx_join').isNotEmpty);
      harness.replyTo(harness.sentOf('phx_join').last, status: 'error');

      final response = await join.future;
      expect(response.isError, isTrue);
      expect(channel.state, PhoenixChannelState.errored);
    });

    test('join timeout schedules exactly one rejoin', () {
      fakeAsync((async) {
        final fakeHarness = _ChannelHarness();
        fakeHarness.socket.connect().ignore();
        async.flushMicrotasks();

        final channel = fakeHarness.socket.addChannel(topic: 'slow-join');
        channel.join(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fakeHarness.sentOf('phx_join'), hasLength(1));

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(channel.state, PhoenixChannelState.errored);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(fakeHarness.sentOf('phx_join'), hasLength(2));

        async.elapse(const Duration(milliseconds: 500));
        expect(fakeHarness.sentOf('phx_join'), hasLength(2));

        unawaited(fakeHarness.socket.disposeAsync());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
      });
    });
  });

  group('pushes', () {
    test('completes once for a matching reply and ignores duplicates',
        () async {
      final channel = await _joinedChannel(harness);
      var callbacks = 0;
      final push = channel.push('echo', const {});
      push.onReply('ok', (_) => callbacks++);

      await _waitUntil(() => harness.sentOf('echo').isNotEmpty);
      final request = harness.sentOf('echo').last;
      harness.replyTo(request, response: const {'value': 1});

      final response = await push.future;
      expect(response.isOk, isTrue);
      expect(response.response, const {'value': 1});

      harness.replyTo(request, response: const {'value': 2});
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(push.hasReceived('ok'), isTrue);
      expect(callbacks, 1);
    });

    test('a timed out push stays timed out and ignores a late reply', () async {
      final channel = await _joinedChannel(harness);
      final push =
          channel.push('slow', const {}, const Duration(milliseconds: 20));

      await expectLater(
        push.future,
        throwsA(isA<ChannelTimeoutException>()),
      );

      await _waitUntil(() => harness.sentOf('slow').isNotEmpty);
      harness.replyTo(harness.sentOf('slow').last);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(push.hasReceived('timeout'), isTrue);
    });

    test('reset fails the previous attempt and resend uses a new ref',
        () async {
      final channel = await _joinedChannel(harness);
      final push = channel.push('echo', const {});
      final previousAttempt = push.future;

      push.reset();
      await expectLater(
        previousAttempt,
        throwsA(isA<PushSupersededException>()),
      );

      unawaited(push.resend(const Duration(seconds: 5)));
      await _waitUntil(() => harness.sentOf('echo').length >= 2);
      harness.replyTo(harness.sentOf('echo').last);

      expect((await push.future).isOk, isTrue);
    });

    test('buffered pushes are flushed after join in order', () async {
      final channel = harness.socket.addChannel(topic: 'buffered');
      final join = channel.join();
      await _waitUntil(() => harness.sentOf('phx_join').isNotEmpty);

      final first = channel.push('first', const {});
      final second = channel.push('second', const {});
      expect(harness.sentOf('first'), isEmpty);

      harness.replyTo(harness.sentOf('phx_join').last);
      await join.future;
      await _waitUntil(
        () =>
            harness.sentOf('first').isNotEmpty &&
            harness.sentOf('second').isNotEmpty,
      );

      final firstIndex = harness.sent.indexWhere((m) => m[3] == 'first');
      final secondIndex = harness.sent.indexWhere((m) => m[3] == 'second');
      expect(firstIndex, lessThan(secondIndex));

      harness.replyTo(harness.sentOf('first').last);
      harness.replyTo(harness.sentOf('second').last);
      await first.future;
      await second.future;
    });
  });

  group('failure paths', () {
    test('channel error completes pending push futures', () async {
      final channel = await _joinedChannel(harness);
      final push = channel.push('pending', const {});
      final expectation = expectLater(push.future, throwsA(anything));

      harness.deliver('room', 'phx_error', const {}, joinRef: channel.joinRef);
      await expectation;

      expect(channel.state, PhoenixChannelState.errored);
      await expectLater(
        harness.socket.waitForReply(push.ref),
        throwsArgumentError,
      );
    });

    test('socket disposal completes pending push futures', () async {
      final channel = await _joinedChannel(harness);
      final push = channel.push('pending', const {});
      final expectation = expectLater(push.future, throwsA(anything));

      await harness.socket.disposeAsync();
      await expectation;
    });

    test('phx_close closes and removes the channel', () async {
      final channel = await _joinedChannel(harness);
      harness.deliver('room', 'phx_close', const {}, joinRef: channel.joinRef);

      await _waitUntil(() => channel.state == PhoenixChannelState.closed);
      expect(harness.socket.channels.containsKey('room'), isFalse);
    });
  });

  group('leave', () {
    test('leaves a joined channel and removes it exactly once', () async {
      final channel = await _joinedChannel(harness);
      final leave = channel.leave();

      await _waitUntil(() => harness.sentOf('phx_leave').isNotEmpty);
      harness.replyTo(harness.sentOf('phx_leave').last);
      await leave.future;

      await _waitUntil(() => channel.state == PhoenixChannelState.closed);
      expect(harness.socket.channels.containsKey('room'), isFalse);
      final leaveCount = harness.sentOf('phx_leave').length;

      expect(identical(channel.leave(), leave), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(harness.sentOf('phx_leave'), hasLength(leaveCount));
    });

    test('leave while disconnected closes locally', () async {
      final channel = await _joinedChannel(harness);
      harness.incoming.addError(Exception('disconnected'));

      await _waitUntil(() => !harness.socket.isConnected);
      final leave = channel.leave();
      await leave.future;

      expect(channel.state, PhoenixChannelState.closed);
      expect(harness.socket.channels.containsKey('room'), isFalse);
      expect(harness.sentOf('phx_leave'), isEmpty);
    });

    test('push after leave throws ChannelClosedError', () async {
      final channel = await _joinedChannel(harness);
      harness.incoming.addError(Exception('disconnected'));
      await _waitUntil(() => !harness.socket.isConnected);

      channel.leave();
      await _waitUntil(() => channel.state == PhoenixChannelState.closed);
      expect(
        () => channel.push('late', const {}),
        throwsA(isA<ChannelClosedError>()),
      );
    });
  });

  group('message stream', () {
    test('emits application messages in order', () async {
      final channel = await _joinedChannel(harness);
      expect(identical(channel.messages, channel.messages), isTrue);
      final received = <String>[];
      final subscription = channel.messages.listen(
        (message) => received.add(message.event.value),
      );

      harness.deliver(
        'room',
        'one',
        const {'index': 1},
        joinRef: channel.joinRef,
      );
      harness.deliver(
        'room',
        'two',
        const {'index': 2},
        joinRef: channel.joinRef,
      );

      await _waitUntil(() => received.length == 2);
      expect(received, ['one', 'two']);
      await subscription.cancel();
    });

    test('emits channel replies but filters foreign replies', () async {
      final channel = await _joinedChannel(harness);
      final received = <Message>[];
      final subscription = channel.messages.listen(received.add);

      harness.deliver(
        'room',
        'phx_reply',
        const {'status': 'ok', 'response': <String, dynamic>{}},
        joinRef: 'other-join',
        ref: 'foreign',
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(received, isEmpty);

      final push = channel.push('echo', const {});
      await _waitUntil(() => harness.sentOf('echo').isNotEmpty);
      harness.replyTo(harness.sentOf('echo').last);
      await push.future;

      await _waitUntil(() => received.isNotEmpty);
      expect(received.single.event.isChannelReply, isTrue);
      await subscription.cancel();
    });
  });

  group('deprecated members and parse safety', () {
    test('deprecated wait APIs remain functional', () async {
      final channel = await _joinedChannel(harness);

      // ignore: deprecated_member_use_from_same_package
      final eventWaiter =
          channel.onPushReply(PhoenixChannelEvent.replyFor('dep-ref'));
      harness.deliver(
        'room',
        'phx_reply',
        const {'status': 'ok'},
        joinRef: channel.joinRef,
        ref: 'dep-ref',
      );
      expect((await eventWaiter).ref, 'dep-ref');

      final socketMessage = Message(
        event: PhoenixChannelEvent.custom('direct'),
        ref: 'wait-ref',
      );
      final pending = harness.socket.sendMessage(socketMessage);
      // ignore: deprecated_member_use_from_same_package
      final deprecatedWait = harness.socket.waitForMessage(socketMessage);
      harness.deliver('room', 'direct', const {}, ref: 'wait-ref');

      expect((await deprecatedWait).ref, 'wait-ref');
      expect((await pending).ref, 'wait-ref');
      await expectLater(
        harness.socket.waitForReply('wait-ref'),
        throwsArgumentError,
      );

      final unsent = Push(
        channel,
        event: PhoenixChannelEvent.custom('unsent'),
        payload: () => const {},
      );
      // ignore: deprecated_member_use_from_same_package
      unsent
        ..clearReceivers()
        ..cleanUp();

      final push = channel.push('echo', const {});
      await _waitUntil(() => harness.sentOf('echo').isNotEmpty);
      harness.replyTo(harness.sentOf('echo').last);
      await push.future;
    });

    test('PushResponse tolerates nested and non-string statuses', () {
      final nested = PushResponse.fromMessage(
        Message(
          event: PhoenixChannelEvent.custom('phx_reply'),
          payload: {
            'response': {'status': 'ok'},
          },
        ),
      );
      expect(nested.isOk, isTrue);

      final nonString = PushResponse.fromMessage(
        Message(
          event: PhoenixChannelEvent.custom('phx_reply'),
          payload: {'status': 7},
        ),
      );
      expect(nonString.status, '7');

      final nonMap = PushResponse.fromMessage(
        Message(
          event: PhoenixChannelEvent.custom('phx_reply'),
          payload: 'not-a-map',
        ),
      );
      expect(nonMap.status, isNull);
    });
  });
}
