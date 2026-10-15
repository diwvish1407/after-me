import 'package:afterme/app/app.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backend.dart';

/// The app's own English strings. The tests look for what a person reads on the screen,
/// taken from the same localisation the app uses, so a typo here cannot hide a bug.
final AppLocalizationsEn l10n = AppLocalizationsEn();

/// One throwaway person: an account and the one trusted contact they add. Unique per
/// test, so no test depends on another and the test clock may move freely.
class TestAccount {
  TestAccount._({
    required this.email,
    required this.password,
    required this.contactEmail,
    required this.secondContactEmail,
  });

  /// A fixed account, for a run on a database of its own (the store screenshots, whose
  /// names and addresses are shown on screen and must be fictional and tidy).
  const TestAccount.fixed({
    required this.email,
    required this.password,
    required this.contactEmail,
    this.secondContactEmail = 'unused@example.com',
  });

  factory TestAccount.fresh() {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return TestAccount._(
      email: 'it+$stamp@example.com',
      password: 'integration glacier $stamp maple',
      contactEmail: 'mom+$stamp@example.com',
      secondContactEmail: 'brother+$stamp@example.com',
    );
  }

  static const name = 'Iris Tester';
  static const contactName = 'Mom';

  /// The second trusted contact of the tests that need two (a premium account).
  static const secondContactName = 'Brother';

  final String email;
  final String password;
  final String contactEmail;
  final String secondContactEmail;
}

/// A test with a [Harness] whose failures always say what the screen and the server held,
/// whatever raised them (a wait that timed out, an `expect`, an exception from the app).
void integrationTest(
  String description,
  Backend backend,
  Future<void> Function(Harness h) body,
) {
  testWidgets(description, (tester) async {
    final h = Harness(tester, backend);
    try {
      await body(h);
    } on Object catch (error) {
      // `Harness.fail` already attached the screen and the server state.
      final reported =
          error is TestFailure &&
          (error.message ?? '').contains('--- screen ---');
      if (!reported) {
        final server = await backend.describe(h.probe);
        debugPrint(
          'INTEGRATION FAILURE (${error.runtimeType}): $description\n'
          '--- screen ---\n${h.screenText()}\n--- server ---\n  $server',
        );
      }
      rethrow;
    }
  });
}

/// The app under test, the backend beside it, and the helpers that make a real run on an
/// emulator bounded and explainable.
///
/// Waiting is always "pump frames until the screen shows X, up to a timeout": real I/O
/// happens while frames are pumped, nothing sleeps for a fixed time, and a timeout reports
/// what the screen said and what the server held (and `tool/integration.sh` adds the tail
/// of the worker log, which only the host can read).
class Harness {
  Harness(this.tester, this.backend);

  final WidgetTester tester;
  final Backend backend;

  /// A session of the tests' own for reading server state; set once the account exists.
  ProbeSession? probe;

  static const _frame = Duration(milliseconds: 250);

  /// Starts the real app (the dev flavor's providers: real API client, secure storage,
  /// preferences and device plugins) on a **signed-out, empty** phone. Anything the
  /// previous test left in secure storage or preferences is wiped first, and the provider
  /// scope is new, so the app starts exactly as after a fresh install.
  Future<void> launch({List<Override> overrides = const []}) async {
    await FlutterSecureStore().deleteAll();
    await PreferencesStore(SharedPreferencesAsync()).clear();
    final config = AppConfig.fromEnvironment();
    final info = ClientInfo.fromPackageInfo(await PackageInfo.fromPlatform());
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        // The same as main(): failed loads show a Retry button, no silent retry loop.
        retry: (retryCount, error) => null,
        overrides: [
          appConfigProvider.overrideWithValue(config),
          clientInfoProvider.overrideWithValue(info),
          ...overrides,
        ],
        child: const AfterMeApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  ProviderContainer get container =>
      ProviderScope.containerOf(tester.element(find.byType(AfterMeApp)));

  // --- what is on the screen ------------------------------------------------------

  /// Every visible text, for failure messages.
  String screenText() {
    final texts = <String>[];
    for (final element in find.byType(Text).evaluate()) {
      final widget = element.widget as Text;
      final value = widget.data ?? widget.textSpan?.toPlainText();
      if (value != null && value.trim().isNotEmpty) {
        texts.add(value.trim());
      }
    }
    final shown = texts.take(70).join(' | ');
    return shown.isEmpty ? '(no text on screen)' : shown;
  }

  /// Fails the test with the screen and the server state attached.
  Future<Never> fail(String what) async {
    final server = await backend.describe(probe);
    final message =
        '$what\n--- screen ---\n${screenText()}\n--- server ---\n  $server';
    debugPrint('INTEGRATION FAILURE: $message');
    throw TestFailure(message);
  }

  // --- waiting ----------------------------------------------------------------------

  Future<void> pump([Duration duration = _frame]) => tester.pump(duration);

  /// Pumps frames until [finder] matches. [onPoll] (for example a Home refresh) runs
  /// about every [pollEvery] while waiting.
  Future<void> waitFor(
    Finder finder, {
    String? reason,
    Duration timeout = const Duration(seconds: 20),
    Future<void> Function()? onPoll,
    Duration pollEvery = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        await fail(
          'Timed out after ${timeout.inSeconds}s waiting for '
          '${reason ?? finder}.',
        );
      }
      if (onPoll != null && DateTime.now().difference(lastPoll) >= pollEvery) {
        lastPoll = DateTime.now();
        try {
          await onPoll();
        } on Object catch (error) {
          debugPrint('poll failed (will retry): $error');
        }
      }
      await tester.pump(_frame);
    }
    // Let a route transition that brought it in finish (about 300 ms).
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// Pumps frames until [finder] no longer matches.
  Future<void> waitUntilAbsent(
    Finder finder, {
    String? reason,
    Duration timeout = const Duration(seconds: 20),
    Future<void> Function()? onPoll,
    Duration pollEvery = const Duration(milliseconds: 1500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var lastPoll = DateTime.fromMillisecondsSinceEpoch(0);
    while (finder.evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        await fail(
          'Timed out after ${timeout.inSeconds}s waiting for '
          '${reason ?? finder} to go away.',
        );
      }
      if (onPoll != null && DateTime.now().difference(lastPoll) >= pollEvery) {
        lastPoll = DateTime.now();
        try {
          await onPoll();
        } on Object catch (error) {
          debugPrint('poll failed (will retry): $error');
        }
      }
      await tester.pump(_frame);
    }
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> waitForText(
    String text, {
    Duration timeout = const Duration(seconds: 20),
    Future<void> Function()? onPoll,
  }) => waitFor(
    find.text(text),
    reason: 'the text "$text"',
    timeout: timeout,
    onPoll: onPoll,
  );

  Future<void> waitForTextContaining(
    String text, {
    Duration timeout = const Duration(seconds: 20),
    Future<void> Function()? onPoll,
  }) => waitFor(
    find.textContaining(text),
    reason: 'a text containing "$text"',
    timeout: timeout,
    onPoll: onPoll,
  );

  /// Pumps for [duration] (screen settles, an unwanted change would show up).
  Future<void> settle([Duration duration = const Duration(seconds: 1)]) async {
    final end = DateTime.now().add(duration);
    while (DateTime.now().isBefore(end)) {
      await tester.pump(_frame);
    }
  }

  // --- acting -----------------------------------------------------------------------

  Future<void> tapFinder(Finder finder, {String? reason}) async {
    final what = reason ?? finder.toString();
    if (finder.evaluate().isEmpty) {
      await fail('Cannot tap $what: not on screen.');
    }
    await tester.ensureVisible(finder.first);
    // A page that has just been pushed is not tappable until its transition ends.
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (finder.hitTestable().evaluate().isEmpty) {
      if (DateTime.now().isAfter(deadline)) {
        await fail(
          'Cannot tap $what: it is on screen but nothing there can be '
          'tapped (covered, off-screen or still animating).',
        );
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(finder.hitTestable().first);
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> tapText(String text) =>
      tapFinder(find.text(text), reason: 'the text "$text"');

  /// A button by its label (a title or heading with the same words is not a button).
  Future<void> tapButton(String label) => tapFinder(
    find.ancestor(
      of: find.text(label),
      matching: find.bySubtype<ButtonStyleButton>(),
    ),
    reason: 'the "$label" button',
  );

  /// A destination of the bottom navigation bar.
  Future<void> tapTab(String label) => tapFinder(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
    reason: 'the "$label" tab',
  );

  Future<void> typeInto(String label, String value) async {
    final field = find.widgetWithText(TextField, label);
    if (field.evaluate().isEmpty) {
      await fail('Cannot type into the field "$label": not on screen.');
    }
    await tester.ensureVisible(field.first);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(field.first, value);
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// What pull-to-refresh does: reads the Home aggregate again.
  Future<void> refreshHome() =>
      container.read(homeControllerProvider.notifier).refresh();

  /// A real pull-to-refresh gesture on the screen that is showing.
  Future<void> pullToRefresh() async {
    await tester.fling(
      find.byType(RefreshIndicator).first,
      const Offset(0, 400),
      1000,
    );
    await tester.pump(const Duration(seconds: 1));
  }

  /// Fails when [finder] is on screen now.
  Future<void> expectAbsent(Finder finder, String what) async {
    if (finder.evaluate().isNotEmpty) {
      await fail('Expected $what to be absent, but it is on screen.');
    }
  }

  /// Fails when [finder] is not on screen now.
  Future<void> expectPresent(Finder finder, String what) async {
    if (finder.evaluate().isEmpty) {
      await fail('Expected $what on screen, but it is not.');
    }
  }
}
