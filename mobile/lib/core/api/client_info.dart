import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Identifies this build to the API (`X-AfterMe-Client`, API_SPEC.md §1).
@immutable
class ClientInfo {
  const ClientInfo({
    required this.version,
    required this.buildNumber,
    this.platform = 'android',
  });

  /// Reads the version from the installed package.
  ///
  /// Flavors append a suffix to `versionName` (`0.1.0-dev`). The API expects plain
  /// semver (`android/1.0.0+12`), so only the `major.minor.patch` core is sent.
  factory ClientInfo.fromPackageInfo(PackageInfo info) => ClientInfo(
    version: semverCore(info.version),
    buildNumber: info.buildNumber,
  );

  final String platform;
  final String version;
  final String buildNumber;

  /// `android/<version>+<build>`, or `android/<version>` when there is no build number.
  String get headerValue => buildNumber.isEmpty
      ? '$platform/$version'
      : '$platform/$version+$buildNumber';

  /// Extracts `major.minor.patch` from a version name such as `1.2.3-dev`.
  /// Falls back to `0.0.0` when the name is not semver.
  static String semverCore(String versionName) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)')
        .firstMatch(versionName.trim());
    return match == null ? '0.0.0' : match.group(0)!;
  }

  @override
  bool operator ==(Object other) =>
      other is ClientInfo &&
      other.platform == platform &&
      other.version == version &&
      other.buildNumber == buildNumber;

  @override
  int get hashCode => Object.hash(platform, version, buildNumber);
}

/// Overridden in `main()` with [ClientInfo.fromPackageInfo]; tests inject a fixed value.
final clientInfoProvider = Provider<ClientInfo>(
  (ref) => throw UnimplementedError(
    'clientInfoProvider must be overridden with ClientInfo.fromPackageInfo().',
  ),
);
