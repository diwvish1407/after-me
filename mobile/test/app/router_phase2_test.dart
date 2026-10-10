import 'dart:async';
import 'dart:io';

import 'package:afterme/app/app.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_ended_notice.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/presentation/create_account_screen.dart';
import 'package:afterme/features/auth/presentation/forgot_password_screen.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:afterme/features/auth/presentation/sign_in_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:afterme/features/onboarding/presentation/welcome_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/fake_http_adapter.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

const _midOnboarding = OnboardingState(
  loaded: true,
  completed: false,
  step: OnboardingStep.plan,
);

void main() {
  group('authRedirect with onboarding', () {
    String? redirect(
      AuthStatus status,
      String location, {
      OnboardingState onboarding = const OnboardingState(loaded: true),
      bool isDev = false,
    }) => authRedirect(
      status: status,
      location: location,
      isDev: isDev,
      onboarding: onboarding,
    );

    test(
      'signed out may use the public sign-up routes and forgot-password',
      () {
        for (final path in [
          AppRoutes.welcome,
          AppRoutes.signIn,
          AppRoutes.createAccount,
          AppRoutes.verifyCode,
          AppRoutes.forgotPassword,
        ]) {
          expect(redirect(AuthStatus.signedOut, path), isNull, reason: path);
        }
      },
    );

    test(
      'signed out cannot reach onboarding, settings, tabs or unknown paths',
      () {
        for (final path in [
          ...OnboardingStep.values.map((s) => s.path),
          ...AppRoutes.settingsScreens,
          ...AppRoutes.shellTabs,
          '/nowhere',
          '/onboarding',
          '//evil',
        ]) {
          expect(
            redirect(AuthStatus.signedOut, path),
            AppRoutes.welcome,
            reason: path,
          );
        }
      },
    );

    test(
      'signed in waits on the splash until the onboarding progress is read',
      () {
        const loading = OnboardingState();
        expect(
          redirect(AuthStatus.signedIn, AppRoutes.home, onboarding: loading),
          AppRoutes.splash,
        );
        expect(
          redirect(AuthStatus.signedIn, AppRoutes.splash, onboarding: loading),
          isNull,
        );
      },
    );

    test(
      'unfinished onboarding resumes at the saved step from anywhere else',
      () {
        for (final path in [
          AppRoutes.home,
          AppRoutes.settings,
          AppRoutes.settingsSecurity,
          AppRoutes.welcome,
          AppRoutes.signIn,
          AppRoutes.splash,
          '/nowhere',
        ]) {
          expect(
            redirect(AuthStatus.signedIn, path, onboarding: _midOnboarding),
            OnboardingStep.plan.path,
            reason: path,
          );
        }
      },
    );

    test('while onboarding, every onboarding step and forgot-password stay reachable', () {
      for (final step in OnboardingStep.values) {
        expect(
          redirect(AuthStatus.signedIn, step.path, onboarding: _midOnboarding),
          isNull,
        );
      }
      expect(
        redirect(
          AuthStatus.signedIn,
          AppRoutes.forgotPassword,
          onboarding: _midOnboarding,
        ),
        isNull,
      );
    });

    test('after onboarding the tabs, settings and steps are reachable; public routes are not', () {
      for (final path in [
        ...AppRoutes.shellTabs,
        ...AppRoutes.settingsScreens,
        ...OnboardingStep.values.map((s) => s.path),
        AppRoutes.forgotPassword,
      ]) {
        expect(redirect(AuthStatus.signedIn, path), isNull, reason: path);
      }
      for (final path in [
        AppRoutes.welcome,
        AppRoutes.signIn,
        AppRoutes.createAccount,
        AppRoutes.verifyCode,
        AppRoutes.splash,
        AppRoutes.devGallery,
        '/nowhere',
      ]) {
        expect(
          redirect(AuthStatus.signedIn, path, isDev: true),
          AppRoutes.home,
          reason: path,
        );
      }
    });

    test('every known route is in exactly the sets the rules use', () {
      final known = AppRoutes.knownRoutes(isDev: true);
      expect(known, containsAll(AppRoutes.settingsScreens));
      expect(known, containsAll(AppRoutes.onboardingSteps));
      expect(
        AppRoutes.knownRoutes(isDev: false),
        isNot(contains(AppRoutes.devGallery)),
      );
    });
  });

  group('deep link safety', () {
    testWidgets('query strings and fragments never select a route', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedOut);
      container.read(routerProvider).go('/settings/profile?next=/home#frag');
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('an unknown or hostile path lands on the safe screen', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedIn);
      for (final path in [
        '/does/not/exist',
        'https://evil.example/home',
        '/dev/gallery',
      ]) {
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget, reason: path);
      }
    });

    testWidgets('only a String is accepted as the forgot-password prefill', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedOut);
      container
          .read(routerProvider)
          .go(AppRoutes.forgotPassword, extra: <String, String>{'email': 'x'});
      await tester.pumpAndSettle();
      expect(find.byType(ForgotPasswordScreen), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Email'))
            .controller!
            .text,
        '',
      );
      container.read(routerProvider).go(AppRoutes.welcome);
      await tester.pumpAndSettle();
      container
          .read(routerProvider)
          .go(AppRoutes.forgotPassword, extra: 'me@example.com');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Email'))
            .controller!
            .text,
        'me@example.com',
      );
    });

    testWidgets('the app declares no deep-link intent filters', (tester) async {
      // The manifest is the contract: nothing outside the app can open a route.
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      final filters = RegExp(
        r'<intent-filter>.*?</intent-filter>',
        dotAll: true,
      ).allMatches(manifest).map((m) => m.group(0)!).toList();
      expect(filters, hasLength(1), reason: 'only the launcher');
      expect(filters.single, contains('android.intent.action.MAIN'));
      expect(filters.single, isNot(contains('VIEW')));
      expect(filters.single, isNot(contains('BROWSABLE')));
      expect(filters.single, isNot(contains('android:scheme')));
    });
  });

  group('routing with the real controllers', () {
    testWidgets('welcome leads to create account and back', (tester) async {
      await pumpAfterMe(tester, status: AuthStatus.signedOut);
      await tapText(tester, 'Get started');
      await tester.pumpAndSettle();
      expect(find.byType(CreateAccountScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('Skip on the welcome cards goes to account creation', (
      tester,
    ) async {
      await pumpAfterMe(tester, status: AuthStatus.signedOut);
      await tapText(tester, 'Skip');
      await tester.pumpAndSettle();
      expect(find.byType(CreateAccountScreen), findsOneWidget);
    });

    testWidgets('signing out from deep inside Settings returns to welcome', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedIn);
      container.read(routerProvider).go(AppRoutes.settingsSessions);
      await tester.pumpAndSettle();
      await container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets(
      'a re-auth sheet open when the session ends does not survive it',
      (tester) async {
        final container = await pumpAfterMe(
          tester,
          status: AuthStatus.signedIn,
        );
        container.read(routerProvider).go(AppRoutes.settingsAbout);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(Scaffold).last);
        unawaited(showReauthSheet(context));
        await tester.pumpAndSettle();
        expect(find.text("Confirm it's you"), findsOneWidget);
        (container.read(authControllerProvider.notifier) as FixedAuthController)
            .set(AuthStatus.signedOut);
        await tester.pumpAndSettle();
        expect(find.text("Confirm it's you"), findsNothing);
        expect(find.byType(WelcomeScreen), findsOneWidget);
      },
    );

    testWidgets('a dialog open when the session ends does not survive it', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedIn);
      container.read(routerProvider).go(AppRoutes.settings);
      await tester.pumpAndSettle();
      await tapText(tester, 'Sign out');
      await tester.pumpAndSettle();
      expect(find.text('Sign out of this phone?'), findsOneWidget);
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(find.text('Sign out of this phone?'), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });
  });

  group('session loss (401 session_revoked)', () {
    test(
      'a session ended for the person redirects to sign-in, not Welcome',
      () {
        String? redirect({required bool ended}) => authRedirect(
          status: AuthStatus.signedOut,
          location: AppRoutes.home,
          isDev: false,
          sessionEnded: ended,
        );
        expect(redirect(ended: true), AppRoutes.signIn);
        expect(redirect(ended: false), AppRoutes.welcome);
      },
    );

    testWidgets('signing out on purpose stays quiet and goes to Welcome', (
      tester,
    ) async {
      final container = await pumpAfterMe(tester, status: AuthStatus.signedIn);
      container.read(routerProvider).go(AppRoutes.settings);
      await tester.pumpAndSettle();
      await container.read(authControllerProvider.notifier).signOut();
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(container.read(sessionEndedNoticeProvider), isFalse);
    });

    testWidgets(
      'explains on sign-in and clears the tokens and cached account',
      (tester) async {
        final store = InMemorySecureStore({
          SessionKeys.refreshToken: 'refresh-token',
          SessionKeys.sessionId: 's',
          SessionKeys.deviceId: 'd',
        });
        final adapter = FakeHttpAdapter((request, _) {
          if (request.path == '/v1/auth/refresh') {
            return const FakeReply.json(200, {
              'access_token': 'access-1',
              'access_token_expires_at': '2030-01-01T00:00:00Z',
              'refresh_token': 'refresh-2',
            });
          }
          if (request.path == '/v1/me' && request.bearer == 'access-1') {
            return FakeReply.problem(401, 'session_revoked');
          }
          return FakeReply.problem(404, 'not_found');
        });
        usePhoneScreen(tester);
        final fakes = TestFakes();
        final container = ProviderContainer.test(
          retry: (retryCount, error) => null,
          // The real account repository over the fake network (no FakeAuthRepository).
          overrides: [
            appConfigProvider.overrideWithValue(devConfig),
            clientInfoProvider.overrideWithValue(testClientInfo),
            secureStoreProvider.overrideWithValue(store),
            deviceInfoSourceProvider.overrideWithValue(fakes.device),
            preferencesStoreProvider.overrideWithValue(fakes.prefs),
            localAuthGatewayProvider.overrideWithValue(fakes.localAuth),
            screenPrivacyProvider.overrideWithValue(fakes.privacy),
            apiHttpAdapterProvider.overrideWithValue(adapter),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const AfterMeApp(),
          ),
        );
        await tester.pumpAndSettle();
        // The restored session shows Home; loading the account hits the revoked session.
        expect(adapter.requests.map((r) => r.path), contains('/v1/me'));
        expect(container.read(authControllerProvider), AuthStatus.signedOut);
        expect(find.byType(WelcomeScreen), findsNothing);
        expect(find.byType(SignInScreen), findsOneWidget);
        expect(find.text('Please sign in again.'), findsOneWidget);
        expect(container.read(sessionEndedNoticeProvider), isTrue);
        expect(store.values, isEmpty);
        expect(container.read(sessionStoreProvider).accessToken, isNull);
        expect(await container.read(meControllerProvider.future), isNull);
      },
    );
  });
}
