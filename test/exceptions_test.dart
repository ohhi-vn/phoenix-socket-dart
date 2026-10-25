import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

void main() {
  group('PhoenixException', () {
    test('string form exposes the wrapped socket error', () {
      final exception = PhoenixException(
        socketError: PhoenixSocketErrorEvent(error: StateError('boom')),
      );

      expect(exception.toString(), 'Bad state: boom');
      expect(exception.socketError, isNotNull);
      expect(exception.socketClosed, isNull);
    });

    test('reports the socket-closed condition without an error event', () {
      final exception = PhoenixException(
        socketClosed: const PhoenixSocketCloseEvent(reason: 'bye', code: 1000),
      );

      expect(exception.toString(), 'PhoenixException: socket closed');
      expect(exception.socketClosed?.reason, 'bye');
    });

    test('defaults to the socket-closed string form when unset', () {
      final exception = PhoenixException();

      expect(exception.toString(), 'PhoenixException: socket closed');
      expect(exception.socketError, isNull);
      expect(exception.socketClosed, isNull);
    });

    test('exposes an error message for close and error events', () {
      final closed = PhoenixException(
        socketClosed: const PhoenixSocketCloseEvent(),
      );
      final errored = PhoenixException(
        socketError: PhoenixSocketErrorEvent(error: StateError('boom')),
      );

      expect(closed.message?.event, PhoenixChannelEvent.error);
      expect(errored.message?.event, PhoenixChannelEvent.error);
      expect(PhoenixException().message, isNull);
    });

    test('carries a channel event name when provided', () {
      final exception = PhoenixException(channelEvent: 'phx_error');
      expect(exception.channelEvent, 'phx_error');
    });
  });

  group('ChannelTimeoutException', () {
    test('keeps the timeout response', () {
      const response = PushResponse(status: 'timeout');
      final exception = ChannelTimeoutException(response);

      expect(exception.response.status, 'timeout');
      expect(exception.response, same(response));
    });
  });

  group('ChannelClosedError', () {
    test('is a state error with the supplied message', () {
      final error = ChannelClosedError('channel closed early');

      expect(error, isA<StateError>());
      expect(error.message, 'channel closed early');
    });
  });

  group('PushSupersededException', () {
    test('string form names the superseded ref', () {
      final exception = PushSupersededException(ref: '42');

      expect(exception.ref, '42');
      expect(exception.toString(), contains('42'));
      expect(exception.toString(), contains('superseded'));
    });

    test('string form falls back when the ref is unknown', () {
      final exception = PushSupersededException();

      expect(exception.ref, isNull);
      expect(exception.toString(), contains('unknown'));
    });
  });
}
