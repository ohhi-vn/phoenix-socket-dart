import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

void main() {
  late MessageSerializer serializer;

  final exampleMsg = Message(
    joinRef: '0',
    ref: '1',
    topic: 't',
    event: PhoenixChannelEvent.custom('e'),
    payload: {'foo': 1},
  );

  Uint8List binPayload() => Uint8List.fromList([1]);

  setUp(() {
    // No longer const — MessageSerializer is mutable.
    serializer = MessageSerializer();
  });

  group('MessageSerializer', () {
    group('JSON', () {
      test('encodes general pushes', () {
        expect(serializer.encode(exampleMsg),
            equals('["0","1","t","e",{"foo":1}]'));
      });

      test('decodes', () {
        final decoded = serializer.decode('["0","1","t","e",{"foo":1}]');
        expect(decoded.joinRef, equals('0'));
        expect(decoded.ref, equals('1'));
        expect(decoded.topic, equals('t'));
        expect(decoded.event.value, equals('e'));
        expect(decoded.payload, equals({'foo': 1}));
      });
    });

    group('Binary', () {
      test('encodes', () {
        final message = Message(
          joinRef: '0',
          ref: '1',
          topic: 't',
          event: PhoenixChannelEvent.custom('e'),
          payload: binPayload(),
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0,
          1,
          1,
          1,
          1,
          ...utf8.encode('0'),
          ...utf8.encode('1'),
          ...utf8.encode('t'),
          ...utf8.encode('e'),
          1,
        ]);

        expect(encoded, equals(expected));
      });

      test('encodes variable length segments', () {
        final message = Message(
          joinRef: '10',
          ref: '1',
          topic: 'top',
          event: PhoenixChannelEvent.custom('ev'),
          payload: binPayload(),
        );

        final encoded = serializer.encode(message);
        final expected = Uint8List.fromList([
          0,
          2,
          1,
          3,
          2,
          ...utf8.encode('10'),
          ...utf8.encode('1'),
          ...utf8.encode('top'),
          ...utf8.encode('ev'),
          1,
        ]);

        expect(encoded, equals(expected));
      });

      test('decodes push', () {
        final message = Uint8List.fromList([
          0,
          3,
          3,
          10,
          ...utf8.encode('123'),
          ...utf8.encode('top'),
          ...utf8.encode('some-event'),
          1,
          1,
        ]);

        final decoded = serializer.decode(message);
        expect(decoded.joinRef, equals('123'));
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });

      test('decodes reply', () {
        final message = Uint8List.fromList([
          1,
          3,
          2,
          3,
          2,
          ...utf8.encode('100'),
          ...utf8.encode('12'),
          ...utf8.encode('top'),
          ...utf8.encode('ok'),
          1,
          1,
        ]);

        final decoded = serializer.decode(message);
        expect(decoded.joinRef, equals('100'));
        expect(decoded.ref, equals('12'));
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('phx_reply'));
        expect(decoded.payload, isA<Map>());
        expect(decoded.payload?['status'], equals('ok'));
        expect(
            decoded.payload?['response'], equals(Uint8List.fromList([1, 1])));
      });

      test('decodes broadcast', () {
        final message = Uint8List.fromList([
          2,
          3,
          10,
          ...utf8.encode('top'),
          ...utf8.encode('some-event'),
          1,
          1,
        ]);

        final decoded = serializer.decode(message);
        expect(decoded.joinRef, isNull);
        expect(decoded.ref, isNull);
        expect(decoded.topic, equals('top'));
        expect(decoded.event.value, equals('some-event'));
        expect(decoded.payload, equals(Uint8List.fromList([1, 1])));
      });
    });

    group('Error cases', () {
      test('throws ArgumentError with runtime type on invalid input', () {
        expect(
          () => serializer.decode(123),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              // New message format from the refactored decode().
              contains('int'),
            ),
          ),
        );
      });

      test('throws ArgumentError — not the old "non-string" wording', () {
        expect(
          () => serializer.decode(123),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'message',
              // Confirm the old message is gone so tests don't pass vacuously.
              isNot(contains('non-string or a non-list of integers')),
            ),
          ),
        );
      });

      test('handles malformed JSON', () {
        expect(
          () => serializer.decode('{"bad json"}'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('Edge cases', () {
      test('handles empty binary payload', () {
        final message = Uint8List.fromList([
          2,
          3,
          5,
          ...utf8.encode('top'),
          ...utf8.encode('event'),
        ]);

        final decoded = serializer.decode(message);
        expect(decoded.payload, isEmpty);
      });

      test('handles custom payload decoder', () {
        Map<String, dynamic> customDecoder(Uint8List payload) => {
              'nested': {'data': 42},
              'list': [
                {'item': 1},
                {'item': 2},
              ],
            };

        // Use serializer: instead of the removed payloadDecoder shortcut.
        final s = MessageSerializer(payloadDecoder: customDecoder);

        final message = Uint8List.fromList([
          2,
          3,
          5,
          ...utf8.encode('top'),
          ...utf8.encode('event'),
          1,
        ]);

        final decoded = s.decode(message);
        expect(decoded.payload?['nested']['data'], equals(42));
        expect(decoded.payload?['list'][0]['item'], equals(1));
        expect(decoded.payload?['list'][1]['item'], equals(2));
      });
    });

    // ── name field ──────────────────────────────────────────────────────────

    group('name', () {
      test('defaults to "json"', () {
        expect(MessageSerializer().name, equals('json'));
      });

      test('is preserved by copyWith', () {
        final copy = MessageSerializer(name: 'toon').copyWith();
        expect(copy.name, equals('toon'));
      });

      test('can be overridden by copyWith', () {
        final copy = MessageSerializer(name: 'json').copyWith(name: 'toon');
        expect(copy.name, equals('toon'));
      });

      test('appears in toString', () {
        expect(
          MessageSerializer(name: 'toon').toString(),
          contains('toon'),
        );
      });
    });

    // ── runtime codec swapping ───────────────────────────────────────────────

    group('runtime encoder/decoder swap', () {
      test('individual setter — decoder', () {
        var called = false;
        serializer.decoder = (raw) {
          called = true;
          return jsonDecode(raw);
        };
        serializer.decode('["0","1","t","e",{}]');
        expect(called, isTrue);
      });

      test('individual setter — encoder', () {
        var called = false;
        serializer.encoder = (v) {
          called = true;
          return jsonEncode(v);
        };
        serializer.encode(exampleMsg);
        expect(called, isTrue);
      });

      test('individual setter — payloadDecoder', () {
        var called = false;
        serializer.payloadDecoder = (bytes) {
          called = true;
          return <String, dynamic>{};
        };

        final msg = Uint8List.fromList([
          2,
          3,
          5,
          ...utf8.encode('top'),
          ...utf8.encode('event'),
          1,
        ]);
        serializer.decode(msg);
        expect(called, isTrue);
      });

      test('update() atomically swaps encoder and decoder', () {
        final encCalls = <String>[];
        final decCalls = <String>[];

        serializer.update(
          encoder: (v) {
            encCalls.add('new');
            return jsonEncode(v);
          },
          decoder: (r) {
            decCalls.add('new');
            return jsonDecode(r);
          },
        );

        serializer.encode(exampleMsg);
        serializer.decode('["0","1","t","e",{}]');

        expect(encCalls, equals(['new']));
        expect(decCalls, equals(['new']));
      });

      test('update() with null arguments leaves existing callbacks intact', () {
        var decoderCalled = false;
        serializer.decoder = (r) {
          decoderCalled = true;
          return jsonDecode(r);
        };

        // Only update encoder — decoder must be untouched.
        serializer.update(encoder: jsonEncode);
        serializer.decode('["0","1","t","e",{}]');

        expect(decoderCalled, isTrue);
      });

      test('update(clearPayloadDecoder: true) removes payload decoder', () {
        serializer.payloadDecoder = (_) => <String, dynamic>{'x': 1};
        expect(serializer.payloadDecoder, isNotNull);

        serializer.update(clearPayloadDecoder: true);
        expect(serializer.payloadDecoder, isNull);
      });

      test(
          'update() ignores payloadDecoder when clearPayloadDecoder is false and value is null',
          () {
        final original = serializer.payloadDecoder;
        serializer.update(); // nothing passed
        expect(serializer.payloadDecoder, equals(original));
      });
    });

    // ── copyWith ─────────────────────────────────────────────────────────────

    group('copyWith', () {
      test('returns a new independent instance', () {
        final copy = serializer.copyWith();
        expect(copy, isNot(same(serializer)));
      });

      test('inherits all callbacks when called with no arguments', () {
        var encCalled = false;
        var decCalled = false;
        serializer
          ..encoder = (v) {
            encCalled = true;
            return jsonEncode(v);
          }
          ..decoder = (r) {
            decCalled = true;
            return jsonDecode(r);
          };

        final copy = serializer.copyWith();
        copy.encode(exampleMsg);
        copy.decode('["0","1","t","e",{}]');

        expect(encCalled, isTrue);
        expect(decCalled, isTrue);
      });

      test('overrides only specified callbacks', () {
        var originalDecCalled = false;
        var newEncCalled = false;
        serializer.decoder = (r) {
          originalDecCalled = true;
          return jsonDecode(r);
        };

        final copy = serializer.copyWith(
          encoder: (v) {
            newEncCalled = true;
            return jsonEncode(v);
          },
        );

        copy.encode(exampleMsg);
        copy.decode('["0","1","t","e",{}]');

        expect(newEncCalled, isTrue);
        expect(originalDecCalled, isTrue);
      });

      test('clearPayloadDecoder removes inherited payload decoder', () {
        serializer.payloadDecoder = (_) => <String, dynamic>{};
        final copy = serializer.copyWith(clearPayloadDecoder: true);
        expect(copy.payloadDecoder, isNull);
      });

      test('mutations on copy do not affect original', () {
        final copy = serializer.copyWith();
        copy.decoder = (r) => jsonDecode(r); // replace on copy

        var originalDecCalled = false;
        serializer.decoder = (r) {
          originalDecCalled = true;
          return jsonDecode(r);
        };

        // Decode on the original — its callback must still fire.
        serializer.decode('["0","1","t","e",{}]');
        expect(originalDecCalled, isTrue);
      });
    });
  });

  // ── SerializerRegistry ────────────────────────────────────────────────────

  group('SerializerRegistry', () {
    late SerializerRegistry registry;

    setUp(() {
      registry = SerializerRegistry.instance;
      // Clean up any registrations added by tests.
      addTearDown(() {
        if (registry.has('custom')) registry.unregister('custom');
        if (registry.has('toon-test')) registry.unregister('toon-test');
      });
    });

    test('"json" is pre-registered', () {
      expect(registry.has('json'), isTrue);
    });

    test('"binary" is pre-registered', () {
      expect(registry.has('binary'), isTrue);
    });

    test('resolve("json") returns a MessageSerializer named "json"', () {
      final s = registry.resolve('json');
      expect(s, isA<MessageSerializer>());
      expect(s.name, equals('json'));
    });

    test('each resolve() call returns a fresh instance', () {
      final a = registry.resolve('json');
      final b = registry.resolve('json');
      expect(a, isNot(same(b)));
    });

    test('register() makes a codec resolvable', () {
      registry.register('custom', () => MessageSerializer(name: 'custom'));
      expect(registry.has('custom'), isTrue);
      expect(registry.resolve('custom').name, equals('custom'));
    });

    test('register() overwrites an existing entry', () {
      registry.register('custom', () => MessageSerializer(name: 'custom-v1'));
      registry.register('custom', () => MessageSerializer(name: 'custom-v2'));
      expect(registry.resolve('custom').name, equals('custom-v2'));
    });

    test('unregister() removes a custom codec', () {
      registry.register('custom', () => MessageSerializer(name: 'custom'));
      registry.unregister('custom');
      expect(registry.has('custom'), isFalse);
    });

    test('unregister("json") throws StateError', () {
      expect(() => registry.unregister('json'), throwsA(isA<StateError>()));
    });

    test('resolve() throws ArgumentError for unknown codec', () {
      expect(
        () => registry.resolve('does-not-exist'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('does-not-exist'),
          ),
        ),
      );
    });

    test('registeredNames includes built-ins and custom codecs', () {
      registry.register(
          'toon-test', () => MessageSerializer(name: 'toon-test'));
      expect(registry.registeredNames,
          containsAll(['json', 'binary', 'toon-test']));
    });

    test('register() throws on blank name', () {
      expect(
        () => registry.register('  ', () => MessageSerializer()),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('resolved instance is independent — mutations do not affect registry',
        () {
      registry.register(
        'toon-test',
        () => MessageSerializer(name: 'toon-test'),
      );

      final s1 = registry.resolve('toon-test');
      s1.decoder = (r) => throw StateError('mutated');

      // A fresh resolve must not carry the mutation from s1.
      final s2 = registry.resolve('toon-test');
      expect(() => s2.decode('["0","1","t","e",{}]'), returnsNormally);
    });
  });

  // ── PhoenixSocketOptions codec resolution ─────────────────────────────────

  group('PhoenixSocketOptions.resolveSerializer', () {
    setUp(() {
      SerializerRegistry.instance.register(
        'toon-test',
        () => MessageSerializer(name: 'toon-test'),
      );
    });

    tearDown(() {
      if (SerializerRegistry.instance.has('toon-test')) {
        SerializerRegistry.instance.unregister('toon-test');
      }
    });

    test('defaults to "json" when neither codec nor serializer is given', () {
      final s = PhoenixSocketOptions().resolveSerializer();
      expect(s.name, equals('json'));
    });

    test('resolves by codec name', () {
      final s = PhoenixSocketOptions(codec: 'toon-test').resolveSerializer();
      expect(s.name, equals('toon-test'));
    });

    test('returns the provided serializer directly', () {
      final custom = MessageSerializer(name: 'mine');
      final s = PhoenixSocketOptions(serializer: custom).resolveSerializer();
      expect(s, same(custom));
    });

    test('asserts when both codec and serializer are provided', () {
      expect(
        () => PhoenixSocketOptions(
          codec: 'json',
          serializer: MessageSerializer(),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
        'each call to resolveSerializer returns a fresh instance for named codecs',
        () {
      final opts = PhoenixSocketOptions(codec: 'toon-test');
      final a = opts.resolveSerializer();
      final b = opts.resolveSerializer();
      expect(a, isNot(same(b)));
    });
  });
}
