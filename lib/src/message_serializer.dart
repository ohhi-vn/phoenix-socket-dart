import 'dart:convert';
import 'dart:typed_data';

// Use relative imports — importing the barrel file (phoenix_socket.dart) from
// inside lib/src/ creates a circular dependency because the barrel re-exports
// this file. Always use relative paths within lib/src/.
import 'codec/binary_codec.dart';
import 'codec/message_decode_exception.dart';
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
  /// [BinaryCodec]; all others are encoded via the current [encoder].
  dynamic encode(Message message) {
    if (message.payload is Uint8List) {
      return BinaryCodec.encode(message);
    }
    return encoder(message.encode());
  }

  /// Decodes a raw WebSocket frame into a [Message].
  ///
  /// [rawData] must be a [String] (JSON / text path) or a [Uint8List]
  /// (binary path). Any other type throws [ArgumentError].
  ///
  /// Malformed text or binary frames throw [MessageDecodeException], a
  /// [FormatException] subtype that identifies the failing stage.
  Message decode(dynamic rawData) {
    if (rawData is String) {
      return _decodeText(rawData);
    }

    if (rawData is Uint8List) {
      if (_hasPayloadEnvelope(rawData)) {
        if (binaryDecoder == null) {
          throw ArgumentError('No binary decoder configured for $name');
        }
        final dynamic decoded;
        try {
          decoded = binaryDecoder!(rawData);
        } on MessageDecodeException {
          rethrow;
        } on FormatException catch (error) {
          throw MessageDecodeException(
            'Failed to decode the payload envelope: ${error.message}',
            stage: DecodeStage.payload,
            frameLength: rawData.length,
            source: error,
          );
        }
        if (decoded is! List) {
          throw MessageDecodeException(
            'Binary decoder must return a Phoenix envelope List, got '
            '${decoded.runtimeType}',
            stage: DecodeStage.payload,
            frameLength: rawData.length,
          );
        }
        return _decodeEnvelope(decoded, DecodeStage.payload);
      }

      return _decodeBinary(rawData);
    }

    throw ArgumentError(
      'rawData must be a String or Uint8List, got ${rawData.runtimeType}',
    );
  }

  @override
  String toString() => 'MessageSerializer(name: $name)';

  // ── Private ───────────────────────────────────────────────────────────────

  Message _decodeText(String rawData) {
    final dynamic decoded;
    try {
      decoded = decoder(rawData);
    } on MessageDecodeException {
      rethrow;
    } on FormatException catch (error) {
      throw MessageDecodeException(
        'Invalid text frame: ${error.message}',
        stage: DecodeStage.text,
        source: error,
      );
    }
    if (decoded is! List) {
      throw MessageDecodeException(
        'Phoenix envelope must be a List, got ${decoded.runtimeType}',
        stage: DecodeStage.text,
        source: rawData,
      );
    }
    return _decodeEnvelope(decoded, DecodeStage.text);
  }

  Message _decodeEnvelope(List<dynamic> parts, DecodeStage stage) {
    try {
      return Message.fromJson(parts);
    } on MessageDecodeException {
      rethrow;
    } on FormatException catch (error) {
      throw MessageDecodeException(
        'Invalid Phoenix envelope: ${error.message}',
        stage: stage,
        source: error,
      );
    }
  }

  Message _decodeBinary(Uint8List rawData) {
    final frame = BinaryCodec.decode(rawData);
    if (frame.kind == BinaryFrameKind.reply) {
      return Message(
        joinRef: frame.joinRef,
        ref: frame.ref,
        topic: frame.topic,
        event: PhoenixChannelEvent.reply,
        payload: {
          'status': frame.event,
          'response': frame.payload,
        },
      );
    }
    return Message(
      joinRef: frame.joinRef,
      ref: frame.ref,
      topic: frame.topic,
      event: PhoenixChannelEvent.custom(frame.event),
      payload: _decodePayload(frame.payload),
    );
  }

  static bool _hasPayloadEnvelope(Uint8List data) =>
      data.length >= 4 &&
      data[0] == 0x42 &&
      data[1] == 0x54 &&
      data[2] == 0x4f &&
      data[3] == 0x4e;

  dynamic _decodePayload(dynamic payload) {
    if (payloadDecoder == null || payload is! Uint8List) return payload;
    final decoded = payloadDecoder!(payload);
    if (decoded is Map) return MapUtils.deepConvertToStringDynamic(decoded);
    if (decoded is Uint8List) return decoded;
    return <String, dynamic>{'data': decoded};
  }
}
