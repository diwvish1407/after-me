import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

TestFakes _fakes([List<TrustedContact>? contacts]) =>
    TestFakes()
      ..contacts = InMemoryContactsRepository(
        tier: 'premium',
        initial:
            contacts ??
            [
              testContact(),
              testContact(
                id: 'c2',
                name: 'Brother',
                relationship: ContactRelationship.sibling,
                email: 'bro@example.com',
                priority: 2,
              ),
            ],
      );

void main() {
  group('Plan tab', () {
    testWidgets('a plan: the grace period, who is told when and what would '
        'happen', (tester) async {
      final fakes = _fakes();
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
            PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1', 'c2']),
          ],
        ),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);

      expect(find.byType(PlanScreen), findsOneWidget);
      expect(find.text('Grace period'), findsOneWidget);
      expect(
        find.text(
          "If you miss a check-in, we'll remind you for 3 hours before anyone is contacted.",
        ),
        findsOneWidget,
      );
      expect(find.text('Who is told, and when'), findsOneWidget);
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(find.text('Stage 2: after 1 day'), findsOneWidget);
      expect(find.text('Notify: Mom and Brother'), findsOneWidget);
      // The worked preview, with the schedule's 8:00 PM.
      expect(find.text('What would happen'), findsOneWidget);
      expect(
        find.text('If you miss 8:00 PM, we remind you first.'),
        findsOneWidget,
      );
      expect(find.text('At 11:00 PM, Mom is notified.'), findsOneWidget);
      expect(
        find.text('At 8:00 PM the next day, Mom and Brother are notified.'),
        findsOneWidget,
      );
      // Read-only: no editor is offered here.
      expect(find.text('Set up your plan'), findsNothing);
      expect(find.text('Use this plan'), findsNothing);
    });

    testWidgets('the way into the editor and the past incidents, and what '
        'a stage shares', (tester) async {
      final fakes = _fakes();
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
            PlanStageDraft(offsetMinutes: 1440, contactIds: ['c2']),
          ],
        ),
      );
      fakes.instructions.seed(
        title: 'House emergency',
        recipients: {'c2': fakes.plan.stages.last.id},
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);

      expect(find.text('Shares 1 instruction'), findsOneWidget);
      expect(
        find.text(
          'At 8:00 PM the next day, Brother is notified. 1 instruction is also shared.',
        ),
        findsOneWidget,
      );
      expect(find.text('Edit your plan'), findsOneWidget);
      expect(find.text('Past incidents'), findsOneWidget);
      expect(find.text('Missed check-ins and how they ended'), findsOneWidget);
    });

    testWidgets('a contact that is not on the list is never shown by id', (
      tester,
    ) async {
      final fakes = _fakes([testContact()]);
      fakes.plan.seed(
        const PlanDraft(
          graceMinutes: 180,
          stages: [
            PlanStageDraft(offsetMinutes: 180, contactIds: ['c1', 'ghost']),
            PlanStageDraft(offsetMinutes: 1440, contactIds: ['ghost']),
          ],
        ),
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.text('Notify: Mom'), findsOneWidget);
      expect(find.text('Nobody to notify yet'), findsOneWidget);
    });

    testWidgets('no stages yet: one calm action that opens the plan step', (
      tester,
    ) async {
      await openApp(tester, fakes: _fakes(), route: AppRoutes.plan);
      expect(find.text("You haven't set up a plan yet"), findsOneWidget);
      expect(
        find.textContaining('this arrives in a later phase'),
        findsNothing,
      );
      await tapText(tester, 'Set up your plan');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Use this plan'), findsOneWidget);
    });

    testWidgets('loading shows a progress indicator', (tester) async {
      final gate = Completer<void>();
      final fakes = _fakes()..plan.gate = gate.future;
      await openApp(tester, fakes: fakes, route: AppRoutes.plan, settle: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text("You haven't set up a plan yet"), findsOneWidget);
    });

    testWidgets('an error can be retried', (tester) async {
      final fakes = _fakes();
      fakes.plan.failures['get'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text('Set up your plan'), findsNothing);

      fakes.plan.seedStandard(['c1']);
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 3 hours'), findsOneWidget);
    });

    testWidgets('pulling down reads the plan again', (tester) async {
      final fakes = _fakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.plan);
      expect(find.text("You haven't set up a plan yet"), findsOneWidget);

      fakes.plan.seedStandard(['c1'], offsetMinutes: 360);
      await tester.fling(
        find.text("You haven't set up a plan yet"),
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
    });
  });
}
