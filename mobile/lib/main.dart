import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/app.dart';
import 'core/api/client_info.dart';
import 'core/config/app_config.dart';
import 'core/config/misconfigured_build_app.dart';

void main() {
  // Fail closed: a build without a valid --dart-define-from-file config must not start,
  // and must not make a request. The configuration is compile-time values, so it is read
  // (and refused) before anything else exists.
  final AppConfig config;
  try {
    config = AppConfig.fromEnvironment();
  } on AppConfigException catch (error) {
    runApp(MisconfiguredBuildApp(message: error.message));
    return;
  }
  // The whole app runs in a zone that tells `dart:io`'s HttpClient whether plain http is
  // allowed (dev only). Android's network security config does not govern `dart:io`,
  // so this, together with AppConfig's own https rule, is what refuses cleartext in
  // staging and prod (SECURITY.md §11). The binding must be created in the same zone as
  // `runApp`, so everything starts inside it.
  runZoned(() => unawaited(_start(config)), zoneValues: config.ioZoneValues);
}

Future<void> _start(AppConfig config) async {
  WidgetsFlutterBinding.ensureInitialized();

  final PackageInfo info;
  try {
    info = await PackageInfo.fromPlatform();
    // The flavor (application id) must be the one this configuration is for: a dev
    // configuration in the production package, or the reverse, never gets to run.
    config.requirePackage(info.packageName);
  } on AppConfigException catch (error) {
    runApp(MisconfiguredBuildApp(message: error.message));
    return;
  }

  runApp(
    ProviderScope(
      // Failed loads show a Retry button; they are not silently retried in a loop.
      retry: (retryCount, error) => null,
      overrides: [
        appConfigProvider.overrideWithValue(config),
        clientInfoProvider.overrideWithValue(ClientInfo.fromPackageInfo(info)),
      ],
      child: const AfterMeApp(),
    ),
  );
}
