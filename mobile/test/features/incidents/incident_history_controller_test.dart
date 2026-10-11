import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/incidents/application/incident_history_controller.dart';
import 'package:afterme/features/incidents/data/incidents_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/incident_fixtures.dart';
import '../../helpers/test_app.dart';

/// A closed incident number [n]: the later the number, the earlier it happened.
Map<String, dynamic> _closed(int n, {String closedBy = 'user_checkin'}) {
  final opened = DateTime.utc(2026, 9, 1).add(Duration(days: 40 - n));
  final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  return {
    ...incidentJson(
      id: id,
      status: closedBy == 'user_safe' ? 'cancelled' : 'resolved',
      requires: null,
      contactsMessaged: closedBy == 'user_safe',
      closedAt: opened.add(const Duration(minutes: 20)),
      closedBy: closedBy,
    ),
    'missed_due_at': iso(opened),
    'anchor_at': iso(opened.add(const Duration(seconds: 1))),
  };
}

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    retry: (retryCount, error) => null,
    overrides: testOverrides(authStatus: AuthStatus.signedIn, fakes: fakes),
  );
  container.listen(incidentHistoryControllerProvider, (_, _) {});
  return container;
}

IncidentHistoryController _controller(ProviderContainer c) =>
    c.read(incidentHistoryControllerProvider.notifier);

void main() {
  group('IncidentHistoryController', () {
    test('an account that never missed a check-in has an empty list', () async {
      final container = _container(TestFakes());
      final state = await container.read(
        incidentHistoryControllerProvider.future,
      );
      expect(state.items, isEmpty);
      expect(state.hasMore, isFalse);
    });

    test(
      'newest first, a page at a time, and the cursor is followed',
      () async {
        final fakes = TestFakes();
        for (var n = 1; n <= 22; n++) {
          fakes.incidents.addClosed(_closed(n));
        }
        final container = _container(fakes);
        var state = await container.read(
          incidentHistoryControllerProvider.future,
        );
        expect(state.items, hasLength(20));
        expect(state.hasMore, isTrue);
        expect(state.nextCursor, '20');
        final opened = [for (final i in state.items) i.openedAt];
        expect([...opened]..sort((a, b) => b.compareTo(a)), opened);

        await _controller(container).loadMore();
        state = container.read(incidentHistoryControllerProvider).value!;
        expect(state.items, hasLength(22));
        expect(state.hasMore, isFalse);
        expect(state.loadingMore, isFalse);
        expect({for (final i in state.items) i.id}, hasLength(22));

        // Nothing more to load: no request.
        final calls = fakes.incidents.calls.length;
        await _controller(container).loadMore();
        expect(fakes.incidents.calls, hasLength(calls));
      },
    );

    test(
      'an open incident is listed first, with how the others ended',
      () async {
        final fakes = TestFakes();
        fakes.incidents.addClosed(_closed(5, closedBy: 'user_safe'));
        fakes.incidents.open(incidentJson());
        final container = _container(fakes);
        final state = await container.read(
          incidentHistoryControllerProvider.future,
        );
        expect(state.items, hasLength(2));
        expect(state.items.first.isClosed, isFalse);
        expect(state.items.last.closedBy, IncidentClosedBy.userSafe);
      },
    );

    test('a failure while loading more keeps the list and says why', () async {
      final fakes = TestFakes();
      for (var n = 1; n <= 22; n++) {
        fakes.incidents.addClosed(_closed(n));
      }
      final container = _container(fakes);
      await container.read(incidentHistoryControllerProvider.future);
      fakes.incidents.failures['list'] = [const NetworkFailure()];
      await _controller(container).loadMore();
      var state = container.read(incidentHistoryControllerProvider).value!;
      expect(state.items, hasLength(20));
      expect(state.moreFailure, isA<NetworkFailure>());
      expect(state.loadingMore, isFalse);
      expect(state.hasMore, isTrue);

      await _controller(container).loadMore();
      state = container.read(incidentHistoryControllerProvider).value!;
      expect(state.items, hasLength(22));
      expect(state.moreFailure, isNull);
    });

    test(
      'the first load failing is an error that can be tried again',
      () async {
        final fakes = TestFakes();
        fakes.incidents.failures['list'] = [const NetworkFailure()];
        final container = _container(fakes);
        await expectLater(
          container.read(incidentHistoryControllerProvider.future),
          throwsA(isA<NetworkFailure>()),
        );
        expect(
          container.read(incidentHistoryControllerProvider).error,
          isA<NetworkFailure>(),
        );
        expect(await _controller(container).reload(), isNull);
        expect(
          container.read(incidentHistoryControllerProvider).hasValue,
          isTrue,
        );
      },
    );

    test(
      'a failed reload keeps what is on screen and returns the failure',
      () async {
        final fakes = TestFakes();
        fakes.incidents.addClosed(_closed(1));
        final container = _container(fakes);
        await container.read(incidentHistoryControllerProvider.future);
        fakes.incidents.failures['list'] = [
          const ServerFailure(statusCode: 500),
        ];
        final failure = await _controller(container).reload();
        expect(failure, isA<ServerFailure>());
        expect(
          container.read(incidentHistoryControllerProvider).value!.items,
          hasLength(1),
        );
      },
    );

    test('signed out there is nothing to read', () async {
      final container = ProviderContainer.test(
        overrides: testOverrides(authStatus: AuthStatus.signedOut),
      );
      final state = await container.read(
        incidentHistoryControllerProvider.future,
      );
      expect(state.items, isEmpty);
    });
  });
}
