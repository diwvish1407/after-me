import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The app does no background work (TEST_PLAN PERF-05, battery; ARCHITECTURE §5): no
/// foreground service, no WorkManager or AlarmManager job, no wake lock of its own, no
/// `Timer.periodic` outside the two places that stop it when the app leaves the
/// foreground. Reminders come from the server (FCM), never from a schedule on the phone.
///
/// This test scans the source so it cannot regress by accident. Anything it finds that is
/// not on the allow-list below fails the test; adding an entry needs a reason, written
/// next to it, that a reviewer can check. `test/perf/foreground_timers_test.dart` proves
/// the behaviour of the entries that are timers.
///
/// It runs from `mobile/` (where `flutter test` runs).

/// What may appear where. Key: a pattern name; value: the files (relative to `mobile/`)
/// that may contain it, with the reason.
const _allowed = <String, Map<String, String>>{
  r'Timer.periodic': {
    'lib/core/time/foreground_ticker.dart':
        'THE foreground-only periodic timer: cancelled on paused/hidden, started again '
        'on resumed. Used by the incident timeline (redraw every 30 s) and the '
        'resend countdown (every second, only while there is something to count).',
    'lib/features/home/presentation/home_screen.dart':
        "Home's 30 s ticker (redraw, and the once-a-minute read while an incident is "
        'open, a deadline passed or an interruption is on). Runs only while the app '
        'is in the foreground AND the Home tab is on view (TickerMode); cancelled on '
        'paused/hidden, restarted on resumed.',
  },
  r'onBackgroundMessage': {
    'lib/core/push/firebase_push_gateway.dart':
        'FCM requires a top-level handler for a data message that arrives while the app '
        'is not running. It is started by the OS for a message the server sent, it '
        'is empty (afterMeBackgroundMessageHandler does nothing, stores nothing), and '
        'it schedules nothing: this is receiving, not background work of our own.',
  },
};

/// Patterns that must never appear in app code, build files or the app's manifest.
/// (`Timer.periodic` and `onBackgroundMessage` are handled by [_allowed].)
final _forbidden = <String, RegExp>{
  'WorkManager / workmanager plugin': RegExp(
    r'work_?manager',
    caseSensitive: false,
  ),
  'AlarmManager / android_alarm_manager': RegExp(
    r'alarm_?manager',
    caseSensitive: false,
  ),
  'foreground service': RegExp(
    r'foreground_?service|flutter_foreground_task|FOREGROUND_SERVICE',
    caseSensitive: false,
  ),
  'flutter_background / background_fetch / background_locator': RegExp(
    r'flutter_background|background_fetch|background_locator|background_service',
    caseSensitive: false,
  ),
  'wake lock': RegExp(
    r'wake_?lock|PowerManager|WAKE_LOCK',
    caseSensitive: false,
  ),
  'JobScheduler / JobService': RegExp(r'JobScheduler|JobService|JobInfo'),
  'boot receiver': RegExp(r'BOOT_COMPLETED|LOCKED_BOOT_COMPLETED'),
  'exact alarms / battery optimisation exemptions': RegExp(
    r'SCHEDULE_EXACT_ALARM|USE_EXACT_ALARM|REQUEST_IGNORE_BATTERY_OPTIMIZATIONS|setExactAndAllowWhileIdle|setAlarmClock',
  ),
  'Stream.periodic': RegExp(r'Stream\s*\.\s*periodic'),
  'a second isolate': RegExp(r'Isolate\s*\.\s*(spawn|run)|\bcompute\s*\('),
  'local notification scheduling (reminders come from the server)': RegExp(
    r'zonedSchedule|periodicallyShow|\.schedule\s*\(',
  ),
  'android wake / exact scheduling classes': RegExp(
    r'AlarmManager|WorkRequest',
  ),
};

List<File> _sourceFiles() {
  final files = <File>[];
  void walk(String dir, bool Function(String path) keep) {
    final root = Directory(dir);
    if (!root.existsSync()) {
      return;
    }
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is File && keep(entity.path)) {
        files.add(entity);
      }
    }
  }

  bool generated(String path) =>
      path.contains('/l10n/gen/') ||
      path.endsWith('.g.dart') ||
      path.endsWith('.freezed.dart') ||
      path.endsWith('GeneratedPluginRegistrant.java');

  walk('lib', (p) => p.endsWith('.dart') && !generated(p));
  walk(
    'android/app/src',
    (p) =>
        (p.endsWith('.kt') ||
            p.endsWith('.java') ||
            p.endsWith('.xml') ||
            p.endsWith('.kts')) &&
        !generated(p),
  );
  files
    ..add(File('android/app/build.gradle.kts'))
    ..add(File('pubspec.yaml'));
  return files.where((f) => f.existsSync()).toList();
}

/// A line is a comment when its first non-blank characters start one. Comments may talk
/// about what the app does not do.
bool _isComment(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') ||
      t.startsWith('///') ||
      t.startsWith('*') ||
      t.startsWith('/*') ||
      t.startsWith('<!--') ||
      t.startsWith('#');
}

/// Strips `<!-- ... -->` blocks (the manifest explains what it leaves out).
String _withoutXmlComments(String path, String text) => path.endsWith('.xml')
    ? text.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '')
    : text;

Iterable<(String, int, String)> _codeLines(File file) sync* {
  final text = _withoutXmlComments(file.path, file.readAsStringSync());
  final lines = text.split('\n');
  var inBlockComment = false;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final t = line.trimLeft();
    if (inBlockComment) {
      if (t.contains('*/')) {
        inBlockComment = false;
      }
      continue;
    }
    if (t.startsWith('/*') && !t.contains('*/')) {
      inBlockComment = true;
      continue;
    }
    if (_isComment(line)) {
      continue;
    }
    yield (file.path, i + 1, line);
  }
}

void main() {
  final files = _sourceFiles();

  test(
    'the scan sees the app (a moved folder cannot make it pass vacuously)',
    () {
      expect(files.length, greaterThan(100));
      expect(files.any((f) => f.path.endsWith('home_screen.dart')), isTrue);
      expect(files.any((f) => f.path.endsWith('AndroidManifest.xml')), isTrue);
      expect(files.any((f) => f.path.endsWith('MainActivity.kt')), isTrue);
      expect(files.any((f) => f.path.endsWith('pubspec.yaml')), isTrue);
    },
  );

  test('nothing that schedules or holds the device awake is in the app', () {
    final found = <String>[];
    for (final file in files) {
      for (final (path, number, line) in _codeLines(file)) {
        _forbidden.forEach((name, pattern) {
          if (pattern.hasMatch(line)) {
            found.add('$path:$number  [$name]  ${line.trim()}');
          }
        });
      }
    }
    expect(
      found,
      isEmpty,
      reason: 'background work found:\n${found.join('\n')}',
    );
  });

  test('every Timer.periodic and background handler is on the allow-list, in '
      'the file named there', () {
    final found = <String, Set<String>>{};
    for (final file in files) {
      for (final (path, _, line) in _codeLines(file)) {
        for (final name in _allowed.keys) {
          if (line.contains(name)) {
            found.putIfAbsent(name, () => {}).add(path);
          }
        }
      }
    }
    for (final entry in found.entries) {
      expect(
        _allowed[entry.key]!.keys.toSet().containsAll(entry.value),
        isTrue,
        reason:
            '${entry.key} appears in ${entry.value} but is allowed only in '
            '${_allowed[entry.key]!.keys}. Add it to the allow-list in '
            'no_background_work_test.dart with a reason, or remove it.',
      );
    }
    // The allow-list holds no stale entry: an allowance whose code is gone is removed.
    for (final name in _allowed.keys) {
      for (final path in _allowed[name]!.keys) {
        expect(
          found[name]?.contains(path) ?? false,
          isTrue,
          reason: '$name is allowed in $path but no longer appears there',
        );
      }
    }
  });

  group("the app's own manifest", () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync()
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    test('declares no WAKE_LOCK (the FCM one is merged in by the library)', () {
      // Firebase Cloud Messaging adds android.permission.WAKE_LOCK to the merged
      // manifest to hold a short lock while it hands over a message. It is allowed there,
      // with its reason, by tool/check_manifest_permissions.dart; the app never asks.
      expect(manifest, isNot(contains('WAKE_LOCK')));
    });

    test(
      'declares no service, no boot or alarm receiver and no job of its own',
      () {
        expect(manifest, isNot(contains('<service')));
        expect(manifest, isNot(contains('<receiver')));
        expect(manifest, isNot(contains('<provider')));
        expect(manifest, isNot(contains('BOOT_COMPLETED')));
        expect(manifest, isNot(contains('FOREGROUND_SERVICE')));
        expect(manifest, isNot(contains('SCHEDULE_EXACT_ALARM')));
        expect(manifest, isNot(contains('USE_EXACT_ALARM')));
      },
    );

    test('the permission list is the short one', () {
      final names = RegExp(r'<uses-permission[^>]*android:name="([^"]+)"')
          .allMatches(manifest)
          .map((m) => m.group(1)!)
          .toSet();
      expect(names, {
        'android.permission.INTERNET',
        'android.permission.USE_BIOMETRIC',
        'android.permission.POST_NOTIFICATIONS',
        'android.permission.USE_FINGERPRINT',
        'android.permission.VIBRATE',
      });
    });
  });

  test('the permission check keeps its wake-lock allowance documented', () {
    final tool = File('tool/check_manifest_permissions.dart')
        .readAsStringSync();
    expect(tool, contains('FCM holds a short wake lock'));
  });
}
