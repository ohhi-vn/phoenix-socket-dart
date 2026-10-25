import 'dart:async';

import 'package:phoenix_socket/src/internal/resource_scope.dart';
import 'package:test/test.dart';

void main() {
  group('ResourceScope', () {
    test('runs releases in registration order', () async {
      final scope = ResourceScope();
      final releases = <String>[];

      scope.add(() => releases.add('first'));
      scope.add(() async => releases.add('second'));
      scope.add(() => releases.add('third'));

      expect(scope.isClosed, isFalse);
      await scope.close();

      expect(releases, ['first', 'second', 'third']);
      expect(scope.isClosed, isTrue);
    });

    test('close is idempotent', () async {
      final scope = ResourceScope();
      var runs = 0;
      scope.add(() => runs++);

      await scope.close();
      await scope.close();

      expect(runs, 1);
    });

    test('releases registrations made after close immediately', () async {
      final scope = ResourceScope();
      var runs = 0;

      await scope.close();
      scope.add(() => runs++);

      expect(runs, 1);
    });

    test('awaits asynchronous releases registered after close', () async {
      final errors = <Object>[];
      final scope = ResourceScope(
        onError: (error, stackTrace) => errors.add(error),
      );
      var completed = false;

      await scope.close();
      scope.add(() async {
        await Future<void>.delayed(Duration.zero);
        completed = true;
      });

      await pumpEventQueue();
      expect(completed, isTrue);
      expect(errors, isEmpty);
    });

    test('a failing release does not block later releases', () async {
      final failures = <Object>[];
      final stackTraces = <StackTrace>[];
      final scope = ResourceScope(
        onError: (error, stackTrace) {
          failures.add(error);
          stackTraces.add(stackTrace);
        },
      );
      final releases = <String>[];

      scope.add(() {
        releases.add('before');
      });
      scope.add(() => throw StateError('teardown failed'));
      scope.add(() {
        releases.add('after');
      });

      await scope.close();

      expect(releases, ['before', 'after']);
      expect(failures.single, isA<StateError>());
      expect((failures.single as StateError).message, 'teardown failed');
      expect(stackTraces.single, isNotNull);
    });

    test('asynchronous release failures reach the error handler', () async {
      final failures = <Object>[];
      final scope = ResourceScope(
        onError: (error, stackTrace) => failures.add(error),
      );
      var ranAfter = false;

      scope.add(() async => throw StateError('async teardown failed'));
      scope.add(() {
        ranAfter = true;
      });

      await scope.close();

      expect(failures.single, isA<StateError>());
      expect(ranAfter, isTrue);
    });

    test('works without an error handler', () async {
      final scope = ResourceScope();
      scope.add(() => throw StateError('ignored'));

      await scope.close();

      expect(scope.isClosed, isTrue);
    });

    test('errors from immediate releases reach the handler', () async {
      final failures = <Object>[];
      final scope = ResourceScope(
        onError: (error, stackTrace) => failures.add(error),
      );
      await scope.close();

      scope.add(() => throw StateError('late failure'));
      scope.add(() async => throw StateError('late async failure'));

      await pumpEventQueue();
      expect(failures.length, 2);
    });
  });
}
