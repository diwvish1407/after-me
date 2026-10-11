import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/fake_http_adapter.dart';
import '../../helpers/http_world.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// SECURITY.md §7 (Phase 9): `GET /v1/instructions` and `GET /v1/instructions/{id}` answer
/// 403 `reauth_required` unless the person entered their password in the last 5 minutes.
/// The list, an instruction's page and the plan editor's names go through `withReauth`
/// like every other step-up: one prompt, then the same read once more. Closing the sheet
/// is calm and leaves the screen usable, a wrong password stays in the sheet, a refusal
/// after the password is not asked about again, and none of it ends the session.

const _sheetTitle = "Confirm it's you";
const _readReason =
    'Your instructions stay hidden until you confirm your password, so nobody who '
    'picks up your phone can read them.';
const _stayHidden =
    'Your instructions stay hidden until you confirm your password.';

/// Mom is told at 3 hours and at 1 day. Two instructions, the older one released to Mom
/// at the 1 day stage. The server asks for the password on every read until it is given.
TestFakes _locked() {
  final fakes = TestFakes()
    ..contacts = InMemoryContactsRepository(
      tier: 'premium',
      initial: [testContact()],
    );
  fakes.plan.seed(
    const PlanDraft(
      graceMinutes: 180,
      stages: [
        PlanStageDraft(offsetMinutes: 180, contactIds: ['c1']),
        PlanStageDraft(offsetMinutes: 1440, contactIds: ['c1']),
      ],
    ),
  );
  fakes.instructions
    ..seed(
      title: 'House emergency',
      body: 'The spare key is with a neighbour.',
      recipients: {'c1': fakes.plan.stages.last.id},
    )
    ..seed(title: 'Car keys', category: InstructionCategory.personal)
    ..readsNeedPassword = true;
  return fakes;
}

int _calls(TestFakes fakes, String method) =>
    fakes.instructions.calls.where((c) => c == method).length;

int _reauths(TestFakes fakes) =>
    fakes.auth.calls.where((c) => c == 'reauth').length;

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _confirm(WidgetTester tester, String password) async {
  await typeInto(tester, 'Password', password);
  await tapText(tester, 'Confirm');
  await _frames(tester);
}

void main() {
  group('the controller', () {
    ProviderContainer container(TestFakes fakes) {
      final c = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
      );
      c.listen(instructionsControllerProvider, (_, _) {});
      return c;
    }

    test(
      'a refused first read is a state, not a failure of the session',
      () async {
        final fakes = _locked();
        final c = container(fakes);
        await expectLater(
          c.read(instructionsControllerProvider.future),
          throwsA(
            isA<ForbiddenFailure>().having(
              (e) => e.code,
              'code',
              'reauth_required',
            ),
          ),
        );
        final state = c.read(instructionsControllerProvider);
        expect(state.needsPassword, isTrue);
        expect(state.value, isNull, reason: 'nothing is guessed or shown');
        expect(c.read(authControllerProvider), AuthStatus.signedIn);
        expect(isPasswordRequired(state.error), isTrue);
        expect(isPasswordRequired(const NetworkFailure()), isFalse);
        expect(
          isPasswordRequired(const ForbiddenFailure(code: 'email_unverified')),
          isFalse,
        );
      },
    );

    test('refresh throws what withReauth needs, then reads once the password '
        'is fresh', () async {
      final fakes = _locked();
      final c = container(fakes);
      await expectLater(
        c.read(instructionsControllerProvider.future),
        throwsA(isA<ForbiddenFailure>()),
      );
      final controller = c.read(instructionsControllerProvider.notifier);
      await expectLater(
        controller.refresh(),
        throwsA(
          isA<ForbiddenFailure>().having(
            (e) => e.code,
            'code',
            'reauth_required',
          ),
        ),
      );
      expect(c.read(instructionsControllerProvider).needsPassword, isTrue);

      fakes.auth.reauthenticated = true;
      await controller.refresh();
      final state = c.read(instructionsControllerProvider);
      expect(state.needsPassword, isFalse);
      expect(
        [for (final i in state.value!) i.title],
        ['Car keys', 'House emergency'],
      );
    });

    test(
      'a list that waits for the password is not guessed from one change',
      () async {
        final fakes = _locked();
        final c = container(fakes);
        await expectLater(
          c.read(instructionsControllerProvider.future),
          throwsA(isA<ForbiddenFailure>()),
        );
        final controller = c.read(instructionsControllerProvider.notifier);

        // Writing needs no password here (nobody receives it).
        await controller.addInstruction(
          const InstructionDraft(
            category: InstructionCategory.work,
            title: 'Laptop',
            body: 'In the bag.',
          ),
        );
        await controller.updateInstruction(
          'instruction-2',
          const InstructionPatch(title: 'Car keys (spare)'),
        );
        await Future<void>.delayed(Duration.zero);

        var state = c.read(instructionsControllerProvider);
        expect(state.needsPassword, isTrue);
        expect(state.value, isNull, reason: 'not [Laptop] alone, and not []');

        fakes.auth.reauthenticated = true;
        await controller.refresh();
        state = c.read(instructionsControllerProvider);
        expect([
          for (final i in state.value!) i.title,
        ], unorderedEquals(['Laptop', 'Car keys (spare)', 'House emergency']));
      },
    );

    test('with the password fresh nothing changes for the list', () async {
      final fakes = _locked();
      fakes.auth.reauthenticated = true;
      final c = container(fakes);
      expect(
        (await c.read(instructionsControllerProvider.future)),
        hasLength(2),
      );
      expect(fakes.instructions.readReauthAsked, 0);
    });
  });

  group('the Instructions tab', () {
    Future<TestFakes> open(WidgetTester tester, {TestFakes? fakes}) async {
      final f = fakes ?? _locked();
      await openApp(tester, fakes: f, route: AppRoutes.instructions);
      return f;
    }

    testWidgets('says it is hidden, asks once, then shows the list', (
      tester,
    ) async {
      final fakes = await open(tester);
      expect(find.text('Your instructions are hidden'), findsOneWidget);
      expect(find.text('House emergency'), findsNothing);
      expect(find.text('Car keys'), findsNothing);
      expect(find.text('Write down what someone may need'), findsNothing);
      final before = _calls(fakes, 'list');

      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(find.text(_readReason), findsOneWidget);
      expect(_calls(fakes, 'list'), before + 1, reason: 'asked once, refused');

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text(_sheetTitle), findsNothing);
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Car keys'), findsOneWidget);
      expect(find.text('Your instructions are hidden'), findsNothing);
      expect(_calls(fakes, 'list'), before + 2, reason: 'the same read, once');
      expect(_reauths(fakes), 1);
    });

    testWidgets('closing the sheet is calm and leaves the tab usable', (
      tester,
    ) async {
      final fakes = await open(tester);
      final before = _calls(fakes, 'list');
      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text(_sheetTitle), findsNothing);
      expect(snackText(tester), _stayHidden);
      expect(find.text('Your instructions are hidden'), findsOneWidget);
      expect(_calls(fakes, 'list'), before + 1, reason: 'not read again');
      expect(_reauths(fakes), 0);
      expect(find.byType(FailureNotice), findsNothing);
      // Still usable: it can be asked again, and the tabs still work.
      final show = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Show my instructions'),
      );
      expect(show.onPressed, isNotNull);

      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsOneWidget);
    });

    testWidgets('a wrong password stays in the sheet and reads nothing', (
      tester,
    ) async {
      final fakes = await open(tester);
      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      final afterAttempt = _calls(fakes, 'list');

      await _confirm(tester, 'not the password');
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(_calls(fakes, 'list'), afterAttempt, reason: 'nothing was read');
      expect(find.text('House emergency'), findsNothing);
      expect(find.byType(FailureNotice), findsNothing);

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text('House emergency'), findsOneWidget);
      expect(_calls(fakes, 'list'), afterAttempt + 1);
    });

    testWidgets('a read that is refused after the password is not asked about '
        'again', (tester) async {
      final fakes = await open(tester);
      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      final afterAttempt = _calls(fakes, 'list');

      // The server still says no to the repeated read.
      fakes.instructions.failures['list'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(_calls(fakes, 'list'), afterAttempt + 1, reason: 'repeated once');
      expect(find.text(_sheetTitle), findsNothing, reason: 'no second sheet');
      expect(_reauths(fakes), 1);
      expect(snackText(tester), _stayHidden);
      expect(find.text('Your instructions are hidden'), findsOneWidget);
    });

    testWidgets('a password entered a moment ago needs no sheet', (
      tester,
    ) async {
      final fakes = _locked();
      fakes.auth.reauthenticated = true;
      await open(tester, fakes: fakes);
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text(_sheetTitle), findsNothing);
      expect(fakes.instructions.readReauthAsked, 0);
    });

    testWidgets(
      'after five minutes a refresh asks, and the list on screen stays '
      'while it does',
      (tester) async {
        final fakes = _locked();
        fakes.auth.reauthenticated = true;
        await open(tester, fakes: fakes);
        expect(find.text('House emergency'), findsOneWidget);

        // The window ran out.
        fakes.auth.reauthenticated = false;
        await tester.fling(
          find.text('House emergency'),
          const Offset(0, 400),
          1000,
        );
        await _frames(tester);
        expect(find.text(_sheetTitle), findsOneWidget);
        expect(find.text('House emergency'), findsOneWidget);

        await _confirm(tester, fakes.auth.password);
        await tester.pumpAndSettle();
        expect(find.text(_sheetTitle), findsNothing);
        expect(find.text('House emergency'), findsOneWidget);
        expect(find.byType(FailureNotice), findsNothing);
      },
    );
  });

  group('an instruction\'s page', () {
    Future<TestFakes> open(
      WidgetTester tester, {
      String route = '/instructions/instruction-1',
    }) async {
      final fakes = _locked();
      // The page behind the password sheet shows its loading spinner, which never
      // settles: a few frames instead of pumpAndSettle.
      await openApp(tester, fakes: fakes, route: route, settle: false);
      await _frames(tester);
      return fakes;
    }

    testWidgets('asks at once, then shows the text', (tester) async {
      final fakes = await open(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(find.text(_readReason), findsOneWidget);
      expect(find.text('The spare key is with a neighbour.'), findsNothing);
      expect(_calls(fakes, 'get'), 1);

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text(_sheetTitle), findsNothing);
      expect(find.text('House emergency'), findsWidgets);
      expect(find.text('The spare key is with a neighbour.'), findsOneWidget);
      expect(_calls(fakes, 'get'), 2, reason: 'the same read, once');
      expect(_reauths(fakes), 1);
    });

    testWidgets('closing the sheet says it stays hidden, and can be asked '
        'again', (tester) async {
      final fakes = await open(tester);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);

      expect(find.text(_sheetTitle), findsNothing);
      expect(
        find.text(
          'This instruction stays hidden until you confirm your password. '
          'Nothing was changed.',
        ),
        findsOneWidget,
      );
      expect(find.text('The spare key is with a neighbour.'), findsNothing);
      expect(_calls(fakes, 'get'), 1);
      expect(find.byType(FailureNotice), findsNothing);

      await tapText(tester, 'Show this instruction');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text('The spare key is with a neighbour.'), findsOneWidget);
    });

    testWidgets('a wrong password stays in the sheet', (tester) async {
      final fakes = await open(tester);
      await _confirm(tester, 'not the password');
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(_calls(fakes, 'get'), 1, reason: 'nothing was read');

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text('The spare key is with a neighbour.'), findsOneWidget);
      expect(_calls(fakes, 'get'), 2);
    });

    testWidgets('a read refused again after the password is not asked about '
        'again', (tester) async {
      final fakes = await open(tester);
      fakes.instructions.failures['get'] = [
        const ForbiddenFailure(code: 'reauth_required'),
      ];
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(_calls(fakes, 'get'), 2);
      expect(find.text(_sheetTitle), findsNothing);
      expect(_reauths(fakes), 1);
      expect(
        find.textContaining('stays hidden until you confirm your password'),
        findsOneWidget,
      );
      expect(find.text('Show this instruction'), findsOneWidget);
    });

    testWidgets('the edit page asks the same way and then shows the form', (
      tester,
    ) async {
      final fakes = await open(tester);
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text('The spare key is with a neighbour.'), findsOneWidget);

      // The five minutes run out while the page is open: Edit asks again, once.
      fakes.auth.reauthenticated = false;
      await tapText(tester, 'Edit');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(_calls(fakes, 'get'), 3);

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();
      expect(find.text(_sheetTitle), findsNothing);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, 'Title'))
            .controller!
            .text,
        'House emergency',
      );
      expect(_calls(fakes, 'get'), 4);
      expect(_reauths(fakes), 2);
    });
  });

  group('the plan editor', () {
    Future<TestFakes> open(WidgetTester tester) async {
      final fakes = _locked();
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.planEdit,
        size: const Size(390, 1400),
      );
      return fakes;
    }

    Future<void> removeStageTwo(WidgetTester tester) async {
      final finder = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Remove stage 2',
      );
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    testWidgets('names the instructions of a stage only after the password', (
      tester,
    ) async {
      final fakes = await open(tester);
      expect(find.text('House emergency'), findsNothing);

      await removeStageTwo(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(find.text(_readReason), findsOneWidget);

      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(find.text("Stage 2 can't be removed yet"), findsOneWidget);
      expect(find.text('House emergency'), findsOneWidget);
      expect(find.text('Car keys'), findsNothing, reason: 'not at this stage');
      expect(_reauths(fakes), 1);
    });

    testWidgets('without the password it still says that the stage is in use', (
      tester,
    ) async {
      final fakes = await open(tester);
      await removeStageTwo(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text(_sheetTitle), findsNothing);
      expect(find.text("Stage 2 can't be removed yet"), findsOneWidget);
      expect(find.text('House emergency'), findsNothing);
      expect(_reauths(fakes), 0);
      expect(find.byType(FailureNotice), findsNothing);
    });
  });

  group('the session', () {
    testWidgets('a 403 reauth_required on a read never signs the person out', (
      tester,
    ) async {
      final fakes = _locked()..instructions.readsNeedPassword = false;
      final summaries = await fakes.instructions.list();
      final one = await fakes.instructions.get('instruction-1');
      fakes.instructions.readsNeedPassword = true;
      fakes.instructions.calls.clear();
      fakes.auth.reauthenticated = false;

      FakeReply read(RecordedRequest request) => fakes.auth.reauthenticated
          ? FakeReply.json(200, {
              'items': [for (final s in summaries) s.toJson()],
            })
          : FakeReply.problem(403, 'reauth_required');
      FakeReply readOne(RecordedRequest request) => fakes.auth.reauthenticated
          ? FakeReply.json(200, one.toJson())
          : FakeReply.problem(403, 'reauth_required');

      final world = await openHttpApp(
        tester,
        fakes: fakes,
        routes: {
          'GET /v1/instructions': read,
          'GET /v1/instructions/instruction-1': readOne,
        },
        route: AppRoutes.instructions,
      );

      // Refused, and still signed in: no logout, the session is kept, and the refusal
      // is not mistaken for an expired token (the one refresh is the stored token's own,
      // made before the first request).
      expect(world.to('GET', '/v1/instructions'), hasLength(1));
      expect(world.container.read(authControllerProvider), AuthStatus.signedIn);
      final refreshes = world.to('POST', '/v1/auth/refresh').length;
      expect(refreshes, lessThanOrEqualTo(1));
      expect(world.to('POST', '/v1/auth/logout'), isEmpty);
      expect(await SessionStore(world.store).hasPersistedSession(), isTrue);
      expect(find.text('Your instructions are hidden'), findsOneWidget);

      // The password, then the same read once.
      await tapText(tester, 'Show my instructions');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(world.to('GET', '/v1/instructions'), hasLength(2));
      await _confirm(tester, fakes.auth.password);
      await tester.pumpAndSettle();

      expect(world.to('GET', '/v1/instructions'), hasLength(3));
      expect(find.text('House emergency'), findsOneWidget);
      expect(world.container.read(authControllerProvider), AuthStatus.signedIn);
      expect(world.to('POST', '/v1/auth/refresh'), hasLength(refreshes));

      // An instruction's page, the window run out: the same, over the same network.
      fakes.auth.reauthenticated = false;
      world.container.read(routerProvider).go('/instructions/instruction-1');
      await _frames(tester);
      expect(find.text(_sheetTitle), findsOneWidget);
      expect(world.container.read(authControllerProvider), AuthStatus.signedIn);
      await tester.tap(find.text('Cancel'));
      await _frames(tester);
      expect(world.container.read(authControllerProvider), AuthStatus.signedIn);
      expect(world.to('GET', '/v1/instructions/instruction-1'), hasLength(1));
      expect(world.to('POST', '/v1/auth/refresh'), hasLength(refreshes));
      expect(world.to('POST', '/v1/auth/logout'), isEmpty);
    });
  });
}
