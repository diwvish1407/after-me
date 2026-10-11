import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// Whether this device can verify the person at all.
enum LockCapability {
  /// A biometric or a device PIN, pattern or password is set up.
  available,

  /// No screen lock and no biometrics: nothing to verify against.
  noScreenLock,
}

/// The result of one unlock attempt.
enum AuthOutcome {
  success,

  /// The person dismissed the prompt.
  canceled,

  /// The biometric or credential did not match.
  failed,

  /// Too many failed attempts; the system asks to wait.
  lockedOut,

  /// The device has no screen lock or enrolled biometrics (any more). Only this outcome,
  /// confirmed again by [LocalAuthGateway.capability], may lead to switching the lock off
  /// without a prompt.
  notAvailable,

  /// The prompt could not be shown right now (the screen was not in the foreground, the
  /// sensor is busy). It is retryable and never a reason to skip the check.
  unavailableNow,
}

/// The app's only contact with `local_auth`, so the lock logic is testable with a fake.
///
/// Android: BiometricPrompt through `local_auth` with `biometricOnly: false`: **any
/// biometric the phone itself accepts to unlock it, with the device credential (PIN,
/// pattern, password) as the fallback**. `local_auth_android` asks for
/// `BIOMETRIC_WEAK or BIOMETRIC_STRONG` (plus `DEVICE_CREDENTIAL`) and offers no option
/// to ask for class 3 only, so a class 2 face unlock opens the app as well. Narrowing it
/// would need a platform channel of our own and would lock out people whose phone offers
/// only weaker biometrics (a person must never be locked out of their check-in), so it
/// is not done; the lock is a convenience on top of the phone's own screen lock
/// (SECURITY.md §11 AUTH).
abstract interface class LocalAuthGateway {
  Future<LockCapability> capability();

  /// Shows the system prompt with [reason].
  Future<AuthOutcome> authenticate(String reason);
}

class PlatformLocalAuthGateway implements LocalAuthGateway {
  PlatformLocalAuthGateway([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<LockCapability> capability() async {
    try {
      return await _auth.isDeviceSupported()
          ? LockCapability.available
          : LockCapability.noScreenLock;
    } on Object {
      return LockCapability.noScreenLock;
    }
  }

  @override
  Future<AuthOutcome> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
      return ok ? AuthOutcome.success : AuthOutcome.failed;
    } on LocalAuthException catch (error) {
      return switch (error.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.timeout ||
        LocalAuthExceptionCode.authInProgress ||
        LocalAuthExceptionCode.userRequestedFallback => AuthOutcome.canceled,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout => AuthOutcome.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware => AuthOutcome.notAvailable,
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable ||
        LocalAuthExceptionCode.uiUnavailable => AuthOutcome.unavailableNow,
        LocalAuthExceptionCode.deviceError ||
        LocalAuthExceptionCode.unknownError => AuthOutcome.failed,
      };
    } on Object {
      return AuthOutcome.failed;
    }
  }
}

final localAuthGatewayProvider = Provider<LocalAuthGateway>(
  (ref) => PlatformLocalAuthGateway(),
);
