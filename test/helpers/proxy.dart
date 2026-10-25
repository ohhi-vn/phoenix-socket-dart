import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';

const _toxiproxy = 'http://localhost:8474';
const _proxyName = 'backend';

// ── Availability result ───────────────────────────────────────────────────────

/// The result of an availability check, carrying the reason on failure so
/// skip messages are actionable rather than just "unavailable".
class AvailabilityResult {
  const AvailabilityResult.available()
      : isAvailable = true,
        reason = null;

  const AvailabilityResult.unavailable(this.reason) : isAvailable = false;

  final bool isAvailable;

  /// Human-readable failure reason, or `null` when available.
  final String? reason;
}

// ── Availability checks ───────────────────────────────────────────────────────

/// Checks whether the Toxiproxy management API is reachable.
///
/// Returns a rich [AvailabilityResult] so callers can surface the specific
/// failure reason in skip messages.
Future<AvailabilityResult> checkToxiproxyAvailability() async {
  try {
    final response = await get(Uri.parse('$_toxiproxy/proxies'))
        .timeout(const Duration(seconds: 2));
    if (response.statusCode == 200) return const AvailabilityResult.available();
    return AvailabilityResult.unavailable(
        'HTTP ${response.statusCode} from management API');
  } on SocketException catch (e) {
    return AvailabilityResult.unavailable('connection refused: ${e.message}');
  } on TimeoutException {
    return const AvailabilityResult.unavailable('timed out after 2s');
  } on Exception catch (e) {
    return AvailabilityResult.unavailable('unexpected error: $e');
  }
}

/// Convenience wrapper — returns `true` if Toxiproxy is reachable.
Future<bool> isToxiproxyAvailable() async =>
    (await checkToxiproxyAvailability()).isAvailable;

/// Checks whether a Phoenix WebSocket server is reachable at [wsUrl].
///
/// Performs a real WebSocket handshake with a short timeout so the check
/// uses the same protocol as the actual tests.
Future<AvailabilityResult> checkPhoenixServerAvailability(String wsUrl) async {
  try {
    final uri = Uri.parse(wsUrl).replace(
      queryParameters: {'vsn': '2.0.0'},
    );
    final socket = await WebSocket.connect(uri.toString())
        .timeout(const Duration(seconds: 2));
    await socket.close();
    return const AvailabilityResult.available();
  } on SocketException catch (e) {
    return AvailabilityResult.unavailable('connection refused: ${e.message}');
  } on TimeoutException {
    return const AvailabilityResult.unavailable('timed out after 2s');
  } on HandshakeException catch (e) {
    return AvailabilityResult.unavailable('TLS handshake failed: $e');
  } on WebSocketException catch (e) {
    return AvailabilityResult.unavailable('WebSocket error: $e');
  } on Exception catch (e) {
    // Log unexpected failures so they are visible during development rather
    // than silently skipping every test in the group.
    return AvailabilityResult.unavailable('unexpected error: $e');
  }
}

/// Convenience wrapper — returns `true` if the Phoenix server is reachable.
Future<bool> isPhoenixServerAvailable(String wsUrl) async =>
    (await checkPhoenixServerAvailability(wsUrl)).isAvailable;

// ── Core proxy helpers ────────────────────────────────────────────────────────

/// Creates the backend proxy, deleting any stale one first (idempotent).
Future<void> prepareProxy() async {
  await _tryDeleteProxy();
  await post(
    Uri.parse('$_toxiproxy/proxies'),
    body: jsonEncode({
      'name': _proxyName,
      'listen': '0.0.0.0:4004',
      'upstream': 'backend:4001',
      'enabled': true,
    }),
  );
}

/// Deletes the backend proxy, ignoring 404 (already gone).
///
/// tearDown must never throw — a throwing tearDown poisons the next test.
Future<void> destroyProxy() => _tryDeleteProxy();

// ── Network fault helpers ─────────────────────────────────────────────────────

Future<void> haltProxy() => patch(
      Uri.parse('$_toxiproxy/proxies/$_proxyName'),
      body: jsonEncode({'enabled': false}),
    );

Future<void> resumeProxy() => patch(
      Uri.parse('$_toxiproxy/proxies/$_proxyName'),
      body: jsonEncode({'enabled': true}),
    );

Future<void> resetPeer({bool enable = true}) => enable
    ? post(
        Uri.parse('$_toxiproxy/proxies/$_proxyName/toxics'),
        body: jsonEncode({'name': 'reset-peer', 'type': 'reset_peer'}),
      )
    : delete(
        Uri.parse('$_toxiproxy/proxies/$_proxyName/toxics/reset-peer'),
      );

Future<void> haltThenResumeProxy([
  Duration delay = const Duration(milliseconds: 500),
]) async {
  await haltProxy();
  await Future<void>.delayed(delay);
  await resumeProxy();
}

Future<void> resetPeerThenResumeProxy([
  Duration delay = const Duration(milliseconds: 500),
]) async {
  await resetPeer();
  await Future<void>.delayed(delay);
  await resetPeer(enable: false);
}

// ── Private ───────────────────────────────────────────────────────────────────

Future<void> _tryDeleteProxy() async {
  try {
    final response = await delete(Uri.parse('$_toxiproxy/proxies/$_proxyName'));
    if (response.statusCode != 200 && response.statusCode != 404) {
      throw Exception(
        'Unexpected status ${response.statusCode} deleting proxy $_proxyName',
      );
    }
  } on SocketException {
    // Toxiproxy not running — nothing to delete.
  } on ClientException {
    // Network-level failure — nothing to clean up.
  }
}
