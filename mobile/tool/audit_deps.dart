// Dependency audit gate for the app (SECURITY §15, T22; TEST_PLAN §10).
//
// The backend runs pip-audit; this is the same gate for pubspec.lock. It sends only package
// names and versions (public information) to the OSV database and fails when any pinned hosted
// package has a known advisory. An advisory that has been looked at and accepted can be skipped
// by id with `--ignore GHSA-xxxx-xxxx-xxxx` (repeatable), and the reason belongs in the commit
// that adds it.
//
// Usage (from mobile/):
//   dart run tool/audit_deps.dart [--ignore ID]...
import 'dart:convert';
import 'dart:io';

const _endpoint = 'https://api.osv.dev/v1/querybatch';
const _batch = 20;

final _block = RegExp(r'^  ([A-Za-z0-9_]+):\n((?:    .*\n)+)', multiLine: true);
final _version = RegExp(r'^    version: "?([^"\n]+)"?', multiLine: true);
final _source = RegExp(r'^    source: "?([^"\n]+)"?', multiLine: true);

Future<int> main(List<String> args) async {
  final ignored = <String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--ignore' && i + 1 < args.length) {
      ignored.add(args[++i]);
    } else {
      stderr.writeln('usage: dart run tool/audit_deps.dart [--ignore ID]...');
      return 64;
    }
  }

  final lock = File('pubspec.lock');
  if (!lock.existsSync()) {
    stderr.writeln('pubspec.lock not found: run from mobile/');
    return 66;
  }
  final packages = <MapEntry<String, String>>[];
  for (final match in _block.allMatches(lock.readAsStringSync())) {
    final body = match.group(2)!;
    if (_source.firstMatch(body)?.group(1) != 'hosted') continue;
    final version = _version.firstMatch(body)?.group(1);
    if (version != null) packages.add(MapEntry(match.group(1)!, version));
  }
  if (packages.isEmpty) {
    stderr.writeln(
      'no hosted packages found in pubspec.lock: refusing to pass an empty audit',
    );
    return 65;
  }

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final findings = <String>[];
  try {
    for (var start = 0; start < packages.length; start += _batch) {
      final chunk = packages.sublist(
        start,
        start + _batch > packages.length ? packages.length : start + _batch,
      );
      final results = await _query(client, chunk);
      for (var i = 0; i < chunk.length; i++) {
        final ids = <String>[
          for (final v in (results[i]['vulns'] as List<dynamic>? ?? const []))
            (v as Map<String, dynamic>)['id'] as String,
        ].where((id) => !ignored.contains(id)).toList();
        if (ids.isNotEmpty) {
          findings.add('${chunk[i].key} ${chunk[i].value}: ${ids.join(', ')}');
        }
      }
    }
  } on Object catch (error) {
    // An audit that could not run must not look like an audit that passed.
    stderr.writeln('OSV query failed: ${error.runtimeType}');
    return 69;
  } finally {
    client.close(force: true);
  }

  stdout.writeln('osv: ${packages.length} hosted packages audited');
  if (findings.isEmpty) {
    stdout.writeln('No known vulnerabilities found');
    return 0;
  }
  stdout.writeln('Advisories:');
  for (final line in findings) {
    stdout.writeln('  - $line');
  }
  return 1;
}

Future<List<Map<String, dynamic>>> _query(
  HttpClient client,
  List<MapEntry<String, String>> chunk,
) async {
  final body = jsonEncode({
    'queries': [
      for (final p in chunk)
        {
          'package': {'name': p.key, 'ecosystem': 'Pub'},
          'version': p.value,
        },
    ],
  });
  for (var attempt = 0; ; attempt++) {
    try {
      final request = await client.postUrl(Uri.parse(_endpoint));
      request.headers.contentType = ContentType.json;
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      final text = await utf8.decodeStream(response);
      if (response.statusCode != 200) {
        throw HttpException('OSV answered ${response.statusCode}');
      }
      final decoded = jsonDecode(text) as Map<String, dynamic>;
      return (decoded['results'] as List<dynamic>).cast<Map<String, dynamic>>();
    } on Object {
      if (attempt >= 2) rethrow;
    }
  }
}
