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
  });

  /// Builds a configuration from raw strings, validating every value.
  ///
  /// Rules:
  /// * `APP_ENV` must be `dev`, `staging` or `prod`.
  /// * `API_BASE_URL` must be an absolute http(s) URL with a host and no query,
  ///   fragment or credentials. Staging and prod must use https and must not point
  ///   at a loopback or emulator address.
  /// * `PUBLIC_BASE_URL` is the origin of the public web pages (terms, privacy, password
  ///   reset). It follows the same rules as `API_BASE_URL`; https is required outside
  ///   dev. In dev it may be omitted and then defaults to the API origin.
  /// * `SENTRY_DSN` is optional; when present it must be an absolute URL, https
  ///   outside dev.
  factory AppConfig.parse({
    required String appEnv,
    required String apiBaseUrl,
    String publicBaseUrl = '',
    String sentryDsn = '',
  }) {
    final env = AppEnv.parse(appEnv);
    final baseUrl = _parseBaseUrl(apiBaseUrl, env, name: 'API_BASE_URL');
    final publicUrl = publicBaseUrl.trim().isEmpty && env == AppEnv.dev
        ? baseUrl
        : _parseBaseUrl(publicBaseUrl, env, name: 'PUBLIC_BASE_URL');
    final dsn = _parseSentryDsn(sentryDsn, env);
    return AppConfig._(
      env: env,
      apiBaseUrl: baseUrl,
      publicBaseUrl: publicUrl,
      sentryDsn: dsn,
    );
  }

  /// Reads the compile-time values provided with `--dart-define-from-file`.
  factory AppConfig.fromEnvironment() => AppConfig.parse(
    appEnv: const String.fromEnvironment('APP_ENV'),
    apiBaseUrl: const String.fromEnvironment('API_BASE_URL'),
    publicBaseUrl: const String.fromEnvironment('PUBLIC_BASE_URL'),
    sentryDsn: const String.fromEnvironment('SENTRY_DSN'),
  );

  final AppEnv env;

  /// API origin, without a trailing slash. Request paths include `/v1/...`.
  final Uri apiBaseUrl;

  /// Origin of the public web pages (`/legal/terms`, `/legal/privacy`, `/a/reset`),
  /// without a trailing slash.
  final Uri publicBaseUrl;

  /// Error-monitoring DSN, or null when monitoring is not configured.
  final Uri? sentryDsn;

  bool get isDev => env == AppEnv.dev;

  /// A page on the public web origin, for example `publicUri('/legal/terms')`.
  Uri publicUri(String path) =>
      publicBaseUrl.replace(path: '${publicBaseUrl.path}$path');

  static const Set<String> _localHosts = {
    'localhost',
    '127.0.0.1',
    '10.0.2.2',
    '::1',
  };

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
      if (_localHosts.contains(uri.host)) {
        throw AppConfigException(
          '$name must not point at a local address in ${env.name}.',
        );
      }
    }
    final path = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return uri.replace(path: path);
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
      other.sentryDsn == sentryDsn;

  @override
  int get hashCode => Object.hash(env, apiBaseUrl, publicBaseUrl, sentryDsn);

  @override
  String toString() => 'AppConfig(env: ${env.name}, apiBaseUrl: $apiBaseUrl)';
}

/// The validated configuration. Always overridden in `main()` (and in tests).
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError(
    'appConfigProvider must be overridden with AppConfig.fromEnvironment().',
  ),
);
