import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/activity/data/dio_activity_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/api_wire.dart';
import '../../helpers/fake_http_adapter.dart';

/// `GET /v1/activity` over the real API client on a fake network.
void main() {
  test('asks for the page size and the cursor, nothing else', () async {
    final wire = await apiWire(
      (_, _) => const FakeReply.json(200, {'items': <Object>[]}),
    );
    final page = await DioActivityRepository(dio: wire.dio)
        .list(limit: 20, cursor: 'abc');
    expect(wire.request.method, 'GET');
    expect(wire.request.path, '/v1/activity');
    expect(wire.request.uri.queryParameters, {'limit': '20', 'cursor': 'abc'});
    expect(page.items, isEmpty);
    expect(page.nextCursor, isNull);
  });

  test('the first page has no cursor in the request', () async {
    final wire = await apiWire(
      (_, _) => const FakeReply.json(200, {'items': <Object>[]}),
    );
    await DioActivityRepository(dio: wire.dio).list();
    expect(wire.request.uri.queryParameters, {'limit': '20'});
  });

  test('a read is repeated by the client after a lost connection', () async {
    var calls = 0;
    final wire = await apiWire(
      (_, _) => ++calls == 1
          ? const FakeReply.networkError()
          : const FakeReply.json(200, {'items': <Object>[]}),
    );
    await DioActivityRepository(dio: wire.dio).list();
    expect(wire.adapter.requests, hasLength(2));
  });

  test('problems become failures: 422 on a cursor, 401, 500', () async {
    var wire = await apiWire(
      (_, _) => FakeReply.problem(
        422,
        'validation_failed',
        extra: {
          'errors': [
            {'field': 'cursor', 'code': 'invalid'},
          ],
        },
      ),
    );
    await expectLater(
      DioActivityRepository(dio: wire.dio).list(cursor: 'x'),
      throwsA(isA<ValidationFailure>()),
    );
    wire = await apiWire((_, _) => FakeReply.problem(401, 'session_revoked'));
    await expectLater(
      DioActivityRepository(dio: wire.dio).list(),
      throwsA(isA<UnauthorizedFailure>()),
    );
    wire = await apiWire((_, _) => FakeReply.problem(500, 'internal_error'));
    await expectLater(
      DioActivityRepository(dio: wire.dio).list(),
      throwsA(isA<ServerFailure>()),
    );
  });

  test('a body that is not a feed is a failure, never an empty list', () async {
    for (final reply in <FakeReply>[
      const FakeReply.raw(200, '<html>Login</html>', 'text/html'),
      const FakeReply.json(200, ['not', 'an', 'object']),
      const FakeReply.json(200),
    ]) {
      final wire = await apiWire((_, _) => reply);
      await expectLater(
        DioActivityRepository(dio: wire.dio).list(),
        throwsA(isA<UnknownFailure>()),
      );
    }
  });

  test(
    'entries the app cannot read are dropped, the others are kept',
    () async {
      final wire = await apiWire(
        (_, _) => const FakeReply.json(200, {
          'items': [
            {'id': 2, 'action': 'checkin.recorded', 'occurred_at': 'soon'},
            {
              'id': 1,
              'action': 'from.the.future',
              'occurred_at': '2026-10-08T09:00:00Z',
              'params': {'a': null},
            },
          ],
          'next_cursor': 'next',
        }),
      );
      final page = await DioActivityRepository(dio: wire.dio).list();
      expect(page.items.map((i) => i.action), ['from.the.future']);
      expect(page.nextCursor, 'next');
    },
  );
}
