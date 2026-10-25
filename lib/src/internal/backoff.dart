import 'dart:math';

/// Computes reconnection delays from a configured sequence.
///
/// The last configured delay is used once the sequence is exhausted; a random
/// sub-second jitter is added so many clients do not retry at once.
class BackoffPolicy {
  /// Creates a policy over [delays].
  BackoffPolicy(
    List<Duration> delays, {
    Random? random,
  })  : delays = List<Duration>.unmodifiable(
          delays.isEmpty ? const [Duration.zero] : delays,
        ),
        _random = random ?? Random();

  /// The configured delay sequence.
  final List<Duration> delays;

  final Random _random;
  int _attempt = 0;

  /// Number of delays handed out since the last [reset].
  int get attempt => _attempt;

  /// Returns the delay for the next attempt and advances the sequence.
  Duration next() {
    final index = _attempt < delays.length ? _attempt : delays.length - 1;
    final base = delays[index];
    _attempt++;
    return base + Duration(milliseconds: _random.nextInt(1000));
  }

  /// Restarts the sequence at its first delay.
  void reset() => _attempt = 0;
}
