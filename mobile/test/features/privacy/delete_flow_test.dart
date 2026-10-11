import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/privacy/application/account_closed_notice.dart';
import 'package:afterme/features/privacy/application/delete_account_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/http_world.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Settings > Privacy and data > Delete account (USER_FLOWS.md §11, SECURITY.md §13): the
/// most destructive thing the app does. What follows a 202 happens even though the screen
/// is gone: every session is already revoked server-side.
const _closedTitle = 'Your account has been closed';
const _unconfirmedTitle = "We couldn't confirm that your account was closed";
const _notConfirmed =
    "We couldn't confirm that your account was closed. Nothing on this "
    'screen has changed. You can try again: if it did go through, we\'ll tell '
    'you.';
const _reason =
    'Closing your account needs your password, so nobody else can do it from '
    'your phone.';

final _pendingTap = PendingCheckIn(
  userId: 'user-1',
  idempotencyKey: 'key-of-an-unconfirmed-tap',
  reportedAt: DateTime.utc(2026, 10, 8, 11),
).encode();

/// A session store with a real session in it, an unconfirmed tap, and one key that is
/// not the account's (a deletion of "everything" would take it too).
RecordingSecureStore _store() => RecordingSecureStore({
  SessionKeys.refreshToken: 'refresh-1',
  SessionKeys.sessionId: 'session-1',
  SessionKeys.deviceId: 'device-1',
  SessionKeys.userId: 'user-1',
  PendingCheckInStore.storageKey: _pendingTap,
  'unrelated.key': 'kept',
});

/// Secure storage whose `session.*` deletions fail, like a broken Keystore at the moment
/// the session has to end.
class _FailingSessionDeleteStore extends RecordingSecureStore {
  _FailingSessionDeleteStore(super.initialValues);

  @override
  Future<void> delete(String key) async {
    if (key.startsWith('session.')) {
      throw StateError('keystore');
    }
    await super.delete(key);
  }
}

Future<ProviderContainer> _open(
  WidgetTester tester,
  TestFakes fakes, {
  RecordingSecureStore? store,
  Map<String, Object> prefs = const {},
}) async {
  fakes.prefs = freshPreferences({
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': true,
    ...prefs,
  });
  // The phone is offline for check-ins: the unconfirmed tap stays unconfirmed (the app
  // would otherwise send it at start-up, which is what it is for).
  fakes.server.failures['checkIn'] = [
    for (var i = 0; i < 20; i++) const NetworkFailure(),
  ];
  final container = await pumpAfterMe(
    tester,
    fakes: fakes,
    status: AuthStatus.signedIn,
    secureStore: store ?? _store(),
  );
  container.read(routerProvider).go(AppRoutes.settingsDelete);
  await tester.pumpAndSettle();
  return container;
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder get _deleteButton =>
    find.widgetWithText(FilledButton, 'Delete my account');

Future<void> _type(WidgetTester tester, String text) async {
  final field = find.widgetWithText(TextField, 'Type DELETE to confirm');
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

Future<void> _tapDelete(WidgetTester tester) async {
  await tester.ensureVisible(_deleteButton);
  await tester.pump();
  await tester.tap(_deleteButton);
  await _frames(tester);
}

Future<void> _password(WidgetTester tester, TestFakes fakes) async {
  expect(find.text("Confirm it's you"), findsOneWidget);
  await typeInto(tester, 'Password', fakes.auth.password);
  await tapText(tester, 'Confirm');
  await _frames(tester);
}

bool _enabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_deleteButton).onPressed != null;

void main() {
  testWidgets('Settings has the entry', (tester) async {
    final fakes = TestFakes();
    fakes.prefs = freshPreferences({
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': true,
    });
    final container = await pumpAfterMe(
      tester,
      fakes: fakes,
      status: AuthStatus.signedIn,
    );
    container.read(routerProvider).go(AppRoutes.settings);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Delete account'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tapText(tester, 'Delete account');
    await tester.pumpAndSettle();
    expect(find.text('Delete your account'), findsOneWidget);
  });

  group('before anything is sent', () {
    testWidgets('says exactly what happens, that it cannot be undone and '
        'offers the export first', (tester) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      for (final line in [
        'Your check-ins stop.',
        'Your instructions are erased, and nobody will receive them.',
        'The details of your trusted contacts are removed.',
        'If a missed check-in is open, the contacts who were already told get a '
            'message that the alert is withdrawn.',
        "You're signed out on every device, including this one.",
        'Everything that remains is removed after 30 days.',
        "This can't be undone.",
      ]) {
        expect(find.text(line), findsOneWidget, reason: line);
      }
      expect(
        find.text(
          'Want a copy of your information first? Export it before you delete.',
        ),
        findsOneWidget,
      );
      expect(fakes.accountData.calls, isEmpty);
      expect(fakes.auth.calls, isNot(contains('reauth')));
    });

    testWidgets('the button stays off until DELETE is typed exactly', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      expect(_enabled(tester), isFalse);
      for (final wrong in [
        'delete',
        'Delete',
        'DELET',
        'DELETE ',
        ' DELETE',
        'DELETE!',
      ]) {
        await _type(tester, wrong);
        expect(_enabled(tester), isFalse, reason: '"$wrong"');
      }
      await _type(tester, 'DELETE');
      expect(_enabled(tester), isTrue);
      await _type(tester, 'DELETEx');
      expect(_enabled(tester), isFalse);
      // The word is typed exactly: the keyboard must not "help".
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Type DELETE to confirm'),
      );
      expect(field.autocorrect, isFalse);
      expect(field.enableSuggestions, isFalse);
      expect(fakes.accountData.calls, isEmpty);
    });

    testWidgets('Keep my account leaves without sending anything', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await tapText(tester, 'Keep my account');
      await tester.pumpAndSettle();
      expect(find.text('Delete your account'), findsNothing);
      expect(fakes.accountData.calls, isEmpty);
    });
  });

  group('the way through', () {
    testWidgets('the password immediately before the request, then the closed '
        'screen with the purge date, then sign-in', (tester) async {
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(tester, fakes, store: store);
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_reason), findsOneWidget);
      await _password(tester, fakes);
      await tester.pumpAndSettle();

      expect(find.text(_closedTitle), findsOneWidget);
      expect(
        find.text(
          'The rest of your information is removed by Saturday, November 7, '
          '2026.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('withdrawn'),
        findsOneWidget,
        reason: 'says what is happening to those who were told',
      );
      expect(fakes.accountData.calls, ['delete', 'delete']);
      expect(fakes.accountData.deleted, isTrue);
      expect(container.read(authControllerProvider), AuthStatus.signedOut);

      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('Sign in'), findsWidgets);
      expect(
        find.text('Please sign in again.'),
        findsNothing,
        reason: 'the account was closed on purpose, nothing "expired"',
      );
      expect(container.read(accountClosedNoticeProvider), isNull);
    });

    testWidgets('a password confirmed less than a minute ago needs no sheet', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.clock.advance(const Duration(seconds: 10));
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      await tester.pumpAndSettle();
      expect(find.text(_closedTitle), findsOneWidget);
      expect(fakes.accountData.calls, ['delete']);
    });

    testWidgets('afterwards the phone keeps nothing of the account: no '
        'session, no pending check-in, no preferences, no app lock; and '
        'nothing that is not the account\'s was swept away', (tester) async {
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(
        tester,
        fakes,
        store: store,
        prefs: const {
          'afterme.appLockEnabled': true,
          'afterme.appLockTimeoutMinutes': 1,
          'afterme.onboardingStep': 'done',
          'afterme.notificationPermissionResult': 'granted',
        },
      );
      // Unlock (the lock is on at a cold start) and prove the in-memory state.
      await container.read(appLockControllerProvider.notifier).unlock('test');
      await tester.pumpAndSettle();
      expect(container.read(appLockControllerProvider).enabled, isTrue);
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isTrue,
      );

      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      await _password(tester, fakes);
      await tester.pumpAndSettle();
      expect(find.text(_closedTitle), findsOneWidget);

      // Secure storage: the `session.*` keys and the pending tap are gone; the one
      // key that is not the account's is still there, and deleteAll was never called.
      expect(store.values.keys, ['unrelated.key']);
      expect(store.log.where((l) => l == 'deleteAll'), isEmpty);
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isFalse,
      );
      expect(container.read(sessionStoreProvider).accessToken, isNull);

      // Preferences: everything AfterMe keeps there.
      final prefs = container.read(preferencesStoreProvider);
      for (final key in PreferenceKey.values) {
        expect(await _anyPreference(prefs, key), isNull, reason: key.name);
      }
      // And what the app holds in memory from them.
      expect(container.read(appLockControllerProvider).enabled, isFalse);
      expect(
        container.read(onboardingControllerProvider).step,
        OnboardingStep.contact,
      );
      expect(container.read(onboardingControllerProvider).completed, isTrue);
    });

    testWidgets('while the request is on its way the screen cannot be left '
        'and the button is off', (tester) async {
      final fakes = TestFakes();
      final wait = Completer<void>();
      await _open(tester, fakes);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.gate = wait.future;
      await _type(tester, 'DELETE');
      await _tapDelete(tester);

      expect(find.text('Closing your account. Please wait…'), findsOneWidget);
      expect(_enabled(tester), isFalse);
      expect(find.byType(BackButton), findsNothing);
      // Neither the system's Back nor another tap gets out of it.
      final popped = await tester.binding.handlePopRoute();
      await tester.pump();
      expect(popped, isTrue);
      expect(find.text('Delete your account'), findsOneWidget);
      expect(find.text('Keep my account'), findsOneWidget);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.widgetWithText(OutlinedButton, 'Keep my account'),
            )
            .onPressed,
        isNull,
      );
      expect(fakes.accountData.calls, ['delete']);

      wait.complete();
      await tester.pumpAndSettle();
      expect(find.text(_closedTitle), findsOneWidget);
    });
  });

  group('when it is not confirmed', () {
    testWidgets('a lost connection says nothing was confirmed and changed '
        'nothing; trying again works', (tester) async {
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(tester, fakes, store: store);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [const NetworkFailure()];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);

      expect(find.text(_notConfirmed), findsOneWidget);
      expect(find.text('Delete your account'), findsOneWidget);
      expect(find.text(_closedTitle), findsNothing);
      // Nothing changed here: the word is still typed, the session and the pending tap
      // are untouched.
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Type DELETE to confirm'),
            )
            .controller!
            .text,
        'DELETE',
      );
      expect(_enabled(tester), isTrue);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(
        store.values.keys,
        containsAll([SessionKeys.refreshToken, PendingCheckInStore.storageKey]),
      );

      await _tapDelete(tester);
      await tester.pumpAndSettle();
      expect(find.text(_closedTitle), findsOneWidget);
      expect(fakes.accountData.calls, ['delete', 'delete']);
    });

    testWidgets('a server problem is not confirmed either', (tester) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [
        const ServerFailure(statusCode: 500),
      ];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_notConfirmed), findsOneWidget);
      expect(find.text(_closedTitle), findsNothing);
    });

    testWidgets('the request went through but its answer was lost: the next '
        'try is a 401, which is "we could not confirm", not "closed"', (
      tester,
    ) async {
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(tester, fakes, store: store);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.loseAnswer = true;
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_notConfirmed), findsOneWidget);
      expect(fakes.accountData.deleted, isTrue, reason: 'the server did it');
      expect(
        find.text(_closedTitle),
        findsNothing,
        reason: 'nobody told us yet',
      );

      await _tapDelete(tester);
      await tester.pumpAndSettle();
      // A 401 is not an answer to the question: said as such, calmly, with a way on.
      expect(find.text(_unconfirmedTitle), findsOneWidget);
      expect(find.text(_closedTitle), findsNothing);
      expect(find.textContaining("we'll send you an email"), findsOneWidget);
      expect(find.textContaining('sign in again'), findsOneWidget);
      expect(find.text('Nothing on this phone was removed.'), findsOneWidget);
      expect(
        find.textContaining('removed by'),
        findsNothing,
        reason: 'no purge date was seen and none is claimed',
      );
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      // The stale session is gone, and **only** it: the unconfirmed tap, the
      // preferences and the key that is not the account's are still there.
      expect(
        store.values.keys,
        unorderedEquals([PendingCheckInStore.storageKey, 'unrelated.key']),
      );
      final prefs = container.read(preferencesStoreProvider);
      expect(
        await prefs.getString(PreferenceKey.onboardingUserId),
        'user-1',
        reason: 'nothing was wiped',
      );

      // The way forward is the sign-in screen, where the next sign-in proves it.
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(find.text(_unconfirmedTitle), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
      expect(container.read(accountClosedNoticeProvider), isNull);
    });

    testWidgets('a session that ended for an unrelated reason after a lost '
        'answer must not wipe a live account\'s phone', (tester) async {
      // Request one: no answer, and the server did NOT act. Then the session is revoked
      // from elsewhere (log out everywhere, a password reset on the web): request two is
      // a 401. The account and its schedule are alive.
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(
        tester,
        fakes,
        store: store,
        prefs: const {
          'afterme.appLockEnabled': true,
          'afterme.onboardingStep': 'done',
        },
      );
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [
        const NetworkFailure(),
        const UnauthorizedFailure(code: 'session_revoked'),
      ];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_notConfirmed), findsOneWidget);
      await _tapDelete(tester);
      await tester.pumpAndSettle();

      expect(fakes.accountData.deleted, isFalse, reason: 'the account is live');
      expect(find.text(_closedTitle), findsNothing);
      expect(
        find.text(
          'Your check-ins have stopped and your instructions were '
          'erased. Contacts who had been told about a missed check-in are '
          'being sent a message that the alert is withdrawn.',
        ),
        findsNothing,
        reason: 'that would be false for a live account',
      );
      expect(find.text(_unconfirmedTitle), findsOneWidget);
      expect(
        store.values.containsKey(PendingCheckInStore.storageKey),
        isTrue,
        reason: 'the unconfirmed check-in is still waiting for a session',
      );
      expect(
        await container
            .read(preferencesStoreProvider)
            .getBool(PreferenceKey.appLockEnabled),
        isTrue,
        reason: 'the app lock is the phone\'s, not the account\'s',
      );
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
    });

    testWidgets('a storage error while the session ends after a 202 is not a '
        'failure: the account is closed and the phone is still cleaned up', (
      tester,
    ) async {
      final fakes = TestFakes();
      final store = _FailingSessionDeleteStore({
        SessionKeys.refreshToken: 'refresh-1',
        SessionKeys.sessionId: 'session-1',
        SessionKeys.deviceId: 'device-1',
        SessionKeys.userId: 'user-1',
        PendingCheckInStore.storageKey: _pendingTap,
      });
      final container = await _open(tester, fakes, store: store);
      await fakes.auth.reauth(password: fakes.auth.password);
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      await tester.pumpAndSettle();

      expect(fakes.accountData.deleted, isTrue);
      expect(find.text(_closedTitle), findsOneWidget);
      expect(find.text(_notConfirmed), findsNothing);
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(
        store.values.containsKey(PendingCheckInStore.storageKey),
        isFalse,
        reason: 'the wipe must still run after the sign-out failed',
      );
      expect(
        await container
            .read(preferencesStoreProvider)
            .getString(PreferenceKey.onboardingUserId),
        isNull,
      );
    });

    testWidgets('a 401 on the first request is a session that ended, not a '
        'closed account', (tester) async {
      final fakes = TestFakes();
      final store = _store();
      final container = await _open(tester, fakes, store: store);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [
        const UnauthorizedFailure(code: 'session_revoked'),
      ];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_closedTitle), findsNothing);
      expect(find.text('Please sign in again.'), findsOneWidget);
      expect(container.read(accountClosedNoticeProvider), isNull);
      expect(
        store.values.containsKey(PendingCheckInStore.storageKey),
        isTrue,
        reason: 'the account was not closed: the tap is still its own',
      );
    });

    testWidgets('closing the password sheet sends nothing more and changes '
        'nothing', (tester) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(fakes.accountData.calls, [
        'delete',
      ], reason: 'only the first, refused');
      expect(fakes.accountData.deleted, isFalse);
      expect(find.text('Delete your account'), findsOneWidget);
      expect(find.text(_notConfirmed), findsNothing);
      expect(_enabled(tester), isTrue);
    });

    testWidgets('a wrong password stays in the sheet and deletes nothing', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      await typeInto(tester, 'Password', 'not the password');
      await tapText(tester, 'Confirm');
      await _frames(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(fakes.accountData.deleted, isFalse);
      expect(fakes.accountData.calls, ['delete']);
    });

    testWidgets('a rate limit is said calmly and nothing is closed', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
      ];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.textContaining('Try again in 10 minutes'), findsOneWidget);
      expect(find.text(_closedTitle), findsNothing);
      expect(_enabled(tester), isTrue);
    });

    testWidgets('a refused word is said under the field', (tester) async {
      final fakes = TestFakes();
      await _open(tester, fakes);
      await fakes.auth.reauth(password: fakes.auth.password);
      fakes.accountData.failures['delete'] = [
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'confirm', code: 'invalid_choice'),
          ],
        ),
      ];
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(
        find.text('Type the word DELETE exactly as shown.'),
        findsOneWidget,
      );
      expect(find.text(_closedTitle), findsNothing);
    });
  });

  group('through the real API client', () {
    testWidgets('403 reauth_required, the password, then {"confirm": '
        '"DELETE"} again: 202 closes the account', (tester) async {
      var calls = 0;
      final world = await openHttpApp(
        tester,
        route: AppRoutes.settingsDelete,
        routes: {
          'DELETE /v1/me': (request) => ++calls == 1
              ? FakeReply.problem(403, 'reauth_required')
              : const FakeReply.json(202, {
                  'status': 'pending_deletion',
                  'purge_after': '2026-11-07T09:02:40Z',
                }),
        },
      );
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      await _password(tester, world.fakes);
      await tester.pumpAndSettle();
      expect(find.text(_closedTitle), findsOneWidget);
      final sent = world.to('DELETE', '/v1/me');
      expect(sent, hasLength(2));
      for (final request in sent) {
        expect(request.data, {'confirm': 'DELETE'});
        expect(request.bearer, isNotNull);
      }
      expect(
        await world.container.read(sessionStoreProvider).hasPersistedSession(),
        isFalse,
      );
    });

    testWidgets('the answer is lost, the retry is a 401 session_revoked (the '
        'API client ends the session on its own): the person is told it could '
        'not be confirmed, with a way to sign in', (tester) async {
      var calls = 0;
      final world = await openHttpApp(
        tester,
        route: AppRoutes.settingsDelete,
        routes: {
          'DELETE /v1/me': (request) => switch (++calls) {
            1 => const FakeReply.networkError(),
            _ => FakeReply.problem(401, 'session_revoked'),
          },
        },
      );
      await world.fakes.auth.reauth(password: world.fakes.auth.password);
      await _type(tester, 'DELETE');
      await _tapDelete(tester);
      expect(find.text(_notConfirmed), findsOneWidget);
      expect(world.to('DELETE', '/v1/me'), hasLength(1));

      await _tapDelete(tester);
      await tester.pumpAndSettle();
      expect(find.text(_unconfirmedTitle), findsOneWidget);
      expect(find.text(_closedTitle), findsNothing);
      expect(world.to('DELETE', '/v1/me'), hasLength(2));
      expect(
        world.container.read(authControllerProvider),
        AuthStatus.signedOut,
      );
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(find.text(_unconfirmedTitle), findsNothing);
    });
  });

  test('the word the server accepts is exactly DELETE', () {
    expect(deleteConfirmationWord, 'DELETE');
  });
}

/// A preference of [key], whatever its type.
Future<Object?> _anyPreference(
  PreferencesStore prefs,
  PreferenceKey key,
) async {
  return switch (key) {
    PreferenceKey.appLockEnabled ||
    PreferenceKey.onboardingCompleted => await prefs.getBool(key),
    PreferenceKey.appLockTimeoutMinutes => await prefs.getInt(key),
    _ => await prefs.getString(key),
  };
}
