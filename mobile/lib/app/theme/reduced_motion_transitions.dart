import 'package:material_ui/material_ui.dart';

/// Page transitions that stand still when the person asked the phone to remove
/// animations (`MediaQuery.disableAnimationsOf`, which follows the system setting): the
/// new page is simply there. Otherwise it is the platform's own transition, unchanged.
///
/// (Flutter already shortens every animation controller to a single frame under that
/// setting; this removes even that frame and the movement within it.)
class ReducedMotionPageTransitionsBuilder extends PageTransitionsBuilder {
  const ReducedMotionPageTransitionsBuilder(this.base);

  /// The transition used when motion is allowed.
  final PageTransitionsBuilder base;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      base.delegatedTransition;

  @override
  Duration get transitionDuration => base.transitionDuration;

  @override
  Duration get reverseTransitionDuration => base.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return base.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}

/// The app's page transitions: Android's own (predictive back) and the zoom transition
/// elsewhere, each wrapped so that they stand still under "remove animations". The app is
/// Android-only for 1.0; the other platforms are listed so that a desktop test run or a
/// later iOS build never falls back to a transition that ignores the setting.
PageTransitionsTheme reducedMotionPageTransitions() =>
    const PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        TargetPlatform.android: ReducedMotionPageTransitionsBuilder(
          PredictiveBackPageTransitionsBuilder(),
        ),
        TargetPlatform.iOS: ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
        TargetPlatform.macOS: ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
        TargetPlatform.windows: ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
        TargetPlatform.linux: ReducedMotionPageTransitionsBuilder(
          ZoomPageTransitionsBuilder(),
        ),
      },
    );
