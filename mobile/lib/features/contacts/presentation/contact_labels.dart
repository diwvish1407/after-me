import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../data/contacts_repository.dart';

/// The localised name of a relationship chip.
String relationshipName(AppLocalizations l10n, ContactRelationship value) =>
    switch (value) {
      ContactRelationship.mother => l10n.relationshipMother,
      ContactRelationship.father => l10n.relationshipFather,
      ContactRelationship.parent => l10n.relationshipParent,
      ContactRelationship.spouse => l10n.relationshipSpouse,
      ContactRelationship.partner => l10n.relationshipPartner,
      ContactRelationship.sibling => l10n.relationshipSibling,
      ContactRelationship.child => l10n.relationshipChild,
      ContactRelationship.relative => l10n.relationshipRelative,
      ContactRelationship.friend => l10n.relationshipFriend,
      ContactRelationship.neighbor => l10n.relationshipNeighbor,
      ContactRelationship.employer => l10n.relationshipEmployer,
      ContactRelationship.colleague => l10n.relationshipColleague,
      ContactRelationship.other => l10n.relationshipOther,
    };

/// How the person knows this contact: the chosen relationship, or the free-text
/// description for "Other".
String contactRelationshipText(AppLocalizations l10n, TrustedContact contact) {
  final label = contact.relationshipLabel?.trim();
  if (contact.relationship == ContactRelationship.other &&
      label != null &&
      label.isNotEmpty) {
    return label;
  }
  return relationshipName(l10n, contact.relationship);
}

/// The chip text for a status (the same words everywhere the status is shown).
String statusLabel(AppLocalizations l10n, VerificationStatus status) =>
    switch (status) {
      VerificationStatus.pending => l10n.contactStatusPending,
      VerificationStatus.verified => l10n.contactStatusAccepted,
      VerificationStatus.declined => l10n.contactStatusDeclined,
      VerificationStatus.optedOut => l10n.contactStatusOptedOut,
      VerificationStatus.bounced => l10n.contactStatusBounced,
    };

/// The one-line explanation of a status.
String statusExplanation(AppLocalizations l10n, VerificationStatus status) =>
    switch (status) {
      VerificationStatus.pending => l10n.contactExplainPending,
      VerificationStatus.verified => l10n.contactExplainAccepted,
      VerificationStatus.declined => l10n.contactExplainDeclined,
      VerificationStatus.optedOut => l10n.contactExplainOptedOut,
      VerificationStatus.bounced => l10n.contactExplainBounced,
    };

/// What the person can do next about a status.
String statusNextAction(AppLocalizations l10n, VerificationStatus status) =>
    switch (status) {
      VerificationStatus.pending => l10n.contactNextPending,
      VerificationStatus.verified => l10n.contactNextAccepted,
      VerificationStatus.declined => l10n.contactNextDeclined,
      VerificationStatus.optedOut => l10n.contactNextOptedOut,
      VerificationStatus.bounced => l10n.contactNextBounced,
    };

/// A distinct shape per status, so the status never depends on colour alone.
IconData statusIcon(VerificationStatus status) => switch (status) {
  VerificationStatus.pending => Icons.schedule_rounded,
  VerificationStatus.verified => Icons.check_circle_outline_rounded,
  VerificationStatus.declined => Icons.block_rounded,
  VerificationStatus.optedOut => Icons.do_not_disturb_on_outlined,
  VerificationStatus.bounced => Icons.mail_outline_rounded,
};

/// Why the resend button is off after a rate limit: when the person can try again.
String resendWaitReason(AppLocalizations l10n, Duration? wait) {
  if (wait == null || wait <= Duration.zero) {
    return l10n.contactResendWaitLater;
  }
  if (wait <= const Duration(hours: 1)) {
    return l10n.contactResendWaitMinutes(
      wait.inSeconds <= 60 ? 1 : (wait.inSeconds / 60).ceil(),
    );
  }
  if (wait <= const Duration(days: 1)) {
    return l10n.contactResendWaitHours((wait.inMinutes / 60).ceil());
  }
  return l10n.contactResendWaitDays((wait.inHours / 24).ceil());
}
