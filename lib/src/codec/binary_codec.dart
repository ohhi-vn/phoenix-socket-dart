import 'dart:convert';
import 'dart:typed_data';

import '../message.dart';
import 'message_decode_exception.dart';

/// The kind of a binary Phoenix frame.
enum BinaryFrameKind {
  /// A push sent by a client (no reference field).
  push(0),

  /// A reply to a push; the event field carries the status (`ok`/`error`).
  reply(1),

  /// A broadcast from the server.
  broadcast(2);

  const BinaryFrameKind(this.code);

  /// The single-byte kind written at the start of the frame.
  final int code;

  /// Resolves a kind from its wire code, or `null` when unknown.
  static BinaryFrameKind? fromCode(int code) => switch (code) {
        0 => push,
        1 => reply,
        2 => broadcast,
        _ => null,
      };
}

/// A decoded binary frame, before it is turned into a [Message].
class BinaryFrame {
  /// Creates a decoded frame.
  const BinaryFrame({
    required this.kind,
    required this.joinRef,
    required this.ref,
    required this.topic,
    required this.event,
    required this.payload,
  });

  /// The frame kind.
  final BinaryFrameKind kind;

  /// The join reference, or `null` when the kind does not carry one.
  final String? joinRef;

  /// The push reference, or `null` when the kind does not carry one.
  final String? ref;

  /// The topic the frame belongs to.
  final String topic;

  /// The event name, or the reply status for [BinaryFrameKind.reply].
  final String event;

  /// The remaining bytes of the frame, as a view into the source buffer.
  final Uint8List payload;

  @override
  String toString() => 'BinaryFrame(kind: $kind, joinRef: $joinRef, ref: $ref, '
      'topic: $topic, event: $event, payloadLength: ${payload.length})';
}

/// Encodes and decodes the binary Phoenix frame format.
///
/// Layouts (lengths are single bytes):
/// - push:      `kind, joinRefLen, topicLen, eventLen, joinRef, topic, event, payload`
/// - reply:     `kind, joinRefLen, refLen, topicLen, eventLen, joinRef, ref, topic, status, payload`
/// - broadcast: `kind, topicLen, eventLen, topic, event, payload`
///
/// Decoding reads relative to the supplied [Uint8List]'s own view, so a frame
/// extracted from a larger buffer decodes identically to a standalone buffer.
class BinaryCodec {
  const BinaryCodec._();

  /// Length of the kind byte.
  static const int headerLength = 1;

  /// Number of length bytes in the reply header (after the kind byte).
  static const int metaLength = 4;

  /// The event name used for decoded replies.
  static const String replyEvent = 'phx_reply';

  /// Mapping of frame names to wire codes.
  static const Map<String, int> kinds = {
    'push': 0,
    'reply': 1,
    'broadcast': 2,
  };

  /// Mapping of reply channel events.
  static const Map<String, String> channelEvents = {
    'reply': replyEvent,
  };

  static final Uint8List _empty = Uint8List(0);

  /// Encodes [message] as a binary frame of [kind].
  ///
  /// The message payload must be a [Uint8List]. Every textual field is
  /// validated against the single-byte length limit before any bytes are
  /// written.
  ///
  /// Throws [ArgumentError] for a non-byte payload or an oversized field.
  static Uint8List encode(
    Message message, {
    BinaryFrameKind kind = BinaryFrameKind.push,
  }) {
    final payload = message.payload;
    if (payload is! Uint8List) {
      throw ArgumentError(
        'Message payload must be Uint8List for binary encoding',
      );
    }

    final joinRef = _fieldBytes(
      kind == BinaryFrameKind.broadcast ? null : message.joinRef,
      'joinRef',
    );
    final ref =
        kind == BinaryFrameKind.reply ? _fieldBytes(message.ref, 'ref') : null;
    final topic = _fieldBytes(message.topic ?? '', 'topic');
    final event = _fieldBytes(message.event.value, 'event');

    final headerSize = switch (kind) {
      BinaryFrameKind.push => headerLength + 3,
      BinaryFrameKind.reply => headerLength + metaLength,
      BinaryFrameKind.broadcast => headerLength + 2,
    };

    final totalLength = headerSize +
        joinRef.length +
        (ref?.length ?? 0) +
        topic.length +
        event.length +
        payload.length;
    final bytes = Uint8List(totalLength);

    var offset = 0;
    bytes[offset++] = kind.code;
    switch (kind) {
      case BinaryFrameKind.push:
        bytes[offset++] = joinRef.length;
        bytes[offset++] = topic.length;
        bytes[offset++] = event.length;
      case BinaryFrameKind.reply:
        bytes[offset++] = joinRef.length;
        bytes[offset++] = ref!.length;
        bytes[offset++] = topic.length;
        bytes[offset++] = event.length;
      case BinaryFrameKind.broadcast:
        bytes[offset++] = topic.length;
        bytes[offset++] = event.length;
    }

    offset = _write(bytes, offset, joinRef);
    if (ref != null) offset = _write(bytes, offset, ref);
    offset = _write(bytes, offset, topic);
    offset = _write(bytes, offset, event);
    bytes.setRange(offset, offset + payload.length, payload);

    return bytes;
  }

  /// Decodes [frame] into a [BinaryFrame].
  ///
  /// Throws [MessageDecodeException] for empty, truncated, malformed, or
  /// unknown-kind frames.
  static BinaryFrame decode(Uint8List frame) {
    if (frame.isEmpty) {
      throw MessageDecodeException(
        'Empty binary frame',
        stage: DecodeStage.binary,
        frameLength: 0,
      );
    }

    final kindCode = frame[0];
    final kind = BinaryFrameKind.fromCode(kindCode);
    if (kind == null) {
      throw MessageDecodeException(
        'Unknown binary message kind: $kindCode',
        stage: DecodeStage.binary,
        kind: kindCode,
        frameLength: frame.length,
      );
    }

    final reader = _FrameReader(frame, kindCode);

    switch (kind) {
      case BinaryFrameKind.push:
        reader.require(3, 'push header');
        final joinRefSize = reader.readUint8('joinRef length');
        final topicSize = reader.readUint8('topic length');
        final eventSize = reader.readUint8('event length');
        final joinRef = reader.readString(joinRefSize, 'joinRef');
        final topic = reader.readString(topicSize, 'topic');
        final event = reader.readString(eventSize, 'event');
        return BinaryFrame(
          kind: kind,
          joinRef: joinRef,
          ref: null,
          topic: topic,
          event: event,
          payload: reader.readRemaining(),
        );
      case BinaryFrameKind.reply:
        reader.require(metaLength, 'reply header');
        final joinRefSize = reader.readUint8('joinRef length');
        final refSize = reader.readUint8('ref length');
        final topicSize = reader.readUint8('topic length');
        final eventSize = reader.readUint8('status length');
        final joinRef = reader.readString(joinRefSize, 'joinRef');
        final ref = reader.readString(refSize, 'ref');
        final topic = reader.readString(topicSize, 'topic');
        final event = reader.readString(eventSize, 'status');
        return BinaryFrame(
          kind: kind,
          joinRef: joinRef,
          ref: ref,
          topic: topic,
          event: event,
          payload: reader.readRemaining(),
        );
      case BinaryFrameKind.broadcast:
        reader.require(2, 'broadcast header');
        final topicSize = reader.readUint8('topic length');
        final eventSize = reader.readUint8('event length');
        final topic = reader.readString(topicSize, 'topic');
        final event = reader.readString(eventSize, 'event');
        return BinaryFrame(
          kind: kind,
          joinRef: null,
          ref: null,
          topic: topic,
          event: event,
          payload: reader.readRemaining(),
        );
    }
  }

  static List<int> _fieldBytes(String? value, String name) {
    if (value == null || value.isEmpty) return _empty;
    final bytes = utf8.encode(value);
    if (bytes.length > 0xFF) {
      throw ArgumentError.value(
        value,
        name,
        'UTF-8 length ${bytes.length} exceeds the single-byte binary '
        'length limit (255)',
      );
    }
    return bytes;
  }

  static int _write(Uint8List target, int offset, List<int> chunk) {
    target.setRange(offset, offset + chunk.length, chunk);
    return offset + chunk.length;
  }
}

/// Sequential reader over a frame view.
///
/// Indices are relative to [Uint8List]'s own view, so `offsetInBytes` of a
/// sublist is handled by the list implementation rather than by this class.
class _FrameReader {
  _FrameReader(this._bytes, this._kind) : _offset = 1;

  final Uint8List _bytes;
  final int _kind;
  int _offset;

  int get _remaining => _bytes.length - _offset;

  void require(int count, String what) {
    if (count < 0 || _remaining < count) {
      throw MessageDecodeException(
        'Truncated binary frame: $what needs $count byte(s) but only '
        '${_remaining < 0 ? 0 : _remaining} remain',
        stage: DecodeStage.binary,
        kind: _kind,
        frameLength: _bytes.length,
      );
    }
  }

  int readUint8(String what) {
    require(1, what);
    return _bytes[_offset++];
  }

  String readString(int length, String field) {
    require(length, field);
    final start = _offset;
    _offset += length;
    try {
      return const Utf8Decoder().convert(_bytes, start, _offset);
    } on FormatException catch (error) {
      throw MessageDecodeException(
        'Invalid UTF-8 in binary frame field "$field"',
        stage: DecodeStage.binary,
        kind: _kind,
        frameLength: _bytes.length,
        source: error,
      );
    }
  }

  Uint8List readRemaining() {
    final view = Uint8List.sublistView(_bytes, _offset, _bytes.length);
    _offset = _bytes.length;
    return view;
  }
}
