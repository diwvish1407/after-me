import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/semantics_audit.dart';

/// The semantics auditor must be able to fail: each rule is shown to fire on a screen
/// built to break it, and to stay quiet on the same screen done properly.
Future<List<SemanticsFinding>> _audit(
  WidgetTester tester,
  Widget body, {
  bool needsHeading = true,
}) async {
  final handle = tester.ensureSemantics();
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  final findings = auditSemantics(tester, needsHeading: needsHeading);
  handle.dispose();
  return findings;
}

Widget _title() => Semantics(header: true, child: const Text('A screen'));

void main() {
  group('semantics auditor', () {
    testWidgets(
      'an unlabelled icon button is reported, a labelled one is not',
      (tester) async {
        final bad = await _audit(
          tester,
          Column(
            children: [
              _title(),
              IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
            ],
          ),
        );
        expect(bad.map((f) => f.kind), contains('unlabelled-control'));

        final good = await _audit(
          tester,
          Column(
            children: [
              _title(),
              IconButton(
                onPressed: () {},
                tooltip: 'Add a contact',
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        );
        expect(good, isEmpty);
      },
    );

    testWidgets('two neighbouring buttons with one name are reported, '
        'distinct names are not', (tester) async {
      final bad = await _audit(
        tester,
        Column(
          children: [
            _title(),
            TextButton(onPressed: () {}, child: const Text('Edit')),
            TextButton(onPressed: () {}, child: const Text('Edit')),
          ],
        ),
      );
      expect(bad.map((f) => f.kind), contains('ambiguous-neighbours'));

      final good = await _audit(
        tester,
        Column(
          children: [
            _title(),
            Semantics(
              button: true,
              label: 'Edit Mom',
              excludeSemantics: true,
              onTap: () {},
              child: const Text('Edit'),
            ),
            Semantics(
              button: true,
              label: 'Edit Brother',
              excludeSemantics: true,
              onTap: () {},
              child: const Text('Edit'),
            ),
          ],
        ),
      );
      expect(good, isEmpty);
    });

    testWidgets('a screen with no heading is reported', (tester) async {
      final bad = await _audit(tester, const Text('Just text'));
      expect(bad.map((f) => f.kind), contains('no-heading'));
      final fine = await _audit(
        tester,
        const Text('A sheet'),
        needsHeading: false,
      );
      expect(fine, isEmpty);
    });

    testWidgets('an icon glyph in a label is reported', (tester) async {
      final bad = await _audit(
        tester,
        Column(
          children: [
            _title(),
            Semantics(
              container: true,
              label: 'Saved ${String.fromCharCode(Icons.check.codePoint)}',
              child: const SizedBox(width: 10, height: 10),
            ),
          ],
        ),
      );
      expect(bad.map((f) => f.kind), contains('icon-glyph'));
    });

    testWidgets(
      'a live region that only wraps its words in a child is reported, '
      'one that carries them is not',
      (tester) async {
        final bad = await _audit(
          tester,
          Column(
            children: [
              _title(),
              Semantics(
                liveRegion: true,
                container: true,
                child: Semantics(container: true, child: const Text('Saved')),
              ),
            ],
          ),
        );
        expect(bad.map((f) => f.kind), contains('silent-live-region'));

        final good = await _audit(
          tester,
          Column(
            children: [
              _title(),
              Semantics(
                liveRegion: true,
                container: true,
                child: const Text('Saved'),
              ),
            ],
          ),
        );
        expect(good, isEmpty);
      },
    );

    testWidgets('a button below the window of a page that does not scroll is '
        'reported, the same page in a list is not', (tester) async {
      tester.view.physicalSize = const Size(360, 640) * 2.75;
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const SizedBox(height: 900),
                FilledButton(onPressed: () {}, child: const Text('Save')),
              ],
            ),
          ),
        ),
      );
      Object? failure;
      try {
        await expectEveryButtonReachable(tester, 'a fixed page');
      } on TestFailure catch (error) {
        failure = error;
      }
      // The column overflows (a layout error is raised too): both say it is wrong.
      tester.takeException();
      expect(failure, isNotNull, reason: 'a button nobody can reach');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                const SizedBox(height: 900),
                FilledButton(onPressed: () {}, child: const Text('Save')),
              ],
            ),
          ),
        ),
      );
      await expectEveryButtonReachable(tester, 'a scrolling page');
    });

    testWidgets('live regions and headings are listed', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                _title(),
                Semantics(
                  liveRegion: true,
                  container: true,
                  child: const Text('Checked in'),
                ),
              ],
            ),
          ),
        ),
      );
      expect(liveRegionLabels(tester), ['Checked in']);
      expect(headingLabels(tester), contains('A screen'));
      handle.dispose();
    });
  });
}
