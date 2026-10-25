import 'dart:async';

import 'socket.dart';

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets.
///
/// Unlike [PhoenixSocket], this variant exposes the raw received frames
/// without decoding them into Phoenix messages.
class PhoenixRawSocket extends PhoenixSocket {
  /// Creates an instance of PhoenixRawSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixRawSocket(
    super.endpoint, {
    super.socketOptions,
    super.webSocketChannelFactory,
    super.loggerName,
  }) {
    addTeardown(_receiveStreamController.close);
  }

  final StreamController<Object> _receiveStreamController =
      StreamController.broadcast();

  /// Stream of raw frames received from the WebSocket.
  ///
  /// Text and byte frames are forwarded unchanged. The stream closes when the
  /// socket is disposed.
  Stream<Object> get rawMessages => _receiveStreamController.stream;

  @override
  void onSocketDataCallback(dynamic message) {
    if (message is String || message is List<int>) {
      if (!_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    } else {
      reportFrameError(
        ArgumentError(
          'Received a non-list of integers: ${message.runtimeType}',
        ),
      );
    }
  }
}
