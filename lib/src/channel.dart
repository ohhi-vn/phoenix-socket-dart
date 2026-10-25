import 'dart:async';

import 'package:logging/logging.dart';

import 'events.dart';
import 'exceptions.dart';
import 'message.dart';
import 'push.dart';
import 'socket.dart';

/// The different states a channel can be.
enum PhoenixChannelState {
  /// The channel is closed, after a normal leave.
  closed,

  /// The channel is errored.
  errored,

  /// The channel is joined and functional.
  joined,

  /// The channel is waiting for a reply to its 'join'
  /// request.
  joining,

  /// The channel is waiting for a reply to its 'leave'
  /// request.
  leaving,
}

/// A set of States where an error triggered by the parent
/// socket do not end up triggering an error on the channel.
const statesIgnoringErrors = {
  PhoenixChannelState.errored,
  PhoenixChannelState.leaving,
  PhoenixChannelState.closed,
};

/// Bi-directional and isolated communication channel shared between
/// differents clients through a common Phoenix server.
class PhoenixChannel {
  /// Build a PhoenixChannel from a [PhoenixSocket].
  PhoenixChannel.fromSocket(
    this.socket, {
    required this.topic,
    Map<String, dynamic>? parameters,
    Duration? timeout,
  })  : _controller = StreamController.broadcast(),
        _replyWaiters = {},
        _eventWaiters = {},
        parameters = parameters ?? {},
        _timeout = timeout ?? socket.defaultTimeout {
    _messages = _controller.stream.where(_isVisibleMessage);
    _joinPush = _prepareJoin();
    _logger = Logger('phoenix_socket.channel.$loggerName');
    _subscriptions
      ..add(_controller.stream.listen(_onMessage))
      ..addAll(_subscribeToSocketStreams(socket));
  }

  /// Parameters passed to the backend at join time.
  final Map<String, dynamic> parameters;

  /// The [PhoenixSocket] through which this channel is established.
  final PhoenixSocket socket;

  final StreamController<Message> _controller;
  final Map<String, Completer<Message>> _replyWaiters;
  final Map<PhoenixChannelEvent, Completer<Message>> _eventWaiters;
  final List<StreamSubscription> _subscriptions = [];

  late final Stream<Message> _messages;

  /// The name of the topic to which this channel will bind.
  final String topic;

  Duration _timeout;
  PhoenixChannelState _state = PhoenixChannelState.closed;
  Timer? _rejoinTimer;
  bool _joinedOnce = false;
  String? _reference;
  late Push _joinPush;
  Push? _leavePush;
  late Logger _logger;

  /// A list of push to be sent out once the channel is joined.
  final List<Push> pushBuffer = [];

  /// Stream of all messages coming through this channel from the backend.
  Stream<Message> get messages => _messages;

  /// Unique identifier of the 'join' push message.
  String get joinRef => _joinPush.ref;

  Push? get leavePush => _leavePush;

  /// The join push of this channel.
  ///
  /// Re-read on every rejoin attempt — the underlying response completer is
  /// replaced each time the channel (re)joins, so awaiting [Push.future] on
  /// this getter always observes the latest join attempt.
  Push get joinPush => _joinPush;

  /// State of the channel.
  PhoenixChannelState get state => _state;

  /// Whether the channel can send messages.
  bool get canPush =>
      socket.isConnected && _state == PhoenixChannelState.joined;

  String? _loggerName;

  /// The name of the logger associated to this channel.
  String get loggerName => _loggerName ??= topic.replaceAll(
      RegExp(
        r'[:,*&?!@#$%]',
      ),
      '_');

  /// This channel's unique numeric reference.
  String get reference => _reference ??= socket.nextRef;

  /// Returns a future that will complete (or throw) when the provided
  /// reply arrives.
  @Deprecated(
    'Use Push.future or Push.onReply instead. This member will be removed in '
    'a future release.',
  )
  Future<Message> onPushReply(PhoenixChannelEvent replyEvent) {
    if (_eventWaiters.containsKey(replyEvent)) {
      _logger.finer(
        () => 'Removing previous waiter for $replyEvent',
      );
      _eventWaiters.remove(replyEvent);
    }
    _logger.finer(
      () => 'Hooking on channel $topic for reply to $replyEvent',
    );
    final completer = Completer<Message>();
    _eventWaiters[replyEvent] = completer;
    completer.future
        .whenComplete(() => _eventWaiters.remove(replyEvent))
        .ignore();
    return completer.future;
  }

  /// Waits for the reply carrying [ref].
  ///
  /// Used by [Push] to correlate a reply with its own attempt. A previous
  /// waiter for the same ref is failed with [PushSupersededException].
  Future<Message> waitForReply(String ref) {
    final previous = _replyWaiters.remove(ref);
    if (previous != null && !previous.isCompleted) {
      previous.future.ignore();
      previous.completeError(PushSupersededException(ref: ref));
    }
    final completer = Completer<Message>();
    _replyWaiters[ref] = completer;
    completer.future.whenComplete(() => _replyWaiters.remove(ref)).ignore();
    return completer.future;
  }

  /// Close this channel.
  ///
  /// As a side effect, this method also remove this channel from
  /// the encompassing [PhoenixSocket].
  void close() {
    if (_state == PhoenixChannelState.closed) {
      return;
    }
    _state = PhoenixChannelState.closed;

    _rejoinTimer?.cancel();
    _rejoinTimer = null;

    final closedError = ChannelClosedError(
      'Channel $topic closed before a reply was received',
    );
    for (final push in pushBuffer) {
      push.cancelTimeout();
      push.fail(closedError);
    }
    pushBuffer.clear();

    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _subscriptions.clear();

    _joinPush.cancelTimeout();
    _joinPush.fail(closedError);
    _leavePush?.cancelTimeout();

    _failWaiters(closedError);

    unawaited(_controller.close());
    socket.removeChannel(this);
  }

  /// Trigger the reception of a message.
  void trigger(Message message) {
    if (_controller.isClosed || !_isMember(message)) {
      return;
    }
    _controller.add(message);
  }

  /// Trigger an error on this channel.
  void triggerError(PhoenixException error) {
    _logger.fine('Receiving error on channel', error);
    if (!statesIgnoringErrors.contains(_state)) {
      if (error.message != null) {
        trigger(error.message!);
      }

      _logger.warning('Got error on channel', error);

      _failWaiters(error);

      final prevState = _state;
      _state = PhoenixChannelState.errored;
      if (prevState == PhoenixChannelState.joining) {
        _joinPush.reset();
      }

      if (socket.isConnected) {
        _startRejoinTimer();
      }
    }
  }

  /// Leave this channel.
  ///
  /// Idempotent: calling leave on a closed channel returns the existing leave
  /// push without sending anything.
  Push leave({Duration? timeout}) {
    final existing = _leavePush;
    if (_state == PhoenixChannelState.closed) {
      final push = existing ??
          Push(
            this,
            event: PhoenixChannelEvent.leave,
            payload: () => {},
            timeout: timeout ?? _timeout,
          );
      _leavePush = push;
      if (!push.hasReceived('ok')) {
        push.trigger(const PushResponse(status: 'ok'));
      }
      return push;
    }

    _joinPush.cancelTimeout();
    _rejoinTimer?.cancel();
    _rejoinTimer = null;

    final prevState = _state;
    _state = PhoenixChannelState.leaving;

    final currentLeavePush = _leavePush ??= Push(
      this,
      event: PhoenixChannelEvent.leave,
      payload: () => {},
      timeout: timeout ?? _timeout,
    );

    if (!socket.isConnected || prevState != PhoenixChannelState.joined) {
      currentLeavePush.trigger(const PushResponse(status: 'ok'));
      _onClose(const PushResponse(status: 'ok'));
      close();
    } else {
      void onClose(PushResponse reply) {
        _onClose(reply);
        close();
      }

      currentLeavePush
        ..onReply('ok', onClose)
        ..onReply('timeout', onClose)
        ..send();
    }

    return currentLeavePush;
  }

  /// Join this channel using the associated [PhoenixSocket].
  Push join([Duration? newTimeout]) {
    if (_joinedOnce) {
      throw StateError('Channel $topic has already joined once');
    }

    if (newTimeout != null) {
      _timeout = newTimeout;
    }

    _joinedOnce = true;
    if (socket.isConnected) {
      _attemptJoin();
    } else {
      _state = PhoenixChannelState.errored;
    }

    return _joinPush;
  }

  /// Push a message to the Phoenix server.
  Push push(
    /// The name of the message's event.
    ///
    /// This can be any string, as long as it matches with something
    /// expected on the backend implementation.
    String eventName,

    /// The message payload.
    ///
    /// This needs to be a JSON encodable object.
    Map<String, dynamic> payload, [
    /// Manually set timeout value for this push.
    ///
    /// If not provided, the default timeout will be used.
    Duration? newTimeout,
  ]) =>
      pushEvent(
        PhoenixChannelEvent.custom(eventName),
        payload,
        newTimeout,
      );

  /// Push a message with a valid [PhoenixChannelEvent] name.
  ///
  /// This variant is used internally for channel joining/leaving. Prefer
  /// using [push] instead.
  Push pushEvent(
    PhoenixChannelEvent event,
    Map<String, dynamic> payload, [
    Duration? newTimeout,
  ]) {
    if (!_joinedOnce) {
      throw StateError('Cannot push before joining channel $topic');
    }

    final pushEvent = Push(
      this,
      event: event,
      payload: () => payload,
      timeout: newTimeout ?? _timeout,
    );

    if (canPush) {
      _logger.finest(() => 'Sending out push ${pushEvent.ref}');
      pushEvent.send();
    } else {
      if (_state == PhoenixChannelState.closed ||
          _state == PhoenixChannelState.errored) {
        throw ChannelClosedError('Can\'t push event on a $_state channel');
      }

      _logger.finest(
          () => 'Buffering push ${pushEvent.ref} for later send ($_state)');
      pushBuffer.add(pushEvent);
    }

    return pushEvent;
  }

  List<StreamSubscription> _subscribeToSocketStreams(PhoenixSocket socket) {
    return [
      socket.errorStream.listen(
        (error) => _rejoinTimer?.cancel(),
      ),
      socket.openStream.listen(
        (event) {
          _rejoinTimer?.cancel();
          _rejoinTimer = null;
          if (_state == PhoenixChannelState.errored) {
            _attemptJoin();
          }
        },
      )
    ];
  }

  Push _prepareJoin([Duration? providedTimeout]) {
    return Push(
      this,
      event: PhoenixChannelEvent.join,
      payload: () => parameters,
      timeout: providedTimeout ?? _timeout,
    );
  }

  void _bindJoinPush(Push push) {
    push
      ..rebind()
      ..onReply('ok', (response) {
        _logger.finer(() => "Join message was ok'ed");
        _state = PhoenixChannelState.joined;
        _rejoinTimer?.cancel();
        _rejoinTimer = null;
        final buffered = pushBuffer.toList(growable: false);
        pushBuffer.clear();
        for (final bufferedPush in buffered) {
          bufferedPush.send();
        }
      })
      ..onReply('error', (response) {
        _logger.warning(() => 'Join message got error response: $response');
        _state = PhoenixChannelState.errored;
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      })
      ..onReply('timeout', (response) {
        _logger.warning('Join message timed out');

        Push(
          this,
          event: PhoenixChannelEvent.leave,
          payload: () => {},
          timeout: _timeout,
        ).send();

        _state = PhoenixChannelState.errored;
        _joinPush.reset();
        if (socket.isConnected) {
          _startRejoinTimer();
        }
      });
  }

  void _startRejoinTimer() {
    _rejoinTimer?.cancel();
    _rejoinTimer = Timer(_timeout, () {
      _rejoinTimer = null;
      if (socket.isConnected) _attemptJoin();
    });
  }

  void _attemptJoin() {
    if (_state == PhoenixChannelState.leaving || !socket.isConnected) {
      return;
    }
    if (_joinPush.sent) {
      _joinPush.reset();
    }
    _joinPush.timeout = _timeout;
    _state = PhoenixChannelState.joining;
    _bindJoinPush(_joinPush);
    unawaited(_joinPush.send());
  }

  bool _isMember(Message message) {
    if (message.joinRef != null &&
        message.joinRef != _joinPush.ref &&
        PhoenixChannelEvent.statuses.contains(message.event)) {
      return false;
    }
    return true;
  }

  bool _isVisibleMessage(Message message) =>
      !message.event.isReply || message.event.isChannelReply;

  void _onMessage(Message message) {
    if (message.event == PhoenixChannelEvent.close) {
      _logger.finer(() => 'Closing channel $topic');
      _rejoinTimer?.cancel();
      _rejoinTimer = null;
      close();
    } else if (message.event == PhoenixChannelEvent.error) {
      _logger.finer(() => 'Erroring channel $topic');
      if (_state == PhoenixChannelState.joining) {
        _joinPush.reset();
      }
      _state = PhoenixChannelState.errored;
      _failWaiters(
        ChannelClosedError(
            'Channel $topic errored before a reply was received'),
      );
      if (socket.isConnected) {
        _rejoinTimer?.cancel();
        _startRejoinTimer();
      }
    } else if (message.event == PhoenixChannelEvent.reply) {
      _controller.add(message.asReplyEvent());
    }

    final ref = message.ref ?? _refFromReplyEvent(message.event);
    if (ref != null) {
      final waiter = _replyWaiters.remove(ref);
      if (waiter != null && !waiter.isCompleted) {
        waiter.complete(message);
      }
    }

    final eventWaiter = _eventWaiters.remove(message.event);
    if (eventWaiter != null && !eventWaiter.isCompleted) {
      eventWaiter.complete(message);
    }
  }

  String? _refFromReplyEvent(PhoenixChannelEvent event) {
    const prefix = 'chan_reply_';
    if (!event.value.startsWith(prefix)) return null;
    return event.value.substring(prefix.length);
  }

  void _failWaiters(Object error) {
    for (final ref in _replyWaiters.keys) {
      socket.failPendingReply(ref, error);
    }
    final waiters = <Completer<Message>>[
      ..._replyWaiters.values,
      ..._eventWaiters.values,
    ];
    _replyWaiters.clear();
    _eventWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) {
        waiter.future.ignore();
        waiter.completeError(error);
      }
    }
  }

  void _onClose(PushResponse response) {
    _logger.finer('Leave message has completed');
    trigger(Message(
      event: PhoenixChannelEvent.close,
      payload: const <String, String>{'ok': 'leave'},
    ));
  }
}
