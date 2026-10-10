import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../contacts/application/contacts_controller.dart';
import '../../plan/application/plan_controller.dart';
import '../application/instructions_controller.dart';
import '../data/instructions_repository.dart';
import 'instruction_labels.dart';
import 'instruction_limit_sheet.dart';
import 'instruction_starter_cards.dart';
import 'instruction_starters.dart';
import 'instruction_status_chip.dart';

/// Opens the Add screen (with [starter] filled in, when given), or the plan-limit sheet
/// when the plan's instruction limit is used up. The limit comes from the entitlements
/// already loaded; when they are not known, the Add screen opens and the server enforces
/// the limit (the form then shows the sheet).
void addInstructionOrExplainLimit(
  BuildContext context,
  WidgetRef ref, {
  InstructionStarter? starter,
}) {
  final entitlements = ref.read(entitlementsProvider).value;
  if (entitlements != null && entitlements.instructionsAtLimit) {
    unawaited(
      showInstructionLimitSheet(
        context,
        limit: entitlements.limits.instructions,
        free: entitlements.isFree,
      ),
    );
    return;
  }
  unawaited(context.push(AppRoutes.instructionNew, extra: starter?.name));
}

/// Instructions: the person's instructions by category, who receives each and when, and
/// the way to write more (USER_FLOWS §9). Titles are content, so the whole tab keeps the
/// window `FLAG_SECURE` while it is on screen (FR-INS-06).
class InstructionsScreen extends ConsumerWidget {
  const InstructionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final items = ref.watch(instructionsControllerProvider);
    // Loaded here so that Add knows the limit before it opens.
    ref.watch(entitlementsProvider);
    Future<void> refresh() async {
      final messenger = ScaffoldMessenger.of(context);
      ref.invalidate(entitlementsProvider);
      final failure = await ref
          .read(instructionsControllerProvider.notifier)
          .reload();
      if (failure != null) {
        messenger.showSnackBar(
          SnackBar(content: Text(failureMessage(l10n, failure))),
        );
      }
    }

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(l10n.navInstructions),
          actions: [
            if (items.value?.isNotEmpty ?? false)
              IconButton(
                tooltip: l10n.instructionsAdd,
                icon: const Icon(Icons.add_rounded),
                onPressed: () => addInstructionOrExplainLimit(context, ref),
              ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: refresh,
            child: CenteredScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: items.when(
                skipLoadingOnReload: true,
                data: (list) => list.isEmpty
                    ? _Empty(
                        onAdd: (starter) => addInstructionOrExplainLimit(
                          context,
                          ref,
                          starter: starter,
                        ),
                      )
                    : _InstructionList(items: list),
                loading: () => const LoadingView(),
                error: (error, _) => ErrorView(
                  failure: error is AppFailure
                      ? error
                      : UnknownFailure(cause: error),
                  onRetry: () => unawaited(
                    ref.read(instructionsControllerProvider.notifier).reload(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// No instruction yet: why it is worth writing one, a way to begin, and the examples
/// that onboarding offers too (USER_FLOWS §9).
class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final void Function(InstructionStarter? starter) onAdd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EmptyState(
          icon: Icons.description_outlined,
          title: l10n.instructionsEmptyTitle,
          message: l10n.instructionsEmptyBody,
          action: AppButton.primary(
            label: l10n.instructionsWriteOwn,
            icon: Icons.edit_outlined,
            onPressed: () => onAdd(null),
          ),
        ),
        Gap.xl,
        Semantics(
          header: true,
          child: Text(
            l10n.instructionsStartersTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Gap.sm,
        for (final starter in InstructionStarter.featured)
          StarterCard(starter: starter, onTap: () => onAdd(starter)),
      ],
    );
  }
}

/// The instructions grouped by category, with a filter when there is more than one.
class _InstructionList extends ConsumerStatefulWidget {
  const _InstructionList({required this.items});

  final List<InstructionSummary> items;

  @override
  ConsumerState<_InstructionList> createState() => _InstructionListState();
}

class _InstructionListState extends ConsumerState<_InstructionList> {
  InstructionCategory? _filter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final order =
        ref.watch(instructionCategoriesProvider).value ??
        InstructionCategory.values;
    // Categories that have instructions, in the server's order (any the server did not
    // list come last).
    final present = {for (final item in widget.items) item.category};
    final categories = [
      for (final c in order)
        if (present.contains(c)) c,
      for (final c in present)
        if (!order.contains(c)) c,
    ];
    final filter = categories.contains(_filter) ? _filter : null;
    final shown = filter == null ? categories : [filter];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (categories.length > 1) ...[
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xxs,
            children: [
              ChoiceChip(
                label: Text(l10n.instructionsFilterAll),
                selected: filter == null,
                onSelected: (_) => setState(() => _filter = null),
              ),
              for (final category in categories)
                ChoiceChip(
                  label: Text(categoryName(l10n, category)),
                  selected: filter == category,
                  onSelected: (_) => setState(() => _filter = category),
                ),
            ],
          ),
          Gap.md,
        ],
        for (final category in shown) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Semantics(
              header: true,
              child: Text(
                categoryName(l10n, category),
                style: textTheme.titleMedium,
              ),
            ),
          ),
          for (final item in widget.items.where((i) => i.category == category))
            _InstructionCard(item: item),
          Gap.sm,
        ],
        AppButton.secondary(
          label: l10n.instructionsAdd,
          icon: Icons.add_rounded,
          onPressed: () => addInstructionOrExplainLimit(context, ref),
          expand: true,
        ),
      ],
    );
  }
}

/// One instruction: its title, whether it is active, who receives it and when.
class _InstructionCard extends ConsumerWidget {
  const _InstructionCard({required this.item});

  final InstructionSummary item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final plan = ref.watch(planControllerProvider).value;
    final contacts = ref.watch(contactsControllerProvider).value ?? const [];
    final lines = sharingLines(l10n, plan, item.recipients);
    final notes = recipientNotes(item.recipients, contacts).lines(l10n);
    // One avatar per person, three at most.
    final avatars = [for (final r in item.recipients.take(3)) r.displayName];
    void open() => context.push(AppRoutes.instructionDetail(item.id));
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Semantics(
        button: true,
        excludeSemantics: true,
        label: l10n.instructionCardSemantics(
          item.title,
          categoryName(l10n, item.category),
          statusName(l10n, item.status),
          [...lines, ...notes].join(' '),
        ),
        onTap: open,
        child: Card(
          margin: EdgeInsets.zero,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.md),
            onTap: open,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.title, style: textTheme.titleMedium),
                        const SizedBox(height: AppSpacing.xs),
                        InstructionStatusChip(status: item.status),
                        const SizedBox(height: AppSpacing.xs),
                        if (avatars.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppSpacing.xs,
                            ),
                            child: Wrap(
                              spacing: AppSpacing.xxs,
                              children: [
                                for (final name in avatars)
                                  RecipientAvatar(name: name),
                              ],
                            ),
                          ),
                        for (final line in lines)
                          Text(line, style: textTheme.bodyMedium),
                        for (final note in notes)
                          Text(
                            note,
                            style: textTheme.bodySmall?.copyWith(
                              color: t.textMuted,
                            ),
                          ),
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
