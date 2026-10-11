import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/freshness/stale_data.dart';
import 'package:afterme/features/activity/application/activity_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_activity_server.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes, {AuthStatus? status}) =>
    ProviderContainer.test(
      retry: (count, error) => null,
      overrides: testOverrides(
        authStatus: status ?? AuthStatus.signedIn,
        fakes: fakes,
      ),
    );

TestFakes _feed(int count) {
  final fakes = TestFakes();
  fakes.activity.items = [
    for (var i = count; i >= 1; i--)
      activityItem('plan.updated', id: i, at: DateTime.utc(2026, 10, 8, 9, i)),
  ];
  return fakes;
}

void main() {
  test('the first page loads with the controller', () async {
    final fakes = _feed(45);
    final c = _container(fakes);
    final state = await c.read(activityControllerProvider.future);
    expect(state.items, hasLength(20));
    expect(state.items.first.id, 45, reason: 'newest first, as sent');
    expect(state.hasMore, isTrue);
    expect(fakes.activity.calls.single.limit, ActivityController.pageSize);
  });

  test('signed out there is nothing to read', () async {
    final fakes = _feed(5);
    final c = _container(fakes, status: AuthStatus.signedOut);
    final state = await c.read(activityControllerProvider.future);
    expect(state.items, isEmpty);
    expect(fakes.activity.calls, isEmpty);
  });

  test('loadMore appends, follows the cursor, and ends the feed', () async {
    final fakes = _feed(45);
    final c = _container(fakes);
    await c.read(activityControllerProvider.future);
    final controller = c.read(activityControllerProvider.notifier);
    await controller.loadMore();
    expect(c.read(activityControllerProvider).value!.items, hasLength(40));
    await controller.loadMore();
    final state = c.read(activityControllerProvider).value!;
    expect(state.items, hasLength(45));
    expect(state.hasMore, isFalse);
    // Nothing more to load: no request is made.
    final calls = fakes.activity.calls.length;
    await controller.loadMore();
    expect(fakes.activity.calls, hasLength(calls));
  });

  test('an entry that moved into the next page is not shown twice', () async {
    final fakes = _feed(30);
    final c = _container(fakes);
    await c.read(activityControllerProvider.future);
    // The server's last page repeats an entry that is already on screen.
    fakes.activity.items = [
      ...fakes.activity.items.take(20),
      ...fakes.activity.items.skip(19),
    ];
    await c.read(activityControllerProvider.notifier).loadMore();
    final ids = c
        .read(activityControllerProvider)
        .value!
        .items
        .map((i) => i.id)
        .toList();
    expect(ids.toSet(), hasLength(ids.length));
  });

  test('a page that fails keeps the list and the cursor', () async {
    final fakes = _feed(45);
    final c = _container(fakes);
    await c.read(activityControllerProvider.future);
    fakes.activity.failures.add(const NetworkFailure());
    final controller = c.read(activityControllerProvider.notifier);
    await controller.loadMore();
    var state = c.read(activityControllerProvider).value!;
    expect(state.items, hasLength(20));
    expect(state.moreFailure, isA<NetworkFailure>());
    expect(state.hasMore, isTrue);
    expect(state.loadingMore, isFalse);
    await controller.loadMore();
    state = c.read(activityControllerProvider).value!;
    expect(state.items, hasLength(40));
    expect(state.moreFailure, isNull);
  });

  test('reload reads the first page again and clears the note', () async {
    final fakes = _feed(3);
    final c = _container(fakes);
    await c.read(activityControllerProvider.future);
    final controller = c.read(activityControllerProvider.notifier);
    fakes.activity.failures.add(const ServerFailure(statusCode: 500));
    expect(await controller.reload(), isA<ServerFailure>());
    expect(c.read(staleDataProvider), {DataArea.activity});
    expect(c.read(activityControllerProvider).value!.items, hasLength(3));
    fakes.activity.items = [
      activityItem('checkin.recorded', id: 9),
      ...fakes.activity.items,
    ];
    expect(await controller.reload(), isNull);
    expect(c.read(staleDataProvider), isEmpty);
    expect(c.read(activityControllerProvider).value!.items, hasLength(4));
  });

  test(
    'a first load that fails is an error state, and Try again recovers',
    () async {
      final fakes = _feed(3);
      fakes.activity.failures.add(const NetworkFailure());
      final c = _container(fakes);
      await expectLater(
        c.read(activityControllerProvider.future),
        throwsA(isA<NetworkFailure>()),
      );
      final controller = c.read(activityControllerProvider.notifier);
      fakes.activity.failures.add(const NetworkFailure());
      expect(await controller.reload(), isA<NetworkFailure>());
      expect(c.read(activityControllerProvider).hasError, isTrue);
      expect(
        c.read(staleDataProvider),
        isEmpty,
        reason: 'nothing is on screen',
      );
      expect(await controller.reload(), isNull);
      expect(c.read(activityControllerProvider).value!.items, hasLength(3));
    },
  );

  test('a 422 on the cursor starts again from the newest entry', () async {
    final fakes = _feed(30);
    final c = _container(fakes);
    await c.read(activityControllerProvider.future);
    fakes.activity.issuedCursors.clear();
    await c.read(activityControllerProvider.notifier).loadMore();
    final state = c.read(activityControllerProvider).value!;
    expect(state.items, hasLength(20));
    expect(state.moreFailure, isNull);
    expect(fakes.activity.calls.last.cursor, isNull);
  });

  test('copyWith keeps what it is not given', () {
    const state = ActivityState(nextCursor: 'c');
    expect(state.copyWith(loadingMore: true).nextCursor, 'c');
    expect(state.copyWith(nextCursor: () => null).hasMore, isFalse);
    expect(
      state.copyWith(moreFailure: () => const NetworkFailure()).moreFailure,
      isA<NetworkFailure>(),
    );
  });
}
