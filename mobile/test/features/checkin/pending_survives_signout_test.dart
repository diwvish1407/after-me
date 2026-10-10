import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/features/checkin/application/pending_checkin_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

/// A tap the server has not confirmed must outlive the end of the session that made it
/// (`session_revoked`, a rejected refresh, "log out everywhere"), because the app tells
/// the person it is kept and will be sent once they sign in. The earlier test of this
/// used a fixed auth controller and never reached the real session store.
void main() {
  test(
    'a pending check-in survives a real sign-out, bound to its account',
    () async {
      final fakes = TestFakes();
      final container = ProviderContainer.test(
        overrides: testOverrides(fakes: fakes),
      );
      final auth = container.read(authControllerProvider.notifier);
      await auth.restored;
      await auth.signIn(tokenResponse());
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isTrue,
      );

      final store = container.read(pendingCheckInStoreProvider);
      final record = PendingCheckIn(
        userId: 'user-1',
        idempotencyKey: 'key-for-this-tap',
        reportedAt: DateTime.utc(2026, 10, 10, 12),
      );
      await store.write(record);

      await auth.signOut();

      expect(container.read(authControllerProvider), AuthStatus.signedOut);
      expect(
        await container.read(sessionStoreProvider).hasPersistedSession(),
        isFalse,
      );
      expect(fakes.secure.values.keys, [PendingCheckInStore.storageKey]);
      expect(await store.read('user-1'), record);
      // Another account that signs in on this phone never sends it.
      expect(await store.read('user-2'), isNull);
    },
  );
}
