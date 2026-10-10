import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/design_system/design_system.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  group('AppButton', () {
    for (final variant in AppButtonVariant.values) {
      testWidgets('$variant: enabled, tappable, at least 48 dp tall', (
        tester,
      ) async {
        var taps = 0;
        await tester.pumpWidget(
          wrapForTest(
            AppButton(
              label: 'Continue',
              variant: variant,
              onPressed: () => taps++,
            ),
          ),
        );
        await tester.tap(find.text('Continue'));
        expect(taps, 1);
        expect(
          tester.getSize(find.byType(AppButton)).height,
          greaterThanOrEqualTo(48),
        );
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });

      testWidgets(
        '$variant: loading shows progress, ignores taps, keeps label',
        (tester) async {
          var taps = 0;
          await tester.pumpWidget(
            wrapForTest(
              AppButton(
                label: 'Saving',
                variant: variant,
                isLoading: true,
                onPressed: () => taps++,
              ),
            ),
          );
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await tester.tap(find.text('Saving'), warnIfMissed: false);
          expect(taps, 0);
        },
      );
    }

    testWidgets('loading is announced, not only shown', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        wrapForTest(
          const AppButton(label: 'Saving', onPressed: null, isLoading: true),
        ),
      );
      final node = tester.getSemantics(find.byType(FilledButton));
      expect(node.label, allOf(contains('Saving'), contains('Loading')));

      await tester.pumpWidget(
        wrapForTest(const AppButton(label: 'Saving', onPressed: null)),
      );
      expect(
        tester.getSemantics(find.byType(FilledButton)).label,
        isNot(contains('Loading')),
      );
      handle.dispose();
    });

    testWidgets('named constructors, icon and expand', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          SizedBox(
            width: 300,
            child: Column(
              children: [
                AppButton.primary(
                  label: 'P',
                  icon: Icons.add,
                  expand: true,
                  onPressed: () {},
                ),
                AppButton.secondary(label: 'S', onPressed: () {}),
                const AppButton.text(label: 'T', onPressed: null),
              ],
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(tester.getSize(find.byType(FilledButton)).width, 300);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
    });
  });

  group('StatusBanner', () {
    for (final (kind, icon, kindLabel) in [
      (StatusBannerKind.ok, Icons.check_circle_outline_rounded, 'All good'),
      (StatusBannerKind.info, Icons.info_outline_rounded, 'Information'),
      (
        StatusBannerKind.attention,
        Icons.error_outline_rounded,
        'Needs your attention',
      ),
      (StatusBannerKind.escalation, Icons.campaign_outlined, 'Important'),
    ]) {
      for (final (themeName, theme) in [
        ('light', AppTheme.light()),
        ('dark', AppTheme.dark()),
      ]) {
        testWidgets('$kind ($themeName): icon + text + spoken kind, readable', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(
            wrapForTest(
              StatusBanner(
                kind: kind,
                title: 'Check-in due at 8:00 PM',
                message: 'Mom will be notified at 11:00 PM.',
                action: AppButton.text(label: 'Check in', onPressed: () {}),
              ),
              theme: theme,
            ),
          );
          expect(find.byIcon(icon), findsOneWidget);
          expect(find.text('Check-in due at 8:00 PM'), findsOneWidget);
          expect(
            find.text('Mom will be notified at 11:00 PM.'),
            findsOneWidget,
          );
          expect(find.bySemanticsLabel(RegExp(kindLabel)), findsWidgets);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }
    }
  });

  testWidgets('SectionCard renders title, subtitle, child and handles taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      wrapForTest(
        SectionCard(
          title: 'Next check-in',
          subtitle: 'Tomorrow · 8:00 PM',
          onTap: () => taps++,
          child: const Text('Body'),
        ),
      ),
    );
    expect(find.text('Next check-in'), findsOneWidget);
    expect(find.text('Tomorrow · 8:00 PM'), findsOneWidget);
    await tester.tap(find.text('Body'));
    expect(taps, 1);
  });

  testWidgets('EmptyState inside CenteredScrollView', (tester) async {
    await tester.pumpWidget(
      wrapForTest(
        CenteredScrollView(
          child: EmptyState(
            icon: Icons.people_outline_rounded,
            title: 'Nobody yet',
            message: 'Add someone.',
            action: AppButton.secondary(label: 'Add', onPressed: () {}),
          ),
        ),
      ),
    );
    expect(find.text('Nobody yet'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('AppTextField', () {
    testWidgets('shows label, hint, helper and inline error', (tester) async {
      String? changed;
      await tester.pumpWidget(
        wrapForTest(
          AppTextField(
            label: 'Email',
            hint: 'you@example.com',
            helperText: 'We never share it.',
            errorText: 'Enter a valid email address.',
            onChanged: (value) => changed = value,
          ),
        ),
      );
      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'a@b.c');
      expect(changed, 'a@b.c');
    });

    testWidgets('password field toggles visibility with an accessible button', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapForTest(const AppTextField(label: 'Password', obscureText: true)),
      );
      TextField field() => tester.widget<TextField>(find.byType(TextField));
      expect(field().obscureText, isTrue);
      expect(field().autocorrect, isFalse);
      expect(find.byTooltip('Show password'), findsOneWidget);

      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(field().obscureText, isFalse);
      expect(find.byTooltip('Hide password'), findsOneWidget);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    });

    testWidgets('disabled field and obscureText updates', (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const AppTextField(
            label: 'Password',
            obscureText: true,
            enabled: false,
          ),
        ),
      );
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.pumpWidget(
        wrapForTest(const AppTextField(label: 'Password')),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
    });
  });

  testWidgets('LoadingView announces its label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(wrapForTest(const LoadingView(label: 'Loading')));
    expect(find.text('Loading'), findsOneWidget);
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    handle.dispose();
  });

  group('failureMessage', () {
    final l10n = AppLocalizationsEn();
    test('maps every failure to calm copy', () {
      final cases = <AppFailure, String>{
        const NetworkFailure(): l10n.errorNetwork,
        const UnauthorizedFailure(code: 'session_revoked'):
            l10n.errorSessionExpired,
        const UnauthorizedFailure(code: 'unauthenticated'):
            l10n.errorSessionExpired,
        const UnauthorizedFailure(code: 'token_expired'):
            l10n.errorSessionExpired,
        const UnauthorizedFailure(): l10n.errorSessionExpired,
        const UnauthorizedFailure(code: 'invalid_credentials'):
            l10n.errorInvalidCredentials,
        const ForbiddenFailure(code: 'reauth_required'):
            l10n.errorReauthRequired,
        const ForbiddenFailure(code: 'email_unverified'):
            l10n.errorEmailUnverified,
        const ForbiddenFailure(code: 'plan_limit_reached'):
            l10n.errorPlanLimitReached,
        const ForbiddenFailure(): l10n.errorForbidden,
        const NotFoundFailure(): l10n.errorNotFound,
        const ConflictFailure(code: 'safe_required'): l10n.errorSafeRequired,
        const ConflictFailure(code: 'incident_open'): l10n.errorIncidentOpen,
        const ConflictFailure(code: 'precondition_failed'): l10n.errorStaleData,
        const ConflictFailure(code: 'precondition_required'):
            l10n.errorStaleData,
        const ConflictFailure(code: 'something_else'): l10n.errorConflict,
        const ConflictFailure(code: 'invalid_state'): l10n.errorInvalidState,
        const InvalidStateFailure(): l10n.errorInvalidState,
        const ActivationRequirementsFailure(requirements: ['no_contacts']):
            l10n.errorActivationRequirements,
        const ContactDuplicateFailure(): l10n.errorContactDuplicate,
        const CannotBeOwnEmailFailure(): l10n.errorOwnEmail,
        const PlanLimitFailure(limit: 1, current: 1, resource: 'contacts'):
            l10n.errorPlanLimitReached,
        const RateLimitedFailure(retryAfter: Duration(minutes: 60)):
            'Too many attempts. Try again in 60 minutes.',
        const RateLimitedFailure(retryAfter: Duration(minutes: 61)):
            'Too many attempts. Try again in about 2 hours.',
        const RateLimitedFailure(retryAfter: Duration(hours: 24)):
            'Too many attempts. Try again in about 24 hours.',
        const RateLimitedFailure(retryAfter: Duration(hours: 25)):
            'Too many attempts. Try again in about 2 days.',
        const ValidationFailure(code: 'invalid_code'): l10n.errorInvalidCode,
        const ValidationFailure(): l10n.errorValidation,
        const RateLimitedFailure(): l10n.errorRateLimited,
        const RateLimitedFailure(retryAfter: Duration(seconds: 30)):
            l10n.errorRateLimited,
        const RateLimitedFailure(retryAfter: Duration(seconds: 61)):
            'Too many attempts. Try again in 2 minutes.',
        const RateLimitedFailure(retryAfter: Duration(minutes: 1)):
            'Too many attempts. Try again in 1 minute.',
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)):
            'Too many attempts. Try again in 10 minutes.',
        const UpgradeRequiredFailure(): l10n.errorUpgradeRequired,
        const ServerFailure(statusCode: 500): l10n.errorServer,
        const UnknownFailure(): l10n.errorUnknown,
      };
      cases.forEach((failure, message) {
        expect(failureMessage(l10n, failure), message, reason: '$failure');
      });
    });

    test('a wrong password is not reported as an ended session', () {
      expect(
        failureMessage(
          l10n,
          const UnauthorizedFailure(code: 'invalid_credentials'),
        ),
        isNot(l10n.errorSessionExpired),
      );
    });

    test('never shows the server detail', () {
      const failure = ServerFailure(
        problem: ApiProblem(status: 500, detail: 'stack trace here'),
      );
      expect(failureMessage(l10n, failure), isNot(contains('stack trace')));
    });
  });

  group('ErrorView', () {
    testWidgets('transient failures offer a retry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(
        wrapForTest(
          ErrorView(failure: const NetworkFailure(), onRetry: () => retries++),
        ),
      );
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);
    });

    testWidgets('the message is its own live region, even inside a card', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final message = failureMessage(
        AppLocalizationsEn(),
        const NetworkFailure(),
      );
      await tester.pumpWidget(
        wrapForTest(
          const SectionCard(
            title: 'Card title',
            child: ErrorView(failure: NetworkFailure()),
          ),
        ),
      );

      final node = tester.getSemantics(find.text(message));
      expect(node, isSemantics(label: message, isLiveRegion: true));
      // The card's own node must not have become a live region.
      final title = tester.getSemantics(find.text('Card title'));
      expect(title, isNot(isSemantics(isLiveRegion: true)));
      expect(title.label, isNot(contains(message)));
      handle.dispose();
    });

    testWidgets('non-transient failures do not', (tester) async {
      for (final (failure, icon) in [
        (const UpgradeRequiredFailure(), Icons.system_update_outlined),
        (const UnauthorizedFailure(), Icons.lock_outline_rounded),
        (const NotFoundFailure(), Icons.info_outline_rounded),
      ]) {
        await tester.pumpWidget(
          wrapForTest(ErrorView(failure: failure, onRetry: () {})),
        );
        expect(find.text('Try again'), findsNothing);
        expect(find.byIcon(icon), findsOneWidget);
      }
      await tester.pumpWidget(
        wrapForTest(
          const ErrorView(
            failure: RateLimitedFailure(retryAfter: Duration(minutes: 10)),
          ),
        ),
      );
      expect(find.byIcon(Icons.hourglass_empty_rounded), findsOneWidget);
    });
  });

  test('AppLocalizations supports English', () {
    expect(
      AppLocalizations.supportedLocales.map((l) => l.languageCode),
      contains('en'),
    );
  });
}
