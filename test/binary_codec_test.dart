import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/codec/binary_codec.dart';
import 'package:phoenix_socket/src/codec/message_decode_exception.dart';
import 'package:test/test.dart';

Message _pushMessage({String? joinRef = '0', Uint8List? payload}) => Message(
      joinRef: joinRef,
      topic: 'topic',
      event: PhoenixChannelEvent.custom('some-event'),
      payload: payload ?? Uint8List.fromList([1, 2, 3]),
    );

Matcher _decodeError({
  required DecodeStage stage,
  int? kind,
}) =>
    isA<MessageDecodeException>()
        .having((e) => e.stage, 'stage', stage)
        .having((e) => e.kind, 'kind', kind);

void main() {
  group('BinaryCodec framing', () {
    test('round trips a push frame', () {
      final message = _pushMessage();
      final encoded = BinaryCodec.encode(message);
      final decoded = BinaryCodec.decode(encoded);

      expect(decoded.kind, BinaryFrameKind.push);
      expect(decoded.joinRef, '0');
      expect(decoded.ref, isNull);
      expect(decoded.topic, 'topic');
      expect(decoded.event, 'some-event');
      expect(decoded.payload, [1, 2, 3]);
    });

    test('round trips a reply frame', () {
      final message = Message(
        joinRef: '10',
        ref: '12',
        topic: 'topic',
        event: PhoenixChannelEvent.custom('ok'),
        payload: Uint8List.fromList([4, 5]),
      );
      final encoded = BinaryCodec.encode(message, kind: BinaryFrameKind.reply);
      final decoded = BinaryCodec.decode(encoded);

      expect(decoded.kind, BinaryFrameKind.reply);
      expect(decoded.joinRef, '10');
      expect(decoded.ref, '12');
      expect(decoded.topic, 'topic');
      expect(decoded.event, 'ok');
      expect(decoded.payload, [4, 5]);
    });

    test('round trips a broadcast frame without references', () {
      final message = Message(
        joinRef: 'ignored',
        ref: 'ignored',
        topic: 'topic',
        event: PhoenixChannelEvent.custom('some-event'),
        payload: Uint8List.fromList([9]),
      );
      final encoded =
          BinaryCodec.encode(message, kind: BinaryFrameKind.broadcast);
      final decoded = BinaryCodec.decode(encoded);

      expect(decoded.kind, BinaryFrameKind.broadcast);
      expect(decoded.joinRef, isNull);
      expect(decoded.ref, isNull);
      expect(decoded.topic, 'topic');
      expect(decoded.event, 'some-event');
      expect(decoded.payload, [9]);
    });

    test('decodes a frame supplied as a non-zero-offset view', () {
      final frame = BinaryCodec.encode(_pushMessage());
      final padded = Uint8List(3 + frame.length + 2)
        ..setRange(3, 3 + frame.length, frame);
      final view = Uint8List.sublistView(padded, 3, 3 + frame.length);

      final fromStandalone = BinaryCodec.decode(frame);
      final fromView = BinaryCodec.decode(view);

      expect(fromView.joinRef, fromStandalone.joinRef);
      expect(fromView.topic, fromStandalone.topic);
      expect(fromView.event, fromStandalone.event);
      expect(fromView.payload, fromStandalone.payload);
      // The payload is a view into the original padded buffer, not a copy.
      expect(fromView.payload.buffer.lengthInBytes, padded.lengthInBytes);
      expect(fromView.payload.offsetInBytes, greaterThanOrEqualTo(3));
    });

    test('rejects an empty frame', () {
      expect(
        () => BinaryCodec.decode(Uint8List(0)),
        throwsA(_decodeError(stage: DecodeStage.binary)),
      );
    });

    test('rejects an unknown kind', () {
      expect(
        () => BinaryCodec.decode(Uint8List.fromList([99, 0, 0, 0])),
        throwsA(_decodeError(stage: DecodeStage.binary, kind: 99)),
      );
    });

    test('rejects a truncated push header without RangeError', () {
      expect(
        () => BinaryCodec.decode(Uint8List.fromList([0, 1])),
        throwsA(_decodeError(stage: DecodeStage.binary, kind: 0)),
      );
    });

    test('rejects a truncated reply header without RangeError', () {
      expect(
        () => BinaryCodec.decode(Uint8List.fromList([1, 1, 1])),
        throwsA(_decodeError(stage: DecodeStage.binary, kind: 1)),
      );
    });

    test('rejects a topic longer than the remaining bytes', () {
      final frame = Uint8List.fromList([
        0, // push
        1, // joinRef length
        9, // topic length, larger than the frame
        1, // event length
        ...'a'.codeUnits,
      ]);
      expect(
        () => BinaryCodec.decode(frame),
        throwsA(_decodeError(stage: DecodeStage.binary, kind: 0)),
      );
    });

    test('rejects a field larger than 255 bytes when encoding', () {
      final message = Message(
        topic: 't' * 256,
        event: PhoenixChannelEvent.custom('e'),
        payload: Uint8List.fromList([1]),
      );
      expect(
        () => BinaryCodec.encode(message),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a non-byte payload when encoding', () {
      final message = Message(
        topic: 't',
        event: PhoenixChannelEvent.custom('e'),
        payload: {'not': 'bytes'},
      );
      expect(
        () => BinaryCodec.encode(message),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('MessageSerializer decode failures', () {
    late MessageSerializer serializer;

    setUp(() => serializer = MessageSerializer());

    test('wraps invalid JSON in a text-stage decode error', () {
      expect(
        () => serializer.decode('not json'),
        throwsA(_decodeError(stage: DecodeStage.text)),
      );
    });

    test('wraps a wrong envelope shape in a text-stage decode error', () {
      expect(
        () => serializer.decode('["only-one"]'),
        throwsA(_decodeError(stage: DecodeStage.text)),
      );
    });

    test('reports binary framing failures with the binary stage', () {
      expect(
        () => serializer.decode(Uint8List.fromList([7, 1])),
        throwsA(_decodeError(stage: DecodeStage.binary, kind: 7)),
      );
    });

    test('requires a binary decoder for the payload envelope', () {
      final serializer = MessageSerializer(name: 'toon');
      expect(
        () => serializer.decode(
          Uint8List.fromList([0x42, 0x54, 0x4f, 0x4e, 0]),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('toon'),
          ),
        ),
      );
    });

    test('text and binary push decoding agree', () {
      final text = serializer.decode(
        '["0",null,"topic","some-event",{"value":1}]',
      );
      final binary = serializer.decode(
        BinaryCodec.encode(
          Message(
            joinRef: '0',
            topic: 'topic',
            event: PhoenixChannelEvent.custom('some-event'),
            payload: Uint8List.fromList([123]),
          ),
        ),
      );

      expect(binary.joinRef, text.joinRef);
      expect(binary.ref, text.ref);
      expect(binary.topic, text.topic);
      expect(binary.event.value, text.event.value);
    });
  });

  group('Payload post-processing', () {
    test('normalises map keys recursively', () {
      final serializer = MessageSerializer(
        payloadDecoder: (_) => {
          1: {
            'nested': {2: 'two'},
          },
        },
      );

      final decoded = serializer.decode(
        BinaryCodec.encode(_pushMessage()),
      );

      expect(decoded.payload, {
        '1': {
          'nested': {'2': 'two'},
        },
      });
    });

    test('passes byte results through unchanged', () {
      final bytes = Uint8List.fromList([7, 8]);
      final serializer = MessageSerializer(payloadDecoder: (_) => bytes);

      final decoded = serializer.decode(
        BinaryCodec.encode(_pushMessage()),
      );

      expect(decoded.payload, same(bytes));
    });

    test('wraps other results under data', () {
      final serializer = MessageSerializer(payloadDecoder: (_) => 42);

      final decoded = serializer.decode(
        BinaryCodec.encode(_pushMessage()),
      );

      expect(decoded.payload, {'data': 42});
    });

    test('leaves payload untouched without a payload decoder', () {
      final serializer = MessageSerializer();
      final decoded = serializer.decode(
        BinaryCodec.encode(_pushMessage()),
      );

      expect(decoded.payload, isA<Uint8List>());
      expect(decoded.payload, [1, 2, 3]);
    });
  });
}
