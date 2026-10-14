import 'package:afterme/app/app.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'fake_auth_repository.dart';
import 'test_app.dart';

/// Pumps the whole app with all Phase 2 fakes. Returns the container so tests can
/// read providers.
///
/// With [status] the auth status is fixed (no storage); without it the real
/// [AuthController] runs on an in-memory secure store, so a real sign-in works.
Future<ProviderContainer> pumpAfterMe(
  WidgetTester tester, {
  TestFakes? fakes,
  AuthStatus? status,
  AppConfig? config,
  SecureStore? secureStore,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool settle = true,
  List<Override> extraOverrides = const [],
  List<ProviderObserver> observers = const [],
}) async {
  usePhoneScreen(tester, size: size);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    observers: observers,
    overrides: [
      ...testOverrides(
        config: config,
        authStatus: status,
        secureStore: secureStore,
        fakes: fakes ?? TestFakes(),
      ),
      ...extraOverrides,
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const AfterMeApp()),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

/// Types [text] into the text field labelled [label].
Future<void> typeInto(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

/// Taps the first widget with [text], scrolling it into view first.
Future<void> tapText(WidgetTester tester, String text) async {
  final finder = find.text(text).hitTestable().first;
  await tester.ensureVisible(find.text(text).first);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

/// The fake repository of [container] (when it was created with [TestFakes]).
FakeAuthRepository authOf(ProviderContainer container) =>
    container.read(authRepositoryProvider) as FakeAuthRepository;
