import 'message_serializer.dart';
import 'serializer_registry.dart';

/// Configuration for a [PhoenixSocket].
///
/// ### Specifying a codec
///
/// **By name** (resolved from [SerializerRegistry] — recommended):
/// ```dart
/// PhoenixSocketOptions(codec: 'toon')
/// ```
/// A fresh [MessageSerializer] instance is created for each socket,
/// so mutations on one socket's serializer cannot affect others.
///
/// **Direct serializer** (advanced — you manage the instance):
/// ```dart
/// PhoenixSocketOptions(
///   serializer: MessageSerializer(
///     name: 'custom',
///     encoder: myEncode,
///     decoder: myDecode,
///   ),
/// )
/// ```
///
/// Providing both [codec] and [serializer] is an error.
class PhoenixSocketOptions {
  PhoenixSocketOptions({
    Duration? timeout,
    Duration? heartbeat,
    Duration? heartbeatTimeout,
    this.reconnectDelays = const [
      Duration.zero,
      Duration(milliseconds: 1000),
      Duration(milliseconds: 2000),
      Duration(milliseconds: 4000),
      Duration(milliseconds: 8000),
      Duration(milliseconds: 16000),
      Duration(milliseconds: 32000),
    ],
    this.params,
    this.dynamicParams,
    String? codec,
    MessageSerializer? serializer,
  })  : _timeout = timeout ?? const Duration(seconds: 10),
        _heartbeat = heartbeat ?? const Duration(seconds: 30),
        _heartbeatTimeout = heartbeatTimeout ?? const Duration(seconds: 10),
        _codec = codec,
        _serializer = serializer {
    assert(
      !(params != null && dynamicParams != null),
      "Cannot set both params and dynamicParams",
    );
    assert(
      !(codec != null && serializer != null),
      "Cannot set both codec and serializer — choose one",
    );
  }

  final Duration _timeout;
  final Duration _heartbeat;
  final Duration _heartbeatTimeout;
  final String? _codec;
  final MessageSerializer? _serializer;

  /// Duration after which a connection or push attempt is considered timed out.
  Duration get timeout => _timeout;

  /// Interval between heartbeat round-trips.
  Duration get heartbeat => _heartbeat;

  /// Duration after which a heartbeat with no reply is considered timed out.
  Duration get heartbeatTimeout => _heartbeatTimeout;

  /// Delays between successive reconnection attempts.
  final List<Duration> reconnectDelays;

  /// Static query-string parameters appended to the WebSocket URL.
  final Map<String, String>? params;

  /// Called before each connection attempt to produce fresh query-string
  /// parameters (e.g. rotating auth tokens).
  final Future<Map<String, String>> Function()? dynamicParams;

  /// Resolves a [MessageSerializer] for a new socket connection.
  ///
  /// Resolution order:
  /// 1. If a direct [serializer] was provided, returns it as-is.
  /// 2. If a [codec] name was given, calls [SerializerRegistry.resolve].
  /// 3. Falls back to the built-in `'json'` codec.
  ///
  /// This is called once per [PhoenixSocket] construction — each socket
  /// always gets its own independent serializer instance.
  MessageSerializer resolveSerializer() {
    if (_serializer != null) return _serializer!;
    final name = _codec ?? 'json';
    return SerializerRegistry.instance.resolve(name);
  }

  Future<Map<String, String>> getParams() async {
    final resolved =
        dynamicParams != null ? await dynamicParams!() : params ?? {};
    return {...resolved, 'vsn': '2.0.0'};
  }
}
