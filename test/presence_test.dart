import 'package:phoenix_socket/phoenix_socket.dart';
import 'package:test/test.dart';

import 'helpers/socket_harness.dart';

const String _topic = 'presence:lobby';

Map<String, dynamic> _meta(String ref, [Map<String, dynamic> extra = const {}]) =>
    {'phx_ref': ref, ...extra};

Map<String, dynamic> _state(
  Map<String, List<Map<String, dynamic>>> metasByUser,
) =>
    metasByUser.map(
      (user, metas) => MapEntry(user, <String, dynamic>{'metas': metas}),
    );

Map<String, dynamic> _diff({
  Map<String, List<Map<String, dynamic>>> joins = const {},
  Map<String, List<Map<String, dynamic>>> leaves = const {},
}) =>
    {'joins': _state(joins), 'leaves': _state(leaves)};

List<String> _refs(Presence presence) =>
    presence.metas.map((meta) => meta.phxRef).toList();

void main() {
  late SocketHarness harness;

  setUp(() async {
    harness = SocketHarness();
    await harness.connect();
  });

  tearDown(() => harness.dispose());

  void deliver(
    String event,
    dynamic payload, {
    PhoenixChannel? onChannel,
  }) {
    harness.deliver(
      onChannel?.topic ?? _topic,
      event,
      payload,
      joinRef: onChannel?.joinRef ?? harness.socket.channels[_topic]?.joinRef,
    );
  }

  Future<PhoenixPresence> joinedPresence({
    Map<String, String>? eventNames,
  }) async {
    final channel = harness.addChannel(_topic);
    final presence = eventNames == null
        ? PhoenixPresence(channel: channel)
        : PhoenixPresence(channel: channel, eventNames: eventNames);
    addTearDown(presence.dispose);
    await harness.join(channel);
    return presence;
  }

  Future<PhoenixPresence> syncedPresence({
    Map<String, String>? eventNames,
  }) async {
    final presence = await joinedPresence(eventNames: eventNames);
    deliver('presence_state', <String, dynamic>{});
    await waitUntil(() => !presence.inPendingSyncState);
    return presence;
  }

  group('state snapshots', () {
    test('populates state and syncs once', () async {
      final presence = await joinedPresence();
      var syncs = 0;
      presence.onSync = () => syncs++;

      deliver(
        'presence_state',
        _state({
          'user-1': [_meta('ref-1')],
          'user-2': [_meta('ref-2', {'online_at': '123'})],
        }),
      );

      await waitUntil(() => presence.state.isNotEmpty);
      expect(presence.state.keys, unorderedEquals(['user-1', 'user-2']));
      expect(_refs(presence.state['user-1']!), ['ref-1']);
      expect(_refs(presence.state['user-2']!), ['ref-2']);
      expect(presence.state['user-2']!.metas.single.data['online_at'], '123');
      expect(syncs, 1);
    });

    test('removes members absent from the new snapshot', () async {
      final presence = await joinedPresence();
      final leaves = <String, Presence>{};
      presence.onLeave = (key, current, left) => leaves[key] = left;

      deliver(
        'presence_state',
        _state({
          'user-1': [_meta('ref-1')],
          'user-2': [_meta('ref-2')],
        }),
      );
      await waitUntil(() => presence.state.length == 2);

      deliver(
        'presence_state',
        _state({
          'user-1': [_meta('ref-1')],
        }),
      );

      await waitUntil(() => !presence.state.containsKey('user-2'));
      expect(presence.state.keys, ['user-1']);
      expect(leaves.keys, ['user-2']);
      expect(_refs(leaves['user-2']!), ['ref-2']);
    });

    test('clears state on an empty snapshot', () async {
      final presence = await joinedPresence();
      final left = <String>[];
      var syncs = 0;
      presence.onLeave = (key, current, leaving) => left.add(key);
      presence.onSync = () => syncs++;

      deliver(
        'presence_state',
        _state({
          'user-1': [_meta('ref-1')],
          'user-2': [_meta('ref-2')],
        }),
      );
      await waitUntil(() => presence.state.length == 2);

      deliver('presence_state', <String, dynamic>{});

      await waitUntil(() => presence.state.isEmpty);
      expect(left, unorderedEquals(['user-1', 'user-2']));
      expect(syncs, 2);
    });
  });

  group('diff application', () {
    test('applies every join in a single frame', () async {
      final presence = await syncedPresence();
      final joined = <String>[];
      presence.onJoin = (key, current, joining) => joined.add(key);

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-a')],
            'user-b': [_meta('ref-b')],
          },
        ),
      );

      await waitUntil(() => presence.state.length == 2, timeout: const Duration(seconds: 1));
      expect(presence.state.keys, unorderedEquals(['user-a', 'user-b']));
      expect(joined, unorderedEquals(['user-a', 'user-b']));
    });

    test('applies every leave in a single frame', () async {
      final presence = await syncedPresence();
      final left = <String>[];
      presence.onLeave = (key, current, leaving) => left.add(key);

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-a')],
            'user-b': [_meta('ref-b')],
          },
        ),
      );
      await waitUntil(() => presence.state.length == 2);

      deliver(
        'presence_diff',
        _diff(
          leaves: {
            'user-a': [_meta('ref-a')],
            'user-b': [_meta('ref-b')],
          },
        ),
      );

      await waitUntil(() => presence.state.isEmpty, timeout: const Duration(seconds: 1));
      expect(left, unorderedEquals(['user-a', 'user-b']));
    });

    test('merges metadata when an existing presence rejoins', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-1')],
        }),
      );
      await waitUntil(() => presence.state.containsKey('user-a'));

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-2')],
          },
        ),
      );

      await waitUntil(
        () => (presence.state['user-a']?.metas.length ?? 0) == 2,
        timeout: const Duration(seconds: 1),
      );
      expect(_refs(presence.state['user-a']!), unorderedEquals(['ref-1', 'ref-2']));
    });

    test('removes only the metadata listed in a leave', () async {
      final presence = await syncedPresence();
      final leaving = <String, Presence>{};
      presence.onLeave = (key, current, left) => leaving[key] = left;

      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-1'), _meta('ref-2')],
        }),
      );
      await waitUntil(() => (presence.state['user-a']?.metas.length ?? 0) == 2);

      deliver(
        'presence_diff',
        _diff(
          leaves: {
            'user-a': [_meta('ref-1')],
          },
        ),
      );

      await waitUntil(
        () => (presence.state['user-a']?.metas.length ?? 0) == 1,
        timeout: const Duration(seconds: 1),
      );
      expect(_refs(presence.state['user-a']!), ['ref-2']);
      expect(_refs(leaving['user-a']!), ['ref-1']);
    });

    test('removes a presence when its last metadata leaves', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-1')],
        }),
      );
      await waitUntil(() => presence.state.containsKey('user-a'));

      deliver(
        'presence_diff',
        _diff(
          leaves: {
            'user-a': [_meta('ref-1')],
          },
        ),
      );

      await waitUntil(
        () => !presence.state.containsKey('user-a'),
        timeout: const Duration(seconds: 1),
      );
      expect(presence.state, isEmpty);
    });
  });

  group('pending diffs and sync state', () {
    test('is out of sync until the first snapshot', () async {
      final presence = await joinedPresence();
      expect(presence.inPendingSyncState, isTrue);

      deliver('presence_state', _state({'user-a': [_meta('ref-a')]}));
      await waitUntil(() => !presence.inPendingSyncState);
      expect(presence.inPendingSyncState, isFalse);
    });

    test('buffers a diff received before the first snapshot', () async {
      final presence = await joinedPresence();
      var syncs = 0;
      presence.onSync = () => syncs++;

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-a')],
          },
        ),
      );
      await harness.pump();

      expect(presence.state, isEmpty);
      expect(syncs, 0);

      deliver('presence_state', _state({'user-b': [_meta('ref-b')]}));

      await waitUntil(() => presence.state.length == 2);
      expect(presence.state.keys, unorderedEquals(['user-a', 'user-b']));
      expect(syncs, 1);
    });

    test('buffers a diff received after a rejoin', () async {
      final channel = harness.socket.addChannel(
        topic: _topic,
        timeout: const Duration(milliseconds: 50),
      );
      final presence = PhoenixPresence(channel: channel);
      addTearDown(presence.dispose);
      await harness.join(channel);

      deliver('presence_state', _state({'user-a': [_meta('ref-a')]}));
      await waitUntil(() => !presence.inPendingSyncState);
      final joinRefBeforeRejoin = channel.joinRef;

      channel.triggerError(
        PhoenixException(
          socketError: PhoenixSocketErrorEvent(
            error: StateError('simulated socket error'),
          ),
        ),
      );
      await waitUntil(() => harness.sentOf('phx_join').length >= 2);
      harness.replyTo(harness.sentOf('phx_join').last);
      await waitUntil(
        () => channel.state == PhoenixChannelState.joined,
      );

      expect(channel.joinRef, isNot(joinRefBeforeRejoin));
      expect(presence.inPendingSyncState, isTrue);

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-b': [_meta('ref-b')],
          },
        ),
      );
      await harness.pump();
      expect(presence.state.keys, ['user-a']);

      deliver('presence_state', _state({'user-c': [_meta('ref-c')]}));
      await waitUntil(() => presence.state.length == 2);
      expect(presence.state.keys, unorderedEquals(['user-b', 'user-c']));
    });
  });

  group('callbacks', () {
    test('reports join arguments for a new presence', () async {
      final presence = await syncedPresence();
      String? joinedKey;
      Presence? prior;
      Presence? joining;
      presence.onJoin = (key, current, presence) {
        joinedKey = key;
        prior = current;
        joining = presence;
      };

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-a')],
          },
        ),
      );

      await waitUntil(() => joinedKey != null);
      expect(joinedKey, 'user-a');
      expect(prior, isNull);
      expect(_refs(joining!), ['ref-a']);
    });

    test('reports leave arguments with remaining metadata', () async {
      final presence = await syncedPresence();
      Presence? current;
      Presence? leaving;
      presence.onLeave = (key, remaining, left) {
        current = remaining;
        leaving = left;
      };

      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-1'), _meta('ref-2')],
        }),
      );
      await waitUntil(() => (presence.state['user-a']?.metas.length ?? 0) == 2);

      deliver(
        'presence_diff',
        _diff(
          leaves: {
            'user-a': [_meta('ref-1')],
          },
        ),
      );

      await waitUntil(() => leaving != null);
      expect(_refs(current!), ['ref-2']);
      expect(_refs(leaving!), ['ref-1']);
    });

    test('syncs once for a diff with one join and one leave', () async {
      final presence = await syncedPresence();
      var syncs = 0;
      presence.onSync = () => syncs++;

      deliver(
        'presence_state',
        _state({'user-a': [_meta('ref-a')]}),
      );
      await waitUntil(() => presence.state.containsKey('user-a'));
      syncs = 0;

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-b': [_meta('ref-b')],
          },
          leaves: {
            'user-a': [_meta('ref-a')],
          },
        ),
      );

      await waitUntil(() => presence.state.containsKey('user-b'));
      expect(presence.state.containsKey('user-a'), isFalse);
      expect(syncs, 1);
    });
  });

  group('event names', () {
    test('honors custom state and diff names', () async {
      final presence = await joinedPresence(
        eventNames: const {'state': 'my_state', 'diff': 'my_diff'},
      );
      expect(presence.stateEventName, 'my_state');
      expect(presence.diffEventName, 'my_diff');

      deliver('my_state', _state({'user-a': [_meta('ref-a')]}));
      await waitUntil(() => presence.state.containsKey('user-a'));

      deliver(
        'my_diff',
        _diff(
          joins: {
            'user-b': [_meta('ref-b')],
          },
        ),
      );
      await waitUntil(() => presence.state.containsKey('user-b'));
      expect(presence.state.keys, unorderedEquals(['user-a', 'user-b']));
    });

    test('keeps the default diff name when only state is overridden', () async {
      final presence = await joinedPresence(
        eventNames: const {'state': 'my_state'},
      );
      expect(presence.stateEventName, 'my_state');
      expect(presence.diffEventName, 'presence_diff');

      deliver('my_state', _state({'user-a': [_meta('ref-a')]}));
      await waitUntil(() => presence.state.containsKey('user-a'));

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-b': [_meta('ref-b')],
          },
        ),
      );
      await waitUntil(() => presence.state.containsKey('user-b'));
    });

    test('ignores unrelated channel messages', () async {
      final presence = await syncedPresence();
      var syncs = 0;
      presence.onSync = () => syncs++;

      deliver('chat:message', {'body': 'hello'});
      await harness.pump();

      expect(presence.state, isEmpty);
      expect(syncs, 0);
    });
  });

  group('list projection', () {
    test('returns presence objects by default', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-a')],
          'user-b': [_meta('ref-b')],
        }),
      );
      await waitUntil(() => presence.state.length == 2);

      final listed = presence.list(presence.state);
      expect(listed, unorderedEquals(presence.state.values));
      expect(listed.every((entry) => entry is Presence), isTrue);
    });

    test('projects through a chooser', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-a')],
          'user-b': [_meta('ref-b')],
        }),
      );
      await waitUntil(() => presence.state.length == 2);

      final keys = presence.list(presence.state, (key, entry) => key);
      expect(keys, unorderedEquals(['user-a', 'user-b']));
    });

    test('returns an empty list for empty state', () async {
      final presence = await syncedPresence();
      expect(presence.list(presence.state), isEmpty);
      expect(presence.list(<String, Presence>{}), isEmpty);
    });
  });

  group('clone and state isolation', () {
    test('clone does not share metadata with the original', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-a', {'online_at': '123'})],
        }),
      );
      await waitUntil(() => presence.state.containsKey('user-a'));

      final original = presence.state['user-a']!;
      final clone = original.clone();
      clone.metas.clear();
      clone.metas.add(
        PhoenixPresenceMeta.fromJson({'phx_ref': 'other'}),
      );

      expect(_refs(original), ['ref-a']);
      expect(original.metas.single.data['online_at'], '123');

      final meta = original.metas.single;
      final metaClone = meta.clone()..data['online_at'] = 'changed';
      expect(meta.data['online_at'], '123');
      expect(metaClone.data['online_at'], 'changed');
    });

    test('captured state is not mutated by later diffs', () async {
      final presence = await syncedPresence();
      deliver(
        'presence_state',
        _state({
          'user-a': [_meta('ref-1')],
        }),
      );
      await waitUntil(() => presence.state.containsKey('user-a'));

      final captured = presence.state;
      final capturedPresence = captured['user-a']!;

      deliver(
        'presence_diff',
        _diff(
          joins: {
            'user-a': [_meta('ref-2')],
          },
        ),
      );
      await waitUntil(() => (presence.state['user-a']?.metas.length ?? 0) == 2);

      expect(_refs(capturedPresence), ['ref-1']);
      expect(captured.keys, ['user-a']);
      expect(_refs(presence.state['user-a']!), unorderedEquals(['ref-1', 'ref-2']));
    });
  });

  group('disposal', () {
    test('stops processing messages after dispose', () async {
      final presence = await joinedPresence();
      var syncs = 0;
      presence.onSync = () => syncs++;
      presence.dispose();

      deliver('presence_state', _state({'user-a': [_meta('ref-a')]}));
      await harness.pump();

      expect(presence.state, isEmpty);
      expect(syncs, 0);
    });
  });
}
