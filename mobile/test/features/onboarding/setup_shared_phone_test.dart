import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/instructions/data/instructions_repository.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fakes.dart';
import '../../helpers/test_app.dart';

/// Shared phone (review M-2): what one account saved in onboarding, an instruction's
/// title, must never read as "saved" for the next account that signs in.
void main() {
  test(
    'A\'s saved instruction is not B\'s after sign-out and sign-in',
    () async {
      final fakes = TestFakes();
      final container = ProviderContainer.test(
        retry: (retryCount, error) => null,
        overrides: testOverrides(fakes: fakes),
      );
      container.listen(setupControllerProvider, (_, _) {});
      final auth = container.read(authControllerProvider.notifier);
      await auth.restored;

      await auth.signIn(tokenResponse());
      await container.read(setupControllerProvider.future);
      await container
          .read(setupControllerProvider.notifier)
          .createInstruction(
            category: InstructionCategory.home,
            title: 'Where the spare key is',
            body: 'Under the third pot.',
            recipients: const [],
          );
      final mine = container.read(setupControllerProvider).value!;
      expect(mine.instructions.map((i) => i.title), ['Where the spare key is']);

      await auth.signOut();
      await pumpEventQueue();
      await auth.signIn(tokenResponse(userId: 'user-2', refresh: 'refresh-b'));
      await pumpEventQueue();
      final theirs = await container.read(setupControllerProvider.future);
      expect(
        theirs.instructions,
        isEmpty,
        reason: 'nothing of A is carried over',
      );
    },
  );

  test('a re-read keeps what this account saved on this run', () async {
    final fakes = TestFakes();
    final container = ProviderContainer.test(
      retry: (retryCount, error) => null,
      overrides: testOverrides(fakes: fakes),
    );
    container.listen(setupControllerProvider, (_, _) {});
    final auth = container.read(authControllerProvider.notifier);
    await auth.restored;
    await auth.signIn(tokenResponse());
    await container.read(setupControllerProvider.future);
    final setup = container.read(setupControllerProvider.notifier);
    await setup.createInstruction(
      category: InstructionCategory.home,
      title: 'Keys',
      body: 'Body text.',
      recipients: const [],
    );
    await setup.refresh();
    expect(
      container
          .read(setupControllerProvider)
          .value!
          .instructions
          .map((i) => i.title),
      ['Keys'],
    );
  });
}
