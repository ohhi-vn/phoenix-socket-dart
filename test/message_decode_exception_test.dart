import 'package:phoenix_socket/src/codec/message_decode_exception.dart';
import 'package:test/test.dart';

void main() {
  group('MessageDecodeException', () {
    test('keeps the failing stage and frame details', () {
      final exception = MessageDecodeException(
        'unexpected frame kind',
        stage: DecodeStage.binary,
        kind: 3,
        frameLength: 12,
      );

      expect(exception.stage, DecodeStage.binary);
      expect(exception.kind, 3);
      expect(exception.frameLength, 12);
      expect(exception.message, 'unexpected frame kind');
    });

    test('renders stage and optional frame details', () {
      final exception = MessageDecodeException(
        'bad frame',
        stage: DecodeStage.binary,
        kind: 4,
        frameLength: 9,
      );

      expect(exception.toString(), contains('bad frame'));
      expect(exception.toString(), contains('stage: binary'));
      expect(exception.toString(), contains('kind: 4'));
      expect(exception.toString(), contains('frameLength: 9'));
    });

    test('omits frame details that were not supplied', () {
      final exception = MessageDecodeException(
        'bad json',
        stage: DecodeStage.text,
      );

      expect(exception.kind, isNull);
      expect(exception.frameLength, isNull);
      expect(exception.toString(), contains('stage: text'));
      expect(exception.toString(), isNot(contains('kind:')));
      expect(exception.toString(), isNot(contains('frameLength:')));
    });

    test('stays catchable as a FormatException', () {
      final exception = MessageDecodeException(
        'bad payload',
        stage: DecodeStage.payload,
      );

      expect(exception, isA<FormatException>());

      Object? caught;
      try {
        throw exception;
      } on FormatException catch (error) {
        caught = error;
      }
      expect(caught, same(exception));
    });

    test('passes source and offset to the format exception', () {
      final exception = MessageDecodeException(
        'bad payload',
        stage: DecodeStage.payload,
        source: '[null,null,"t","e",{}]',
        offset: 2,
      );

      expect(exception.source, '[null,null,"t","e",{}]');
      expect(exception.offset, 2);
    });

    test('decode stages are nameable', () {
      expect(
        DecodeStage.values.map((stage) => stage.name),
        ['text', 'binary', 'payload'],
      );
    });
  });
}
