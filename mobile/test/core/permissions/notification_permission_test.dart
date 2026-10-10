import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/security/app_lock/app_lock_controller.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../helpers/fake_platform.dart';
import '../../helpers/test_app.dart';

ProviderContainer _container(TestFakes fakes) {
  final container = ProviderContainer.test(
    overrides: testOverrides(fakes: fakes),
  );
  container.listen(notificationPermissionControllerProvider, (_, _) {});
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotificationPermissionController', () {
    test('refresh reads the status', () async {
      final fakes = TestFakes(
        notifications: FakeNotificationPermissionGateway(
          current: NotificationPermission.granted,
        ),
      );
      final container = _container(fakes);
      expect(
        container.read(notificationPermissionControllerProvider).status,
        NotificationPermission.unknown,
      );
      await container
          .read(notificationPermissionControllerProvider.notifier)
          .refresh();
      expect(
        container.read(notificationPermissionControllerProvider).status,
        NotificationPermission.granted,
      );
    });

    test(
      'request shows the dialog once, stores the result and reports it',
      () async {
        final fakes = TestFakes();
        final container = _container(fakes);
        final status = await container
            .read(notificationPermissionControllerProvider.notifier)
            .request();
        expect(status, NotificationPermission.granted);
        expect(fakes.notifications.requests, 1);
        expect(
          await fakes.prefs.getString(
            PreferenceKey.notificationPermissionResult,
          ),
          'granted',
        );
        expect(
          container.read(notificationPermissionControllerProvider).busy,
          isFalse,
        );
      },
    );

    test('denied and permanently denied are stored and reported', () async {
      for (final result in [
        NotificationPermission.denied,
        NotificationPermission.permanentlyDenied,
      ]) {
        final fakes = TestFakes(
          notifications: FakeNotificationPermissionGateway(
            afterRequest: result,
          ),
        );
        final container = _container(fakes);
        expect(
          await container
              .read(notificationPermissionControllerProvider.notifier)
              .request(),
          result,
        );
        expect(
          container.read(notificationPermissionControllerProvider).status,
          result,
        );
        expect(
          await fakes.prefs.getString(
            PreferenceKey.notificationPermissionResult,
          ),
          result.name,
        );
      }
    });

    test('the system dialog does not lock the app', () async {
      final fakes = TestFakes();
      fakes.prefs = freshPreferences({
        'afterme.appLockEnabled': true,
        'afterme.appLockTimeoutMinutes': 0,
      });
      final container = ProviderContainer.test(
        overrides: testOverrides(fakes: fakes),
      );
      container.listen(appLockControllerProvider, (_, _) {});
      container.listen(notificationPermissionControllerProvider, (_, _) {});
      final lock = container.read(appLockControllerProvider.notifier);
      await lock.loaded;
      await lock.unlock('r');
      fakes.notifications.afterRequest = NotificationPermission.granted;
      final gate = fakes.notifications;
      // Simulate the activity pausing while the dialog is up.
      final request = container
          .read(notificationPermissionControllerProvider.notifier)
          .request();
      lock.didChangeLifecycle(AppLifecycleState.paused);
      lock.didChangeLifecycle(AppLifecycleState.resumed);
      await request;
      expect(gate.requests, 1);
      expect(container.read(appLockControllerProvider).locked, isFalse);
    });

    test('a failing gateway reads as denied, never a crash', () async {
      final container = ProviderContainer.test(
        overrides: testOverrides(
          fakes: TestFakes(notifications: _ThrowingGateway()),
        ),
      );
      container.listen(notificationPermissionControllerProvider, (_, _) {});
      final controller = container.read(
        notificationPermissionControllerProvider.notifier,
      );
      await controller.refresh();
      expect(
        container.read(notificationPermissionControllerProvider).status,
        NotificationPermission.denied,
      );
      expect(await controller.request(), NotificationPermission.denied);
    });

    test('openSystemSettings opens the app settings page', () async {
      final fakes = TestFakes();
      final container = _container(fakes);
      await container
          .read(notificationPermissionControllerProvider.notifier)
          .openSystemSettings();
      expect(fakes.notifications.settingsOpened, 1);
    });
  });

  group('PlatformNotificationPermissionGateway', () {
    const channel = MethodChannel('flutter.baseflow.com/permissions/methods');
    const gateway = PlatformNotificationPermissionGateway();

    // PermissionStatus values on the wire: 0 denied, 1 granted, 2 restricted,
    // 3 limited, 4 permanentlyDenied, 5 provisional.
    void answer(int status) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'checkPermissionStatus':
                return status;
              case 'requestPermissions':
                return <int, int>{
                  for (final p in (call.arguments as List<Object?>).cast<int>())
                    p: status,
                };
              case 'openAppSettings':
                return true;
            }
            return null;
          });
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('maps every plugin status', () async {
      const expected = {
        0: NotificationPermission.denied,
        1: NotificationPermission.granted,
        2: NotificationPermission.permanentlyDenied,
        3: NotificationPermission.granted,
        4: NotificationPermission.permanentlyDenied,
        5: NotificationPermission.granted,
      };
      for (final MapEntry(:key, :value) in expected.entries) {
        answer(key);
        expect(await gateway.status(), value, reason: 'status $key');
        expect(await gateway.request(), value, reason: 'request $key');
      }
    });

    test('opens the app settings', () async {
      answer(0);
      expect(await gateway.openSettings(), isTrue);
    });

    test('the permission enum has the statuses the mapping covers', () {
      expect(PermissionStatus.values, hasLength(6));
    });
  });
}

class _ThrowingGateway extends FakeNotificationPermissionGateway {
  @override
  Future<bool> openSettings() async => throw StateError('x');

  @override
  Future<NotificationPermission> request() async => throw StateError('x');

  @override
  Future<NotificationPermission> status() async => throw StateError('x');
}
