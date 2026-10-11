import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_http_adapter.dart';
import 'fakes.dart';
import 'pump_app.dart';
import 'test_app.dart';

/// A route handler of [openHttpApp]: answers one request.
typedef HttpRoute = FakeReply Function(RecordedRequest request);

/// The app on the REAL repositories (contacts, schedule, check-ins, Home, plan,
/// instructions, incidents, activity, export and deletion) over a fake network, signed
/// in with a real session store that holds a refresh token.
class HttpWorld {
  HttpWorld({
    required this.container,
    required this.adapter,
    required this.fakes,
    required this.store,
  });

  final ProviderContainer container;
  final FakeHttpAdapter adapter;
  final TestFakes fakes;
  final InMemorySecureStore store;

  List<RecordedRequest> to(String method, String path) => adapter.requests
      .where((r) => r.method == method && r.path == path)
      .toList();
}

Map<String, Object?> homeJson({
  String status = 'active',
  List<Map<String, Object?>> activity = const [],
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
    'last_checkin_at': '2026-10-08T09:00:00Z',
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
    'contacts_verified': 1,
    'instructions_active': 0,
  },
  'readiness': {'ready': true, 'issues': <Object>[]},
  'recent_activity': activity,
};

const Map<String, Object?> entitlementsJson = {
  'tier': 'free',
  'limits': {
    'contacts': 1,
    'instructions': 3,
    'stages': 2,
    'custom_offsets': false,
  },
  'usage': {'contacts': 1, 'instructions': 0, 'stages': 1},
};

Map<String, Object?> checkinResultJson() => {
  'checkin': {
    'id': 'ck-1',
    'kind': 'ok',
    'source': 'app',
    'received_at': '2026-10-08T12:00:00Z',
  },
  'next_due_at': '2026-10-09T14:30:00Z',
  'incident_resolved': false,
  'server_time': '2026-10-08T12:00:00Z',
};

/// Opens the app signed in at [route]. [routes] answers by `"METHOD /path"`; anything
/// else gets a sensible default (Home, entitlements, the token refresh) or a 404.
///
/// With [everythingIs] every request, whatever it is, gets that answer (for the 426
/// gate: "the server refuses this version").
Future<HttpWorld> openHttpApp(
  WidgetTester tester, {
  Map<String, HttpRoute> routes = const {},
  FakeReply Function(RecordedRequest request)? fallback,
  String route = AppRoutes.home,
  TestFakes? fakes,
  InMemorySecureStore? store,
  Map<String, Object> prefs = const {
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': true,
  },
  AuthStatus status = AuthStatus.signedIn,
  bool settle = true,
}) async {
  final secure = store ?? InMemorySecureStore();
  if (status == AuthStatus.signedIn) {
    await SessionStore(secure).saveSession(tokenResponse());
  }
  final adapter = FakeHttpAdapter((request, index) {
    final key = '${request.method} ${request.path}';
    final custom = routes[key];
    if (custom != null) {
      return custom(request);
    }
    if (fallback != null) {
      return fallback(request);
    }
    return switch (key) {
      'POST /v1/auth/refresh' => FakeReply.json(
        200,
        refreshResponse().toJson(),
      ),
      'GET /v1/home' => FakeReply.json(200, homeJson()),
      'GET /v1/me/entitlements' => const FakeReply.json(200, entitlementsJson),
      'GET /v1/activity' => const FakeReply.json(200, {
        'items': <Object>[],
        'next_cursor': null,
      }),
      _ => FakeReply.problem(404, 'not_found'),
    };
  });
  final world = fakes ?? TestFakes();
  world
    ..realContactsRepository = true
    ..realCheckInRepositories = true
    ..realPlanRepository = true
    ..realInstructionsRepository = true
    ..realIncidentsRepository = true
    ..realActivityRepository = true
    ..realPrivacyRepository = true;
  world.prefs = freshPreferences(prefs);
  final container = await pumpAfterMe(
    tester,
    fakes: world,
    status: status,
    secureStore: secure,
    settle: settle,
    extraOverrides: [apiHttpAdapterProvider.overrideWithValue(adapter)],
  );
  if (route != AppRoutes.home && route != AppRoutes.splash) {
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();
  }
  return HttpWorld(
    container: container,
    adapter: adapter,
    fakes: world,
    store: secure,
  );
}
