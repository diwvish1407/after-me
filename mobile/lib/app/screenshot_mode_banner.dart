import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';

/// A thin strip on top of every screen of a screenshot build (`SCREENSHOT_MODE`, never
/// the production build), so that such a build can never be mistaken for the real app.
///
/// It takes its own row, with the status-bar inset inside it: nothing of the app is
/// covered, the app below it sees no top inset again, and a capture can be cropped
/// cleanly. It ignores the system text scale (it is a marker, not content) and is read
/// out by a screen reader as one line.
class ScreenshotModeBanner extends StatelessWidget {
  const ScreenshotModeBanner({required this.child, super.key});

  final Widget child;

  /// The height of the strip, below the status bar.
  static const double height = 20;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final scheme = Theme.of(context).colorScheme;
    final label = AppLocalizations.of(context).screenshotModeBanner;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          label: label,
          excludeSemantics: true,
          child: Material(
            color: scheme.inverseSurface,
            child: SizedBox(
              height: media.padding.top + height,
              child: Padding(
                padding: EdgeInsets.only(top: media.padding.top),
                child: Center(
                  child: MediaQuery.withNoTextScaling(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(
                        color: scheme.onInverseSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery(
            data: media.removePadding(removeTop: true),
            child: child,
          ),
        ),
      ],
    );
  }
}
