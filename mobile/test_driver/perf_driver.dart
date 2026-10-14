import 'dart:async';

import 'package:integration_test/integration_test_driver.dart';

/// The host half of `integration_test/perf_home_test.dart` (run by `flutter drive
/// --profile`, see `tool/integration.sh --perf`): writes what the test reported to
/// `build/perf_frames.json`.
Future<void> main() => integrationDriver(
  responseDataCallback: (data) =>
      writeResponseData(data, testOutputFilename: 'perf_frames'),
);
