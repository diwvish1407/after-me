import 'package:flutter_test/flutter_test.dart';

import '../../tool/check_manifest_permissions.dart';

String _manifest(List<String> permissions, {String tag = 'uses-permission'}) =>
    '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="app.afterme">
${permissions.map((p) => '    <$tag android:name="$p" />').join('\n')}
    <application android:label="AfterMe" />
</manifest>''';

void main() {
  const id = 'app.afterme';

  test(
    'accepts the allowlist and the AndroidX dynamic receiver permission',
    () {
      final xml = _manifest([
        'android.permission.INTERNET',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.USE_BIOMETRIC',
        'app.afterme.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
      ]);
      expect(unexpectedPermissions(xml, id), isEmpty);
      expect(requestsInternet(xml), isTrue);
    },
  );

  test('rejects AD_ID and any other permission', () {
    final xml = _manifest([
      'android.permission.INTERNET',
      'com.google.android.gms.permission.AD_ID',
      'android.permission.CAMERA',
    ]);
    expect(unexpectedPermissions(xml, id), [
      'com.google.android.gms.permission.AD_ID',
      'android.permission.CAMERA',
    ]);
  });

  test('the allowlist is exactly the app\'s three and the three FCM adds', () {
    expect(allowedPermissions, {
      'android.permission.INTERNET',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.USE_BIOMETRIC',
      // The push stack (Phase 8), each reviewed on the merged manifest.
      'android.permission.WAKE_LOCK',
      'android.permission.ACCESS_NETWORK_STATE',
      'com.google.android.c2dm.permission.RECEIVE',
    });
  });

  test('accepts what the FCM libraries declare', () {
    final xml = _manifest([
      'android.permission.INTERNET',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.USE_BIOMETRIC',
      'android.permission.WAKE_LOCK',
      'android.permission.ACCESS_NETWORK_STATE',
      'com.google.android.c2dm.permission.RECEIVE',
      'app.afterme.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
    ]);
    expect(unexpectedPermissions(xml, id), isEmpty);
  });

  test('a push stack never gets more than FCM itself needs', () {
    final xml = _manifest([
      'android.permission.INTERNET',
      // The local-notifications plugin declares VIBRATE, which the app removes: a
      // channel vibrates on the app's behalf.
      'android.permission.VIBRATE',
      // Only needed to reschedule notifications after a reboot: nothing is scheduled.
      'android.permission.RECEIVE_BOOT_COMPLETED',
      'android.permission.SCHEDULE_EXACT_ALARM',
      'android.permission.USE_EXACT_ALARM',
      'android.permission.FOREGROUND_SERVICE',
      'com.google.android.gms.permission.AD_ID',
      'android.permission.USE_FULL_SCREEN_INTENT',
    ]);
    expect(unexpectedPermissions(xml, id), [
      'android.permission.VIBRATE',
      'android.permission.RECEIVE_BOOT_COMPLETED',
      'android.permission.SCHEDULE_EXACT_ALARM',
      'android.permission.USE_EXACT_ALARM',
      'android.permission.FOREGROUND_SERVICE',
      'com.google.android.gms.permission.AD_ID',
      'android.permission.USE_FULL_SCREEN_INTENT',
    ]);
  });

  test('rejects READ_CONTACTS, USE_FINGERPRINT and other near misses', () {
    final xml = _manifest([
      'android.permission.INTERNET',
      'android.permission.READ_CONTACTS',
      'android.permission.USE_FINGERPRINT', // no maxSdkVersion: not allowed
      'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      'android.permission.WRITE_CONTACTS',
    ]);
    expect(unexpectedPermissions(xml, id), [
      'android.permission.READ_CONTACTS',
      'android.permission.USE_FINGERPRINT',
      'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
      'android.permission.WRITE_CONTACTS',
    ]);
  });

  test('USE_FINGERPRINT is accepted only when limited to Android 8.x', () {
    String manifest(String attrs) =>
        '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <uses-permission android:name="android.permission.INTERNET" />
  <uses-permission android:name="android.permission.USE_FINGERPRINT" $attrs />
</manifest>''';
    expect(
      unexpectedPermissions(manifest('android:maxSdkVersion="27"'), id),
      isEmpty,
    );
    expect(
      unexpectedPermissions(manifest('android:maxSdkVersion="26"'), id),
      isEmpty,
    );
    for (final attrs in [
      '',
      'android:maxSdkVersion="28"',
      'android:maxSdkVersion="x"',
    ]) {
      expect(unexpectedPermissions(manifest(attrs), id), [
        'android.permission.USE_FINGERPRINT',
      ], reason: attrs);
    }
  });

  test('rejects a dynamic receiver permission of another package', () {
    final xml = _manifest([
      'android.permission.INTERNET',
      'other.app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION',
    ]);
    expect(unexpectedPermissions(xml, id), hasLength(1));
  });

  test('also inspects uses-permission-sdk-23 and multi-line tags', () {
    final xml = _manifest([
      'android.permission.READ_CONTACTS',
    ], tag: 'uses-permission-sdk-23');
    expect(unexpectedPermissions(xml, id), [
      'android.permission.READ_CONTACTS',
    ]);
    const multiline = '''
<manifest>
  <uses-permission
      android:maxSdkVersion="32"
      android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
</manifest>''';
    expect(declaredPermissions(multiline), [
      'android.permission.WRITE_EXTERNAL_STORAGE',
    ]);
  });

  test('missing INTERNET is detected', () {
    expect(requestsInternet(_manifest([])), isFalse);
  });
}
