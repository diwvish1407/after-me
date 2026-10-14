import 'dart:async';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/leave_guards.dart';
import '../../../app/repository_providers.dart';
import '../../../app/router.dart';
import '../../../core/api/client_info.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/session_epoch.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/device/device_info_source.dart';
import '../../../core/permissions/notification_permission.dart';
import '../../../core/push/local_notification_gateway.dart';
import '../../../core/push/push_gateway.dart';
import '../../../core/time/clock.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../../l10n/gen/app_localizations_en.dart';
import '../../home/application/home_controller.dart';
import '../../incidents/application/incident_history_controller.dart';
import '../../onboarding/application/onboarding_controller.dart';
import '../data/devices_repository.dart';
import '../presentation/channel_labels.dart';
import 'push_message.dart';
import 'push_registration_store.dart';

/// Takes the app to a route. The default is the router; tests record the calls.
typedef PushNavigate = void Function(String location);

final pushNavigateProvider = Provider<PushNavigate>(
  (ref) =>
      (location) => ref.read(routerProvider).go(location),
);

/// Puts [location] **on top of** what is on screen instead of replacing it, so that a
/// screen with unsaved work (the plan editor) stays underneath with its draft. Used for a
/// tap that must reach Home at once while such a screen is open. The default is the
/// router's `push`; tests record the calls.
final pushShowOnTopProvider = Provider<PushNavigate>(
  (ref) =>
      (location) => unawaited(ref.read(routerProvider).push<void>(location)),
);

/// Starts a one-shot timer. The default is [Timer.new]; tests fire timers by hand.
typedef PushTimerFactory = Timer Function(Duration after, void Function() run);

final pushTimerProvider = Provider<PushTimerFactory>((ref) => Timer.new);

/// How long a token that was sent (or refused) is left alone before it is sent again.
const Duration pushResendAfter = Duration(days: 1);

/// How long to wait before trying again after a failure that may pass (offline, the
/// server busy), then again, then again. After the last one the next try waits for
/// something to change: the app returning, FCM issuing a new token, a sign-in.
const List<Duration> pushRetryDelays = [
  Duration(minutes: 1),
  Duration(minutes: 5),
  Duration(minutes: 15),
];

/// The life of push on this phone (MOB-56..60; ARCHITECTURE.md §5.7; SECURITY.md T21).
///
/// **What it does**
/// * Registers the FCM token with `PUT /v1/devices/current` once the person is signed in,
///   push is configured and the notification permission is granted: at start, when the app
///   returns, when FCM issues a new token and when the permission changes. A token that has
///   not changed is not sent again for a day.
/// * Removes the token from the server (`push_token: null`) when the permission is off.
/// * After a sign-out (of any kind, including a session the server ended and a deleted
///   account) forgets the registration and deletes the local FCM token, and never registers
///   one while signed out.
/// * Shows a push that arrives while the app is open as a local notification (the system
///   shows none), on the channel the server named and with the server's generic text, and
///   reads Home again.
/// * Takes a tap on a notification to the Home or the People tab.
///
/// **What it never does**
/// * Act on what a message says: a push is a hint. Nothing in it is stored, logged, used to
///   change state or composed into text.
/// * Block anything: every failure is swallowed here and tried again later.
///
/// Created on first use by `PushHost`; `start` is called once.
class PushCoordinator {
  PushCoordinator(this._ref);

  final Ref _ref;

  bool _started = false;
  bool _disposed = false;

  /// Counts sessions: a registration that was started for one account is dropped when
  /// the session ends or another begins.
  final SessionEpoch _session = SessionEpoch();

  Future<void>? _syncing;
  bool _syncAgain = false;

  Timer? _retry;
  int _attempt = 0;

  /// The app is not in the foreground: no retry is scheduled (see [onPaused]).
  bool _inBackground = false;

  /// Where a tap is going, until the app is ready to go there.
  PushDestination? _pendingTap;

  /// Whether the pending tap is about a check-in or an incident (always reaches Home).
  bool _pendingUrgent = false;

  /// A screen with unsaved work is being asked whether the tap may take the person away.
  bool _confirming = false;

  /// Counts the taps that started a journey; a question that is answered after a newer,
  /// urgent tap took the person to Home must not move them again.
  int _tapGeneration = 0;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  PushGateway get _push => _ref.read(pushGatewayProvider);
  LocalNotificationGateway get _local =>
      _ref.read(localNotificationGatewayProvider);
  PushRegistrationStore get _store => _ref.read(pushRegistrationStoreProvider);
  AuthStatus get _auth => _ref.read(authControllerProvider);
  bool get _live => !_disposed && _ref.mounted;

  // --- start ---------------------------------------------------------------------------

  /// Prepares the notification channels, starts listening and handles what started the app
  /// (a tap on a notification), then brings the registration up to date. Safe to call
  /// more than once.
  Future<void> start() async {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    _session.next();
    await _startLocal();
    await _startPush();
    switch (_auth) {
      case AuthStatus.signedIn:
        unawaited(sync());
      case AuthStatus.signedOut:
        // A token that could not be deleted at the last sign-out (offline) goes now.
        unawaited(_deleteLeftoverToken());
      case AuthStatus.unknown:
        // The session is still being read; the auth listener takes it from there.
        break;
    }
  }

  Future<void> _startLocal() async {
    try {
      final local = _local;
      await local.initialize();
      _subscriptions.add(local.taps.listen(_onLocalTap, onError: _ignore));
      await local.ensureChannels(notificationChannelSpecs(_l10n()));
      final launched = await local.launchPayload();
      if (launched != null) {
        _onLocalTap(launched);
      }
    } on Object {
      // The system still shows every notification; only the foreground copy is lost.
    }
  }

  Future<void> _startPush() async {
    try {
      final push = _push;
      if (!push.isConfigured) {
        return;
      }
      _subscriptions
        ..add(push.foregroundMessages.listen(_onForeground, onError: _ignore))
        ..add(push.openedMessages.listen(_onOpened, onError: _ignore))
        ..add(
          push.tokenRefreshes.listen(
            (_) => unawaited(sync()),
            onError: _ignore,
          ),
        );
      final initial = await push.initialMessage();
      if (initial != null && _live) {
        _onOpened(initial);
      }
    } on Object {
      // Push is a convenience on top of the schedule and the emails; never a blocker.
    }
  }

  /// A stream that failed has nothing to say to the person; it is not a crash.
  static void _ignore(Object _) {}

  AppLocalizations _l10n() {
    final locale = PlatformDispatcher.instance.locale;
    return AppLocalizations.delegate.isSupported(locale)
        ? lookupAppLocalizations(locale)
        : AppLocalizationsEn();
  }

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _retry = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  // --- what the app tells the coordinator ---------------------------------------------

  /// The app returned to the foreground: the permission may have been changed in the
  /// system settings, and the token may have been issued again.
  Future<void> onResumed() async {
    if (!_started || _disposed) {
      return;
    }
    _inBackground = false;
    await sync();
  }

  /// The app left the foreground. The app does no background work (TEST_PLAN PERF-05): a
  /// registration retry that was waiting is cancelled, and the count starts again, because
  /// [onResumed] brings the registration up to date at once and schedules its own retries
  /// if that fails.
  void onPaused() {
    if (!_started || _disposed) {
      return;
    }
    _inBackground = true;
    _cancelRetry();
    _attempt = 0;
  }

  void onAuthChanged(AuthStatus? previous, AuthStatus next) {
    if (!_started || _disposed) {
      return;
    }
    // A new session scope: whatever was started for the earlier one is stale.
    _session.next();
    _cancelRetry();
    _attempt = 0;
    switch (next) {
      case AuthStatus.signedIn:
        unawaited(sync());
      case AuthStatus.signedOut:
        if (previous == AuthStatus.signedIn) {
          unawaited(forgetDevice());
        } else {
          unawaited(_deleteLeftoverToken());
        }
      case AuthStatus.unknown:
        break;
    }
    _flushPendingTap();
  }

  void onPermissionChanged(
    NotificationPermission? previous,
    NotificationPermission next,
  ) {
    if (!_started || _disposed || next == NotificationPermission.unknown) {
      return;
    }
    if (previous != next) {
      unawaited(sync());
    }
  }

  void onOnboardingChanged() => _flushPendingTap();

  // --- the token's life ----------------------------------------------------------------

  /// Brings the server's idea of this phone's push token up to date: registers the token,
  /// or removes it when notifications are off. One run at a time; a request that arrives
  /// meanwhile makes the run go once more. Never throws.
  Future<void> sync() {
    final running = _syncing;
    if (running != null) {
      _syncAgain = true;
      return running;
    }
    final future = _syncLoop();
    _syncing = future;
    return future;
  }

  Future<void> _syncLoop() async {
    try {
      do {
        _syncAgain = false;
        await _syncOnce();
      } while (_syncAgain && _live);
    } on Object {
      // Nothing here may become an error the person sees.
    } finally {
      _syncing = null;
    }
  }

  bool _current(int session) =>
      _live && _session.isCurrent(session) && _auth == AuthStatus.signedIn;

  Future<void> _syncOnce() async {
    if (!_push.isConfigured || _auth != AuthStatus.signedIn) {
      return;
    }
    final session = _session.current;
    final permission = await _permission();
    if (!_current(session)) {
      return;
    }
    switch (permission) {
      case NotificationPermission.granted:
        await _register(session);
      case NotificationPermission.denied ||
          NotificationPermission.permanentlyDenied:
        await _withdraw(session);
      case NotificationPermission.unknown:
        break;
    }
  }

  Future<NotificationPermission> _permission() async {
    try {
      return await _ref.read(notificationPermissionGatewayProvider).status();
    } on Object {
      return NotificationPermission.unknown;
    }
  }

  static String _facts(DeviceDescriptor device) =>
      '${device.appVersion}|${device.osVersion}|${device.locale}';

  Future<DeviceDescriptor> _describe() => DeviceDescriptors.describe(
    _ref.read(clientInfoProvider),
    _ref.read(deviceInfoSourceProvider),
  );

  Future<String> _userId() async {
    try {
      return await _ref.read(sessionStoreProvider).readUserId() ?? '';
    } on Object {
      return '';
    }
  }

  Future<void> _register(int session) async {
    final push = _push;
    if (!await push.ensureInitialized() || !_current(session)) {
      return;
    }
    if (await _store.isDeletePending() && !await _deleteLocalToken()) {
      _scheduleRetry();
      return;
    }
    final token = await push.token();
    if (!_current(session)) {
      return;
    }
    if (token == null) {
      // FCM cannot give one right now (offline, Google services busy).
      _scheduleRetry();
      return;
    }
    final device = await _describe();
    final facts = _facts(device);
    final userId = await _userId();
    final now = _ref.read(clockProvider)();
    final previous = await _store.read();
    if (!_current(session)) {
      return;
    }
    if (userId.isNotEmpty &&
        previous != null &&
        previous.userId == userId &&
        previous.token == token &&
        previous.facts == facts &&
        _isFresh(previous.at, now)) {
      return;
    }
    if (!isAcceptablePushToken(token)) {
      // The server would refuse it: say so once a day, not at every start.
      await _remember(userId, token, facts, now, accepted: false);
      return;
    }
    try {
      await _ref
          .read(devicesRepositoryProvider)
          .update(device, SetPushToken(token));
    } on Object catch (error) {
      await _onFailure(
        toAppFailure(error),
        session: session,
        userId: userId,
        token: token,
        facts: facts,
        now: now,
      );
      return;
    }
    if (!_current(session)) {
      return;
    }
    _attempt = 0;
    _cancelRetry();
    await _remember(userId, token, facts, now, accepted: true);
  }

  Future<void> _withdraw(int session) async {
    final previous = await _store.read();
    final userId = await _userId();
    if (!_current(session) ||
        previous == null ||
        previous.token == null ||
        !previous.accepted ||
        (userId.isNotEmpty && previous.userId != userId)) {
      // Nothing was registered for this account, so there is nothing to take back.
      return;
    }
    final device = await _describe();
    final facts = _facts(device);
    final now = _ref.read(clockProvider)();
    try {
      await _ref
          .read(devicesRepositoryProvider)
          .update(device, const RemovePushToken());
    } on Object catch (error) {
      await _onFailure(
        toAppFailure(error),
        session: session,
        userId: userId,
        token: null,
        facts: facts,
        now: now,
      );
      return;
    }
    if (!_current(session)) {
      return;
    }
    _attempt = 0;
    _cancelRetry();
    await _remember(userId, null, facts, now, accepted: true);
  }

  bool _isFresh(DateTime at, DateTime now) {
    final age = now.difference(at);
    return !age.isNegative && age < pushResendAfter;
  }

  Future<void> _remember(
    String userId,
    String? token,
    String facts,
    DateTime now, {
    required bool accepted,
  }) async {
    if (userId.isEmpty) {
      return;
    }
    await _store.write(
      PushRegistration(
        userId: userId,
        token: token,
        facts: facts,
        at: now,
        accepted: accepted,
      ),
    );
  }

  /// What a failed request means for the next try. The person sees nothing either way.
  Future<void> _onFailure(
    AppFailure failure, {
    required int session,
    required String userId,
    required String? token,
    required String facts,
    required DateTime now,
  }) async {
    switch (failure) {
      case ValidationFailure():
        // The server refused this token: it is not offered again before tomorrow (a new
        // token from FCM is, at once).
        if (token != null && _current(session)) {
          await _remember(userId, token, facts, now, accepted: false);
        }
      case UnauthorizedFailure() || UpgradeRequiredFailure():
        // The session or the app version has its own handling; nothing to add.
        break;
      case NetworkFailure() ||
          ServerFailure() ||
          RateLimitedFailure() ||
          UnknownFailure():
        if (_current(session)) {
          _scheduleRetry(
            failure is RateLimitedFailure ? failure.retryAfter : null,
          );
        }
      default:
        // A refusal that is not about the token (403, 404, 409): the next start or
        // return tries again.
        break;
    }
  }

  void _scheduleRetry([Duration? atLeast]) {
    if (!_live || _inBackground || _attempt >= pushRetryDelays.length) {
      return;
    }
    var delay = pushRetryDelays[_attempt++];
    if (atLeast != null && atLeast > delay) {
      delay = atLeast;
    }
    _retry?.cancel();
    _retry = _ref.read(pushTimerProvider)(delay, () {
      _retry = null;
      if (_live) {
        unawaited(sync());
      }
    });
  }

  void _cancelRetry() {
    _retry?.cancel();
    _retry = null;
  }

  // --- sign-out ------------------------------------------------------------------------

  /// The person is signed out (they chose to, the server ended the session, or the account
  /// was closed): the registration is forgotten and the FCM token on this phone is deleted,
  /// **after** whatever the server was told (the sign-out request, or the deletion, has
  /// already been answered when the status changes). The server's copy is cleared by that
  /// request itself. Never throws.
  Future<void> forgetDevice() async {
    try {
      await _store.clear();
      await _deleteLocalToken();
    } on Object {
      // Both steps are independent and swallow their own failures.
    }
  }

  /// Deletes the FCM token on this phone. When that cannot be done now the marker stays,
  /// and the next start (or the next sign-in, before a token is asked for) tries again.
  Future<bool> _deleteLocalToken() async {
    await _store.setDeletePending(pending: true);
    final deleted = await _push.deleteToken();
    if (deleted) {
      await _store.setDeletePending(pending: false);
    }
    return deleted;
  }

  Future<void> _deleteLeftoverToken() async {
    try {
      if (await _store.isDeletePending()) {
        await _deleteLocalToken();
      }
    } on Object {
      // Tried again at the next start.
    }
  }

  // --- messages and taps ---------------------------------------------------------------

  /// A push arrived while the app is open. A known one is shown (the system shows nothing
  /// for it) and Home is read again. Anything else, and anything while nobody is signed in,
  /// is ignored.
  void _onForeground(IncomingPush push) {
    if (_auth != AuthStatus.signedIn) {
      return;
    }
    final message = PushMessage.tryParse(push);
    if (message == null) {
      return;
    }
    if (message.hasText) {
      unawaited(
        _show(
          LocalNotification(
            id: message.type.notificationId,
            channel: message.channel,
            title: message.title ?? '',
            body: message.body ?? '',
            payload: message.type.wire,
          ),
        ),
      );
    }
    _readAgain();
  }

  Future<void> _show(LocalNotification notification) async {
    try {
      await _local.show(notification);
    } on Object {
      // The screen shows the same thing once Home has been read again.
    }
  }

  /// The person tapped a notification the system showed.
  void _onOpened(IncomingPush push) => _openDestination(
    tapDestination(push.data),
    urgent: tapIsUrgent(push.data),
  );

  /// The person tapped a notification this app showed. Its payload is the push's type.
  void _onLocalTap(String payload) {
    final data = <String, String>{'type': payload, 'v': supportedPushVersion};
    _openDestination(tapDestination(data), urgent: tapIsUrgent(data));
  }

  void _openDestination(PushDestination destination, {required bool urgent}) {
    if (_confirming && !urgent) {
      // The person is answering "Leave without saving?" for an earlier tap.
      return;
    }
    _pendingTap = destination;
    _pendingUrgent = urgent;
    _flushPendingTap();
  }

  /// Goes where the tap asked once the app can: a tap that arrives while the session is
  /// still being read, or the saved progress is, waits for that; a tap while signed out
  /// goes to sign-in and shows nothing; one during onboarding leaves the router to resume
  /// the saved step. The app lock is above the navigator, so a tap while locked changes the
  /// page under the lock and nothing is shown until the person unlocks.
  void _flushPendingTap() {
    final destination = _pendingTap;
    if (destination == null || _disposed) {
      return;
    }
    final urgent = _pendingUrgent;
    final navigate = _ref.read(pushNavigateProvider);
    switch (_auth) {
      case AuthStatus.unknown:
        return;
      case AuthStatus.signedOut:
        _pendingTap = null;
        navigate(AppRoutes.signIn);
      case AuthStatus.signedIn:
        final onboarding = _ref.read(onboardingControllerProvider);
        if (!onboarding.loaded) {
          return;
        }
        _pendingTap = null;
        if (!onboarding.needsOnboarding) {
          final guards = _ref.read(leaveGuardsProvider);
          _tapGeneration++;
          if (!guards.isGuarding) {
            navigate(destination.location);
            _readAgain();
          } else {
            unawaited(
              _goPastUnsavedWork(
                guards,
                destination,
                urgent: urgent,
                generation: _tapGeneration,
              ),
            );
          }
        }
    }
  }

  /// A screen with unsaved work (the plan editor) is open, and `go` would replace the
  /// page stack and drop its draft without a word.
  ///
  /// * A tap about a check-in or an incident is **never** held up and never dropped: the
  ///   person must be able to reach I'M OK or I'M SAFE. A save that is on its way is
  ///   waited for (bounded: the screen closes itself when it succeeds), and Home is then
  ///   put on top of the editor, which stays under it with its draft; Back returns to it.
  /// * Any other tap asks the question Back asks and goes only if the person leaves (the
  ///   draft is then discarded, so the question is not asked again later).
  ///
  /// Either way the push was a hint to read Home again, and that happens.
  Future<void> _goPastUnsavedWork(
    LeaveGuards guards,
    PushDestination destination, {
    required bool urgent,
    required int generation,
  }) async {
    final navigate = _ref.read(pushNavigateProvider);
    final showOnTop = _ref.read(pushShowOnTopProvider);
    if (!urgent) {
      _confirming = true;
    }
    var leave = false;
    try {
      await guards.whenIdle();
      if (!_live || generation != _tapGeneration) {
        return;
      }
      if (urgent) {
        // The save may have closed the screen meanwhile: then nothing is left to keep.
        if (guards.isGuarding) {
          showOnTop(destination.location);
        } else {
          navigate(destination.location);
        }
      } else {
        leave = guards.isGuarding ? await guards.confirmLeave() : true;
      }
    } on Object {
      // A question that cannot be asked must not leave a draft to be thrown away.
    } finally {
      if (!urgent) {
        _confirming = false;
      }
    }
    if (!_live) {
      return;
    }
    if (!urgent && leave && generation == _tapGeneration) {
      navigate(destination.location);
    }
    _readAgain();
  }

  /// A push is only a hint: Home (and with it the incident on screen) is read again from
  /// the API, and a loaded incident history is read again too.
  void _readAgain() {
    if (!_live || _auth != AuthStatus.signedIn) {
      return;
    }
    unawaited(_ref.read(homeControllerProvider.notifier).refresh());
    _ref.invalidate(incidentHistoryControllerProvider);
  }
}

/// The coordinator, wired to the auth status, the notification permission and the
/// onboarding progress. Created by `PushHost` (so only the running app has one).
final pushCoordinatorProvider = Provider<PushCoordinator>((ref) {
  final coordinator = PushCoordinator(ref);
  ref
    ..listen<AuthStatus>(authControllerProvider, coordinator.onAuthChanged)
    ..listen<NotificationPermission>(
      notificationPermissionControllerProvider.select((state) => state.status),
      coordinator.onPermissionChanged,
    )
    ..listen<OnboardingState>(
      onboardingControllerProvider,
      (previous, next) => coordinator.onOnboardingChanged(),
    )
    ..onDispose(coordinator.dispose);
  return coordinator;
});
