import 'dart:typed_data';

import '../codec/binary_codec.dart';
import '../message.dart';

/// Legacy facade over [BinaryCodec].
///
/// Kept so existing internal imports keep compiling. New code should use
/// [BinaryCodec] directly.
@Deprecated(
  'Use BinaryCodec from src/codec/binary_codec.dart. This facade will be '
  'removed in a future release.',
)
class BinaryDecoder {
  /// Length of the kind byte.
  static const int headerLength = BinaryCodec.headerLength;

  /// Number of length bytes in the reply header (after the kind byte).
  static const int metaLength = BinaryCodec.metaLength;

  /// Mapping of frame names to wire codes.
  static const Map<String, int> kinds = BinaryCodec.kinds;

  /// Mapping of reply channel events.
  static const Map<String, String> channelEvents = BinaryCodec.channelEvents;

  /// Encodes [message] as a binary push frame.
  @Deprecated(
    'Use BinaryCodec.encode(message, kind: BinaryFrameKind.push) instead.',
  )
  static Uint8List binaryEncode(Message message) => BinaryCodec.encode(message);

  /// Decodes [buffer] into the legacy map representation.
  @Deprecated('Use BinaryCodec.decode(buffer) instead.')
  static Map<String, dynamic> binaryDecode(Uint8List buffer) =>
      _toMap(BinaryCodec.decode(buffer));

  /// Decodes a push frame.
  @Deprecated('Use BinaryCodec.decode(buffer) instead.')
  static Map<String, dynamic> decodePush(Uint8List buffer, ByteData view) =>
      _toMap(BinaryCodec.decode(buffer));

  /// Decodes a reply frame.
  @Deprecated('Use BinaryCodec.decode(buffer) instead.')
  static Map<String, dynamic> decodeReply(Uint8List buffer, ByteData view) =>
      _toMap(BinaryCodec.decode(buffer));

  /// Decodes a broadcast frame.
  @Deprecated('Use BinaryCodec.decode(buffer) instead.')
  static Map<String, dynamic> decodeBroadcast(
          Uint8List buffer, ByteData view) =>
      _toMap(BinaryCodec.decode(buffer));

  static Map<String, dynamic> _toMap(BinaryFrame frame) {
    if (frame.kind == BinaryFrameKind.reply) {
      return {
        'join_ref': frame.joinRef,
        'ref': frame.ref,
        'topic': frame.topic,
        'event': BinaryCodec.replyEvent,
        'payload': {
          'status': frame.event,
          'response': frame.payload,
        },
      };
    }
    return {
      'join_ref': frame.joinRef,
      'ref': frame.ref,
      'topic': frame.topic,
      'event': frame.event,
      'payload': frame.payload,
    };
  }
}
