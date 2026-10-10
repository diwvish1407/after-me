import 'dart:async';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/features/contacts/presentation/add_contact_screen.dart';
import 'package:afterme/features/contacts/presentation/contact_detail_screen.dart';
import 'package:afterme/features/contacts/presentation/edit_contact_screen.dart';
import 'package:afterme/features/contacts/presentation/people_screen.dart';
import 'package:afterme/features/home/presentation/home_screen.dart';
import 'package:afterme/features/onboarding/application/onboarding_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/contacts_harness.dart';
import '../helpers/in_memory_contacts_repository.dart';
import '../helpers/pump_app.dart';
import '../helpers/test_app.dart';

void main() {
  group('contact routes', () {
    String? redirect(
      AuthStatus status,
      String location, {
      OnboardingState onboarding = const OnboardingState(loaded: true),
    }) => authRedirect(
      status: status,
      location: location,
      isDev: false,
      onboarding: onboarding,
    );

    test('path helpers build fixed, encoded paths', () {
      expect(AppRoutes.peopleAdd, '/people/add');
      expect(AppRoutes.contactDetail('c1'), '/people/c1');
      expect(AppRoutes.contactEdit('c1'), '/people/c1/edit');
      expect(AppRoutes.contactDetail('a b/c'), '/people/a%20b%2Fc');
    });

    test('only well-formed contact paths are contact routes', () {
      for (final path in [
        '/people/c1',
        '/people/6f1c2a52-8d3b-4a6e-9a43-0c1d5e7b9a10',
        '/people/c1/edit',
        '/people/add',
      ]) {
        expect(
          AppRoutes.isContactRoute(path) ||
              AppRoutes.signedInRoutes().contains(path),
          isTrue,
          reason: path,
        );
      }
      for (final path in [
        '/people/',
        '/people/c1/edit/extra',
        '/people/c1/delete',
        '/people/a b',
        '/people/..%2Fhome',
        '/people/${'x' * 65}',
        '/people//edit',
        '/people/c1?next=/home',
      ]) {
        expect(AppRoutes.isContactRoute(path), isFalse, reason: path);
      }
    });

    test(
      'signed in with onboarding done may open them; anything else goes Home',
      () {
        for (final path in ['/people/add', '/people/c1', '/people/c1/edit']) {
          expect(redirect(AuthStatus.signedIn, path), isNull, reason: path);
        }
        for (final path in [
          '/people/c1/edit/more',
          '/people/',
          '/people/a b',
        ]) {
          expect(
            redirect(AuthStatus.signedIn, path),
            AppRoutes.home,
            reason: path,
          );
        }
      },
    );

    test('signed out and mid-onboarding people cannot open them', () {
      for (final path in ['/people/add', '/people/c1', '/people/c1/edit']) {
        expect(redirect(AuthStatus.signedOut, path), AppRoutes.welcome);
        expect(
          redirect(
            AuthStatus.signedIn,
            path,
            onboarding: const OnboardingState(
              loaded: true,
              completed: false,
              step: OnboardingStep.plan,
            ),
          ),
          OnboardingStep.plan.path,
        );
      }
    });
  });

  group('contact screens', () {
    testWidgets('add is not read as an id, and the stack unwinds', (
      tester,
    ) async {
      final container = await openApp(tester);
      unawaited(container.read(routerProvider).push(AppRoutes.peopleAdd));
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
      expect(find.byType(ContactDetailScreen), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets('detail then edit, then back twice to the list', (
      tester,
    ) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(initial: [testContact()]);
      final container = await openApp(tester, fakes: fakes);
      unawaited(
        container.read(routerProvider).push(AppRoutes.contactDetail('c1')),
      );
      await tester.pumpAndSettle();
      unawaited(
        container.read(routerProvider).push(AppRoutes.contactEdit('c1')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(EditContactScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(PeopleScreen), findsOneWidget);
    });

    testWidgets('query strings and fragments never select a contact', (
      tester,
    ) async {
      final container = await openApp(tester);
      container.read(routerProvider).go('/people/c1?next=/home#x');
      await tester.pumpAndSettle();
      expect(
        find.byType(ContactDetailScreen),
        findsOneWidget,
        reason: 'the path alone decides; the query is ignored',
      );
      container.read(routerProvider).go('/people/c1/edit/extra');
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('the People tab keeps its place when another tab is used', (
      tester,
    ) async {
      final fakes = TestFakes()
        ..contacts = InMemoryContactsRepository(initial: [testContact()]);
      final container = await openApp(tester, fakes: fakes);
      unawaited(
        container.read(routerProvider).push(AppRoutes.contactDetail('c1')),
      );
      await tester.pumpAndSettle();
      await tapText(tester, 'Home');
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      await tapText(tester, 'People');
      await tester.pumpAndSettle();
      expect(find.byType(ContactDetailScreen), findsOneWidget);
    });
  });
}
