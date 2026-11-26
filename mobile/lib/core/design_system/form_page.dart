import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';
import '../../l10n/gen/app_localizations.dart';
import '../api/failures/app_failure.dart';
import 'empty_state.dart';
import 'error_view.dart';
import 'status_banner.dart';

/// A page with an app bar and a scrolling, width-limited column. Everything reflows
/// at large text sizes (USER_FLOWS.md §1.4). Used by every form-like screen.
class FormPage extends StatelessWidget {
  const FormPage({
    required this.title,
    this.children = const <Widget>[],
    this.body,
    this.footer,
    this.leading,
    this.actions,
    this.automaticallyImplyLeading = true,
    super.key,
  });

  final String title;

  /// The page's content, top-aligned, scrolling only when it does not fit.
  final List<Widget> children;

  /// Replaces [children] for content that lays out its own scrolling and footer (a form
  /// with `pinActions`).
  final Widget? body;

  /// The actions fixed at the bottom of the screen (an [ActionBar]).
  final Widget? footer;
  final Widget? leading;
  final List<Widget>? actions;
  final bool automaticallyImplyLeading;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: leading,
        actions: actions,
        automaticallyImplyLeading: automaticallyImplyLeading,
      ),
      body: SafeArea(
        child:
            body ??
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: CenteredScrollView(
                    alignTop: true,
                    physics: const ClampingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: children,
                    ),
                  ),
                ),
                ?footer,
              ],
            ),
      ),
    );
  }
}

/// A calm in-form message for a failed request, announced to screen readers.
class FailureNotice extends StatelessWidget {
  const FailureNotice({required this.message, super.key});

  FailureNotice.of(BuildContext context, AppFailure failure, {super.key})
    : message = failureMessage(AppLocalizations.of(context), failure);

  final String message;

  @override
  Widget build(BuildContext context) {
    return StatusBanner(
      kind: StatusBannerKind.attention,
      message: message,
      liveRegion: true,
    );
  }
}

/// Body text under a title (a subtitle): small and greyed out.
class BodyText extends StatelessWidget {
  const BodyText(this.text, {this.textAlign, super.key});

  final String text;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: textAlign,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: context.tokens.textMuted),
    );
  }
}

/// A page heading (announced as a heading by screen readers).
class PageHeading extends StatelessWidget {
  const PageHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.headlineSmall),
    );
  }
}

/// Vertical gap helpers.
abstract final class Gap {
  static const xs = SizedBox(height: AppSpacing.xs);
  static const sm = SizedBox(height: AppSpacing.sm);
  static const md = SizedBox(height: AppSpacing.md);
  static const lg = SizedBox(height: AppSpacing.lg);
  static const xl = SizedBox(height: AppSpacing.xl);
}
