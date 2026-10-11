import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/freshness/stale_data.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../onboarding/application/setup_controller.dart';
import '../application/contacts_controller.dart';
import '../data/contacts_repository.dart';
import 'contact_labels.dart';
import 'contact_limit_sheet.dart';
import 'contact_status_chip.dart';

/// Opens the Add screen, or the plan-limit sheet when the plan's contact limit is used
/// up. The limit comes from the entitlements already loaded; when they are not known,
/// the Add screen opens and the server enforces the limit (the form then shows the sheet).
void addContactOrExplainLimit(BuildContext context, WidgetRef ref) {
  final entitlements = ref.read(entitlementsProvider).value;
  if (entitlements != null && entitlements.contactsAtLimit) {
    unawaited(
      showContactLimitSheet(
        context,
        limit: entitlements.limits.contacts,
        free: entitlements.isFree,
      ),
    );
    return;
  }
  unawaited(context.push(AppRoutes.peopleAdd));
}

/// People: the trusted contacts, their status, and the way to add more (USER_FLOWS §8).
///
/// A contact accepts the invitation somewhere this app cannot see, so the list is read
/// again whenever the tab comes back into view (and when Home's counts disagree with it,
/// see `HomeController`). It is read silently: the list on screen stays, with its scroll
/// position, until the new one replaces it.
class PeopleScreen extends ConsumerStatefulWidget {
  const PeopleScreen({super.key});

  @override
  ConsumerState<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends ConsumerState<PeopleScreen> {
  /// Whether the screen was on view the last time its surroundings changed; null before
  /// the first build (which loads the list by itself).
  bool? _onView;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The shell keeps every tab alive and switches off the animations of the hidden ones
    // (and a page pushed above also hides this one), so this is "became visible".
    final onView = TickerMode.valuesOf(context).enabled;
    final cameBack = _onView == false && onView;
    _onView = onView;
    if (cameBack) {
      unawaited(
        Future<void>.microtask(() {
          if (mounted) {
            unawaited(ref.read(contactsControllerProvider.notifier).reload());
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final contacts = ref.watch(contactsControllerProvider);
    // Loaded here so that Add knows the limit before it opens.
    ref.watch(entitlementsProvider);
    final plan = ref.watch(setupControllerProvider).value?.plan;
    final planIds = <String>{};
    if (plan != null) {
      for (final stage in plan.stages) {
        planIds.addAll(stage.contactIds);
      }
    }
    Future<void> refresh() async {
      final messenger = ScaffoldMessenger.of(context);
      ref.invalidate(entitlementsProvider);
      final failure = await ref
          .read(contactsControllerProvider.notifier)
          .reload();
      if (failure != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(l10n, failure))),
        );
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.navPeople),
        actions: [
          if (contacts.value?.isNotEmpty ?? false)
            IconButton(
              tooltip: l10n.peopleAddContact,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              onPressed: () => addContactOrExplainLimit(context, ref),
            ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: refresh,
          child: CenteredScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: contacts.when(
              skipLoadingOnReload: true,
              data: (items) => items.isEmpty
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const StaleDataNote(area: DataArea.contacts),
                        EmptyState(
                          icon: Icons.people_outline_rounded,
                          title: l10n.peopleEmptyTitle,
                          message: l10n.peopleEmptyBody,
                          action: AppButton.primary(
                            label: l10n.peopleAddContact,
                            icon: Icons.person_add_alt_1_outlined,
                            onPressed: () =>
                                addContactOrExplainLimit(context, ref),
                          ),
                        ),
                      ],
                    )
                  : _ContactList(
                      contacts: items,
                      planContactIds: planIds,
                      onAdd: () => addContactOrExplainLimit(context, ref),
                    ),
              loading: () => const LoadingView(),
              error: (error, _) => ErrorView(
                failure: error is AppFailure
                    ? error
                    : UnknownFailure(cause: error),
                onRetry: () => unawaited(
                  ref.read(contactsControllerProvider.notifier).reload(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContactList extends StatelessWidget {
  const _ContactList({
    required this.contacts,
    required this.planContactIds,
    required this.onAdd,
  });

  final List<TrustedContact> contacts;
  final Set<String> planContactIds;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StaleDataNote(area: DataArea.contacts),
        _ReadinessHint(
          readiness: peopleReadiness(contacts, planContactIds: planContactIds),
          unreachable: unreachableCount(contacts),
        ),
        for (final contact in contacts) _ContactRow(contact: contact),
        Gap.md,
        AppButton.secondary(
          label: AppLocalizations.of(context).peopleAddContact,
          icon: Icons.person_add_alt_1_outlined,
          onPressed: onAdd,
          expand: true,
        ),
      ],
    );
  }
}

/// The contact-related readiness hint (USER_FLOWS §4): who cannot be notified yet.
class _ReadinessHint extends StatelessWidget {
  const _ReadinessHint({required this.readiness, required this.unreachable});

  final PeopleReadiness readiness;
  final int unreachable;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final (StatusBannerKind kind, String message)? hint = switch (readiness) {
      PeopleReadiness.ready => null,
      PeopleReadiness.nobodyAccepted => (
        StatusBannerKind.info,
        l10n.peopleHintNoneAccepted,
      ),
      PeopleReadiness.planWaiting => (
        StatusBannerKind.info,
        l10n.peopleHintPlanPending,
      ),
      PeopleReadiness.unreachable => (
        StatusBannerKind.attention,
        l10n.peopleHintProblem(unreachable),
      ),
    };
    if (hint == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Semantics(
        container: true,
        child: StatusBanner(kind: hint.$1, message: hint.$2),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  const _ContactRow({required this.contact});

  final TrustedContact contact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final relationship = contactRelationshipText(l10n, contact);
    final explanation = statusExplanation(l10n, contact.verificationStatus);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        button: true,
        excludeSemantics: true,
        label: l10n.peopleListSemantics(
          contact.displayName,
          relationship,
          statusLabel(l10n, contact.verificationStatus),
          explanation,
        ),
        onTap: () => context.push(AppRoutes.contactDetail(contact.id)),
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: () => context.push(AppRoutes.contactDetail(contact.id)),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(contact.displayName, style: textTheme.titleMedium),
                        Text(
                          relationship,
                          style: textTheme.bodyMedium?.copyWith(
                            color: t.textMuted,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        ContactStatusChip(status: contact.verificationStatus),
                        const SizedBox(height: AppSpacing.xs),
                        Text(explanation, style: textTheme.bodyMedium),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xxs),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      color: t.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
