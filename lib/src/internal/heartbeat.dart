import 'dart:async';

/// Owns the socket's periodic heartbeat timer.
class HeartbeatScheduler {
  /// Creates a scheduler that calls [onTick] every [interval].
  HeartbeatScheduler({
    required this.interval,
    required this.onTick,
  });

  /// Interval between heartbeats.
  final Duration interval;

  /// Callback invoked on every tick.
  final void Function() onTick;

  Timer? _timer;

  /// Whether a heartbeat timer is currently active.
  bool get isActive => _timer != null;

  /// Starts the timer, replacing any previous timer.
  ///
  /// At most one timer is ever active.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => onTick());
  }

  /// Stops the timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
