import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/empty_state.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The first screen: three short cards (skippable), then sign-up or sign-in.
/// USER_FLOWS.md §3 step 1.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({required this.showDevGallery, super.key});

  /// Shows the developer gallery link. True only in dev builds.
  final bool showDevGallery;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  int _index = 0;

  static const _icons = [
    Icons.event_available_outlined,
    Icons.touch_app_outlined,
    Icons.tune_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final cards = [l10n.welcomeCard1, l10n.welcomeCard2, l10n.welcomeCard3];
    final last = _index == cards.length - 1;
    return Scaffold(
      body: SafeArea(
        child: CenteredScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: AppButton.text(
                  label: l10n.welcomeSkip,
                  onPressed: () => context.push(AppRoutes.createAccount),
                ),
              ),
              Icon(Icons.favorite_border_rounded, size: 48, color: t.primary),
              const SizedBox(height: AppSpacing.md),
              Semantics(
                header: true,
                child: Text(
                  l10n.appName,
                  style: textTheme.displaySmall,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.tagline,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              _WelcomeCard(
                key: ValueKey(_index),
                icon: _icons[_index],
                text: cards[_index],
                position: l10n.welcomeCardPosition(_index + 1, cards.length),
              ),
              const SizedBox(height: AppSpacing.sm),
              _Dots(count: cards.length, index: _index),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Both buttons stay in the tree (disabled at the ends), so the
                  // focused one never disappears and screen-reader focus is not lost.
                  AppButton.text(
                    label: l10n.back,
                    onPressed: _index > 0
                        ? () => setState(() => _index--)
                        : null,
                  ),
                  AppButton.text(
                    label: l10n.welcomeNext,
                    onPressed: last ? null : () => setState(() => _index++),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton.primary(
                label: l10n.welcomeGetStarted,
                onPressed: () => context.push(AppRoutes.createAccount),
                expand: true,
              ),
              const SizedBox(height: AppSpacing.xs),
              AppButton.text(
                label: l10n.welcomeSignIn,
                onPressed: () => context.push(AppRoutes.signIn),
                expand: true,
              ),
              if (widget.showDevGallery) ...[
                const SizedBox(height: AppSpacing.xs),
                AppButton.text(
                  label: l10n.welcomeOpenGallery,
                  icon: Icons.palette_outlined,
                  onPressed: () => context.push(AppRoutes.devGallery),
                  expand: true,
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: t.textMuted,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      l10n.notEmergencyService,
                      style: textTheme.bodySmall?.copyWith(color: t.textMuted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({
    required this.icon,
    required this.text,
    required this.position,
    super.key,
  });

  final IconData icon;
  final String text;
  final String position;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // A live region: pressing Next swaps the card, and the new position and text are
    // announced together (and read once, not twice).
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$position. $text',
      child: ExcludeSemantics(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              children: [
                Icon(icon, size: 40, color: t.primary),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i == index ? t.primary : t.border,
              ),
            ),
        ],
      ),
    );
  }
}
