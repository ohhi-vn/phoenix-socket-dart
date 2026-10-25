/// Stage of the wire format that failed to decode.
enum DecodeStage {
  /// Decoding a text (JSON) frame into the Phoenix v2 envelope.
  text,

  /// Decoding a binary frame header or field.
  binary,

  /// Decoding a custom binary payload or envelope.
  payload,
}

/// A typed decoding failure for the wire format.
///
/// Extends [FormatException] so existing callers that catch
/// [FormatException] keep working, while adding the failing stage, the frame
/// kind (for binary frames), and the total frame length.
class MessageDecodeException extends FormatException {
  /// Creates a decoding failure.
  MessageDecodeException(
    String message, {
    required this.stage,
    this.kind,
    this.frameLength,
    dynamic source,
    int? offset,
  }) : super(message, source, offset);

  /// The stage that failed.
  final DecodeStage stage;

  /// The binary frame kind that failed, when applicable.
  final int? kind;

  /// The total length of the frame being decoded, when known.
  final int? frameLength;

  @override
  String toString() {
    final buffer = StringBuffer('MessageDecodeException(${super.message})');
    buffer.write(' [stage: ${stage.name}');
    if (kind != null) buffer.write(', kind: $kind');
    if (frameLength != null) buffer.write(', frameLength: $frameLength');
    buffer.write(']');
    return buffer.toString();
  }
}
