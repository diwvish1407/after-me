import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app/start.dart';
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
  runZoned(() {
    WidgetsFlutterBinding.ensureInitialized();
    // The first frame is the splash; the app starts when the package check is done (see
    // AfterMeStart).
    runApp(AfterMeStart(config: config));
  }, zoneValues: config.ioZoneValues);
}
