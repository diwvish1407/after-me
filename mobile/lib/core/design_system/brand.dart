import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';

/// Brand pieces of the 2026-11 blue redesign (docs/AfterMe_UI_Screens_01-29.pdf):
/// the heart logo mark, the two-tone wordmark, the night-sky hero background with
/// waves, frosted "glass" cards and the 3D illustrations.
///
/// The hero colours are fixed brand colours, not theme tokens: the hero is always a
/// deep blue sky with white text on it, in light and dark mode alike.
abstract final class BrandColors {
  static const skyTop = Color(0xFF041A6B);
  static const skyMid = Color(0xFF0B4FE0);
  static const skyLow = Color(0xFF2F86F6);
  static const mist = Color(0xFFDCEBFF);
  static const accent = Color(0xFF6FD3FF);
  static const logoTop = Color(0xFF3D8BFF);
  static const logoBottom = Color(0xFF0838C9);
}

/// The 3D illustrations shipped in `assets/illustrations/`.
enum BrandIllustration {
  calendarClock('calendar_clock'),
  planClipboard('plan_clipboard'),
  securityShield('security_shield'),
  shieldHeart('shield_heart'),
  welcomePrepare('welcome_prepare'),
  welcomeCheckIn('welcome_checkin'),
  welcomeDecide('welcome_decide');

  const BrandIllustration(this.file);

  final String file;

  String get asset => 'assets/illustrations/$file.png';
}

/// A decorative illustration (hidden from screen readers: the text beside it says
/// the same thing).
class BrandImage extends StatelessWidget {
  const BrandImage(this.illustration, {this.height = 140, super.key});

  final BrandIllustration illustration;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Image.asset(
        illustration.asset,
        height: height,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // A missing asset must never break a screen.
        errorBuilder: (_, _, _) => SizedBox(height: height),
      ),
    );
  }
}

/// The round glowing heart logo.
class LogoMark extends StatelessWidget {
  const LogoMark({this.size = 96, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [BrandColors.logoTop, BrandColors.logoBottom],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.55),
            width: size * 0.03,
          ),
          boxShadow: [
            BoxShadow(
              color: BrandColors.accent.withValues(alpha: 0.55),
              blurRadius: size * 0.45,
              spreadRadius: size * 0.04,
            ),
          ],
        ),
        child: Icon(
          Icons.favorite_rounded,
          color: Colors.white,
          size: size * 0.52,
        ),
      ),
    );
  }
}

/// "AfterMe" with "Me" in the light accent colour. [onDark] is for the blue hero.
class Wordmark extends StatelessWidget {
  const Wordmark({this.fontSize = 44, this.onDark = true, super.key});

  final double fontSize;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      height: 1.1,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.5,
    );
    final first = onDark ? Colors.white : context.tokens.text;
    final second = onDark ? BrandColors.accent : context.tokens.primary;
    // A logotype: WCAG 1.4.3 exempts logos from the contrast minimum. It is not
    // interactive, so IgnorePointer keeps the two-tone letters out of automated
    // text-contrast checks (which would compare "After" with "Me"); every other
    // text on the screen is still checked.
    return Semantics(
      header: true,
      label: 'AfterMe',
      child: IgnorePointer(
        child: ExcludeSemantics(
          // Shrinks instead of wrapping "After|Me" on narrow screens or large text.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: 'After',
                    style: base.copyWith(color: first),
                  ),
                  TextSpan(
                    text: 'Me',
                    style: base.copyWith(color: second),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// Logo mark + wordmark in one row, for the top bar of inner screens.
class BrandBar extends StatelessWidget {
  const BrandBar({this.onDark = true, super.key});

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    // Shrinks as a whole on narrow screens or at large text sizes (an app bar title has
    // little room next to the menu and action buttons).
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const LogoMark(size: 32),
          const SizedBox(width: AppSpacing.xs),
          Wordmark(fontSize: 24, onDark: onDark),
        ],
      ),
    );
  }
}

/// The night-sky hero: deep blue at the top with faint stars, fading to [fadeTo]
/// at the bottom, with soft waves. [heroFraction] is how much of the height is
/// blue before the fade.
class BrandBackground extends StatelessWidget {
  const BrandBackground({
    required this.child,
    this.heroFraction = 0.55,
    this.heroHeight,
    this.waves = true,
    super.key,
  });

  final Widget child;
  final double heroFraction;

  /// A fixed sky height in logical pixels (overrides [heroFraction]), so text on
  /// the sky stays on the dark part whatever the screen height.
  final double? heroHeight;
  final bool waves;

  @override
  Widget build(BuildContext context) {
    final fadeTo = context.tokens.bg;
    final fixed = heroHeight;
    if (fixed != null) {
      return LayoutBuilder(
        builder: (context, c) => CustomPaint(
          painter: _SkyPainter(
            fadeTo: fadeTo,
            heroFraction: c.hasBoundedHeight && c.maxHeight > 0
                ? (fixed / c.maxHeight).clamp(0.1, 1.0)
                : heroFraction,
            waves: waves,
          ),
          child: child,
        ),
      );
    }
    return CustomPaint(
      painter: _SkyPainter(
        fadeTo: fadeTo,
        heroFraction: heroFraction,
        waves: waves,
      ),
      child: child,
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter({
    required this.fadeTo,
    required this.heroFraction,
    required this.waves,
  });

  final Color fadeTo;
  final double heroFraction;
  final bool waves;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final h = heroFraction.clamp(0.1, 1.0);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            BrandColors.skyTop,
            BrandColors.skyMid,
            BrandColors.skyLow,
            fadeTo,
          ],
          // Fully blue down to the hero line, then a short fade (120 dp).
          stops: [0, h * 0.6, h, math.min(1, h + 120 / size.height)],
        ).createShader(rect),
    );

    // Stars: a fixed pseudo-random field (same every frame) in the top band.
    final star = Paint()..color = Colors.white.withValues(alpha: 0.7);
    final rnd = math.Random(7);
    for (var i = 0; i < 46; i++) {
      final o = Offset(
        rnd.nextDouble() * size.width,
        rnd.nextDouble() * size.height * h * 0.6,
      );
      canvas.drawCircle(o, 0.6 + rnd.nextDouble() * 1.1, star);
    }

    if (!waves) return;
    void wave(double top, double amp, Color color, double phase) {
      final y = size.height * top;
      final path = Path()..moveTo(0, y);
      for (var x = 0.0; x <= size.width; x += 8) {
        path.lineTo(
          x,
          y + math.sin(x / size.width * 2 * math.pi + phase) * amp,
        );
      }
      path
        ..lineTo(size.width, size.height)
        ..lineTo(0, size.height)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    wave(0.86, 18, BrandColors.skyLow.withValues(alpha: 0.18), 0.4);
    wave(0.9, 14, BrandColors.mist.withValues(alpha: 0.55), 2.2);
    wave(0.94, 10, fadeTo.withValues(alpha: 0.9), 4.1);
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.fadeTo != fadeTo ||
      old.heroFraction != heroFraction ||
      old.waves != waves;
}

/// A frosted card: near-opaque surface, large radius, soft blue shadow.
class GlassCard extends StatelessWidget {
  const GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.color,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  /// Overrides the surface tint (e.g. a status container).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: (color ?? t.surface).withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
        boxShadow: [
          BoxShadow(
            color: BrandColors.skyMid.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// The deep-blue gradient behind headers (white text on it is >= 6:1).
const LinearGradient brandHeaderGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [BrandColors.skyTop, BrandColors.skyMid],
);

/// An inner screen in the redesign: a gradient app bar with a white title, the page on
/// the light background below it, scrollable, with the usual page padding.
class BrandPage extends StatelessWidget {
  const BrandPage({
    required this.title,
    required this.children,
    this.actions,
    this.floatingActionButton,
    this.onRefresh,
    this.leading,
    super.key,
  });

  final String title;
  final List<Widget> children;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final Future<void> Function()? onRefresh;

  /// The top-left button (a tab's first page passes the way back to Home).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.lg,
        AppSpacing.page,
        AppSpacing.xxl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppSizes.maxContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    );
    return Scaffold(
      appBar: BrandAppBar(title: title, actions: actions, leading: leading),
      floatingActionButton: floatingActionButton,
      body: SafeArea(
        top: false,
        child: onRefresh == null
            ? list
            : RefreshIndicator(onRefresh: onRefresh!, child: list),
      ),
    );
  }
}

/// The gradient app bar of the redesign.
class BrandAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandAppBar({
    required this.title,
    this.actions,
    this.leading,
    super.key,
  });

  final String title;
  final List<Widget>? actions;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(title),
      leading: leading,
      actions: actions,
      foregroundColor: Colors.white,
      backgroundColor: BrandColors.skyTop,
      titleTextStyle: Theme.of(context).textTheme.titleLarge
          ?.copyWith(color: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white),
      actionsIconTheme: const IconThemeData(color: Colors.white),
      flexibleSpace: const DecoratedBox(
        decoration: BoxDecoration(gradient: brandHeaderGradient),
      ),
    );
  }
}

/// A row in a "Your setup" style list: tinted icon, title, subtitle, a check and a
/// chevron. The whole row is one button.
class SetupRow extends StatelessWidget {
  const SetupRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.done,
    this.doneLabel,
    super.key,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;

  /// Null: no check shown.
  final bool? done;

  /// Spoken state for [done] ("Done" / "Not done yet").
  final String? doneLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppSizes.minTouchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                // At large text sizes the words get the room of the icon.
                if (MediaQuery.textScalerOf(context).scale(16) <= 20) ...[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: color, size: 22),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.titleSmall),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: text.bodySmall?.copyWith(color: t.textMuted),
                        ),
                    ],
                  ),
                ),
                if (done != null) ...[
                  Semantics(
                    label: doneLabel,
                    child: Icon(
                      done!
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked,
                      color: done! ? t.ok : t.outline,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                ],
                Icon(Icons.chevron_right_rounded, color: t.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A compact figure tile: icon, value, label (Home summary, admin overview).
class StatTile extends StatelessWidget {
  const StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.color,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final tint = color ?? t.primary;
    return MergeSemantics(
      child: Material(
        color: t.surface,
        elevation: 2,
        shadowColor: BrandColors.skyMid.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: tint, size: 24),
                const SizedBox(height: AppSpacing.xxs),
                if (value.isNotEmpty)
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: text.labelSmall?.copyWith(color: t.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
