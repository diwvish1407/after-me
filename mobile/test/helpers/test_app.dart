import 'package:afterme/app/repository_providers.dart';
import 'package:afterme/app/theme/app_theme.dart';
import 'package:afterme/core/api/client_info.dart';
import 'package:afterme/core/auth/auth_controller.dart';
import 'package:afterme/core/config/app_config.dart';
import 'package:afterme/core/device/device_info_source.dart';
import 'package:afterme/core/links/url_opener.dart';
import 'package:afterme/core/permissions/notification_permission.dart';
import 'package:afterme/core/platform/contact_picker.dart';
import 'package:afterme/core/security/app_lock/local_auth_gateway.dart';
import 'package:afterme/core/security/screen_privacy.dart';
import 'package:afterme/core/storage/preferences_store.dart';
import 'package:afterme/core/storage/secure_store.dart';
import 'package:afterme/core/time/clock.dart';
import 'package:afterme/features/auth/data/auth_repository.dart';
import 'package:afterme/features/checkin/application/checkin_controller.dart';
import 'package:afterme/features/checkin/data/models/checkin_models.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'fake_auth_repository.dart';
import 'fake_checkin_server.dart';
import 'fake_plan_server.dart';
import 'fake_platform.dart';
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
       notifications = notifications ?? FakeNotificationPermissionGateway();

  final FakeAuthRepository auth;
  final FakeLocalAuthGateway localAuth;
  final FakeNotificationPermissionGateway notifications;
  final FakeScreenPrivacy privacy = FakeScreenPrivacy();
  final FakeUrlOpener urls = FakeUrlOpener();
  final FakeContactPicker picker = FakeContactPicker();
  final FakeDeviceInfoSource device = FakeDeviceInfoSource();
  final FakeClock clock = FakeClock();

  /// The contacts "server" (tests script it; the app itself uses the real API).
  InMemoryContactsRepository contacts = InMemoryContactsRepository();

  /// Use the production [contactsRepositoryProvider] (the Dio one) instead of
  /// [contacts]. Only the wiring tests do this.
  bool realContactsRepository = false;

  /// The check-in "server": schedule, check-ins and the Home aggregate. It reads the
  /// contacts above, so readiness and activation follow what the test did there.
  late final FakeCheckInServer server = FakeCheckInServer(
    clock: clock.now,
    contacts: () => contacts.contacts,
    plan: () => plan,
    reauthenticated: () => auth.reauthenticated,
    displayName: auth.displayName,
    timezone: auth.timezone,
  );

  /// The plan "server": `GET` and `PUT /v1/plan` with the backend's validation. The
  /// check-in server above reads it for activation and the Home aggregate.
  late final FakePlanServer plan = FakePlanServer(
    contacts: () => contacts.contacts,
    tier: () => contacts.tier,
    incidentOpen: () => server.status == CheckInStatus.incidentOpen,
  );

  /// Use the production [planRepositoryProvider] (the Dio one) instead of [plan]. Only
  /// the wiring tests do this.
  bool realPlanRepository = false;

  /// Retry and reset timers of the check-in controller (fired by hand).
  final FakeTimers timers = FakeTimers();

  /// The idempotency keys the check-in controller creates.
  final FakeKeys keys = FakeKeys();

  /// Use the production schedule, check-in and Home repositories (the Dio ones).
  /// Only the wiring tests do this.
  bool realCheckInRepositories = false;

  /// Fresh in-memory preferences (the platform instance is replaced globally).
  PreferencesStore prefs = freshPreferences();

  /// The in-memory secure storage shared by everything this test wires up.
  final InMemorySecureStore secure = InMemorySecureStore();

  List<Override> get overrides => [
    authRepositoryProvider.overrideWithValue(auth),
    localAuthGatewayProvider.overrideWithValue(localAuth),
    screenPrivacyProvider.overrideWithValue(privacy),
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
    checkInTimerProvider.overrideWithValue(timers.create),
    checkInKeyGeneratorProvider.overrideWithValue(keys.next),
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
