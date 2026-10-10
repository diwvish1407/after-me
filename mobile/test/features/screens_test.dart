import 'package:afterme/app/app.dart';
import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/design_system/check_in_button.dart';
import 'package:afterme/features/auth/presentation/sign_in_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/features/dev/presentation/design_gallery_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/instructions/presentation/instructions_screen.dart';
import 'package:afterme/features/onboarding/presentation/welcome_screen.dart';
import 'package:afterme/features/plan/presentation/plan_screen.dart';
import 'package:afterme/features/settings/presentation/about_screen.dart';
import 'package:afterme/features/settings/presentation/settings_screen.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

/// Pumps [screen] inside the real theme and localizations at [textScale].
Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen, {
  double textScale = 1,
  ThemeData? theme,
  AuthStatus? authStatus,
}) async {
  usePhoneScreen(tester);
  await tester.pumpWidget(
    ProviderScope(
      overrides: testOverrides(authStatus: authStatus),
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: screen,
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('welcome screen', () {
    testWidgets(
      'shows the product, tagline, the three cards, an enabled Get started and '
      'the disclaimer',
      (tester) async {
        await _pumpScreen(tester, const WelcomeScreen(showDevGallery: false));

        expect(find.text('AfterMe'), findsOneWidget);
        expect(
          find.text("If you can't answer, your instructions can."),
          findsOneWidget,
        );
        expect(find.textContaining('not an emergency service'), findsOneWidget);
        expect(
          find.text('Prepare today for what someone may need tomorrow.'),
          findsOneWidget,
        );
        final getStarted = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Get started'),
        );
        expect(getStarted.onPressed, isNotNull);
        expect(
          find.text('Design system gallery (developer build)'),
          findsNothing,
        );
      },
    );

    testWidgets('Next walks through the three cards', (tester) async {
      await _pumpScreen(tester, const WelcomeScreen(showDevGallery: false));
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.textContaining('Check in with one tap'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.textContaining('You decide who gets what'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Next'))
            .onPressed,
        isNull,
        reason: 'the slot stays, disabled, so focus is not lost',
      );
      await tester.tap(find.text('Back'));
      await tester.pump();
      expect(find.textContaining('Check in with one tap'), findsOneWidget);
    });

    testWidgets('the new card is announced as one live region after Next', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpScreen(tester, const WelcomeScreen(showDevGallery: false));
      await tester.tap(find.text('Next'));
      await tester.pump();
      final card = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Card 2 of 3\. Check in')),
      );
      expect(card.flagsCollection.isLiveRegion, isTrue);
      expect(find.bySemanticsLabel(RegExp('Check in with one tap')), findsOne);
      handle.dispose();
    });

    testWidgets('meets the accessibility guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpScreen(tester, const WelcomeScreen(showDevGallery: true));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });

  testWidgets('home (nothing set up yet) shows the checklist and a disabled '
      'check-in button with an explanation', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpScreen(
      tester,
      const HomeScreen(),
      authStatus: AuthStatus.signedIn,
    );
    await tester.pumpAndSettle();

    final button = tester.widget<CheckInButton>(find.byType(CheckInButton));
    expect(button.state, CheckInButtonState.disabled);
    expect(button.onPressed, isNull);
    expect(
      find.textContaining('Turn on check-ins to start checking in.'),
      findsOneWidget,
    );
    expect(find.text("Let's finish your plan"), findsOneWidget);
    expect(find.text('Add a trusted contact'), findsOneWidget);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    handle.dispose();
  });

  testWidgets('about shows the app version', (tester) async {
    await _pumpScreen(tester, const AboutScreen());
    expect(find.text('Version 0.1.0 (7)'), findsOneWidget);
  });

  group('key screens at 2.0 text scale render without overflow', () {
    final screens = <String, Widget>{
      'welcome': const WelcomeScreen(showDevGallery: true),
      'sign-in': const SignInScreen(),
      'home': const HomeScreen(),
      'people': const PeopleScreen(),
      'instructions': const InstructionsScreen(),
      'plan': const PlanScreen(),
      'settings': const SettingsScreen(),
    };
    for (final MapEntry(key: name, value: screen) in screens.entries) {
      for (final (themeName, theme) in [
        ('light', AppTheme.light()),
        ('dark', AppTheme.dark()),
      ]) {
        testWidgets('$name ($themeName)', (tester) async {
          await _pumpScreen(
            tester,
            screen,
            textScale: 2,
            theme: theme,
            authStatus: AuthStatus.signedIn,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('signed-in shell with navigation bar', (tester) async {
      usePhoneScreen(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        ProviderScope(
          overrides: testOverrides(authStatus: AuthStatus.signedIn),
          child: const AfterMeApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('shell navigation switches tabs (fake signed-in status)', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(authStatus: AuthStatus.signedIn),
        child: const AfterMeApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    for (final (label, type, index) in [
      ('People', PeopleScreen, 1),
      ('Instructions', InstructionsScreen, 2),
      ('Plan', PlanScreen, 3),
      ('Settings', SettingsScreen, 4),
      ('Home', HomeScreen, 0),
    ]) {
      await tester.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(type), findsOneWidget, reason: label);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        index,
      );
    }

    // Re-selecting the current tab keeps it.
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Home'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  group('design gallery', () {
    testWidgets('renders every component in light and dark', (tester) async {
      await _pumpScreen(tester, const DesignGalleryScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('Light'), findsOneWidget);
      // ListView builds lazily; scroll to the dark section.
      final list = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(find.text('Dark'), 400, scrollable: list);
      expect(find.text('Dark'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Error views').last,
        400,
        scrollable: list,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows all check-in states', (tester) async {
      await _pumpScreen(tester, const DesignGalleryScreen());
      await tester.scrollUntilVisible(
        find.byType(CheckInButton).first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final states = tester
          .widgetList<CheckInButton>(
            find.byType(CheckInButton, skipOffstage: false),
          )
          .map((b) => b.state)
          .toSet();
      expect(states, containsAll(CheckInButtonState.values));
    });
  });
}
