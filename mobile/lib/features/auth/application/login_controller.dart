import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../data/auth_repository.dart';
import 'signup_controller.dart';

/// The outcome of a sign-in attempt.
enum LoginResult {
  /// Signed in; the router takes over.
  signedIn,

  /// The account exists but its email was never confirmed; a new code was sent.
  needsVerification,

  /// Failed; see [LoginState.failure].
  failed,
}

@immutable
class LoginState {
  const LoginState({this.busy = false, this.failure});

  final bool busy;
  final AppFailure? failure;
}

/// Signs in with email and password. The password is passed through and not stored.
class LoginController extends Notifier<LoginState> {
  @override
  LoginState build() => const LoginState();

  Future<LoginResult> signIn({
    required String email,
    required String password,
  }) async {
    if (state.busy) {
      return LoginResult.failed;
    }
    state = const LoginState(busy: true);
    try {
      final tokens = await ref
          .read(authRepositoryProvider)
          .login(email: email, password: password);
      await ref
          .read(onboardingControllerProvider.notifier)
          .accountSignedIn(tokens.user.id);
      await ref.read(authControllerProvider.notifier).signIn(tokens);
      state = const LoginState();
      return LoginResult.signedIn;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (failure is ForbiddenFailure && failure.code == 'email_unverified') {
        // The server sent a new code. Verify it with the password just typed.
        ref
            .read(signupControllerProvider.notifier)
            .resumeVerification(email: email, password: password);
        state = const LoginState();
        return LoginResult.needsVerification;
      }
      state = LoginState(failure: failure);
      return LoginResult.failed;
    }
  }

  void clearFailure() {
    if (state.failure != null) {
      state = const LoginState();
    }
  }
}

final loginControllerProvider = NotifierProvider<LoginController, LoginState>(
  LoginController.new,
);
