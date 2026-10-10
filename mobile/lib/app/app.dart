import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/security/app_lock/app_lock_gate.dart';
import '../l10n/gen/app_localizations.dart';
import 'router.dart';
import 'theme/app_theme.dart';

/// The font family of both themes. Null in the app (the platform font); tests override
/// it with `Roboto` so layout is measured with real glyph widths.
final fontFamilyProvider = Provider<String?>((ref) => null);

/// The root widget: Material 3 light and dark themes from tokens, localizations, the
/// router, and the app lock above everything.
class AfterMeApp extends ConsumerWidget {
  const AfterMeApp({super.key});

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
      // The lock covers the navigator, so it also covers sheets and dialogs.
      builder: (context, child) =>
          AppLockGate(child: child ?? const SizedBox.shrink()),
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
