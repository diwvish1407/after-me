import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api/upgrade_gate.dart';
import '../core/auth/auth_controller.dart';
import '../core/security/app_lock/app_lock_gate.dart';
import '../core/upgrade/upgrade_recheck.dart';
import '../core/upgrade/upgrade_required_gate.dart';
import '../features/home/application/home_controller.dart';
import '../features/notifications/presentation/push_host.dart';
import '../l10n/gen/app_localizations.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// The font family of both themes. Null in the app (the platform font); tests override
/// it with `Roboto` so layout is measured with real glyph widths.
final fontFamilyProvider = Provider<String?>((ref) => null);

/// The root widget: Material 3 light and dark themes from tokens, localizations, the
/// router, the "Update AfterMe" screen for a version the server refuses, and the app
/// lock above everything.
class AfterMeApp extends ConsumerWidget {
  const AfterMeApp({super.key});

  /// "Check again" on the update screen: one real request, and what it says is all that
  /// is claimed.
  ///
  /// * Signed in, Home is read again (a 200 clears the gate by itself, a 426 keeps it).
  /// * Signed out nothing is waiting to be sent, but the gate is still lifted only by an
  ///   answer: an unauthenticated request goes through the same version check (a 426
  ///   keeps the gate; a 401 `unauthenticated` proves the version is accepted).
  ///
  /// An answer that is neither (offline, a timeout, server trouble, a rate limit) is
  /// "inconclusive": the screen says it could not check, never "still not supported".
  Future<UpgradeRecheck> _recheck(WidgetRef ref) async {
    final signedIn = ref.read(authControllerProvider) == AuthStatus.signedIn;
    final failure = signedIn
        ? await ref.read(homeControllerProvider.notifier).refresh()
        : await ref.read(upgradeProbeProvider)();
    final result = classifyUpgradeRecheck(
      failure,
      gateRaised: ref.read(upgradeGateProvider),
    );
    if (result == UpgradeRecheck.accepted) {
      // A 2xx has lifted it already; any other answer from the API's own side of the
      // version check (a 401 after the session ended, say) lifts it here.
      ref.read(upgradeGateProvider.notifier).clear();
    }
    return result;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final fontFamily = ref.watch(fontFamilyProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appName,
      theme: AppTheme.light(fontFamily: fontFamily),
      darkTheme: AppTheme.dark(fontFamily: fontFamily),
      themeMode: ThemeMode.system,
      routerConfig: router,
      // The lock covers the navigator, so it also covers sheets and dialogs; the update
      // screen sits just under it and keeps everything below it alive. Push (Phase 8)
      // paints nothing: it starts the token's life and hears the app return.
      builder: (context, child) => PushHost(
        child: AppLockGate(
          child: UpgradeRequiredGate(
            onRecheck: () => _recheck(ref),
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ),
      // material_ui ships its own Material/Cupertino localizations (Flutter 3.47
      // moved Material out of the SDK); combine them with ours.
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      debugShowCheckedModeBanner: false,
    );
  }
}
