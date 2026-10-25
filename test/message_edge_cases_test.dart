import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

void main() {
  group('Message.fromJson envelope validation', () {
    test('decodes a complete envelope', () {
      final message = Message.fromJson([
        'join-ref',
        '1',
        'room:lobby',
        'new_msg',
        {'body': 'hi'},
      ]);

      expect(message.joinRef, 'join-ref');
      expect(message.ref, '1');
      expect(message.topic, 'room:lobby');
      expect(message.event, PhoenixChannelEvent.custom('new_msg'));
      expect(message.payload, {'body': 'hi'});
      expect(message.isReply, isFalse);
    });

    test('accepts null join ref, ref and topic', () {
      final message = Message.fromJson([null, null, null, 'event', null]);

      expect(message.joinRef, isNull);
      expect(message.ref, isNull);
      expect(message.topic, isNull);
      expect(message.payload, isNull);
    });

    test('rejects envelopes with the wrong element count', () {
      expect(
        () => Message.fromJson([null, null, 'topic', 'event']),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            allOf(contains('5-element'), contains('4')),
          ),
        ),
      );
    });

    test('names the offending field for non-string envelope values', () {
      FormatException decode(List<dynamic> parts) {
        try {
          Message.fromJson(parts);
        } on FormatException catch (error) {
          return error;
        }
        fail('Expected a FormatException');
      }

      expect(
        decode([1, null, 'topic', 'event', {}]).message,
        contains('joinRef'),
      );
      expect(
        decode([null, 1, 'topic', 'event', {}]).message,
        contains('ref'),
      );
      expect(
        decode([null, null, 1, 'event', {}]).message,
        contains('topic'),
      );
      expect(
        decode([null, null, 'topic', 1, {}]).message,
        contains('String'),
      );
    });
  });

  group('Message factories', () {
    test('heartbeat targets the phoenix topic', () {
      final message = Message.heartbeat('7');

      expect(message.topic, 'phoenix');
      expect(message.ref, '7');
      expect(message.event, PhoenixChannelEvent.heartbeat);
      expect(message.payload, isEmpty);
      expect(message.joinRef, isNull);
    });

    test('timeoutFor builds a reply message with a timeout payload', () {
      final message = Message.timeoutFor('9');

      expect(message.event.value, 'chan_reply_9');
      expect(message.isReply, isTrue);
      expect(message.payload, {
        'status': 'timeout',
        'response': <String, dynamic>{},
      });
    });

    test('binary wraps the payload without copying', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final message = Message.binary(
        joinRef: 'join',
        ref: '1',
        topic: 'room',
        event: PhoenixChannelEvent.custom('binary'),
        payload: payload,
      );

      expect(message.payload, same(payload));
      expect((message.encode() as List<dynamic>)[4], same(payload));
    });
  });

  group('Message encoding', () {
    test('encode round-trips through fromJson', () {
      final payload = <String, dynamic>{'body': 'hi'};
      final original = Message(
        joinRef: 'join',
        ref: '1',
        topic: 'room',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: payload,
      );

      final decoded = Message.fromJson(original.encode() as List<dynamic>);

      expect(decoded, original);
      expect(decoded.payload, same(payload));
    });

    test('equality and hash cover every envelope field', () {
      final payload = <String, dynamic>{'body': 'hi'};
      final a = Message(
        joinRef: 'join',
        ref: '1',
        topic: 'room',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: payload,
      );
      final b = Message(
        joinRef: 'join',
        ref: '1',
        topic: 'room',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: payload,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          Message(
            joinRef: 'other',
            ref: '1',
            topic: 'room',
            event: PhoenixChannelEvent.custom('new_msg'),
            payload: payload,
          ),
        ),
      );
      expect(a.toString(), contains('new_msg'));
      expect(a.toString(), contains('room'));
    });
  });

  group('replies', () {
    test('asReplyEvent rewrites the event and keeps the envelope', () {
      final message = Message(
        joinRef: 'join',
        ref: '15',
        topic: 'room',
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: const {'ok': true},
      );

      final reply = message.asReplyEvent();

      expect(reply.event.value, 'chan_reply_15');
      expect(reply.isReply, isTrue);
      expect(reply.ref, '15');
      expect(reply.topic, 'room');
      expect(reply.joinRef, 'join');
      expect(reply.payload, same(message.payload));
    });

    test('isReply is false for custom events', () {
      final message = Message(
        event: PhoenixChannelEvent.custom('new_msg'),
        payload: const {},
      );

      expect(message.isReply, isFalse);
    });
  });
}
