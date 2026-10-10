import 'package:afterme/core/api/api_client.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/onboarding/application/setup_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/contacts_harness.dart';
import '../../helpers/fake_http_adapter.dart';
import '../../helpers/fakes.dart';
import '../../helpers/pump_app.dart';
import '../../helpers/test_app.dart';

const _created = <String, Object?>{
  'id': 'c-1',
  'display_name': 'Mom',
  'relationship': 'mother',
  'relationship_label': null,
  'email': 'mom@example.com',
  'phone_e164': null,
  'priority': 1,
  'verification_status': 'pending',
  'verified_at': null,
  'is_active': true,
  'invitation_sent_at': '2026-10-08T10:30:00Z',
  'invitation_send_count': 1,
  'notified_at_stages': <int>[],
  'receives_instructions': 0,
  'created_at': '2026-10-08T10:30:00Z',
  'updated_at': '2026-10-08T10:30:00Z',
};

/// Onboarding step 4 on the REAL contacts repository over a fake network.
Future<(ProviderContainer, FakeHttpAdapter)> _openStep(
  WidgetTester tester,
  FakeReply Function(RecordedRequest request, int index) contacts,
) async {
  final store = InMemorySecureStore();
  await SessionStore(store).saveSession(tokenResponse());
  final adapter = FakeHttpAdapter((request, index) {
    if (request.path == '/v1/auth/refresh') {
      return FakeReply.json(200, refreshResponse().toJson());
    }
    return contacts(request, index);
  });
  final fakes = TestFakes()..realContactsRepository = true;
  fakes.prefs = freshPreferences({
    'afterme.onboardingUserId': 'user-1',
    'afterme.onboardingCompleted': false,
    'afterme.onboardingStep': 'contact',
  });
  final container = await pumpAfterMe(
    tester,
    fakes: fakes,
    status: AuthStatus.signedIn,
    secureStore: store,
    extraOverrides: [apiHttpAdapterProvider.overrideWithValue(adapter)],
  );
  return (container, adapter);
}

FakeReply _entitlements(RecordedRequest request) => const FakeReply.json(200, {
  'tier': 'free',
  'limits': {
    'contacts': 1,
    'instructions': 3,
    'stages': 2,
    'custom_offsets': false,
  },
  'usage': {'contacts': 0, 'instructions': 0, 'stages': 0},
});

void main() {
  testWidgets('saving sends the real invitation request and continues', (
    tester,
  ) async {
    final (container, adapter) = await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {'items': <Object>[]});
      }
      if (request.method == 'POST' && request.path == '/v1/contacts') {
        return const FakeReply.json(201, _created);
      }
      if (request.path == '/v1/me/entitlements') {
        return _entitlements(request);
      }
      return FakeReply.problem(404, 'not_found');
    });
    expect(find.text('Preview: nothing is saved or sent yet.'), findsNothing);
    await fillContactForm(tester);
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();

    final post = adapter.requests.singleWhere(
      (r) => r.method == 'POST' && r.path == '/v1/contacts',
    );
    expect(post.data, {
      'display_name': 'Mom',
      'relationship': 'mother',
      'email': 'mom@example.com',
    });
    expect(post.bearer, isNotNull);
    expect(find.text('When should you check in?'), findsOneWidget);
    expect(
      container.read(setupControllerProvider).value!.contacts.single.id,
      'c-1',
    );
    expect(
      await container
          .read(preferencesStoreProvider)
          .getString(PreferenceKey.onboardingStep),
      'schedule',
    );
  });

  testWidgets('the free-plan limit is explained and the step can be skipped', (
    tester,
  ) async {
    await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {'items': <Object>[]});
      }
      if (request.method == 'POST') {
        return FakeReply.problem(
          403,
          'plan_limit_reached',
          extra: {'limit': 1, 'current': 1, 'resource': 'contacts'},
        );
      }
      return _entitlements(request);
    });
    await fillContactForm(tester);
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    expect(
      find.text('More trusted contacts are part of Premium'),
      findsOneWidget,
    );
    await tapText(tester, 'Close');
    await tester.pumpAndSettle();
    await tapText(tester, 'Skip for now');
    await tester.pumpAndSettle();
    expect(find.text('When should you check in?'), findsOneWidget);
  });

  testWidgets('a duplicate address is explained on the email field', (
    tester,
  ) async {
    await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {'items': <Object>[]});
      }
      return FakeReply.problem(409, 'contact_duplicate');
    });
    await fillContactForm(tester);
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    expect(
      fieldError(tester, 'Their email'),
      "You've already added someone with this email address.",
    );
    expect(find.text('When should you check in?'), findsNothing);
  });

  testWidgets('your own address is explained on the email field', (
    tester,
  ) async {
    await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {'items': <Object>[]});
      }
      return FakeReply.problem(422, 'cannot_be_own_email');
    });
    await fillContactForm(tester);
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    expect(
      fieldError(tester, 'Their email'),
      "That's your own email address. Choose someone else.",
    );
  });

  testWidgets('a network failure keeps the form; the person can try again', (
    tester,
  ) async {
    var posts = 0;
    await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {'items': <Object>[]});
      }
      if (request.method == 'POST') {
        posts++;
        return posts == 1
            ? const FakeReply.networkError()
            : const FakeReply.json(201, _created);
      }
      return _entitlements(request);
    });
    await fillContactForm(tester);
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    expect(find.textContaining("You're offline"), findsOneWidget);
    expect(
      posts,
      1,
      reason: 'a failed write is not repeated behind their back',
    );
    await tapText(tester, 'Save and continue');
    await tester.pumpAndSettle();
    expect(find.text('When should you check in?'), findsOneWidget);
  });

  testWidgets('a contact that already exists is shown with its status', (
    tester,
  ) async {
    await _openStep(tester, (request, index) {
      if (request.method == 'GET' && request.path == '/v1/contacts') {
        return const FakeReply.json(200, {
          'items': [_created],
        });
      }
      return _entitlements(request);
    });
    expect(find.text('Mom will get an invitation to accept.'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    await tapText(tester, 'Continue');
    await tester.pumpAndSettle();
    expect(find.text('When should you check in?'), findsOneWidget);
  });
}
