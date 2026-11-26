import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/design_system/brand.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/data/auth_repository.dart';

/// Signed-in shell: five destinations in the bottom navigation bar (Home, Instructions,
/// Check-in, Contacts, Profile) over six branches (the plan has no tab of its own), and
/// the side menu (USER_FLOWS.md §2; design screens 14 and 20).
/// Each tab keeps its own navigation stack (StatefulShellRoute.indexedStack).
class AppShell extends StatefulWidget {
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

  /// Whether the page on top of [navigator] refuses to be left without asking (it holds a
  /// `PopScope` that does not allow popping right now).
  static bool _topPageGuards(NavigatorState navigator) {
    Route<dynamic>? top;
    // Peeks at the top route; the predicate stops at once, so nothing is popped.
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final route = top;
    return route is ModalRoute &&
        route.popDisposition == RoutePopDisposition.doNotPop;
  }

  /// Navigation-bar destination -> shell branch (see `AppRoutes.shellTabs`):
  /// Home, Instructions, Check-in, Contacts, Profile.
  static const List<int> destinationBranches = [0, 2, 5, 1, 4];

  /// The destination shown as selected for a branch. The plan branch opens from Home
  /// and the menu, so Home stays selected there.
  static int destinationFor(int branch) {
    final index = destinationBranches.indexOf(branch);
    return index < 0 ? 0 : index;
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  DateTime? _lastBack;

  void _onBack(bool didPop) {
    if (didPop) {
      return;
    }
    final shell = widget.navigationShell;
    if (shell.currentIndex != 0) {
      shell.goBranch(0);
      return;
    }
    final now = DateTime.now();
    final last = _lastBack;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      unawaited(SystemNavigator.pop());
      return;
    }
    _lastBack = now;
    final l10n = AppLocalizations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(l10n.backAgainToExit),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  /// A tab was tapped. Another tab shows its own stack as it was. The current tab again
  /// returns to its first page (the usual tab-bar behaviour), **unless the page on top
  /// guards something**: a page that asks "Leave without saving?" (the plan editor) must
  /// be asked the same question as when Back is pressed, instead of being thrown away
  /// with its draft. Then the tap does exactly what Back does there.
  void _onSelected(int index) {
    if (index != widget.navigationShell.currentIndex) {
      widget.navigationShell.goBranch(index);
      return;
    }
    final navigator =
        widget.navigationShell.route.branches[index].navigatorKey.currentState;
    if (navigator != null &&
        navigator.canPop() &&
        AppShell._topPageGuards(navigator)) {
      unawaited(navigator.maybePop());
      return;
    }
    widget.navigationShell.goBranch(index, initialLocation: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final labels = [
      l10n.navHome,
      l10n.navInstructions,
      l10n.navCheckIn,
      l10n.navContacts,
      l10n.navProfile,
    ];
    // Back on a tab's first page goes to Home; on Home it asks for a second press before
    // leaving the app (a page pushed on top is popped by the router before this).
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) => _onBack(didPop),
      child: Scaffold(
        key: shellScaffoldKey,
        drawer: AppDrawer(onSelectBranch: _onSelected),
        body: widget.navigationShell,
        bottomNavigationBar: LayoutBuilder(
          builder: (context, constraints) => MediaQuery.withClampedTextScaling(
            maxScaleFactor: AppShell.labelScaleCap(
              context,
              labels,
              constraints.maxWidth,
            ),
            child: NavigationBar(
              selectedIndex: AppShell.destinationFor(
                widget.navigationShell.currentIndex,
              ),
              onDestinationSelected: (index) =>
                  _onSelected(AppShell.destinationBranches[index]),
              destinations: [
                NavigationDestination(
                  icon: const Icon(Icons.home_outlined),
                  selectedIcon: const Icon(Icons.home_rounded),
                  label: labels[0],
                ),
                NavigationDestination(
                  icon: const Icon(Icons.description_outlined),
                  selectedIcon: const Icon(Icons.description_rounded),
                  label: labels[1],
                ),
                NavigationDestination(
                  icon: const Icon(Icons.event_available_outlined),
                  selectedIcon: const Icon(Icons.event_available_rounded),
                  label: labels[2],
                ),
                NavigationDestination(
                  icon: const Icon(Icons.people_outline_rounded),
                  selectedIcon: const Icon(Icons.people_rounded),
                  label: labels[3],
                ),
                NavigationDestination(
                  icon: const Icon(Icons.person_outline_rounded),
                  selectedIcon: const Icon(Icons.person_rounded),
                  label: labels[4],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The shell's scaffold, so a page can open the menu (the Home menu button).
final GlobalKey<ScaffoldState> shellScaffoldKey = GlobalKey<ScaffoldState>();

/// Opens the side menu of the signed-in shell, if it is on screen.
void openAppDrawer() => shellScaffoldKey.currentState?.openDrawer();

/// The side menu (design screen 20): the person, then every area of the app. Admins
/// also see the admin screens.
class AppDrawer extends ConsumerWidget {
  const AppDrawer({required this.onSelectBranch, super.key});

  /// Switches to a shell branch (as the navigation bar does).
  final void Function(int branch) onSelectBranch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    final account = ref.watch(accountProvider).value;
    final name = account?.profile.displayName ?? '';
    void go(String route, {int? branch}) {
      Navigator.of(context).pop();
      if (branch != null) {
        onSelectBranch(branch);
        if (route.isEmpty) {
          return;
        }
      }
      unawaited(GoRouter.of(context).push(route));
    }

    Widget item(
      IconData icon,
      String label,
      VoidCallback onTap, {
      Color? color,
    }) => ListTile(
      leading: Icon(icon, color: color ?? t.primary),
      title: Text(label, style: text.titleSmall?.copyWith(color: color)),
      trailing: Icon(Icons.chevron_right_rounded, color: t.textMuted),
      onTap: onTap,
    );

    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: const BoxDecoration(gradient: brandHeaderGradient),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const BrandBar(),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: Colors.white,
                        child: Text(
                          name.isEmpty
                              ? '?'
                              : name.characters.first.toUpperCase(),
                          style: text.titleLarge?.copyWith(
                            color: BrandColors.skyMid,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: text.titleMedium?.copyWith(
                                color: Colors.white,
                              ),
                            ),
                            if (account != null)
                              Text(
                                account.email,
                                style: text.bodySmall?.copyWith(
                                  color: Colors.white,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            item(Icons.home_rounded, l10n.navHome, () => go('', branch: 0)),
            item(
              Icons.layers_outlined,
              l10n.drawerMyPlan,
              () => go('', branch: 3),
            ),
            item(
              Icons.description_outlined,
              l10n.navInstructions,
              () => go('', branch: 2),
            ),
            item(
              Icons.people_outline_rounded,
              l10n.drawerContacts,
              () => go('', branch: 1),
            ),
            item(
              Icons.event_available_outlined,
              l10n.drawerSchedule,
              () => go('', branch: 5),
            ),
            item(
              Icons.shield_outlined,
              l10n.drawerSecurity,
              () => go(AppRoutes.settingsSecurity, branch: 4),
            ),
            item(
              Icons.bar_chart_rounded,
              l10n.drawerActivity,
              () => go(AppRoutes.settingsActivity, branch: 4),
            ),
            item(
              Icons.ios_share_rounded,
              l10n.drawerExport,
              () => go(AppRoutes.settingsExport, branch: 4),
            ),
            item(
              Icons.help_outline_rounded,
              l10n.drawerHelp,
              () => go(AppRoutes.settingsAbout, branch: 4),
            ),
            const Divider(),
            item(
              Icons.settings_outlined,
              l10n.drawerSettings,
              () => go('', branch: 4),
            ),
            if (account?.role == 'admin')
              item(
                Icons.admin_panel_settings_rounded,
                l10n.drawerAdmin,
                () => go(AppRoutes.admin, branch: 4),
                color: t.escalation,
              ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}
