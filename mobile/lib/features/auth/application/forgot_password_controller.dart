import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../data/auth_repository.dart';

@immutable
class ForgotPasswordState {
  const ForgotPasswordState({
    this.busy = false,
    this.sent = false,
    this.failure,
  });

  final bool busy;

  /// The request was accepted. The server answers the same way whether or not an
  /// account exists, so the app says so too.
  final bool sent;
  final AppFailure? failure;
}

class ForgotPasswordController extends Notifier<ForgotPasswordState> {
  @override
  ForgotPasswordState build() => const ForgotPasswordState();

  Future<void> submit(String email) async {
    if (state.busy) {
      return;
    }
    state = const ForgotPasswordState(busy: true);
    try {
      await ref.read(authRepositoryProvider).forgotPassword(email: email);
      state = const ForgotPasswordState(sent: true);
    } on Object catch (error) {
      state = ForgotPasswordState(failure: toAppFailure(error));
    }
  }

  /// Back to the form (for "use a different email").
  void reset() => state = const ForgotPasswordState();
}

final forgotPasswordControllerProvider =
    NotifierProvider.autoDispose<ForgotPasswordController, ForgotPasswordState>(
      ForgotPasswordController.new,
    );
