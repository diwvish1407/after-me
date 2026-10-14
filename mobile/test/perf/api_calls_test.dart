import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:afterme/app/router.dart';
import 'package:afterme/features/auth/application/me_controller.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_http_adapter.dart';
import '../helpers/http_world.dart';

/// The HTTP calls the app makes (PERF-05, battery and data): the request log of the real
/// repositories over a fake network that serves the backend's golden files
/// (`docs/contracts`), for a cold start of a signed-in phone and for each screen.
///
/// Each count is pinned: a call added to a cold start or a screen, or a duplicate, fails
/// here and has to be argued for.
///
/// Before this work a cold start made seven requests (`POST /auth/refresh`, `GET /me`,
/// `/checkin/schedule`, `/contacts`, `/plan`, `/home`, and `/contacts` once more), because
/// Home listened to the controllers behind them. Now it is the refresh and Home.

Map<String, Object?> _golden(String file) =>
    jsonDecode(File('../docs/contracts/$file').readAsStringSync())
        as Map<String, Object?>;

/// Home as the backend answers it, with the plan summary matching the contacts golden
/// (3 contacts, 1 verified) so that nothing disagrees and nothing is read again.
Map<String, Object?> _home() {
  final home = _golden('phase4/home_active.response.json');
  home['plan_summary'] = {
    ...(home['plan_summary']! as Map<String, Object?>),
    'contacts_total': 3,
    'contacts_verified': 1,
  };
  return home;
}

FakeReply _serve(RecordedRequest r) {
  final key = '${r.method} ${r.path}';
  switch (key) {
    case 'POST /v1/auth/refresh':
      return FakeReply.json(200, _golden('phase2/refresh.response.json'));
    case 'GET /v1/home':
      return FakeReply.json(200, _home());
    case 'GET /v1/me':
      return FakeReply.json(200, _golden('phase2/me.response.json'));
    case 'PATCH /v1/me/profile':
      return FakeReply.json(200, _golden('phase2/profile_patch.response.json'));
    case 'GET /v1/me/entitlements':
      return FakeReply.json(
        200,
        _golden('phase3/entitlements_free.response.json'),
      );
    case 'GET /v1/contacts':
      return FakeReply.json(200, _golden('phase3/contacts_list.response.json'));
    case 'GET /v1/checkin/schedule':
      return FakeReply.json(
        200,
        _golden('phase4/schedule_get_default.response.json'),
      );
    case 'GET /v1/plan':
      return FakeReply.json(
        200,
        _golden('phase5/plan_get_default.response.json'),
      );
    case 'GET /v1/instruction-categories':
      return FakeReply.json(
        200,
        _golden('phase6/categories_list.response.json'),
      );
    case 'GET /v1/instructions':
      return FakeReply.json(
        200,
        _golden('phase6/instructions_list.response.json'),
      );
    case 'GET /v1/activity':
      return FakeReply.json(
        200,
        _golden('phase7/activity_first_page.response.json'),
      );
  }
  return FakeReply.problem(404, 'not_found');
}

Future<HttpWorld> _open(WidgetTester tester, {String route = AppRoutes.home}) =>
    openHttpApp(tester, fallback: _serve, realAuth: true, route: route);

/// "METHOD /path" of every request, in order.
List<String> _log(HttpWorld world) => [
  for (final r in world.adapter.requests) '${r.method} ${r.path}',
];

/// The requests made from [mark] on, sorted (the order of parallel reads is not a
/// contract; the set and the counts are).
List<String> _since(HttpWorld world, int mark) =>
    _log(world).skip(mark).toList()..sort();

Matcher _exactly(List<String> calls) => equals([...calls]..sort());

void main() {
  group('cold start, signed in', () {
    testWidgets('is the token refresh and Home, and nothing else', (
      tester,
    ) async {
      final world = await _open(tester);
      expect(_log(world), ['POST /v1/auth/refresh', 'GET /v1/home']);
      // Not read at start: the account, the schedule, the contacts, the plan.
      for (final path in [
        '/v1/me',
        '/v1/checkin/schedule',
        '/v1/contacts',
        '/v1/plan',
        '/v1/me/entitlements',
        '/v1/instructions',
        '/v1/activity',
      ]) {
        expect(world.adapter.requestsTo(path), isEmpty, reason: path);
      }
    });

    testWidgets('no request repeats', (tester) async {
      final world = await _open(tester);
      final log = _log(world);
      expect(log.toSet().length, log.length);
    });

    testWidgets('Home still shows the name and the readiness from its own '
        'answer', (tester) async {
      await _open(tester);
      expect(find.textContaining('Test User'), findsWidgets);
    });
  });

  group('Home', () {
    testWidgets('pull to refresh is one read of Home', (tester) async {
      final world = await _open(tester);
      final mark = world.adapter.requests.length;
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(_since(world, mark), _exactly(['GET /v1/home']));
    });

    testWidgets('coming back to the app is one read of Home', (tester) async {
      final world = await _open(tester);
      final mark = world.adapter.requests.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(_since(world, mark), _exactly(['GET /v1/home']));
    });

    testWidgets('a profile change (name, timezone) reads Home again once, '
        'though Home no longer listens to the account', (tester) async {
      final world = await _open(tester);
      // The account is read when a screen needs it.
      world.container.read(meControllerProvider);
      await tester.pumpAndSettle();
      final mark = world.adapter.requests.length;
      unawaited(
        world.container
            .read(meControllerProvider.notifier)
            .patchProfile(
              const ProfilePatch(
                displayName: 'Asha R.',
                timezone: 'Europe/London',
              ),
            ),
      );
      await tester.pumpAndSettle();
      expect(
        _since(world, mark),
        _exactly(['PATCH /v1/me/profile', 'GET /v1/home']),
      );
    });

    testWidgets('a profile change that changes neither reads nothing more', (
      tester,
    ) async {
      final world = await _open(tester);
      world.container.read(meControllerProvider);
      await tester.pumpAndSettle();
      final me = world.container.read(meControllerProvider).value!;
      final mark = world.adapter.requests.length;
      world.container.read(meControllerProvider.notifier).apply(me);
      await tester.pumpAndSettle();
      expect(_since(world, mark), isEmpty);
    });
  });

  group('each screen, opened from a cold start', () {
    // (screen, route, the requests it adds to the refresh and Home of the start.)
    testWidgets('People: the contacts, the limits, and what the plan summary '
        'needs (schedule, plan), each once', (tester) async {
      final world = await _open(tester, route: AppRoutes.people);
      expect(
        _log(world).skip(2).toList()..sort(),
        _exactly([
          'GET /v1/contacts',
          'GET /v1/me/entitlements',
          'GET /v1/checkin/schedule',
          'GET /v1/plan',
        ]),
      );
      expect(world.adapter.requestsTo('/v1/home'), hasLength(1));
    });

    testWidgets('Plan: the plan and the contacts it names, each once', (
      tester,
    ) async {
      final world = await _open(tester, route: AppRoutes.plan);
      final calls = _log(world).skip(2).toList()..sort();
      expect(calls, hasLength(calls.toSet().length), reason: 'no duplicates');
      expect(calls, containsAll(<String>['GET /v1/plan', 'GET /v1/contacts']));
      expect(calls, isNot(contains('GET /v1/me')));
      expect(world.adapter.requestsTo('/v1/home'), hasLength(1));
    });

    testWidgets('Instructions: the list and the categories, and the plan and '
        'contacts the recipients need, each once', (tester) async {
      final world = await _open(tester, route: AppRoutes.instructions);
      expect(
        _log(world).skip(2).toList()..sort(),
        _exactly([
          'GET /v1/instructions',
          'GET /v1/instruction-categories',
          'GET /v1/me/entitlements',
          'GET /v1/contacts',
          'GET /v1/plan',
        ]),
      );
    });

    testWidgets('Activity: the feed once, and the account the Settings page '
        'underneath shows once', (tester) async {
      final world = await _open(tester, route: AppRoutes.settingsActivity);
      expect(
        _log(world).skip(2).toList()..sort(),
        _exactly(['GET /v1/activity', 'GET /v1/me']),
      );
    });

    testWidgets('Check-in schedule settings: the schedule once, and not the '
        'account', (tester) async {
      final world = await _open(tester, route: AppRoutes.settingsSchedule);
      final calls = _log(world).skip(2).toList()..sort();
      expect(calls.where((c) => c == 'GET /v1/checkin/schedule'), hasLength(1));
      expect(calls.where((c) => c == 'GET /v1/home'), isEmpty);
    });
  });
}
