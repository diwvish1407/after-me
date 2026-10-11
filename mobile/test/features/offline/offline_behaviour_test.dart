import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/status_banner.dart';
import 'package:afterme/core/freshness/stale_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

/// What every screen that reads from the server shows when a refresh fails while it has
/// data: the last known information with a note, never an empty error (USER_FLOWS.md §14).
const _note = 'Showing the last information we have';

Future<void> _pull(WidgetTester tester) async {
  await tester.fling(find.byType(Scrollable).first, const Offset(0, 400), 800);
  await tester.pumpAndSettle();
}

TestFakes _world() {
  final fakes = TestFakes();
  fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
  fakes.plan.seedStandard(['c1']);
  return fakes;
}

void main() {
  group('People', () {
    testWidgets('a failed refresh keeps the contacts and says they are the '
        'last information we have; the next read removes the note', (
      tester,
    ) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.people);
      expect(find.text('Mom'), findsOneWidget);
      expect(find.textContaining(_note), findsNothing);

      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await _pull(tester);
      expect(find.text('Mom'), findsOneWidget);
      expect(find.textContaining(_note), findsOneWidget);
      expect(find.text('Try again'), findsNothing, reason: 'not an error page');

      await _pull(tester);
      expect(find.text('Mom'), findsOneWidget);
      expect(find.textContaining(_note), findsNothing);
    });

    testWidgets('a server problem is the same: the data stays', (tester) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.people);
      fakes.contacts.failures['list'] = [const ServerFailure(statusCode: 500)];
      await _pull(tester);
      expect(find.text('Mom'), findsOneWidget);
      expect(find.textContaining(_note), findsOneWidget);
    });

    testWidgets('a first load that fails is an error with Try again, not a '
        'note', (tester) async {
      final fakes = _world();
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.people);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.textContaining(_note), findsNothing);
    });

    testWidgets('the note is forgotten when the sign-in status changes', (
      tester,
    ) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.people,
      );
      fakes.contacts.failures['list'] = [const NetworkFailure()];
      await _pull(tester);
      expect(container.read(staleDataProvider), {DataArea.contacts});
      (container.read(authControllerProvider.notifier) as FixedAuthController)
          .set(AuthStatus.signedOut);
      await tester.pumpAndSettle();
      expect(container.read(staleDataProvider), isEmpty);
    });
  });

  group('Instructions', () {
    testWidgets('a failed refresh keeps the list with the note', (
      tester,
    ) async {
      final fakes = _world();
      fakes.instructions.seed(title: 'House emergency');
      await openApp(tester, fakes: fakes, route: AppRoutes.instructions);
      expect(find.text('House emergency'), findsOneWidget);
      fakes.instructions.failures['list'] = [const NetworkFailure()];
      await _pull(tester);
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.textContaining(_note), findsOneWidget);
      await _pull(tester);
      expect(find.textContaining(_note), findsNothing);
    });
  });

  group('Plan', () {
    testWidgets('a failed refresh keeps the plan with the note', (
      tester,
    ) async {
      final fakes = _world();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      fakes.plan.failures['get'] = [const NetworkFailure()];
      await _pull(tester);
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.textContaining(_note), findsOneWidget);
      await _pull(tester);
      expect(find.textContaining(_note), findsNothing);
    });
  });

  group('Home', () {
    testWidgets('a failed refresh keeps the last known status and says so', (
      tester,
    ) async {
      final fakes = _world();
      fakes.server.activateNow();
      await openApp(tester, fakes: fakes, route: AppRoutes.home);
      expect(find.text("You're checked in"), findsOneWidget);
      fakes.server.failures['home'] = [const NetworkFailure()];
      await _pull(tester);
      expect(find.text("You're checked in"), findsOneWidget);
      expect(find.text('Offline — showing last known status'), findsOneWidget);
    });
  });

  testWidgets('the note is announced and has an icon and words, not colour '
      'alone', (tester) async {
    final fakes = _world();
    final handle = tester.ensureSemantics();
    await openApp(tester, fakes: fakes, route: AppRoutes.people);
    fakes.contacts.failures['list'] = [const NetworkFailure()];
    await _pull(tester);
    final semantics = tester.getSemantics(find.textContaining(_note));
    expect(semantics.label, contains(_note));
    expect(
      find.descendant(
        of: find.byType(StatusBanner),
        matching: find.byType(Icon),
      ),
      findsWidgets,
    );
    handle.dispose();
  });

  test('every area has its own flag', () {
    final container = ProviderContainer.test();
    final stale = container.read(staleDataProvider.notifier);
    for (final area in DataArea.values) {
      stale.mark(area);
    }
    expect(container.read(staleDataProvider), DataArea.values.toSet());
    stale
      ..mark(DataArea.plan)
      ..clear(DataArea.plan);
    expect(container.read(staleDataProvider), isNot(contains(DataArea.plan)));
  });
}
