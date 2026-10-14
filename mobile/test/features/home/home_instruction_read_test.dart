import 'package:afterme/app/router.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/test_app.dart';

/// Deferred defect (Phase 9 -> 10 hand-off): since Phase 9 reading the instruction list
/// needs a password entered in the last five minutes, and Home's start-up asked for the
/// list anyway (it listened to the list controller, and so did the setup controller it
/// shows the checklist from). The answer, `403 reauth_required`, was swallowed, but it was
/// a request that could not succeed on every cold start. Home does not need the list at
/// all: the aggregate carries the counts.
void main() {
  group('Home at start-up', () {
    testWidgets('does not ask for the instruction list when reading it needs '
        'the password', (tester) async {
      final fakes = TestFakes();
      fakes.instructions.readsNeedPassword = true;
      fakes.server.activateNow();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(
        fakes.instructions.calls.where((c) => c == 'list'),
        isEmpty,
        reason: 'no request that cannot succeed',
      );
      expect(fakes.instructions.readReauthAsked, 0);
      // No prompt and no error state anywhere.
      expect(find.byType(ReauthSheet), findsNothing);
      expect(find.text('Try again'), findsNothing);
      // The list controller was never even started by Home.
      expect(container.exists(instructionsControllerProvider), isFalse);
    });

    testWidgets('still follows the instructions once the list has been read '
        'for another screen', (tester) async {
      final fakes = TestFakes();
      fakes.server.activateNow();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      await tester.pumpAndSettle();
      final before = fakes.server.calls.where((c) => c == 'home').length;

      // Another screen (the Instructions tab) reads the list and then changes it.
      await container.read(instructionsControllerProvider.future);
      await container.read(instructionsControllerProvider.notifier).reload();
      await tester.pumpAndSettle();
      expect(
        fakes.server.calls.where((c) => c == 'home').length,
        greaterThanOrEqualTo(before),
      );
    });
  });
}
