import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/design_system/brand.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Shown while the saved session is read at start-up (AuthStatus.unknown).
/// Design: docs/AfterMe_UI_Screens_01-29.pdf, screen 01.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      body: BrandBackground(
        heroFraction: 0.78,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LogoMark(size: 112),
                  const SizedBox(height: AppSpacing.lg),
                  const Wordmark(fontSize: 52),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    l10n.tagline,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  const ExcludeSemantics(
                    child: SizedBox.square(
                      dimension: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Color(0x33FFFFFF),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.splashLoading,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
