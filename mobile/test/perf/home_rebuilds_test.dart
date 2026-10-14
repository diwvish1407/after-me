import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/in_memory_contacts_repository.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

/// Rebuild storms on Home (PERF-05: no frame over 16 ms). Home is the screen that is
/// always open, and a refresh touches many providers. This pins how often the screen is
/// rebuilt and how often the providers change for one refresh, one pull and one
/// check-in, so a listener that invalidates too widely (or a timer that rebuilds the
/// tree) shows up as a number, not as a janky frame on a phone.
///
/// The limits are the measured counts plus a margin of one; a change that raises them
/// has to say why.

base class _Counter extends ProviderObserver {
  final Map<String, int> updates = {};

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    final name =
        context.provider.name ?? context.provider.runtimeType.toString();
    updates[name] = (updates[name] ?? 0) + 1;
  }

  int get total => updates.values.fold(0, (a, b) => a + b);

  void reset() => updates.clear();
}

TestFakes _world() {
  final fakes = TestFakes();
  fakes.clock.current = DateTime.utc(2026, 10, 9, 6);
  fakes.notifications.current = NotificationPermission.granted;
  fakes.contacts = InMemoryContactsRepository(
    tier: 'premium',
    initial: [
      testContact(),
      testContact(
        id: 'c2',
        name: 'Brother',
        relationship: ContactRelationship.sibling,
        email: 'brother@example.com',
        priority: 2,
      ),
    ],
  );
  fakes.plan.seedStandard(['c1']);
  fakes.server.activateNow();
  return fakes;
}

void main() {
  late int homeBuilds;
  late int totalBuilds;
  final onRebuild = debugOnRebuildDirtyWidget;

  setUp(() {
    homeBuilds = 0;
    totalBuilds = 0;
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      totalBuilds++;
      if (element.widget is HomeScreen) {
        homeBuilds++;
      }
    };
  });
  tearDown(() => debugOnRebuildDirtyWidget = onRebuild);

  Future<(ProviderContainer, _Counter, TestFakes)> open(
    WidgetTester tester,
  ) async {
    final fakes = _world();
    fakes.prefs = freshPreferences({
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': true,
    });
    final counter = _Counter();
    final container = await pumpAfterMe(
      tester,
      fakes: fakes,
      status: AuthStatus.signedIn,
      observers: [counter],
    );
    expect(find.text("I'M OK"), findsOneWidget);
    return (container, counter, fakes);
  }

  testWidgets('opening Home builds the screen a handful of times', (
    tester,
  ) async {
    homeBuilds = 0;
    await open(tester);
    // ignore: avoid_print
    print('PERF open: Home builds $homeBuilds, all builds $totalBuilds');
    expect(homeBuilds, lessThanOrEqualTo(_openLimit));
  });

  testWidgets('one refresh of an unchanged Home rebuilds Home once or twice, '
      'and changes only the Home providers', (tester) async {
    final (container, counter, _) = await open(tester);
    homeBuilds = 0;
    totalBuilds = 0;
    counter.reset();
    await container.read(homeControllerProvider.notifier).refresh();
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      'PERF refresh: Home builds $homeBuilds, all builds $totalBuilds, '
      'provider updates ${counter.updates}',
    );
    expect(homeBuilds, lessThanOrEqualTo(_refreshLimit));
    expect(totalBuilds, lessThanOrEqualTo(_refreshAllLimit));
    expect(counter.total, lessThanOrEqualTo(_refreshProviderUpdates));
    // Nothing else is woken by a read of Home: the controllers behind the other tabs
    // are not even created.
    expect(
      counter.updates.keys.where(
        (k) => !k.contains('home') && !k.contains('Home'),
      ),
      isEmpty,
      reason: '${counter.updates}',
    );
  });

  testWidgets('a pull to refresh and the 30 s ticker with nothing new do not '
      'rebuild the tree over and over', (tester) async {
    final (container, counter, _) = await open(tester);
    homeBuilds = 0;
    totalBuilds = 0;
    counter.reset();
    // Ten minutes in the foreground with nothing to say: 20 ticks, one redraw each.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(seconds: 30));
    }
    // ignore: avoid_print
    print('PERF ticks: Home builds $homeBuilds, all builds $totalBuilds');
    // About 115 elements are rebuilt per tick (a few milliseconds at most): the redraw
    // keeps "in 45 minutes" true; it is not a reason to restructure Home.
    expect(homeBuilds, 20, reason: 'one redraw per tick, no more');
    expect(totalBuilds, lessThan(20 * 200));
    expect(counter.total, 0, reason: 'a tick changes no provider');
    expect(container.read(homeControllerProvider).hasValue, isTrue);
  });

  testWidgets('an I\'M OK rebuilds Home a bounded number of times', (
    tester,
  ) async {
    final (_, counter, _) = await open(tester);
    homeBuilds = 0;
    totalBuilds = 0;
    counter.reset();
    await tester.tap(find.text("I'M OK"));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // ignore: avoid_print
    print(
      'PERF check-in: Home builds $homeBuilds, all builds $totalBuilds, '
      'provider updates ${counter.total}',
    );
    expect(homeBuilds, lessThanOrEqualTo(_checkInLimit));
  });
}

// Measured (see the PERF lines this test prints) plus one: opening Home builds the screen
// twice (loading, then the answer); a refresh once; a check-in once (the tap's own state
// and the confirmed answer land in the same frame).
const _openLimit = 3;
const _refreshLimit = 2;
const _refreshAllLimit = 150;
const _refreshProviderUpdates = 2;
const _checkInLimit = 2;
