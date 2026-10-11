import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_manifest_permissions.dart';

/// The shape of the merged prod release manifest (Phase 9 review of the real APK):
/// the launcher activity, the two FCM receivers and AndroidX's profile installer exported,
/// everything else not.
String _merged({
  String application =
      'android:allowBackup="false" android:fullBackupContent="false"',
  String launcherMeta =
      '<meta-data android:name="flutter_deeplinking_enabled" '
      'android:value="false" />',
  String launcherFilter =
      '<intent-filter><action android:name="android.intent.action.MAIN"/>'
      '<category android:name="android.intent.category.LAUNCHER"/>'
      '</intent-filter>',
  String extra = '',
  bool profileInstaller = true,
  String profilePermission = 'android.permission.DUMP',
  String fcmPermission = 'com.google.android.c2dm.permission.SEND',
}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="app.afterme">
    <uses-permission android:name="android.permission.INTERNET" />
    <!-- a comment with <activity android:name="x" android:exported="true"> in it -->
    <application $application android:name="android.app.Application">
        <activity android:name="app.afterme.MainActivity" android:exported="true"
            android:taskAffinity="">
            <meta-data android:name="io.flutter.embedding.android.NormalTheme"
                android:resource="@style/NormalTheme" />
            $launcherMeta
            $launcherFilter
        </activity>
        <meta-data android:name="flutterEmbedding" android:value="2" />
        <service android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingService"
            android:exported="false">
            <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT"/></intent-filter>
        </service>
        <receiver android:name="io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver"
            android:permission="$fcmPermission" android:exported="true">
            <intent-filter><action android:name="com.google.android.c2dm.intent.RECEIVE"/></intent-filter>
        </receiver>
        <provider android:name="androidx.startup.InitializationProvider"
            android:exported="false" android:authorities="app.afterme.androidx-startup">
            <meta-data android:name="androidx.lifecycle.ProcessLifecycleInitializer"
                android:value="androidx.startup" />
        </provider>
        <activity android:name="io.flutter.plugins.urllauncher.WebViewActivity"
            android:exported="false" />
        <receiver android:name="com.google.firebase.iid.FirebaseInstanceIdReceiver"
            android:permission="$fcmPermission" android:exported="true">
            <intent-filter><action android:name="com.google.android.c2dm.intent.RECEIVE"/></intent-filter>
        </receiver>
        ${profileInstaller ? '''
        <receiver android:name="androidx.profileinstaller.ProfileInstallReceiver"
            android:permission="$profilePermission" android:enabled="true"
            android:exported="true" android:directBootAware="false">
            <intent-filter><action android:name="androidx.profileinstaller.action.INSTALL_PROFILE"/></intent-filter>
            <intent-filter><action android:name="androidx.profileinstaller.action.SAVE_PROFILE"/></intent-filter>
        </receiver>''' : ''}
        $extra
    </application>
</manifest>''';

void main() {
  group('hardeningIssues', () {
    test('the documented manifest has none', () {
      expect(hardeningIssues(_merged()), isEmpty);
    });

    test('lists exactly the documented exported components', () {
      expect(exportedComponentsOf(_merged()), {
        'activity app.afterme.MainActivity': null,
        'receiver io.flutter.plugins.firebase.messaging.FlutterFirebaseMessagingReceiver':
            'com.google.android.c2dm.permission.SEND',
        'receiver com.google.firebase.iid.FirebaseInstanceIdReceiver':
            'com.google.android.c2dm.permission.SEND',
        'receiver androidx.profileinstaller.ProfileInstallReceiver':
            'android.permission.DUMP',
      });
      expect(exportedComponentsOf(_merged()), exportedComponents);
    });

    test('allowBackup must be false', () {
      for (final application in [
        'android:allowBackup="true"',
        'android:label="x"',
      ]) {
        expect(hardeningIssues(_merged(application: application)), [
          contains('allowBackup'),
        ], reason: application);
      }
    });

    test('cleartext and debuggable flags are refused', () {
      expect(
        hardeningIssues(
          _merged(
            application: 'android:allowBackup="false" android:usesCleartextTraffic="true"',
          ),
        ),
        [contains('usesCleartextTraffic')],
      );
      expect(
        hardeningIssues(
          _merged(
            application:
                'android:allowBackup="false" android:debuggable="true"',
          ),
        ),
        [contains('debuggable')],
      );
      // Explicitly off is fine.
      expect(
        hardeningIssues(
          _merged(
            application:
                'android:allowBackup="false" android:debuggable="false" '
                'android:usesCleartextTraffic="false"',
          ),
        ),
        isEmpty,
      );
    });

    test('the launcher activity must switch deep links off', () {
      expect(hardeningIssues(_merged(launcherMeta: '')), [
        contains('flutter_deeplinking_enabled'),
      ]);
      expect(
        hardeningIssues(
          _merged(
            launcherMeta:
                '<meta-data android:name="flutter_deeplinking_enabled" '
                'android:value="true" />',
          ),
        ),
        [contains('flutter_deeplinking_enabled')],
      );
    });

    test('a deep-link intent filter on the launcher is refused', () {
      final issues = hardeningIssues(
        _merged(
          launcherFilter:
              '<intent-filter><action android:name="android.intent.action.VIEW"/>'
              '<data android:scheme="https" android:host="afterme.invalid"/>'
              '</intent-filter>',
        ),
      );
      expect(issues, [contains('intent filter other than')]);
    });

    test('a new exported component is a finding, whoever added it', () {
      for (final extra in [
        '<service android:name="x.Svc" android:exported="true" />',
        '<provider android:name="x.Prov" android:authorities="a" '
            'android:exported="true" />',
        '<activity-alias android:name="x.Alias" android:exported="true" '
            'android:targetActivity="app.afterme.MainActivity" />',
        '<activity android:name="x.Other" android:exported="true" />',
        '<receiver android:name="x.Rcv" android:exported="true" />',
        // Implicitly exported by its intent filter, with no attribute at all.
        '<receiver android:name="x.Implicit"><intent-filter>'
            '<action android:name="x.ACTION"/></intent-filter></receiver>',
        // A reference the scanner cannot resolve counts as exported.
        '<service android:name="x.Ref" android:exported="@bool/exp" />',
      ]) {
        expect(hardeningIssues(_merged(extra: extra)), [
          contains('unexpected exported component'),
        ], reason: extra);
      }
    });

    test('a component that is not exported is fine', () {
      expect(
        hardeningIssues(
          _merged(
            extra:
                '<service android:name="x.Svc" android:exported="false">'
                '<intent-filter><action android:name="x"/></intent-filter>'
                '</service>',
          ),
        ),
        isEmpty,
      );
    });

    test('a documented receiver must stay guarded by its permission', () {
      expect(
        hardeningIssues(_merged(fcmPermission: 'android.permission.INTERNET')),
        hasLength(2),
      );
      expect(
        hardeningIssues(_merged(profilePermission: 'android.permission.DUMP2')),
        [contains('ProfileInstallReceiver')],
      );
    });

    test('a documented component that disappeared is reported too', () {
      expect(hardeningIssues(_merged(profileInstaller: false)), [
        contains('documented exported component is missing'),
      ]);
    });

    test('relative class names resolve against the package', () {
      final xml = _merged().replaceAll(
        'app.afterme.MainActivity',
        '.MainActivity',
      );
      expect(hardeningIssues(xml), isEmpty);
    });

    test('a manifest it cannot read is never a pass', () {
      expect(hardeningIssues(''), [contains('no <manifest>')]);
      expect(hardeningIssues('<manifest package="app.afterme"/>'), [
        contains('no <manifest>'),
      ]);
    });

    test('single-quoted attributes are read like double-quoted ones', () {
      final xml = _merged().replaceAll('"', "'");
      expect(hardeningIssues(xml), isEmpty);
      expect(
        hardeningIssues(
          _merged(
            extra: '<service android:name="x.S" android:exported="true"/>',
          ).replaceAll('"', "'"),
        ),
        [contains('unexpected exported component')],
      );
    });
  });

  group('the app\'s own manifest source', () {
    final source = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    test(
      'turns deep links off on the launcher and keeps one intent filter',
      () {
        final application = parseManifest(source).children
            .firstWhere((e) => e.tag == 'manifest');
        final activity = application.children
            .firstWhere((e) => e.tag == 'application')
            .children
            .firstWhere((e) => e.tag == 'activity');
        expect(activity.android('name'), '.MainActivity');
        expect(activity.android('exported'), 'true');
        final deepLinks = activity.children.where(
          (e) =>
              e.tag == 'meta-data' &&
              e.android('name') == 'flutter_deeplinking_enabled',
        );
        expect(deepLinks.map((e) => e.android('value')), ['false']);
        expect(
          activity.children.where((e) => e.tag == 'intent-filter'),
          hasLength(1),
        );
      },
    );

    test('has no backup, no cleartext flag and no debuggable flag', () {
      expect(source, contains('android:allowBackup="false"'));
      expect(source, isNot(contains('usesCleartextTraffic')));
      expect(source, isNot(contains('android:debuggable')));
    });

    test('MainActivity refuses what an intent could steer it with', () {
      final kotlin = File(
        'android/app/src/main/kotlin/app/afterme/MainActivity.kt',
      ).readAsStringSync();
      for (final hook in [
        'override fun getInitialRoute(): String? = null',
        'override fun getCachedEngineId(): String? = null',
        'override fun getCachedEngineGroupId(): String? = null',
        'override fun getBackgroundMode(): BackgroundMode = BackgroundMode.opaque',
        'override fun getDartEntrypointArgs(): List<String>? = null',
        'override fun shouldHandleDeeplinking(): Boolean = false',
        'override fun createFlutterFragment(): FlutterFragment',
      ]) {
        expect(kotlin, contains(hook));
      }
      // The engine flags the framework would read from the intent are not passed on
      // (comments may name them).
      final code = kotlin
          .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
          .replaceAll(RegExp(r'//.*'), '');
      expect(code, isNot(contains('FlutterShellArgs')));
      expect(code, isNot(contains('flutterShellArgs(')));
    });
  });
}
