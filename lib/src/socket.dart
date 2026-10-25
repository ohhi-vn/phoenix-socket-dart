import 'dart:async';
import 'dart:core';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:rxdart/rxdart.dart';
import 'package:web_socket_channel/status.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'channel.dart';
import 'events.dart';
import 'exceptions.dart';
import 'internal/backoff.dart';
import 'internal/heartbeat.dart';
import 'internal/pending_replies.dart';
import 'internal/resource_scope.dart';
import 'message.dart';
import 'message_serializer.dart';
import 'push.dart';
import 'socket_options.dart';

/// State of a [PhoenixSocket].
enum SocketState {
  /// The connection is closed
  closed,

  /// The connection is closing
  closing,

  /// The connection is opening
  connecting,

  /// The connection is established
  connected,

  /// Unknown state
  unknown,
}

/// Main class to use when wishing to establish a persistent connection
/// with a Phoenix backend using WebSockets.
class PhoenixSocket {
  /// Creates an instance of PhoenixSocket
  ///
  /// endpoint is the full url to which you wish to connect
  /// e.g. `ws://localhost:4000/websocket/socket`
  PhoenixSocket(
    /// The URL of the Phoenix server.
    String endpoint, {
    /// The options used when initiating and maintaining the
    /// websocket connection.
    PhoenixSocketOptions? socketOptions,

    /// The factory to use to create the WebSocketChannel.
    WebSocketChannel Function(Uri uri)? webSocketChannelFactory,

    /// Logger name for the socket instance.
    String loggerName = 'phoenix_socket.socket',
  })  : _endpoint = endpoint,
        _socketState = SocketState.unknown,
        _webSocketChannelFactory = webSocketChannelFactory,
        _logger = Logger(loggerName) {
    _options = socketOptions ?? PhoenixSocketOptions();
    _serializer = _options.resolveSerializer();
    _backoff = BackoffPolicy(_options.reconnectDelays);

    _messageStream = _messageController.stream;

    _openStream =
        _stateStreamController.stream.whereType<PhoenixSocketOpenEvent>();

    _closeStream =
        _stateStreamController.stream.whereType<PhoenixSocketCloseEvent>();

    _errorStream =
        _stateStreamController.stream.whereType<PhoenixSocketErrorEvent>();

    _heartbeat = HeartbeatScheduler(
      interval: _options.heartbeat,
      onTick: () => unawaited(_sendHeartbeat()),
    );

    _resources = ResourceScope(onError: _logTeardownError);

    _subscriptions = [
      _receiveStreamController.stream.listen(
        _handleRawFrame,
        onError: _onSocketError,
      ),
      _openStream.listen((_) => _startHeartbeat()),
      _closeStream.listen((_) => _cancelHeartbeat()),
    ];
    for (final subscription in _subscriptions) {
      _resources.add(() => subscription.cancel());
    }

    _resources
      ..add(_cancelHeartbeat)
      ..add(() {
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
      })
      ..add(_closeSinkForTeardown)
      ..add(() {
        _pendingReplies.completeAllWithError(
          PhoenixException(
            socketClosed: PhoenixSocketCloseEvent(reason: 'Socket disposed'),
          ),
        );
      })
      ..add(_closeChannelsForTeardown)
      ..add(_closeTopicControllersForTeardown)
      ..add(() async {
        await _stateStreamController.close();
      })
      ..add(() async {
        await _messageController.close();
      })
      ..add(() async {
        await _receiveStreamController.close();
      });
  }

  /// Logger instance used for logging messages related to this
  /// `PhoenixSocket` instance. The logger name is configurable
  /// via the `loggerName` parameter in the constructor.
  final Logger _logger;
  final PendingReplies _pendingReplies = PendingReplies();
  final Map<String, Stream<Message>> _topicStreams = {};

  final BehaviorSubject<PhoenixSocketEvent> _stateStreamController =
      BehaviorSubject();
  final StreamController<dynamic> _receiveStreamController =
      StreamController.broadcast();
  final StreamController<Message> _messageController =
      StreamController.broadcast();
  final String _endpoint;

  /// O(1) topic routing table backing [streamForTopic].
  final Map<String, StreamController<Message>> _topicControllers = {};

  final WebSocketChannel Function(Uri uri)? _webSocketChannelFactory;

  late Uri _mountPoint;

  late Stream<PhoenixSocketOpenEvent> _openStream;
  late Stream<PhoenixSocketCloseEvent> _closeStream;
  late Stream<PhoenixSocketErrorEvent> _errorStream;
  late Stream<Message> _messageStream;

  late final MessageSerializer _serializer;
  late final BackoffPolicy _backoff;
  late final HeartbeatScheduler _heartbeat;
  late final ResourceScope _resources;

  SocketState _socketState;

  WebSocketChannel? _ws;

  /// Stream of [PhoenixSocketOpenEvent] being produced whenever
  /// the connection is open.
  Stream<PhoenixSocketOpenEvent> get openStream => _openStream;

  /// Stream of [PhoenixSocketCloseEvent] being produced whenever
  /// the connection closes.
  Stream<PhoenixSocketCloseEvent> get closeStream => _closeStream;

  /// Stream of [PhoenixSocketErrorEvent] being produced in
  /// the lifetime of the [PhoenixSocket].
  Stream<PhoenixSocketErrorEvent> get errorStream => _errorStream;

  /// Stream of all [Message] instances received.
  Stream<Message> get messageStream => _messageStream;

  /// The serializer used by this socket.
  MessageSerializer get serializer => _serializer;

  List<StreamSubscription> _subscriptions = [];

  int _ref = 0;
  String? _nextHeartbeatRef;

  /// A property yielding unique message reference ids,
  /// monotonically increasing.
  String get nextRef => '${_ref++}';

  bool _shouldReconnect = true;
  bool _reconnecting = false;
  bool _attemptErrorReported = false;
  Completer<PhoenixSocket?>? _activeConnect;
  Timer? _reconnectTimer;

  /// [Map] of topic names to [PhoenixChannel] instances being
  /// maintained and tracked by the socket.
  Map<String, PhoenixChannel> channels = {};

  late PhoenixSocketOptions _options;

  /// Default duration for a connection timeout.
  Duration get defaultTimeout => _options.timeout;

  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// A stream yielding [Message] instances for a given topic.
  ///
  /// The [PhoenixChannel] for this topic may not be open yet, it'll still
  /// eventually yield messages when the channel is open and it receives
  /// messages.
  Stream<Message> streamForTopic(String topic) {
    final existing = _topicStreams[topic];
    if (existing != null) return existing;

    late final StreamController<Message> controller;
    controller = StreamController<Message>.broadcast(
      onCancel: () {
        final current = _topicControllers.remove(topic);
        _topicStreams.remove(topic);
        if (current != null && !current.isClosed) {
          unawaited(current.close());
        }
      },
    );
    _topicControllers[topic] = controller;
    final stream = controller.stream;
    _topicStreams[topic] = stream;
    return stream;
  }

  /// The string URL of the remote Phoenix server.
  String get endpoint => _endpoint;

  /// The [Uri] containing all the parameters and options for the
  /// remote connection to occur.
  Uri get mountPoint => _mountPoint;

  /// Whether the underlying socket is connected of not.
  bool get isConnected => _ws != null && _socketState == SocketState.connected;

  /// Registers an extra teardown callback owned by this socket.
  ///
  /// Used by specialised subclasses to release resources they own.
  void addTeardown(FutureOr<void> Function() release) =>
      _resources.add(release);

  /// Reports a frame that could not be processed without tearing down the
  /// socket.
  void reportFrameError(Object error, [StackTrace? stackTrace]) {
    if (_disposed) return;
    final trace = stackTrace ?? StackTrace.current;
    _logger.warning(() => 'Failed to process a frame: $error');
    _emit(PhoenixSocketErrorEvent(error: error, stacktrace: trace));
  }

  Future<void> _connect(Completer<PhoenixSocket?> completer) async {
    if (_disposed) {
      _complete(
        completer,
        error: StateError('PhoenixSocket cannot connect after being disposed.'),
      );
      return;
    }

    if (_ws != null &&
        (_socketState == SocketState.connected ||
            _socketState == SocketState.connecting)) {
      _logger.warning(
          'Calling connect() on already connected or connecting socket.');
      _complete(completer, value: this);
      return;
    }

    _shouldReconnect = true;
    _attemptErrorReported = false;
    _socketState = SocketState.connecting;

    try {
      _mountPoint = await _buildMountPoint(_endpoint, _options);
      if (_disposed) {
        _complete(completer, value: null);
        return;
      }
      _logger.finest(() => 'Attempting to connect to $_mountPoint');

      final ws = _webSocketChannelFactory != null
          ? _webSocketChannelFactory!(_mountPoint)
          : WebSocketChannel.connect(_mountPoint);
      _ws = ws;

      final subscription = ws.stream.where(_shouldPipeMessage).listen(
          _onSocketData,
          onError: _onSocketError,
          onDone: _onSocketClosed,
          cancelOnError: true);
      _resources.add(() => subscription.cancel());

      // Wait for the WebSocket to be ready before continuing. In case of a
      // failure to connect, the future will complete with an error and will be
      // caught below.
      await ws.ready.timeout(_options.timeout);

      if (_disposed) {
        _complete(completer, value: null);
        return;
      }

      _socketState = SocketState.connected;

      _logger.finest('Waiting for initial heartbeat roundtrip');
      if (await _sendHeartbeat(ignorePreviousHeartbeat: true)) {
        _backoff.reset();
        _emit(PhoenixSocketOpenEvent());
        _logger.info('Socket open');
        _complete(completer, value: this);
      } else {
        throw PhoenixException();
      }
    } on TimeoutException catch (error, stackTrace) {
      _logger.severe(
          'Timed out waiting for WebSocket to be ready', error, stackTrace);
      await _handleConnectFailure(completer, error, stackTrace);
    } catch (error, stackTrace) {
      _logger.severe('Raised Exception', error, stackTrace);
      await _handleConnectFailure(completer, error, stackTrace);
    }
  }

  Future<void> _handleConnectFailure(
    Completer<PhoenixSocket?> completer,
    Object error,
    StackTrace stackTrace,
  ) async {
    _closeSink();
    _ws = null;
    _socketState = SocketState.closed;
    if (!_attemptErrorReported) {
      _attemptErrorReported = true;
      final socketError = PhoenixSocketErrorEvent(
        error: error,
        stacktrace: stackTrace,
      );
      _emit(socketError);
      _triggerChannelExceptions(PhoenixException(socketError: socketError));
    }
    _pendingReplies.completeAllWithError(error, stackTrace);

    if (_disposed) {
      _complete(completer, value: null);
      return;
    }
    _complete(completer, value: await _delayedReconnect());
  }

  /// Attempts to make a WebSocket connection to the Phoenix backend.
  ///
  /// If the attempt fails, retries will be triggered at intervals specified
  /// by the configured reconnect delays.
  ///
  /// The returned future always completes: with a connected socket, with the
  /// outcome of a reconnection, or with an error when the socket is disposed.
  Future<PhoenixSocket?> connect() {
    if (_disposed) {
      return Future<PhoenixSocket?>.error(
        StateError('PhoenixSocket cannot connect after being disposed.'),
      );
    }
    final existing = _activeConnect;
    if (existing != null) {
      return existing.future;
    }
    final completer = Completer<PhoenixSocket?>();
    _activeConnect = completer;
    unawaited(completer.future.then<void>(
      (_) => _clearActiveConnect(completer),
      onError: (Object _) => _clearActiveConnect(completer),
    ));
    unawaited(_connect(completer));
    return completer.future;
  }

  /// Close the underlying connection supporting the socket.
  void close([
    int? code,
    String? reason,
    reconnect = false,
  ]) {
    _shouldReconnect = reconnect;
    if (isConnected) {
      _socketState = SocketState.closing;
      _closeSink(code, reason);
    } else if (!reconnect) {
      unawaited(disposeAsync());
    } else {
      _scheduleReconnect();
    }
  }

  /// Dispose of the socket.
  ///
  /// Don't forget to call this at the end of the lifetime of a socket.
  ///
  /// This synchronous entry point delegates to [disposeAsync]; prefer awaiting
  /// [disposeAsync] when the caller needs to know that teardown finished.
  void dispose() {
    unawaited(disposeAsync());
  }

  /// Disposes the socket and completes once all owned resources are released.
  ///
  /// Idempotent: repeated calls return the same future.
  Future<void> disposeAsync() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    _shouldReconnect = false;
    final active = _activeConnect;
    _activeConnect = null;
    if (active != null && !active.isCompleted) {
      active.complete(null);
    }
    final future = _disposeWithGrace();
    _disposeFuture = future;
    return future;
  }

  /// Lets already-scheduled zero-duration timers (for example a push timeout)
  /// settle before resources are torn down, so a terminal timeout wins over
  /// the disposal error.
  Future<void> _disposeWithGrace() async {
    await Future<void>.delayed(Duration.zero);
    await _resources.close();
  }

  /// Wait for an expected message to arrive.
  ///
  /// Used internally when expecting a message like a heartbeat
  /// reply, a join reply, etc. If you need to wait for the
  /// reply of message you sent on a channel, you would usually
  /// use wait the returned [Push.future].
  @Deprecated(
    'Use waitForReply(ref) instead. This member will be removed in a future '
    'release.',
  )
  Future<Message> waitForMessage(Message message) {
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'needs to contain a ref in order to be awaited for',
      );
    }
    return waitForReply(message.ref!);
  }

  /// Waits for the reply to the message identified by [ref].
  ///
  /// The future completes when a message with that reference arrives, or
  /// fails when the socket closes before a reply.
  Future<Message> waitForReply(String ref) {
    final future = _pendingReplies.futureFor(ref);
    if (future == null) {
      return Future.error(
        ArgumentError(
          "Message with ref $ref hasn't been sent using this socket.",
        ),
      );
    }
    return future.then((value) => value as Message);
  }

  /// Send a channel on the socket.
  ///
  /// Used internall to send prepared message. If you need to send
  /// a message on a channel, you would usually use [PhoenixChannel.push]
  /// instead.
  Future<Message> sendMessage(Message message) {
    if (message.ref == null) {
      throw ArgumentError.value(
        message,
        'message',
        'does not contain a ref',
      );
    }
    if (_disposed || _ws?.sink == null) {
      return Future.error(PhoenixException(
        socketClosed: PhoenixSocketCloseEvent(),
      ));
    }

    final completer = _pendingReplies.register(message.ref!, owner: 'socket');
    try {
      _addToSink(_serializer.encode(message));
    } catch (error, stackTrace) {
      _pendingReplies.remove(message.ref!);
      return Future.error(error, stackTrace);
    }
    return completer.future.then((value) => value as Message);
  }

  /// Fails a pending reply registered for [ref].
  ///
  /// Used by channels when an attempt can no longer receive a reply.
  void failPendingReply(String ref, Object error, [StackTrace? stackTrace]) {
    _pendingReplies.completeError(ref, error, stackTrace);
  }

  void _addToSink(dynamic data) {
    if (_disposed) {
      return;
    }
    _ws!.sink.add(data);
  }

  void _closeSink([int? code, String? reason]) {
    if (_disposed || _ws == null) {
      return;
    }
    try {
      unawaited(_ws!.sink.close(code, reason).catchError((Object _) {}));
    } catch (error, stackTrace) {
      _logger.finest(() => 'Closing the sink failed: $error');
      _logger.finest(() => '$stackTrace');
    }
  }

  Future<void> _closeSinkForTeardown() async {
    final ws = _ws;
    _ws = null;
    if (ws == null) return;
    try {
      await ws.sink.close().timeout(const Duration(seconds: 1));
    } catch (error, stackTrace) {
      _logTeardownError(error, stackTrace);
    }
  }

  /// [topic] is the name of the channel you wish to join
  /// [parameters] are any options parameters you wish to send
  PhoenixChannel addChannel({
    required String topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  }) {
    if (_disposed) {
      throw StateError('Cannot add a channel to a disposed PhoenixSocket.');
    }
    PhoenixChannel? channel = channels[topic];

    if (channel == null) {
      channel = PhoenixChannel.fromSocket(
        this,
        topic: topic,
        parameters: parameters,
        timeout: timeout ?? defaultTimeout,
      );

      channels[channel.topic] = channel;
      _logger.finer(() => 'Adding channel ${channel!.topic}');
    } else {
      _logger.finer(() => 'Reusing existing channel ${channel!.topic}');
    }
    return channel;
  }

  /// Stop managing and tracking a channel on this phoenix
  /// socket.
  ///
  /// Used internally by PhoenixChannel to remove itself after
  /// leaving the channel.
  void removeChannel(PhoenixChannel channel) {
    _logger.finer(() => 'Removing channel ${channel.topic}');
    channels.remove(channel.topic);
    _topicStreams.remove(channel.topic);
    final controller = _topicControllers.remove(channel.topic);
    if (controller != null && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  /// Processing incoming data from the socket
  ///
  /// Used to define a custom message type for proper data decoding.
  void onSocketDataCallback(dynamic message) {
    if (message is String || message is Uint8List) {
      if (!_receiveStreamController.isClosed) {
        _receiveStreamController.add(message);
      }
    } else {
      reportFrameError(ArgumentError('Received an unsupported frame type: '
          '${message.runtimeType}'));
    }
  }

  bool _shouldPipeMessage(dynamic event) {
    if (event is WebSocketChannelException) {
      return true;
    } else if (_socketState != SocketState.closed) {
      return true;
    } else {
      _logger.warning(
        'Message from socket dropped because PhoenixSocket is closed',
        '  $event',
      );
      return false;
    }
  }

  static Future<Uri> _buildMountPoint(
      String endpoint, PhoenixSocketOptions options) async {
    final decodedUri = Uri.parse(endpoint);
    final params = await options.getParams();
    final queryParams = decodedUri.queryParameters.entries.toList()
      ..addAll(params.entries.toList());
    return decodedUri.replace(
      queryParameters: Map.fromEntries(queryParams),
    );
  }

  void _startHeartbeat() {
    if (_disposed) return;
    _backoff.reset();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnecting = false;
    _heartbeat.start();
  }

  void _cancelHeartbeat() {
    _heartbeat.stop();
    _nextHeartbeatRef = null;
  }

  Future<bool> _sendHeartbeat({bool ignorePreviousHeartbeat = false}) async {
    if (!isConnected || _disposed) return false;

    if (_nextHeartbeatRef != null && !ignorePreviousHeartbeat) {
      _nextHeartbeatRef = null;
      _closeSink(normalClosure, 'heartbeat timeout');
      return false;
    }

    final message = _heartbeatMessage();
    final ref = message.ref!;
    try {
      await sendMessage(message).timeout(_options.heartbeatTimeout);
      _logger.fine('[phoenix_socket] Heartbeat completed');
      return true;
    } on TimeoutException catch (error, stackTrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message timed out',
        error,
        stackTrace,
      );
      _closeSink(normalClosure, 'heartbeat timeout');
      return false;
    } on WebSocketChannelException catch (error, stackTrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed: WebSocketChannelException',
        error,
        stackTrace,
      );
      _triggerChannelExceptions(PhoenixException(
        socketError: PhoenixSocketErrorEvent(
          error: error,
          stacktrace: stackTrace,
        ),
      ));
      return false;
    } catch (error, stackTrace) {
      _logger.severe(
        '[phoenix_socket] Heartbeat message failed',
        error,
        stackTrace,
      );
      return false;
    } finally {
      if (_nextHeartbeatRef == ref) {
        _nextHeartbeatRef = null;
      }
      _pendingReplies.discard(ref);
    }
  }

  void _triggerChannelExceptions(PhoenixException exception) {
    _logger.fine(
      () => 'Trigger channel exceptions on ${channels.length} channels',
    );
    for (final channel in channels.values) {
      _logger.finer(
        () => 'Trigger channel exceptions on ${channel.topic}',
      );
      channel.triggerError(exception);
    }
  }

  Message _heartbeatMessage() => Message.heartbeat(_nextHeartbeatRef = nextRef);

  void _handleRawFrame(dynamic frame) {
    final Message message;
    try {
      message = _serializer.decode(frame);
    } catch (error, stackTrace) {
      reportFrameError(error, stackTrace);
      return;
    }
    _onMessage(message);
    if (!_messageController.isClosed) {
      _messageController.add(message);
    }
  }

  void _onMessage(Message message) {
    final ref = message.ref;
    if (ref != null) {
      if (_nextHeartbeatRef == ref) {
        _nextHeartbeatRef = null;
      }
      _pendingReplies.complete(ref, message);
    }

    final topic = message.topic;
    if (topic == null || topic.isEmpty) return;

    final channel = channels[topic];
    if (channel != null) {
      channel.trigger(message);
    }

    final controller = _topicControllers[topic];
    if (controller != null && !controller.isClosed) {
      controller.add(message);
    }
  }

  void _onSocketData(dynamic message) {
    try {
      onSocketDataCallback(message);
    } catch (error, stackTrace) {
      reportFrameError(error, stackTrace);
    }
  }

  void _onSocketError(dynamic error, dynamic stacktrace) {
    if (_disposed) return;
    final trace = stacktrace is StackTrace ? stacktrace : StackTrace.current;
    final socketError = PhoenixSocketErrorEvent(
      error: error,
      stacktrace: trace,
    );

    _attemptErrorReported = true;
    _emit(socketError);
    _logger.severe('Error on socket', error, trace);
    _pendingReplies.completeAllWithError(error, trace);
    _triggerChannelExceptions(PhoenixException(socketError: socketError));
    _onSocketClosed();
  }

  void _onSocketClosed() {
    if (_disposed || _socketState == SocketState.closed) return;

    final wasClosing = _socketState == SocketState.closing;
    final wasConnecting = _socketState == SocketState.connecting;

    final ev = PhoenixSocketCloseEvent(
      reason: _ws?.closeReason ?? 'WebSocket could not establish a connection',
      code: _ws?.closeCode,
    );
    final exc = PhoenixException(socketClosed: ev);

    _cancelHeartbeat();
    _closeSink();
    _ws = null;
    _socketState = SocketState.closed;
    _emit(ev);

    _pendingReplies.completeAllWithError(exc);
    _triggerChannelExceptions(exc);

    if (wasClosing) {
      if (!_shouldReconnect) {
        unawaited(disposeAsync());
      } else {
        _scheduleReconnect();
      }
      return;
    }

    // While connecting, the attempt owner (`_connect`) decides whether to
    // retry, which keeps failures from scheduling two reconnects.
    if (wasConnecting) return;

    _logger.info(
      () => 'Socket closed with reason ${ev.reason} and code ${ev.code}',
    );
    if (_shouldReconnect) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed || !_shouldReconnect || _reconnectTimer != null) return;
    final delay = _backoff.next();
    _logger.finest(() => 'Scheduling reconnect in $delay');
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || !_shouldReconnect) return;
      unawaited(connect().then<void>((_) {}, onError: (Object _) {}));
    });
  }

  Future<PhoenixSocket?> _delayedReconnect() async {
    if (_disposed) return null;
    if (_reconnecting) return null;

    _reconnecting = true;
    final delay = _backoff.next();
    try {
      await Future<void>.delayed(delay);
    } finally {
      _reconnecting = false;
    }

    if (_disposed) return null;
    return _connectOnce();
  }

  Future<PhoenixSocket?> _connectOnce() {
    final completer = Completer<PhoenixSocket?>();
    unawaited(_connect(completer));
    return completer.future;
  }

  void _clearActiveConnect(Completer<PhoenixSocket?> completer) {
    if (identical(_activeConnect, completer)) {
      _activeConnect = null;
    }
  }

  void _complete(
    Completer<PhoenixSocket?> completer, {
    PhoenixSocket? value,
    Object? error,
  }) {
    if (completer.isCompleted) return;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(value);
    }
  }

  void _emit(PhoenixSocketEvent event) {
    if (_disposed || _stateStreamController.isClosed) return;
    _stateStreamController.add(event);
  }

  void _logTeardownError(Object error, StackTrace stackTrace) {
    _logger.warning(() => 'Resource teardown failed: $error');
    _logger.fine(() => '$stackTrace');
  }

  void _closeChannelsForTeardown() {
    final disposedChannels = channels.values.toList(growable: false);
    channels.clear();
    for (final channel in disposedChannels) {
      channel.leavePush?.trigger(PushResponse(status: 'ok'));
      channel.close();
    }
  }

  Future<void> _closeTopicControllersForTeardown() async {
    final controllers = _topicControllers.values.toList(growable: false);
    _topicControllers.clear();
    _topicStreams.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }
}
