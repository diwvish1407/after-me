import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../core/api/client_info.dart';
import '../core/config/app_config.dart';
import '../core/config/misconfigured_build_app.dart';
import '../features/onboarding/presentation/splash_screen.dart';
import '../l10n/gen/app_localizations.dart';
import 'app.dart';
import 'theme/app_theme.dart';

/// The root of the app: it puts the first frame on screen at once and starts the app
/// when the build's identity is known.
///
/// `PackageInfo.fromPlatform()` is a platform-channel call that queues behind the
/// platform's own start-up work (on a slow phone it can take hundreds of milliseconds),
/// and the configuration check that needs its answer ([AppConfig.requirePackage]) must
/// run before anything else does. So the first frame is the plain splash (the same page
/// the app shows while it reads the saved session), which creates no provider, reads no
/// storage and makes no request; when the answer is in:
///
/// * the flavor matches: the app starts (`ProviderScope` + [AfterMeApp]);
/// * it does not, or the answer cannot be had: [MisconfiguredBuildApp], and nothing else
///   ever runs (fail closed, exactly as before).
class AfterMeStart extends StatefulWidget {
  const AfterMeStart({
    required this.config,
    this.loadPackageInfo = PackageInfo.fromPlatform,
    this.extraOverrides = const [],
    super.key,
  });

  final AppConfig config;

  /// Reads the installed package's identity. Tests pass their own.
  final Future<PackageInfo> Function() loadPackageInfo;

  /// Provider overrides added to the app's own (tests only).
  final List<Override> extraOverrides;

  @override
  State<AfterMeStart> createState() => _AfterMeStartState();
}

class _AfterMeStartState extends State<AfterMeStart> {
  late final Future<PackageInfo> _info = widget.loadPackageInfo();

  /// What the check decided; null while the answer is pending.
  Widget? _app;

  @override
  void initState() {
    super.initState();
    _info.then<void>(_ready, onError: _failed);
  }

  void _ready(PackageInfo info) {
    if (!mounted) {
      return;
    }
    try {
      // The flavor (application id) must be the one this configuration is for: a dev
      // configuration in the production package, or the reverse, never gets to run.
      widget.config.requirePackage(info.packageName);
    } on AppConfigException catch (error) {
      setState(() => _app = MisconfiguredBuildApp(message: error.message));
      return;
    }
    setState(
      () => _app = ProviderScope(
        // Failed loads show a Retry button; they are not silently retried in a loop.
        retry: (retryCount, error) => null,
        overrides: [
          appConfigProvider.overrideWithValue(widget.config),
          clientInfoProvider.overrideWithValue(
            ClientInfo.fromPackageInfo(info),
          ),
          ...widget.extraOverrides,
        ],
        child: const AfterMeApp(),
      ),
    );
  }

  void _failed(Object error, StackTrace stack) {
    if (!mounted) {
      return;
    }
    setState(
      () => _app = const MisconfiguredBuildApp(
        message:
            'The application id of this build could not be read, so its flavor '
            'cannot be matched to APP_ENV.',
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _app ?? const _StartSplash();
}

/// The first frame: the splash page in the app's themes and strings, with no state.
class _StartSplash extends StatelessWidget {
  const _StartSplash();

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    onGenerateTitle: (context) => AppLocalizations.of(context).appName,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: ThemeMode.system,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      ...GlobalMaterialLocalizations.delegates,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: const SplashScreen(),
  );
}
