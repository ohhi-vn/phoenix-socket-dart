import 'message_serializer.dart';

/// A factory function that produces a fresh [MessageSerializer] instance.
///
/// A factory (rather than a shared instance) is used so that each
/// [PhoenixSocket] gets its own serializer — mutations on one socket's
/// serializer cannot affect any other socket.
typedef SerializerFactory = MessageSerializer Function();

/// Global registry mapping codec names to [MessageSerializer] factories.
///
/// Two codecs are pre-registered at startup:
///   - `'json'`  — the default `dart:convert` JSON codec
///   - `'binary'`— JSON encoding with raw [Uint8List] payload pass-through
///
/// Register additional codecs (e.g. MessagePack, TOON) before creating sockets:
///
/// ```dart
/// SerializerRegistry.instance.register(
///   'toon',
///   () => MessageSerializer(
///     encoder: ToonCodec.encode,
///     decoder: ToonCodec.decode,
///     payloadDecoder: ToonCodec.decodePayload,
///   ),
/// );
/// ```
///
/// Then pass the name to [PhoenixSocketOptions]:
///
/// ```dart
/// final socket = PhoenixSocket(
///   'wss://api.example.com/socket/websocket',
///   socketOptions: PhoenixSocketOptions(codec: 'toon'),
/// );
/// ```
class SerializerRegistry {
  SerializerRegistry._() {
    _factories['json'] = () => MessageSerializer(name: 'json');
    _factories['binary'] = () => MessageSerializer(name: 'binary');
  }

  /// The shared singleton instance.
  static final SerializerRegistry instance = SerializerRegistry._();

  final Map<String, SerializerFactory> _factories = {};

  // ── Registration ──────────────────────────────────────────────────────────

  /// Registers a [factory] under [name], replacing any existing entry.
  ///
  /// The factory is called once per [PhoenixSocket] creation, so each socket
  /// gets an independent [MessageSerializer] instance.
  ///
  /// Throws [ArgumentError] if [name] is blank.
  void register(String name, SerializerFactory factory) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'Codec name cannot be blank');
    }
    _factories[name] = factory;
  }

  /// Removes the registration for [name].
  ///
  /// Throws [StateError] if you attempt to unregister the built-in
  /// `'json'` codec — it must always be available as a fallback.
  void unregister(String name) {
    if (name == 'json') {
      throw StateError("Cannot unregister the built-in 'json' codec.");
    }
    _factories.remove(name);
  }

  // ── Resolution ────────────────────────────────────────────────────────────

  /// Calls the factory registered under [name] and returns a new instance.
  ///
  /// Throws [ArgumentError] if no codec with that name has been registered.
  MessageSerializer resolve(String name) {
    final factory = _factories[name];
    if (factory == null) {
      throw ArgumentError(
        'No codec registered for "$name". '
        'Registered codecs: ${registeredNames.join(', ')}',
      );
    }
    return factory();
  }

  /// Returns `true` if a codec with [name] has been registered.
  bool has(String name) => _factories.containsKey(name);

  /// The names of all currently registered codecs.
  Set<String> get registeredNames => Set<String>.unmodifiable(_factories.keys);
}
