import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

const _mom = <String, Object?>{
  'id': 'c-1',
  'display_name': 'Mom',
  'relationship': 'mother',
  'relationship_label': null,
  'email': 'mom@example.com',
  'phone_e164': null,
  'priority': 1,
  'verification_status': 'pending',
  'verified_at': null,
  'is_active': true,
  'invitation_sent_at': '2026-10-08T10:30:00Z',
  'invitation_send_count': 1,
  'notified_at_stages': <int>[],
  'receives_instructions': 0,
  'created_at': '2026-10-08T10:30:00Z',
  'updated_at': '2026-10-08T10:30:00Z',
};

Map<String, Object?> _rules({bool custom = false}) => {
  'grace_min': 60,
  'grace_max': 4320,
  'stage_gap_min': 30,
  'offset_max': 43200,
  'release_offset_min': 1440,
  'max_stages': custom ? 10 : 2,
  'custom_offsets': custom,
  'presets': [180, 360, 720, 1440, 2880, 4320],
};

Map<String, Object?> _stage(
  String id,
  int position,
  int offset,
  List<String> contacts,
) => {
  'id': id,
  'position': position,
  'offset_minutes': offset,
  'notify_contact_ids': contacts,
  'release_count': 0,
};

Map<String, Object?> _plan({
  int version = 1,
  int grace = 180,
  List<Map<String, Object?>> stages = const [],
  bool custom = false,
}) => {
  'id': 'p-1',
  'version': version,
  'grace_minutes': grace,
  'stages': stages,
  'rules': _rules(custom: custom),
};

Map<String, Object?> _schedule({String status = 'inactive', int version = 1}) =>
    {
      'interval_days': 1,
      'due_local_time': '20:00',
      'reminder_lead_minutes': 60,
      'timezone': 'Asia/Kolkata',
      'status': status,
      'next_due_at': status == 'active' ? '2026-10-09T14:30:00Z' : null,
      'last_checkin_at': null,
      'version': version,
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
    'stages': 0,
    'contacts_total': 1,
    'contacts_verified': 0,
    'instructions_active': 0,
  },
  'readiness': {'ready': false, 'issues': <Object>[]},
  'recent_activity': <Object>[],
};

typedef _Route = FakeReply Function(RecordedRequest request);

/// The app on the REAL contacts, schedule, check-in, Home and plan repositories over a
/// fake network, at onboarding [step]. [routes] answers by "METHOD /path"; everything
/// else gets a sensible default (a new account: no plan, check-ins off).
Future<(ProviderContainer, FakeHttpAdapter)> _openStep(
  WidgetTester tester,
  String step,
  Map<String, _Route> routes, {
  bool hasContact = true,
}) async {
  final store = InMemorySecureStore();
  await SessionStore(store).saveSession(tokenResponse());
  final adapter = FakeHttpAdapter((request, index) {
    final custom = routes['${request.method} ${request.path}'];
    if (custom != null) {
      return custom(request);
    }
    return switch ('${request.method} ${request.path}') {
      'POST /v1/auth/refresh' => FakeReply.json(
        200,
        refreshResponse().toJson(),
      ),
      'GET /v1/contacts' => FakeReply.json(200, {
        'items': hasContact ? [_mom] : <Object>[],
      }),
      'GET /v1/me/entitlements' => const FakeReply.json(200, {
        'tier': 'free',
        'limits': {
          'contacts': 1,
          'instructions': 3,
          'stages': 2,
          'custom_offsets': false,
        },
        'usage': {'contacts': 1, 'instructions': 0, 'stages': 0},
      }),
      'GET /v1/checkin/schedule' => FakeReply.json(200, _schedule(), const {
        'ETag': '"sched-1"',
      }),
      'GET /v1/plan' => FakeReply.json(200, _plan(), const {
        'ETag': '"plan-1"',
      }),
      'GET /v1/home' => FakeReply.json(200, _home()),
      _ => FakeReply.problem(404, 'not_found'),
    };
  });
  final fakes = TestFakes()
    ..realContactsRepository = true
    ..realCheckInRepositories = true
    ..realPlanRepository = true;
  fakes.prefs = freshPreferences({
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': false,
    'afterme.onboardingStep': step,
  });
  final container = await pumpAfterMe(
    tester,
    fakes: fakes,
    status: AuthStatus.signedIn,
    secureStore: store,
    extraOverrides: [apiHttpAdapterProvider.overrideWithValue(adapter)],
  );
  return (container, adapter);
}

List<RecordedRequest> _to(
  FakeHttpAdapter adapter,
  String method,
  String path,
) => adapter.requests
    .where((r) => r.method == method && r.path == path)
    .toList();

/// The answer of a `PUT /v1/plan` that saved [stages] as version [version].
_Route _saved({
  int version = 2,
  int grace = 180,
  List<Map<String, Object?>>? stages,
}) =>
    (r) => FakeReply.json(
      200,
      _plan(
        version: version,
        grace: grace,
        stages:
            stages ??
            [
              _stage('s-1', 1, grace, ['c-1']),
            ],
      ),
      {'ETag': '"plan-$version"'},
    );

void main() {
  group('step 6: the plan is saved through the API', () {
    testWidgets('sends If-Match and the preset body, then moves on', (
      tester,
    ) async {
      final (container, adapter) = await _openStep(tester, 'plan', {
        'PUT /v1/plan': _saved(),
      });
      expect(find.text('At 11:00 PM, Mom is notified.'), findsOneWidget);
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();

      final put = _to(adapter, 'PUT', '/v1/plan').single;
      expect(put.header('If-Match'), '"plan-1"');
      expect(put.bearer, isNotNull);
      expect(put.data, {
        'grace_minutes': 180,
        'stages': [
          {
            'id': null,
            'offset_minutes': 180,
            'notify_contact_ids': ['c-1'],
          },
        ],
      });
      expect(find.text('Add a first instruction'), findsOneWidget);
      final setup = container.read(setupControllerProvider).value!;
      expect(setup.plan!.version, 2);
      expect(setup.plan!.stages.single.id, 's-1');
      expect(setup.hasPlan, isTrue);
      expect(
        await container
            .read(preferencesStoreProvider)
            .getString(PreferenceKey.onboardingStep),
        'instruction',
      );
    });

    testWidgets('the chosen delay is the grace period and the first stage\'s '
        'offset', (tester) async {
      final (_, adapter) = await _openStep(tester, 'plan', {
        'PUT /v1/plan': _saved(grace: 360),
      });
      await tapText(tester, '6 hours');
      expect(
        find.text('At 2:00 AM the next day, Mom is notified.'),
        findsOneWidget,
      );
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      final body =
          _to(adapter, 'PUT', '/v1/plan').single.data! as Map<String, dynamic>;
      expect(body['grace_minutes'], 360);
      final stage = (body['stages'] as List).single as Map<String, dynamic>;
      expect(stage['offset_minutes'], 360);
    });

    testWidgets('a free account is offered only the delays its tier allows', (
      tester,
    ) async {
      await _openStep(tester, 'plan', {});
      for (final choice in ['3 hours', '6 hours', '12 hours', '1 day']) {
        expect(find.widgetWithText(ChoiceChip, choice), findsOneWidget);
      }
      expect(find.widgetWithText(ChoiceChip, '1 hour'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, '2 hours'), findsNothing);
    });

    testWidgets('an account with custom offsets is offered the shorter ones', (
      tester,
    ) async {
      await _openStep(tester, 'plan', {
        'GET /v1/plan': (r) => FakeReply.json(200, _plan(custom: true), const {
          'ETag': '"plan-1"',
        }),
      });
      expect(find.widgetWithText(ChoiceChip, '1 hour'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '2 hours'), findsOneWidget);
    });

    testWidgets('a plan saved elsewhere is shown as it is; choosing the '
        'preset replaces only stage 1', (tester) async {
      final (_, adapter) = await _openStep(tester, 'plan', {
        'GET /v1/plan': (r) => FakeReply.json(
          200,
          _plan(
            version: 5,
            grace: 360,
            stages: [
              _stage('s-1', 1, 360, ['c-1']),
              _stage('s-2', 2, 1440, ['c-1']),
            ],
          ),
          const {'ETag': '"plan-5"'},
        ),
        'PUT /v1/plan': _saved(version: 6, grace: 360),
      });
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '6 hours'))
            .selected,
        isTrue,
        reason: 'the saved delay is the selected one',
      );
      expect(
        find.text('At 8:00 PM the next day, Mom is notified.'),
        findsOneWidget,
        reason: 'stage 2 is part of what would happen',
      );
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      final put = _to(adapter, 'PUT', '/v1/plan').single;
      expect(put.header('If-Match'), '"plan-5"');
      expect(put.data, {
        'grace_minutes': 360,
        'stages': [
          {
            'id': 's-1',
            'offset_minutes': 360,
            'notify_contact_ids': ['c-1'],
          },
          {
            'id': 's-2',
            'offset_minutes': 1440,
            'notify_contact_ids': ['c-1'],
          },
        ],
      });
    });

    testWidgets('without a contact nothing is saved and the step says why', (
      tester,
    ) async {
      final (_, adapter) = await _openStep(
        tester,
        'plan',
        {},
        hasContact: false,
      );
      expect(
        find.textContaining("haven't added a trusted contact"),
        findsOneWidget,
      );
      expect(find.text('Use this plan'), findsNothing);
      await tapText(tester, 'Continue');
      await tester.pumpAndSettle();
      expect(find.text('Add a first instruction'), findsOneWidget);
      expect(_to(adapter, 'PUT', '/v1/plan'), isEmpty);
    });

    testWidgets('a plan changed elsewhere (412) is reloaded and explained; '
        'saving again uses the new version', (tester) async {
      var gets = 0;
      var puts = 0;
      final (container, adapter) = await _openStep(tester, 'plan', {
        'GET /v1/plan': (r) {
          gets++;
          return gets == 1
              ? FakeReply.json(200, _plan(), const {'ETag': '"plan-1"'})
              : FakeReply.json(
                  200,
                  _plan(
                    version: 2,
                    grace: 720,
                    stages: [
                      _stage('s-9', 1, 720, ['c-1']),
                    ],
                  ),
                  const {'ETag': '"plan-2"'},
                );
        },
        'PUT /v1/plan': (r) {
          puts++;
          return puts == 1
              ? FakeReply.problem(412, 'precondition_failed')
              : _saved(version: 3, grace: 180)(r);
        },
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Your plan was changed somewhere else'),
        findsOneWidget,
      );
      expect(find.text('Your plan'), findsOneWidget);
      expect(_to(adapter, 'GET', '/v1/plan'), hasLength(2));
      expect(container.read(setupControllerProvider).value!.plan!.version, 2);

      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(_to(adapter, 'PUT', '/v1/plan').map((r) => r.header('If-Match')), [
        '"plan-1"',
        '"plan-2"',
      ]);
      expect(find.text('Add a first instruction'), findsOneWidget);
    });

    testWidgets('403 reauth_required: the password sheet, then the very same '
        'PUT (same If-Match, same body) once', (tester) async {
      var puts = 0;
      final (container, adapter) = await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) {
          puts++;
          return puts == 1
              ? FakeReply.problem(403, 'reauth_required')
              : _saved()(r);
        },
      });
      await tapText(tester, 'Use this plan');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text("Confirm it's you"), findsOneWidget);
      expect(_to(adapter, 'PUT', '/v1/plan'), hasLength(1));

      await typeInto(tester, 'Password', authOf(container).password);
      await tapText(tester, 'Confirm');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();

      final sent = _to(adapter, 'PUT', '/v1/plan');
      expect(sent, hasLength(2));
      expect(sent.map((r) => r.header('If-Match')), ['"plan-1"', '"plan-1"']);
      expect(sent[0].data, sent[1].data);
      expect(find.text('Add a first instruction'), findsOneWidget);
    });

    testWidgets('a grace period the server refuses is said next to the '
        'choices', (tester) async {
      await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) => FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {
                'field': 'grace_minutes',
                'code': 'not_a_preset',
                'message': 'Choose one of the suggested grace periods.',
              },
            ],
          },
        ),
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "That wait isn't available for your plan. Choose one of the times shown.",
        ),
        findsOneWidget,
      );
      expect(
        find.text('Choose one of the suggested grace periods.'),
        findsNothing,
        reason: 'the server text is never what the person reads',
      );
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('a stage time the server refuses is said calmly', (
      tester,
    ) async {
      await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) => FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {
                'field': 'stages[1].offset_minutes',
                'code': 'too_close',
                'message': 'Stages must be at least 30 minutes apart.',
              },
            ],
          },
        ),
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "The times in your plan don't fit together. Choose a wait and try again.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('too many stages (403) is said calmly', (tester) async {
      await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) => FakeReply.problem(
          403,
          'plan_limit_reached',
          extra: {'resource': 'stages', 'limit': 2, 'current': 3},
        ),
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.text("You've reached the number of stages your account includes."),
        findsOneWidget,
      );
    });

    testWidgets('a contact that is gone (404) reloads the contacts and says '
        'so', (tester) async {
      final (_, adapter) = await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) => FakeReply.problem(404, 'not_found'),
      });
      expect(_to(adapter, 'GET', '/v1/contacts'), hasLength(1));
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("Someone in this plan can't be found any more"),
        findsOneWidget,
      );
      expect(_to(adapter, 'GET', '/v1/contacts'), hasLength(2));
      expect(_to(adapter, 'GET', '/v1/plan'), hasLength(2));
    });

    testWidgets('an open incident (409) is said calmly', (tester) async {
      await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) => FakeReply.problem(409, 'incident_open'),
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('a network failure is shown and the write is not repeated '
        'behind their back', (tester) async {
      var puts = 0;
      final (_, adapter) = await _openStep(tester, 'plan', {
        'PUT /v1/plan': (r) {
          puts++;
          return puts == 1 ? const FakeReply.networkError() : _saved()(r);
        },
      });
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(
        find.textContaining("We couldn't confirm that this was saved"),
        findsOneWidget,
      );
      expect(_to(adapter, 'PUT', '/v1/plan'), hasLength(1));
      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(find.text('Add a first instruction'), findsOneWidget);
    });

    testWidgets('does not show the preview notice: the plan is real', (
      tester,
    ) async {
      await _openStep(tester, 'plan', {});
      expect(find.textContaining('Preview:'), findsNothing);
    });
  });

  group('step 9: what the server says is missing, and where to fix it', () {
    FakeReply unmet(List<String> requirements) => FakeReply.problem(
      409,
      'activation_requirements_unmet',
      extra: {'requirements': requirements},
    );

    testWidgets('a plan that was saved is summarised and activation goes '
        'through', (tester) async {
      final (container, adapter) = await _openStep(tester, 'done', {
        'GET /v1/plan': (r) => FakeReply.json(
          200,
          _plan(
            version: 2,
            stages: [
              _stage('s-1', 1, 180, ['c-1']),
            ],
          ),
          const {'ETag': '"plan-2"'},
        ),
        'POST /v1/checkin/activate': (r) => FakeReply.json(
          200,
          _schedule(status: 'active', version: 2),
          const {'ETag': '"sched-2"'},
        ),
      });
      expect(_to(adapter, 'POST', '/v1/checkin/activate'), hasLength(1));
      expect(find.text("You're set"), findsOneWidget);
      expect(
        find.text('We wait 3 hours before telling your contact'),
        findsOneWidget,
      );
      expect(find.text('Review your plan'), findsNothing);
      expect(
        container.read(setupControllerProvider).value!.scheduleActive,
        isTrue,
      );
    });

    testWidgets('no_stages: says a plan stage is missing; the button opens '
        'the plan step and saving it finishes the job', (tester) async {
      var activations = 0;
      final (_, adapter) = await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) {
          activations++;
          return activations == 1
              ? unmet(['no_stages'])
              : FakeReply.json(
                  200,
                  _schedule(status: 'active', version: 2),
                  const {'ETag': '"sched-2"'},
                );
        },
        'PUT /v1/plan': _saved(),
      });
      expect(find.text('Almost there'), findsOneWidget);
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a plan stage. You can finish from Home.",
        ),
        findsOneWidget,
      );
      expect(find.text('No plan yet'), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsNothing);

      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
      expect(find.text('Step 6 of 9'), findsOneWidget);

      await tapText(tester, 'Use this plan');
      await tester.pumpAndSettle();
      expect(_to(adapter, 'PUT', '/v1/plan'), hasLength(1));
      // Back at the last step, which asks the server again.
      expect(find.text("You're set"), findsOneWidget);
      expect(_to(adapter, 'POST', '/v1/checkin/activate'), hasLength(2));
    });

    testWidgets('stage_empty: a stage that tells no one has its own words '
        'and the same way out', (tester) async {
      await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) => unmet(['stage_empty']),
      });
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a plan stage that tells someone. You can finish from Home.",
        ),
        findsOneWidget,
      );
      expect(find.text('Review your plan'), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsNothing);
      await tapText(tester, 'Review your plan');
      await tester.pumpAndSettle();
      expect(find.text('Step 6 of 9'), findsOneWidget);
    });

    testWidgets('no_contacts and no_stages: both are said, contact first, '
        'each with its own way out', (tester) async {
      await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) => unmet(['no_contacts', 'no_stages']),
      }, hasContact: false);
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a trusted contact, a plan stage. You can finish from Home.",
        ),
        findsOneWidget,
      );
      final contact = tester.getTopLeft(find.text('Add a trusted contact'));
      final plan = tester.getTopLeft(find.text('Review your plan'));
      expect(contact.dy, lessThan(plan.dy));

      await tapText(tester, 'Add a trusted contact');
      await tester.pumpAndSettle();
      expect(
        find.text("Who should we tell if you don't check in?"),
        findsOneWidget,
      );
      expect(find.text('Step 4 of 9'), findsOneWidget);
    });

    testWidgets('a requirement this version does not know offers no button, '
        'only Go to Home', (tester) async {
      await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) => unmet(['future_requirement']),
      });
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: something else in your plan. You can finish from Home.",
        ),
        findsOneWidget,
      );
      expect(find.text('Review your plan'), findsNothing);
      expect(find.text('Add a trusted contact'), findsNothing);
      expect(find.text('Go to Home'), findsOneWidget);
    });
  });
}
