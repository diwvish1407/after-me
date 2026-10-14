import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The deployment environment a build targets (ARCHITECTURE.md §5.9).
enum AppEnv {
  dev,
  staging,
  prod;

  /// Parses the `APP_ENV` build value. Unknown values are a configuration error.
  static AppEnv parse(String raw) {
    final value = raw.trim().toLowerCase();
    for (final env in AppEnv.values) {
      if (env.name == value) {
        return env;
      }
    }
    throw AppConfigException(
      raw.trim().isEmpty
          ? 'APP_ENV is not set. Build with --dart-define-from-file=config/<env>.json '
                'together with --flavor <env>.'
          : 'APP_ENV "$raw" is not one of dev, staging, prod.',
    );
  }
}

/// Thrown when the build configuration is missing or unsafe. The app refuses to start.
@immutable
class AppConfigException implements Exception {
  const AppConfigException(this.message);

  final String message;

  @override
  String toString() => 'AppConfigException: $message';
}

/// The four public identifiers of a Firebase app (Phase 8: push).
///
/// They name the project and the app; they are **not secrets** (the same values are in
/// every installed APK, and an API key without the app's signature and package name
/// cannot act for it). They are read from `--dart-define-from-file` and handed to
/// `Firebase.initializeApp` at run time, so the build needs neither a `google-services.json`
/// nor the google-services Gradle plugin.
@immutable
class FirebaseSettings {
  const FirebaseSettings({
    required this.apiKey,
    required this.appId,
    required this.messagingSenderId,
    required this.projectId,
  });

  final String apiKey;
  final String appId;
  final String messagingSenderId;
  final String projectId;

  @override
  bool operator ==(Object other) =>
      other is FirebaseSettings &&
      other.apiKey == apiKey &&
      other.appId == appId &&
      other.messagingSenderId == messagingSenderId &&
      other.projectId == projectId;

  @override
  int get hashCode => Object.hash(apiKey, appId, messagingSenderId, projectId);

  /// Never prints the values: they are identifiers of the deployment, not for logs.
  @override
  String toString() => 'FirebaseSettings(<configured>)';
}

/// Validated, non-secret build configuration.
///
/// Values come from `--dart-define-from-file=config/<env>.json`. There are no secrets in
/// the app (ARCHITECTURE.md §5.9). Construction fails fast: an invalid configuration
/// throws [AppConfigException] instead of producing a half-working app.
@immutable
class AppConfig {
  const AppConfig._({
    required this.env,
    required this.apiBaseUrl,
    required this.publicBaseUrl,
    required this.sentryDsn,
    required this.playStoreUrl,
    required this.firebase,
    required this.screenshotMode,
  });

  /// Builds a configuration from raw strings, validating every value.
  ///
  /// Rules:
  /// * `APP_ENV` must be `dev`, `staging` or `prod`.
  /// * `API_BASE_URL` must be an absolute http(s) URL with a host and no query,
  ///   fragment or credentials. Staging and prod must use https and must not point
  ///   at a development-looking host ([isDevLookingHost]: loopback, the emulator alias,
  ///   a private network address, `.local`, a bare name). The reverse holds as well: a
  ///   dev build talks to a development-looking host only, and in dev plain `http` is for
  ///   [devCleartextHosts] only (the hosts the dev flavor's network security config
  ///   names), so a mixed-up configuration file is refused instead of used.
  /// * `PUBLIC_BASE_URL` is the origin of the public web pages (terms, privacy, password
  ///   reset). It follows the same rules as `API_BASE_URL`; https is required outside
  ///   dev. In dev it may be omitted and then defaults to the API origin.
  /// * `SENTRY_DSN` is optional; when present it must be an absolute URL, https
  ///   outside dev.
  /// * `PLAY_STORE_URL` is optional: where the "Update AfterMe" screen sends the person
  ///   when the server no longer supports this version (426). It must be an absolute
  ///   https URL; empty means the app's own Play Store page ([defaultPlayStoreUrl]).
  /// * `FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID` and
  ///   `FIREBASE_PROJECT_ID` are all empty (push is not configured: the app runs normally
  ///   and reports it calmly) or all set. Some of them without the others is a mistake
  ///   in the build's configuration and is refused like any other, with the missing
  ///   names.
  /// * `SCREENSHOT_MODE` is `false` (or absent) in every build that people use. `true`
  ///   makes the window capturable (`FLAG_SECURE` is not set) so that store screenshots
  ///   can be taken, and shows a "Screenshot mode" strip on every screen. It is refused
  ///   with `APP_ENV` prod, and any value that is not `true` or `false` is refused: a
  ///   typo must never switch a protection off, nor be silently read as "on".
  factory AppConfig.parse({
    required String appEnv,
    required String apiBaseUrl,
    String publicBaseUrl = '',
    String sentryDsn = '',
    String playStoreUrl = '',
    String firebaseApiKey = '',
    String firebaseAppId = '',
    String firebaseMessagingSenderId = '',
    String firebaseProjectId = '',
    String screenshotMode = '',
  }) {
    final env = AppEnv.parse(appEnv);
    final screenshots = _parseScreenshotMode(screenshotMode, env);
    final baseUrl = _parseBaseUrl(apiBaseUrl, env, name: 'API_BASE_URL');
    final publicUrl = publicBaseUrl.trim().isEmpty && env == AppEnv.dev
        ? baseUrl
        : _parseBaseUrl(publicBaseUrl, env, name: 'PUBLIC_BASE_URL');
    final dsn = _parseSentryDsn(sentryDsn, env);
    final store = _parsePlayStoreUrl(playStoreUrl);
    final firebase = _parseFirebase(
      apiKey: firebaseApiKey,
      appId: firebaseAppId,
      messagingSenderId: firebaseMessagingSenderId,
      projectId: firebaseProjectId,
    );
    return AppConfig._(
      env: env,
      apiBaseUrl: baseUrl,
      publicBaseUrl: publicUrl,
      sentryDsn: dsn,
      playStoreUrl: store,
      firebase: firebase,
      screenshotMode: screenshots,
    );
  }

  /// Reads the compile-time values provided with `--dart-define-from-file`.
  factory AppConfig.fromEnvironment() => AppConfig.parse(
    appEnv: const String.fromEnvironment('APP_ENV'),
    apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
    publicBaseUrl: const String.fromEnvironment('PUBLIC_BASE_URL'),
    sentryDsn: const String.fromEnvironment('SENTRY_DSN'),
    playStoreUrl: const String.fromEnvironment('PLAY_STORE_URL'),
    firebaseApiKey: const String.fromEnvironment('FIREBASE_API_KEY'),
    firebaseAppId: const String.fromEnvironment('FIREBASE_APP_ID'),
    firebaseMessagingSenderId: const String.fromEnvironment(
      'FIREBASE_MESSAGING_SENDER_ID',
    ),
    firebaseProjectId: const String.fromEnvironment('FIREBASE_PROJECT_ID'),
    screenshotMode: const String.fromEnvironment('SCREENSHOT_MODE'),
  );

  /// The app's own page in Google Play (the production application id).
  static final Uri defaultPlayStoreUrl = Uri.parse(
    'https://play.google.com/store/apps/details?id=app.afterme',
  );

  final AppEnv env;

  /// API origin, without a trailing slash. Request paths include `/v1/...`.
  final Uri apiBaseUrl;

  /// Origin of the public web pages (`/legal/terms`, `/legal/privacy`, `/a/reset`),
  /// without a trailing slash.
  final Uri publicBaseUrl;

  /// Error-monitoring DSN, or null when monitoring is not configured.
  final Uri? sentryDsn;

  /// Where the person updates the app (opened in Google Play).
  final Uri playStoreUrl;

  /// The Firebase app push runs on, or null when the build was made without one (push
  /// is then "not configured": nothing is registered and nothing arrives, and the app
  /// says so calmly).
  final FirebaseSettings? firebase;

  /// A build made to capture store screenshots: instruction screens are not
  /// `FLAG_SECURE`, and every screen carries a "Screenshot mode" strip. Never true in
  /// prod ([parse] refuses it).
  final bool screenshotMode;

  bool get isDev => env == AppEnv.dev;

  /// A page on the public web origin, for example `publicUri('/legal/terms')`.
  Uri publicUri(String path) =>
      publicBaseUrl.replace(path: '${publicBaseUrl.path}$path');

  /// The only hosts a dev build may reach over plain `http`: the emulator's alias for the
  /// host machine and loopback (`adb reverse`). They are the ones the dev flavor's
  /// `network_security_config.xml` names. Android's network security config does **not**
  /// bind `dart:io`, which the API client uses, so this list is enforced here (and by the
  /// `#flutter.io.allow_http` zone in `main()`), not by the platform.
  static const Set<String> devCleartextHosts = {
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    '::1',
  };

  /// Whether [host] belongs to a development setup rather than a deployed server: a
  /// loopback or private-network address, `localhost`, a `.local`/`.localhost`/
  /// `.internal`/`.lan` name, or a bare name with no dot. Such a host never appears in a
  /// staging or prod configuration, and a dev configuration never names anything else.
  static bool isDevLookingHost(String host) {
    final value = host.trim().toLowerCase();
    if (value.isEmpty) {
      return false;
    }
    if (devCleartextHosts.contains(value)) {
      return true;
    }
    const suffixes = [
      '.localhost',
      '.local',
      '.internal',
      '.lan',
      '.home.arpa',
    ];
    if (suffixes.any(value.endsWith)) {
      return true;
    }
    if (value.contains(':')) {
      // An IPv6 literal: loopback, unspecified, unique-local (fc00::/7) or link-local
      // (fe80::/10).
      return value == '::' ||
          value.startsWith('fc') ||
          value.startsWith('fd') ||
          RegExp(r'^fe[89ab]').hasMatch(value);
    }
    final octets = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(value);
    if (octets != null) {
      final a = int.parse(octets.group(1)!);
      final b = int.parse(octets.group(2)!);
      return a == 0 ||
          a == 10 ||
          a == 127 ||
          (a == 169 && b == 254) ||
          (a == 172 && b >= 16 && b <= 31) ||
          (a == 192 && b == 168);
    }
    // A bare name ("backend") is a machine on somebody's network, not a public host.
    return !value.contains('.');
  }

  /// The environment an application id belongs to, by the flavor's suffix: `.dev`,
  /// `.staging`, or none for the production id. The suffix (not the whole id) is what
  /// the flavors define in `build.gradle.kts`, so this keeps holding when the base
  /// application id is decided (D1).
  static AppEnv envOfPackage(String packageName) {
    final id = packageName.trim().toLowerCase();
    if (id.endsWith('.dev')) {
      return AppEnv.dev;
    }
    if (id.endsWith('.staging')) {
      return AppEnv.staging;
    }
    return AppEnv.prod;
  }

  /// Requires that the installed application id is the flavor of this configuration's
  /// `APP_ENV`. A `config/dev.json` built into the production flavor (or the reverse) is
  /// a mistake the build cannot catch by itself; the app refuses to run on it
  /// ([AppConfigException]) before it makes a single request.
  void requirePackage(String packageName) {
    final id = packageName.trim();
    if (id.isEmpty) {
      throw const AppConfigException(
        'The application id of this build is unknown, so its flavor cannot be '
        'matched to APP_ENV.',
      );
    }
    final flavor = envOfPackage(id);
    if (screenshotMode && flavor == AppEnv.prod) {
      // Parse already refuses this with APP_ENV prod; the installed id is the second
      // line: the production application id never runs without FLAG_SECURE.
      throw const AppConfigException(
        'SCREENSHOT_MODE is on in the production application. It is for the '
        'staging and dev flavors only.',
      );
    }
    if (flavor != env) {
      throw AppConfigException(
        'APP_ENV is ${env.name} but this is the ${flavor.name} flavor ("$id"). '
        'Build with --flavor ${env.name} together with '
        '--dart-define-from-file=config/${env.name}.json.',
      );
    }
  }

  /// The zone key `dart:ui` reads in its `dart:io` connection hook
  /// (`sky_engine/lib/ui/hooks.dart`, `_getHttpConnectionHookClosure`). With the value
  /// `false`, `HttpClient` refuses `http` to any non-loopback host with an
  /// `UnsupportedError`, whatever the platform's network security config says.
  static const Symbol allowHttpZoneKey = #flutter.io.allow_http;

  /// The values of the zone the whole app runs in (`main()`): plain `http` is allowed
  /// in dev only. A second line behind [parse], not a replacement for it.
  Map<Object?, Object?> get ioZoneValues => {allowHttpZoneKey: isDev};

  static Uri _parseBaseUrl(String raw, AppEnv env, {required String name}) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw AppConfigException('$name is not set.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw AppConfigException(
        '$name "$value" must be an absolute http(s) URL.',
      );
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw AppConfigException(
        '$name "$value" must not contain a query, fragment or credentials.',
      );
    }
    if (env != AppEnv.dev) {
      if (uri.scheme != 'https') {
        throw AppConfigException(
          '$name must use https in ${env.name} (got "$value").',
        );
      }
      if (isDevLookingHost(uri.host)) {
        throw AppConfigException(
          '$name must not point at a local or private-network address in '
          '${env.name} (a development configuration in a ${env.name} build?).',
        );
      }
    } else {
      if (!isDevLookingHost(uri.host)) {
        throw AppConfigException(
          '$name must point at this machine or network in dev, not at "${uri.host}". '
          'A deployed server is for the staging or prod flavor.',
        );
      }
      if (uri.scheme == 'http' && !devCleartextHosts.contains(uri.host)) {
        throw AppConfigException(
          '$name uses plain http in dev, which is only for '
          '${devCleartextHosts.join(', ')} (use `adb reverse` for a device).',
        );
      }
    }
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: path);
  }

  static Uri _parsePlayStoreUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      return defaultPlayStoreUrl;
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isAbsolute ||
        uri.host.isEmpty ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty) {
      throw AppConfigException(
        'PLAY_STORE_URL "$value" must be an absolute https URL.',
      );
    }
    return uri;
  }

  static FirebaseSettings? _parseFirebase({
    required String apiKey,
    required String appId,
    required String messagingSenderId,
    required String projectId,
  }) {
    final values = <String, String>{
      'FIREBASE_API_KEY': apiKey.trim(),
      'FIREBASE_APP_ID': appId.trim(),
      'FIREBASE_MESSAGING_SENDER_ID': messagingSenderId.trim(),
      'FIREBASE_PROJECT_ID': projectId.trim(),
    };
    final missing = [
      for (final entry in values.entries)
        if (entry.value.isEmpty) entry.key,
    ];
    if (missing.length == values.length) {
      return null;
    }
    if (missing.isNotEmpty) {
      throw AppConfigException(
        'The Firebase values go together: ${missing.join(', ')} '
        '${missing.length == 1 ? 'is' : 'are'} not set. Set all four, or leave all '
        'four empty to build without push.',
      );
    }
    if (values.values.any((value) => RegExp(r'\s').hasMatch(value))) {
      throw const AppConfigException(
        'The FIREBASE_* values must not contain spaces.',
      );
    }
    return FirebaseSettings(
      apiKey: values['FIREBASE_API_KEY']!,
      appId: values['FIREBASE_APP_ID']!,
      messagingSenderId: values['FIREBASE_MESSAGING_SENDER_ID']!,
      projectId: values['FIREBASE_PROJECT_ID']!,
    );
  }

  static bool _parseScreenshotMode(String raw, AppEnv env) {
    final value = raw.trim().toLowerCase();
    if (value.isEmpty || value == 'false') {
      return false;
    }
    if (value != 'true') {
      throw AppConfigException(
        'SCREENSHOT_MODE "${raw.trim()}" must be true or false.',
      );
    }
    if (env == AppEnv.prod) {
      throw const AppConfigException(
        'SCREENSHOT_MODE must not be true in a prod build: it switches off the '
        'protection of instruction screens.',
      );
    }
    return true;
  }

  static Uri? _parseSentryDsn(String raw, AppEnv env) {
    final value = raw.trim();
    if (value.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.isAbsolute || uri.host.isEmpty) {
      throw const AppConfigException('SENTRY_DSN must be an absolute URL.');
    }
    final secure = uri.scheme == 'https';
    if (!secure && (env != AppEnv.dev || uri.scheme != 'http')) {
      throw AppConfigException('SENTRY_DSN must use https in ${env.name}.');
    }
    return uri;
  }

  @override
  bool operator ==(Object other) =>
      other is AppConfig &&
      other.env == env &&
      other.apiBaseUrl == apiBaseUrl &&
      other.publicBaseUrl == publicBaseUrl &&
      other.sentryDsn == sentryDsn &&
      other.playStoreUrl == playStoreUrl &&
      other.firebase == firebase &&
      other.screenshotMode == screenshotMode;

  @override
  int get hashCode => Object.hash(
    env,
    apiBaseUrl,
    publicBaseUrl,
    sentryDsn,
    playStoreUrl,
    firebase,
    screenshotMode,
  );

  @override
  String toString() => 'AppConfig(env: ${env.name}, apiBaseUrl: $apiBaseUrl)';
}

/// The validated configuration. Always overridden in `main()` (and in tests).
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError(
    'appConfigProvider must be overridden with AppConfig.fromEnvironment().',
  ),
);
