import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';

void main() {
  group('SessionStore', () {
    test('starts empty', () async {
      final store = SessionStore(InMemorySecureStore());
      expect(store.accessToken, isNull);
      expect(store.accessTokenExpiresAt, isNull);
      expect(await store.hasPersistedSession(), isFalse);
    });

    test('saveSession persists ids and refresh token; access token stays in memory', () async {
      final secure = InMemorySecureStore();
      final store = SessionStore(secure);

      await store.saveSession(tokenResponse());

      expect(store.accessToken, 'access-1');
      expect(store.accessTokenExpiresAt, DateTime.utc(2026, 10, 8, 10, 15));
      expect(secure.values, {
        SessionKeys.refreshToken: 'refresh-1',
        SessionKeys.sessionId: 'session-1',
        SessionKeys.deviceId: 'device-1',
      });
      expect(secure.values.values, isNot(contains('access-1')));
      expect(await store.hasPersistedSession(), isTrue);
      expect(await store.readRefreshToken(), 'refresh-1');
      expect(await store.readSessionId(), 'session-1');
      expect(await store.readDeviceId(), 'device-1');
    });

    test(
      'a new store instance (process restart) has no access token',
      () async {
        final secure = InMemorySecureStore();
        await SessionStore(secure).saveSession(tokenResponse());

        final restarted = SessionStore(secure);
        expect(restarted.accessToken, isNull);
        expect(await restarted.hasPersistedSession(), isTrue);
      },
    );

    test('saveRefreshedTokens persists the rotated refresh token before exposing '
        'the access token', () async {
      final secure = RecordingSecureStore();
      final store = SessionStore(secure);
      await store.saveSession(tokenResponse());
      secure.log.clear();

      // While the rotated refresh token is being written, the new access token
      // must not be visible yet (a concurrent request could otherwise use it).
      String? accessDuringWrite;
      secure.afterWrite = () async {
        accessDuringWrite = store.accessToken;
      };
      final saved = await store.saveRefreshedTokens(
        refreshResponse(),
        expectedGeneration: store.generation,
      );

      expect(saved, isTrue);
      expect(secure.log, ['write ${SessionKeys.refreshToken}=refresh-2']);
      expect(accessDuringWrite, 'access-1');
      expect(store.accessToken, 'access-2');
      expect(await store.readRefreshToken(), 'refresh-2');
    });

    test(
      'saveRefreshedTokens refuses to resurrect a cleared session',
      () async {
        final secure = InMemorySecureStore();
        final store = SessionStore(secure);
        await store.saveSession(tokenResponse());
        final generation = store.generation;

        await store.clear();
        final saved = await store.saveRefreshedTokens(
          refreshResponse(),
          expectedGeneration: generation,
        );

        expect(saved, isFalse);
        expect(store.accessToken, isNull);
        expect(secure.values, isEmpty);
      },
    );

    test('a sign-out racing the rotated-token write is undone', () async {
      final secure = RecordingSecureStore();
      final store = SessionStore(secure);
      await store.saveSession(tokenResponse());
      secure.afterWrite = store.clear;

      final saved = await store.saveRefreshedTokens(
        refreshResponse(),
        expectedGeneration: store.generation,
      );

      expect(saved, isFalse);
      expect(store.accessToken, isNull);
      expect(await store.readRefreshToken(), isNull);
    });

    test(
      'clear wipes memory and the session keys and bumps the generation',
      () async {
        final secure = InMemorySecureStore();
        final store = SessionStore(secure);
        await store.saveSession(tokenResponse());
        final before = store.generation;

        await store.clear();

        expect(store.accessToken, isNull);
        expect(store.accessTokenExpiresAt, isNull);
        expect(secure.values, isEmpty);
        expect(store.generation, before + 1);
        expect(await store.hasPersistedSession(), isFalse);
      },
    );

    test('clear leaves values that are not part of the session', () async {
      // The pending check-in lives in the same store and must outlive a session
      // that ended under it (it is sent once the person signs in again).
      final secure = InMemorySecureStore({'checkin.pending': '{"v":1}'});
      final store = SessionStore(secure);
      await store.saveSession(tokenResponse());

      await store.clear();

      expect(secure.values, {'checkin.pending': '{"v":1}'});
      expect(await store.hasPersistedSession(), isFalse);
    });

    test(
      'clear forgets the access token even if the platform store fails',
      () async {
        final store = SessionStore(ThrowingSecureStore());
        await expectLater(store.clear(), throwsStateError);
        expect(store.accessToken, isNull);
      },
    );

    test('a session cleared during saveSession is not kept', () async {
      final secure = InMemorySecureStore();
      final store = SessionStore(secure);
      final saving = store.saveSession(tokenResponse());
      await store.clear();
      expect(await saving, isFalse);
      expect(store.accessToken, isNull);
      expect(secure.values, isEmpty);
    });

    test('saveSession reports true when nothing interfered', () async {
      expect(
        await SessionStore(InMemorySecureStore()).saveSession(tokenResponse()),
        isTrue,
      );
    });

    test(
      'a sign-out racing the writes makes saveSession return false',
      () async {
        final secure = RecordingSecureStore();
        final store = SessionStore(secure);
        var cleared = false;
        secure.afterWrite = () async {
          if (!cleared) {
            cleared = true;
            await store.clear();
          }
        };

        final saved = await store.saveSession(tokenResponse());

        expect(saved, isFalse);
        expect(store.accessToken, isNull);
        expect(secure.values, isEmpty);
      },
    );
  });
}
