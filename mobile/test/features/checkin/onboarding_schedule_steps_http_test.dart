import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

Map<String, Object?> _schedule({
  int interval = 1,
  String due = '20:00',
  int lead = 60,
  String status = 'inactive',
  int version = 1,
}) => {
  'interval_days': interval,
  'due_local_time': due,
  'reminder_lead_minutes': lead,
  'timezone': 'Asia/Kolkata',
  'status': status,
  'next_due_at': status == 'active' ? '2026-10-09T14:30:00Z' : null,
  'last_checkin_at': null,
  'version': version,
};

Map<String, Object?> _home({
  String status = 'inactive',
  List<Map<String, Object?>> issues = const [],
}) => {
  'server_time': '2026-10-08T12:00:00Z',
  'user': {
    'display_name': 'Diwakar',
    'tier': 'free',
    'timezone': 'Asia/Kolkata',
  },
  'checkin': {
    'status': status,
    'next_due_at': status == 'active' ? '2026-10-09T14:30:00Z' : null,
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
  'readiness': {'ready': issues.isEmpty, 'issues': issues},
  'recent_activity': <Object>[],
};

typedef _Route = FakeReply Function(RecordedRequest request);

/// The app on the REAL contacts, schedule, check-in and Home repositories over a fake
/// network, at onboarding [step]. [routes] answers by "METHOD /path"; everything else
/// gets a sensible default.
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
      'GET /v1/home' => FakeReply.json(200, _home()),
      _ => FakeReply.problem(404, 'not_found'),
    };
  });
  final fakes = TestFakes()
    ..realContactsRepository = true
    ..realCheckInRepositories = true;
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

void main() {
  group('step 5: the schedule is saved through the API', () {
    testWidgets('sends If-Match and the three chosen values, then moves on', (
      tester,
    ) async {
      final (container, adapter) = await _openStep(tester, 'schedule', {
        'PUT /v1/checkin/schedule': (r) => FakeReply.json(
          200,
          _schedule(interval: 7, lead: 60, version: 2),
          const {'ETag': '"sched-2"'},
        ),
      });
      expect(find.text('Check in every day by 8:00 PM.'), findsOneWidget);
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();

      final put = _to(adapter, 'PUT', '/v1/checkin/schedule').single;
      expect(put.header('If-Match'), '"sched-1"');
      expect(put.data, {
        'interval_days': 7,
        'due_local_time': '20:00',
        'reminder_lead_minutes': 60,
      });
      expect(put.bearer, isNotNull);
      expect(find.text('Your plan'), findsOneWidget);
      final setup = container.read(setupControllerProvider).value!;
      expect(setup.schedule!.intervalDays, 7);
      expect(setup.snapshot!.version, 2);
      expect(
        await container
            .read(preferencesStoreProvider)
            .getString(PreferenceKey.onboardingStep),
        'plan',
      );
    });

    testWidgets('a schedule that was changed elsewhere (412) is reloaded and '
        'explained; saving again uses the new version', (tester) async {
      var gets = 0;
      var puts = 0;
      final (container, adapter) = await _openStep(tester, 'schedule', {
        'GET /v1/checkin/schedule': (r) {
          gets++;
          return gets == 1
              ? FakeReply.json(200, _schedule(), const {'ETag': '"sched-1"'})
              : FakeReply.json(200, _schedule(interval: 3, version: 2), const {
                  'ETag': '"sched-2"',
                });
        },
        'PUT /v1/checkin/schedule': (r) {
          puts++;
          return puts == 1
              ? FakeReply.problem(412, 'precondition_failed')
              : FakeReply.json(200, _schedule(interval: 7, version: 3), const {
                  'ETag': '"sched-3"',
                });
        },
      });
      await tapText(tester, 'Every week');
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          "This was changed somewhere else, so we've loaded the latest version.",
        ),
        findsOneWidget,
      );
      expect(find.text('When should you check in?'), findsOneWidget);
      expect(_to(adapter, 'GET', '/v1/checkin/schedule'), hasLength(2));
      expect(
        container.read(setupControllerProvider).value!.schedule!.intervalDays,
        3,
      );

      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      final sent = _to(adapter, 'PUT', '/v1/checkin/schedule');
      expect(sent.map((r) => r.header('If-Match')), ['"sched-1"', '"sched-2"']);
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('an open incident (409) is said calmly', (tester) async {
      await _openStep(tester, 'schedule', {
        'PUT /v1/checkin/schedule': (r) =>
            FakeReply.problem(409, 'incident_open'),
      });
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
      expect(find.text('When should you check in?'), findsOneWidget);
    });

    testWidgets('a validation answer (422) keeps the step', (tester) async {
      await _openStep(tester, 'schedule', {
        'PUT /v1/checkin/schedule': (r) => FakeReply.problem(
          422,
          'validation_failed',
          extra: {
            'errors': [
              {'field': 'interval_days', 'code': 'too_small', 'message': 'x'},
            ],
          },
        ),
      });
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(find.text('Some details need another look.'), findsOneWidget);
    });

    testWidgets('a network failure is shown and the write is not repeated '
        'behind their back', (tester) async {
      var puts = 0;
      final (_, adapter) = await _openStep(tester, 'schedule', {
        'PUT /v1/checkin/schedule': (r) {
          puts++;
          return puts == 1
              ? const FakeReply.networkError()
              : FakeReply.json(200, _schedule(version: 2), const {
                  'ETag': '"sched-2"',
                });
        },
      });
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(_to(adapter, 'PUT', '/v1/checkin/schedule'), hasLength(1));
      await tapText(tester, 'Save schedule');
      await tester.pumpAndSettle();
      expect(find.text('Your plan'), findsOneWidget);
    });

    testWidgets('the saved reminder is the one the server has', (tester) async {
      await _openStep(tester, 'schedule', {
        'GET /v1/checkin/schedule': (r) => FakeReply.json(
          200,
          _schedule(lead: 30, interval: 2, due: '09:15'),
          const {'ETag': '"sched-1"'},
        ),
      });
      expect(find.text('Check in every 2 days by 9:15 AM.'), findsOneWidget);
      expect(find.text("We'll remind you 30 minutes before."), findsOneWidget);
    });

    testWidgets('a reminder that is off is said so', (tester) async {
      await _openStep(tester, 'schedule', {
        'GET /v1/checkin/schedule': (r) => FakeReply.json(
          200,
          _schedule(lead: 0),
          const {'ETag': '"sched-1"'},
        ),
      });
      expect(find.text("We won't send a reminder."), findsOneWidget);
    });
  });

  group('step 9: check-ins are turned on by the server', () {
    testWidgets('activates and says the invitation went out', (tester) async {
      final (container, adapter) = await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) => FakeReply.json(
          200,
          _schedule(status: 'active', version: 2),
          const {'ETag': '"sched-2"'},
        ),
      });
      final post = _to(adapter, 'POST', '/v1/checkin/activate').single;
      expect(post.data, isNull);
      expect(post.bearer, isNotNull);
      expect(find.text("You're set"), findsOneWidget);
      expect(
        find.text(
          "Your plan is active. Mom has been invited, and we'll let you know when they accept.",
        ),
        findsOneWidget,
      );
      expect(
        container.read(setupControllerProvider).value!.scheduleActive,
        isTrue,
      );
    });

    testWidgets('says what is missing and leaves Home to show the checklist', (
      tester,
    ) async {
      final (container, _) = await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) => FakeReply.problem(
          409,
          'activation_requirements_unmet',
          extra: {
            'requirements': ['no_contacts'],
          },
        ),
        'GET /v1/home': (r) => FakeReply.json(
          200,
          _home(
            issues: [
              {'code': 'schedule_inactive', 'contact_id': null},
              {'code': 'no_contacts', 'contact_id': null},
            ],
          ),
        ),
      }, hasContact: false);
      expect(find.text('Almost there'), findsOneWidget);
      expect(
        find.text(
          "Check-ins aren't on yet. Still needed: a trusted contact. You can finish from Home.",
        ),
        findsOneWidget,
      );
      expect(
        container.read(setupControllerProvider).value!.scheduleActive,
        isFalse,
      );
      await tapText(tester, 'Go to Home');
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text("Let's finish your plan"), findsOneWidget);
      expect(find.text('Add a trusted contact'), findsOneWidget);
    });

    testWidgets(
      'requirements this version does not know are said generically',
      (tester) async {
        await _openStep(tester, 'done', {
          'POST /v1/checkin/activate': (r) => FakeReply.problem(
            409,
            'activation_requirements_unmet',
            extra: {
              'requirements': ['no_stages', 'future_requirement'],
            },
          ),
        });
        expect(
          find.text(
            "Check-ins aren't on yet. Still needed: a plan stage, something else in your plan. You can finish from Home.",
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('a network failure offers Try again', (tester) async {
      var posts = 0;
      final (_, adapter) = await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) {
          posts++;
          return posts == 1
              ? const FakeReply.networkError()
              : FakeReply.json(
                  200,
                  _schedule(status: 'active', version: 2),
                  const {'ETag': '"sched-2"'},
                );
        },
      });
      expect(find.textContaining("You're offline"), findsOneWidget);
      expect(find.text("You're set"), findsNothing);
      expect(_to(adapter, 'POST', '/v1/checkin/activate'), hasLength(1));
      await tapText(tester, 'Try again');
      await tester.pumpAndSettle();
      expect(find.text("You're set"), findsOneWidget);
    });

    testWidgets('an open incident while activating is said calmly', (
      tester,
    ) async {
      await _openStep(tester, 'done', {
        'POST /v1/checkin/activate': (r) =>
            FakeReply.problem(409, 'incident_open'),
      });
      expect(
        find.text(
          "This can't be changed while a check-in is overdue. Check in first to make changes.",
        ),
        findsOneWidget,
      );
    });
  });
}
