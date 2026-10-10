import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/links/url_opener.dart';
import 'package:afterme/core/pickers/country_names.dart';
import 'package:afterme/core/pickers/timezone_catalog.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../helpers/fake_platform.dart';

class _FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];
  bool result = true;
  bool throws = false;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    if (throws) {
      throw StateError('no browser');
    }
    launched.add('$url ${options.mode.name}');
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DeviceDescriptors', () {
    test('app version is semver plus the build number', () {
      expect(
        DeviceDescriptors.appVersion(
          const ClientInfo(version: '1.0.0', buildNumber: '12'),
        ),
        '1.0.0+12',
      );
      expect(
        DeviceDescriptors.appVersion(
          const ClientInfo(version: '1.0.0', buildNumber: ''),
        ),
        '1.0.0',
      );
    });

    test('values the API would reject are replaced', () {
      expect(DeviceDescriptors.sanitizeOsVersion('15'), '15');
      expect(DeviceDescriptors.sanitizeOsVersion('  14 (QPR1) '), '14 (QPR1)');
      expect(DeviceDescriptors.sanitizeOsVersion(''), 'unknown');
      expect(
        DeviceDescriptors.sanitizeOsVersion('Linux 6.1 #1 SMP'),
        'unknown',
      );
      expect(DeviceDescriptors.sanitizeLocale('en-IN'), 'en-IN');
      expect(DeviceDescriptors.sanitizeLocale('zh-Hans-CN'), 'zh-Hans-CN');
      expect(DeviceDescriptors.sanitizeLocale('en_US'), 'en');
      expect(DeviceDescriptors.sanitizeLocale(''), 'en');
    });

    test('describe combines the pieces and has a stable JSON shape', () async {
      final d = await DeviceDescriptors.describe(
        const ClientInfo(version: '1.0.0', buildNumber: '12'),
        FakeDeviceInfoSource(os: 'weird os!', locale: 'en-IN'),
      );
      expect(d.toJson(), {
        'platform': 'android',
        'app_version': '1.0.0+12',
        'os_version': 'unknown',
        'locale': 'en-IN',
      });
    });
  });

  group('PlatformDeviceInfoSource without a platform', () {
    test('falls back instead of crashing', () async {
      const source = PlatformDeviceInfoSource();
      expect(await source.osVersion(), '');
      expect(await source.timezone(), isNull);
      expect(await source.availableTimezones(), isEmpty);
      expect(source.localeTag(), isNotEmpty);
    });

    test('reads the timezone and the zone list from the plugin', () async {
      const channel = MethodChannel('flutter_timezone');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            return switch (call.method) {
              'getLocalTimezone' => 'Asia/Kolkata',
              'getAvailableTimezones' => ['Asia/Kolkata', 'Europe/London'],
              _ => null,
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const source = PlatformDeviceInfoSource();
      expect(await source.timezone(), 'Asia/Kolkata');
      expect(await source.availableTimezones(), [
        'Asia/Kolkata',
        'Europe/London',
      ]);
    });
  });

  group('PlatformUrlOpener', () {
    late _FakeLauncher launcher;

    setUp(() {
      launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
    });

    test('opens web links in the external browser only', () async {
      const opener = PlatformUrlOpener();
      expect(
        await opener.open(Uri.parse('https://afterme.invalid/legal/terms')),
        isTrue,
      );
      expect(
        launcher.launched.single,
        'https://afterme.invalid/legal/terms externalApplication',
      );
      expect(
        await opener.open(Uri.parse('http://10.0.2.2:8000/legal/terms')),
        isTrue,
      );
    });

    test('refuses other schemes and survives failures', () async {
      const opener = PlatformUrlOpener();
      expect(await opener.open(Uri.parse('intent://evil')), isFalse);
      expect(await opener.open(Uri.parse('tel:123')), isFalse);
      expect(launcher.launched, isEmpty);
      launcher.result = false;
      expect(await opener.open(Uri.parse('https://example.invalid')), isFalse);
      launcher.throws = true;
      expect(await opener.open(Uri.parse('https://example.invalid')), isFalse);
    });
  });

  group('PlatformContactPicker', () {
    const channel = MethodChannel('app.afterme/contact_picker');
    const picker = PlatformContactPicker();

    void answer(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }

    test('returns the chosen name and email', () async {
      answer((call) async {
        expect(call.method, 'pick');
        return {'name': ' Mom ', 'email': ' mom@example.com '};
      });
      final picked = await picker.pick();
      expect(picked?.name, 'Mom');
      expect(picked?.email, 'mom@example.com');
    });

    test('cancelled or without an email is null', () async {
      answer((call) async => null);
      expect(await picker.pick(), isNull);
      answer((call) async => {'name': 'No Email', 'email': ' '});
      expect(await picker.pick(), isNull);
    });

    test('a missing picker or a platform error is "unavailable"', () async {
      await expectLater(
        picker.pick(),
        throwsA(
          isA<ContactPickException>().having(
            (e) => e.error,
            'error',
            ContactPickError.unavailable,
          ),
        ),
      );
      answer((call) async => throw PlatformException(code: 'unavailable'));
      await expectLater(picker.pick(), throwsA(isA<ContactPickException>()));
    });
  });

  group('timezone and country lists', () {
    test('only canonical Area/City ids are offered, sorted, de-duplicated', () {
      final choices = TimezoneCatalog.choices([
        'Europe/London',
        'Asia/Kolkata',
        'Asia/Kolkata',
        'EST5EDT',
        'Etc/GMT+5',
        'US/Pacific',
        'UTC',
        'America/Argentina/Buenos_Aires',
      ]);
      expect(choices, [
        'America/Argentina/Buenos_Aires',
        'Asia/Kolkata',
        'Europe/London',
        'UTC',
      ]);
    });

    test('an empty platform list falls back to common zones; the current one is kept', () {
      final choices = TimezoneCatalog.choices(
        const [],
        include: 'Pacific/Fiji',
      );
      expect(choices, contains('Asia/Kolkata'));
      expect(choices, contains('Pacific/Fiji'));
      expect(
        TimezoneCatalog.choices(const [], include: 'Not/Valid!'),
        isNot(contains('Not/Valid!')),
      );
      expect(TimezoneCatalog.label('America/New_York'), 'America/New York');
    });

    test('country names cover the backend list and look up by code', () {
      expect(countryNames, hasLength(249));
      expect(countryName('IN'), 'India');
      expect(countryName('ZZ'), isNull);
      expect(countryName(null), isNull);
      expect({for (final (code, _) in countryNames) code}, hasLength(249));
    });
  });
}
