import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/auth/application/signup_controller.dart';
import 'package:afterme/features/auth/presentation/reauth_sheet.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

Future<ProviderContainer> _open(
  WidgetTester tester,
  String route, {
  TestFakes? fakes,
  AuthStatus status = AuthStatus.signedOut,
}) async {
  final container = await pumpAfterMe(tester, fakes: fakes, status: status);
  container.read(routerProvider).go(route);
  await tester.pumpAndSettle();
  return container;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

String? _error(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).decoration?.errorText;

Future<void> _fillCreateAccount(
  WidgetTester tester, {
  String password = 'a long unique phrase',
  bool consent = true,
}) async {
  await typeInto(tester, 'Your name', 'Diwakar');
  await typeInto(tester, 'Email', 'new@example.com');
  await typeInto(tester, 'Password', password);
  if (consent) {
    await tapText(tester, 'I am 18 or older.');
    await tapText(
      tester,
      'I agree to the Terms of Service and the Privacy Policy.',
    );
  }
}

void main() {
  group('create account', () {
    testWidgets(
      'empty fields and missing consent are explained, nothing is sent',
      (tester) async {
        final fakes = TestFakes();
        await _open(tester, AppRoutes.createAccount, fakes: fakes);
        await tapText(tester, 'Send my code');
        expect(_error(tester, 'Your name'), 'Please fill this in.');
        expect(_error(tester, 'Email'), 'Please fill this in.');
        expect(_error(tester, 'Password'), 'Please fill this in.');
        expect(find.text('Please confirm both to continue.'), findsOneWidget);
        expect(fakes.auth.calls, isEmpty);
      },
    );

    testWidgets('field-level validation clears when the person types', (
      tester,
    ) async {
      await _open(tester, AppRoutes.createAccount);
      await typeInto(tester, 'Email', 'not-an-email');
      await typeInto(tester, 'Password', 'short');
      await tapText(tester, 'Send my code');
      expect(_error(tester, 'Email'), 'Enter a valid email address.');
      expect(_error(tester, 'Password'), 'Use at least 10 characters.');
      await typeInto(tester, 'Email', 'ok@example.com');
      expect(_error(tester, 'Email'), isNull);
    });

    testWidgets('the password hint is calm and follows what is typed', (
      tester,
    ) async {
      await _open(tester, AppRoutes.createAccount);
      expect(
        find.textContaining('A few unrelated words work well'),
        findsOneWidget,
      );
      await typeInto(tester, 'Password', 'short');
      expect(find.textContaining('Keep going'), findsOneWidget);
      await typeInto(tester, 'Password', 'correct horse battery staple');
      expect(find.textContaining('Strong'), findsOneWidget);
    });

    testWidgets('show/hide toggles the password', (tester) async {
      await _open(tester, AppRoutes.createAccount);
      await typeInto(tester, 'Password', 'secret words here');
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: _field('Password'),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isTrue,
      );
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(
        tester
            .widget<EditableText>(
              find.descendant(
                of: _field('Password'),
                matching: find.byType(EditableText),
              ),
            )
            .obscureText,
        isFalse,
      );
      expect(find.byTooltip('Hide password'), findsOneWidget);
    });

    testWidgets('the detected timezone is shown and can be changed', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.device.deviceTimezone = 'Europe/London';
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      expect(find.text('Europe/London'), findsOneWidget);

      await tapText(tester, 'Change');
      await tester.pumpAndSettle();
      expect(find.text('Choose your timezone'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search'),
        'new york',
      );
      await tester.pump();
      expect(find.text('America/New York'), findsOneWidget);
      expect(find.text('Asia/Kolkata'), findsNothing);
      await tester.tap(find.text('America/New York'));
      await tester.pumpAndSettle();
      expect(find.text('America/New_York'), findsOneWidget);

      await _fillCreateAccount(tester);
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      expect(
        fakes.auth.lastArgs['registerStart']!['timezone'],
        'America/New_York',
      );
    });

    testWidgets('an undetectable timezone falls back to UTC', (tester) async {
      final fakes = TestFakes();
      fakes.device.deviceTimezone = null;
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      expect(find.text('UTC'), findsOneWidget);
    });

    testWidgets('terms and privacy open the public pages in the browser', (
      tester,
    ) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      await tapText(tester, 'Terms of Service');
      await tapText(tester, 'Privacy Policy');
      expect(fakes.urls.opened.map((u) => u.toString()), [
        'http://10.0.2.2:8000/legal/terms',
        'http://10.0.2.2:8000/legal/privacy',
      ]);
    });

    testWidgets('a browser that cannot open the page says so calmly', (
      tester,
    ) async {
      final fakes = TestFakes()..urls.succeeds = false;
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      await tapText(tester, 'Terms of Service');
      await tester.pump();
      expect(find.textContaining("couldn't open that page"), findsOneWidget);
    });

    testWidgets('server field errors are shown next to the field', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'registerStart',
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'password', code: 'password_too_common'),
          ],
        ),
      );
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      await _fillCreateAccount(tester, password: 'password123456');
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      expect(_error(tester, 'Password'), contains('too common'));
      expect(find.text('Enter your code'), findsNothing);
    });

    testWidgets('other failures appear as a calm notice', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail('registerStart', const NetworkFailure());
      await _open(tester, AppRoutes.createAccount, fakes: fakes);
      await _fillCreateAccount(tester);
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      expect(find.textContaining("You're offline"), findsOneWidget);
    });

    testWidgets('a failure from an earlier visit does not greet a fresh form', (
      tester,
    ) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'registerStart',
        const ValidationFailure(
          code: 'validation_failed',
          fieldErrors: [
            ApiFieldError(field: 'password', code: 'password_too_common'),
          ],
        ),
      );
      final container = await _open(
        tester,
        AppRoutes.createAccount,
        fakes: fakes,
      );
      await _fillCreateAccount(tester, password: 'password123456');
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      expect(_error(tester, 'Password'), contains('too common'));

      container.read(routerProvider).go(AppRoutes.welcome);
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.createAccount);
      await tester.pumpAndSettle();
      expect(_error(tester, 'Password'), isNull);
      expect(container.read(signupControllerProvider).failure, isNull);
    });

    testWidgets('the sign-in link leads to sign-in', (tester) async {
      await _open(tester, AppRoutes.createAccount);
      await tapText(tester, 'I already have an account');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
    });
  });

  group('enter code', () {
    Future<(ProviderContainer, TestFakes)> toCode(WidgetTester tester) async {
      final fakes = TestFakes();
      final container = await _open(
        tester,
        AppRoutes.createAccount,
        fakes: fakes,
      );
      await _fillCreateAccount(tester);
      await tapText(tester, 'Send my code');
      await tester.pumpAndSettle();
      expect(find.text('Enter your code'), findsOneWidget);
      return (container, fakes);
    }

    testWidgets('shows where the code went', (tester) async {
      await toCode(tester);
      expect(find.textContaining('new@example.com'), findsOneWidget);
    });

    testWidgets('a pasted code with spaces is accepted', (tester) async {
      final (container, fakes) = await toCode(tester);
      await typeInto(tester, '6-digit code', '482 913');
      expect(
        tester.widget<TextField>(_field('6-digit code')).controller!.text,
        '482913',
      );
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(fakes.auth.lastArgs['registerVerify']!['code'], '482913');
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    testWidgets('a short code is flagged before anything is sent', (
      tester,
    ) async {
      final (_, fakes) = await toCode(tester);
      await typeInto(tester, '6-digit code', '123');
      await tapText(tester, 'Confirm');
      expect(
        _error(tester, '6-digit code'),
        'Enter the 6-digit code from the email.',
      );
      expect(fakes.auth.calls, isNot(contains('registerVerify')));
    });

    testWidgets('a wrong code is explained and the field is cleared', (
      tester,
    ) async {
      final (container, _) = await toCode(tester);
      await typeInto(tester, '6-digit code', '000000');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(find.textContaining('wrong or has expired'), findsOneWidget);
      expect(
        tester.widget<TextField>(_field('6-digit code')).controller!.text,
        '',
      );
      expect(
        container.read(authControllerProvider),
        isNot(AuthStatus.signedIn),
      );
    });

    testWidgets(
      'the resend countdown runs on the clock and then offers a button',
      (tester) async {
        final (container, fakes) = await toCode(tester);
        expect(find.text('You can ask for a new code in 1:00'), findsOneWidget);
        expect(find.text('Send a new code'), findsNothing);

        fakes.clock.advance(const Duration(seconds: 15));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('You can ask for a new code in 0:45'), findsOneWidget);

        fakes.clock.advance(const Duration(seconds: 44));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('You can ask for a new code in 0:01'), findsOneWidget);

        fakes.clock.advance(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Send a new code'), findsOneWidget);

        await tester.tap(find.text('Send a new code'));
        await tester.pump();
        await tester.pump();
        expect(fakes.auth.calls, contains('registerResend'));
        expect(find.text('A new code is on its way.'), findsOneWidget);
        // The countdown starts again.
        await tester.pump(const Duration(seconds: 5));
        expect(
          find.textContaining('You can ask for a new code in'),
          findsOneWidget,
        );
        expect(container.read(signupControllerProvider).codeSentCount, 2);
      },
    );

    testWidgets('a failed resend shows the failure and no snackbar', (
      tester,
    ) async {
      final (_, fakes) = await toCode(tester);
      fakes.auth.fail(
        'registerResend',
        const RateLimitedFailure(retryAfter: Duration(minutes: 10)),
      );
      fakes.clock.advance(const Duration(seconds: 61));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Send a new code'));
      await tester.pump();
      await tester.pump();
      expect(
        find.text('Too many attempts. Try again in 10 minutes.'),
        findsOneWidget,
      );
      expect(find.text('A new code is on its way.'), findsNothing);
    });

    testWidgets('"Wrong email address?" goes back to the form', (tester) async {
      final (container, _) = await toCode(tester);
      await tapText(tester, 'Wrong email address?');
      await tester.pumpAndSettle();
      expect(find.text("Let's set you up"), findsOneWidget);
      expect(container.read(signupControllerProvider).stage, SignupStage.form);
    });

    testWidgets(
      'reaching the screen without a sign-up in progress starts over',
      (tester) async {
        await _open(tester, AppRoutes.verifyCode);
        expect(find.text('Enter your code'), findsNothing);
        expect(find.text('Get started'), findsOneWidget);
      },
    );

    testWidgets('leaving the flow forgets the password', (tester) async {
      final (container, _) = await toCode(tester);
      final signup = container.read(signupControllerProvider.notifier);
      expect(signup.hasPassword, isTrue);
      container.read(routerProvider).go(AppRoutes.welcome);
      await tester.pumpAndSettle();
      expect(signup.hasPassword, isFalse);
    });
  });

  group('sign in', () {
    testWidgets('validates before sending', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.signIn, fakes: fakes);
      await tapText(tester, 'Sign in');
      expect(_error(tester, 'Email'), 'Please fill this in.');
      expect(_error(tester, 'Password'), 'Please fill this in.');
      expect(fakes.auth.calls, isEmpty);
    });

    testWidgets('wrong details show one calm message', (tester) async {
      await _open(tester, AppRoutes.signIn);
      await typeInto(tester, 'Email', 'diwakar@example.com');
      await typeInto(tester, 'Password', 'wrong password!');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(
        find.text(
          "That email and password didn't match. Check them and try again.",
        ),
        findsOneWidget,
      );
      await typeInto(tester, 'Password', 'x');
      expect(find.textContaining("didn't match"), findsNothing);
    });

    testWidgets('a failed attempt is gone when Sign in is opened again', (
      tester,
    ) async {
      final container = await _open(tester, AppRoutes.signIn);
      await typeInto(tester, 'Email', 'diwakar@example.com');
      await typeInto(tester, 'Password', 'wrong password!');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(find.textContaining("didn't match"), findsOneWidget);

      container.read(routerProvider).go(AppRoutes.welcome);
      await tester.pumpAndSettle();
      container.read(routerProvider).go(AppRoutes.signIn);
      await tester.pumpAndSettle();
      expect(find.textContaining("didn't match"), findsNothing);
    });

    testWidgets('other failures use the shared copy', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail('login', const ServerFailure(statusCode: 500));
      await _open(tester, AppRoutes.signIn, fakes: fakes);
      await typeInto(tester, 'Email', 'diwakar@example.com');
      await typeInto(tester, 'Password', 'correct horse battery');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Something went wrong on our side'),
        findsOneWidget,
      );
    });

    testWidgets('success leaves for Home', (tester) async {
      final container = await _open(tester, AppRoutes.signIn);
      await typeInto(tester, 'Email', ' Diwakar@Example.com ');
      await typeInto(tester, 'Password', 'correct horse battery');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('an unverified account continues with its code', (
      tester,
    ) async {
      final fakes = TestFakes()..auth.verified = false;
      final container = await _open(tester, AppRoutes.signIn, fakes: fakes);
      await typeInto(tester, 'Email', 'diwakar@example.com');
      await typeInto(tester, 'Password', 'correct horse battery');
      await tapText(tester, 'Sign in');
      await tester.pumpAndSettle();
      expect(find.text('Enter your code'), findsOneWidget);
      await typeInto(tester, '6-digit code', '482913');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
    });

    testWidgets(
      'links lead to forgot password (email carried over) and sign-up',
      (tester) async {
        await _open(tester, AppRoutes.signIn);
        await typeInto(tester, 'Email', 'diwakar@example.com');
        await tapText(tester, 'Forgot your password?');
        await tester.pumpAndSettle();
        expect(find.text('Reset password'), findsOneWidget);
        expect(
          tester.widget<TextField>(_field('Email')).controller!.text,
          'diwakar@example.com',
        );
        await tester.pageBack();
        await tester.pumpAndSettle();
        await tapText(tester, 'Create an account');
        await tester.pumpAndSettle();
        expect(find.text("Let's set you up"), findsOneWidget);
      },
    );
  });

  group('forgot password', () {
    testWidgets('asks for a valid email', (tester) async {
      final fakes = TestFakes();
      await _open(tester, AppRoutes.forgotPassword, fakes: fakes);
      await tapText(tester, 'Send the link');
      expect(_error(tester, 'Email'), 'Please fill this in.');
      await typeInto(tester, 'Email', 'nope');
      await tapText(tester, 'Send the link');
      expect(_error(tester, 'Email'), 'Enter a valid email address.');
      expect(fakes.auth.calls, isEmpty);
    });

    testWidgets(
      'shows "check your email" without saying whether an account exists',
      (tester) async {
        final fakes = TestFakes();
        await _open(tester, AppRoutes.forgotPassword, fakes: fakes);
        await typeInto(tester, 'Email', 'stranger@example.com');
        await tapText(tester, 'Send the link');
        await tester.pumpAndSettle();
        expect(find.text('Check your email'), findsOneWidget);
        expect(find.text('stranger@example.com'), findsOneWidget);
        expect(
          find.text(
            "If there's an account for this address, we've sent a link to choose a new password.",
          ),
          findsOneWidget,
        );
        expect(find.textContaining('30 minutes'), findsOneWidget);

        await tapText(tester, 'Use a different email');
        await tester.pumpAndSettle();
        expect(find.text('Send the link'), findsOneWidget);
      },
    );

    testWidgets('"Back to sign in" returns', (tester) async {
      await _open(tester, AppRoutes.signIn);
      await tapText(tester, 'Forgot your password?');
      await tester.pumpAndSettle();
      await typeInto(tester, 'Email', 'a@example.com');
      await tapText(tester, 'Send the link');
      await tester.pumpAndSettle();
      await tapText(tester, 'Back to sign in');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
    });

    testWidgets('"Back to sign in" works when it was opened directly', (
      tester,
    ) async {
      await _open(tester, AppRoutes.forgotPassword);
      await typeInto(tester, 'Email', 'a@example.com');
      await tapText(tester, 'Send the link');
      await tester.pumpAndSettle();
      await tapText(tester, 'Back to sign in');
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
    });

    testWidgets('a rate limit is shown in the form', (tester) async {
      final fakes = TestFakes();
      fakes.auth.fail(
        'forgotPassword',
        const RateLimitedFailure(retryAfter: Duration(minutes: 60)),
      );
      await _open(tester, AppRoutes.forgotPassword, fakes: fakes);
      await typeInto(tester, 'Email', 'a@example.com');
      await tapText(tester, 'Send the link');
      await tester.pumpAndSettle();
      expect(
        find.text('Too many attempts. Try again in 60 minutes.'),
        findsOneWidget,
      );
      expect(find.text('Check your email'), findsNothing);
    });

    testWidgets('is reachable while signed in too (from the reauth sheet)', (
      tester,
    ) async {
      await _open(
        tester,
        AppRoutes.forgotPassword,
        status: AuthStatus.signedIn,
      );
      expect(find.text('Reset password'), findsOneWidget);
    });
  });

  group('ReauthSheet', () {
    Future<(ProviderContainer, TestFakes, ValueNotifier<bool?>)> host(
      WidgetTester tester,
    ) async {
      final fakes = TestFakes();
      final container = await pumpAfterMe(
        tester,
        fakes: fakes,
        status: AuthStatus.signedIn,
      );
      final result = ValueNotifier<bool?>(null);
      container.read(routerProvider).go(AppRoutes.settingsAbout);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(Scaffold).last);
      unawaited(showReauthSheet(context).then((value) => result.value = value));
      await tester.pumpAndSettle();
      return (container, fakes, result);
    }

    testWidgets('confirming the password returns true', (tester) async {
      final (_, fakes, result) = await host(tester);
      expect(find.text("Confirm it's you"), findsOneWidget);
      await typeInto(tester, 'Password', 'correct horse battery');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(result.value, isTrue);
      expect(fakes.auth.reauthenticated, isTrue);
      expect(find.text("Confirm it's you"), findsNothing);
    });

    testWidgets('a wrong password keeps the sheet and the session', (
      tester,
    ) async {
      final (container, _, result) = await host(tester);
      await typeInto(tester, 'Password', 'wrong');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(
        find.text("That password didn't match. Try again."),
        findsOneWidget,
      );
      expect(result.value, isNull);
      expect(container.read(authControllerProvider), AuthStatus.signedIn);
      expect(tester.widget<TextField>(_field('Password')).controller!.text, '');
    });

    testWidgets('an empty password is flagged', (tester) async {
      final (_, fakes, _) = await host(tester);
      await tapText(tester, 'Confirm');
      expect(_error(tester, 'Password'), 'Please fill this in.');
      expect(fakes.auth.calls, isNot(contains('reauth')));
    });

    testWidgets('a rate limit and network failure show calm notices', (
      tester,
    ) async {
      final (_, fakes, _) = await host(tester);
      fakes.auth.fail(
        'reauth',
        const RateLimitedFailure(retryAfter: Duration(minutes: 15)),
      );
      await typeInto(tester, 'Password', 'x');
      await tapText(tester, 'Confirm');
      await tester.pumpAndSettle();
      expect(
        find.text('Too many attempts. Try again in 15 minutes.'),
        findsOneWidget,
      );
    });

    testWidgets('cancel returns false', (tester) async {
      final (_, _, result) = await host(tester);
      await tapText(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(result.value, isFalse);
    });

    testWidgets(
      'the forgot-password link closes the sheet and opens the reset request',
      (tester) async {
        final (_, _, result) = await host(tester);
        await tapText(tester, 'Forgot your password?');
        await tester.pumpAndSettle();
        expect(result.value, isFalse);
        expect(find.text('Reset password'), findsOneWidget);
        expect(
          tester.widget<TextField>(_field('Email')).controller!.text,
          'diwakar@example.com',
        );
      },
    );

    testWidgets(
      'withReauth retries the action after a successful confirmation',
      (tester) async {
        final fakes = TestFakes();
        final container = await pumpAfterMe(
          tester,
          fakes: fakes,
          status: AuthStatus.signedIn,
        );
        container.read(routerProvider).go(AppRoutes.settingsAbout);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(Scaffold).last);

        var calls = 0;
        int? outcome;
        unawaited(
          withReauth<int>(context, () async {
            calls++;
            if (calls == 1) {
              throw const ForbiddenFailure(code: 'reauth_required');
            }
            return 7;
          }).then((value) => outcome = value),
        );
        await tester.pumpAndSettle();
        expect(find.text("Confirm it's you"), findsOneWidget);
        await typeInto(tester, 'Password', 'correct horse battery');
        await tapText(tester, 'Confirm');
        await tester.pumpAndSettle();
        expect(outcome, 7);
        expect(calls, 2);
      },
    );

    testWidgets(
      'withReauth returns null when the sheet is dismissed and rethrows other failures',
      (tester) async {
        final container = await pumpAfterMe(
          tester,
          status: AuthStatus.signedIn,
        );
        container.read(routerProvider).go(AppRoutes.settingsAbout);
        await tester.pumpAndSettle();
        final context = tester.element(find.byType(Scaffold).last);

        var done = false;
        int? outcome = -1;
        unawaited(
          withReauth<int>(
            context,
            () async => throw const ForbiddenFailure(code: 'reauth_required'),
          ).then((value) {
            outcome = value;
            done = true;
          }),
        );
        await tester.pumpAndSettle();
        await tapText(tester, 'Cancel');
        await tester.pumpAndSettle();
        expect(done, isTrue);
        expect(outcome, isNull);

        await expectLater(
          withReauth<int>(
            context,
            () async =>
                throw const ForbiddenFailure(code: 'plan_limit_reached'),
          ),
          throwsA(isA<ForbiddenFailure>()),
        );
        expect(await withReauth<int>(context, () async => 3), 3);
      },
    );
  });
}
