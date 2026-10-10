import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app/app.dart';
import 'core/api/client_info.dart';
import 'core/config/app_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Fail fast: a build without a valid --dart-define-from-file config must not start.
  final config = AppConfig.fromEnvironment();
  final clientInfo = ClientInfo.fromPackageInfo(
    await PackageInfo.fromPlatform(),
  );

  runApp(
    ProviderScope(
      // Failed loads show a Retry button; they are not silently retried in a loop.
      retry: (retryCount, error) => null,
      overrides: [
        appConfigProvider.overrideWithValue(config),
        clientInfoProvider.overrideWithValue(clientInfo),
      ],
      child: const AfterMeApp(),
    ),
  );
}
