import 'package:material_ui/material_ui.dart';

import '../../app/theme/dimens.dart';
import '../../app/theme/tokens.dart';

/// A centred progress indicator with an optional visible label. The label (or
/// [semanticsLabel]) is announced to screen readers.
class LoadingView extends StatelessWidget {
  const LoadingView({this.label, this.semanticsLabel, super.key});

  final String? label;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(semanticsLabel: semanticsLabel ?? label),
            if (label != null) ...[
              const SizedBox(height: AppSpacing.md),
              ExcludeSemantics(
                child: Text(
                  label!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: t.textMuted),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
