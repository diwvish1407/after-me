// Fails when the merged release manifest requests anything beyond the allowlist
// (SECURITY §11, PLAY_STORE §3): INTERNET, POST_NOTIFICATIONS (check-in reminders,
// Android 13+), USE_BIOMETRIC (app lock), plus the signature-level
// "<applicationId>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" that AndroidX Core adds
// for apps targeting SDK 33+. In particular there must be no AD_ID and no READ_CONTACTS
// (contacts come from the system picker).
//
// One conditional entry: androidx.biometric 1.1.0 (through local_auth) declares the legacy
// USE_FINGERPRINT, which Android 8.0-8.1 (API 26-27, our minSdk) still needs for the
// fingerprint prompt. The app's manifest limits it with maxSdkVersion="27", and the check
// accepts it only with that limit, so it is never requested on Android 9+.
//
// Usage (from mobile/), after `flutter build apk --flavor prod --release ...`:
//   dart run tool/check_manifest_permissions.dart [manifest.xml] [applicationId]
import 'dart:io';

const _internet = 'android.permission.INTERNET';
const _postNotifications = 'android.permission.POST_NOTIFICATIONS';
const _useBiometric = 'android.permission.USE_BIOMETRIC';

/// Permissions the app may request, besides the per-application dynamic receiver one.
const allowedPermissions = <String>{
  _internet,
  _postNotifications,
  _useBiometric,
};
const _dynamicReceiver = 'DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION';

const _legacyFingerprint = 'android.permission.USE_FINGERPRINT';

/// The newest Android API on which the legacy fingerprint permission may still apply.
const _legacyFingerprintMaxSdk = 27;

/// Permission names declared by the manifest (`uses-permission` and
/// `uses-permission-sdk-23`), in document order.
List<String> declaredPermissions(String manifestXml) => [
  for (final (name, _) in _declarations(manifestXml)) name,
];

/// (name, maxSdkVersion) of every declared permission.
List<(String, int?)> _declarations(String manifestXml) {
  final tag = RegExp(r'<uses-permission(?:-sdk-23)?\b([^>]*)>', dotAll: true);
  final name = RegExp(r'android:name\s*=\s*"([^"]*)"');
  final maxSdk = RegExp(r'android:maxSdkVersion\s*=\s*"(\d+)"');
  return [
    for (final match in tag.allMatches(manifestXml))
      if (name.firstMatch(match.group(1)!)?.group(1) case final permission?)
        (
          permission,
          int.tryParse(maxSdk.firstMatch(match.group(1)!)?.group(1) ?? ''),
        ),
  ];
}

/// Declared permissions that are not on the allowlist for [applicationId].
List<String> unexpectedPermissions(String manifestXml, String applicationId) {
  final allowed = <String>{
    ...allowedPermissions,
    '$applicationId.$_dynamicReceiver',
  };
  return [
    for (final (permission, maxSdk) in _declarations(manifestXml))
      if (!allowed.contains(permission) &&
          !(permission == _legacyFingerprint &&
              maxSdk != null &&
              maxSdk <= _legacyFingerprintMaxSdk))
        permission,
  ];
}

/// Whether the manifest requests INTERNET (the app cannot work without it).
bool requestsInternet(String manifestXml) =>
    declaredPermissions(manifestXml).contains(_internet);

File? _findMergedManifest() {
  final root = Directory(
    'build/app/intermediates/merged_manifests/prodRelease',
  );
  if (!root.existsSync()) {
    return null;
  }
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('AndroidManifest.xml')) {
      return entity;
    }
  }
  return null;
}

void main(List<String> args) {
  final file = args.isNotEmpty ? File(args[0]) : _findMergedManifest();
  final applicationId = args.length > 1 ? args[1] : 'app.afterme';
  if (file == null || !file.existsSync()) {
    stderr.writeln(
      'Merged prodRelease manifest not found. Run '
      '`flutter build apk --flavor prod --release '
      '--dart-define-from-file=config/prod.json` first.',
    );
    exit(2);
  }
  final xml = file.readAsStringSync();
  final unexpected = unexpectedPermissions(xml, applicationId);
  if (unexpected.isNotEmpty) {
    stderr.writeln('Unexpected permissions in ${file.path}:');
    for (final permission in unexpected) {
      stderr.writeln('  $permission');
    }
    exit(1);
  }
  if (!requestsInternet(xml)) {
    stderr.writeln('${file.path} does not request INTERNET.');
    exit(1);
  }
  stdout.writeln(
    'OK: ${file.path} requests only ${declaredPermissions(xml).join(', ')}',
  );
}
