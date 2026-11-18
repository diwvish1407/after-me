import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/api/models/token_response.dart';
import '../../../core/auth/auth_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../data/auth_repository.dart';
import '../data/google_sign_in_gateway.dart';
import 'signup_controller.dart';

/// The outcome of a sign-in attempt.
enum LoginResult {
  /// Signed in; the router takes over.
  signedIn,

  /// The account exists but its email was never confirmed; a new code was sent.
  needsVerification,

  /// The password was right; the account has two-step verification: ask for the code
  /// and sign in again with it.
  needsCode,

  /// The person closed the Google account picker.
  cancelled,

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
    String? otp,
  }) async {
    if (state.busy) {
      return LoginResult.failed;
    }
    state = const LoginState(busy: true);
    try {
      final tokens = await ref
          .read(authRepositoryProvider)
          .login(email: email, password: password, otp: otp);
      return await _signedIn(tokens);
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (failure is UnauthorizedFailure && failure.code == 'mfa_required') {
        state = const LoginState();
        return LoginResult.needsCode;
      }
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

  Future<LoginResult> _signedIn(TokenResponse tokens) async {
    await ref
        .read(onboardingControllerProvider.notifier)
        .accountSignedIn(tokens.user.id);
    await ref.read(authControllerProvider.notifier).signIn(tokens);
    state = const LoginState();
    return LoginResult.signedIn;
  }

  /// Sign in with Google: the account picker, then the server. [idToken] is reused for
  /// the second step when two-step verification asks for a code.
  Future<(LoginResult, String?)> signInWithGoogle({
    required String timezone,
    String? idToken,
    String? otp,
  }) async {
    if (state.busy) {
      return (LoginResult.failed, idToken);
    }
    state = const LoginState(busy: true);
    String? token = idToken;
    try {
      token ??= await ref.read(googleSignInGatewayProvider).idToken();
      if (token == null) {
        state = const LoginState();
        return (LoginResult.cancelled, null);
      }
      final tokens = await ref
          .read(authRepositoryProvider)
          .googleLogin(idToken: token, timezone: timezone, otp: otp);
      return (await _signedIn(tokens), null);
    } on Object catch (error) {
      final failure = toAppFailure(error);
      if (failure is UnauthorizedFailure && failure.code == 'mfa_required') {
        state = const LoginState();
        return (LoginResult.needsCode, token);
      }
      state = LoginState(failure: failure);
      return (LoginResult.failed, token);
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
