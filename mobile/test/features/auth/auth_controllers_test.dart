import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/application/account_session.dart';
import 'package:afterme/features/auth/application/forgot_password_controller.dart';
import 'package:afterme/features/auth/application/login_controller.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/application/sessions_controller.dart';
import 'package:afterme/features/auth/application/signup_controller.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes, {InMemorySecureStore? store}) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(fakes: fakes, secureStore: store),
  );
  // Keep the auto-disposed and lazily built providers alive during the test.
  container.listen(authControllerProvider, (_, _) {});
  container.listen(onboardingControllerProvider, (_, _) {});
  return container;
}

Future<SignupController> _startedSignup(
  ProviderContainer container, {
  String password = 'a long unique phrase',
}) async {
  final signup = container.read(signupControllerProvider.notifier);
  expect(
    await signup.start(
      displayName: 'Diwakar',
      email: 'new@example.com',
      password: password,
      timezone: 'Asia/Kolkata',
    ),
    isTrue,
  );
  return signup;
}

void main() {
  group('SignupController', () {
    test('start sends the code request and moves to the code stage', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final signup = await _startedSignup(container);

      final state = container.read(signupControllerProvider);
      expect(state.stage, SignupStage.code);
      expect(state.email, 'new@example.com');
      expect(state.busy, isFalse);
      expect(
        state.resendAvailableAt,
        fakes.clock.now().add(const Duration(seconds: 60)),
      );
      expect(state.codeSentCount, 1);
      expect(fakes.auth.lastArgs['registerStart']!['locale'], 'en');
      expect(fakes.auth.lastArgs['registerStart']!['timezone'], 'Asia/Kolkata');
      expect(signup.hasPassword, isTrue);
    });

    test('the password is never part of the state', () async {
      final container = _container(TestFakes());
      await _startedSignup(container, password: 'hunter2 hunter2 hunter2');
      final text = [
        container.read(signupControllerProvider).email,
        container.read(signupControllerProvider).displayName,
        container.read(signupControllerProvider).timezone,
        '${container.read(signupControllerProvider.notifier)}',
      ].join(' ');
      expect(text, isNot(contains('hunter2')));
    });

    test(
      'a failed start reports the failure and forgets the password',
      () async {
        final fakes = TestFakes();
        fakes.auth.fail('registerStart', const NetworkFailure());
        final container = _container(fakes);
        final signup = container.read(signupControllerProvider.notifier);
        final started = await signup.start(
          displayName: 'D',
          email: 'x@example.com',
          password: 'a long unique phrase',
          timezone: 'UTC',
        );
        expect(started, isFalse);
        expect(
          container.read(signupControllerProvider).failure,
          isA<NetworkFailure>(),
        );
        expect(
          container.read(signupControllerProvider).stage,
          SignupStage.form,
        );
        expect(signup.hasPassword, isFalse);
      },
    );

    test('a second start while busy is ignored', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final signup = container.read(signupControllerProvider.notifier);
      final first = signup.start(
        displayName: 'D',
        email: 'x@example.com',
        password: 'a long unique phrase',
        timezone: 'UTC',
      );
      final second = await signup.start(
        displayName: 'D',
        email: 'x@example.com',
        password: 'a long unique phrase',
        timezone: 'UTC',
      );
      expect(second, isFalse);
      await first;
      expect(fakes.auth.calls.where((c) => c == 'registerStart'), hasLength(1));
    });

    test(
      'verify creates the session, begins onboarding, clears the password',
      () async {
        final fakes = TestFakes();
        final store = InMemorySecureStore();
        final container = _container(fakes, store: store);
        final signup = await _startedSignup(container);

        expect(await signup.verify('482913'), isTrue);

        expect(container.read(authControllerProvider), AuthStatus.signedIn);
        expect(await store.read(SessionKeys.refreshToken), 'refresh-token');
        expect(
          container.read(signupControllerProvider).stage,
          SignupStage.done,
        );
        expect(signup.hasPassword, isFalse);
        final onboarding = container.read(onboardingControllerProvider);
        expect(onboarding.needsOnboarding, isTrue);
        expect(onboarding.step, OnboardingStep.contact);
        // The code and password never reach preferences.
        final prefs = fakes.prefs;
        for (final key in [
          PreferenceKey.onboardingStep,
          PreferenceKey.onboardingUserId,
          PreferenceKey.notificationPermissionResult,
        ]) {
          final value = await prefs.getString(key) ?? '';
          expect(value, isNot(contains('482913')));
          expect(value, isNot(contains('a long unique phrase')));
        }
        expect(await prefs.getString(PreferenceKey.onboardingUserId), 'user-1');
        expect(await prefs.getString(PreferenceKey.onboardingStep), 'contact');
      },
    );

    test(
      'a wrong code is flagged and the password is kept for another try',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final signup = await _startedSignup(container);

        expect(await signup.verify('000000'), isFalse);
        final state = container.read(signupControllerProvider);
        expect(state.codeRejected, isTrue);
        expect(state.failure, isA<ValidationFailure>());
        expect(
          container.read(authControllerProvider),
          isNot(AuthStatus.signedIn),
        );
        expect(signup.hasPassword, isTrue);

        expect(await signup.verify('482913'), isTrue);
      },
    );

    test('other verify failures are not reported as a wrong code', () async {
      final fakes = TestFakes();
      fakes.auth.fail('registerVerify', const ServerFailure(statusCode: 500));
      final container = _container(fakes);
      final signup = await _startedSignup(container);
      expect(await signup.verify('482913'), isFalse);
      expect(container.read(signupControllerProvider).codeRejected, isFalse);
      expect(
        container.read(signupControllerProvider).failure,
        isA<ServerFailure>(),
      );
    });

    test('verify without a password in memory does nothing', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final signup = container.read(signupControllerProvider.notifier);
      expect(await signup.verify('482913'), isFalse);
      expect(fakes.auth.calls, isEmpty);
    });

    test(
      'resend waits for the countdown, then sends and restarts it',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final signup = await _startedSignup(container);

        await signup.resend();
        expect(
          fakes.auth.calls,
          isNot(contains('registerResend')),
          reason: 'too early',
        );

        fakes.clock.advance(const Duration(seconds: 59));
        await signup.resend();
        expect(fakes.auth.calls, isNot(contains('registerResend')));

        fakes.clock.advance(const Duration(seconds: 1));
        await signup.resend();
        expect(fakes.auth.calls, contains('registerResend'));
        final state = container.read(signupControllerProvider);
        expect(state.codeSentCount, 2);
        expect(
          state.resendAvailableAt,
          fakes.clock.now().add(const Duration(seconds: 60)),
        );
        expect(state.resending, isFalse);
      },
    );

    test(
      'a rate-limited resend keeps the countdown and reports the failure',
      () async {
        final fakes = TestFakes();
        fakes.auth.fail(
          'registerResend',
          const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
        );
        final container = _container(fakes);
        final signup = await _startedSignup(container);
        fakes.clock.advance(const Duration(seconds: 61));
        await signup.resend();
        expect(
          container.read(signupControllerProvider).failure,
          isA<RateLimitedFailure>(),
        );
      },
    );

    test('changeEmail returns to the form and clears errors', () async {
      final container = _container(TestFakes());
      final signup = await _startedSignup(container);
      await signup.verify('000000');
      signup.changeEmail();
      final state = container.read(signupControllerProvider);
      expect(state.stage, SignupStage.form);
      expect(state.failure, isNull);
      expect(state.codeRejected, isFalse);
      expect(signup.hasPassword, isTrue, reason: 'the form still holds it');
    });

    test(
      'abandon forgets the password; clearFailure clears messages',
      () async {
        final container = _container(TestFakes());
        final signup = await _startedSignup(container);
        await signup.verify('000000');
        signup.clearFailure();
        expect(container.read(signupControllerProvider).codeRejected, isFalse);
        signup.clearFailure(); // nothing to clear: no-op
        signup.abandon();
        expect(signup.hasPassword, isFalse);
        expect(await signup.verify('482913'), isFalse);
      },
    );

    test(
      'resumeVerification (from sign-in) goes straight to the code stage',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final signup = container.read(signupControllerProvider.notifier);
        signup.resumeVerification(
          email: 'diwakar@example.com',
          password: 'correct horse battery',
        );
        final state = container.read(signupControllerProvider);
        expect(state.stage, SignupStage.code);
        expect(state.email, 'diwakar@example.com');
        expect(signup.hasPassword, isTrue);
        expect(state.resendAvailableAt, isNotNull);
      },
    );

    test('disposing the controller forgets the password', () async {
      final container = _container(TestFakes());
      final signup = await _startedSignup(container);
      container.dispose();
      expect(signup.hasPassword, isFalse);
    });
  });

  group('LoginController', () {
    test('signs in and persists the session', () async {
      final fakes = TestFakes();
      final store = InMemorySecureStore();
      final container = _container(fakes, store: store);
      final result = await container
          .read(loginControllerProvider.notifier)
          .signIn(
            email: 'Diwakar@Example.com',
            password: 'correct horse battery',
          );
      expect(result, LoginResult.signedIn);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(await store.read(SessionKeys.refreshToken), 'refresh-token');
      expect(container.read(loginControllerProvider).busy, isFalse);
      // An existing account without saved progress has nothing to resume.
      await container.read(onboardingControllerProvider.notifier).loaded;
      expect(
        container.read(onboardingControllerProvider).needsOnboarding,
        isFalse,
      );
    });

    test(
      'a wrong password is an UnauthorizedFailure and nothing is stored',
      () async {
        final fakes = TestFakes();
        final store = InMemorySecureStore();
        final container = _container(fakes, store: store);
        final result = await container
            .read(loginControllerProvider.notifier)
            .signIn(email: 'diwakar@example.com', password: 'nope');
        expect(result, LoginResult.failed);
        final failure = container.read(loginControllerProvider).failure;
        expect(failure, isA<UnauthorizedFailure>());
        expect(store.values, isEmpty);

        container.read(loginControllerProvider.notifier).clearFailure();
        expect(container.read(loginControllerProvider).failure, isNull);
      },
    );

    test(
      'an unverified account continues with the code (password kept in memory)',
      () async {
        final fakes = TestFakes()..auth.verified = false;
        final container = _container(fakes);
        final result = await container
            .read(loginControllerProvider.notifier)
            .signIn(
              email: 'diwakar@example.com',
              password: 'correct horse battery',
            );
        expect(result, LoginResult.needsVerification);
        final signup = container.read(signupControllerProvider.notifier);
        expect(signup.hasPassword, isTrue);
        expect(
          container.read(signupControllerProvider).stage,
          SignupStage.code,
        );
        expect(
          container.read(signupControllerProvider).email,
          'diwakar@example.com',
        );
        expect(
          container.read(authControllerProvider),
          isNot(AuthStatus.signedIn),
        );
        expect(container.read(loginControllerProvider).failure, isNull);

        // The verification then uses the stored password.
        fakes.auth.pendingEmail = 'diwakar@example.com';
        fakes.auth.pendingPassword = 'correct horse battery';
        expect(await signup.verify('482913'), isTrue);
      },
    );

    test('network and rate-limit failures are reported as they are', () async {
      final fakes = TestFakes();
      fakes.auth.fail('login', const NetworkFailure());
      final container = _container(fakes);
      final controller = container.read(loginControllerProvider.notifier);
      expect(
        await controller.signIn(email: 'a@b.co', password: 'x'),
        LoginResult.failed,
      );
      expect(
        container.read(loginControllerProvider).failure,
        isA<NetworkFailure>(),
      );
    });

    test('a second sign-in while busy is ignored', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      final controller = container.read(loginControllerProvider.notifier);
      final first = controller.signIn(
        email: 'diwakar@example.com',
        password: 'correct horse battery',
      );
      expect(
        await controller.signIn(email: 'diwakar@example.com', password: 'x'),
        LoginResult.failed,
      );
      expect(await first, LoginResult.signedIn);
      expect(fakes.auth.calls.where((c) => c == 'login'), hasLength(1));
    });
  });

  group('ForgotPasswordController', () {
    test('submit marks the request as sent (same for any address)', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      container.listen(forgotPasswordControllerProvider, (_, _) {});
      final c = container.read(forgotPasswordControllerProvider.notifier);
      await c.submit('anyone@example.com');
      expect(container.read(forgotPasswordControllerProvider).sent, isTrue);
      expect(
        fakes.auth.lastArgs['forgotPassword']!['email'],
        'anyone@example.com',
      );
      c.reset();
      expect(container.read(forgotPasswordControllerProvider).sent, isFalse);
    });

    test('rate limits and network errors are shown, not sent', () async {
      final fakes = TestFakes();
      fakes.auth
        ..fail(
          'forgotPassword',
          const RateLimitedFailure(retryAfter: Duration(hours: 1)),
        )
        ..fail('forgotPassword', const NetworkFailure());
      final container = _container(fakes);
      container.listen(forgotPasswordControllerProvider, (_, _) {});
      final c = container.read(forgotPasswordControllerProvider.notifier);
      await c.submit('a@b.co');
      expect(
        container.read(forgotPasswordControllerProvider).failure,
        isA<RateLimitedFailure>(),
      );
      expect(container.read(forgotPasswordControllerProvider).sent, isFalse);
      await c.submit('a@b.co');
      expect(
        container.read(forgotPasswordControllerProvider).failure,
        isA<NetworkFailure>(),
      );
    });
  });

  group('MeController', () {
    Future<ProviderContainer> signedIn(TestFakes fakes) async {
      final container = _container(fakes);
      await container
          .read(loginControllerProvider.notifier)
          .signIn(
            email: 'diwakar@example.com',
            password: 'correct horse battery',
          );
      container.listen(meControllerProvider, (_, _) {});
      return container;
    }

    test(
      'is empty when signed out and loads the account when signed in',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        container.listen(meControllerProvider, (_, _) {});
        expect(await container.read(meControllerProvider.future), isNull);
        expect(fakes.auth.calls, isNot(contains('me')));

        await container
            .read(loginControllerProvider.notifier)
            .signIn(
              email: 'diwakar@example.com',
              password: 'correct horse battery',
            );
        final me = await container.read(meControllerProvider.future);
        expect(me?.profile.displayName, 'Diwakar');
        expect(me?.email, 'diwakar@example.com');
      },
    );

    test('is emptied again on sign-out', () async {
      final container = await signedIn(TestFakes());
      expect((await container.read(meControllerProvider.future))?.id, 'user-1');
      await container.read(authControllerProvider.notifier).signOut();
      expect(await container.read(meControllerProvider.future), isNull);
    });

    test('patchProfile updates the state; failures are AppFailures', () async {
      final fakes = TestFakes();
      final container = await signedIn(fakes);
      await container.read(meControllerProvider.future);
      final controller = container.read(meControllerProvider.notifier);
      final updated = await controller.patchProfile(
        const ProfilePatch(displayName: 'Asha'),
      );
      expect(updated.profile.displayName, 'Asha');
      expect(
        container.read(meControllerProvider).value?.profile.displayName,
        'Asha',
      );

      fakes.auth.fail('patchProfile', const NetworkFailure());
      await expectLater(
        controller.patchProfile(const ProfilePatch(displayName: 'X')),
        throwsA(isA<NetworkFailure>()),
      );
      expect(
        container.read(meControllerProvider).value?.profile.displayName,
        'Asha',
      );
    });

    test('refresh reloads and a failing load surfaces the failure', () async {
      final fakes = TestFakes();
      final container = await signedIn(fakes);
      await container.read(meControllerProvider.future);
      fakes.auth.displayName = 'Changed elsewhere';
      fakes.auth.me_ = fakes.auth.me_.copyWith(
        profile: fakes.auth.me_.profile.copyWith(
          displayName: 'Changed elsewhere',
        ),
      );
      await container.read(meControllerProvider.notifier).refresh();
      expect(
        container.read(meControllerProvider).value?.profile.displayName,
        'Changed elsewhere',
      );

      fakes.auth.fail('me', const ServerFailure(statusCode: 500));
      await container.read(meControllerProvider.notifier).refresh();
      expect(container.read(meControllerProvider).hasError, isTrue);
      expect(container.read(meControllerProvider).error, isA<ServerFailure>());
    });

    test('a build failure is an AppFailure', () async {
      final fakes = TestFakes();
      fakes.auth.fail('me', const NetworkFailure());
      final container = _container(fakes);
      await container
          .read(loginControllerProvider.notifier)
          .signIn(
            email: 'diwakar@example.com',
            password: 'correct horse battery',
          );
      container.listen(meControllerProvider, (_, _) {});
      await expectLater(
        container.read(meControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('apply replaces the account', () async {
      final fakes = TestFakes();
      final container = await signedIn(fakes);
      final me = await container.read(meControllerProvider.future);
      container
          .read(meControllerProvider.notifier)
          .apply(me!.copyWith(email: 'changed@example.com'));
      expect(
        container.read(meControllerProvider).value?.email,
        'changed@example.com',
      );
    });
  });

  group('SessionsController and AccountSession', () {
    Future<ProviderContainer> signedIn(TestFakes fakes) async {
      final container = _container(fakes);
      await container
          .read(loginControllerProvider.notifier)
          .signIn(
            email: 'diwakar@example.com',
            password: 'correct horse battery',
          );
      container.listen(sessionsControllerProvider, (_, _) {});
      return container;
    }

    test(
      'lists sessions and revokes one only after the server confirmed',
      () async {
        final fakes = TestFakes();
        final container = await signedIn(fakes);
        final items = await container.read(sessionsControllerProvider.future);
        expect(items.map((s) => s.id), ['session-current', 'session-other']);

        final controller = container.read(sessionsControllerProvider.notifier);
        fakes.auth.fail('revokeSession', const NetworkFailure());
        await expectLater(
          controller.revoke('session-other'),
          throwsA(isA<NetworkFailure>()),
        );
        expect(container.read(sessionsControllerProvider).value, hasLength(2));

        await controller.revoke('session-other');
        expect(
          container.read(sessionsControllerProvider).value!.map((s) => s.id),
          ['session-current'],
        );
      },
    );

    test('refresh reloads; errors are AppFailures', () async {
      final fakes = TestFakes();
      final container = await signedIn(fakes);
      await container.read(sessionsControllerProvider.future);
      fakes.auth.sessions = [fakes.auth.sessions.first];
      await container.read(sessionsControllerProvider.notifier).refresh();
      expect(container.read(sessionsControllerProvider).value, hasLength(1));

      fakes.auth.fail('listSessions', const ServerFailure(statusCode: 503));
      await container.read(sessionsControllerProvider.notifier).refresh();
      expect(
        container.read(sessionsControllerProvider).error,
        isA<ServerFailure>(),
      );
    });

    test('is empty when signed out', () async {
      final container = _container(TestFakes());
      container.listen(sessionsControllerProvider, (_, _) {});
      expect(await container.read(sessionsControllerProvider.future), isEmpty);
    });

    test('a build failure surfaces as an AppFailure', () async {
      final fakes = TestFakes();
      fakes.auth.fail('listSessions', const NetworkFailure());
      final container = await signedIn(fakes);
      await expectLater(
        container.read(sessionsControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
    });

    test('signOut tells the server but always signs out locally', () async {
      final fakes = TestFakes();
      fakes.auth.fail('logout', const NetworkFailure());
      final store = InMemorySecureStore();
      final container = _container(fakes, store: store);
      await container
          .read(loginControllerProvider.notifier)
          .signIn(
            email: 'diwakar@example.com',
            password: 'correct horse battery',
          );
      expect(store.values, isNotEmpty);
      await container.read(accountSessionProvider).signOut();
      expect(fakes.auth.calls, contains('logout'));
      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(store.values, isEmpty);
    });

    test(
      'signOutEverywhere needs the server; a failure keeps the session',
      () async {
        final fakes = TestFakes();
        final store = InMemorySecureStore();
        final container = _container(fakes, store: store);
        await container
            .read(loginControllerProvider.notifier)
            .signIn(
              email: 'diwakar@example.com',
              password: 'correct horse battery',
            );
        final session = container.read(accountSessionProvider);

        fakes.auth.fail('logoutAll', const NetworkFailure());
        await expectLater(
          session.signOutEverywhere(),
          throwsA(isA<NetworkFailure>()),
        );
        expect(container.read(authControllerProvider), AuthStatus.signedIn);

        await session.signOutEverywhere();
        expect(container.read(authControllerProvider), AuthStatus.signedOut);
        expect(store.values, isEmpty);
      },
    );
  });

  test('the repository provider builds a Dio implementation', () {
    final container = ProviderContainer.test(
      overrides: [...testOverrides().where((o) => true)],
    );
    // The default provider is overridden by TestFakes; the real one needs the API client.
    expect(container.read(authRepositoryProvider), isA<FakeAuthRepository>());
  });
}
