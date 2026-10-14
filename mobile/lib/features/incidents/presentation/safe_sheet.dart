import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/repository_providers.dart';
import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/security/secure_screen.dart';
import '../../../core/time/time_format.dart';
import '../../../core/time/zoned_time.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../checkin/application/checkin_controller.dart';
import '../../home/application/home_controller.dart';
import '../../plan/presentation/plan_preview.dart';
import '../application/incident_context.dart';
import '../application/safe_controller.dart';
import '../data/models/incident_models.dart';
import 'incident_labels.dart';

/// The password, then the confirmation of I'M SAFE (USER_FLOWS.md §7), then what the
/// server answered.
///
/// 1. [ReauthSheet]: the password (`reauth_required` later asks again).
/// 2. [SafeSheet]: who is told, what has been shared and viewed, what stops, and a
///    clearly labelled confirm button.
/// 3. The same sheet shows the result, in words that follow the server's answer only.
///
/// Nothing is sent until the confirm button is pressed, and the incident is never shown
/// as stopped before the server's 200.
Future<void> startSafeFlow(
  BuildContext context, {
  required String incidentId,
  Incident? incident,
}) async {
  final container = ProviderScope.containerOf(context);
  // One flow at a time: a second tap before the first sheet is on screen starts nothing.
  if (_flowOpen[container] ?? false) {
    return;
  }
  if (container.read(safeControllerProvider).isSending) {
    return;
  }
  _flowOpen[container] = true;
  try {
    final confirmed = await showReauthSheet(
      context,
      reason: ReauthReason.incidentSafe,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      isDismissible: false,
      enableDrag: false,
      builder: (context) =>
          SafeSheet(incidentId: incidentId, incident: incident),
    );
  } finally {
    _flowOpen[container] = false;
  }
}

/// Which containers have a flow open right now.
final Expando<bool> _flowOpen = Expando<bool>('I\'M SAFE flow open');

/// The I'M SAFE sheet: confirm, sending, and the result.
class SafeSheet extends ConsumerStatefulWidget {
  const SafeSheet({required this.incidentId, this.incident, super.key});

  final String incidentId;

  /// What Home knows about the incident; null when it could not be read.
  final Incident? incident;

  @override
  ConsumerState<SafeSheet> createState() => _SafeSheetState();
}

class _SafeSheetState extends ConsumerState<SafeSheet> {
  Incident? _incident;

  /// A fresh read says the incident is not open any more.
  bool _closedMeanwhile = false;

  /// The server still asked for the password right after the person had entered it: the
  /// password sheet would only open again, so say so instead of looping without a word.
  bool _passwordNotAccepted = false;

  @override
  void initState() {
    super.initState();
    _incident = widget.incident;
    unawaited(Future.microtask(_readLatest));
  }

  /// Reads the incident again so the sheet says what has been viewed *now*. A failure
  /// changes nothing: the confirmation works with what Home had.
  Future<void> _readLatest() async {
    try {
      final latest = await ref
          .read(incidentsRepositoryProvider)
          .get(widget.incidentId);
      if (!mounted) {
        return;
      }
      setState(() {
        _incident = latest;
        _closedMeanwhile = latest.isClosed;
      });
      if (latest.isClosed) {
        // Over, whoever closed it: no "confirm you're safe" about it may stay behind,
        // even when Home cannot be read right now.
        ref
            .read(checkInControllerProvider.notifier)
            .dismissSafeRequiredFor(widget.incidentId);
        unawaited(ref.read(homeControllerProvider.notifier).refresh());
      }
    } on Object {
      // Offline or refused: keep what is on screen.
    }
  }

  Future<void> _confirm() async {
    final controller = ref.read(safeControllerProvider.notifier);
    var sent = 0;
    if (_passwordNotAccepted) {
      setState(() => _passwordNotAccepted = false);
    }
    try {
      // The server asks for the password again when its 5 minutes ran out while this
      // sheet was open (403 `reauth_required`): the sheet is shown once and the same
      // confirmation (the same key) sent again.
      await withReauth(context, () {
        sent++;
        return controller.markSafe(widget.incidentId);
      }, reason: ReauthReason.incidentSafe);
    } on AppFailure catch (failure) {
      // The state of the controller says what happened, except in one case: the
      // password was just accepted and the server asks for it again. Nothing in the
      // controller's state is different from "asks for the password" then.
      if (sent > 1 &&
          failure is ForbiddenFailure &&
          failure.code == 'reauth_required' &&
          mounted) {
        setState(() => _passwordNotAccepted = true);
      }
    }
  }

  void _close() {
    ref.read(safeControllerProvider.notifier).reset();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(safeControllerProvider);
    final l10n = AppLocalizations.of(context);
    final Widget content;
    if (state.phase == SafePhase.success && state.result != null) {
      content = _Done(
        result: state.result!,
        notifiedOrder: [
          ...?_incident?.notifiedContacts.map((contact) => contact.id),
        ],
        onClose: _close,
      );
    } else if (_closedMeanwhile || state.alreadyClosed) {
      content = _Message(
        title: l10n.safeAlreadyClosedTitle,
        body: l10n.safeAlreadyClosedBody,
        actions: [
          AppButton.primary(
            label: l10n.safeDoneButton,
            onPressed: _close,
            expand: true,
          ),
        ],
      );
    } else if (state.notConfirmed) {
      content = _Message(
        title: l10n.safeNotConfirmedTitle,
        body: l10n.safeNotConfirmedBody,
        actions: [
          AppButton.primary(
            label: l10n.safeTryAgain,
            onPressed: _confirm,
            expand: true,
          ),
          Gap.xs,
          AppButton.secondary(
            label: l10n.safeConfirmCancel,
            onPressed: _close,
            expand: true,
          ),
        ],
      );
    } else {
      // A request for the password is answered by the password sheet, not by a notice,
      // unless the sheet was just answered and the server asks again.
      final failure =
          state.phase == SafePhase.failed &&
              (!state.needsPassword || _passwordNotAccepted)
          ? state.failure
          : null;
      content = _Confirm(
        incident: _incident,
        failure: failure,
        sending: state.isSending,
        onConfirm: _confirm,
        onCancel: _close,
      );
    }
    // The confirmation names what was opened: a title is content, so the window is
    // secure while one is on screen (the incident may be newer than Home's).
    final showsTitle =
        _incident?.releases.any(
          (r) => r.wasViewed && (r.instructionTitle ?? '').isNotEmpty,
        ) ??
        false;
    return SecureScreen(
      enabled: showsTitle,
      child: PopScope(
        canPop: !state.isSending,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            ref.read(safeControllerProvider.notifier).reset();
          }
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.page,
            AppSpacing.lg,
            AppSpacing.page,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [content],
          ),
        ),
      ),
    );
  }
}

/// A heading, a sentence and the buttons: used for the answers that are not the
/// confirmation itself.
class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.body,
    required this.actions,
  });

  final String title;
  final String body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(title),
          Gap.sm,
          Text(body, style: Theme.of(context).textTheme.bodyLarge),
          Gap.lg,
          ...actions,
        ],
      ),
    );
  }
}

/// "We'll tell Mom and Brother you're safe. ... Brother viewed “House emergency” at
/// 8:20 PM. That can't be undone. Escalation stops. Your check-in schedule restarts."
class _Confirm extends ConsumerWidget {
  const _Confirm({
    required this.incident,
    required this.failure,
    required this.sending,
    required this.onConfirm,
    required this.onCancel,
  });

  final Incident? incident;
  final AppFailure? failure;
  final bool sending;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  /// The clock time of a view today; the date and time otherwise.
  String _clockOrDate(
    BuildContext context,
    DateTime at, {
    required DateTime now,
    String? timezone,
  }) => calendarDaysBetween(now, at, timezone) == 0
      ? formatClockTime(context, at, timezone: timezone)
      : formatDateTime(context, at, timezone: timezone);

  /// "Brother viewed “House emergency” at 8:20 PM. That can't be undone."
  String _viewedLine(
    BuildContext context,
    AppLocalizations l10n,
    IncidentRelease release, {
    required DateTime now,
    String? timezone,
  }) {
    final at =
        release.firstViewedAt ?? release.lastViewedAt ?? release.releasedAt;
    final when = _clockOrDate(context, at, now: now, timezone: timezone);
    final title = release.instructionTitle;
    return title == null || title.isEmpty
        ? l10n.safeConfirmViewedUntitled(release.contactDisplayName, when)
        : l10n.safeConfirmViewed(release.contactDisplayName, title, when);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final timezone = ref.watch(incidentTimezoneProvider);
    final now = ref.watch(serverNowProvider)();
    final incident = this.incident;

    final told = <String>[
      if (incident != null)
        for (final contact in incident.notifiedContacts)
          if (contact.displayName.isNotEmpty) contact.displayName,
    ];
    final sharedWith = <String>{
      if (incident != null)
        for (final release in incident.releases)
          if (!release.isRevoked && release.contactDisplayName.isNotEmpty)
            release.contactDisplayName,
    }.toList();
    final viewed = [
      if (incident != null)
        for (final release in incident.releases)
          if (release.wasViewed) release,
    ];
    final lines = <String>[
      if (incident == null)
        l10n.safeConfirmTellGeneric
      else if (told.isEmpty)
        l10n.safeConfirmTellNobody
      else
        l10n.safeConfirmTell(joinNames(l10n, told)),
      if (sharedWith.isNotEmpty)
        l10n.safeConfirmShared(joinNames(l10n, sharedWith)),
      for (final release in viewed)
        _viewedLine(context, l10n, release, now: now, timezone: timezone),
      l10n.safeConfirmConsequences,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeading(l10n.safeConfirmTitle),
        Gap.md,
        if (failure != null) ...[
          FailureNotice(
            message: actionFailureMessage(
              l10n,
              failure!,
              UnconfirmedAction.safe,
            ),
          ),
          Gap.md,
        ],
        for (final line in lines) ...[
          Text(line, style: textTheme.bodyLarge),
          Gap.sm,
        ],
        Gap.sm,
        AppButton.primary(
          label: l10n.safeConfirmButton,
          isLoading: sending,
          onPressed: sending ? null : onConfirm,
          expand: true,
        ),
        Gap.xs,
        AppButton.secondary(
          label: l10n.safeConfirmCancel,
          onPressed: sending ? null : onCancel,
          expand: true,
        ),
      ],
    );
  }
}

/// "You're marked safe." who is told, and when the next check-in is: only what the
/// server's 200 says.
class _Done extends ConsumerWidget {
  const _Done({
    required this.result,
    required this.notifiedOrder,
    required this.onClose,
  });

  final SafeResult result;

  /// Contact ids in the order they were first notified (from the incident the sheet
  /// was showing), for a sentence whose order does not change between reads.
  final List<String> notifiedOrder;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final timezone = ref.watch(incidentTimezoneProvider);
    final now = ref.watch(serverNowProvider)();
    final names = allClearNames(
      result.allClearSentTo,
      notifiedOrder: notifiedOrder,
    );
    final next = result.nextDueAt;
    return _Message(
      title: l10n.safeDoneTitle,
      body: [
        names.isEmpty
            ? l10n.safeDoneNobody
            : l10n.safeDoneTold(joinNames(l10n, names)),
        next == null
            ? l10n.safeDoneNoNext
            : l10n.safeDoneNext(
                formatSpokenDayTime(
                  context,
                  l10n,
                  next,
                  now: now,
                  timezone: timezone,
                ),
              ),
      ].join(' '),
      actions: [
        AppButton.primary(
          label: l10n.safeDoneButton,
          onPressed: onClose,
          expand: true,
        ),
      ],
    );
  }
}
