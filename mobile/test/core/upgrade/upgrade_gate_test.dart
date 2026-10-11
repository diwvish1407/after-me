import 'dart:async';
import 'dart:math';

import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/failures/failure_mapper.dart';
import 'package:afterme/core/api/upgrade_gate.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/core/upgrade/upgrade_recheck.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/http_world.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

/// The global "Update AfterMe" gate (USER_FLOWS.md §14): any 426 from any request puts
/// the app on a blocking screen with the Play Store link; nothing is lost; the next
/// successful request lifts it; no other failure raises it.
FakeReply _upgrade() => FakeReply.problem(426, 'upgrade_required');

/// The real API client over a fake network, with counters for the two callbacks.
class _Client {
  _Client(FakeHandler handler, {String? refreshToken = 'refresh-1'})
    : adapter = FakeHttpAdapter(handler) {
    secure = InMemorySecureStore({
      SessionKeys.refreshToken: ?refreshToken,
      SessionKeys.sessionId: 'session-1',
      SessionKeys.deviceId: 'device-1',
    });
    session = SessionStore(secure);
    unawaited(session.saveSession(tokenResponse(access: 'access-1')));
    dio = createApiClient(
      config: devConfig,
      clientInfo: testClientInfo,
      sessionStore: session,
      onSessionEnded: () async => session.clear(),
      adapter: adapter,
      retryDelay: (_) async {},
      random: Random(1),
      onUpgradeRequired: () => raised++,
      onAccepted: () => accepted++,
    );
  }

  final FakeHttpAdapter adapter;
  late final InMemorySecureStore secure;
  late final SessionStore session;
  late final Dio dio;
  int raised = 0;
  int accepted = 0;

  Future<AppFailure?> get(String path) async {
    try {
      await dio.get<Object?>(path);
    } on DioException catch (error) {
      return mapDioException(error);
    }
    return null;
  }
}

void main() {
  upgradeRecheckTests();

  group('the interceptor', () {
    test('a 426 raises the gate once and the request still fails with '
        'UpgradeRequiredFailure', () async {
      final client = _Client((_, _) => _upgrade());
      final failure = await client.get('/v1/home');
      expect(failure, isA<UpgradeRequiredFailure>());
      expect(client.raised, 1);
      expect(client.accepted, 0);
      expect(client.adapter.requests, hasLength(1), reason: 'never repeated');
    });

    test('a success lifts it', () async {
      var reply = _upgrade();
      final client = _Client((_, _) => reply);
      await client.get('/v1/home');
      expect(client.raised, 1);
      reply = const FakeReply.json(200, {'ok': true});
      expect(await client.get('/v1/home'), isNull);
      expect(client.accepted, 1);
    });

    test('other failures never raise it: 401, 403, 404, 409, 422, 429, 500, '
        '503 and a lost connection', () async {
      for (final reply in <FakeReply>[
        FakeReply.problem(401, 'session_revoked'),
        FakeReply.problem(403, 'forbidden'),
        FakeReply.problem(404, 'not_found'),
        FakeReply.problem(409, 'invalid_state'),
        FakeReply.problem(422, 'validation_failed'),
        FakeReply.problem(429, 'rate_limited'),
        FakeReply.problem(500, 'internal_error'),
        FakeReply.problem(503, 'service_unavailable'),
        const FakeReply.networkError(),
        const FakeReply.raw(502, '<html>Bad gateway</html>', 'text/html'),
      ]) {
        final client = _Client((_, _) => reply);
        final failure = await client.get('/v1/home');
        expect(failure, isNotNull);
        expect(failure, isNot(isA<UpgradeRequiredFailure>()));
        expect(client.raised, 0, reason: '$failure');
        expect(client.accepted, 0, reason: 'a failure is no acceptance');
      }
    });

    test('a 426 on the token refresh reaches the gate through the original '
        'request', () async {
      final client = _Client((request, _) {
        if (request.path == '/v1/auth/refresh') {
          return _upgrade();
        }
        return FakeReply.problem(401, 'token_expired');
      });
      final failure = await client.get('/v1/home');
      expect(failure, isA<UpgradeRequiredFailure>());
      expect(client.raised, 1);
    });

    test(
      'a 426 after a successful refresh (the retried request) counts too',
      () async {
        var home = 0;
        final client = _Client((request, _) {
          if (request.path == '/v1/auth/refresh') {
            return FakeReply.json(200, refreshResponse().toJson());
          }
          return ++home == 1
              ? FakeReply.problem(401, 'token_expired')
              : _upgrade();
        });
        final failure = await client.get('/v1/home');
        expect(failure, isA<UpgradeRequiredFailure>());
        // Raised by the retried request and again as its failure comes back out: the
        // gate is a flag, so saying it twice is the same as once.
        expect(client.raised, greaterThanOrEqualTo(1));
      },
    );

    test(
      'a request that succeeds after a transient failure lifts it',
      () async {
        var calls = 0;
        final client = _Client(
          (_, _) => ++calls == 1
              ? FakeReply.problem(503, 'service_unavailable')
              : const FakeReply.json(200, {'ok': true}),
        );
        expect(await client.get('/v1/home'), isNull);
        expect(client.raised, 0);
        expect(client.accepted, greaterThanOrEqualTo(1));
      },
    );

    test('without callbacks nothing is added to the chain', () {
      Dio build({VoidCallback? onUpgradeRequired}) => createApiClient(
        config: devConfig,
        clientInfo: testClientInfo,
        sessionStore: SessionStore(InMemorySecureStore()),
        onSessionEnded: () async {},
        onUpgradeRequired: onUpgradeRequired,
      );
      expect(
        build(onUpgradeRequired: () {}).interceptors.length,
        build().interceptors.length + 1,
      );
    });
  });

  group('every repository', () {
    /// A container whose API client is answered with 426 for everything.
    Future<ProviderContainer> container() async {
      final fakes = TestFakes()
        ..realContactsRepository = true
        ..realCheckInRepositories = true
        ..realPlanRepository = true
        ..realInstructionsRepository = true
        ..realIncidentsRepository = true
        ..realActivityRepository = true
        ..realPrivacyRepository = true;
      final store = InMemorySecureStore();
      await SessionStore(store).saveSession(tokenResponse());
      final adapter = FakeHttpAdapter((_, _) => _upgrade());
      return ProviderContainer.test(
        retry: (count, error) => null,
        overrides: [
          ...testOverrides(
            authStatus: AuthStatus.signedIn,
            secureStore: store,
            fakes: fakes,
          ),
          apiHttpAdapterProvider.overrideWithValue(adapter),
        ],
      );
    }

    final calls = <String, Future<Object?> Function(ProviderContainer c)>{
      'contacts.list': (c) => c.read(contactsRepositoryProvider).list(),
      'contacts.entitlements': (c) =>
          c.read(contactsRepositoryProvider).entitlements(),
      'schedule.get': (c) => c.read(scheduleRepositoryProvider).get(),
      'checkIn.checkIn': (c) => c
          .read(checkInRepositoryProvider)
          .checkIn(idempotencyKey: 'k-1234567890123456'),
      'checkIn.history': (c) => c.read(checkInRepositoryProvider).history(),
      'home.load': (c) => c.read(homeRepositoryProvider).load(),
      'plan.get': (c) => c.read(planRepositoryProvider).get(),
      'instructions.list': (c) => c.read(instructionsRepositoryProvider).list(),
      'instructions.categories': (c) =>
          c.read(instructionsRepositoryProvider).categories(),
      'incidents.list': (c) => c.read(incidentsRepositoryProvider).list(),
      'incidents.markSafe': (c) => c
          .read(incidentsRepositoryProvider)
          .markSafe('i-1', idempotencyKey: 'k-1234567890123456'),
      'activity.list': (c) => c.read(activityRepositoryProvider).list(),
      'privacy.exportData': (c) =>
          c.read(privacyRepositoryProvider).exportData(),
      'privacy.deleteAccount': (c) =>
          c.read(privacyRepositoryProvider).deleteAccount(),
      'auth.me': (c) => DioAuthRepository(
        dio: c.read(apiClientProvider),
        clientInfo: testClientInfo,
        deviceInfo: FakeDeviceInfoSourceForGate(),
        sessionStore: c.read(sessionStoreProvider),
      ).me(),
      'auth.login': (c) => DioAuthRepository(
        dio: c.read(apiClientProvider),
        clientInfo: testClientInfo,
        deviceInfo: FakeDeviceInfoSourceForGate(),
        sessionStore: c.read(sessionStoreProvider),
      ).login(email: 'a@example.com', password: 'a long unique phrase'),
    };

    for (final entry in calls.entries) {
      test('${entry.key}: a 426 raises the gate', () async {
        final c = await container();
        expect(c.read(upgradeGateProvider), isFalse);
        await expectLater(entry.value(c), throwsA(isA<Object>()));
        expect(c.read(upgradeGateProvider), isTrue);
      });
    }
  });

  group('the screen', () {
    testWidgets('a 426 from Home puts the app on the Update screen, with '
        'what is kept, and the store link', (tester) async {
      final world = await openHttpApp(
        tester,
        fallback: (_) => _upgrade(),
        settle: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      expect(
        find.text(
          "This version of AfterMe isn't supported any more. Please update "
          'AfterMe to keep your plan running.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('kept on this phone'), findsOneWidget);
      expect(world.container.read(upgradeGateProvider), isTrue);
      // The app below is not reachable.
      expect(find.text('Home'), findsNothing);

      await tapText(tester, 'Update in Google Play');
      await tester.pump();
      expect(world.fakes.urls.opened.single, AppConfig.defaultPlayStoreUrl);
      expect(find.textContaining("couldn't open Google Play"), findsNothing);
    });

    testWidgets('the store link comes from the configuration', (tester) async {
      final world = await openHttpApp(
        tester,
        fallback: (_) => _upgrade(),
        settle: false,
      );
      await tester.pumpAndSettle();
      expect(
        world.container.read(appConfigProvider).playStoreUrl,
        devConfig.playStoreUrl,
      );
    });

    testWidgets('a store that cannot be opened is said calmly', (tester) async {
      final fakes = TestFakes();
      fakes.urls.succeeds = false;
      await openHttpApp(
        tester,
        fakes: fakes,
        fallback: (_) => _upgrade(),
        settle: false,
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Update in Google Play');
      await tester.pumpAndSettle();
      expect(find.textContaining("couldn't open Google Play"), findsOneWidget);
    });

    testWidgets('it is lifted by the next success, and Check again asks the '
        'server', (tester) async {
      var accepted = false;
      final world = await openHttpApp(
        tester,
        routes: {
          'GET /v1/home': (_) =>
              accepted ? FakeReply.json(200, homeJson()) : _upgrade(),
        },
        settle: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);

      // Still not accepted: Check again says so and keeps the gate.
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      expect(find.textContaining('still isn\'t supported'), findsOneWidget);

      accepted = true;
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsNothing);
      expect(world.container.read(upgradeGateProvider), isFalse);
      expect(find.text("You're checked in"), findsOneWidget);
    });

    testWidgets('it does not appear for other failures', (tester) async {
      final world = await openHttpApp(
        tester,
        fallback: (_) => FakeReply.problem(500, 'internal_error'),
        settle: false,
      );
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsNothing);
      expect(world.container.read(upgradeGateProvider), isFalse);
    });

    testWidgets('what the person typed is still there when it is lifted', (
      tester,
    ) async {
      // Signed out: "Check again" is a real request through the same version check
      // (`GET /v1/me` without a token: 426 refuses, 401 `unauthenticated` accepts).
      var version = 'old';
      final world = await openHttpApp(
        tester,
        status: AuthStatus.signedOut,
        route: AppRoutes.signIn,
        routes: {
          'GET /v1/me': (_) => version == 'old'
              ? _upgrade()
              : FakeReply.problem(401, 'unauthenticated'),
        },
      );
      await typeInto(tester, 'Email', 'someone@example.com');
      world.container.read(upgradeGateProvider.notifier).raise();
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      expect(find.text('Email'), findsNothing, reason: 'covered');
      // Back is swallowed: the page below keeps its state.
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pump();

      // Still refused: said so, and the gate stays.
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      expect(find.textContaining('still isn\'t supported'), findsOneWidget);
      expect(world.to('GET', '/v1/me'), hasLength(1));
      expect(world.to('GET', '/v1/me').single.bearer, isNull);

      // Accepted: the version check passed (the API answered 401 after it).
      version = 'new';
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsNothing);
      expect(world.to('GET', '/v1/me'), hasLength(2));
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Email'),
      );
      expect(field.controller!.text, 'someone@example.com');
    });

    for (final (name, reply) in <(String, FakeReply)>[
      ('a lost connection', const FakeReply.networkError()),
      ('server trouble', FakeReply.problem(500, 'internal_error')),
      ('a rate limit', FakeReply.problem(429, 'rate_limited')),
    ]) {
      testWidgets('Check again with $name says it could not check, never "still '
          'not supported"', (tester) async {
        var answer = _upgrade();
        final world = await openHttpApp(
          tester,
          routes: {'GET /v1/home': (_) => answer},
          settle: false,
        );
        await tester.pumpAndSettle();
        expect(find.text('Update AfterMe'), findsOneWidget);

        answer = reply;
        await tapText(tester, 'Check again');
        await tester.pumpAndSettle();
        expect(find.text('Update AfterMe'), findsOneWidget);
        expect(
          find.text(
            "We couldn't check just now. Check your connection and try again.",
          ),
          findsOneWidget,
        );
        expect(find.textContaining('still isn\'t supported'), findsNothing);
        expect(world.container.read(upgradeGateProvider), isTrue);
      });
    }

    testWidgets('signed out and offline, Check again does not lift the gate '
        'without an answer', (tester) async {
      final world = await openHttpApp(
        tester,
        status: AuthStatus.signedOut,
        route: AppRoutes.signIn,
        routes: {'GET /v1/me': (_) => const FakeReply.networkError()},
      );
      world.container.read(upgradeGateProvider.notifier).raise();
      await tester.pumpAndSettle();
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      expect(find.textContaining("We couldn't check just now"), findsOneWidget);
      expect(world.container.read(upgradeGateProvider), isTrue);
    });

    testWidgets('a tap refused because of the version is sent by itself, with '
        'its own key, once the server accepts the app again', (tester) async {
      var upToDate = false;
      final world = await openHttpApp(
        tester,
        fallback: (r) {
          if (r.path == '/v1/auth/refresh') {
            return FakeReply.json(200, refreshResponse().toJson());
          }
          if (r.method == 'POST' && r.path == '/v1/checkins') {
            return upToDate
                ? FakeReply.json(200, checkinResultJson())
                : _upgrade();
          }
          return r.path == '/v1/home'
              ? FakeReply.json(200, homeJson())
              : FakeReply.problem(404, 'not_found');
        },
      );
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      final key = world
          .to('POST', '/v1/checkins')
          .single
          .header('Idempotency-Key');
      expect(key, isNotNull);

      upToDate = true;
      await tapText(tester, 'Check again');
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsNothing);
      final sent = world.to('POST', '/v1/checkins');
      expect(sent, hasLength(2));
      expect(sent.last.header('Idempotency-Key'), key);
      expect(
        world.store.values.containsKey(PendingCheckInStore.storageKey),
        isFalse,
        reason: 'confirmed, so forgotten',
      );
    });

    testWidgets('a pending check-in stays in storage under the gate, and is '
        'sent once the app is up to date', (tester) async {
      final store = InMemorySecureStore();
      var upToDate = false;
      FakeReply routes(RecordedRequest r) {
        if (r.path == '/v1/auth/refresh') {
          return FakeReply.json(200, refreshResponse().toJson());
        }
        if (r.path == '/v1/checkins' && r.method == 'POST') {
          return upToDate
              ? FakeReply.json(200, checkinResultJson())
              : _upgrade();
        }
        return upToDate
            ? FakeReply.json(200, homeJson())
            : (r.path == '/v1/home'
                  ? FakeReply.json(200, homeJson())
                  : FakeReply.problem(404, 'not_found'));
      }

      final world = await openHttpApp(
        tester,
        store: store,
        fallback: routes,
        fakes: TestFakes()..keys.next(),
      );
      // Tap I'M OK: the server refuses this version.
      await tester.tap(find.byType(CheckInButton));
      await tester.pumpAndSettle();
      expect(find.text('Update AfterMe'), findsOneWidget);
      final record = PendingCheckIn.tryDecode(
        store.values[PendingCheckInStore.storageKey],
      );
      expect(record, isNotNull, reason: 'kept, with its key');
      final sentWith = world
          .to('POST', '/v1/checkins')
          .single
          .header('Idempotency-Key');
      expect(sentWith, record!.idempotencyKey);

      // The app is updated and started again: the same tap goes out with the same key.
      upToDate = true;
      final second = await openHttpApp(
        tester,
        store: store,
        fallback: routes,
        fakes: TestFakes(),
      );
      await tester.pumpAndSettle();
      final resent = second.to('POST', '/v1/checkins');
      expect(resent, hasLength(1));
      expect(resent.single.header('Idempotency-Key'), record.idempotencyKey);
      expect(
        store.values.containsKey(PendingCheckInStore.storageKey),
        isFalse,
        reason: 'confirmed, so forgotten',
      );
    });
  });
}

/// "Check again" claims only what the answer says.
void upgradeRecheckTests() {
  group('classifyUpgradeRecheck', () {
    test('a 2xx that lifted the gate is accepted', () {
      expect(
        classifyUpgradeRecheck(null, gateRaised: false),
        UpgradeRecheck.accepted,
      );
    });

    test('a request that was not really made is not an answer', () {
      expect(
        classifyUpgradeRecheck(null, gateRaised: true),
        UpgradeRecheck.inconclusive,
      );
    });

    test('only a 426 refuses the version', () {
      expect(
        classifyUpgradeRecheck(
          const UpgradeRequiredFailure(),
          gateRaised: true,
        ),
        UpgradeRecheck.refused,
      );
    });

    test('offline, server trouble, a rate limit and a lost answer prove '
        'nothing', () {
      for (final failure in <AppFailure>[
        const NetworkFailure(),
        const ServerFailure(statusCode: 503),
        const RateLimitedFailure(),
        const UnknownFailure(),
      ]) {
        expect(
          classifyUpgradeRecheck(failure, gateRaised: true),
          UpgradeRecheck.inconclusive,
          reason: '${failure.runtimeType}',
        );
      }
    });

    test('an answer from the API after its version check accepts the '
        'version', () {
      for (final failure in <AppFailure>[
        const UnauthorizedFailure(code: 'unauthenticated'),
        const ForbiddenFailure(code: 'forbidden'),
        const NotFoundFailure(),
      ]) {
        expect(
          classifyUpgradeRecheck(failure, gateRaised: true),
          UpgradeRecheck.accepted,
          reason: '${failure.runtimeType}',
        );
      }
    });
  });
}

/// Only the OS version and locale are read by the repository's calls above.
class FakeDeviceInfoSourceForGate implements DeviceInfoSource {
  @override
  Future<List<String>> availableTimezones() async => const ['UTC'];

  @override
  String localeTag() => 'en';

  @override
  Future<String> osVersion() async => '15';

  @override
  Future<String?> timezone() async => 'UTC';
}
