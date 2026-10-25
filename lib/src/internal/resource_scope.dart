import 'dart:async';

/// Ordered, idempotent collection of teardown callbacks.
///
/// Resources are released in registration order. [close] runs at most once;
/// later registrations after closure are released immediately.
class ResourceScope {
  /// Creates a scope.
  ///
  /// [onError] receives failures from individual releases so one failing
  /// resource cannot prevent the rest from being released.
  ResourceScope({void Function(Object error, StackTrace stackTrace)? onError})
      : _onError = onError;

  final List<FutureOr<void> Function()> _releases = [];
  final void Function(Object error, StackTrace stackTrace)? _onError;
  bool _closed = false;

  /// Whether this scope has been closed.
  bool get isClosed => _closed;

  /// Registers a release callback.
  void add(FutureOr<void> Function() release) {
    if (_closed) {
      _run(release);
      return;
    }
    _releases.add(release);
  }

  /// Runs every registered release once, in registration order.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final releases = _releases.toList(growable: false);
    _releases.clear();
    for (final release in releases) {
      try {
        await release();
      } catch (error, stackTrace) {
        _onError?.call(error, stackTrace);
      }
    }
  }

  void _run(FutureOr<void> Function() release) {
    try {
      final result = release();
      if (result is Future<void>) {
        unawaited(result.catchError((Object error, StackTrace stackTrace) {
          _onError?.call(error, stackTrace);
        }));
      }
    } catch (error, stackTrace) {
      _onError?.call(error, stackTrace);
    }
  }
}
