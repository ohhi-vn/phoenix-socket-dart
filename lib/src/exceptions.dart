import 'events.dart';
import 'message.dart';
import 'push.dart';

/// Exception yield when a [PhoenixSocket] closes for unexpected reasons.
class PhoenixException implements Exception {
  /// The default constructor for this exception.
  PhoenixException({
    this.socketClosed,
    this.socketError,
    this.channelEvent,
  });

  /// The associated error event.
  final PhoenixSocketErrorEvent? socketError;

  /// The associated close event.
  final PhoenixSocketCloseEvent? socketClosed;

  /// The associated channel event.
  final String? channelEvent;

  /// The error message for this exception.
  Message? get message {
    if (socketClosed != null) {
      return Message(event: PhoenixChannelEvent.error);
    } else if (socketError != null) {
      return Message(event: PhoenixChannelEvent.error);
    }
    return null;
  }

  @override
  String toString() {
    if (socketError != null) {
      return socketError!.error.toString();
    } else {
      return 'PhoenixException: socket closed';
    }
  }
}

/// Exception thrown when a [Push]'s reply was awaited for, and
/// the allowed delay has passed.
class ChannelTimeoutException implements Exception {
  /// Default constructor
  ChannelTimeoutException(this.response);

  /// The PushReponse containing the timeout event.
  PushResponse response;
}

class ChannelClosedError extends StateError {
  ChannelClosedError(super.message);
}

/// Thrown when a push attempt is replaced by a newer attempt before its reply
/// arrived.
///
/// Awaiting the previous [Push.future] now fails instead of hanging.
class PushSupersededException implements Exception {
  /// Creates an exception for [push], optionally carrying the superseded
  /// [ref].
  PushSupersededException({this.push, this.ref});

  /// The push whose attempt was superseded, when known.
  final Push? push;

  /// The reference of the superseded attempt.
  final String? ref;

  @override
  String toString() =>
      'PushSupersededException: push ${ref ?? 'unknown'} was superseded by a '
      'newer attempt';
}
