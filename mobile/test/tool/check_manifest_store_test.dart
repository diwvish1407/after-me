import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_manifest_permissions.dart';

/// The Play-release part of the merged-manifest check (Phase 13, PLAY_STORE §3): no
/// advertising ID in any form, and the adaptive launcher icon wired under the flavor's
/// label.
String _manifest({
  String permissions = '',
  String icon = 'android:icon="@mipmap/ic_launcher"',
  String roundIcon = 'android:roundIcon="@mipmap/ic_launcher_round"',
  String label = 'android:label="@string/app_name"',
}) =>
    '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="app.afterme">
$permissions
    <application $label $icon $roundIcon android:allowBackup="false" />
</manifest>''';

void main() {
  test('a manifest as built: no issue', () {
    expect(storeReadinessIssues(_manifest()), isEmpty);
  });

  test('AD_ID as a permission is refused, with how to remove it', () {
    final issues = storeReadinessIssues(
      _manifest(
        permissions:
            '    <uses-permission android:name="$advertisingIdPermission" />',
      ),
    );
    expect(issues, hasLength(1));
    expect(issues.single, contains('tools:node="remove"'));
  });

  test('AD_ID in any other form (sdk-23 permission) is refused too', () {
    expect(
      storeReadinessIssues(
        _manifest(
          permissions:
              '    <uses-permission-sdk-23 android:name="$advertisingIdPermission" />',
        ),
      ),
      isNotEmpty,
    );
  });

  test('the launcher icon, the round icon and the label must be wired', () {
    expect(
      storeReadinessIssues(_manifest(roundIcon: '')),
      contains(contains('android:roundIcon')),
    );
    expect(
      storeReadinessIssues(_manifest(icon: 'android:icon="@drawable/other"')),
      contains(contains('android:icon')),
    );
    expect(
      storeReadinessIssues(_manifest(label: 'android:label="AfterMe Dev"')),
      contains(contains('android:label')),
    );
  });

  test('no application element is reported, not passed', () {
    expect(
      storeReadinessIssues('<manifest package="app.afterme"></manifest>'),
      isNotEmpty,
    );
  });
}
