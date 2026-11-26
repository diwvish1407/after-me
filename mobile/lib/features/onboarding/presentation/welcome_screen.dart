import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/brand.dart';
import '../../../l10n/gen/app_localizations.dart';

/// The first screen: three swipeable cards, then sign-up. Sign in and Skip sit at the
/// top in pill buttons. The page fits one screen (no scrolling); only at very large text
/// sizes does the card area scroll inside itself.
/// USER_FLOWS.md §3 step 1.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({required this.showDevGallery, super.key});

  /// Shows the developer gallery link. True only in dev builds.
  final bool showDevGallery;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  final _pages = PageController(viewportFraction: 0.82);
  int _index = 0;

  static const _art = [
    BrandIllustration.welcomePrepare,
    BrandIllustration.welcomeCheckIn,
    BrandIllustration.welcomeDecide,
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int index) {
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final cards = [l10n.welcomeCard1, l10n.welcomeCard2, l10n.welcomeCard3];
    final last = _index == cards.length - 1;
    const onHero = Colors.white;
    return Scaffold(
      body: DecoratedBox(
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              // One screen, no scrolling, when there is room. On a small phone or at a
              // large text size the cards get a fixed height and the page scrolls.
              final roomy =
                  constraints.maxHeight >= 560 &&
                  MediaQuery.textScalerOf(context).scale(16) <= 20;
              final column = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: roomy ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.sm,
                      AppSpacing.page,
                      0,
                    ),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      runSpacing: AppSpacing.xs,
                      children: [
                        _PillButton(
                          label: l10n.signInTitle,
                          icon: Icons.login_rounded,
                          onPressed: () => context.push(AppRoutes.signIn),
                        ),
                        _PillButton(
                          label: l10n.welcomeSkip,
                          onPressed: () =>
                              context.push(AppRoutes.createAccount),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  const Center(child: LogoMark(size: 60)),
                  const SizedBox(height: AppSpacing.xs),
                  const Center(child: Wordmark(fontSize: 34)),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.page,
                    ),
                    child: Text(
                      l10n.tagline,
                      style: textTheme.titleSmall?.copyWith(
                        color: onHero,
                        fontWeight: FontWeight.w500,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // The swipeable cards take whatever height is left.
                  _flex(
                    roomy,
                    PageView.builder(
                      controller: _pages,
                      itemCount: cards.length,
                      onPageChanged: (i) => setState(() => _index = i),
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                          vertical: AppSpacing.xs,
                        ),
                        child: _WelcomeCard(
                          art: _art[i],
                          text: cards[i],
                          position: l10n.welcomeCardPosition(
                            i + 1,
                            cards.length,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.sm,
                      AppSpacing.page,
                      AppSpacing.md,
                    ),
                    child: Container(
                      // An opaque panel: the buttons never sit on the sky gradient.
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: t.bg,
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Dots(
                            count: cards.length,
                            index: _index,
                            onTap: _goTo,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          // Back on the left, the main action on the right; on a
                          // narrow screen or with large text they share the row.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              AppButton.text(
                                label: l10n.back,
                                onPressed: _index > 0
                                    ? () => _goTo(_index - 1)
                                    : null,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              // Get started only on the last card; Next before it.
                              Flexible(
                                child: last
                                    ? AppButton.primary(
                                        label: l10n.welcomeGetStarted,
                                        icon: Icons.arrow_forward_rounded,
                                        onPressed: () => context.push(
                                          AppRoutes.createAccount,
                                        ),
                                      )
                                    : AppButton.primary(
                                        label: l10n.welcomeNext,
                                        icon: Icons.arrow_forward_rounded,
                                        onPressed: () => _goTo(_index + 1),
                                      ),
                              ),
                            ],
                          ),
                          if (widget.showDevGallery)
                            AppButton.text(
                              label: l10n.welcomeOpenGallery,
                              icon: Icons.palette_outlined,
                              onPressed: () =>
                                  context.push(AppRoutes.devGallery),
                              expand: true,
                            ),
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: t.textMuted,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Expanded(
                                child: Text(
                                  l10n.notEmergencyService,
                                  style: textTheme.labelSmall?.copyWith(
                                    color: t.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
              return roomy ? column : SingleChildScrollView(child: column);
            },
          ),
        ),
      ),
    );
  }

  /// The cards fill the rest of the screen when it fits, else a fixed height.
  Widget _flex(bool roomy, Widget child) =>
      roomy ? Expanded(child: child) : SizedBox(height: 300, child: child);
}

/// A small action on the sky in an oval (pill) background.
class _PillButton extends StatelessWidget {
  const _PillButton({required this.label, required this.onPressed, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.2),
      shape: StadiumBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.55)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 72),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: Colors.white),
                  const SizedBox(width: AppSpacing.xxs),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
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
  });

  final BrandIllustration art;
  final String text;
  final String position;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      header: true,
      liveRegion: true,
      label: '$position. $text',
      child: ExcludeSemantics(
        child: GlassCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The picture shrinks with the room there is, so nothing overflows.
              final art = (constraints.maxHeight * 0.55).clamp(60.0, 170.0);
              return SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      BrandImage(this.art, height: art),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        text,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index, required this.onTap});

  final int count;
  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return ExcludeSemantics(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            GestureDetector(
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: i == index ? 22 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  color: i == index ? t.primary : t.border,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
