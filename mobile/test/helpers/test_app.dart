import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/auth/session_store.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/links/url_opener.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/platform/clipboard_gateway.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/platform/file_export.dart';
import 'package:afterme/core/push/local_notification_gateway.dart';
import 'package:afterme/core/push/push_gateway.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:afterme/core/security/secure_screen.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/core/time/clock.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/features/incidents/application/safe_controller.dart';
import 'package:afterme/features/notifications/application/push_coordinator.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_activity_server.dart';
import 'fake_auth_repository.dart';
import 'fake_checkin_server.dart';
import 'fake_incident_server.dart';
import 'fake_instructions_server.dart';
import 'fake_plan_server.dart';
import 'fake_platform.dart';
import 'fake_privacy.dart';
import 'fake_push.dart';
import 'fake_timers.dart';
import 'in_memory_contacts_repository.dart';

final devConfig = AppConfig.parse(
  appEnv: 'dev',
  apiBaseUrl: 'http://10.0.2.2:8000',
);

final prodConfig = AppConfig.parse(
  appEnv: 'prod',
  apiBaseUrl: 'https://api.afterme.invalid',
  publicBaseUrl: 'https://afterme.invalid',
);

const testClientInfo = ClientInfo(version: '0.1.0', buildNumber: '7');

/// An [AuthController] fixed to one status (no storage access).
class FixedAuthController extends AuthController {
  FixedAuthController(this.initial);

  final AuthStatus initial;

  @override
  AuthStatus build() => initial;

  void set(AuthStatus status) => state = status;
}

/// A controllable clock.
class FakeClock {
  FakeClock([DateTime? start])
    : current = start ?? DateTime.utc(2026, 10, 8, 12);

  DateTime current;

  DateTime now() => current;

  void advance(Duration duration) => current = current.add(duration);
}

/// Every fake the Phase 2 features talk to, created once per test so the test can
/// script and inspect them.
class TestFakes {
  TestFakes({
    FakeAuthRepository? auth,
    FakeLocalAuthGateway? localAuth,
    FakeNotificationPermissionGateway? notifications,
  }) : auth = auth ?? FakeAuthRepository(),
       localAuth = localAuth ?? FakeLocalAuthGateway(),
       notifications = notifications ?? FakeNotificationPermissionGateway() {
    contacts = InMemoryContactsRepository();
    this.auth.clock ??= clock.now;
  }

  final FakeAuthRepository auth;
  final FakeLocalAuthGateway localAuth;
  final FakeNotificationPermissionGateway notifications;
  final FakeScreenPrivacy privacy = FakeScreenPrivacy();

  /// What the screens that show instruction content asked of the window.
  final FakeSecureScreenGateway secureScreen = FakeSecureScreenGateway();
  final FakeUrlOpener urls = FakeUrlOpener();
  final FakeClipboardGateway clipboard = FakeClipboardGateway();

  /// Use the production [PlatformClipboardGateway] on the (mocked) platform channel.
  bool realClipboard = false;
  final FakeContactPicker picker = FakeContactPicker();
  final FakeDeviceInfoSource device = FakeDeviceInfoSource();
  final FakeClock clock = FakeClock();

  /// The contacts "server" (tests script it; the app itself uses the real API). Whatever
  /// instance a test assigns is wired to the plan and the schedule below, so removing or
  /// re-addressing a contact who is in a stage while check-ins are on asks for the
  /// password like the real server does.
  InMemoryContactsRepository get contacts => _contacts;
  set contacts(InMemoryContactsRepository value) {
    _contacts = value
      ..stepUp = ContactStepUp(
        scheduleOff: () => server.status == CheckInStatus.inactive,
        inPlan: (id) => plan.stages.any((s) => s.contactIds.contains(id)),
        reauthenticated: () => auth.reauthenticated,
        receivesInstruction: (id) => instructions.isActiveRecipient(id),
      )
      ..instructionUsage = (() => instructions.liveCount)
      ..stageUsage = (() => plan.stages.length);
  }

  late InMemoryContactsRepository _contacts;

  /// Use the production [authRepositoryProvider] (the Dio one: `GET /v1/me`, ...)
  /// instead of [auth]. Only the request-log tests do this.
  bool realAuthRepository = false;

  /// Use the production [contactsRepositoryProvider] (the Dio one) instead of
  /// [contacts]. Only the wiring tests do this.
  bool realContactsRepository = false;

  /// Every call the plan and instructions "servers" received, in order across both
  /// (`plan.save`, `instructions.create`, ...).
  final List<String> events = [];

  /// The check-in "server": schedule, check-ins and the Home aggregate. It reads the
  /// contacts above, so readiness and activation follow what the test did there.
  late final FakeCheckInServer server = FakeCheckInServer(
    clock: clock.now,
    contacts: () => contacts.contacts,
    plan: () => plan,
    reauthenticated: () => auth.reauthenticated,
    displayName: auth.displayName,
    timezone: auth.timezone,
  )..instructionCount = () => instructions.activeCount;

  /// The plan "server": `GET` and `PUT /v1/plan` with the backend's validation. The
  /// check-in server above reads it for activation and the Home aggregate.
  late final FakePlanServer plan = FakePlanServer(
    contacts: () => contacts.contacts,
    tier: () => contacts.tier,
    incidentOpen: () => server.status == CheckInStatus.incidentOpen,
    scheduleActive: () => server.status == CheckInStatus.active,
    reauthenticated: () => auth.reauthenticated,
    releaseCount: (stageId) => instructions.releaseCount(stageId),
    instructionIdsAt: (stageId) => instructions.idsAtStage(stageId),
    onCall: events.add,
  );

  /// Use the production [planRepositoryProvider] (the Dio one) instead of [plan]. Only
  /// the wiring tests do this.
  bool realPlanRepository = false;

  /// The instructions "server": the categories and `GET` / `POST` / `PATCH` / `DELETE
  /// /v1/instructions` with the backend's validation and the free tier's three. It reads
  /// the contacts and the plan above, which in turn count what it holds (the stages'
  /// `release_count`, the entitlements' usage and Home's active instructions).
  late final FakeInstructionsServer instructions = FakeInstructionsServer(
    contacts: () => contacts.contacts,
    plan: () => plan,
    tier: () => contacts.tier,
    clock: clock.now,
    scheduleOn: () => server.status != CheckInStatus.inactive,
    reauthenticated: () => auth.reauthenticated,
    onCall: events.add,
  );

  /// Use the production [instructionsRepositoryProvider] (the Dio one) instead of
  /// [instructions]. Only the wiring tests do this.
  bool realInstructionsRepository = false;

  /// The incidents "server": `GET /v1/incidents`, `GET /v1/incidents/{id}` and `POST
  /// /v1/incidents/{id}/safe`. The open incident is the one the check-in server shows in
  /// Home, so both always agree; `incidents.open(...)` opens one.
  late final FakeIncidentServer incidents = FakeIncidentServer(
    serverOf: () => server,
    clock: clock.now,
    reauthenticated: () => auth.reauthenticated,
  )..attach();

  /// Use the production [incidentsRepositoryProvider] (the Dio one) instead of
  /// [incidents]. Only the wiring tests do this.
  bool realIncidentsRepository = false;

  /// The Activity "server": entries newest first, served in cursor pages.
  final FakeActivityServer activity = FakeActivityServer();

  /// Use the production [activityRepositoryProvider] (the Dio one) instead of
  /// [activity]. Only the wiring tests do this.
  bool realActivityRepository = false;

  /// The export and account deletion "server" (the 60-second password rule, the 3 an
  /// hour limit, the 401 after a deletion).
  late final FakePrivacyRepository accountData = FakePrivacyRepository(
    auth: auth,
    clock: clock.now,
  );

  /// Use the production [privacyRepositoryProvider] (the Dio one) instead of
  /// [accountData]. Only the wiring tests do this.
  bool realPrivacyRepository = false;

  /// The system's save dialog for the export.
  final FakeFileExportGateway exportGateway = FakeFileExportGateway();

  /// Retry and reset timers of the check-in controller (fired by hand).
  final FakeTimers timers = FakeTimers();

  /// Push: Firebase Cloud Messaging, not configured unless a test says so (so no other
  /// test ever registers a token), the foreground notifications, and the devices API.
  final FakePushGateway push = FakePushGateway();
  final FakeLocalNotificationGateway localNotifications =
      FakeLocalNotificationGateway();
  final FakeDevicesRepository devices = FakeDevicesRepository();

  /// Retry timers of the push registration (fired by hand), and where a tapped
  /// notification went.
  final FakeTimers pushTimers = FakeTimers();
  final List<String> pushRoutes = [];

  /// Use the production [devicesRepositoryProvider] (the Dio one) instead of [devices].
  /// Only the wiring tests do this.
  bool realDevicesRepository = false;

  /// Take a tapped notification to the real router instead of recording the route in
  /// [pushRoutes].
  bool realPushNavigation = false;

  /// The idempotency keys the check-in controller creates.
  final FakeKeys keys = FakeKeys();

  /// The idempotency keys of I'M SAFE confirmations (`key-1`, `key-2`, ...).
  final FakeKeys safeKeys = FakeKeys();

  /// Use the production schedule, check-in and Home repositories (the Dio ones).
  /// Only the wiring tests do this.
  bool realCheckInRepositories = false;

  /// Fresh in-memory preferences (the platform instance is replaced globally).
  PreferencesStore prefs = freshPreferences();

  /// The in-memory secure storage shared by everything this test wires up. It holds the
  /// id of the account the session belongs to (`user-1`, the one `tokenResponse()` and
  /// the fakes use): that is where the pending check-in reads its owner from.
  final InMemorySecureStore secure = InMemorySecureStore({
    SessionKeys.userId: 'user-1',
  });

  List<Override> get overrides => [
    if (!realAuthRepository) authRepositoryProvider.overrideWithValue(auth),
    localAuthGatewayProvider.overrideWithValue(localAuth),
    screenPrivacyProvider.overrideWithValue(privacy),
    secureScreenGatewayProvider.overrideWithValue(secureScreen),
    if (!realClipboard) clipboardGatewayProvider.overrideWithValue(clipboard),
    notificationPermissionGatewayProvider.overrideWithValue(notifications),
    urlOpenerProvider.overrideWithValue(urls),
    contactPickerProvider.overrideWithValue(picker),
    deviceInfoSourceProvider.overrideWithValue(device),
    clockProvider.overrideWithValue(clock.now),
    preferencesStoreProvider.overrideWithValue(prefs),
    if (!realContactsRepository)
      contactsRepositoryProvider.overrideWithValue(contacts),
    if (!realCheckInRepositories) ...[
      scheduleRepositoryProvider.overrideWithValue(server),
      checkInRepositoryProvider.overrideWithValue(server),
      homeRepositoryProvider.overrideWithValue(server),
    ],
    if (!realPlanRepository) planRepositoryProvider.overrideWithValue(plan),
    if (!realInstructionsRepository)
      instructionsRepositoryProvider.overrideWithValue(instructions),
    if (!realIncidentsRepository)
      incidentsRepositoryProvider.overrideWithValue(incidents),
    if (!realActivityRepository)
      activityRepositoryProvider.overrideWithValue(activity),
    if (!realPrivacyRepository)
      privacyRepositoryProvider.overrideWithValue(accountData),
    fileExportGatewayProvider.overrideWithValue(exportGateway),
    pushGatewayProvider.overrideWithValue(push),
    localNotificationGatewayProvider.overrideWithValue(localNotifications),
    if (!realDevicesRepository)
      devicesRepositoryProvider.overrideWithValue(devices),
    pushTimerProvider.overrideWithValue(pushTimers.create),
    if (!realPushNavigation)
      pushNavigateProvider.overrideWithValue(pushRoutes.add),
    checkInTimerProvider.overrideWithValue(timers.create),
    checkInKeyGeneratorProvider.overrideWithValue(keys.next),
    safeKeyGeneratorProvider.overrideWithValue(safeKeys.next),
  ];
}

/// A [PreferencesStore] on a fresh in-memory platform.
PreferencesStore freshPreferences([Map<String, Object>? initial]) {
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.withData(initial ?? {});
  return PreferencesStore(SharedPreferencesAsync());
}

/// Standard overrides for widget tests: config, client info, in-memory storage and all
/// platform fakes, and optionally a fixed auth status.
List<Override> testOverrides({
  AppConfig? config,
  AuthStatus? authStatus,
  SecureStore? secureStore,
  TestFakes? fakes,
}) {
  final wired = fakes ?? TestFakes();
  return [
    appConfigProvider.overrideWithValue(config ?? devConfig),
    clientInfoProvider.overrideWithValue(testClientInfo),
    secureStoreProvider.overrideWithValue(secureStore ?? wired.secure),
    ...wired.overrides,
    if (authStatus != null)
      authControllerProvider.overrideWith(
        () => FixedAuthController(authStatus),
      ),
  ];
}

/// Wraps [child] in a themed, localized MaterialApp for component tests.
Widget wrapForTest(
  Widget child, {
  ThemeData? theme,
  TextScaler textScaler = TextScaler.noScaling,
  MediaQueryData Function(MediaQueryData data)? mediaQuery,
}) => MaterialApp(
  theme: theme ?? AppTheme.light(),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    ...GlobalMaterialLocalizations.delegates,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Builder(
    builder: (context) => MediaQuery(
      data: (mediaQuery ?? (d) => d)(
        MediaQuery.of(context).copyWith(textScaler: textScaler),
      ),
      child: Scaffold(body: Center(child: child)),
    ),
  ),
);

/// Sets a phone-sized logical screen for the test and resets it afterwards.
void usePhoneScreen(WidgetTester tester, {Size size = const Size(390, 844)}) {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
}
