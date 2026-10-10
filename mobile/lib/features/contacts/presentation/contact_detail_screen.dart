import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/router.dart';
import '../../../app/theme/dimens.dart';
import '../../../app/theme/tokens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/time/clock.dart';
import '../../../core/time/time_format.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/presentation/reauth_sheet.dart';
import '../../plan/application/plan_controller.dart';
import '../application/contacts_controller.dart';
import '../data/contacts_repository.dart';
import 'contact_by_id_view.dart';
import 'contact_labels.dart';
import 'contact_status_chip.dart';

/// A trusted contact: status and what to do next, invitation history, Resend, Edit and
/// Remove (USER_FLOWS §8).
class ContactDetailScreen extends StatelessWidget {
  const ContactDetailScreen({required this.contactId, super.key});

  final String contactId;

  @override
  Widget build(BuildContext context) {
    return ContactByIdView(
      id: contactId,
      title: AppLocalizations.of(context).contactDetailTitle,
      builder: (context, contact) => _ContactDetail(contact: contact),
    );
  }
}

class _ContactDetail extends ConsumerStatefulWidget {
  const _ContactDetail({required this.contact});

  final TrustedContact contact;

  @override
  ConsumerState<_ContactDetail> createState() => _ContactDetailState();
}

class _ContactDetailState extends ConsumerState<_ContactDetail> {
  bool _resending = false;
  bool _removing = false;
  AppFailure? _failure;

  /// After a rate limit: when the resend button works again, and whether the server
  /// said how long to wait.
  DateTime? _resendBlockedUntil;
  bool _waitKnown = false;

  TrustedContact get _contact => widget.contact;

  bool get _blocked {
    final until = _resendBlockedUntil;
    return until != null && ref.read(clockProvider)().isBefore(until);
  }

  Future<void> _resend() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final controller = ref.read(contactsControllerProvider.notifier);
    setState(() {
      _resending = true;
      _failure = null;
    });
    try {
      await controller.resendInvitation(_contact.id);
      messenger.showSnackBar(SnackBar(content: Text(l10n.contactResendQueued)));
    } on RateLimitedFailure catch (failure) {
      _resendBlockedUntil = ref
          .read(clockProvider)()
          .add(failure.retryAfter ?? const Duration(hours: 1));
      _waitKnown = failure.retryAfter != null;
    } on InvalidStateFailure catch (failure) {
      // Their answer changed since this was loaded: show the latest status.
      _failure = failure;
      unawaited(controller.reload());
    } on AppFailure catch (failure) {
      _failure = failure;
    } finally {
      if (mounted) {
        setState(() => _resending = false);
      }
    }
  }

  /// Why the password may be asked for: the contact is told by the plan, or (when they are
  /// not in a stage) receives an instruction. Their own wording each.
  ReauthReason _removeReason() {
    final plan = ref.read(planControllerProvider).value;
    final inPlan =
        plan?.contactIds.contains(_contact.id) ??
        _contact.notifiedAtStages.isNotEmpty;
    return !inPlan && _contact.receivesInstructions > 0
        ? ReauthReason.removeRecipient
        : ReauthReason.removeContact;
  }

  Future<void> _remove() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => _RemoveSheet(contact: _contact),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    setState(() {
      _removing = true;
      _failure = null;
    });
    final controller = ref.read(contactsControllerProvider.notifier);
    try {
      // Taking someone who is in the plan out of it while check-ins are on asks for the
      // password again (403 reauth_required): the sheet is shown once and the same
      // removal repeated. Someone who is in no stage, or any removal while check-ins are
      // off, never asks.
      final removed = await withReauth(context, () async {
        await controller.removeContact(_contact.id);
        return true;
      }, reason: _removeReason());
      if (removed == null) {
        // The sheet was closed: nothing was removed and nothing is said.
        if (mounted) {
          setState(() => _removing = false);
        }
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.contactRemoved(_contact.displayName))),
      );
      router.pop();
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _removing = false;
          _failure = failure;
        });
      }
    }
  }

  /// Why "Resend invitation" is off, or null when it works.
  String? _resendOffReason(AppLocalizations l10n) {
    switch (_contact.verificationStatus) {
      case VerificationStatus.verified:
        return l10n.contactResendNotNeededAccepted;
      case VerificationStatus.declined:
        return l10n.contactResendNotNeededDeclined;
      case VerificationStatus.optedOut:
        return l10n.contactResendNotNeededOptedOut;
      case VerificationStatus.pending:
      case VerificationStatus.bounced:
        if (_blocked) {
          return resendWaitReason(
            l10n,
            _waitKnown
                ? _resendBlockedUntil!.difference(ref.read(clockProvider)())
                : null,
          );
        }
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final t = context.tokens;
    final textTheme = Theme.of(context).textTheme;
    final status = _contact.verificationStatus;
    final reason = _resendOffReason(l10n);
    final busy = _resending || _removing;
    return FormPage(
      title: l10n.contactDetailTitle,
      children: [
        if (_failure != null) ...[FailureNotice.of(context, _failure!), Gap.md],
        PageHeading(_contact.displayName),
        Text(
          contactRelationshipText(l10n, _contact),
          style: textTheme.bodyMedium?.copyWith(color: t.textMuted),
        ),
        Gap.md,
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ContactStatusChip(status: status),
        ),
        Gap.xs,
        Text(statusExplanation(l10n, status), style: textTheme.bodyLarge),
        const SizedBox(height: AppSpacing.xxs),
        BodyText(statusNextAction(l10n, status)),
        Gap.lg,
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ValueRow(label: l10n.contactEmailLabel, value: _contact.email),
                if (_contact.phoneE164 != null) ...[
                  Gap.sm,
                  _ValueRow(
                    label: l10n.contactPhoneLabel,
                    value: _contact.phoneE164!,
                  ),
                ],
              ],
            ),
          ),
        ),
        Gap.md,
        _InvitationHistory(contact: _contact),
        Gap.lg,
        AppButton.secondary(
          label: l10n.contactResend,
          icon: Icons.forward_to_inbox_outlined,
          onPressed: busy || reason != null ? null : _resend,
          isLoading: _resending,
          expand: true,
        ),
        if (reason != null) ...[
          Gap.xs,
          Semantics(liveRegion: true, child: BodyText(reason)),
        ],
        Gap.sm,
        AppButton.secondary(
          label: l10n.contactEditAction,
          icon: Icons.edit_outlined,
          onPressed: busy
              ? null
              : () => context.push(AppRoutes.contactEdit(_contact.id)),
          expand: true,
        ),
        Gap.sm,
        AppButton.text(
          label: l10n.contactRemoveAction,
          icon: Icons.person_remove_outlined,
          onPressed: busy ? null : _remove,
          isLoading: _removing,
          expand: true,
        ),
        Gap.lg,
        BodyText(l10n.contactMustAccept),
      ],
    );
  }
}

/// A small label above a value that must stay whole (an email address, a phone number).
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: textTheme.bodySmall?.copyWith(
                color: context.tokens.textMuted,
              ),
            ),
            FitText(value, style: textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

class _InvitationHistory extends StatelessWidget {
  const _InvitationHistory({required this.contact});

  final TrustedContact contact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final sent = contact.invitationSentAt;
    final accepted = contact.verifiedAt;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.contactInvitationHeading,
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(height: AppSpacing.xxs),
            if (sent == null && contact.invitationSendCount == 0)
              Text(l10n.contactInvitationNotSent)
            else ...[
              if (sent != null)
                Text(
                  l10n.contactInvitationLastSent(formatDateTime(context, sent)),
                ),
              if (contact.invitationSendCount > 0)
                Text(l10n.contactInvitationCount(contact.invitationSendCount)),
            ],
            if (contact.isAccepted && accepted != null)
              Text(l10n.contactAcceptedOn(formatDateTime(context, accepted))),
          ],
        ),
      ),
    );
  }
}

/// "Remove Mom? They will no longer be notified." (USER_FLOWS §8).
class _RemoveSheet extends StatelessWidget {
  const _RemoveSheet({required this.contact});

  final TrustedContact contact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = contact.displayName;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        0,
        AppSpacing.page,
        AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeading(l10n.contactRemoveTitle(name)),
          Gap.sm,
          BodyText(
            contact.receivesInstructions > 0
                ? l10n.contactRemoveBodyInstructions(
                    name,
                    contact.receivesInstructions,
                  )
                : l10n.contactRemoveBody(name),
          ),
          Gap.lg,
          AppButton.primary(
            label: l10n.contactRemoveConfirm,
            onPressed: () => Navigator.of(context).pop(true),
            expand: true,
          ),
          Gap.xs,
          AppButton.secondary(
            label: l10n.cancel,
            onPressed: () => Navigator.of(context).pop(false),
            expand: true,
          ),
        ],
      ),
    );
  }
}
