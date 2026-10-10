import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fake_instructions_server.dart';
import '../../helpers/fake_plan_server.dart';
import '../../helpers/fakes.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

typedef _Route = FakeReply Function(RecordedRequest request);

Map<String, Object?> _schedule() => {
  'interval_days': 1,
  'due_local_time': '20:00',
  'reminder_lead_minutes': 60,
  'timezone': 'Asia/Kolkata',
  'status': 'inactive',
  'next_due_at': null,
  'last_checkin_at': null,
  'version': 1,
};

Map<String, Object?> _home() => {
  'server_time': '2026-10-08T12:00:00Z',
  'user': {
    'display_name': 'Diwakar',
    'tier': 'free',
    'timezone': 'Asia/Kolkata',
  },
  'checkin': {
    'status': 'inactive',
    'next_due_at': null,
    'last_checkin_at': null,
    'schedule': {
      'interval_days': 1,
      'due_local_time': '20:00',
      'reminder_lead_minutes': 60,
    },
  },
  'incident': null,
  'plan_summary': {
    'stages': 1,
    'contacts_total': 1,
    'contacts_verified': 0,
    'instructions_active': 0,
  },
  'readiness': {'ready': false, 'issues': <Object>[]},
  'recent_activity': <Object>[],
};

/// The app on the REAL contacts, schedule, check-in, Home, plan and instructions
/// repositories over a fake network, at onboarding step 7. The instructions, the plan and
/// the contact are served by the same "servers" the widget tests use, so what is on the
/// wire is what those rules answer. [routes] answers by "METHOD /path" before them.
class _Step {
  _Step({this.lateStage = true, this.instructionsListFails = false})
    : contact = testContact(id: 'c-1') {
    plan = FakePlanServer(contacts: () => [contact], tier: () => tier)
      ..seedStandard(['c-1'], offsetMinutes: lateStage ? 1440 : 180);
    server = FakeInstructionsServer(
      contacts: () => [contact],
      plan: () => plan,
      tier: () => tier,
    );
  }

  final bool lateStage;
  final bool instructionsListFails;
  final String tier = 'free';
  final TrustedContact contact;
  late final FakePlanServer plan;
  late final FakeInstructionsServer server;
  final Map<String, _Route> routes = {};
  late final FakeHttpAdapter adapter;
  late final ProviderContainer container;

  Future<void> open(WidgetTester tester) async {
    final store = InMemorySecureStore();
    await SessionStore(store).saveSession(tokenResponse());
    adapter = FakeHttpAdapter((request, index) async {
      final custom = routes['${request.method} ${request.path}'];
      if (custom != null) {
        return custom(request);
      }
      switch ('${request.method} ${request.path}') {
        case 'POST /v1/auth/refresh':
          return FakeReply.json(200, refreshResponse().toJson());
        case 'GET /v1/contacts':
          return FakeReply.json(200, {
            'items': [contact.toJson()],
          });
        case 'GET /v1/me/entitlements':
          return FakeReply.json(200, {
            'tier': tier,
            'limits': {
              'contacts': 1,
              'instructions': tier == 'free' ? 3 : 200,
              'stages': 2,
              'custom_offsets': false,
            },
            'usage': {
              'contacts': 1,
              'instructions': server.liveCount,
              'stages': 1,
            },
          });
        case 'GET /v1/checkin/schedule':
          return FakeReply.json(200, _schedule(), const {'ETag': '"sched-1"'});
        case 'GET /v1/plan':
          final current = await plan.get();
          return FakeReply.json(200, current.toJson(), {
            'ETag': current.ifMatch,
          });
        case 'GET /v1/home':
          return FakeReply.json(200, _home());
        case 'PUT /v1/plan':
          return await _savePlan(request);
      }
      if (instructionsListFails && request.path == '/v1/instructions') {
        return FakeReply.problem(500, 'internal_error');
      }
      return await server.handle(request) ??
          FakeReply.problem(404, 'not_found');
    });
    final fakes = TestFakes()
      ..realContactsRepository = true
      ..realCheckInRepositories = true
      ..realPlanRepository = true
      ..realInstructionsRepository = true;
    fakes.prefs = freshPreferences({
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': false,
      'afterme.onboardingStep': 'instruction',
    });
    container = await pumpAfterMe(
      tester,
      fakes: fakes,
      status: AuthStatus.signedIn,
      secureStore: store,
      extraOverrides: [apiHttpAdapterProvider.overrideWithValue(adapter)],
    );
  }

  /// `PUT /v1/plan` as the plan "server" answers it (If-Match, the tier's limits).
  Future<FakeReply> _savePlan(RecordedRequest request) async {
    final body = request.data! as Map<String, dynamic>;
    final draft = PlanDraft(
      graceMinutes: body['grace_minutes'] as int,
      stages: [
        for (final raw in body['stages'] as List)
          PlanStageDraft(
            id: (raw as Map)['id'] as String?,
            offsetMinutes: raw['offset_minutes'] as int,
            contactIds: (raw['notify_contact_ids'] as List).cast<String>(),
          ),
      ],
    );
    try {
      final saved = await plan.save(
        draft,
        ifMatch: request.header('If-Match') ?? '',
      );
      return FakeReply.json(200, saved.toJson(), {'ETag': saved.ifMatch});
    } on PlanLimitFailure catch (failure) {
      return FakeReply.problem(
        403,
        'plan_limit_reached',
        extra: {
          'resource': failure.resource,
          'limit': failure.limit,
          'current': failure.current,
        },
      );
    } on ConflictFailure catch (failure) {
      final stale = failure.code == 'precondition_failed';
      return FakeReply.problem(
        stale ? 412 : (failure.code == 'precondition_required' ? 428 : 409),
        failure.code ?? 'conflict',
      );
    } on ValidationFailure catch (failure) {
      return FakeReply.problem(
        422,
        'validation_failed',
        extra: {
          'errors': [
            for (final e in failure.fieldErrors)
              {'field': e.field, 'code': e.code, 'message': 'x'},
          ],
        },
      );
    } on NotFoundFailure {
      return FakeReply.problem(404, 'not_found');
    }
  }

  List<RecordedRequest> to(String method, String path) => adapter.requests
      .where((r) => r.method == method && r.path == path)
      .toList();
}

/// Chooses the time "1 day" in the form: the plan's own stage, or, with a plan that has
/// none that far out, a time that is added to it.
Future<void> _chooseDay(WidgetTester tester) async {
  final finder = find.widgetWithText(
    RadioListTile<String>,
    "If you haven't checked in for 1 day",
  );
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pumpAndSettle();
}

void main() {
  group('step 7: the instruction is saved through the API', () {
    testWidgets('an example becomes a POST with the documented body, and the '
        'step moves on', (tester) async {
      final step = _Step();
      await step.open(tester);
      await tapText(tester, 'Home and keys');
      await tester.pumpAndSettle();
      await typeInto(tester, 'Title', 'House keys');
      await _chooseDay(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      final post = step.to('POST', '/v1/instructions').single;
      expect(post.bearer, isNotNull);
      expect(post.header('Idempotency-Key'), isNull);
      expect(post.data, {
        'category': 'home',
        'title': 'House keys',
        'body': 'A spare key is…\nThe alarm code is kept…\nBills and mail go to…\nPlease check on…',
        'status': 'active',
        'recipients': [
          {'contact_id': 'c-1', 'release_stage_id': step.plan.stages.single.id},
        ],
      });
      expect(find.text('Stay protected'), findsOneWidget);
      final setup = step.container.read(setupControllerProvider).value!;
      expect(setup.instructions.single.title, 'House keys');
      expect(
        await step.container
            .read(preferencesStoreProvider)
            .getString(PreferenceKey.onboardingStep),
        'protect',
      );
    });

    testWidgets('no title or text is in a URL, in a header or in a log', (
      tester,
    ) async {
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
      try {
        final step = _Step();
        await step.open(tester);
        await tapText(tester, 'Write your own');
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'Pets'));
        await tester.pump();
        await typeInto(tester, 'Title', 'A-very-secret-title');
        await tester.enterText(
          find.widgetWithText(TextField, 'What should they know?'),
          'A-very-secret-body',
        );
        await tester.pumpAndSettle();
        await _chooseDay(tester);
        await tapText(tester, 'Save instruction');
        await tester.pumpAndSettle();

        expect(step.server.created, hasLength(1));
        for (final request in step.adapter.requests) {
          expect(request.uri.toString(), isNot(contains('secret')));
          expect(request.headers.toString(), isNot(contains('secret')));
        }
      } finally {
        debugPrint = original;
      }
      expect(printed.join(' '), isNot(contains('secret')));
    });

    testWidgets('a time the plan has no stage for is added with one PUT, then '
        'the instruction is created with the new stage', (tester) async {
      final step = _Step(lateStage: false);
      await step.open(tester);
      final before = step.plan.stages.single;
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Choosing a time adds it to your plan'),
        findsOneWidget,
      );
      await _chooseDay(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();

      final put = step.to('PUT', '/v1/plan').single;
      expect(put.header('If-Match'), '"plan-2"');
      expect(put.data, {
        'grace_minutes': 180,
        'stages': [
          {
            'id': before.id,
            'offset_minutes': 180,
            'notify_contact_ids': ['c-1'],
          },
          {
            'id': null,
            'offset_minutes': 1440,
            'notify_contact_ids': ['c-1'],
          },
        ],
      });
      final created = step.plan.stages.last;
      expect(created.offsetMinutes, 1440);
      final post = step.to('POST', '/v1/instructions').single;
      expect((post.data! as Map<String, dynamic>)['recipients'], [
        {'contact_id': 'c-1', 'release_stage_id': created.id},
      ]);
      final order = [
        for (final r in step.adapter.requests)
          if (r.method != 'GET' && r.path != '/v1/auth/refresh')
            '${r.method} ${r.path}',
      ];
      expect(order, ['PUT /v1/plan', 'POST /v1/instructions']);
      expect(find.text('Stay protected'), findsOneWidget);
    });

    testWidgets('a limit answer opens the same sheet as everywhere else', (
      tester,
    ) async {
      final step = _Step();
      step.routes['POST /v1/instructions'] = (r) => FakeReply.problem(
        403,
        'plan_limit_reached',
        extra: {'resource': 'instructions', 'limit': 3, 'current': 3},
      );
      await step.open(tester);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await _chooseDay(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(
        find.text('More instructions are part of Premium'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The free plan allows 3 instructions.'),
        findsOneWidget,
      );
      expect(find.text('Close'), findsOneWidget);
      await tapText(tester, 'Close');
      await tester.pumpAndSettle();
      expect(find.text('Stay protected'), findsNothing);
      expect(find.text('Save instruction'), findsOneWidget);
    });

    testWidgets('a field the server refuses is said on that field', (
      tester,
    ) async {
      final step = _Step();
      step.routes['POST /v1/instructions'] = (r) => FakeReply.problem(
        422,
        'validation_failed',
        extra: {
          'errors': [
            {
              'field': 'title',
              'code': 'too_long',
              'message': 'Use at most 120 characters.',
            },
          ],
        },
      );
      await step.open(tester);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await _chooseDay(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(
        find.text('That title is too long. Use 120 characters or fewer.'),
        findsOneWidget,
      );
      expect(find.text('Use at most 120 characters.'), findsNothing);
      expect(find.text('Stay protected'), findsNothing);
    });

    testWidgets('a network failure is shown and the write is not repeated '
        'behind their back', (tester) async {
      final step = _Step();
      var posts = 0;
      step.routes['POST /v1/instructions'] = (r) {
        posts++;
        return const FakeReply.networkError();
      };
      await step.open(tester);
      await tapText(tester, 'Pets');
      await tester.pumpAndSettle();
      await _chooseDay(tester);
      await tapText(tester, 'Save instruction');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(posts, 1);
      // The form is still there, with what was chosen.
      expect(find.widgetWithText(TextField, 'Pets'), findsOneWidget);
    });

    testWidgets('a list that cannot be read does not hide the step', (
      tester,
    ) async {
      final step = _Step(instructionsListFails: true);
      await step.open(tester);
      expect(find.text('Add a first instruction'), findsOneWidget);
      expect(find.text('Who to call first'), findsOneWidget);
      expect(
        step.container.read(setupControllerProvider).value!.hasContact,
        isTrue,
      );
    });

    testWidgets('one that already exists is shown as saved', (tester) async {
      final step = _Step();
      step.server.seed(title: 'Already written');
      await step.open(tester);
      expect(find.textContaining('Saved: Already written'), findsOneWidget);
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('Stay protected'), findsOneWidget);
    });

    testWidgets('the list is read once, and never with a body', (tester) async {
      final step = _Step();
      step.server.seed(title: 'Written', body: 'a-body-nobody-should-keep');
      await step.open(tester);
      expect(step.to('GET', '/v1/instructions'), hasLength(1));
      final items = step.container.read(instructionsControllerProvider).value!;
      expect(items.single.toJson().containsKey('body'), isFalse);
    });
  });
}
