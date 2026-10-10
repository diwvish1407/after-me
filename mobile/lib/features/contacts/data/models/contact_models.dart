import 'package:freezed_annotation/freezed_annotation.dart';

part 'contact_models.freezed.dart';
part 'contact_models.g.dart';

/// How the user knows a contact. The wire value is the enum name (API_SPEC.md §7);
/// an unknown value from a newer server is shown as [other].
@JsonEnum()
enum ContactRelationship {
  mother,
  father,
  parent,
  spouse,
  partner,
  sibling,
  child,
  relative,
  friend,
  neighbor,
  employer,
  colleague,
  other,
}

/// Where a contact stands with their invitation (API_SPEC.md §7). An unknown value
/// from a newer server is treated as [pending]: the app never claims someone accepted
/// unless the server said so.
@JsonEnum(fieldRename: FieldRename.snake)
enum VerificationStatus { pending, verified, declined, optedOut, bounced }

/// A trusted contact (`contact` object in API_SPEC.md §7).
///
/// The invitation fields describe the invitation history; the contact's answer is
/// [verificationStatus]. [notifiedAtStages] and [receivesInstructions] are filled in by
/// later phases.
@freezed
abstract class TrustedContact with _$TrustedContact {
  const TrustedContact._();

  /// Redacted: names and addresses must never reach a log.
  @override
  String toString() => 'TrustedContact(<redacted>)';

  const factory TrustedContact({
    required String id,
    required String displayName,
    @JsonKey(unknownEnumValue: ContactRelationship.other)
    required ContactRelationship relationship,
    required String email,
    @JsonKey(unknownEnumValue: VerificationStatus.pending)
    required VerificationStatus verificationStatus,
    String? relationshipLabel,
    String? phoneE164,
    @Default(1) int priority,
    DateTime? verifiedAt,
    @Default(true) bool isActive,
    DateTime? invitationSentAt,
    @Default(0) int invitationSendCount,
    @Default(<int>[]) List<int> notifiedAtStages,
    @Default(0) int receivesInstructions,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _TrustedContact;

  factory TrustedContact.fromJson(Map<String, dynamic> json) =>
      _$TrustedContactFromJson(json);

  /// The contact has accepted the invitation.
  bool get isAccepted => verificationStatus == VerificationStatus.verified;

  /// The contact cannot be notified and will not be, unless the person replaces them:
  /// they declined, opted out, or the invitation email bounced.
  bool get isUnreachable =>
      verificationStatus == VerificationStatus.declined ||
      verificationStatus == VerificationStatus.optedOut ||
      verificationStatus == VerificationStatus.bounced;

  /// Whether the server accepts "Resend invitation" for this contact: only while the
  /// invitation is unanswered or bounced (API_SPEC.md §7).
  bool get canResendInvitation =>
      verificationStatus == VerificationStatus.pending ||
      verificationStatus == VerificationStatus.bounced;
}

/// `GET /v1/contacts`.
@freezed
abstract class ContactList with _$ContactList {
  const factory ContactList({
    @Default(<TrustedContact>[]) List<TrustedContact> items,
  }) = _ContactList;

  factory ContactList.fromJson(Map<String, dynamic> json) =>
      _$ContactListFromJson(json);
}

/// The `limits` part of `GET /v1/me/entitlements`.
@freezed
abstract class EntitlementLimits with _$EntitlementLimits {
  const factory EntitlementLimits({
    required int contacts,
    @Default(0) int instructions,
    @Default(0) int stages,
    @Default(false) bool customOffsets,
  }) = _EntitlementLimits;

  factory EntitlementLimits.fromJson(Map<String, dynamic> json) =>
      _$EntitlementLimitsFromJson(json);
}

/// The `usage` part of `GET /v1/me/entitlements`.
@freezed
abstract class EntitlementUsage with _$EntitlementUsage {
  const factory EntitlementUsage({
    required int contacts,
    @Default(0) int instructions,
    @Default(0) int stages,
  }) = _EntitlementUsage;

  factory EntitlementUsage.fromJson(Map<String, dynamic> json) =>
      _$EntitlementUsageFromJson(json);
}

/// `GET /v1/me/entitlements`: the tier, what it allows and what is used.
@freezed
abstract class Entitlements with _$Entitlements {
  const Entitlements._();

  const factory Entitlements({
    required String tier,
    required EntitlementLimits limits,
    required EntitlementUsage usage,
  }) = _Entitlements;

  factory Entitlements.fromJson(Map<String, dynamic> json) =>
      _$EntitlementsFromJson(json);

  bool get isFree => tier == 'free';

  /// Another trusted contact would exceed the tier's limit.
  bool get contactsAtLimit => usage.contacts >= limits.contacts;

  /// Another instruction would exceed the tier's limit. A limit the answer left out (0)
  /// is not a limit: the server decides.
  bool get instructionsAtLimit =>
      limits.instructions > 0 && usage.instructions >= limits.instructions;
}
