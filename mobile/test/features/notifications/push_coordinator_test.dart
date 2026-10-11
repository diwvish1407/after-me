import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:afterme/app/router.dart';
import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/push/notification_channel.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/features/auth/application/account_session.dart';
import 'package:afterme/features/home/application/home_controller.dart';
import 'package:afterme/features/notifications/application/push_coordinator.dart';
import 'package:afterme/features/notifications/application/push_message.dart';
import 'package:afterme/features/privacy/application/local_account_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/test_app.dart';

/// The phone's push life, without a widget: the token, the registration, what happens when
/// the permission, the session or the token changes, and what is done with a push.
class _World {
  _World({
    AuthStatus status = AuthStatus.signedIn,
    bool configured = true,
    NotificationPermission permission = NotificationPermission.granted,
    TestFakes? fakes,
    InMemorySecureStore? secure,
    bool onboarded = true,
    bool realAuth = false,
    FakeAuthRepository? auth,
  }) : fakes = fakes ?? TestFakes(auth: auth) {
    this.fakes.push.configured = configured;
    this.fakes.notifications.current = permission;
    this.fakes.prefs = freshPreferences({
      'afterme.onboardingUserId': 'user-1',
      'afterme.onboardingCompleted': onboarded,
    });
    container = ProviderContainer.test(
      overrides: testOverrides(
        fakes: this.fakes,
        authStatus: realAuth ? null : status,
        secureStore: secure,
      ),
    );
  }

  final TestFakes fakes;
  late final ProviderContainer container;

  PushCoordinator get coordinator => container.read(pushCoordinatorProvider);

  FixedAuthController get fixedAuth =>
      container.read(authControllerProvider.notifier) as FixedAuthController;

  /// Starts push and lets everything it set going finish.
  Future<void> start() async {
    await coordinator.start();
    await pumpEventQueue();
  }

  /// The app returns to the foreground.
  Future<void> resume() async {
    await coordinator.onResumed();
    await pumpEventQueue();
  }

  List<Map<String, Object?>> get puts => fakes.devices.puts;

  Map<String, Object?>? get stored {
    final raw = fakes.secure.values['push.registration'];
    return raw == null ? null : jsonDecode(raw) as Map<String, Object?>;
  }

  int get homeReads => fakes.server.calls.where((c) => c == 'home').length;

  /// Home is loaded once, so a push is seen to add exactly one read.
  Future<void> loadHome() async {
    await container.read(homeControllerProvider.future);
  }
}

const _token = 'fcm-token-aaaaaaaaaaaaaaaaaaaaaaaa';
const _newToken = 'fcm-token-bbbbbbbbbbbbbbbbbbbbbbbb';

Map<String, Object?> _body(String? token, {bool omit = false}) => {
  'platform': 'android',
  'app_version': '0.1.0+7',
  'os_version': '15',
  'locale': 'en-IN',
  if (!omit) 'push_token': token,
};

IncomingPush _incident({
  String type = 'incident_missed',
  String v = '1',
  String? title = 'You missed your check-in',
  String? body = "Tap I'M OK to stop the reminders.",
  String? channel = 'reminders',
}) => IncomingPush(
  data: {'type': type, 'v': v},
  title: title,
  body: body,
  channelId: channel,
);

void main() {
  group('the token\'s life', () {
    test('registers the token once the person is signed in, push is configured '
        'and notifications are allowed', () async {
      final w = _World();
      await w.start();
      expect(w.puts, [_body(_token)]);
      expect(w.stored, containsPair('user_id', 'user-1'));
      expect(w.stored, containsPair('token', _token));
      expect(w.stored, containsPair('accepted', true));
    });

    test(
      'an unchanged token is not sent again, not even after a restart',
      () async {
        final w = _World();
        await w.start();
        await w.resume();
        await w.resume();
        expect(w.puts, hasLength(1));

        // The app is started again with the same secure storage.
        final again = _World(fakes: _fresh(), secure: w.fakes.secure);
        await again.start();
        expect(again.puts, isEmpty);
      },
    );

    test('it is sent again after a day, and not before', () async {
      final w = _World();
      await w.start();
      w.fakes.clock.advance(const Duration(hours: 23, minutes: 59));
      await w.resume();
      expect(w.puts, hasLength(1));
      w.fakes.clock.advance(const Duration(minutes: 2));
      await w.resume();
      expect(w.puts, hasLength(2));
      await w.resume();
      expect(
        w.puts,
        hasLength(2),
        reason: 'a day starts again from the new send',
      );
    });

    test(
      'a clock that moved back is not trusted to keep a token quiet',
      () async {
        final w = _World();
        await w.start();
        w.fakes.clock.advance(const Duration(days: -2));
        await w.resume();
        expect(w.puts, hasLength(2));
      },
    );

    test('a token FCM issues again is sent at once', () async {
      final w = _World();
      await w.start();
      w.fakes.push.refreshToken(_newToken);
      await pumpEventQueue();
      expect(w.puts, [_body(_token), _body(_newToken)]);
      expect(w.stored, containsPair('token', _newToken));
    });

    test('a changed app or system version is sent again', () async {
      final w = _World();
      await w.start();
      w.fakes.device.os = '16';
      await w.resume();
      expect(w.puts, hasLength(2));
      expect(w.puts.last['os_version'], '16');
    });

    test(
      'turning notifications off removes the token (push_token: null), once',
      () async {
        final w = _World();
        await w.start();
        w.fakes.notifications.current = NotificationPermission.denied;
        await w.resume();
        expect(w.puts.last, _body(null));
        expect(w.puts, hasLength(2));
        await w.resume();
        expect(w.puts, hasLength(2), reason: 'it is said once');
        expect(w.stored, containsPair('token', null));
      },
    );

    test('turning them on again registers the token again', () async {
      final w = _World();
      await w.start();
      w.fakes.notifications.current = NotificationPermission.permanentlyDenied;
      await w.resume();
      w.fakes.notifications.current = NotificationPermission.granted;
      await w.resume();
      expect(w.puts, [_body(_token), _body(null), _body(_token)]);
    });

    test('an answer in the system dialog registers at once', () async {
      final w = _World(permission: NotificationPermission.denied);
      await w.start();
      expect(w.puts, isEmpty);
      expect(w.fakes.push.tokenReads, 0, reason: 'not asked while off');
      await w.container
          .read(notificationPermissionControllerProvider.notifier)
          .request();
      await pumpEventQueue();
      expect(w.puts, [_body(_token)]);
    });

    test('nothing is removed that was never registered', () async {
      final w = _World(permission: NotificationPermission.denied);
      await w.start();
      await w.resume();
      expect(w.puts, isEmpty);
      expect(w.fakes.devices.deletes, 0);
    });

    test('a status that cannot be read changes nothing', () async {
      final w = _World(permission: NotificationPermission.unknown);
      await w.start();
      expect(w.puts, isEmpty);
    });

    test(
      'without a configured push service nothing is asked or sent',
      () async {
        final w = _World(configured: false);
        await w.start();
        await w.resume();
        expect(w.puts, isEmpty);
        expect(w.fakes.push.tokenReads, 0);
        expect(w.fakes.push.calls, isNot(contains('init')));
      },
    );

    test('Firebase that cannot start is a quiet no-op', () async {
      final w = _World();
      w.fakes.push.starts = false;
      await w.start();
      expect(w.puts, isEmpty);
      expect(w.fakes.push.tokenReads, 0);
    });

    test('a token that FCM cannot give yet is tried again later', () async {
      final w = _World();
      w.fakes.push.currentToken = null;
      await w.start();
      expect(w.puts, isEmpty);
      expect(w.fakes.pushTimers.delays, [const Duration(minutes: 1)]);
      w.fakes.push.currentToken = _token;
      w.fakes.pushTimers.fireNext();
      await pumpEventQueue();
      expect(w.puts, [_body(_token)]);
    });

    test(
      'a token the server would refuse is not sent, and not asked again today',
      () async {
        final w = _World();
        w.fakes.push.currentToken = 'has spaces';
        await w.start();
        await w.resume();
        expect(w.puts, isEmpty);
        expect(w.stored, containsPair('accepted', false));
        w.fakes.push.refreshToken(_newToken);
        await pumpEventQueue();
        expect(w.puts, [_body(_newToken)]);
      },
    );
  });

  group('signed out', () {
    test('a token is never registered while nobody is signed in', () async {
      final w = _World(status: AuthStatus.signedOut);
      await w.start();
      await w.resume();
      expect(w.puts, isEmpty);
      expect(w.fakes.push.tokenReads, 0);
      expect(w.fakes.push.deletes, 0);
    });

    test('while the session is being read nothing happens either, then it registers', () async {
      final w = _World(status: AuthStatus.unknown);
      await w.start();
      expect(w.puts, isEmpty);
      w.fixedAuth.set(AuthStatus.signedIn);
      await pumpEventQueue();
      expect(w.puts, [_body(_token)]);
    });

    test('signing in registers', () async {
      final w = _World(status: AuthStatus.signedOut);
      await w.start();
      w.fixedAuth.set(AuthStatus.signedIn);
      await pumpEventQueue();
      expect(w.puts, [_body(_token)]);
    });

    test(
      'signing out deletes the FCM token after the server was told',
      () async {
        final events = <String>[];
        final auth = _RecordingAuth(events);
        final w = _World(auth: auth);
        w.fakes.push.events = events;
        await w.start();
        expect(w.stored, isNotNull);

        await w.container.read(accountSessionProvider).signOut();
        await pumpEventQueue();

        expect(events, ['push.token', 'auth.logout', 'push.deleteToken']);
        expect(w.fakes.push.deletes, 1);
        expect(w.stored, isNull, reason: 'the registration is forgotten');
        expect(
          w.fakes.secure.values.keys,
          isNot(contains('push.delete_pending')),
          reason: 'the token is gone, nothing is left to do',
        );
      },
    );

    test('a session the server ended is the same as signing out', () async {
      final w = _World();
      await w.start();
      await w.container.read(authControllerProvider.notifier).signOut();
      await pumpEventQueue();
      expect(w.fakes.push.deletes, 1);
      expect(w.stored, isNull);
    });

    test('a closed account forgets the registration and the token', () async {
      final w = _World();
      await w.start();
      await w.container.read(localAccountDataProvider).wipe(userId: 'user-1');
      await pumpEventQueue();
      expect(w.fakes.push.deletes, 1);
      expect(w.stored, isNull);
    });

    test('the next account on the phone gets a new token', () async {
      final w = _World();
      await w.start();
      await w.container.read(authControllerProvider.notifier).signOut();
      await pumpEventQueue();
      expect(w.fakes.push.currentToken, isNull);

      w.fakes.push.currentToken = _newToken;
      w.fixedAuth.set(AuthStatus.signedIn);
      await pumpEventQueue();
      expect(w.puts.last, _body(_newToken));
      expect(w.puts, hasLength(2));
    });

    test('a token that could not be deleted (offline) is deleted at the next start', () async {
      final w = _World();
      await w.start();
      w.fakes.push.deleteWorks = false;
      await w.container.read(authControllerProvider.notifier).signOut();
      await pumpEventQueue();
      expect(w.fakes.push.deletes, 1);
      expect(w.fakes.secure.values['push.delete_pending'], '1');

      final again = _World(
        fakes: _fresh(),
        status: AuthStatus.signedOut,
        secure: w.fakes.secure,
      );
      again.fakes.push.deleteWorks = true;
      await again.start();
      expect(again.fakes.push.deletes, 1);
      expect(
        again.fakes.secure.values.keys,
        isNot(contains('push.delete_pending')),
      );
    });

    test(
      'a token that is still to be deleted goes before a new one is asked for',
      () async {
        final w = _World();
        await w.start();
        w.fakes.push.deleteWorks = false;
        await w.container.read(authControllerProvider.notifier).signOut();
        await pumpEventQueue();
        w.fakes.push.deleteWorks = true;
        w.fakes.push.tokenAfterDelete = _newToken;
        final events = <String>[];
        w.fakes.push.events = events;
        w.fixedAuth.set(AuthStatus.signedIn);
        await pumpEventQueue();
        expect(events.take(2), ['push.deleteToken', 'push.token']);
        expect(w.puts.last, _body(_newToken));
      },
    );

    test('a token that is still to be deleted and cannot be yet is tried again '
        'before any new one is asked for', () async {
      final w = _World();
      await w.start();
      w.fakes.push.deleteWorks = false;
      await w.container.read(authControllerProvider.notifier).signOut();
      await pumpEventQueue();
      final reads = w.fakes.push.tokenReads;

      w.fixedAuth.set(AuthStatus.signedIn);
      await pumpEventQueue();
      expect(w.fakes.push.tokenReads, reads, reason: 'no new token yet');
      expect(w.puts, hasLength(1));
      expect(w.fakes.pushTimers.delays, [const Duration(minutes: 1)]);

      w.fakes.push.deleteWorks = true;
      w.fakes.push.tokenAfterDelete = _newToken;
      w.fakes.pushTimers.fireNext();
      await pumpEventQueue();
      expect(w.puts.last, _body(_newToken));
    });

    test(
      'a registration that was on its way when the session ended is dropped',
      () async {
        final w = _World();
        w.fakes.devices.gate = Completer<void>();
        unawaited(w.coordinator.start());
        await pumpEventQueue();
        expect(w.puts, hasLength(1), reason: 'the request is on its way');

        await w.container.read(authControllerProvider.notifier).signOut();
        await pumpEventQueue();
        w.fakes.devices.gate!.complete();
        await pumpEventQueue();

        expect(w.stored, isNull, reason: 'nothing of the old session is kept');
        expect(w.puts, hasLength(1));
      },
    );
  });

  group('when the server says no', () {
    test('a token it refuses (422) is left alone until tomorrow', () async {
      final w = _World();
      w.fakes.devices.failures.add(const ValidationFailure());
      await w.start();
      expect(w.puts, hasLength(1));
      expect(
        w.fakes.pushTimers.created,
        isEmpty,
        reason: 'no retry of the same token',
      );
      expect(w.stored, containsPair('accepted', false));
      await w.resume();
      expect(w.puts, hasLength(1));
      w.fakes.clock.advance(const Duration(days: 1, minutes: 1));
      await w.resume();
      expect(w.puts, hasLength(2));
      expect(w.stored, containsPair('accepted', true));
    });

    test(
      'a session that cannot be used (401) is left to the session handling',
      () async {
        final w = _World();
        w.fakes.devices.failures.add(
          const UnauthorizedFailure(code: 'token_expired'),
        );
        await w.start();
        expect(w.fakes.pushTimers.created, isEmpty);
        expect(w.stored, isNull);
        await w.resume();
        expect(w.puts, hasLength(2), reason: 'the next return tries again');
        expect(w.stored, containsPair('accepted', true));
      },
    );

    test('an update that is required is not a push problem', () async {
      final w = _World();
      w.fakes.devices.failures.add(const UpgradeRequiredFailure());
      await w.start();
      expect(w.fakes.pushTimers.created, isEmpty);
      expect(w.stored, isNull);
    });

    test(
      'a refusal that is not about the token waits for the next start',
      () async {
        final w = _World();
        w.fakes.devices.failures.add(const NotFoundFailure());
        await w.start();
        expect(w.fakes.pushTimers.created, isEmpty);
        await w.resume();
        expect(w.puts, hasLength(2));
      },
    );

    test(
      'no network: tried again after 1, 5 and 15 minutes, then it waits',
      () async {
        final w = _World();
        w.fakes.devices.failures.addAll([
          const NetworkFailure(),
          const NetworkFailure(),
          const NetworkFailure(),
          const NetworkFailure(),
        ]);
        await w.start();
        expect(w.puts, hasLength(1));
        for (var i = 0; i < 3; i++) {
          w.fakes.pushTimers.fireNext();
          await pumpEventQueue();
        }
        expect(w.puts, hasLength(4));
        expect(w.fakes.pushTimers.delays, pushRetryDelays);
        expect(w.fakes.pushTimers.active, isEmpty, reason: 'no fourth timer');
        expect(w.stored, isNull);

        await w.resume();
        expect(
          w.puts,
          hasLength(5),
          reason: 'the app returning starts it over',
        );
        expect(w.stored, containsPair('accepted', true));
      },
    );

    test(
      'a server that is busy (503, 500, an unreadable answer) is waited for',
      () async {
        for (final failure in <Object>[
          const ServerFailure(statusCode: 503),
          const ServerFailure(statusCode: 500),
          const UnknownFailure(),
          StateError('not even an AppFailure'),
        ]) {
          final w = _World();
          w.fakes.devices.failures.add(failure);
          await w.start();
          expect(w.fakes.pushTimers.delays, [
            const Duration(minutes: 1),
          ], reason: '$failure');
          w.fakes.pushTimers.fireNext();
          await pumpEventQueue();
          expect(w.puts, hasLength(2));
          expect(w.stored, containsPair('accepted', true));
        }
      },
    );

    test('"slow down" is waited for as long as the server says', () async {
      final w = _World();
      w.fakes.devices.failures.add(
        const RateLimitedFailure(retryAfter: Duration(minutes: 20)),
      );
      await w.start();
      expect(w.fakes.pushTimers.delays, [const Duration(minutes: 20)]);
    });

    test(
      'a retry that is no longer wanted is cancelled by signing out',
      () async {
        final w = _World();
        w.fakes.devices.failures.add(const NetworkFailure());
        await w.start();
        expect(w.fakes.pushTimers.active, hasLength(1));
        await w.container.read(authControllerProvider.notifier).signOut();
        await pumpEventQueue();
        expect(w.fakes.pushTimers.active, isEmpty);
      },
    );

    test('removing the token that fails is tried again too', () async {
      final w = _World();
      await w.start();
      w.fakes.notifications.current = NotificationPermission.denied;
      w.fakes.devices.failures.add(const NetworkFailure());
      await w.resume();
      expect(w.fakes.pushTimers.delays, [const Duration(minutes: 1)]);
      w.fakes.pushTimers.fireNext();
      await pumpEventQueue();
      expect(w.puts.last, _body(null));
      expect(w.stored, containsPair('token', null));
    });

    test('several triggers at once make one request', () async {
      final w = _World();
      w.fakes.devices.gate = Completer<void>();
      unawaited(w.coordinator.start());
      await pumpEventQueue();
      unawaited(w.coordinator.onResumed());
      unawaited(w.coordinator.onResumed());
      w.fakes.push.refreshToken(_token);
      await pumpEventQueue();
      expect(w.puts, hasLength(1));
      w.fakes.devices.gate!.complete();
      await pumpEventQueue();
      expect(
        w.puts,
        hasLength(1),
        reason: 'what ran again found it up to date',
      );
    });
  });

  group('a push while the app is open', () {
    test('a known one is shown on its channel with the server\'s words, and Home is read again', () async {
      final w = _World();
      await w.start();
      await w.loadHome();
      final reads = w.homeReads;

      w.fakes.push.foreground.add(
        _incident(
          type: 'stage_executed',
          title: 'Your contacts have been notified',
          body: "If you're safe, open AfterMe and tap I'M SAFE.",
          channel: 'incidents',
        ),
      );
      await pumpEventQueue();

      final shown = w.fakes.localNotifications.shown.single;
      expect(shown.channel, NotificationChannel.incidents);
      expect(shown.title, 'Your contacts have been notified');
      expect(shown.body, "If you're safe, open AfterMe and tap I'M SAFE.");
      expect(shown.payload, 'stage_executed');
      expect(shown.id, PushType.stageExecuted.notificationId);
      expect(w.homeReads, reads + 1);
    });

    test('every known type is shown, on its channel', () async {
      final w = _World();
      await w.start();
      for (final type in PushType.values) {
        w.fakes.push.foreground.add(
          IncomingPush(
            data: {'type': type.wire, 'v': '1'},
            title: 'Title of ${type.wire}',
            body: 'Body of ${type.wire}',
          ),
        );
      }
      await pumpEventQueue();
      expect(
        w.fakes.localNotifications.shown,
        hasLength(PushType.values.length),
      );
      for (final (i, type) in PushType.values.indexed) {
        final shown = w.fakes.localNotifications.shown[i];
        expect(shown.channel, type.channel, reason: type.wire);
        expect(shown.payload, type.wire);
        expect(shown.title, 'Title of ${type.wire}');
      }
    });

    test('the channel the server names wins when it is one of ours', () async {
      final w = _World();
      await w.start();
      w.fakes.push.foreground.add(_incident(channel: 'account'));
      w.fakes.push.foreground.add(_incident(channel: 'made-up'));
      await pumpEventQueue();
      expect(w.fakes.localNotifications.shown.map((n) => n.channel), [
        NotificationChannel.account,
        NotificationChannel.reminders,
      ]);
    });

    test(
      'an unknown type, another version, no type and no data are ignored',
      () async {
        final w = _World();
        await w.start();
        await w.loadHome();
        final reads = w.homeReads;
        for (final push in [
          _incident(type: 'something_new'),
          _incident(v: '2'),
          const IncomingPush(title: 'Hello', body: 'World'),
          const IncomingPush(data: {'v': '1'}, title: 'No type'),
          const IncomingPush(),
        ]) {
          w.fakes.push.foreground.add(push);
        }
        await pumpEventQueue();
        expect(w.fakes.localNotifications.shown, isEmpty);
        expect(
          w.homeReads,
          reads,
          reason: 'nothing is read for what is ignored',
        );
      },
    );

    test('a message with no text shows nothing but still reads Home', () async {
      final w = _World();
      await w.start();
      await w.loadHome();
      final reads = w.homeReads;
      w.fakes.push.foreground.add(_incident(title: null, body: null));
      await pumpEventQueue();
      expect(w.fakes.localNotifications.shown, isEmpty);
      expect(w.homeReads, reads + 1);
    });

    test('nothing is shown while nobody is signed in', () async {
      final w = _World(status: AuthStatus.signedOut);
      await w.start();
      w.fakes.push.foreground.add(_incident());
      await pumpEventQueue();
      expect(w.fakes.localNotifications.shown, isEmpty);
    });

    test(
      'a notification that cannot be shown does not stop anything',
      () async {
        final w = _World();
        await w.start();
        await w.loadHome();
        final reads = w.homeReads;
        w.fakes.localNotifications.showThrows = true;
        w.fakes.push.foreground.add(_incident());
        await pumpEventQueue();
        expect(w.homeReads, reads + 1);
      },
    );

    test('the channels are created at start, with their words', () async {
      final w = _World(status: AuthStatus.signedOut, configured: false);
      await w.start();
      expect(w.fakes.localNotifications.initializations, 1);
      expect(w.fakes.localNotifications.channels.map((c) => c.channel.id), [
        'reminders',
        'incidents',
        'account',
      ]);
      expect(w.fakes.localNotifications.channels.map((c) => c.name), [
        'Check-in reminders',
        'Alerts about your plan',
        'Account notices',
      ]);
      expect(
        w.fakes.localNotifications.channels.every(
          (c) => c.description.isNotEmpty,
        ),
        isTrue,
      );
    });

    test('a language the app has no words for gets the English ones', () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.localeTestValue = const Locale('xx', 'YY');
      addTearDown(binding.platformDispatcher.clearLocaleTestValue);
      final w = _World(status: AuthStatus.signedOut, configured: false);
      await w.start();
      expect(w.fakes.localNotifications.channels.map((c) => c.name), [
        'Check-in reminders',
        'Alerts about your plan',
        'Account notices',
      ]);
    });

    test('start twice changes nothing', () async {
      final w = _World();
      await w.start();
      await w.start();
      expect(w.fakes.localNotifications.initializations, 1);
      expect(w.puts, hasLength(1));
    });
  });

  group('a tap on a notification', () {
    test('goes to Home or People by the type', () async {
      final w = _World();
      await w.start();
      w.fakes.push.opened.add(
        _incident(type: 'contact_unreachable', channel: 'account'),
      );
      await pumpEventQueue();
      w.fakes.push.opened.add(_incident(type: 'incident_midpoint'));
      await pumpEventQueue();
      expect(w.fakes.pushRoutes, [AppRoutes.people, AppRoutes.home]);
    });

    test('an unknown type, another version or no data opens Home', () async {
      final w = _World();
      await w.start();
      for (final push in [
        _incident(type: 'something_new'),
        _incident(type: 'contact_unreachable', v: '2'),
        const IncomingPush(),
      ]) {
        w.fakes.push.opened.add(push);
        await pumpEventQueue();
      }
      expect(w.fakes.pushRoutes, [
        AppRoutes.home,
        AppRoutes.home,
        AppRoutes.home,
      ]);
    });

    test('a tap on a notification the app showed goes by its type', () async {
      final w = _World();
      await w.start();
      w.fakes.localNotifications.tap('contact_unreachable');
      await pumpEventQueue();
      w.fakes.localNotifications.tap('whatever');
      await pumpEventQueue();
      expect(w.fakes.pushRoutes, [AppRoutes.people, AppRoutes.home]);
    });

    test('a notification that started the app is followed once', () async {
      final w = _World();
      w.fakes.push.initial = _incident(type: 'contact_unreachable');
      await w.start();
      expect(w.fakes.pushRoutes, [AppRoutes.people]);
      await w.start();
      expect(w.fakes.pushRoutes, hasLength(1));
    });

    test('a local notification that started the app is followed', () async {
      final w = _World();
      w.fakes.localNotifications.launch = 'incident_missed';
      await w.start();
      expect(w.fakes.pushRoutes, [AppRoutes.home]);
    });

    test('a tap waits for the session to be read', () async {
      final w = _World(status: AuthStatus.unknown);
      w.fakes.push.initial = _incident(type: 'contact_unreachable');
      await w.start();
      expect(w.fakes.pushRoutes, isEmpty);
      w.fixedAuth.set(AuthStatus.signedIn);
      await pumpEventQueue();
      expect(w.fakes.pushRoutes, [AppRoutes.people]);
    });

    test(
      'a tap while signed out goes to sign-in, and shows nothing of the push',
      () async {
        final w = _World(status: AuthStatus.signedOut);
        w.fakes.push.initial = _incident(type: 'contact_unreachable');
        await w.start();
        expect(w.fakes.pushRoutes, [AppRoutes.signIn]);
        w.fakes.push.opened.add(_incident(type: 'incident_missed'));
        await pumpEventQueue();
        expect(w.fakes.pushRoutes, [AppRoutes.signIn, AppRoutes.signIn]);
        expect(w.fakes.localNotifications.shown, isEmpty);
      },
    );

    test(
      'a tap during onboarding leaves the saved step to the router',
      () async {
        final w = _World(onboarded: false);
        w.fakes.push.initial = _incident();
        await w.start();
        expect(w.fakes.pushRoutes, isEmpty);
      },
    );

    test(
      'a tap that arrives before the progress is read waits for it',
      () async {
        final w = _World();
        // Nothing has read the saved progress yet when the tap arrives.
        w.fakes.localNotifications.launch = 'contact_unreachable';
        await w.coordinator.start();
        await pumpEventQueue();
        expect(w.fakes.pushRoutes, [AppRoutes.people]);
      },
    );

    test('a tap reads Home again', () async {
      final w = _World();
      await w.start();
      await w.loadHome();
      final reads = w.homeReads;
      w.fakes.push.opened.add(_incident());
      await pumpEventQueue();
      expect(w.homeReads, reads + 1);
    });
  });

  group('failures of the platform never reach the person', () {
    test('streams that fail are ignored', () async {
      final w = _World();
      await w.start();
      w.fakes.push.foreground.addError(StateError('boom'));
      w.fakes.push.opened.addError(StateError('boom'));
      w.fakes.push.refreshes.addError(StateError('boom'));
      w.fakes.localNotifications.tapController.addError(StateError('boom'));
      await pumpEventQueue();
      expect(w.puts, hasLength(1));
    });
  });
}

/// A fresh set of fakes for a second start of the app with the same storage.
TestFakes _fresh() => TestFakes();

/// An account "server" that notes when the sign-out request arrives.
class _RecordingAuth extends FakeAuthRepository {
  _RecordingAuth(this.events);

  final List<String> events;

  @override
  Future<void> logout() async {
    events.add('auth.logout');
    await super.logout();
  }
}
