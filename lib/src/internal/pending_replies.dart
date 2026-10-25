import 'dart:async';

/// Ref-keyed registry of pending replies.
///
/// Owns every completer waiting for a message, so failure paths can complete
/// all of them instead of dropping the map and stranding callers.
class PendingReplies {
  final Map<String, Completer<Object?>> _completers = {};
  final Map<String, String> _owners = {};

  /// Number of pending replies.
  int get length => _completers.length;

  /// References currently pending.
  Iterable<String> get refs => _completers.keys;

  /// Registers a completer for [ref] owned by [owner].
  ///
  /// If a completer is already registered for [ref], the previous one is
  /// completed with an [StateError] so no caller is left waiting.
  Completer<Object?> register(String ref, {required String owner}) {
    final previous = _completers.remove(ref);
    if (previous != null && !previous.isCompleted) {
      previous.future.ignore();
      previous.completeError(
        StateError('Reply for ref $ref was superseded by a newer wait'),
      );
    }
    final completer = Completer<Object?>();
    _completers[ref] = completer;
    _owners[ref] = owner;
    return completer;
  }

  /// Whether [ref] has a pending completer.
  bool contains(String ref) => _completers.containsKey(ref);

  /// The pending future for [ref], if any.
  Future<Object?>? futureFor(String ref) => _completers[ref]?.future;

  /// The owner label registered for [ref], if any.
  String? ownerOf(String ref) => _owners[ref];

  /// Removes and returns the completer for [ref] without completing it.
  Completer<Object?>? remove(String ref) {
    _owners.remove(ref);
    return _completers.remove(ref);
  }

  /// Completes the waiter for [ref] with [value].
  bool complete(String ref, Object? value) {
    final completer = remove(ref);
    if (completer == null || completer.isCompleted) return false;
    completer.complete(value);
    return true;
  }

  /// Fails the waiter for [ref] with [error].
  bool completeError(String ref, Object error, [StackTrace? stackTrace]) {
    final completer = remove(ref);
    if (completer == null || completer.isCompleted) return false;
    completer.future.ignore();
    completer.completeError(error, stackTrace);
    return true;
  }

  /// Fails and removes every pending waiter.
  void completeAllWithError(Object error, [StackTrace? stackTrace]) {
    final completers = _completers.values.toList(growable: false);
    _completers.clear();
    _owners.clear();
    for (final completer in completers) {
      if (!completer.isCompleted) {
        completer.future.ignore();
        completer.completeError(error, stackTrace);
      }
    }
  }

  /// Drops the waiter for [ref] without completing it.
  ///
  /// Only for cases where the caller has already been completed elsewhere.
  void discard(String ref) {
    remove(ref);
  }
}
