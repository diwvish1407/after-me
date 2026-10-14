import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/notifications/application/push_message.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:afterme/features/plan/presentation/plan_editor_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/test_app.dart';

/// A notification tap navigates with the router's `go`, which replaces the page stack and
/// would drop the plan editor's draft. The two kinds of tap are treated differently:
///
///  * about a check-in or an incident (a reminder, a missed check-in, contacts told, the
///    final warning, an interruption): **never** held up and never dropped. Home is put on
///    top of the editor, which stays underneath with its draft; a save on its way is
///    waited for first. The person always reaches I'M OK or I'M SAFE.
///  * anything else (a contact that could not be reached): asks "Leave without
///    saving?", and goes only if the person leaves.
IncomingPush _tap(String type) => IncomingPush(data: {'type': type, 'v': '1'});

TestFakes _world() {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: 'premium',
      initial: [
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
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c2']),
      ],
    ),
  );
  fakes.push.configured = true;
  fakes.notifications.current = NotificationPermission.granted;
  fakes.realPushNavigation = true;
  return fakes;
}

Future<void> _dirtyTheEditor(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ChoiceChip, '6 hours').first);
  await tester.pumpAndSettle();
  expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
}

/// The editor reached from the Plan tab, with a change.
Future<TestFakes> _editorFromPlanTab(WidgetTester tester) async {
  final fakes = _world();
  await openApp(tester, fakes: fakes, route: AppRoutes.plan);
  await tester.tap(find.text('Edit your plan'));
  await tester.pumpAndSettle();
  await _dirtyTheEditor(tester);
  return fakes;
}

/// The editor reached the way Home's banner does (`push`), with a change.
Future<TestFakes> _editorPushedFromHome(WidgetTester tester) async {
  final fakes = _world();
  final container = await openApp(tester, fakes: fakes, route: AppRoutes.home);
  unawaited(container.read(routerProvider).push(AppRoutes.planEdit));
  await tester.pumpAndSettle();
  expect(find.byType(PlanEditorScreen), findsOneWidget);
  await _dirtyTheEditor(tester);
  return fakes;
}

void _expectHomeOnTop(WidgetTester tester) {
  expect(find.text('Leave without saving?'), findsNothing);
  expect(find.byType(HomeScreen), findsOneWidget);
  expect(
    find.text("I'M OK"),
    findsOneWidget,
    reason: 'the way out is on screen',
  );
}

Future<void> _backToTheEditor(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
  expect(find.byType(PlanEditorScreen), findsOneWidget);
  expect(
    find.text('Stage 1: after 6 hours'),
    findsOneWidget,
    reason: 'the draft is still there',
  );
}

void main() {
  group('which taps are urgent', () {
    test('everything that is about a check-in or an incident, and a type this '
        'version does not know', () {
      for (final type in [
        'checkin_pre_reminder',
        'incident_missed',
        'incident_midpoint',
        'incident_last_chance',
        'incident_delayed',
        'stage_executed',
        'release_final_warning',
        'service_interruption',
      ]) {
        expect(PushType.fromWire(type)!.isUrgent, isTrue, reason: type);
        expect(tapIsUrgent({'type': type, 'v': '1'}), isTrue, reason: type);
      }
      expect(tapIsUrgent({'type': 'something_new', 'v': '1'}), isTrue);
      expect(tapIsUrgent(const {}), isTrue);
    });

    test('and only a notice that asks for nothing now may wait', () {
      expect(PushType.contactUnreachable.isUrgent, isFalse);
      expect(PushType.allClearConfirmation.isUrgent, isFalse);
    });
  });

  group('an incident tap while the plan editor has unsaved changes', () {
    for (final type in [
      'incident_missed',
      'stage_executed',
      'release_final_warning',
      'service_interruption',
    ]) {
      testWidgets(
        '$type from the Plan tab: Home is on top, the draft is kept',
        (tester) async {
          final fakes = await _editorFromPlanTab(tester);
          fakes.push.opened.add(_tap(type));
          await tester.pumpAndSettle();
          _expectHomeOnTop(tester);
          await _backToTheEditor(tester);
          expect(fakes.plan.saved, isEmpty);
        },
      );
    }

    testWidgets('pushed from Home (the banner\'s way): Home is on top and '
        'Back returns to the draft', (tester) async {
      final fakes = await _editorPushedFromHome(tester);
      fakes.push.opened.add(_tap('incident_missed'));
      await tester.pumpAndSettle();
      _expectHomeOnTop(tester);
      await _backToTheEditor(tester);
    });

    testWidgets('a push the app showed itself behaves the same', (
      tester,
    ) async {
      final fakes = await _editorPushedFromHome(tester);
      fakes.localNotifications.tap('incident_missed');
      await tester.pumpAndSettle();
      _expectHomeOnTop(tester);
    });

    testWidgets('while a save is on its way: waits for it, and the person ends '
        'on Home with the plan saved', (tester) async {
      final fakes = await _editorPushedFromHome(tester);
      final gate = Completer<void>();
      fakes.plan.gate = gate.future;
      final save = find.widgetWithText(FilledButton, 'Save changes');
      await tester.ensureVisible(save);
      await tester.pump();
      await tester.tap(save);
      await tester.pump();

      fakes.push.opened.add(_tap('incident_missed'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Leave without saving?'), findsNothing);
      expect(
        fakes.plan.calls.where((c) => c == 'save'),
        hasLength(1),
        reason: 'the save is on the wire, and not cut short',
      );

      gate.complete();
      await tester.pumpAndSettle();
      expect(
        find.byType(PlanEditorScreen),
        findsNothing,
        reason: 'saved, closed',
      );
      _expectHomeOnTop(tester);
    });

    testWidgets('with a clean editor the tap just goes to Home', (
      tester,
    ) async {
      final fakes = _world();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      unawaited(container.read(routerProvider).push(AppRoutes.planEdit));
      await tester.pumpAndSettle();
      fakes.push.opened.add(_tap('incident_missed'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(PlanEditorScreen), findsNothing);
    });

    testWidgets(
      'a notification that started the app opens Home, asks nothing',
      (tester) async {
        final fakes = _world();
        fakes.push.initial = _tap('incident_missed');
        await openApp(tester, fakes: fakes, route: AppRoutes.home);
        await tester.pumpAndSettle();
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(find.text('Leave without saving?'), findsNothing);
      },
    );
  });

  group('a notice that can wait while the plan editor has unsaved changes', () {
    testWidgets('asks first; "Keep editing" stays with the draft', (
      tester,
    ) async {
      final fakes = await _editorFromPlanTab(tester);
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanEditorScreen), findsOneWidget);
      expect(find.text('Stage 1: after 6 hours'), findsOneWidget);
      expect(find.byType(PeopleScreen), findsNothing);
    });

    testWidgets('"Leave" goes where the notification asked and drops the '
        'changes (a retained tab does not ask again)', (tester) async {
      final fakes = await _editorFromPlanTab(tester);
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(find.byType(PeopleScreen), findsOneWidget);
      expect(fakes.plan.saved, isEmpty);

      // A later tap is not held up by the editor that is still alive in its tab.
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsNothing);
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets('a second tap while the question is open does not stack '
        'another one', (tester) async {
      final fakes = await _editorPushedFromHome(tester);
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pump();
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsNothing);
      expect(find.byType(PlanEditorScreen), findsOneWidget);
    });

    testWidgets('an incident tap while the question is open still reaches '
        'Home, and the late answer does not move the person again', (
      tester,
    ) async {
      final fakes = await _editorPushedFromHome(tester);
      fakes.push.opened.add(_tap('contact_unreachable'));
      await tester.pumpAndSettle();
      expect(find.text('Leave without saving?'), findsOneWidget);

      fakes.push.opened.add(_tap('incident_missed'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsWidgets);
      expect(find.text("I'M OK"), findsOneWidget);
    });
  });
}
