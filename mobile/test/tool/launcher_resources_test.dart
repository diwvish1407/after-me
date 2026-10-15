import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The launcher icon, its label per flavor and the Android 12+ splash, as the sources say
/// (PLAY_STORE §3, §5; Phase 13). The merged manifest of a real build is checked by
/// tool/check_manifest_permissions.dart in tool/build_release.sh; this test needs no build.
const _res = 'android/app/src/main/res';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('adaptive launcher icon', () {
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      test('$name has a background, a foreground and a monochrome layer', () {
        final xml = _read('$_res/mipmap-anydpi-v26/$name.xml');
        expect(xml, contains('<adaptive-icon'));
        expect(
          xml,
          contains(
            '<background android:drawable="@color/ic_launcher_background"',
          ),
        );
        expect(
          xml,
          contains(
            '<foreground android:drawable="@drawable/ic_launcher_foreground"',
          ),
        );
        // Themed icons (Android 13+) need the monochrome layer.
        expect(
          xml,
          contains(
            '<monochrome android:drawable="@drawable/ic_launcher_monochrome"',
          ),
        );
      });
    }

    test('the layers are vector drawables in the 108 dp viewport', () {
      for (final name in [
        'ic_launcher_foreground',
        'ic_launcher_monochrome',
        'ic_splash',
      ]) {
        final xml = _read('$_res/drawable/$name.xml');
        expect(xml, contains('<vector'), reason: name);
        expect(xml, contains('android:viewportWidth="108"'), reason: name);
        expect(xml, contains('android:width="108dp"'), reason: name);
      }
    });

    test('the colours are the design tokens: teal on warm white', () {
      final foreground = _read('$_res/drawable/ic_launcher_foreground.xml');
      expect(foreground, contains('#FF1F6F6B')); // primary
      expect(foreground, contains('#FFF7F5F2')); // bg
      expect(
        _read('$_res/values/colors.xml'),
        contains('<color name="ic_launcher_background">#F7F5F2</color>'),
      );
    });

    test('the manifest names the icon and its round twin', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(
        manifest,
        contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      );
      expect(manifest, contains('android:label="@string/app_name"'));
    });

    test(
      'the legacy PNGs exist for every density (rendered from the mark)',
      () {
        for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
          for (final name in ['ic_launcher', 'ic_launcher_round']) {
            expect(
              File('$_res/mipmap-$density/$name.png').existsSync(),
              isTrue,
              reason: 'mipmap-$density/$name.png',
            );
          }
        }
      },
    );
  });

  test('the launcher label is "AfterMe" in prod; dev and staging say so', () {
    final gradle = _read('android/app/build.gradle.kts');
    String labelOf(String flavor) {
      final block = RegExp(
        'create\\("$flavor"\\) \\{(.*?)\\n        \\}',
        dotAll: true,
      ).firstMatch(gradle)!.group(1)!;
      return RegExp(r'resValue\("string", "app_name", "([^"]*)"\)')
          .firstMatch(block)!
          .group(1)!;
    }

    expect(labelOf('prod'), 'AfterMe');
    expect(labelOf('dev'), 'AfterMe Dev');
    expect(labelOf('staging'), 'AfterMe Staging');
  });

  group('Android 12+ splash', () {
    for (final (folder, parent) in [
      ('values-v31', 'Theme.AppCompat.Light.NoActionBar'),
      ('values-night-v31', 'Theme.AppCompat.NoActionBar'),
    ]) {
      test('$folder: the theme background and the mark, nothing else', () {
        final xml = _read('$_res/$folder/styles.xml');
        expect(xml, contains('<style name="LaunchTheme" parent="$parent">'));
        expect(
          xml,
          contains(
            '<item name="android:windowSplashScreenBackground">@color/launch_background</item>',
          ),
        );
        expect(
          xml,
          contains(
            '<item name="android:windowSplashScreenAnimatedIcon">@drawable/ic_splash</item>',
          ),
        );
        // Calm and brief: no animation, no branding image.
        expect(xml, isNot(contains('windowSplashScreenAnimationDuration')));
        expect(xml, isNot(contains('windowSplashScreenBrandingImage')));
      });
    }

    test('the dark splash uses the dark tokens', () {
      final night = _read('$_res/values-night/colors.xml');
      expect(
        night,
        contains('<color name="launch_background">#121718</color>'),
      );
      expect(night, contains('<color name="splash_tile">#5FB3AD</color>'));
      final light = _read('$_res/values/colors.xml');
      expect(
        light,
        contains('<color name="launch_background">#F7F5F2</color>'),
      );
      expect(light, contains('<color name="splash_tile">#1F6F6B</color>'));
    });

    test('before Android 12 the launch background shows the same mark', () {
      final xml = _read('$_res/drawable/launch_background.xml');
      expect(xml, contains('@color/launch_background'));
      expect(xml, contains('@drawable/ic_splash'));
    });
  });
}
