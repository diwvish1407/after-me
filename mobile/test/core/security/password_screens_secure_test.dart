import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// Phase 9 (S4): a password is typed, or a file of the person's data is requested, only
/// behind `FLAG_SECURE`: no screenshot, no screen recording and nothing in the recents
/// card (SECURITY.md §11, ARCHITECTURE.md §5.6). The flag follows what is on screen, so
/// it is gone again when the person leaves.
void main() {
  late ProviderContainer container;

  Future<TestFakes> signedOutAt(WidgetTester tester, String route) async {
    final fakes = TestFakes();
    container = await pumpAfterMe(
      tester,
      fakes: fakes,
      status: AuthStatus.signedOut,
    );
    expect(fakes.secureScreen.secure, isFalse, reason: 'the welcome page');
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();
    return fakes;
  }

  testWidgets('sign in holds the flag while it is open', (tester) async {
    final fakes = await signedOutAt(tester, AppRoutes.signIn);
    expect(fakes.secureScreen.secure, isTrue);
    container.read(routerProvider).go(AppRoutes.welcome);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse);
  });

  testWidgets('create account holds the flag while it is open', (tester) async {
    final fakes = await signedOutAt(tester, AppRoutes.createAccount);
    expect(fakes.secureScreen.secure, isTrue);
    container.read(routerProvider).go(AppRoutes.welcome);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse);
  });

  for (final (name, route) in [
    ('change password', AppRoutes.settingsChangePassword),
    ('export my data', AppRoutes.settingsExport),
    ('delete account', AppRoutes.settingsDelete),
  ]) {
    testWidgets('$name holds the flag while it is open', (tester) async {
      final fakes = TestFakes();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settings,
      );
      expect(fakes.secureScreen.secure, isFalse, reason: 'Settings itself');
      container.read(routerProvider).go(route);
      await tester.pumpAndSettle();
      expect(fakes.secureScreen.secure, isTrue);
      expect(fakes.secureScreen.enabledCount, 1);

      container.read(routerProvider).go(AppRoutes.settings);
      await tester.pumpAndSettle();
      expect(fakes.secureScreen.secure, isFalse);
    });
  }

  testWidgets('the password sheet holds the flag while it is open, on any '
      'screen', (tester) async {
    final fakes = TestFakes();
    final container = await pumpAfterMe(
      tester,
      fakes: fakes,
      status: AuthStatus.signedIn,
    );
    container.read(routerProvider).go(AppRoutes.settingsAbout);
    await tester.pumpAndSettle();
    expect(fakes.secureScreen.secure, isFalse, reason: 'About is not secure');

    final context = tester.element(find.byType(Scaffold).last);
    unawaited(showReauthSheet(context));
    await tester.pumpAndSettle();
    expect(find.text("Confirm it's you"), findsOneWidget);
    expect(fakes.secureScreen.secure, isTrue);

    await tapText(tester, 'Cancel');
    await tester.pumpAndSettle();
    expect(find.text("Confirm it's you"), findsNothing);
    expect(fakes.secureScreen.secure, isFalse);
  });
}
