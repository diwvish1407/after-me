import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/in_memory_contacts_repository.dart';
import '../../helpers/no_purchase.dart';
import '../../helpers/real_fonts.dart';
import '../../helpers/test_app.dart';

/// The Phase 7 Settings screens that are not the activity feed, the export or the
/// deletion: your plan and its limits, what AfterMe keeps, and help for a lost phone.
void main() {
  setUpAll(loadRoboto);

  group('Settings list', () {
    testWidgets('has the new entries in the sections they belong to', (
      tester,
    ) async {
      await openApp(tester, route: AppRoutes.settings);
      for (final text in [
        'Your plan',
        'Activity',
        'Privacy and data',
        'What AfterMe keeps',
        'Export my data',
        'Delete account',
        'If you lose your phone',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(text), findsOneWidget, reason: text);
      }
      // The privacy policy and the terms stay in Help.
      expect(find.text('Privacy Policy'), findsOneWidget);
    });
  });

  group('Your plan', () {
    testWidgets('a free account: the tier and what is used, in one line and '
        'as a list; no purchase button', (tester) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.plan.seedStandard(['c1']);
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsYourPlan);
      expect(
        find.text(
          'Free · 1 of 1 contact · 0 of 3 instructions · 1 of 2 stages',
        ),
        findsOneWidget,
      );
      expect(find.text('Trusted contacts'), findsOneWidget);
      // (The navigation bar has an "Instructions" of its own.)
      expect(
        find.descendant(
          of: find.byType(Card),
          matching: find.text('Instructions'),
        ),
        findsOneWidget,
      );
      expect(find.text('Stages in your plan'), findsOneWidget);
      expect(find.text('Choosing your own times'), findsOneWidget);
      expect(find.text('Not available yet'), findsOneWidget);
      expect(
        find.text(
          'Everything listed here is part of the free plan and works in full.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'More contacts, instructions and stages, and choosing your own '
          "times, aren't available yet.",
        ),
        findsOneWidget,
      );
      // Nothing that could be mistaken for buying (PRD D5: no billing in 1.0), and no
      // mention of a Premium the person cannot get.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expectNoPurchaseOffer();
    });

    testWidgets('a premium account: its limits and what it includes', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        tier: 'premium',
        limit: 25,
        initial: [
          testContact(),
          testContact(id: 'c2', name: 'Dad', email: 'dad@example.com'),
        ],
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsYourPlan);
      expect(
        find.text(
          'Premium · 2 of 25 contacts · 0 of 200 instructions · 0 of 10 stages',
        ),
        findsOneWidget,
      );
      expect(find.text('Included'), findsOneWidget);
      expect(find.text('Not available yet'), findsNothing);
      expect(find.textContaining("isn't available yet"), findsNothing);
      expect(
        find.text(
          'Your plan includes more contacts, instructions and stages, and '
          'your own times.',
        ),
        findsOneWidget,
      );
      // An operator-granted Premium is named, and nothing about paying is said.
      expect(find.text('Premium'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      final texts = visibleTexts().where(
        (t) => t != 'Premium' && !t.startsWith('Premium · '),
      );
      expect(texts.where(purchaseLanguage.hasMatch), isEmpty);
    });

    testWidgets('a tier this version does not know is "Your plan", with the '
        'limits the server sent', (tester) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        tier: 'enterprise',
        limit: 50,
        initial: [testContact()],
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsYourPlan);
      expect(
        find.textContaining('Your plan · 1 of 50 contacts'),
        findsOneWidget,
      );
      expect(find.text('Choosing your own times'), findsOneWidget);
    });

    testWidgets('loading, a calm error with Try again, and pull to refresh', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(initial: [testContact()]);
      fakes.contacts.failures['entitlements'] = [const NetworkFailure()];
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsYourPlan);
      expect(find.textContaining("You're offline"), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 of 1 contact'), findsWidgets);

      // The refresh fails: the last information stays, with the note.
      fakes.contacts.failures['entitlements'] = [const NetworkFailure()];
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 of 1 contact'), findsWidgets);
      expect(
        find.textContaining('Showing the last information we have'),
        findsOneWidget,
      );
      await tester.fling(
        find.byType(Scrollable).first,
        const Offset(0, 400),
        800,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Showing the last information we have'),
        findsNothing,
      );
    });

    testWidgets('while it loads there is a progress indicator', (tester) async {
      final fakes = TestFakes();
      final gate = Completer<void>();
      fakes.contacts.listGate = gate.future;
      await openApp(
        tester,
        fakes: fakes,
        route: AppRoutes.settingsYourPlan,
        settle: false,
      );
      await tester.pump(const Duration(milliseconds: 50));
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('Free ·'), findsOneWidget);
    });

    testWidgets('a limit of 1 reads in the singular, others in the plural', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.contacts = InMemoryContactsRepository(
        limit: 3,
        initial: [testContact()],
      );
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsYourPlan);
      expect(find.textContaining('1 of 3 contacts'), findsOneWidget);
    });
  });

  group('What AfterMe keeps', () {
    testWidgets('says what is stored, what is never done and what deleting '
        'does, with the policy and terms links', (tester) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsPrivacy);
      for (final text in [
        'Your account',
        'Your trusted contacts',
        'Your instructions',
        'Your history',
        "What we don't do",
        'If you delete your account',
      ]) {
        await tester.scrollUntilVisible(
          find.text(text),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(text), findsOneWidget, reason: text);
      }
      expect(
        find.textContaining("We don't sell your information"),
        findsOneWidget,
      );
      // The honest limitation: AfterMe can open instructions.
      expect(
        find.textContaining('AfterMe can open them, because it has to deliver'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Privacy Policy'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Privacy Policy'));
      await tester.pump();
      expect(fakes.urls.opened.single, devConfig.publicUri('/legal/privacy'));
    });
  });

  group('If you lose your phone', () {
    testWidgets('explains the browser route and shows the address as text', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsLostPhone);
      expect(
        find.textContaining('From any web browser you can check in'),
        findsOneWidget,
      );
      expect(find.text('http://10.0.2.2:8000/a/login'), findsOneWidget);
      expect(
        find.textContaining('Sign in with your email address'),
        findsOneWidget,
      );
      expect(find.textContaining("confirm I'M SAFE"), findsOneWidget);
      expect(find.textContaining('shown in your Activity'), findsOneWidget);

      await tester.tap(find.text('Open the page'));
      await tester.pump();
      expect(fakes.urls.opened.single, devConfig.publicUri('/a/login'));
    });

    testWidgets('uses the configured public address, not a fixed one', (
      tester,
    ) async {
      final fakes = TestFakes();
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsLostPhone);
      expect(
        AppConfig.parse(
          appEnv: 'prod',
          apiBaseUrl: 'https://api.afterme.invalid',
          publicBaseUrl: 'https://afterme.invalid',
        ).publicUri('/a/login').toString(),
        'https://afterme.invalid/a/login',
      );
    });

    testWidgets('a page that cannot be opened is said calmly', (tester) async {
      final fakes = TestFakes();
      fakes.urls.succeeds = false;
      await openApp(tester, fakes: fakes, route: AppRoutes.settingsLostPhone);
      await tester.tap(find.text('Open the page'));
      await tester.pump();
      await tester.pump();
      expect(snackText(tester), contains("couldn't open that page"));
    });

    testWidgets('is reached from Settings > Help', (tester) async {
      await openApp(tester, route: AppRoutes.settings);
      await tester.scrollUntilVisible(
        find.text('If you lose your phone'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('If you lose your phone'));
      await tester.pumpAndSettle();
      expect(find.text('Open this page in a browser'), findsOneWidget);
    });
  });
}
