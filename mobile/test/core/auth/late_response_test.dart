import 'dart:async';

import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/activity/application/activity_controller.dart';
import 'package:afterme/features/activity/data/activity_repository.dart';
import 'package:afterme/features/checkin/application/schedule_controller.dart';
import 'package:afterme/features/checkin/data/schedule_repository.dart';
import 'package:afterme/features/contacts/application/contacts_controller.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/home/data/home_repository.dart';
import 'package:afterme/features/incidents/application/incident_history_controller.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:afterme/features/instructions/application/instructions_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/plan/application/plan_controller.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_activity_server.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/incident_fixtures.dart';
import '../../helpers/test_app.dart';

/// A response that is on its way when the account changes must never land in the next
/// account's state.
///
/// A `Notifier` is the same object after sign-out and sign-in (`build()` runs again), and
/// `ref.mounted` stays true across it, so before the session-epoch guard a late answer
/// for account A was applied to B's controller: A's incident, contact names and
/// instruction titles on B's Home, and A's "you're marked safe" closing B's incident.
///
/// Each repository below is wrapped so that **the answer is read when the call is made**
/// (it is the answer to the question account A asked) and handed back only when the test
/// releases it, after B has signed in and loaded its own data.

/// Holds the answer of the next call that passes through it.
class _Hold {
  Completer<void>? _next;

  /// The next call's answer waits for the returned completer.
  Completer<void> arm() => _next = Completer<void>();

  Future<T> pass<T>(Future<T> Function() call) async {
    final hold = _next;
    _next = null;
    final value = await call();
    if (hold != null) {
      await hold.future;
    }
    return value;
  }
}

class _HomeLate implements HomeRepository {
  _HomeLate(this.inner, this.hold);

  final HomeRepository inner;
  final _Hold hold;

  @override
  Future<HomeSnapshot> load() => hold.pass(inner.load);
}

class _ScheduleLate implements ScheduleRepository {
  _ScheduleLate(this.inner, this.hold);

  final ScheduleRepository inner;
  final _Hold hold;

  @override
  Future<ScheduleSnapshot> get() => hold.pass(inner.get);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _PlanLate implements PlanRepository {
  _PlanLate(this.inner, this.hold);

  final PlanRepository inner;
  final _Hold hold;

  @override
  Future<Plan> get() => hold.pass(inner.get);

  @override
  Future<Plan> save(PlanDraft draft, {required String ifMatch}) =>
      hold.pass(() => inner.save(draft, ifMatch: ifMatch));
}

class _ContactsLate implements ContactsRepository {
  _ContactsLate(this.inner, this.hold);

  ContactsRepository inner;
  final _Hold hold;

  @override
  Future<List<TrustedContact>> list() => hold.pass(inner.list);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _InstructionsLate implements InstructionsRepository {
  _InstructionsLate(this.hold);

  List<InstructionSummary> items = const [];
  final _Hold hold;

  @override
  Future<List<InstructionSummary>> list({InstructionCategory? category}) {
    final captured = [...items];
    return hold.pass(() async => captured);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _IncidentsLate implements IncidentsRepository {
  _IncidentsLate(this.inner, this.hold);

  final IncidentsRepository inner;
  final _Hold hold;

  @override
  Future<SafeResult> markSafe(
    String incidentId, {
    required String idempotencyKey,
  }) => hold.pass(
    () => inner.markSafe(incidentId, idempotencyKey: idempotencyKey),
  );

  @override
  Future<IncidentPage> list({int limit = 20, String? cursor}) =>
      hold.pass(() => inner.list(limit: limit, cursor: cursor));

  @override
  Future<Incident> get(String id) => hold.pass(() => inner.get(id));
}

class _ActivityLate implements ActivityRepository {
  _ActivityLate(this.inner, this.hold);

  final ActivityRepository inner;
  final _Hold hold;

  @override
  Future<ActivityPage> list({int limit = 20, String? cursor}) =>
      hold.pass(() => inner.list(limit: limit, cursor: cursor));
}

/// The check-in repositories that are not the one under test stay the fake server.
List<Override> _checkInRepositories(
  TestFakes fakes, {
  HomeRepository? home,
  ScheduleRepository? schedule,
}) {
  fakes.realCheckInRepositories = true;
  return [
    homeRepositoryProvider.overrideWithValue(home ?? fakes.server),
    scheduleRepositoryProvider.overrideWithValue(schedule ?? fakes.server),
    checkInRepositoryProvider.overrideWithValue(fakes.server),
  ];
}

ProviderContainer _container(TestFakes fakes, List<Override> extra) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: [
      ...testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
      ...extra,
    ],
  );
  return container;
}

/// A signs out and B signs in.
Future<void> _switchAccount(ProviderContainer container) async {
  final auth =
      container.read(authControllerProvider.notifier) as FixedAuthController;
  auth.set(AuthStatus.signedOut);
  await pumpEventQueue();
  auth.set(AuthStatus.signedIn);
  await pumpEventQueue();
}

InstructionSummary _instruction(String id, String title) => InstructionSummary(
  id: id,
  title: title,
  category: InstructionCategory.other,
  status: InstructionStatus.active,
);

void main() {
  group('a late answer for the account that signed out', () {
    test('Home: A\'s aggregate is not shown to B', () async {
      final fakes = TestFakes();
      fakes.server.displayName = 'Alice';
      final hold = _Hold();
      final container = _container(
        fakes,
        _checkInRepositories(fakes, home: _HomeLate(fakes.server, hold)),
      );
      container.listen(homeControllerProvider, (_, _) {});
      final first = await container.read(homeControllerProvider.future);
      expect(first!.snapshot.user.displayName, 'Alice');

      // A pulls to refresh; the answer is slow.
      final release = hold.arm();
      final late = container.read(homeControllerProvider.notifier).refresh();
      await pumpEventQueue();

      // A signs out, B signs in and B's Home loads.
      fakes.server.displayName = 'Bob';
      await _switchAccount(container);
      final second = await container.read(homeControllerProvider.future);
      expect(second!.snapshot.user.displayName, 'Bob');

      release.complete();
      expect(await late, isNull, reason: 'nothing to report to B');
      await pumpEventQueue();
      expect(
        container.read(homeControllerProvider).value!.snapshot.user.displayName,
        'Bob',
      );
    });

    test('Home: B\'s own refresh is not answered with A\'s', () async {
      final fakes = TestFakes();
      fakes.server.displayName = 'Alice';
      final hold = _Hold();
      final container = _container(
        fakes,
        _checkInRepositories(fakes, home: _HomeLate(fakes.server, hold)),
      );
      container.listen(homeControllerProvider, (_, _) {});
      await container.read(homeControllerProvider.future);

      final release = hold.arm();
      final late = container.read(homeControllerProvider.notifier).refresh();
      await pumpEventQueue();
      fakes.server.displayName = 'Bob';
      await _switchAccount(container);
      await container.read(homeControllerProvider.future);

      // B asks while A's request is still running: it is B's own request, not A's
      // future handed back.
      fakes.server.displayName = 'Bob (renamed)';
      final callsBefore = fakes.server.calls.length;
      await container.read(homeControllerProvider.notifier).refresh();
      expect(fakes.server.calls.length, callsBefore + 1);
      expect(
        container.read(homeControllerProvider).value!.snapshot.user.displayName,
        'Bob (renamed)',
      );
      release.complete();
      await late;
    });

    test(
      'I\'M SAFE: A\'s "marked safe" does not close B\'s incident',
      () async {
        final fakes = TestFakes();
        fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
        fakes.plan.seedStandard(['c1']);
        fakes.server.activateNow();
        fakes.incidents.open(escalatedJson());
        fakes.auth.reauthenticated = true;
        final hold = _Hold();
        fakes.realIncidentsRepository = true;
        final container = _container(fakes, [
          incidentsRepositoryProvider.overrideWithValue(
            _IncidentsLate(fakes.incidents, hold),
          ),
        ]);
        container
          ..listen(homeControllerProvider, (_, _) {})
          ..listen(safeControllerProvider, (_, _) {});
        await container.read(homeControllerProvider.future);

        final release = hold.arm();
        final late = container
            .read(safeControllerProvider.notifier)
            .markSafe(incidentId);
        await pumpEventQueue();
        expect(container.read(safeControllerProvider).isSending, isTrue);

        // B has an incident of its own, contacts told.
        fakes.incidents.open(escalatedJson());
        await _switchAccount(container);
        final home = await container.read(homeControllerProvider.future);
        expect(home!.snapshot.incident, isNotNull);
        expect(container.read(safeControllerProvider).phase, SafePhase.idle);

        release.complete();
        await late;
        await pumpEventQueue();

        expect(
          container.read(safeControllerProvider).phase,
          SafePhase.idle,
          reason: 'B never asked to be marked safe',
        );
        expect(container.read(safeControllerProvider).result, isNull);
        expect(
          container.read(homeControllerProvider).value!.snapshot.incident,
          isNotNull,
          reason: 'B\'s incident is still open on B\'s Home',
        );
      },
    );

    test('the plan: A\'s plan is not B\'s', () async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.plan.seedStandard(['c1']);
      final hold = _Hold();
      fakes.realPlanRepository = true;
      final container = _container(fakes, [
        planRepositoryProvider.overrideWithValue(_PlanLate(fakes.plan, hold)),
      ]);
      container.listen(planControllerProvider, (_, _) {});
      final first = await container.read(planControllerProvider.future);
      expect(first!.graceMinutes, 180);

      final release = hold.arm();
      final late = container.read(planControllerProvider.notifier).reload();
      await pumpEventQueue();

      fakes.plan.seedStandard(['c1'], offsetMinutes: 360);
      await _switchAccount(container);
      final second = await container.read(planControllerProvider.future);
      expect(second!.graceMinutes, 360);

      release.complete();
      expect(await late, isNull);
      await pumpEventQueue();
      expect(container.read(planControllerProvider).value!.graceMinutes, 360);
    });

    test('contacts: A\'s names are not B\'s', () async {
      final fakes = TestFakes();
      final alice = InMemoryContactsRepository(
        initial: [testContact(name: 'Alice\'s mother')],
      );
      final bob = InMemoryContactsRepository(
        initial: [testContact(name: 'Bob\'s brother')],
      );
      final hold = _Hold();
      final late = _ContactsLate(alice, hold);
      fakes.realContactsRepository = true;
      final container = _container(fakes, [
        contactsRepositoryProvider.overrideWithValue(late),
      ]);
      container.listen(contactsControllerProvider, (_, _) {});
      final first = await container.read(contactsControllerProvider.future);
      expect(first.single.displayName, 'Alice\'s mother');

      final release = hold.arm();
      final reload = container
          .read(contactsControllerProvider.notifier)
          .reload();
      await pumpEventQueue();

      late.inner = bob;
      await _switchAccount(container);
      final second = await container.read(contactsControllerProvider.future);
      expect(second.single.displayName, 'Bob\'s brother');

      release.complete();
      expect(await reload, isNull);
      await pumpEventQueue();
      expect(
        container.read(contactsControllerProvider).value!.single.displayName,
        'Bob\'s brother',
      );
    });

    test('the schedule: A\'s settings are not B\'s', () async {
      final fakes = TestFakes();
      fakes.server.intervalDays = 1;
      final hold = _Hold();
      final container = _container(
        fakes,
        _checkInRepositories(
          fakes,
          schedule: _ScheduleLate(fakes.server, hold),
        ),
      );
      container.listen(scheduleControllerProvider, (_, _) {});
      final first = await container.read(scheduleControllerProvider.future);
      expect(first!.settings.intervalDays, 1);

      final release = hold.arm();
      final late = container.read(scheduleControllerProvider.notifier).reload();
      await pumpEventQueue();

      fakes.server.intervalDays = 3;
      await _switchAccount(container);
      final second = await container.read(scheduleControllerProvider.future);
      expect(second!.settings.intervalDays, 3);

      release.complete();
      expect(await late, isNull);
      await pumpEventQueue();
      expect(
        container.read(scheduleControllerProvider).value!.settings.intervalDays,
        3,
      );
    });

    test('instructions: A\'s titles are not B\'s', () async {
      final fakes = TestFakes();
      final hold = _Hold();
      final repo = _InstructionsLate(hold)
        ..items = [_instruction('a1', 'Alice\'s safe')];
      fakes.realInstructionsRepository = true;
      final container = _container(fakes, [
        instructionsRepositoryProvider.overrideWithValue(repo),
      ]);
      container.listen(instructionsControllerProvider, (_, _) {});
      final first = await container.read(instructionsControllerProvider.future);
      expect(first.single.title, 'Alice\'s safe');

      final release = hold.arm();
      final late = container
          .read(instructionsControllerProvider.notifier)
          .reload();
      await pumpEventQueue();

      repo.items = [_instruction('b1', 'Bob\'s car')];
      await _switchAccount(container);
      final second = await container.read(
        instructionsControllerProvider.future,
      );
      expect(second.single.title, 'Bob\'s car');

      release.complete();
      expect(await late, isNull);
      await pumpEventQueue();
      expect(
        container.read(instructionsControllerProvider).value!.single.title,
        'Bob\'s car',
      );
    });
  });

  group('a page that is asked for before the list is read again', () {
    TestFakes feed(int count) {
      final fakes = TestFakes();
      fakes.activity.items = [
        for (var i = count; i >= 1; i--)
          activityItem(
            'plan.updated',
            id: i,
            at: DateTime.utc(2026, 10, 8, 9, i % 60),
          ),
      ];
      return fakes;
    }

    test('Activity: "Show more" that lands after a refresh does not put the '
        'older list back', () async {
      final fakes = feed(45);
      final hold = _Hold();
      fakes.realActivityRepository = true;
      final container = _container(fakes, [
        activityRepositoryProvider.overrideWithValue(
          _ActivityLate(fakes.activity, hold),
        ),
      ]);
      container.listen(activityControllerProvider, (_, _) {});
      await container.read(activityControllerProvider.future);
      final controller = container.read(activityControllerProvider.notifier);

      // "Show more" is asked for and is slow ...
      final release = hold.arm();
      final more = controller.loadMore();
      await pumpEventQueue();
      expect(
        container.read(activityControllerProvider).value!.loadingMore,
        isTrue,
      );

      // ... meanwhile the person pulls to refresh and a new entry is there.
      fakes.activity.items = [
        activityItem('checkin.recorded', id: 99),
        ...fakes.activity.items,
      ];
      expect(await controller.reload(), isNull);
      final refreshed = container.read(activityControllerProvider).value!;
      expect(refreshed.items.first.id, 99);

      release.complete();
      await more;
      final after = container.read(activityControllerProvider).value!;
      expect(
        after.items.first.id,
        99,
        reason: 'the older first page was put back over the refreshed one',
      );
      expect(after.items, hasLength(refreshed.items.length));
      expect(after.loadingMore, isFalse);
    });

    test('Activity: a refresh that fails does not leave "Show more" '
        'spinning', () async {
      final fakes = feed(45);
      final hold = _Hold();
      fakes.realActivityRepository = true;
      final container = _container(fakes, [
        activityRepositoryProvider.overrideWithValue(
          _ActivityLate(fakes.activity, hold),
        ),
      ]);
      container.listen(activityControllerProvider, (_, _) {});
      await container.read(activityControllerProvider.future);
      final controller = container.read(activityControllerProvider.notifier);

      final release = hold.arm();
      final more = controller.loadMore();
      await pumpEventQueue();
      fakes.activity.failures.add(const NetworkFailure());
      await controller.reload();
      release.complete();
      await more;

      final state = container.read(activityControllerProvider).value!;
      expect(state.items, hasLength(20));
      expect(state.loadingMore, isFalse);
    });

    test('Activity: nothing is written to a controller that is gone', () async {
      final fakes = feed(45);
      final hold = _Hold();
      fakes.realActivityRepository = true;
      final container = _container(fakes, [
        activityRepositoryProvider.overrideWithValue(
          _ActivityLate(fakes.activity, hold),
        ),
      ]);
      final subscription = container.listen(
        activityControllerProvider,
        (_, _) {},
      );
      await container.read(activityControllerProvider.future);
      final controller = container.read(activityControllerProvider.notifier);

      final release = hold.arm();
      final more = controller.loadMore();
      await pumpEventQueue();
      // The screen was left: the autoDispose controller goes.
      subscription.close();
      await pumpEventQueue();

      release.complete();
      await expectLater(more, completes);
      final reload = controller.reload();
      await expectLater(reload, completes);
    });

    test('incident history: "Show more" that lands after a refresh does not '
        'put the older list back', () async {
      final fakes = TestFakes();
      for (var i = 0; i < 30; i++) {
        fakes.incidents.addClosed(
          incidentJson(
              id: 'closed-$i',
              status: 'resolved',
              requires: null,
              closedAt: DateTime.utc(2026, 9, 1, 10).add(Duration(minutes: i)),
              closedBy: 'user_checkin',
            )
            ..['anchor_at'] = iso(
              DateTime.utc(2026, 9, 1, 9).add(Duration(minutes: i)),
            ),
        );
      }
      final hold = _Hold();
      fakes.realIncidentsRepository = true;
      final container = _container(fakes, [
        incidentsRepositoryProvider.overrideWithValue(
          _IncidentsLate(fakes.incidents, hold),
        ),
      ]);
      container.listen(incidentHistoryControllerProvider, (_, _) {});
      await container.read(incidentHistoryControllerProvider.future);
      final controller = container.read(
        incidentHistoryControllerProvider.notifier,
      );
      final firstPage = container
          .read(incidentHistoryControllerProvider)
          .value!
          .items
          .map((i) => i.id)
          .toList();

      final release = hold.arm();
      final more = controller.loadMore();
      await pumpEventQueue();

      // A newer incident closed meanwhile; the person refreshes.
      fakes.incidents.addClosed(
        incidentJson(
          id: 'newest',
          status: 'resolved',
          requires: null,
          closedAt: DateTime.utc(2026, 10, 1, 10),
          closedBy: 'user_checkin',
        )..['anchor_at'] = iso(DateTime.utc(2026, 10, 1, 9)),
      );
      expect(await controller.reload(), isNull);
      final refreshed = container
          .read(incidentHistoryControllerProvider)
          .value!
          .items
          .map((i) => i.id)
          .toList();
      expect(refreshed.first, 'newest');
      expect(refreshed, isNot(firstPage));

      release.complete();
      await more;
      final after = container
          .read(incidentHistoryControllerProvider)
          .value!
          .items
          .map((i) => i.id)
          .toList();
      expect(after, refreshed);
    });
  });
}
