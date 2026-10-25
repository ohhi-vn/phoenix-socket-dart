import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

void main() {
  group('PhoenixSocketCloseEvent', () {
    test('equality and hash depend on reason and code', () {
      const event = PhoenixSocketCloseEvent(reason: 'bye', code: 1000);
      const same = PhoenixSocketCloseEvent(reason: 'bye', code: 1000);
      const otherReason = PhoenixSocketCloseEvent(reason: 'later', code: 1000);
      const otherCode = PhoenixSocketCloseEvent(reason: 'bye', code: 1001);

      expect(event, same);
      expect(event.hashCode, same.hashCode);
      expect(event, isNot(otherReason));
      expect(event, isNot(otherCode));
      expect(event, isNot(PhoenixSocketOpenEvent()));
    });

    test('string form includes the payload fields', () {
      const event = PhoenixSocketCloseEvent(reason: 'bye', code: 1000);
      expect(event.toString(), contains('bye'));
      expect(event.toString(), contains('1000'));
      expect(event.toString(), startsWith('PhoenixSocketCloseEvent('));
    });

    test('accepts omitted fields', () {
      const event = PhoenixSocketCloseEvent();
      expect(event.reason, isNull);
      expect(event.code, isNull);
      expect(event, const PhoenixSocketCloseEvent());
    });
  });

  group('PhoenixSocketErrorEvent', () {
    test('equality and hash depend on the error', () {
      final event = PhoenixSocketErrorEvent(error: StateError('boom'));
      final same = PhoenixSocketErrorEvent(error: event.error);
      final other = PhoenixSocketErrorEvent(error: StateError('other'));

      expect(event, same);
      expect(event.hashCode, same.hashCode);
      expect(event, isNot(other));
    });

    test('string form includes the error', () {
      final event = PhoenixSocketErrorEvent(error: StateError('boom'));
      expect(event.toString(), contains('boom'));
      expect(event.toString(), startsWith('PhoenixSocketErrorEvent('));
    });

    test('keeps an optional stack trace', () {
      final trace = StackTrace.current;
      final event = PhoenixSocketErrorEvent(
        error: StateError('boom'),
        stacktrace: trace,
      );
      expect(event.stacktrace, same(trace));
    });
  });

  group('PhoenixChannelEvent', () {
    test('replyFor builds a channel reply name', () {
      final event = PhoenixChannelEvent.replyFor('42');

      expect(event.value, 'chan_reply_42');
      expect(event.isReply, isTrue);
      expect(event.isChannelReply, isTrue);
      expect(event, PhoenixChannelEvent.custom('chan_reply_42'));
    });

    test('custom events keep their name', () {
      final event = PhoenixChannelEvent.custom('my:event');

      expect(event.value, 'my:event');
      expect(event.isReply, isFalse);
      expect(event.isChannelReply, isFalse);
    });

    test('protocol names map to the known constants', () {
      expect(PhoenixChannelEvent('phx_close'), PhoenixChannelEvent.close);
      expect(PhoenixChannelEvent('phx_error'), PhoenixChannelEvent.error);
      expect(PhoenixChannelEvent('phx_join'), PhoenixChannelEvent.join);
      expect(PhoenixChannelEvent('phx_reply'), PhoenixChannelEvent.reply);
      expect(PhoenixChannelEvent('phx_leave'), PhoenixChannelEvent.leave);
    });

    test('unknown protocol names are rejected', () {
      expect(
        () => PhoenixChannelEvent('not_a_protocol_event'),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.invalidValue,
            'invalidValue',
            'not_a_protocol_event',
          ),
        ),
      );
    });

    test('reply detection covers plain and channel replies', () {
      expect(PhoenixChannelEvent.reply.isReply, isTrue);
      expect(PhoenixChannelEvent.reply.isChannelReply, isFalse);
      expect(PhoenixChannelEvent.custom('reply').isReply, isFalse);
    });

    test('statuses list only protocol lifecycle events', () {
      expect(
        PhoenixChannelEvent.statuses,
        {
          PhoenixChannelEvent.close,
          PhoenixChannelEvent.error,
          PhoenixChannelEvent.join,
          PhoenixChannelEvent.reply,
          PhoenixChannelEvent.leave,
        },
      );
      expect(PhoenixChannelEvent.statuses, isNot(contains(PhoenixChannelEvent.heartbeat)));
    });

    test('equality and hash depend on the value', () {
      final a = PhoenixChannelEvent.custom('same');
      final b = PhoenixChannelEvent.custom('same');
      final c = PhoenixChannelEvent.custom('different');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.toString(), 'PhoenixChannelEvent(same)');
    });

    test('heartbeat is a non-protocol event', () {
      expect(PhoenixChannelEvent.heartbeat.value, 'heartbeat');
      expect(PhoenixChannelEvent.heartbeat.isReply, isFalse);
    });
  });
}
