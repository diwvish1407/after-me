import 'package:afterme/app/app.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/presentation/sign_in_screen.dart';
import 'package:afterme/features/dev/presentation/design_gallery_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/presentation/splash_screen.dart';
import 'package:afterme/features/onboarding/presentation/welcome_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required AuthStatus status,
  AppConfig? config,
}) async {
  usePhoneScreen(tester);
  final container = ProviderContainer.test(
    overrides: testOverrides(config: config, authStatus: status),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const AfterMeApp()),
  );
  await tester.pump();
  // Onboarding progress is read from preferences before a signed-in user is routed on.
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  group('authRedirect', () {
    const all = [
      AppRoutes.splash,
      AppRoutes.welcome,
      AppRoutes.signIn,
      AppRoutes.devGallery,
      ...AppRoutes.shellTabs,
      '/nowhere',
    ];

    test('unknown sends everything to the splash', () {
      for (final isDev in [true, false]) {
        for (final location in all) {
          expect(
            authRedirect(
              status: AuthStatus.unknown,
              location: location,
              isDev: isDev,
            ),
            location == AppRoutes.splash ? isNull : AppRoutes.splash,
            reason: location,
          );
        }
      }
    });

    test('signedOut allows only public routes (gallery only in dev)', () {
      String? redirect(String location, {required bool isDev}) => authRedirect(
        status: AuthStatus.signedOut,
        location: location,
        isDev: isDev,
      );

      expect(redirect(AppRoutes.welcome, isDev: false), isNull);
      expect(redirect(AppRoutes.signIn, isDev: false), isNull);
      expect(redirect(AppRoutes.devGallery, isDev: true), isNull);
      expect(redirect(AppRoutes.devGallery, isDev: false), AppRoutes.welcome);
      expect(redirect(AppRoutes.splash, isDev: true), AppRoutes.welcome);
      expect(redirect('/nowhere', isDev: true), AppRoutes.welcome);
      for (final tab in AppRoutes.shellTabs) {
        expect(redirect(tab, isDev: true), AppRoutes.welcome, reason: tab);
      }
    });

    test('signedIn leaves public routes and the splash for /home', () {
      String? redirect(String location, {required bool isDev}) => authRedirect(
        status: AuthStatus.signedIn,
        location: location,
        isDev: isDev,
      );

      for (final tab in AppRoutes.shellTabs) {
        expect(redirect(tab, isDev: true), isNull, reason: tab);
      }
      for (final location in [
        AppRoutes.splash,
        AppRoutes.welcome,
        AppRoutes.signIn,
        AppRoutes.devGallery,
        '/nowhere',
      ]) {
        expect(
          redirect(location, isDev: true),
          AppRoutes.home,
          reason: location,
        );
        expect(
          redirect(location, isDev: false),
          AppRoutes.home,
          reason: location,
        );
      }
    });

    test('known and public route sets', () {
      expect(
        AppRoutes.publicRoutes(isDev: false),
        isNot(contains(AppRoutes.devGallery)),
      );
      expect(
        AppRoutes.knownRoutes(isDev: false),
        isNot(contains(AppRoutes.devGallery)),
      );
      expect(
        AppRoutes.knownRoutes(isDev: true),
        contains(AppRoutes.devGallery),
      );
    });
  });

  group('router', () {
    testWidgets('unknown status shows the splash', (tester) async {
      await _pumpApp(tester, status: AuthStatus.unknown);
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.text('Getting things ready'), findsOneWidget);
    });

    testWidgets('signedOut shows the welcome screen', (tester) async {
      await _pumpApp(tester, status: AuthStatus.signedOut);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('signedIn shows home', (tester) async {
      await _pumpApp(tester, status: AuthStatus.signedIn);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('auth status changes drive navigation', (tester) async {
      final container = await _pumpApp(tester, status: AuthStatus.unknown);
      final auth = container.read(
        authControllerProvider.notifier,
      ) as FixedAuthController;

      auth.set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);

      auth.set(AuthStatus.signedIn);
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      auth.set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('a restored session goes from splash to home', (tester) async {
      usePhoneScreen(tester);
      final container = ProviderContainer.test(
        overrides: testOverrides(
          secureStore: InMemorySecureStore({SessionKeys.refreshToken: 'r'}),
        ),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const AfterMeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    testWidgets('dev: the gallery is reachable from welcome', (tester) async {
      await _pumpApp(tester, status: AuthStatus.signedOut, config: devConfig);
      final link = find.text('Design system gallery (developer build)');
      await tester.scrollUntilVisible(link, 100);
      await tester.tap(link);
      // The gallery shows spinners forever, so pump frames instead of settling.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(DesignGalleryScreen), findsOneWidget);
    });

    testWidgets('prod: no gallery link, and the route redirects away', (
      tester,
    ) async {
      final container = await _pumpApp(
        tester,
        status: AuthStatus.signedOut,
        config: prodConfig,
      );
      expect(
        find.text('Design system gallery (developer build)'),
        findsNothing,
      );

      container.read(routerProvider).go(AppRoutes.devGallery);
      await tester.pumpAndSettle();

      expect(find.byType(DesignGalleryScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('prod: the gallery route is not even registered', (
      tester,
    ) async {
      final container = await _pumpApp(
        tester,
        status: AuthStatus.signedIn,
        config: prodConfig,
      );
      final router = container.read(routerProvider);
      expect(
        router.configuration.findMatch(Uri.parse(AppRoutes.devGallery)).isEmpty,
        isTrue,
      );
      router.go(AppRoutes.devGallery);
      await tester.pumpAndSettle();
      expect(find.byType(DesignGalleryScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('sign-in link opens the sign-in screen and back returns', (
      tester,
    ) async {
      await _pumpApp(tester, status: AuthStatus.signedOut);
      final link = find.text('I already have an account');
      await tester.scrollUntilVisible(link, 100);
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('the router is a GoRouter starting at the splash', (
      tester,
    ) async {
      final container = await _pumpApp(tester, status: AuthStatus.unknown);
      final router = container.read(routerProvider);
      expect(router, isA<GoRouter>());
      expect(
        router.routerDelegate.currentConfiguration.uri.path,
        AppRoutes.splash,
      );
    });
  });
}
