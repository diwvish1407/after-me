import 'dart:async';

import 'package:afterme/app/start.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/config/misconfigured_build_app.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/onboarding/presentation/splash_screen.dart';
import 'package:afterme/features/onboarding/presentation/welcome_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_app.dart';

PackageInfo _info(String id) => PackageInfo(
  appName: 'AfterMe',
  packageName: id,
  version: '0.1.0',
  buildNumber: '1',
);

/// The first frame does not wait for the platform (PERF-05): the splash is on screen
/// while `PackageInfo` is still pending, and the app starts only after the build's
/// identity has been checked (fail closed, as before).
void main() {
  List<Override> overrides(TestFakes fakes) => [
    secureStoreProvider.overrideWithValue(fakes.secure),
    ...fakes.overrides,
    authControllerProvider.overrideWith(
      () => FixedAuthController(AuthStatus.signedOut),
    ),
  ];

  testWidgets('the splash is the first frame, before the package is known, and '
      'no provider exists yet', (tester) async {
    final gate = Completer<PackageInfo>();
    var reads = 0;
    await tester.pumpWidget(
      AfterMeStart(
        config: devConfig,
        loadPackageInfo: () {
          reads++;
          return gate.future;
        },
        extraOverrides: overrides(TestFakes()),
      ),
    );
    expect(find.byType(SplashScreen), findsOneWidget);
    expect(find.byType(ProviderScope), findsNothing);
    expect(find.byType(WelcomeScreen), findsNothing);
    expect(reads, 1);

    // A rebuild does not read it again.
    await tester.pump();
    expect(reads, 1);

    gate.complete(_info('app.afterme.dev'));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byType(MisconfiguredBuildApp), findsNothing);
  });

  testWidgets('a flavor that does not belong to its configuration never '
      'starts the app', (tester) async {
    await tester.pumpWidget(
      AfterMeStart(
        config: devConfig,
        loadPackageInfo: () async => _info('app.afterme'),
        extraOverrides: overrides(TestFakes()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MisconfiguredBuildApp), findsOneWidget);
    expect(find.byType(ProviderScope), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const Key('misconfigured-detail'))).data,
      contains('APP_ENV is dev'),
    );
  });

  testWidgets('a package that cannot be read stops the app too', (
    tester,
  ) async {
    await tester.pumpWidget(
      AfterMeStart(
        config: devConfig,
        loadPackageInfo: () async => throw StateError('no platform'),
        extraOverrides: overrides(TestFakes()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MisconfiguredBuildApp), findsOneWidget);
    expect(find.byType(ProviderScope), findsNothing);
    expect(find.byType(WelcomeScreen), findsNothing);
  });

  testWidgets('leaving before the answer arrives is quiet', (tester) async {
    final gate = Completer<PackageInfo>();
    await tester.pumpWidget(
      AfterMeStart(config: devConfig, loadPackageInfo: () => gate.future),
    );
    await tester.pumpWidget(const SizedBox());
    gate.complete(_info('app.afterme.dev'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
