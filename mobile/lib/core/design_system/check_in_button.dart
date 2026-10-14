import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import 'progress_spinner.dart';

/// Visual states of the check-in button (USER_FLOWS.md §1.3, §5).
enum CheckInButtonState {
  /// Ready: "I'M OK".
  idle,

  /// The check-in is being sent.
  sending,

  /// The server confirmed the check-in. Never shown before that (USER_FLOWS.md §5).
  success,

  /// Not received yet; the app keeps retrying. Tapping retries now.
  pending,

  /// Check-ins are not available (no active plan).
  disabled,
}

/// The large circular I'M OK button.
///
/// * At least 160 dp across; it grows with the text scale so the label never needs
///   truncating. It is sized from the widest unbreakable word of the label, so a word
///   is never split across lines, and everything stays inside the circle's inscribed
///   square.
/// * Every state has its own icon **and** text, so state is never colour-only.
/// * Semantics: a button whose label is the visible text, a hint that explains the
///   state, and a live region so TalkBack announces state changes.
/// * Haptic feedback on press.
///
/// The button never decides success: callers move it to [CheckInButtonState.success]
/// only after the server confirms.
class CheckInButton extends StatelessWidget {
  const CheckInButton({
    required this.state,
    required this.onPressed,
    super.key,
  });

  final CheckInButtonState state;

  /// Called on tap in the idle and pending states.
  final VoidCallback? onPressed;

  bool get _interactive =>
      onPressed != null &&
      (state == CheckInButtonState.idle || state == CheckInButtonState.pending);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final visuals = _visualsFor(state, t, l10n);

    final textScale = MediaQuery.textScalerOf(context).scale(24) / 24;
    final labelStyle = AppTypography.checkInLabel.copyWith(
      color: visuals.textColor,
    );
    final widestWord = _widestWord(context, visuals.label, labelStyle);
    // The inscribed square of a circle has side d / sqrt(2); the widest word must fit it.
    final neededForWord = widestWord * math.sqrt2;
    final preferred = math.max(
      AppSizes.checkInButton * (textScale > 1 ? 0.6 + 0.4 * textScale : 1),
      neededForWord,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : double.infinity;
        final diameter = maxWidth < preferred
            ? (maxWidth < AppSizes.checkInButton
                  ? AppSizes.checkInButton
                  : maxWidth)
            : preferred;
        // Content lives in the inscribed square. If the diameter was capped so a word is
        // wider than the square, lay the column out at the word's width and let FittedBox
        // scale the whole label down evenly rather than break the word.
        final square = diameter / math.sqrt2;
        final contentWidth = math.max(square, widestWord);

        return Semantics(
          container: true,
          button: true,
          enabled: _interactive,
          liveRegion: true,
          label: visuals.label,
          hint: visuals.hint,
          onTap: _interactive ? _handleTap : null,
          excludeSemantics: true,
          child: SizedBox.square(
            dimension: diameter,
            child: Material(
              color: visuals.fill,
              shape: CircleBorder(
                side: visuals.border == null
                    ? BorderSide.none
                    : BorderSide(color: visuals.border!, width: 3),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: _interactive ? _handleTap : null,
                customBorder: const CircleBorder(),
                child: Center(
                  child: SizedBox.square(
                    dimension: square,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _StateIcon(state: state, color: visuals.iconColor),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              visuals.label,
                              textAlign: TextAlign.center,
                              style: labelStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Width of the widest word of [label] at the current text scale.
  static double _widestWord(
    BuildContext context,
    String label,
    TextStyle style,
  ) {
    // Measure with the style `Text` will actually use: the inherited default merged with
    // ours, plus the system bold-text setting. Otherwise the widths can differ.
    var effective = DefaultTextStyle.of(context).style.merge(style);
    if (MediaQuery.boldTextOf(context)) {
      effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: label, style: effective),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    // +1 dp so sub-pixel rounding can never push the word over the box and split it.
    final width = painter.minIntrinsicWidth + 1;
    painter.dispose();
    return width;
  }

  void _handleTap() {
    unawaited(HapticFeedback.mediumImpact());
    onPressed?.call();
  }

  static _Visuals _visualsFor(
    CheckInButtonState state,
    AppColorTokens t,
    AppLocalizations l10n,
  ) => switch (state) {
    CheckInButtonState.idle => _Visuals(
      label: l10n.checkInLabelIdle,
      hint: l10n.checkInHintIdle,
      fill: t.primary,
      textColor: t.onPrimary,
      iconColor: t.onPrimary,
    ),
    CheckInButtonState.sending => _Visuals(
      label: l10n.checkInLabelSending,
      hint: l10n.checkInHintSending,
      fill: t.primary,
      textColor: t.onPrimary,
      iconColor: t.onPrimary,
    ),
    CheckInButtonState.success => _Visuals(
      label: l10n.checkInLabelSuccess,
      hint: l10n.checkInHintSuccess,
      fill: t.ok,
      textColor: t.onPrimary,
      iconColor: t.onPrimary,
    ),
    CheckInButtonState.pending => _Visuals(
      label: l10n.checkInLabelPending,
      hint: l10n.checkInHintPending,
      fill: t.surface,
      textColor: t.text,
      iconColor: t.attention,
      border: t.attention,
    ),
    CheckInButtonState.disabled => _Visuals(
      label: l10n.checkInLabelIdle,
      hint: l10n.checkInHintDisabled,
      fill: t.surface,
      textColor: t.textMuted,
      iconColor: t.textMuted,
      border: t.border,
    ),
  };
}

class _Visuals {
  const _Visuals({
    required this.label,
    required this.hint,
    required this.fill,
    required this.textColor,
    required this.iconColor,
    this.border,
  });

  final String label;
  final String hint;
  final Color fill;
  final Color textColor;
  final Color iconColor;
  final Color? border;
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.state, required this.color});

  final CheckInButtonState state;
  final Color color;

  static const double _size = 36;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    switch (state) {
      case CheckInButtonState.sending:
        return SizedBox.square(
          dimension: _size,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxs),
            child: ProgressSpinner(
              strokeWidth: 3,
              color: color,
              // A translucent track keeps the moving arc visible on filled colours.
              backgroundColor: color.withValues(alpha: 0.3),
            ),
          ),
        );
      case CheckInButtonState.idle:
        icon = Icons.check_rounded;
      case CheckInButtonState.success:
        icon = Icons.check_circle_rounded;
      case CheckInButtonState.pending:
        icon = Icons.schedule_rounded;
      case CheckInButtonState.disabled:
        icon = Icons.lock_clock_outlined;
    }
    return Icon(icon, size: _size, color: color);
  }
}
