import 'package:afterme/app/app.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'pump_app.dart';
import 'test_app.dart';

/// Opens the app as a signed-in person who finished onboarding, at [route].
Future<ProviderContainer> openApp(
  WidgetTester tester, {
  TestFakes? fakes,
  String route = AppRoutes.people,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool settle = true,
  bool roboto = false,
}) async {
  final f = fakes ?? TestFakes();
  f.prefs = freshPreferences({
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': true,
  });
  final container = await pumpAfterMe(
    tester,
    fakes: f,
    status: AuthStatus.signedIn,
    size: size,
    textScale: textScale,
    settle: settle,
    extraOverrides: [
      if (roboto) fontFamilyProvider.overrideWithValue('Roboto'),
    ],
  );
  if (route != AppRoutes.home) {
    container.read(routerProvider).go(route);
  }
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

/// The visible text of the current snack bar, if any.
String? snackText(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Text),
  );
  if (finder.evaluate().isEmpty) {
    return null;
  }
  return tester.widget<Text>(finder.first).data;
}

/// The inline error under the text field labelled [label].
String? fieldError(WidgetTester tester, String label) => tester
    .widget<TextField>(find.widgetWithText(TextField, label))
    .decoration
    ?.errorText;

Future<void> fillContactForm(
  WidgetTester tester, {
  String name = 'Mom',
  String relationship = 'Mother',
  String email = 'mom@example.com',
  String? phone,
}) async {
  await typeInto(tester, 'Their name', name);
  await tapText(tester, relationship);
  await typeInto(tester, 'Their email', email);
  if (phone != null) {
    await typeInto(tester, 'Their phone (optional)', phone);
  }
}
