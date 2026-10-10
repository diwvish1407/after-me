import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../home/application/home_controller.dart';
import '../../settings/presentation/settings_widgets.dart';
import '../application/schedule_controller.dart';
import '../data/models/checkin_models.dart';
import 'schedule_labels.dart';

/// Settings > Check-in schedule (USER_FLOWS.md §11): how often, by when and how long
/// before to be reminded; whether check-ins are on; turning them on or off.
///
/// A save carries the `ETag` of what is on screen as `If-Match`. If the schedule was
/// changed somewhere else (412) the latest version is loaded and the person is told, so
/// nothing is overwritten unseen. Turning check-ins off, and making the interval longer
/// while they are on, need the password again.
class ScheduleSettingsScreen extends ConsumerWidget {
  const ScheduleSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final schedule = ref.watch(scheduleControllerProvider);
    final snapshot = schedule.value;
    if (snapshot != null) {
      return _ScheduleForm(snapshot: snapshot);
    }
    return FormPage(
      title: l10n.settingsCheckInSchedule,
      children: [
        if (schedule.hasError)
          ErrorView(
            failure: schedule.error is AppFailure
                ? schedule.error! as AppFailure
                : UnknownFailure(cause: schedule.error),
            onRetry: () => unawaited(
              ref.read(scheduleControllerProvider.notifier).reload(),
            ),
          )
        else
          const LoadingView(),
      ],
    );
  }
}

class _ScheduleForm extends ConsumerStatefulWidget {
  const _ScheduleForm({required this.snapshot});

  final ScheduleSnapshot snapshot;

  @override
  ConsumerState<_ScheduleForm> createState() => _ScheduleFormState();
}

class _ScheduleFormState extends ConsumerState<_ScheduleForm> {
  int? _interval;
  int? _dueMinutes;
  int? _lead;
  bool _busy = false;
  AppFailure? _failure;
  bool _stale = false;
  List<String>? _missing;

  ScheduleSnapshot get _snapshot => widget.snapshot;

  int get _intervalValue => _interval ?? _snapshot.intervalDays;
  int get _dueValue => _dueMinutes ?? _snapshot.dueMinutes;
  int get _leadValue => _lead ?? _snapshot.reminderLeadMinutes;

  bool get _dirty =>
      _intervalValue != _snapshot.intervalDays ||
      _dueValue != _snapshot.dueMinutes ||
      _leadValue != _snapshot.reminderLeadMinutes;

  bool get _locked => _snapshot.status == CheckInStatus.incidentOpen;

  @override
  void didUpdateWidget(_ScheduleForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.snapshot.version != widget.snapshot.version) {
      // A newer version arrived (saved, or loaded after a 412): the draft starts again
      // from what the server has.
      _interval = null;
      _dueMinutes = null;
      _lead = null;
    }
  }

  Future<void> _pickTime() async {
    final current = _dueValue;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (picked != null && mounted) {
      setState(() => _dueMinutes = picked.hour * 60 + picked.minute);
    }
  }

  /// Runs [action] (true when it did what was asked) with the busy state and the
  /// calm messages for every way it can fail.
  Future<void> _run(
    Future<bool> Function() action, {
    String? doneMessage,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _failure = null;
      _stale = false;
      _missing = null;
    });
    try {
      final done = await action();
      if (done && doneMessage != null) {
        messenger.showSnackBar(SnackBar(content: Text(doneMessage)));
      }
    } on ActivationRequirementsFailure catch (failure) {
      _missing = failure.requirements.isEmpty
          ? const ['unknown']
          : failure.requirements;
    } on ConflictFailure catch (failure) {
      if (failure.code == 'precondition_failed' ||
          failure.code == 'precondition_required') {
        // The controller already loaded the latest version.
        _stale = true;
      } else {
        _failure = failure;
      }
    } on AppFailure catch (failure) {
      _failure = failure;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _save() {
    final l10n = AppLocalizations.of(context);
    final schedule = _snapshot.settings.copyWith(
      intervalDays: _intervalValue,
      dueMinutes: _dueValue,
      reminderLeadMinutes: _leadValue,
    );
    final controller = ref.read(scheduleControllerProvider.notifier);
    return _run(() async {
      // Making the interval longer while check-ins are on asks for the password again
      // (403 reauth_required): the sheet is shown once and the same save repeated, with
      // the same If-Match (nothing changed meanwhile).
      final saved = await withReauth(context, () => controller.save(schedule));
      // Null: the sheet was closed; nothing was saved, the edits stay and nothing is
      // said.
      return saved != null;
    }, doneMessage: l10n.scheduleSaved);
  }

  Future<void> _turnOn() {
    final l10n = AppLocalizations.of(context);
    return _run(() async {
      await ref.read(scheduleControllerProvider.notifier).activate();
      return true;
    }, doneMessage: l10n.scheduleTurnedOn);
  }

  Future<void> _turnOff() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.scheduleTurnOffTitle,
      message: l10n.scheduleTurnOffBody,
      confirmLabel: l10n.scheduleTurnOffConfirm,
      cancelLabel: l10n.cancel,
    );
    if (!confirmed || !mounted) {
      return;
    }
    final controller = ref.read(scheduleControllerProvider.notifier);
    await _run(() async {
      // The server asks for the password again if it has been a while (403
      // reauth_required); the sheet is shown once and the call repeated.
      final result = await withReauth(context, controller.deactivate);
      // Null: the sheet was closed; nothing happened and nothing is said.
      return result != null;
    }, doneMessage: l10n.scheduleTurnedOff);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final snapshot = _snapshot;
    final timezone = snapshot.timezone;
    final serverNow = ref.watch(serverNowProvider)();
    final next = snapshot.nextDueAt;
    final intervals = {...scheduleIntervalChoices, _intervalValue}.toList()
      ..sort();
    final leads = {...reminderLeadChoices, _leadValue}.toList()..sort();
    final (StatusBannerKind kind, String status) = switch (snapshot.status) {
      CheckInStatus.active => (StatusBannerKind.ok, l10n.scheduleStatusOn),
      CheckInStatus.inactive => (StatusBannerKind.info, l10n.scheduleStatusOff),
      CheckInStatus.incidentOpen => (
        StatusBannerKind.attention,
        l10n.scheduleStatusOverdue,
      ),
      CheckInStatus.unknown => (
        StatusBannerKind.info,
        l10n.scheduleStatusUnknown,
      ),
    };
    final statusMessage = switch (snapshot.status) {
      CheckInStatus.active when next != null => l10n.scheduleNextDue(
        formatDayTime(context, l10n, next, now: serverNow, timezone: timezone),
      ),
      CheckInStatus.incidentOpen => l10n.errorIncidentOpen,
      _ => '',
    };
    final summary = l10n.scheduleSummary(
      intervalLabel(l10n, _intervalValue).toLowerCase(),
      formatMinutesOfDay(context, _dueValue),
    );
    return FormPage(
      title: l10n.settingsCheckInSchedule,
      children: [
        if (_stale) ...[FailureNotice(message: l10n.scheduleStale), Gap.md],
        if (_failure != null) ...[FailureNotice.of(context, _failure!), Gap.md],
        if (_missing != null) ...[
          FailureNotice(
            message: l10n.homeActivationMissing(
              activationMissingText(l10n, _missing!),
            ),
          ),
          Gap.md,
        ],
        Semantics(
          liveRegion: true,
          container: true,
          child: StatusBanner(
            kind: kind,
            title: status,
            message: statusMessage,
          ),
        ),
        Gap.lg,
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
            for (final days in intervals)
              ChoiceChip(
                label: Text(intervalLabel(l10n, days)),
                selected: _intervalValue == days,
                onSelected: _busy || _locked
                    ? null
                    : (_) => setState(() => _interval = days),
              ),
          ],
        ),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(
            l10n.scheduleBy,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        AppButton.secondary(
          label: formatMinutesOfDay(context, _dueValue),
          icon: Icons.schedule_rounded,
          onPressed: _busy || _locked ? null : _pickTime,
          expand: true,
        ),
        Gap.lg,
        Semantics(
          header: true,
          child: Text(
            l10n.scheduleReminderHeading,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        Wrap(
          spacing: AppSpacing.xs,
          children: [
            for (final minutes in leads)
              ChoiceChip(
                label: Text(reminderChoiceLabel(l10n, minutes)),
                selected: _leadValue == minutes,
                onSelected: _busy || _locked
                    ? null
                    : (_) => setState(() => _lead = minutes),
              ),
          ],
        ),
        Gap.md,
        StatusBanner(kind: StatusBannerKind.info, message: summary),
        Gap.sm,
        BodyText(l10n.scheduleTimezoneNote(timezone)),
        if (snapshot.isOn && !_locked) ...[
          Gap.xs,
          BodyText(l10n.scheduleRestartNote),
          Gap.xs,
          BodyText(l10n.scheduleLengthenNote),
        ],
        Gap.lg,
        AppButton.primary(
          label: l10n.scheduleSave,
          isLoading: _busy,
          onPressed: _dirty && !_locked ? _save : null,
          expand: true,
        ),
        if (!_locked) ...[
          Gap.md,
          if (snapshot.status == CheckInStatus.active)
            AppButton.secondary(
              label: l10n.scheduleTurnOff,
              onPressed: _busy ? null : _turnOff,
              expand: true,
            )
          else if (snapshot.status == CheckInStatus.inactive)
            AppButton.secondary(
              label: l10n.scheduleTurnOn,
              onPressed: _busy ? null : _turnOn,
              expand: true,
            ),
        ],
      ],
    );
  }
}
