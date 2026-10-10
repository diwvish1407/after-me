import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

class _MockLocalAuth extends Mock implements LocalAuthentication {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformLocalAuthGateway', () {
    late _MockLocalAuth auth;
    late PlatformLocalAuthGateway gateway;

    setUp(() {
      auth = _MockLocalAuth();
      gateway = PlatformLocalAuthGateway(auth);
    });

    void whenAuthenticate(Future<bool> Function() answer) {
      when(
        () => auth.authenticate(
          localizedReason: any(named: 'localizedReason'),
          biometricOnly: any(named: 'biometricOnly'),
        ),
      ).thenAnswer((_) => answer());
    }

    test(
      'capability follows isDeviceSupported (strong biometric or credential)',
      () async {
        when(() => auth.isDeviceSupported()).thenAnswer((_) async => true);
        expect(await gateway.capability(), LockCapability.available);
        when(() => auth.isDeviceSupported()).thenAnswer((_) async => false);
        expect(await gateway.capability(), LockCapability.noScreenLock);
        when(() => auth.isDeviceSupported()).thenThrow(StateError('x'));
        expect(await gateway.capability(), LockCapability.noScreenLock);
      },
    );

    test('authenticates with the device credential fallback allowed', () async {
      whenAuthenticate(() async => true);
      expect(await gateway.authenticate('why'), AuthOutcome.success);
      verify(
        () => auth.authenticate(localizedReason: 'why', biometricOnly: false),
      ).called(1);
    });

    test('false is a failed attempt', () async {
      whenAuthenticate(() async => false);
      expect(await gateway.authenticate('why'), AuthOutcome.failed);
    });

    test('every exception code maps to an outcome', () async {
      const expected = <LocalAuthExceptionCode, AuthOutcome>{
        LocalAuthExceptionCode.userCanceled: AuthOutcome.canceled,
        LocalAuthExceptionCode.systemCanceled: AuthOutcome.canceled,
        LocalAuthExceptionCode.timeout: AuthOutcome.canceled,
        LocalAuthExceptionCode.authInProgress: AuthOutcome.canceled,
        LocalAuthExceptionCode.userRequestedFallback: AuthOutcome.canceled,
        LocalAuthExceptionCode.temporaryLockout: AuthOutcome.lockedOut,
        LocalAuthExceptionCode.biometricLockout: AuthOutcome.lockedOut,
        LocalAuthExceptionCode.noCredentialsSet: AuthOutcome.notAvailable,
        LocalAuthExceptionCode.noBiometricsEnrolled: AuthOutcome.notAvailable,
        LocalAuthExceptionCode.noBiometricHardware: AuthOutcome.notAvailable,
        // Transient: retryable, never a reason to skip the check.
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable:
            AuthOutcome.unavailableNow,
        LocalAuthExceptionCode.uiUnavailable: AuthOutcome.unavailableNow,
        LocalAuthExceptionCode.deviceError: AuthOutcome.failed,
        LocalAuthExceptionCode.unknownError: AuthOutcome.failed,
      };
      expect(expected.keys.toSet(), LocalAuthExceptionCode.values.toSet());
      for (final MapEntry(:key, :value) in expected.entries) {
        whenAuthenticate(() async => throw LocalAuthException(code: key));
        expect(await gateway.authenticate('why'), value, reason: '$key');
      }
    });

    test('unexpected errors are a failed attempt, never a crash', () async {
      whenAuthenticate(() async => throw StateError('boom'));
      expect(await gateway.authenticate('why'), AuthOutcome.failed);
    });
  });

  group('PlatformScreenPrivacy', () {
    const channel = MethodChannel('app.afterme/privacy');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('sends the flag to the activity', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      await const PlatformScreenPrivacy().setObscureInRecents(enabled: true);
      expect(calls.single.method, 'setObscureInRecents');
      expect(calls.single.arguments, {'enabled': true});
    });

    test('no platform implementation or a platform error is ignored', () async {
      await const PlatformScreenPrivacy().setObscureInRecents(enabled: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'nope');
          });
      await const PlatformScreenPrivacy().setObscureInRecents(enabled: false);
    });
  });
}
