import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/logging.dart';
import 'helpers/proxy.dart';

// main() is async so we can await the availability check before any group or
// test is registered. Passing skip: to group() is the only reliable way to
// prevent test *bodies* from running — markTestSkipped() in setUp() marks the
// test but does not stop execution, causing timeouts and false failures.
Future<void> main() async {
  maybeActivateAllLogLevels();

  final availability = await checkToxiproxyAvailability();
  final skipReason = availability.isAvailable
      ? null
      : 'Toxiproxy unavailable on localhost:8474 '
          '(${availability.reason}) — '
          'start Toxiproxy and the Phoenix backend to run these tests.';

  group('PhoenixChannel', () {
    const addr = 'ws://localhost:4004/socket/websocket';

    setUp(() => prepareProxy());
    tearDown(() => destroyProxy());

    test('can join a channel through a socket', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();
      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test(
        'can join a channel through a socket that starts closed then connects',
        () async {
      await haltThenResumeProxy();

      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();
      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test(
        'can join a channel through a socket that disconnects before join '
        'but reconnects', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      await haltProxy();
      final joinFuture = socket.addChannel(topic: 'channel1').join();
      Future<void>.delayed(const Duration(milliseconds: 300))
          .then((_) => resumeProxy());

      joinFuture.onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test(
        'can join a channel through a socket that gets a "peer reset" '
        'before join but reconnects', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();
      addTearDown(socket.close);
      await resetPeer();

      runZonedGuarded(() {
        final joinFuture = socket.addChannel(topic: 'channel1').join();
        joinFuture.onReply('ok', (reply) {
          expect(reply.status, equals('ok'));
          completer.complete();
        });
      }, (error, stack) {});

      Future<void>.delayed(const Duration(milliseconds: 1000))
          .then((_) => resetPeer(enable: false));

      await completer.future;
    });

    test('can join a channel through an unawaited socket', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      socket.connect();
      socket.addChannel(topic: 'channel1').join().onReply('ok', (reply) {
        expect(reply.status, equals('ok'));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test('can join a channel requiring parameters', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(
        topic: 'channel1:hello',
        parameters: {'password': 'deadbeef'},
      );

      await expectLater(channel1.join().future, completes);
      socket.dispose();
    });

    test('can handle channel join failures', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      final channel1 = socket.addChannel(
        topic: 'channel1:hello',
        parameters: {'password': 'deadbee?'},
      );

      channel1.join().onReply('error', (error) {
        expect(error.status, equals('error'));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test('can handle channel crash on join', () async {
      final socket = PhoenixSocket(addr);
      final completer = Completer<void>();

      await socket.connect();

      final channel1 = socket.addChannel(
        topic: 'channel1:hello',
        parameters: {'crash!': '11'},
      );

      channel1.join().onReply('error', (error) {
        expect(error.status, equals('error'));
        expect(error.response, equals({'reason': 'join crashed'}));
        completer.complete();
      });

      await completer.future;
      socket.dispose();
    });

    test('can send messages to channels and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      final reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
      socket.dispose();
    });

    test(
        'can send messages to channels that got transiently '
        'disconnected and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await haltThenResumeProxy();
      await socket.openStream.first;

      final reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
      socket.dispose();
    });

    test(
        'can send messages to channels that got "peer reset" '
        'and receive a reply', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await resetPeerThenResumeProxy();

      final reply = await channel1.push('hello!', {'foo': 'bar'}).future;
      expect(reply.status, equals('ok'));
      expect(reply.response, equals({'name': 'bar'}));
      socket.dispose();
    });

    test(
        'throws when sending messages to channels that got "peer reset" '
        'and that have not recovered yet', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      await channel1.join().future;

      await resetPeer();

      final errorCompleter = Completer<Object>();
      runZonedGuarded(() async {
        try {
          await channel1.push('hello!', {'foo': 'bar'}).future;
        } catch (err) {
          errorCompleter.complete(err);
        }
      }, (error, stack) {});

      final exception = await errorCompleter.future;
      expect(exception, isA<PhoenixException>());
      expect((exception as PhoenixException).socketClosed, isNotNull);
      socket.dispose();
    });

    test(
      'throws when sending messages to channels that got disconnected '
      'and that have not recovered yet',
      () async {
        final socket = PhoenixSocket(addr);

        await socket.connect();

        final channel1 = socket.addChannel(topic: 'channel1');
        await channel1.join().future;

        await haltProxy();

        final errorCompleter = Completer<Object>();
        runZonedGuarded(() async {
          try {
            await channel1.push('hello!', {'foo': 'bar'}).future;
          } catch (err) {
            errorCompleter.complete(err);
          }
        }, (error, stack) {});

        expect(await errorCompleter.future, isA<ChannelClosedError>());
        socket.dispose();
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test('only emits reply messages that are channel replies', () async {
      final socket = PhoenixSocket(addr);

      socket.connect();

      final channel1 = socket.addChannel(topic: 'channel1');
      final channelMessages = <dynamic>[];
      channel1.messages.forEach(channelMessages.add);

      await channel1.join().future;
      await channel1.push('hello!', {'foo': 'bar'}).future;

      expect(channelMessages, hasLength(2));
      socket.dispose();
    });

    test('can receive messages from channels', () async {
      final socket = PhoenixSocket(addr);

      await socket.connect();

      final channel2 = socket.addChannel(topic: 'channel2');
      await channel2.join().future;

      var count = 0;
      await for (final msg in channel2.messages) {
        expect(msg.event.value, equals('ping'));
        expect(msg.payload, equals({}));
        if (++count == 5) break;
      }
      socket.dispose();
    });

    test('can send and receive messages from multiple channels', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.dispose();
        socket2.dispose();
      });

      expect(
        channel1.messages,
        emitsInOrder([
          predicate((dynamic m) => m.payload['from'] == 'socket1', 'from socket1'),
          predicate((dynamic m) => m.payload['from'] == 'socket2', 'from socket2'),
          predicate((dynamic m) => m.payload['from'] == 'socket2', 'from socket2'),
        ]),
      );
      expect(
        channel2.messages,
        emitsInOrder([
          predicate((dynamic m) => m.payload['from'] == 'socket1', 'from socket1'),
          predicate((dynamic m) => m.payload['from'] == 'socket2', 'from socket2'),
          predicate((dynamic m) => m.payload['from'] == 'socket2', 'from socket2'),
        ]),
      );

      channel1.push('ping', {'from': 'socket1'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      channel2.push('ping', {'from': 'socket2'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      channel2.push('ping', {'from': 'socket2'});
    });

    test('closes successfully', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.dispose();
        socket2.dispose();
      });

      channel1.push('ping', {'from': 'socket1'});
      expect(
        channel2.messages,
        emits(predicate((dynamic m) => m.payload['from'] == 'socket1',
            'from socket1')),
      );

      await channel1.leave().future;
      expect(channel1.state, equals(PhoenixChannelState.closed));
      expect(socket1.channels.length, equals(0));
    });

    test('can join another channel after closing a previous one', () async {
      final socket1 = PhoenixSocket(addr);
      await socket1.connect();
      final channel1 = socket1.addChannel(topic: 'channel3');
      await channel1.join().future;

      final socket2 = PhoenixSocket(addr);
      await socket2.connect();
      final channel2 = socket2.addChannel(topic: 'channel3');
      await channel2.join().future;

      addTearDown(() {
        socket1.dispose();
        socket2.dispose();
      });

      channel1.push('ping', {'from': 'socket1'});
      expect(
        channel2.messages,
        emits(predicate((dynamic m) => m.payload['from'] == 'socket1',
            'from socket1')),
      );

      await channel1.leave().future;
      expect(channel1.state, equals(PhoenixChannelState.closed));
      expect(socket1.channels.length, equals(0));

      final channel3 = socket1.addChannel(topic: 'channel3');
      await channel3.join().future;

      channel3.push('ping', {'from': 'socket1'});
      expect(
        channel2.messages,
        emits(predicate((dynamic m) => m.payload['from'] == 'socket1',
            'from socket1')),
      );
    });

    test('pushing message on a closed channel throws exception', () async {
      final socket = PhoenixSocket(addr);
      await socket.connect();
      final channel = socket.addChannel(topic: 'channel3');

      await channel.join().future;
      await channel.leave().future;

      expect(
        () => channel.push('EventName', {}),
        throwsA(isA<ChannelClosedError>()),
      );
      socket.dispose();
    });

    test('timeout on send message will throw', () async {
      final socket = PhoenixSocket(addr);
      await socket.connect();
      final channel = socket.addChannel(topic: 'channel1');
      await channel.join().future;

      final push = channel.push('hello!', {'foo': 'bar'}, Duration.zero);
      expect(push.future, throwsA(isA<ChannelTimeoutException>()));
      socket.dispose();
    });
  }, skip: skipReason); // ← group-level skip: prevents test bodies from running
}
