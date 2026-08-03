import 'dart:convert';
import 'dart:typed_data';

// Use relative imports — importing the barrel file (phoenix_socket.dart) from
// inside lib/src/ creates a circular dependency because the barrel re-exports
// this file. Always use relative paths within lib/src/.
import 'utils/binary_decoder.dart';
import 'events.dart';
import 'message.dart';
import 'utils/map_utils.dart';

typedef DecoderCallback = dynamic Function(String rawData);
typedef EncoderCallback = dynamic Function(Object? data);
typedef PayloadDecoderCallback = dynamic Function(Uint8List payload);
typedef BinaryDecoderCallback = dynamic Function(Uint8List rawData);

/// Serializes and deserializes [Message] instances to and from the wire format.
///
/// Each [PhoenixSocket] owns exactly one [MessageSerializer] instance,
/// resolved from [SerializerRegistry] at socket-creation time.
///
/// All three callbacks can be replaced at runtime via setters or [update].
class MessageSerializer {
  MessageSerializer({
    this.name = 'json',
    this.decoder = jsonDecode,
    this.encoder = jsonEncode,
    this.payloadDecoder,
    this.binaryDecoder,
  });

  /// The codec name this serializer was created from.
  ///
  /// Set by [SerializerRegistry] for logging / introspection. Has no effect
  /// on encoding or decoding behaviour.
  final String name;

  DecoderCallback decoder;
  EncoderCallback encoder;
  PayloadDecoderCallback? payloadDecoder;
  BinaryDecoderCallback? binaryDecoder;

  // ── Atomic update ─────────────────────────────────────────────────────────

  /// Atomically replaces one or more codec callbacks.
  ///
  /// Only non-null arguments are applied, except when [clearPayloadDecoder]
  /// is `true`, which explicitly sets [payloadDecoder] to `null`.
  void update({
    DecoderCallback? decoder,
    EncoderCallback? encoder,
    PayloadDecoderCallback? payloadDecoder,
    BinaryDecoderCallback? binaryDecoder,
    bool clearPayloadDecoder = false,
  }) {
    if (decoder != null) this.decoder = decoder;
    if (encoder != null) this.encoder = encoder;
    if (clearPayloadDecoder) {
      this.payloadDecoder = null;
    } else if (payloadDecoder != null) {
      this.payloadDecoder = payloadDecoder;
    }
    if (binaryDecoder != null) this.binaryDecoder = binaryDecoder;
  }

  // ── copyWith ──────────────────────────────────────────────────────────────

  /// Returns a new [MessageSerializer] with the given overrides applied.
  ///
  /// The receiver is not modified.
  MessageSerializer copyWith({
    String? name,
    DecoderCallback? decoder,
    EncoderCallback? encoder,
    PayloadDecoderCallback? payloadDecoder,
    BinaryDecoderCallback? binaryDecoder,
    bool clearPayloadDecoder = false,
  }) =>
      MessageSerializer(
        name: name ?? this.name,
        decoder: decoder ?? this.decoder,
        encoder: encoder ?? this.encoder,
        payloadDecoder: clearPayloadDecoder
            ? null
            : (payloadDecoder ?? this.payloadDecoder),
        binaryDecoder: binaryDecoder ?? this.binaryDecoder,
      );

  // ── Encode / decode ───────────────────────────────────────────────────────

  /// Encodes [message] for transmission over the WebSocket.
  ///
  /// Messages with a [Uint8List] payload use the binary frame format via
  /// [BinaryDecoder]; all others are encoded via the current [encoder].
  dynamic encode(Message message) {
    if (message.payload is Uint8List) {
      return BinaryDecoder.binaryEncode(message);
    }
    return encoder(message.encode());
  }

  /// Decodes a raw WebSocket frame into a [Message].
  ///
  /// [rawData] must be a [String] (JSON / text path) or a [Uint8List]
  /// (binary path). Any other type throws [ArgumentError].
  ///
  /// This method is optimized for the common case (String messages)
  /// to minimize overhead on the hot path.
  Message decode(dynamic rawData) {
    if (rawData is String) {
      // Fast path: decode JSON string to Message
      final List<dynamic> parts = decoder(rawData) as List<dynamic>;
      return Message(
        joinRef: parts[0] as String?,
        ref: parts[1] as String?,
        topic: parts[2] as String?,
        event: PhoenixChannelEvent.custom(parts[3] as String),
        payload: parts[4],
      );
    }

    if (rawData is Uint8List) {
      if (rawData.length >= 4 &&
          rawData[0] == 0x42 &&
          rawData[1] == 0x54 &&
          rawData[2] == 0x4f &&
          rawData[3] == 0x4e) {
        if (binaryDecoder == null) {
          throw ArgumentError('No binary decoder configured for $name');
        }
        final List<dynamic> parts = binaryDecoder!(rawData) as List<dynamic>;
        return Message(
          joinRef: parts[0] as String?,
          ref: parts[1] as String?,
          topic: parts[2] as String?,
          event: PhoenixChannelEvent.custom(parts[3] as String),
          payload: parts[4],
        );
      }

      final raw = BinaryDecoder.binaryDecode(rawData);
      return Message(
        joinRef: raw['join_ref'] as String?,
        ref: raw['ref'] as String?,
        topic: raw['topic'] as String?,
        event: PhoenixChannelEvent.custom(raw['event'] as String),
        payload: _decodePayload(raw['payload']),
      );
    }

    throw ArgumentError(
      'rawData must be a String or Uint8List, got ${rawData.runtimeType}',
    );
  }

  @override
  String toString() => 'MessageSerializer(name: $name)';

  // ── Private ───────────────────────────────────────────────────────────────

  dynamic _decodePayload(dynamic payload) {
    if (payloadDecoder == null || payload is! Uint8List) return payload;
    final decoded = payloadDecoder!(payload);
    if (decoded is Map) return MapUtils.deepConvertToStringDynamic(decoded);
    if (decoded is Uint8List) return decoded;
    return <String, dynamic>{'data': decoded};
  }
}
