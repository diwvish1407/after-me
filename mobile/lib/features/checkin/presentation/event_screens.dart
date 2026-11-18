import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/failures/failure_mapper.dart';
import '../../../core/design_system/app_button.dart';
import '../../../core/design_system/app_text_field.dart';
import '../../../core/design_system/brand.dart';
import '../../../core/design_system/form_page.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../plan/application/plan_controller.dart';
import '../../plan/application/plan_editor_controller.dart';
import '../../plan/presentation/plan_editor_screen.dart';
import '../application/events_controller.dart';
import '../data/events_repository.dart';
import '../data/models/checkin_models.dart';

/// Add or change an extra check-in time ([eventId] null: a new one).
class CheckInEventFormScreen extends ConsumerStatefulWidget {
  const CheckInEventFormScreen({this.eventId, super.key});

  final String? eventId;

  @override
  ConsumerState<CheckInEventFormScreen> createState() =>
      _CheckInEventFormScreenState();
}

class _CheckInEventFormScreenState
    extends ConsumerState<CheckInEventFormScreen> {
  final _label = TextEditingController();
  int _minutes = 9 * 60;
  int _days = 1;
  bool _loaded = false;
  bool _busy = false;
  bool _showErrors = false;
  AppFailure? _failure;
  CheckInEvent? _event;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _fill(CheckInEventList? list) {
    if (_loaded || widget.eventId == null || list == null) {
      return;
    }
    for (final e in list.items) {
      if (e.id == widget.eventId) {
        _event = e;
        _label.text = e.label;
        _minutes = parseLocalTime(e.dueLocalTime);
        _days = e.intervalDays;
      }
    }
    _loaded = true;
  }

  CheckInEventDraft get _draft => CheckInEventDraft(
    label: _label.text,
    dueLocalTime: formatLocalTime(_minutes),
    intervalDays: _days,
    intervalMinutes: _event?.intervalMinutes,
  );

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _minutes ~/ 60, minute: _minutes % 60),
    );
    if (picked != null) {
      setState(() => _minutes = picked.hour * 60 + picked.minute);
    }
  }

  Future<void> _save() async {
    setState(() => _showErrors = true);
    if (_label.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    final controller = ref.read(eventsControllerProvider.notifier);
    final draft = _draft;
    try {
      final id = widget.eventId;
      final saved = await withReauth(
        context,
        () =>
            id == null ? controller.create(draft) : controller.save(id, draft),
      );
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).eventSaved)),
        );
        context.pop();
      }
    } on Object catch (error) {
      setState(() => _failure = toAppFailure(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final id = widget.eventId;
    if (id == null) {
      return;
    }
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.eventDeleteTitle),
        content: Text(l10n.eventDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.adminCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.eventDeleteConfirm),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final done = await withReauth(context, () async {
        await ref.read(eventsControllerProvider.notifier).remove(id);
        return true;
      });
      if (done == true && mounted) {
        context.pop();
      }
    } on Object catch (error) {
      setState(() => _failure = toAppFailure(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final text = Theme.of(context).textTheme;
    _fill(ref.watch(eventsControllerProvider).value);
    final editing = widget.eventId != null;
    final labelMissing = _showErrors && _label.text.trim().isEmpty;
    return BrandPage(
      title: editing ? l10n.eventEditTitle : l10n.eventNewTitle,
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppTextField(
                label: l10n.eventLabelField,
                hint: l10n.eventLabelHint,
                controller: _label,
                errorText: labelMissing ? l10n.eventLabelRequired : null,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
              ),
              Gap.md,
              Text(l10n.eventTimeField, style: text.labelLarge),
              Gap.xs,
              OutlinedButton.icon(
                onPressed: _busy ? null : _pickTime,
                icon: const Icon(Icons.access_time_rounded),
                label: Text(formatMinutesOfDay(context, _minutes)),
              ),
              Gap.md,
              Text(l10n.eventFrequencyField, style: text.labelLarge),
              Gap.xs,
              Wrap(
                spacing: AppSpacing.xs,
                runSpacing: AppSpacing.xs,
                children: [
                  for (final (days, label) in [
                    (1, l10n.eventEveryDay),
                    (2, l10n.eventEveryOtherDay),
                    (7, l10n.eventEveryWeek),
                  ])
                    ChoiceChip(
                      label: Text(label),
                      selected: _days == days,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _days = days),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (_failure != null) ...[Gap.md, FailureNotice.of(context, _failure!)],
        Gap.lg,
        AppButton.primary(
          label: l10n.eventSave,
          onPressed: _busy ? null : _save,
          isLoading: _busy,
          expand: true,
        ),
        if (editing) ...[
          Gap.lg,
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.eventPlanTitle, style: text.titleMedium),
                Gap.xs,
                Text(
                  _event?.hasOwnPlan ?? false
                      ? l10n.eventOwnPlan
                      : l10n.eventPlanInherits,
                  style: text.bodyMedium?.copyWith(color: t.textMuted),
                ),
                Gap.md,
                AppButton.secondary(
                  label: l10n.eventPlanButton,
                  icon: Icons.account_tree_outlined,
                  onPressed: () =>
                      context.push(AppRoutes.checkInEventPlan(widget.eventId!)),
                  expand: true,
                ),
              ],
            ),
          ),
          Gap.lg,
          AppButton.text(
            label: l10n.eventDelete,
            icon: Icons.delete_outline_rounded,
            onPressed: _busy ? null : _delete,
            expand: true,
          ),
        ],
      ],
    );
  }
}

/// An event's own plan, edited with the same editor (and the same rules, password
/// step and incident checks) as the main plan: the plan providers are scoped to this
/// event. The first save creates the event's plan from what is on screen.
class EventPlanScreen extends ConsumerWidget {
  const EventPlanScreen({required this.eventId, super.key});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ProviderScope(
      overrides: [
        planRepositoryProvider.overrideWith(
          (ref) => eventPlanRepository(ref, eventId),
        ),
        planControllerProvider.overrideWith(PlanController.new),
        planEditorControllerProvider.overrideWith(PlanEditorController.new),
      ],
      child: _EventPlanBody(eventId: eventId),
    );
  }
}

class _EventPlanBody extends ConsumerWidget {
  const _EventPlanBody({required this.eventId});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The list shows "Own plan" once this is saved.
    ref.listen(planControllerProvider, (previous, next) {
      final before = previous?.value?.version;
      final after = next.value?.version;
      if (before != null && after != null && before != after) {
        ref.read(eventsControllerProvider.notifier).reload();
      }
    });
    return const PlanEditorScreen();
  }
}
