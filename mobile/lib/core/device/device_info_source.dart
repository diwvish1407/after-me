import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import '../api/client_info.dart';

/// What the API wants to know about this device (`device` in register/verify and login,
/// API_SPEC.md §2.2). No hardware identifiers: the device id is assigned by the server.
@immutable
class DeviceDescriptor {
  const DeviceDescriptor({
    required this.appVersion,
    required this.osVersion,
    required this.locale,
    this.platform = 'android',
  });

  final String platform;
  final String appVersion;
  final String osVersion;
  final String locale;

  Map<String, Object?> toJson() => <String, Object?>{
    'platform': platform,
    'app_version': appVersion,
    'os_version': osVersion,
    'locale': locale,
  };
}

/// Reads device facts. A seam so tests never touch platform channels.
abstract interface class DeviceInfoSource {
  /// The Android release, for example `15`.
  Future<String> osVersion();

  /// The BCP 47 tag of the device language, for example `en-IN`.
  String localeTag();

  /// The IANA timezone the device is set to, or null when it cannot be read.
  Future<String?> timezone();

  /// IANA timezone identifiers the platform knows, or an empty list.
  Future<List<String>> availableTimezones();
}

/// Platform implementation (device_info_plus, flutter_timezone).
class PlatformDeviceInfoSource implements DeviceInfoSource {
  const PlatformDeviceInfoSource();

  @override
  Future<String> osVersion() async {
    try {
      return (await DeviceInfoPlugin().androidInfo).version.release;
    } on Object {
      return '';
    }
  }

  @override
  String localeTag() => PlatformDispatcher.instance.locale.toLanguageTag();

  @override
  Future<String?> timezone() async {
    try {
      return (await FlutterTimezone.getLocalTimezone()).identifier;
    } on Object {
      return null;
    }
  }

  @override
  Future<List<String>> availableTimezones() async {
    try {
      return [
        for (final zone in await FlutterTimezone.getAvailableTimezones())
          zone.identifier,
      ];
    } on Object {
      return const [];
    }
  }
}

final deviceInfoSourceProvider = Provider<DeviceInfoSource>(
  (ref) => const PlatformDeviceInfoSource(),
);

/// Makes the strings the API accepts out of raw platform values.
abstract final class DeviceDescriptors {
  static final RegExp _osVersion = RegExp(r'^[A-Za-z0-9 ._()-]{1,32}$');
  static final RegExp _locale = RegExp(
    r'^[A-Za-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|\d{3}))?$',
  );

  /// `1.0.0+12` (or `1.0.0` without a build number).
  static String appVersion(ClientInfo info) => info.buildNumber.isEmpty
      ? info.version
      : '${info.version}+${info.buildNumber}';

  /// The OS version if it is acceptable to the API, else `unknown`.
  static String sanitizeOsVersion(String raw) =>
      _osVersion.hasMatch(raw.trim()) ? raw.trim() : 'unknown';

  /// The locale tag if it is well-formed, else `en`.
  static String sanitizeLocale(String raw) =>
      _locale.hasMatch(raw.trim()) ? raw.trim() : 'en';

  static Future<DeviceDescriptor> describe(
    ClientInfo info,
    DeviceInfoSource source,
  ) async => DeviceDescriptor(
    appVersion: appVersion(info),
    osVersion: sanitizeOsVersion(await source.osVersion()),
    locale: sanitizeLocale(source.localeTag()),
  );
}
