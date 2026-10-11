import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/links/url_opener.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/push/firebase_push_gateway.dart';
import 'package:afterme/core/push/local_notification_gateway.dart';
import 'package:afterme/core/push/plugin_local_notification_gateway.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:afterme/core/time/clock.dart';
import 'package:afterme/features/plan/data/plan_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('without overrides every platform seam is the real implementation', () {
    final container = ProviderContainer.test();
    expect(container.read(urlOpenerProvider), isA<PlatformUrlOpener>());
    expect(container.read(screenPrivacyProvider), isA<PlatformScreenPrivacy>());
    expect(container.read(contactPickerProvider), isA<PlatformContactPicker>());
    expect(
      container.read(deviceInfoSourceProvider),
      isA<PlatformDeviceInfoSource>(),
    );
    expect(
      container.read(localAuthGatewayProvider),
      isA<PlatformLocalAuthGateway>(),
    );
    expect(
      container.read(notificationPermissionGatewayProvider),
      isA<PlatformNotificationPermissionGateway>(),
    );
    final before = DateTime.now();
    expect(
      container.read(clockProvider)().difference(before).inSeconds.abs(),
      lessThan(2),
    );
  });

  test('push: Firebase and the local notifications are the real adapters, '
      'configured from the build', () {
    final configured = ProviderContainer.test(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.parse(
            appEnv: 'dev',
            apiBaseUrl: 'http://10.0.2.2:8000',
            firebaseApiKey: 'k',
            firebaseAppId: 'a',
            firebaseMessagingSenderId: 's',
            firebaseProjectId: 'p',
          ),
        ),
      ],
    );
    expect(configured.read(pushGatewayProvider), isA<FirebasePushGateway>());
    expect(configured.read(pushGatewayProvider).isConfigured, isTrue);
    expect(
      configured.read(localNotificationGatewayProvider),
      isA<PluginLocalNotificationGateway>(),
    );

    final plain = ProviderContainer.test(
      overrides: [
        appConfigProvider.overrideWithValue(
          AppConfig.parse(appEnv: 'dev', apiBaseUrl: 'http://10.0.2.2:8000'),
        ),
      ],
    );
    expect(plain.read(pushGatewayProvider).isConfigured, isFalse);
  });

  test('plan drafts compare by value', () {
    const a = PlanStageDraft(offsetMinutes: 60, contactIds: ['x']);
    expect(a, const PlanStageDraft(offsetMinutes: 60, contactIds: ['x']));
    expect(
      a,
      isNot(const PlanStageDraft(offsetMinutes: 61, contactIds: ['x'])),
    );
    expect(
      a,
      isNot(
        const PlanStageDraft(id: 's', offsetMinutes: 60, contactIds: ['x']),
      ),
    );
    expect(
      a.hashCode,
      const PlanStageDraft(offsetMinutes: 60, contactIds: ['x']).hashCode,
    );
    const draft = PlanDraft(graceMinutes: 60, stages: [a]);
    expect(draft, const PlanDraft(graceMinutes: 60, stages: [a]));
    expect(
      draft.hashCode,
      const PlanDraft(graceMinutes: 60, stages: [a]).hashCode,
    );
    expect(draft, isNot(const PlanDraft(graceMinutes: 60, stages: [])));
    expect(draft, isNot(const PlanDraft(graceMinutes: 120, stages: [a])));
  });
}
