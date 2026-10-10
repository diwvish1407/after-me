import 'dart:math' as math;

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Signed-in shell: five tabs with a bottom navigation bar (USER_FLOWS.md §2).
/// Each tab keeps its own navigation stack (StatefulShellRoute.indexedStack).
class AppShell extends StatelessWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  /// Largest label text scale at which the longest label still fits one destination.
  ///
  /// The system's own scaling is capped at 1.3 by [NavigationBar]. On narrow screens a
  /// scaled label such as "Instructions" would wrap in the middle of the word and push
  /// its icon out of line with the others, so the cap is lowered to what actually fits
  /// (never below [_minLabelScale], which keeps the text readable).
  static double labelScaleCap(
    BuildContext context,
    List<String> labels,
    double barWidth,
  ) {
    final style = DefaultTextStyle.of(context).style.merge(
      Theme.of(context).navigationBarTheme.labelTextStyle
          ?.resolve({WidgetState.selected}),
    );
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: Directionality.of(context),
      )..layout();
      widest = math.max(widest, painter.minIntrinsicWidth);
      painter.dispose();
    }
    final room = barWidth / labels.length - AppSizes.navLabelPadding;
    return widest <= 0
        ? _maxLabelScale
        : (room / widest).clamp(_minLabelScale, _maxLabelScale);
  }

  static const double _maxLabelScale = 1.3;
  static const double _minLabelScale = 0.85;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = [
      l10n.navHome,
      l10n.navPeople,
      l10n.navInstructions,
      l10n.navPlan,
      l10n.navSettings,
    ];
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: LayoutBuilder(
        builder: (context, constraints) => MediaQuery.withClampedTextScaling(
          maxScaleFactor: labelScaleCap(context, labels, constraints.maxWidth),
          child: NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (index) => navigationShell.goBranch(
              index,
              // Tapping the current tab again returns to its first page.
              initialLocation: index == navigationShell.currentIndex,
            ),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_outlined),
                selectedIcon: const Icon(Icons.home_rounded),
                label: labels[0],
              ),
              NavigationDestination(
                icon: const Icon(Icons.people_outline_rounded),
                selectedIcon: const Icon(Icons.people_rounded),
                label: labels[1],
              ),
              NavigationDestination(
                icon: const Icon(Icons.description_outlined),
                selectedIcon: const Icon(Icons.description_rounded),
                label: labels[2],
              ),
              NavigationDestination(
                icon: const Icon(Icons.timeline_outlined),
                selectedIcon: const Icon(Icons.timeline_rounded),
                label: labels[3],
              ),
              NavigationDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings_rounded),
                label: labels[4],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
