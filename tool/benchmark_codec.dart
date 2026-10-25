// Codec micro-benchmark used to track hot-path regressions.
//
// Run with: dart run tool/benchmark_codec.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:phoenix_socket/src/codec/binary_codec.dart';

const _iterations = 100000;
const _warmup = 5000;

void main() {
  final serializer = MessageSerializer();
  final message = Message(
    joinRef: '1',
    ref: '42',
    topic: 'room:lobby',
    event: PhoenixChannelEvent.custom('new_msg'),
    payload: const {
      'body': 'hello world',
      'count': 3,
      'nested': {
        'items': [1, 2, 3],
      },
    },
  );

  final textFrame = serializer.encode(message) as String;
  final binaryMessage = Message(
    joinRef: '1',
    ref: '42',
    topic: 'room:lobby',
    event: PhoenixChannelEvent.custom('new_msg'),
    payload: Uint8List.fromList(List<int>.generate(64, (i) => i)),
  );
  final binaryFrame = BinaryCodec.encode(binaryMessage);

  _benchmark('text encode', () => serializer.encode(message));
  _benchmark('text decode', () => serializer.decode(textFrame));
  _benchmark('binary encode', () => BinaryCodec.encode(binaryMessage));
  _benchmark('binary decode', () => BinaryCodec.decode(binaryFrame));
}

void _benchmark(String label, void Function() body) {
  for (var i = 0; i < _warmup; i++) {
    body();
  }
  final stopwatch = Stopwatch()..start();
  for (var i = 0; i < _iterations; i++) {
    body();
  }
  stopwatch.stop();
  final seconds = stopwatch.elapsedMicroseconds / 1000000;
  final perSecond = _iterations / seconds;
  stdout.writeln(
    '$label: ${perSecond.toStringAsFixed(0)} ops/s '
    '(${stopwatch.elapsedMilliseconds} ms for $_iterations iterations)',
  );
}
