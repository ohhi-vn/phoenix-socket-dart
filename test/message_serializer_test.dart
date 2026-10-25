import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  late MessageSerializer serializer;

  final exampleMsg = Message(
    joinRef: '0',
    ref: '1',
    topic: 't',
    event: PhoenixChannelEvent.custom('e'),
    payload: {'foo': 1},
  );

  Uint8List binPayload() => Uint8List.fromList([1]);

  setUp(() {
    // const removed — MessageSerializer is now mutable.
    serializer = MessageSerializer();
  });

  group('MessageSerializer', () {
    group('JSON', () {
      test('encodes general pushes', () {
        final encoded = serializer.encode(exampleMsg);
        expect(encoded, equals('["0","1","t","e",{"foo":1}]'));
      });

      test('decodes', () {
        final decoded = serializer.decode('["0","1","t","e",{"foo":1}]');
        expect(decoded.joinRef, equals('0'));
        expect(decoded.ref, equals('1'));
        expect(decoded.topic, equals('t'));
        expect(decoded.event.value, equals('e'));
        expect(decoded.payload, equals({'foo': 1}));
      });
    });

    group('Binary', () {
      test('encodes', () {
        final buffer = binPayload();
        final message = Message(
          joinRef: '0',
          ref: '1',
          topic: 't',
          event: PhoenixChannelEvent.custom('e'),
          payload: buffer,
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0,
          1,
          1,
          1,
          1,
          ...utf8.encode('0'),
          ...utf8.encode('1'),
          ...utf8.encode('t'),
          ...utf8.encode('e'),
          1,
        ]);

        expect(encoded, equals(expected));
      });

      test('encodes variable length segments', () {
        final buffer = binPayload();
        final message = Message(
          joinRef: '10',
          ref: '1',
          topic: 'top',
          event: PhoenixChannelEvent.custom('ev'),
          payload: buffer,
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0,
          2,
          1,
          3,
          2,
          ...utf8.encode('10'),
          ...utf8.encode('1'),
          ...utf8.encode('top'),
          ...utf8.encode('ev'),
          1,
        ]);

        expect(encoded, equals(expected));
      });

      test('decodes push', () {
        final List<int> message = [
          0,
          3,
          3,
          10,
          ...utf8.encode('123'),
          ...utf8.encode('top'),
          ...utf8.encode('some-event'),
          1,
          1,
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));
        expect(decoded.joinRef, equals('123'));
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });

      test('decodes reply', () {
        final List<int> message = [
          1,
          3,
          2,
          3,
          2,
          ...utf8.encode('100'),
          ...utf8.encode('12'),
          ...utf8.encode('top'),
          ...utf8.encode('ok'),
          1,
          1,
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));
        expect(decoded.joinRef, equals('100'));
        expect(decoded.ref, equals('12'));
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('phx_reply'));
        expect(decoded.payload, isA<Map>());
        expect(decoded.payload?['status'], equals('ok'));
        expect(
            decoded.payload?['response'], equals(Uint8List.fromList([1, 1])));
      });

      test('decodes broadcast', () {
        final List<int> message = [
          2,
          3,
          10,
          ...utf8.encode('top'),
          ...utf8.encode('some-event'),
          1,
          1,
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));
        expect(decoded.joinRef, isNull);
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });
    });

    group('Error cases', () {
      test('throws on invalid message type', () {
        expect(
          () => serializer.decode(123),
          // Updated to match the new ArgumentError message from
          // message_serializer.dart: "rawData must be a String or Uint8List, got int"
          throwsA(isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('String or Uint8List'),
          )),
        );
      });

      test('handles malformed JSON', () {
        expect(
          () => serializer.decode('{"bad json"}'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('Edge cases', () {
      test('handles empty binary payload', () {
        final List<int> message = [
          2,
          3,
          5,
          ...utf8.encode('top'),
          ...utf8.encode('event'),
        ];

        final decoded = serializer.decode(Uint8List.fromList(message));
        expect(decoded.payload, isEmpty);
      });

      test('handles custom payload decoder', () {
        Map<String, dynamic> customDecoder(Uint8List payload) => {
              'nested': {'data': 42},
              'list': [
                {'item': 1},
                {'item': 2},
              ],
            };

        // payloadDecoder shortcut on PhoenixSocketOptions is gone —
        // construct MessageSerializer directly instead.
        final s = MessageSerializer(payloadDecoder: customDecoder);

        final List<int> message = [
          2,
          3,
          5,
          ...utf8.encode('top'),
          ...utf8.encode('event'),
          1,
        ];

        final decoded = s.decode(Uint8List.fromList(message));
        expect(decoded.payload?['nested']['data'], equals(42));
        expect(decoded.payload?['list'][0]['item'], equals(1));
        expect(decoded.payload?['list'][1]['item'], equals(2));
      });
    });
  });
}
