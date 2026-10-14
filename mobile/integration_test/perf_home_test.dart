// PERF-05: no jank (frames over 16 ms) on Home. NOT part of the default suite (its name
// does not match mob6*_test.dart): frame times from a debug build are meaningless, so it
// is run in PROFILE mode by `tool/integration.sh --perf`, which uses `flutter drive
// --profile` with test_driver/perf_driver.dart and leaves the numbers in
// build/perf_frames.json. On the emulator they are indicative; run it on a real mid-range
// phone for the PERF-05 figure. Known limit: see the note in tool/integration.sh (typing
// does not register under `flutter drive --profile` on the emulator).
//
// What it does: a new account, an active plan, Home; then it scrolls Home up and down,
// pulls to refresh, and switches tabs and back, ten rounds, collecting every frame's
// build and raster time (`FrameTiming`) and the binding's own summary (`watchPerformance`).
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/backend.dart';
import 'support/harness.dart';
import 'support/journeys.dart';

double _ms(Duration d) => d.inMicroseconds / 1000;

double _percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) {
    return 0;
  }
  final index = ((sorted.length - 1) * p).round();
  return sorted[index];
}

Map<String, Object?> _summarize(List<FrameTiming> frames) {
  final build = [for (final f in frames) _ms(f.buildDuration)]..sort();
  final raster = [for (final f in frames) _ms(f.rasterDuration)]..sort();
  final total = [for (final f in frames) _ms(f.totalSpan)]..sort();
  double avg(List<double> v) =>
      v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
  return {
    'frames': frames.length,
    'build_ms_avg': avg(build),
    'build_ms_p90': _percentile(build, 0.9),
    'build_ms_p99': _percentile(build, 0.99),
    'build_ms_max': build.isEmpty ? 0 : build.last,
    'raster_ms_avg': avg(raster),
    'raster_ms_p90': _percentile(raster, 0.9),
    'raster_ms_p99': _percentile(raster, 0.99),
    'raster_ms_max': raster.isEmpty ? 0 : raster.last,
    'total_span_ms_p99': _percentile(total, 0.99),
    // A frame is janky when the UI or the raster thread alone needed more than 16 ms.
    'frames_build_over_16ms': build.where((v) => v > 16).length,
    'frames_raster_over_16ms': raster.where((v) => v > 16).length,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final backend = Backend.fromEnvironment();
  tearDownAll(backend.close);

  integrationTest('PERF-05 Home frame times', backend, (h) async {
    await signUpAndActivate(h);
    await h.waitFor(
      find.text(l10n.checkInLabelIdle),
      reason: 'I\'M OK on Home',
    );
    await h.pump(const Duration(seconds: 2));

    final frames = <FrameTiming>[];
    void collect(List<FrameTiming> timings) => frames.addAll(timings);
    WidgetsBinding.instance.addTimingsCallback(collect);

    await binding.watchPerformance(() async {
      for (var round = 0; round < 10; round++) {
        final scrollable = find.byType(Scrollable).first;
        await h.tester.fling(scrollable, const Offset(0, -400), 1500);
        await h.pump(const Duration(milliseconds: 600));
        // Down past the top: the pull-to-refresh, which reads Home again.
        await h.tester.fling(scrollable, const Offset(0, 900), 1500);
        await h.pump(const Duration(milliseconds: 900));
        // Another tab and back.
        await h.tapText(l10n.navPeople);
        await h.pump(const Duration(milliseconds: 500));
        await h.tapText(l10n.navHome);
        await h.pump(const Duration(milliseconds: 500));
      }
    }, reportKey: 'home_scroll_refresh_tabs');

    WidgetsBinding.instance.removeTimingsCallback(collect);
    final summary = _summarize(frames);
    binding.reportData ??= <String, dynamic>{};
    binding.reportData!['frames_summary'] = summary;
    debugPrint('PERF_FRAMES $summary');
    expect(frames, isNotEmpty, reason: 'the engine reported no frame timings');
  });
}
