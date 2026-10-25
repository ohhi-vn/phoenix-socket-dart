import 'package:phoenix_socket/src/internal/pending_replies.dart';
import 'package:test/test.dart';

void main() {
  group('PendingReplies', () {
    test('registers and exposes pending state', () {
      final replies = PendingReplies();
      final completer = replies.register('1', owner: 'socket');

      expect(replies.length, 1);
      expect(replies.refs, ['1']);
      expect(replies.contains('1'), isTrue);
      expect(replies.contains('2'), isFalse);
      expect(replies.futureFor('1'), same(completer.future));
      expect(replies.futureFor('2'), isNull);
      expect(replies.ownerOf('1'), 'socket');
      expect(replies.ownerOf('2'), isNull);
    });

    test('fails the earlier waiter when a ref is re-registered', () async {
      final replies = PendingReplies();
      final first = replies.register('1', owner: 'first');
      final firstError = expectLater(
        first.future,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('superseded'),
          ),
        ),
      );

      final second = replies.register('1', owner: 'second');

      await firstError;
      expect(replies.length, 1);
      expect(replies.ownerOf('1'), 'second');
      expect(replies.futureFor('1'), same(second.future));
    });

    test('completes and removes a waiter', () async {
      final replies = PendingReplies();
      final completer = replies.register('1', owner: 'socket');

      final completed = replies.complete('1', const {'ok': true});

      expect(completed, isTrue);
      expect(await completer.future, {'ok': true});
      expect(replies.length, 0);
      expect(replies.contains('1'), isFalse);
      expect(replies.ownerOf('1'), isNull);
    });

    test('fails and removes a waiter', () async {
      final replies = PendingReplies();
      final completer = replies.register('1', owner: 'socket');
      final error = StateError('reply failed');
      final expectation = expectLater(completer.future, throwsA(same(error)));

      final completed = replies.completeError('1', error);

      expect(completed, isTrue);
      await expectation;
      expect(replies.length, 0);
      expect(replies.contains('1'), isFalse);
    });

    test('completing an unknown ref reports nothing completed', () {
      final replies = PendingReplies();

      expect(replies.complete('missing', null), isFalse);
      expect(replies.completeError('missing', StateError('nope')), isFalse);
      expect(replies.length, 0);
    });

    test('completeAllWithError fails every waiter and clears owners', () async {
      final replies = PendingReplies();
      final first = replies.register('1', owner: 'first');
      final second = replies.register('2', owner: 'second');
      final error = StateError('socket closed');
      final expectations = [
        expectLater(first.future, throwsA(same(error))),
        expectLater(second.future, throwsA(same(error))),
      ];

      replies.completeAllWithError(error);

      await Future.wait(expectations);
      expect(replies.length, 0);
      expect(replies.refs, isEmpty);
      expect(replies.ownerOf('1'), isNull);
      expect(replies.ownerOf('2'), isNull);
    });

    test('discard drops a waiter without completing it', () async {
      final replies = PendingReplies();
      final completer = replies.register('1', owner: 'socket');
      var completed = false;
      completer.future.whenComplete(() => completed = true).ignore();

      replies.discard('1');
      await pumpEventQueue();

      expect(replies.length, 0);
      expect(replies.contains('1'), isFalse);
      expect(completed, isFalse);
    });

    test('remove returns the completer without completing it', () async {
      final replies = PendingReplies();
      final completer = replies.register('1', owner: 'socket');

      final removed = replies.remove('1');
      await pumpEventQueue();

      expect(removed, same(completer));
      expect(replies.length, 0);
      expect(completer.isCompleted, isFalse);
      expect(replies.remove('1'), isNull);
    });
  });
}
