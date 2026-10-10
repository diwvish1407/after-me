import 'package:material_ui/material_ui.dart';

import '../../../app/theme/app_theme.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../l10n/gen/app_localizations.dart';

/// Developer-only gallery (route `/dev/gallery`, registered only in dev builds).
/// Shows every design-system component in every state, in the light and dark theme.
class DesignGalleryScreen extends StatelessWidget {
  const DesignGalleryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.galleryTitle)),
      body: ListView(
        children: [
          _ThemedGallery(title: l10n.galleryLight, theme: AppTheme.light()),
          _ThemedGallery(title: l10n.galleryDark, theme: AppTheme.dark()),
        ],
      ),
    );
  }
}

class _ThemedGallery extends StatelessWidget {
  const _ThemedGallery({required this.title, required this.theme});

  final String title;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return Material(
            color: context.tokens.bg,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.page),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(title, style: theme.textTheme.headlineMedium),
                  ),
                  _Group(
                    title: l10n.galleryButtons,
                    children: [
                      for (final variant in AppButtonVariant.values) ...[
                        AppButton(
                          label: _variantLabel(l10n, variant),
                          variant: variant,
                          onPressed: () {},
                        ),
                        AppButton(
                          label: _variantLabel(l10n, variant),
                          variant: variant,
                          icon: Icons.check_rounded,
                          onPressed: () {},
                        ),
                        AppButton(
                          label: _variantLabel(l10n, variant),
                          variant: variant,
                          isLoading: true,
                          onPressed: () {},
                        ),
                        AppButton(
                          label: l10n.galleryDisabled,
                          variant: variant,
                          onPressed: null,
                        ),
                      ],
                    ],
                  ),
                  _Group(
                    title: l10n.galleryCheckIn,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.md,
                        children: [
                          for (final state in CheckInButtonState.values)
                            CheckInButton(
                              state: state,
                              onPressed: state == CheckInButtonState.disabled
                                  ? null
                                  : () {},
                            ),
                        ],
                      ),
                    ],
                  ),
                  _Group(
                    title: l10n.galleryBanners,
                    children: [
                      StatusBanner(
                        kind: StatusBannerKind.info,
                        message: l10n.galleryBannerInfo,
                      ),
                      StatusBanner(
                        kind: StatusBannerKind.attention,
                        title: l10n.galleryBannerAttentionTitle,
                        message: l10n.galleryBannerAttention,
                      ),
                      StatusBanner(
                        kind: StatusBannerKind.escalation,
                        title: l10n.galleryBannerEscalationTitle,
                        message: l10n.galleryBannerEscalation,
                      ),
                    ],
                  ),
                  _Group(
                    title: l10n.galleryCards,
                    children: [
                      SectionCard(
                        title: l10n.gallerySampleTitle,
                        subtitle: l10n.gallerySampleBody,
                        child: Text(l10n.homeFinishBody),
                      ),
                    ],
                  ),
                  _Group(
                    title: l10n.galleryEmptyState,
                    children: [
                      EmptyState(
                        icon: Icons.people_outline_rounded,
                        title: l10n.peopleEmptyTitle,
                        message: l10n.peopleEmptyBody,
                        action: AppButton.secondary(
                          label: l10n.gallerySecondary,
                          onPressed: () {},
                        ),
                      ),
                    ],
                  ),
                  _Group(
                    title: l10n.galleryTextFields,
                    children: [
                      AppTextField(
                        label: l10n.galleryFieldLabel,
                        hint: l10n.galleryFieldHint,
                      ),
                      AppTextField(
                        label: l10n.galleryFieldLabel,
                        errorText: l10n.galleryFieldError,
                      ),
                      AppTextField(
                        label: l10n.galleryFieldLabel,
                        enabled: false,
                      ),
                      AppTextField(
                        label: l10n.galleryPasswordLabel,
                        obscureText: true,
                      ),
                    ],
                  ),
                  _Group(
                    title: l10n.galleryLoading,
                    children: [LoadingView(label: l10n.loading)],
                  ),
                  _Group(
                    title: l10n.galleryErrors,
                    children: [
                      ErrorView(
                        failure: const NetworkFailure(),
                        onRetry: () {},
                      ),
                      ErrorView(
                        failure: const RateLimitedFailure(
                          retryAfter: Duration(minutes: 10),
                        ),
                        onRetry: () {},
                      ),
                      const ErrorView(failure: UpgradeRequiredFailure()),
                      ErrorView(failure: const ServerFailure(), onRetry: () {}),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _variantLabel(
    AppLocalizations l10n,
    AppButtonVariant variant,
  ) => switch (variant) {
    AppButtonVariant.primary => l10n.galleryPrimary,
    AppButtonVariant.secondary => l10n.gallerySecondary,
    AppButtonVariant.text => l10n.galleryText,
  };
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          for (final child in children) ...[
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ],
      ),
    );
  }
}
