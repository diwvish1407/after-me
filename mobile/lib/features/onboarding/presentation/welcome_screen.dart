import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/brand.dart';
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

  static const _art = [
    BrandIllustration.welcomePrepare,
    BrandIllustration.welcomeCheckIn,
    BrandIllustration.welcomeDecide,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final cards = [l10n.welcomeCard1, l10n.welcomeCard2, l10n.welcomeCard3];
    final last = _index == cards.length - 1;
    int at(int offset) => (_index + offset) % cards.length;
    // Large text: the centre card alone, full width (no squeezed side cards).
    final roomy = MediaQuery.textScalerOf(context).scale(16) <= 20;
    const onHero = Colors.white;
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The sky is part of the content (not a screen background), so the
            // white text always sits on deep blue, whatever the screen height.
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    BrandColors.skyTop,
                    BrandColors.skyMid,
                    BrandColors.skyLow,
                    BrandColors.mist,
                  ],
                  stops: [0, 0.42, 0.72, 1],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.page,
                    AppSpacing.sm,
                    AppSpacing.page,
                    AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Sign in sits at the top too, so a returning person never has
                      // to scroll past the cards to find it.
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        children: [
                          TextButton.icon(
                            style: TextButton.styleFrom(
                              foregroundColor: onHero,
                            ),
                            onPressed: () => context.push(AppRoutes.signIn),
                            icon: const Icon(Icons.login_rounded, size: 20),
                            label: Text(l10n.signInTitle),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: onHero,
                            ),
                            onPressed: () =>
                                context.push(AppRoutes.createAccount),
                            child: Text(l10n.welcomeSkip),
                          ),
                        ],
                      ),
                      const Center(child: LogoMark(size: 72)),
                      const SizedBox(height: AppSpacing.sm),
                      const Center(child: Wordmark(fontSize: 40)),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        l10n.tagline,
                        style: textTheme.titleMedium?.copyWith(
                          color: onHero,
                          fontWeight: FontWeight.w500,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (roomy)
                            Expanded(
                              flex: 5,
                              child: _SideCard(
                                art: _art[at(-1 + cards.length)],
                                text: cards[at(-1 + cards.length)],
                                tilt: -0.08,
                              ),
                            ),
                          Expanded(
                            flex: 7,
                            child: _WelcomeCard(
                              key: ValueKey(_index),
                              art: _art[_index],
                              text: cards[_index],
                              position: l10n.welcomeCardPosition(
                                _index + 1,
                                cards.length,
                              ),
                            ),
                          ),
                          if (roomy)
                            Expanded(
                              flex: 5,
                              child: _SideCard(
                                art: _art[at(1)],
                                text: cards[at(1)],
                                tilt: 0.08,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  AppSpacing.lg,
                ),
                child: Container(
                  // An opaque panel: the buttons never sit on the sky gradient,
                  // whatever the screen height or text size.
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: t.bg,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
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
                            onPressed: last
                                ? null
                                : () => setState(() => _index++),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      AppButton.primary(
                        label: l10n.welcomeGetStarted,
                        icon: Icons.arrow_forward_rounded,
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
                      const SizedBox(height: AppSpacing.lg),
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        decoration: BoxDecoration(
                          color: t.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 20,
                              color: t.primary,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                l10n.notEmergencyService,
                                style: textTheme.bodySmall?.copyWith(
                                  color: t.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({
    required this.art,
    required this.text,
    required this.position,
    super.key,
  });

  final BrandIllustration art;
  final String text;
  final String position;

  @override
  Widget build(BuildContext context) {
    // A live region: pressing Next swaps the card, and the new position and text are
    // announced together (and read once, not twice).
    // Also the screen's heading once the wordmark has scrolled away.
    return Semantics(
      container: true,
      header: true,
      liveRegion: true,
      label: '$position. $text',
      child: ExcludeSemantics(
        child: GlassCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              BrandImage(art, height: 130),
              const SizedBox(height: AppSpacing.sm),
              Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A neighbouring card, tilted and smaller (decoration only; the centre card is the
/// one read by screen readers).
class _SideCard extends StatelessWidget {
  const _SideCard({required this.art, required this.text, required this.tilt});

  final BrandIllustration art;
  final String text;
  final double tilt;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Transform.rotate(
        angle: tilt,
        child: Transform.scale(
          scale: 0.86,
          child: Opacity(
            opacity: 0.85,
            child: GlassCard(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  BrandImage(art, height: 84),
                  // At large text sizes the narrow side cards show only the art.
                  if (MediaQuery.textScalerOf(context).scale(16) <= 20) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
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
