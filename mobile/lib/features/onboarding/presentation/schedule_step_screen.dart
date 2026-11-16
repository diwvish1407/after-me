import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../checkin/data/schedule_repository.dart';
import '../../checkin/presentation/custom_minutes_sheet.dart';
import '../../checkin/presentation/schedule_labels.dart';
import '../application/onboarding_controller.dart';
import '../application/setup_controller.dart';
import 'onboarding_scaffold.dart';

/// Step 5: when to check in. The only step after sign-up that is not skippable.
class ScheduleStepScreen extends ConsumerStatefulWidget {
  const ScheduleStepScreen({super.key});

  @override
  ConsumerState<ScheduleStepScreen> createState() => _ScheduleStepScreenState();
}

class _ScheduleStepScreenState extends ConsumerState<ScheduleStepScreen> {
  int? _interval;
  // Null: as saved. True: the custom interval in [_customMinutes]. False: days.
  bool? _useCustom;
  int? _customMinutes;
  int? _dueMinutes;
  bool _busy = false;
  AppFailure? _failure;

  Future<void> _pickTime(int current) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked != null && mounted) {
      setState(() => _dueMinutes = picked.hour * 60 + picked.minute);
    }
  }

  int? _customFor(CheckInSchedule base) => switch (_useCustom) {
    null => base.intervalMinutes,
    true => _customMinutes,
    false => null,
  };

  Future<void> _pickCustom(int? current) async {
    final l10n = AppLocalizations.of(context);
    final picked = await showCustomMinutesSheet(
      context,
      title: l10n.scheduleCustomIntervalTitle,
      help: l10n.scheduleCustomIntervalHelp,
      choices: customIntervalChoices,
      min: minIntervalMinutes,
      max: maxIntervalMinutes,
      initial: current,
    );
    if (picked != null && mounted) {
      setState(() {
        _useCustom = true;
        _customMinutes = picked;
      });
    }
  }

  Future<void> _save(CheckInSchedule base) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final setup = ref.read(setupControllerProvider.notifier);
      final custom = _customFor(base);
      final schedule = base.copyWith(
        intervalDays: _interval ?? base.intervalDays,
        intervalMinutes: custom,
        clearIntervalMinutes: custom == null,
        dueMinutes: _dueMinutes ?? base.dueMinutes,
      );
      // The schedule is still off here, so no password is asked for. If the server ever
      // asks (403 reauth_required) the sheet appears instead of an error.
      final saved = await withReauth(context, () async {
        await setup.saveSchedule(schedule);
        return true;
      });
      if (!mounted) {
        return;
      }
      if (saved == null) {
        // The sheet was closed: nothing was saved and the person stays on this step.
        setState(() => _busy = false);
        return;
      }
      await advanceFrom(context, ref, OnboardingStep.schedule);
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final saved = ref.watch(setupControllerProvider).value?.schedule;
    final timezone =
        saved?.timezone ??
        ref.watch(meControllerProvider).value?.profile.timezone ??
        'UTC';
    final base = (saved ?? CheckInSchedule(timezone: timezone));
    final interval = _interval ?? base.intervalDays;
    final custom = _customFor(base);
    final due = _dueMinutes ?? base.dueMinutes;
    final dueText = formatMinutesOfDay(context, due);
    return OnboardingScaffold(
      step: OnboardingStep.schedule,
      title: l10n.scheduleStepTitle,
      subtitle: l10n.scheduleStepBody,
      primaryLabel: l10n.scheduleStepSave,
      primaryBusy: _busy,
      onPrimary: () => _save(base),
      children: [
        if (_failure != null) ...[
          // After a 412 the latest schedule is already loaded; say that instead of
          // asking the person to refresh.
          _failure is ConflictFailure &&
                  (_failure! as ConflictFailure).code == 'precondition_failed'
              ? FailureNotice(message: l10n.scheduleStale)
              : FailureNotice.of(context, _failure!),
          Gap.md,
        ],
        Semantics(
          header: true,
          child: Text(
            l10n.scheduleCheckInEvery,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        Wrap(
          spacing: AppSpacing.xs,
          children: [
            for (final days in {
              ...scheduleIntervalChoices,
              interval,
            }.toList()..sort())
              ChoiceChip(
                label: Text(intervalLabel(l10n, days)),
                selected: custom == null && interval == days,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _interval = days;
                        _useCustom = false;
                      }),
              ),
            ChoiceChip(
              label: Text(
                custom == null
                    ? l10n.scheduleChoiceCustom
                    : scheduleIntervalLabel(
                        l10n,
                        intervalDays: interval,
                        intervalMinutes: custom,
                      ),
              ),
              selected: custom != null,
              onSelected: _busy ? null : (_) => _pickCustom(custom),
            ),
          ],
        ),
        Gap.lg,
        if (custom == null) ...[
          Semantics(
            header: true,
            child: Text(
              l10n.scheduleBy,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Gap.xs,
          AppButton.secondary(
            label: dueText,
            icon: Icons.schedule_rounded,
            onPressed: _busy ? null : () => _pickTime(due),
            expand: true,
          ),
        ] else
          BodyText(
            l10n.scheduleCustomIntervalNote(
              formatDurationMinutes(l10n, custom),
            ),
          ),
        Gap.md,
        StatusBanner(
          kind: StatusBannerKind.info,
          message: scheduleSummaryText(
            l10n,
            intervalDays: interval,
            intervalMinutes: custom,
            dueTime: dueText,
          ),
        ),
        Gap.sm,
        BodyText(reminderSentence(l10n, base.reminderLeadMinutes)),
        BodyText(l10n.scheduleTimezoneNote(timezone)),
      ],
    );
  }
}
