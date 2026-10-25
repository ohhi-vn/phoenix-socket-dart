import 'dart:async';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/proxy.dart';
import 'helpers/socket_harness.dart';

/// Presence scenarios against the example backend's `presence:lobby` channel.
///
/// Only the backend is required (no Toxiproxy). The whole group skips with an
/// actionable reason when the harness is not running.
Future<void> main() async {
  const addr = 'ws://localhost:4001/socket/websocket';

  final availability = await checkPhoenixServerAvailability(addr);
  final skipReason = availability.isAvailable
      ? null
      : 'Phoenix server unavailable on localhost:4001 '
          '(${availability.reason}) — '
          'run tool/integration_test.sh to start the local harness.';

  group('PhoenixPresence (live backend)', () {
    late PhoenixSocket socket;
    late PhoenixChannel channel;
    late PhoenixPresence presence;

    Future<void> joinAs(String userId) async {
      socket = PhoenixSocket(
        addr,
        socketOptions: PhoenixSocketOptions(params: {'user_id': userId}),
      );
      addTearDown(socket.disposeAsync);

      channel = socket.addChannel(topic: 'presence:lobby');
      // Constructed before the join so the initial snapshot is not missed.
      presence = PhoenixPresence(channel: channel);
      addTearDown(presence.dispose);

      await socket.connect();
      await channel.join().future;
    }

    test(
      'receives the initial presence snapshot',
      () async {
        const userId = 'presence-it-snapshot';
        await joinAs(userId);

        await waitUntil(
          () => presence.state.containsKey(userId),
          timeout: const Duration(seconds: 10),
          reason: 'The initial presence snapshot never contained $userId',
        );
        expect(presence.state[userId]!.metas, isNotEmpty);
        expect(presence.inPendingSyncState, isFalse);
      },
      skip: skipReason,
    );

    test(
      'sees a second client join without losing the first',
      () async {
        const firstUser = 'presence-it-join-a';
        const secondUser = 'presence-it-join-b';
        await joinAs(firstUser);
        await waitUntil(
          () => presence.state.containsKey(firstUser),
          timeout: const Duration(seconds: 10),
          reason: 'The first client never saw its own presence',
        );

        final secondSocket = PhoenixSocket(
          addr,
          socketOptions: PhoenixSocketOptions(params: {'user_id': secondUser}),
        );
        addTearDown(secondSocket.disposeAsync);
        await secondSocket.connect();
        final secondChannel = secondSocket.addChannel(topic: 'presence:lobby');
        final secondPresence = PhoenixPresence(channel: secondChannel);
        addTearDown(secondPresence.dispose);
        await secondChannel.join().future;

        await waitUntil(
          () => presence.state.containsKey(secondUser),
          timeout: const Duration(seconds: 10),
          reason: 'The first client never received the join diff for '
              '$secondUser',
        );
        expect(presence.state.containsKey(firstUser), isTrue);
      },
      skip: skipReason,
    );

    test(
      'drops a client that disconnects',
      () async {
        const firstUser = 'presence-it-leave-a';
        const secondUser = 'presence-it-leave-b';
        await joinAs(firstUser);
        await waitUntil(
          () => presence.state.containsKey(firstUser),
          timeout: const Duration(seconds: 10),
          reason: 'The first client never saw its own presence',
        );

        final secondSocket = PhoenixSocket(
          addr,
          socketOptions: PhoenixSocketOptions(params: {'user_id': secondUser}),
        );
        await secondSocket.connect();
        final secondChannel = secondSocket.addChannel(topic: 'presence:lobby');
        final secondPresence = PhoenixPresence(channel: secondChannel);
        await secondChannel.join().future;
        await waitUntil(
          () => presence.state.containsKey(secondUser),
          timeout: const Duration(seconds: 10),
          reason: 'The first client never received the join of $secondUser',
        );

        secondPresence.dispose();
        await secondSocket.disposeAsync();

        await waitUntil(
          () => !presence.state.containsKey(secondUser),
          timeout: const Duration(seconds: 10),
          reason: 'The first client never received the leave of $secondUser',
        );
        expect(presence.state.containsKey(firstUser), isTrue);
      },
      skip: skipReason,
    );
  });
}
