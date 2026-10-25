import 'dart:async';
import 'dart:convert';

import 'package:mockito/mockito.dart';
import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import '../mocks.dart';

/// Polls [predicate] until it holds, failing the test after [timeout].
///
/// Integration and stream-driven tests should use this instead of fixed
/// sleeps so they stay deterministic on slow CI machines.
Future<void> waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 3),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'Condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A real [PhoenixSocket] and its channels, driven by a fake WebSocket.
///
/// The socket is genuine, so channel routing, join-ref handling and stream
/// filtering behave as in production; only the transport is faked. Outbound
/// frames are recorded in [sent] and inbound frames are injected with
/// [deliver].
class SocketHarness {
  SocketHarness({String address = 'ws://localhost/socket/websocket'}) {
    _stubChannel();
    socket = PhoenixSocket(
      address,
      socketOptions: PhoenixSocketOptions(
        reconnectDelays: const [Duration(hours: 1)],
      ),
      webSocketChannelFactory: (_) => channel,
    );
  }

  final MockWebSocketChannel channel = MockWebSocketChannel();
  final MockWebSocketSink sink = MockWebSocketSink();
  final StreamController<dynamic> incoming =
      StreamController<dynamic>.broadcast();
  final List<List<dynamic>> sent = [];

  late final PhoenixSocket socket;

  /// Wires the fake transport into the mock channel. Called by the constructor.
  void _stubChannel() {
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

  /// Connects the underlying socket.
  Future<void> connect() async {
    await socket.connect();
  }

  /// Adds a channel without joining it.
  PhoenixChannel addChannel(String topic) => socket.addChannel(topic: topic);

  /// Joins [channel] and acknowledges the join as the backend would.
  Future<void> join(PhoenixChannel channel) async {
    final join = channel.join();
    await waitUntil(
      () => sentOf('phx_join').isNotEmpty,
      reason: 'No phx_join frame was sent for ${channel.topic}',
    );
    replyTo(sentOf('phx_join').last);
    await join.future;
  }

  /// Adds and joins a channel in one step.
  Future<PhoenixChannel> joinChannel(String topic) async {
    final channel = addChannel(topic);
    await join(channel);
    return channel;
  }

  /// Outbound frames whose event element matches [event].
  List<List<dynamic>> sentOf(String event) =>
      sent.where((message) => message[3] == event).toList(growable: false);

  /// Replies to an outbound request frame.
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

  /// Injects a Phoenix v2 envelope for [topic] arriving from the backend.
  void deliver(
    String topic,
    String event,
    dynamic payload, {
    String? joinRef,
    String? ref,
  }) {
    incoming.add(jsonEncode([joinRef, ref, topic, event, payload]));
  }

  /// Lets queued stream events run.
  Future<void> pump([int microtasks = 1]) async {
    for (var i = 0; i < microtasks; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Closes the socket and the inbound controller.
  Future<void> dispose() async {
    await socket.disposeAsync();
    await incoming.close();
  }
}
