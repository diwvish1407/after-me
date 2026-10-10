// Enforces the mobile coverage gates (TEST_PLAN.md §10) on coverage/lcov.info:
//   * >= 70% line coverage overall,
//   * >= 90% for the API interceptors and the session/auth code,
//   * >= 90% for every Phase 2-4 feature area (auth, onboarding, settings, home,
//     contacts, check-ins, the temporary repositories, app lock, permissions, forms,
//     pickers, device and platform gateways, time formatting).
// Generated code (*.g.dart, *.freezed.dart, lib/l10n/gen/) is excluded.
//
// `flutter test --coverage` only reports libraries that some test loads, so a lib
// file that no test imports would silently not count. Every non-generated file under
// lib/ without coverage data therefore FAILS the gate (and its lines count as
// uncovered), unless it is allowlisted below or contains only exports/comments.
//
// Usage (from mobile/): flutter test --coverage && dart run tool/coverage_check.dart
import 'dart:io';

const _gates = <String, double>{
  'lib/': 70,
  'lib/core/api/interceptors/': 90,
  'lib/core/auth/': 90,
  // Phase 2 (authentication and onboarding experience).
  'lib/features/auth/': 90,
  'lib/features/onboarding/': 90,
  'lib/features/settings/': 90,
  'lib/features/home/': 90,
  // Phase 3 (trusted contacts: data, controllers, People/Add/Edit/Detail screens).
  'lib/features/contacts/': 90,
  // Phase 4 (check-ins: schedule, I'M OK with its pending state, Home, history).
  'lib/features/checkin/': 90,
  'lib/features/plan/': 90,
  'lib/features/instructions/': 90,
  'lib/core/security/': 90,
  'lib/core/permissions/': 90,
  'lib/core/forms/': 90,
  'lib/core/pickers/': 90,
  'lib/core/device/': 90,
  'lib/core/links/': 90,
  'lib/core/platform/': 90,
  'lib/core/time/': 90,
};

/// Files that legitimately have no coverage data.
const _noCoverageAllowlist = <String>{
  // Process bootstrap with side effects; exercised by the debug/release builds.
  'lib/main.dart',
  // Pure compile-time constants (no executable lines).
  'lib/app/theme/dimens.dart',
  // Interface declarations and re-exports only: no executable lines. The
  // implementations (Dio*) and the models are covered by their own tests.
  'lib/features/checkin/data/checkin_repository.dart',
  'lib/features/checkin/data/schedule_repository.dart',
  'lib/features/home/data/home_repository.dart',
};

bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.contains('lib/l10n/gen/');

void main(List<String> args) {
  final file = File(args.isEmpty ? 'coverage/lcov.info' : args.first);
  if (!file.existsSync()) {
    stderr.writeln(
      '${file.path} not found. Run `flutter test --coverage` first.',
    );
    exit(2);
  }

  final found = <String, int>{};
  final hit = <String, int>{};
  String? current;
  for (final line in file.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      final path = line.substring(3).replaceAll(r'\', '/');
      final libIndex = path.indexOf('lib/');
      current = libIndex < 0 ? path : path.substring(libIndex);
      if (_isGenerated(current)) {
        current = null;
      }
    } else if (line.startsWith('DA:') && current != null) {
      final parts = line.substring(3).split(',');
      found[current] = (found[current] ?? 0) + 1;
      if ((int.tryParse(parts[1]) ?? 0) > 0) {
        hit[current] = (hit[current] ?? 0) + 1;
      }
    }
  }

  var failed = false;
  failed = _addUncoveredFiles(found) || failed;
  for (final MapEntry(key: prefix, value: minimum) in _gates.entries) {
    var total = 0;
    var covered = 0;
    for (final path in found.keys.where((p) => p.startsWith(prefix))) {
      total += found[path]!;
      covered += hit[path] ?? 0;
    }
    if (total == 0) {
      stderr.writeln('No coverage data for $prefix');
      failed = true;
      continue;
    }
    final percent = 100 * covered / total;
    final ok = percent >= minimum;
    failed = failed || !ok;
    stdout.writeln(
      '${ok ? 'PASS' : 'FAIL'} $prefix ${percent.toStringAsFixed(1)}% '
      '($covered/$total lines, minimum $minimum%)',
    );
  }
  exit(failed ? 1 : 0);
}

/// Whether [source] has no executable code: only comments, blank lines, `library`
/// and `export` directives.
bool _hasNoExecutableCode(List<String> lines) => lines.every((line) {
  final trimmed = line.trim();
  return trimmed.isEmpty ||
      trimmed.startsWith('//') ||
      trimmed.startsWith('export ') ||
      trimmed.startsWith('library') ||
      trimmed.startsWith("show ") ||
      trimmed.startsWith("hide ") ||
      trimmed.startsWith("'") ||
      trimmed.startsWith(';');
});

/// Adds every lib/ file that has no lcov entry to [found] as fully uncovered, and
/// reports it. Returns true when at least one such file exists.
bool _addUncoveredFiles(Map<String, int> found) {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    return false;
  }
  var any = false;
  final files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    if (_isGenerated(path) ||
        found.containsKey(path) ||
        _noCoverageAllowlist.contains(path)) {
      continue;
    }
    final lines = file.readAsLinesSync();
    if (_hasNoExecutableCode(lines)) {
      continue;
    }
    final executable = lines
        .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('//'))
        .length;
    found[path] = executable;
    any = true;
    stderr.writeln('NO COVERAGE DATA: $path (no test imports it)');
  }
  return any;
}
