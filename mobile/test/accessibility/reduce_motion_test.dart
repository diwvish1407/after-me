import 'package:afterme/app/router.dart';
import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/app/theme/reduced_motion_transitions.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/features/settings/presentation/about_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/contacts_harness.dart';
import '../helpers/test_app.dart';

/// Reduce motion (TEST_PLAN §8): when the person asked the phone to remove animations
/// (`MediaQuery.disableAnimationsOf`, from `AccessibilityFeatures.disableAnimations`),
/// nothing in the app spins, slides or fades by itself. Each place that moved has its own
/// test; the spinner and the page transitions are the only places the app's own code
/// animates (everything else is the framework's, which shortens its controllers to one
/// frame under the same setting).
const _reduced = FakeAccessibilityFeatures(disableAnimations: true);

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool reduceMotion,
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue = reduceMotion
      ? _reduced
      : const FakeAccessibilityFeatures();
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    wrapForTest(
      Scaffold(body: Center(child: child)),
      theme: AppTheme.light(),
    ),
  );
}

void main() {
  group('the spinner', () {
    testWidgets('spins normally', (tester) async {
      await _pump(tester, const ProgressSpinner(), reduceMotion: false);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    });

    testWidgets('is a still hourglass under "remove animations"', (
      tester,
    ) async {
      await _pump(tester, const ProgressSpinner(), reduceMotion: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
    });
  });

  group('every place that waits', () {
    testWidgets('a loading view', (tester) async {
      await _pump(
        tester,
        const LoadingView(label: 'Loading'),
        reduceMotion: true,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(find.text('Loading'), findsOneWidget, reason: 'the words stay');
    });

    testWidgets('a busy button', (tester) async {
      await _pump(
        tester,
        AppButton.primary(label: 'Save', onPressed: () {}, isLoading: true),
        reduceMotion: true,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
    });

    testWidgets('the I\'M OK button while it sends', (tester) async {
      await _pump(
        tester,
        CheckInButton(state: CheckInButtonState.sending, onPressed: () {}),
        reduceMotion: true,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.hourglass_top_rounded), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
    });

    testWidgets('and all three spin when motion is allowed', (tester) async {
      await _pump(
        tester,
        Column(
          children: [
            const LoadingView(label: 'Loading'),
            AppButton.primary(label: 'Save', onPressed: () {}, isLoading: true),
            CheckInButton(state: CheckInButtonState.sending, onPressed: () {}),
          ],
        ),
        reduceMotion: false,
      );
      expect(find.byType(CircularProgressIndicator), findsNWidgets(3));
    });
  });

  group('what the framework animates', () {
    // The app's own code animates nothing else. A bottom sheet, a snackbar and a dialog
    // are the framework's; Flutter shortens their controllers to one frame under the
    // same setting, which these tests pin so that an upgrade cannot change it silently.
    Future<double> sheetTopAfter(
      WidgetTester tester, {
      required bool reduce,
      required Duration after,
    }) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = reduce
          ? _reduced
          : const FakeAccessibilityFeatures();
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(
                      height: 200,
                      child: Text('The sheet', key: Key('sheet')),
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(after);
      return tester.getTopLeft(find.byKey(const Key('sheet'))).dy;
    }

    testWidgets('a bottom sheet is in place after one short frame when '
        'animations are removed, and still on its way otherwise', (
      tester,
    ) async {
      final reduced = await sheetTopAfter(
        tester,
        reduce: true,
        after: const Duration(milliseconds: 50),
      );
      final settled = tester.getTopLeft(find.byKey(const Key('sheet'))).dy;
      await tester.pumpAndSettle();
      final finalTop = tester.getTopLeft(find.byKey(const Key('sheet'))).dy;
      expect(reduced, finalTop, reason: 'already where it ends');
      expect(settled, finalTop);
    });

    testWidgets('with motion allowed the same sheet is not there yet after '
        '50 ms', (tester) async {
      final moving = await sheetTopAfter(
        tester,
        reduce: false,
        after: const Duration(milliseconds: 50),
      );
      await tester.pumpAndSettle();
      final finalTop = tester.getTopLeft(find.byKey(const Key('sheet'))).dy;
      expect(moving, greaterThan(finalTop), reason: 'still sliding up');
    });
  });

  group('page transitions', () {
    test('the theme wraps every platform\'s transition', () {
      final builders = AppTheme.light().pageTransitionsTheme.builders;
      expect(
        builders[TargetPlatform.android],
        isA<ReducedMotionPageTransitionsBuilder>(),
      );
      for (final builder in builders.values) {
        expect(builder, isA<ReducedMotionPageTransitionsBuilder>());
      }
    });

    testWidgets('a pushed page is simply there under "remove animations"', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = _reduced;
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final fakes = TestFakes();
      final container = await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.home,
      );
      container.read(routerProvider).go(AppRoutes.settingsAbout);
      // One frame to build, one more for whatever the framework runs: far less than the
      // 300 ms a transition takes.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.byType(AboutScreen), findsOneWidget);
      final transitions = find.descendant(
        of: find.byType(AboutScreen).first,
        matching: find.byType(FadeTransition),
      );
      expect(transitions, findsNothing);
      final ancestors = find.ancestor(
        of: find.byType(AboutScreen),
        matching: find.byWidgetPredicate(
          (w) =>
              w is SlideTransition ||
              w is ScaleTransition ||
              w is FadeTransition && w.opacity.value < 1,
        ),
      );
      expect(ancestors, findsNothing, reason: 'nothing is mid-transition');
    });

    testWidgets('the wrapper hands the page over untouched when motion is '
        'removed, and to the platform\'s transition otherwise', (tester) async {
      final base = _RecordingTransitions();
      final builder = ReducedMotionPageTransitionsBuilder(base);
      final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      const child = SizedBox(key: Key('page'));
      late Widget built;

      Future<void> build({required bool reduce}) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue = reduce
            ? _reduced
            : const FakeAccessibilityFeatures();
        await tester.pumpWidget(
          Builder(
            builder: (context) {
              built = builder.buildTransitions<void>(
                route,
                context,
                kAlwaysCompleteAnimation,
                kAlwaysDismissedAnimation,
                child,
              );
              return built;
            },
          ),
        );
      }

      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await build(reduce: true);
      expect(identical(built, child), isTrue, reason: 'the page itself');
      expect(base.calls, 0, reason: 'the platform transition is not used');

      await build(reduce: false);
      expect(base.calls, 1, reason: 'motion allowed: the platform transition');
      expect(identical(built, child), isFalse);
    });
  });
}

/// A transition that wraps the page and counts how often it was asked to.
class _RecordingTransitions extends PageTransitionsBuilder {
  int calls = 0;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    calls++;
    return FadeTransition(opacity: animation, child: child);
  }
}
