import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/time/clock.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../data/auth_repository.dart';

/// Which part of sign-up the user is in.
enum SignupStage {
  /// Filling in the account form.
  form,

  /// A code was sent; waiting for it.
  code,

  /// The account exists and the session started.
  done,
}

/// What the user sees of the sign-up flow. It never holds the password or the code.
@immutable
class SignupState {
  const SignupState({
    this.stage = SignupStage.form,
    this.email = '',
    this.displayName = '',
    this.timezone = '',
    this.busy = false,
    this.resending = false,
    this.failure,
    this.codeRejected = false,
    this.resendAvailableAt,
    this.codeSentCount = 0,
  });

  final SignupStage stage;
  final String email;
  final String displayName;
  final String timezone;

  /// A request is running.
  final bool busy;
  final bool resending;

  /// The last failure, for the screen to show next to the right field.
  final AppFailure? failure;

  /// The server rejected the code (wrong, expired or used up).
  final bool codeRejected;

  /// The earliest time the "resend" action is offered.
  final DateTime? resendAvailableAt;

  /// How many times a code was sent in this flow (for announcements).
  final int codeSentCount;

  SignupState copyWith({
    SignupStage? stage,
    String? email,
    String? displayName,
    String? timezone,
    bool? busy,
    bool? resending,
    AppFailure? failure,
    bool clearFailure = false,
    bool? codeRejected,
    DateTime? resendAvailableAt,
    int? codeSentCount,
  }) => SignupState(
    stage: stage ?? this.stage,
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    timezone: timezone ?? this.timezone,
    busy: busy ?? this.busy,
    resending: resending ?? this.resending,
    failure: clearFailure ? null : (failure ?? this.failure),
    codeRejected: codeRejected ?? this.codeRejected,
    resendAvailableAt: resendAvailableAt ?? this.resendAvailableAt,
    codeSentCount: codeSentCount ?? this.codeSentCount,
  );
}

/// Drives sign-up: start, verify the code, resend.
///
/// **The password is kept in memory only**, in the private [_password] field, from the
/// moment it is submitted until the account is created or the flow is abandoned
/// ([abandon]). It is not part of [SignupState], never written to storage and never
/// logged (this class has no `toString`). The verification code is passed straight
/// through to the API and is not stored at all.
class SignupController extends Notifier<SignupState> {
  String? _password;

  @override
  SignupState build() {
    ref.onDispose(abandon);
    return const SignupState();
  }

  /// Whether the password is still held (for tests and for the screens to know that
  /// verification is possible).
  bool get hasPassword => _password != null;

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  /// Sends the first code. Returns true when the code step should be shown.
  Future<bool> start({
    required String displayName,
    required String email,
    required String password,
    required String timezone,
  }) async {
    if (state.busy) {
      return false;
    }
    _password = password;
    state = state.copyWith(
      busy: true,
      clearFailure: true,
      email: email,
      displayName: displayName,
      timezone: timezone,
    );
    try {
      final result = await _repo.registerStart(
        email: email,
        password: password,
        displayName: displayName,
        timezone: timezone,
        // The app speaks English only for now; the device locale goes in `device`.
        locale: 'en',
      );
      state = state.copyWith(
        busy: false,
        stage: SignupStage.code,
        resendAvailableAt: _resendAt(result.resendAfterSeconds),
        codeSentCount: state.codeSentCount + 1,
        codeRejected: false,
      );
      return true;
    } on Object catch (error) {
      _password = null;
      state = state.copyWith(busy: false, failure: toAppFailure(error));
      return false;
    }
  }

  /// Continues a sign-up from sign-in: the account exists but is not verified, and the
  /// server has just sent a code. The password the user typed is needed to verify.
  void resumeVerification({required String email, required String password}) {
    _password = password;
    state = SignupState(
      stage: SignupStage.code,
      email: email,
      resendAvailableAt: _resendAt(60),
      codeSentCount: 1,
    );
  }

  DateTime _resendAt(int seconds) =>
      ref.read(clockProvider)().add(Duration(seconds: seconds));

  /// Verifies the code and starts the session. Returns true on success.
  Future<bool> verify(String code) async {
    final password = _password;
    if (state.busy || password == null) {
      return false;
    }
    state = state.copyWith(busy: true, clearFailure: true, codeRejected: false);
    try {
      final tokens = await _repo.registerVerify(
        email: state.email,
        code: code,
        password: password,
      );
      // Onboarding must exist before the session does, so the router never flashes Home.
      await ref
          .read(onboardingControllerProvider.notifier)
          .beginForNewAccount(tokens.user.id);
      await ref.read(authControllerProvider.notifier).signIn(tokens);
      _password = null;
      state = state.copyWith(busy: false, stage: SignupStage.done);
      return true;
    } on Object catch (error) {
      final failure = toAppFailure(error);
      state = state.copyWith(
        busy: false,
        failure: failure,
        codeRejected:
            failure is ValidationFailure && failure.code == 'invalid_code',
      );
      return false;
    }
  }

  /// Sends a new code. Rate limits and failures end up in [SignupState.failure].
  Future<void> resend() async {
    if (state.busy || state.resending) {
      return;
    }
    final available = state.resendAvailableAt;
    if (available != null && ref.read(clockProvider)().isBefore(available)) {
      return;
    }
    state = state.copyWith(resending: true, clearFailure: true);
    try {
      final seconds = await _repo.registerResend(email: state.email);
      state = state.copyWith(
        resending: false,
        resendAvailableAt: _resendAt(seconds),
        codeSentCount: state.codeSentCount + 1,
      );
    } on Object catch (error) {
      state = state.copyWith(resending: false, failure: toAppFailure(error));
    }
  }

  /// "Wrong email?": back to the form. The password stays in memory (the form still
  /// shows it), the old code is useless.
  void changeEmail() {
    state = state.copyWith(
      stage: SignupStage.form,
      clearFailure: true,
      codeRejected: false,
    );
  }

  /// Forgets the password. Called when the flow ends or the screens go away.
  void abandon() {
    _password = null;
  }

  /// Clears the failure after the screen showed it.
  void clearFailure() {
    if (state.failure != null || state.codeRejected) {
      state = state.copyWith(clearFailure: true, codeRejected: false);
    }
  }
}

final signupControllerProvider =
    NotifierProvider<SignupController, SignupState>(SignupController.new);
