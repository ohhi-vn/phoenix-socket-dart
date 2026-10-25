import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/proxy.dart';

Future<void> main() async {
  const addr = 'ws://localhost:4001/socket/websocket';

  final availability = await checkPhoenixServerAvailability(addr);
  final skipReason = availability.isAvailable
      ? null
      : 'Phoenix server unavailable on localhost:4001 '
          '(${availability.reason}) — '
          'start the backend to run these tests.';

  // ── Tests that require a live Phoenix server ────────────────────────────────
  group('PhoenixSocket', () {
    test('can connect to a running Phoenix server', () async {
      final socket = PhoenixSocket(addr);
      await socket.connect();
      expect(socket.isConnected, isTrue);
      socket.dispose();
    });

    test('can connect to a running Phoenix server with params', () async {
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: const {'user_id': 'this_is_a_userid'},
        ),
      );
      await socket.connect();
      expect(socket.isConnected, isTrue);
      socket.dispose();
    });

    test('emits an "open" event', () async {
      final socket = PhoenixSocket(addr);
      unawaited(socket.connect());
      await for (final event in socket.openStream) {
        expect(event, isA<PhoenixSocketOpenEvent>());
        socket.close();
        break;
      }
    });

    test('emits a "close" event after the connection was closed', () async {
      final completer = Completer<void>();
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: const {'user_id': 'this_is_a_userid'},
        ),
      );
      await socket.connect();
      Timer(const Duration(milliseconds: 100), socket.close);
      socket.closeStream.listen((event) {
        expect(event, isA<PhoenixSocketCloseEvent>());
        completer.complete();
      });
      await completer.future;
    });

    test('reconnects automatically after a socket close', () async {
      final socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(
          params: const {'user_id': 'this_is_a_userid'},
        ),
      );
      await socket.connect();
      addTearDown(socket.dispose);

      var i = 0;
      socket.openStream.listen((event) async {
        if (i++ < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          socket.close(null, null, true);
        }
      });

      expect(
        socket.openStream,
        emitsInOrder([
          isA<PhoenixSocketOpenEvent>(),
          isA<PhoenixSocketOpenEvent>(),
          isA<PhoenixSocketOpenEvent>(),
        ]),
      );
    });
  }, skip: skipReason);

  // ── Tests that do NOT require a live server (never skip) ───────────────────
  //
  // These tests intentionally connect to unreachable or invalid addresses and
  // assert on the failure behaviour. They must never be inside the skipped
  // group above, otherwise they are wrongly omitted when the server is down.
  group('PhoenixSocket (no server required)', () {
    test('throws an error when connecting to an invalid address', () async {
      final socket = PhoenixSocket('https://example.com/random-addr');
      unawaited(socket.connect());
      expect(await socket.errorStream.first, isA<PhoenixSocketErrorEvent>());
      socket.dispose();
    });

    test('reconnection delay', () async {
      final socket = PhoenixSocket(
        'ws://example.com/random-addr',
        socketOptions: PhoenixSocketOptions(
          reconnectDelays: const [
            Duration.zero,
            Duration.zero,
            Duration.zero,
            Duration(seconds: 10),
          ],
        ),
      );
      addTearDown(socket.dispose);

      var errCount = 0;
      socket.errorStream.listen((_) => errCount++);

      runZonedGuarded(() => socket.connect().ignore(), (e, s) {});

      // Drive the test on events rather than elapsed time.
      // Each Duration.zero delay still has up to 999ms of random jitter
      // (see PhoenixSocket._reconnectDelay), so a fixed 3-second wait is
      // a race. take(3) waits for exactly 3 errors however long they take.
      // The generous 6-second timeout guards against the test hanging if
      // the socket never errors at all.
      await socket.errorStream.take(3).last.timeout(const Duration(seconds: 6));

      // Briefly confirm the 4th reconnect (10-second delay) has not fired.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(errCount, 3);
    });
  });
}
