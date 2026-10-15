import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// tool/integration.sh drops its database and starts servers, so what it accepts from
/// the environment is checked before it does anything: only the two throwaway databases,
/// and a port number. (The run itself needs an emulator: README "Integration tests".)
void main() {
  ProcessResult run(Map<String, String> env, [List<String> args = const []]) =>
      Process.runSync('bash', [
        'tool/integration.sh',
        ...args,
      ], environment: env);

  test('a database other than the throwaway ones is refused', () {
    for (final db in [
      'afterme_dev',
      'afterme',
      'postgres',
      'afterme_it; drop',
    ]) {
      final result = run({'AFTERME_IT_DB': db});
      expect(result.exitCode, 2, reason: db);
      expect('${result.stderr}', contains('AFTERME_IT_DB must be'), reason: db);
    }
  });

  test('a port that is not a number is refused', () {
    for (final port in ['abc', '80', '8000x', '123456']) {
      final result = run({'AFTERME_IT_PORT': port});
      expect(result.exitCode, 2, reason: port);
      expect(
        '${result.stderr}',
        contains('AFTERME_IT_PORT must be'),
        reason: port,
      );
    }
  });

  test('--help documents the port, the database and the screenshots', () {
    final result = run({}, ['--help']);
    expect(result.exitCode, 0);
    expect('${result.stdout}', contains('AFTERME_IT_PORT'));
    expect('${result.stdout}', contains('afterme_shots'));
    expect('${result.stdout}', contains('--screenshots'));
  });

  test('tool/screenshots.sh uses its own database and not port 8000', () {
    final script = File('tool/screenshots.sh').readAsStringSync();
    expect(script, contains('AFTERME_IT_DB=afterme_shots'));
    expect(script, contains(r'AFTERME_IT_PORT="${AFTERME_IT_PORT:-8010}"'));
    expect(script, contains('--screenshots'));
  });
}
