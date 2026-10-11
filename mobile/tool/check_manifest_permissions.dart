// Fails when the merged release manifest requests anything beyond the allowlist
// (SECURITY §11, PLAY_STORE §3): INTERNET, POST_NOTIFICATIONS (check-in reminders,
// Android 13+), USE_BIOMETRIC (app lock), the three that Firebase Cloud Messaging adds
// (WAKE_LOCK, ACCESS_NETWORK_STATE, c2dm RECEIVE: see below, each with its reason), plus
// the signature-level "<applicationId>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" that
// AndroidX Core adds for apps targeting SDK 33+. In particular there must be no AD_ID, no
// READ_CONTACTS (contacts come from the system picker), no RECEIVE_BOOT_COMPLETED (nothing
// is scheduled on the phone: reminders come from the server), no VIBRATE (a channel vibrates
// on the app's behalf; the manifest removes the plugin's declaration), no exact-alarm and no
// foreground-service permission.
//
// One conditional entry: androidx.biometric 1.1.0 (through local_auth) declares the legacy
// USE_FINGERPRINT, which Android 8.0-8.1 (API 26-27, our minSdk) still needs for the
// fingerprint prompt. The app's manifest limits it with maxSdkVersion="27", and the check
// accepts it only with that limit, so it is never requested on Android 9+.
//
// The same manifest is also checked for the properties SECURITY §11 relies on
// (Phase 9 review M-02, M-04):
//   * `android:allowBackup="false"`, and no `usesCleartextTraffic="true"` and no
//     `debuggable="true"` on the application;
//   * the launcher activity (which any app can start with an explicit intent) carries
//     `flutter_deeplinking_enabled=false`, so an intent's data never becomes a route;
//   * the exported components are exactly the launcher activity, the two Firebase
//     Cloud Messaging receivers (each guarded by the c2dm SEND permission) and AndroidX's
//     profile installer receiver (guarded by DUMP): a new exported component, from the
//     app or from a library an update pulled in, is a finding until it is reviewed and
//     added here and to SECURITY §11.
//
// Usage (from mobile/), after `flutter build apk --flavor prod --release ...`:
//   dart run tool/check_manifest_permissions.dart [manifest.xml] [applicationId]
import 'dart:io';

const _internet = 'android.permission.INTERNET';
const _postNotifications = 'android.permission.POST_NOTIFICATIONS';
const _useBiometric = 'android.permission.USE_BIOMETRIC';

// What the push stack adds (Phase 8: firebase_core, firebase_messaging, and the
// flutter_local_notifications plugin for the foreground copy of a push). Reviewed on the
// merged manifests of the dev debug and prod release builds; every entry here is there
// because the library declares it and FCM works with it, none because the app asks for it.

/// FCM holds a short wake lock while it hands a message to the app (the receiver and the
/// background service of firebase_messaging). Normal permission, no prompt.
const _wakeLock = 'android.permission.WAKE_LOCK';

/// Declared by the firebase_messaging plugin: the Firebase SDKs read whether there is a
/// network to decide when to sync. Normal permission, no prompt, nothing of the person.
const _accessNetworkState = 'android.permission.ACCESS_NETWORK_STATE';

/// Declared by the Firebase Messaging SDK: "required by older versions of Google Play
/// services to create IID tokens". Normal permission, no prompt.
const _c2dmReceive = 'com.google.android.c2dm.permission.RECEIVE';

/// Permissions the app may request, besides the per-application dynamic receiver one.
const allowedPermissions = <String>{
  _internet,
  _postNotifications,
  _useBiometric,
  _wakeLock,
  _accessNetworkState,
  _c2dmReceive,
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

/// One element of a manifest: its tag, attributes (with their `android:` prefix) and
/// children.
class ManifestElement {
  ManifestElement(this.tag, this.attributes);

  final String tag;
  final Map<String, String> attributes;
  final List<ManifestElement> children = [];

  /// The value of `android:<name>`, or null.
  String? android(String name) => attributes['android:$name'];

  Iterable<ManifestElement> childrenNamed(String name) =>
      children.where((child) => child.tag == name);
}

/// Reads the element structure of an Android manifest (comments and the XML declaration
/// are ignored). A small scanner is enough for the machine-written merged manifest and
/// keeps this tool free of dependencies; anything it cannot make sense of surfaces as a
/// missing `application` element, which [hardeningIssues] reports instead of passing.
ManifestElement parseManifest(String manifestXml) {
  final cleaned = manifestXml
      .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
      .replaceAll(RegExp(r'<\?.*?\?>', dotAll: true), '');
  const quoted = r'''(?:"[^"]*"|'[^']*')''';
  final tag = RegExp(
    r'<(/?)([A-Za-z_][\w.:-]*)((?:\s+[^\s=<>/]+\s*=\s*' +
        quoted +
        r')*)\s*(/?)>',
  );
  final attribute = RegExp(r'''([^\s=]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
  final root = ManifestElement('#document', {});
  final stack = [root];
  for (final match in tag.allMatches(cleaned)) {
    if (match.group(1) == '/') {
      if (stack.length > 1) {
        stack.removeLast();
      }
      continue;
    }
    final attributes = <String, String>{
      for (final a in attribute.allMatches(match.group(3)!))
        a.group(1)!: a.group(2) ?? a.group(3) ?? '',
    };
    final element = ManifestElement(match.group(2)!, attributes);
    stack.last.children.add(element);
    if (match.group(4) != '/') {
      stack.add(element);
    }
  }
  return root;
}

ManifestElement? _first(ManifestElement parent, String tag) =>
    parent.childrenNamed(tag).firstOrNull;

ManifestElement? _application(String manifestXml) {
  final manifest = _first(parseManifest(manifestXml), 'manifest');
  return manifest == null ? null : _first(manifest, 'application');
}

const _componentTags = {
  'activity',
  'activity-alias',
  'service',
  'receiver',
  'provider',
};

/// What every exported component of the app is, and what guards it (null: nothing but
/// being the launcher). SECURITY §11 PLATFORM: the launcher activity, the two FCM
/// receivers and AndroidX's profile installer.
const exportedComponents = <String, String?>{
  'activity app.afterme.MainActivity': null,
  'receiver io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver':
      'com.google.android.c2dm.permission.SEND',
  'receiver com.google.firebase.iid.FirebaseInstanceIdReceiver':
      'com.google.android.c2dm.permission.SEND',
  'receiver androidx.profileinstaller.ProfileInstallReceiver':
      'android.permission.DUMP',
};

/// The launcher activity, by its name in the merged manifest.
const launcherActivity = 'app.afterme.MainActivity';

/// Whether a component answers to other apps: `exported="true"`, anything that is not a
/// plain `false`, or no `exported` at all with an intent filter (the implicit export of
/// targets below Android 12, which the build refuses today but a check should not rely on).
bool _isExported(ManifestElement component) {
  final exported = component.android('exported');
  if (exported == 'false') {
    return false;
  }
  return exported != null ||
      component.childrenNamed('intent-filter').isNotEmpty;
}

String _componentName(ManifestElement component, String package) {
  final name = component.android('name') ?? '';
  return name.startsWith('.') ? '$package$name' : name;
}

/// The exported components of the manifest, as `<tag> <class name>`, with the permission
/// that guards each (null when none).
Map<String, String?> exportedComponentsOf(String manifestXml) {
  final manifest = _first(parseManifest(manifestXml), 'manifest');
  final application = manifest == null ? null : _first(manifest, 'application');
  if (manifest == null || application == null) {
    return {};
  }
  final package = manifest.attributes['package'] ?? '';
  return {
    for (final component in application.children)
      if (_componentTags.contains(component.tag) && _isExported(component))
        '${component.tag} ${_componentName(component, package)}': component
            .android('permission'),
  };
}

/// Everything about exported components, application flags and the launcher activity's
/// deep-link switch that the documentation says is not the case. Empty when the manifest
/// is as documented.
List<String> hardeningIssues(String manifestXml) {
  final issues = <String>[];
  final manifest = _first(parseManifest(manifestXml), 'manifest');
  final application = _application(manifestXml);
  if (manifest == null || application == null) {
    return ['no <manifest>/<application> element was found'];
  }
  final package = manifest.attributes['package'] ?? '';

  if (application.android('allowBackup') != 'false') {
    issues.add(
      'android:allowBackup must be "false" (is '
      '${application.android('allowBackup') ?? 'not set'})',
    );
  }
  if (application.android('usesCleartextTraffic') == 'true') {
    issues.add('android:usesCleartextTraffic must not be "true"');
  }
  if (application.android('debuggable') == 'true') {
    issues.add('android:debuggable must not be "true"');
  }

  final exported = exportedComponentsOf(manifestXml);
  for (final entry in exported.entries) {
    if (!exportedComponents.containsKey(entry.key)) {
      issues.add('unexpected exported component: ${entry.key}');
    } else if (exportedComponents[entry.key] != entry.value) {
      issues.add(
        '${entry.key} must be guarded by ${exportedComponents[entry.key]} '
        '(is ${entry.value ?? 'unguarded'})',
      );
    }
  }
  for (final expected in exportedComponents.keys) {
    if (!exported.containsKey(expected)) {
      issues.add('documented exported component is missing: $expected');
    }
  }

  ManifestElement? launcher;
  for (final activity in application.childrenNamed('activity')) {
    if (_componentName(activity, package) == launcherActivity) {
      launcher = activity;
    }
  }
  if (launcher == null) {
    issues.add('the launcher activity $launcherActivity was not found');
  } else {
    final deepLinks = launcher
        .childrenNamed('meta-data')
        .where((m) => m.android('name') == 'flutter_deeplinking_enabled')
        .map((m) => m.android('value'))
        .toList();
    if (deepLinks.length != 1 || deepLinks.single != 'false') {
      issues.add(
        'the launcher activity must set flutter_deeplinking_enabled to "false" '
        '(is ${deepLinks.isEmpty ? 'not set' : deepLinks.join(', ')})',
      );
    }
    // Nothing but MAIN/LAUNCHER may reach it by intent filter.
    for (final filter in launcher.childrenNamed('intent-filter')) {
      final actions = [
        for (final a in filter.childrenNamed('action')) a.android('name'),
      ];
      final hasData = filter.childrenNamed('data').isNotEmpty;
      if (hasData || actions.any((a) => a != 'android.intent.action.MAIN')) {
        issues.add(
          'the launcher activity has an intent filter other than '
          'MAIN/LAUNCHER (actions: ${actions.join(', ')})',
        );
      }
    }
  }
  return issues;
}

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
  final issues = hardeningIssues(xml);
  if (issues.isNotEmpty) {
    stderr.writeln('Manifest hardening check failed for ${file.path}:');
    for (final issue in issues) {
      stderr.writeln('  $issue');
    }
    exit(1);
  }
  stdout.writeln(
    'OK: ${file.path} requests only ${declaredPermissions(xml).join(', ')}; '
    'backup off, no cleartext flag, not debuggable, deep links off, exported '
    'components: ${exportedComponents.keys.join(', ')}',
  );
}
