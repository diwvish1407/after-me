import 'package:flutter/foundation.dart';

import 'models/contact_models.dart';

export 'models/contact_models.dart';

/// What the person typed for a new contact (`POST /v1/contacts`).
@immutable
class ContactDraft {
  const ContactDraft({
    required this.name,
    required this.relationship,
    required this.email,
    this.relationshipLabel,
    this.phone,
  });

  final String name;
  final ContactRelationship relationship;
  final String email;

  /// Free text; only sent when [relationship] is `other`.
  final String? relationshipLabel;

  /// E.164, or null.
  final String? phone;

  Map<String, Object?> toJson() => <String, Object?>{
    'display_name': name.trim(),
    'relationship': relationship.name,
    if (relationship == ContactRelationship.other &&
        (relationshipLabel?.trim().isNotEmpty ?? false))
      'relationship_label': relationshipLabel!.trim(),
    'email': email.trim(),
    if (phone != null && phone!.trim().isNotEmpty) 'phone_e164': phone!.trim(),
  };
}

/// A partial update (`PATCH /v1/contacts/{id}`). Only the fields that are set are
/// sent; [clearPhone] and [clearRelationshipLabel] send an explicit `null`.
@immutable
class ContactPatch {
  const ContactPatch({
    this.name,
    this.relationship,
    this.relationshipLabel,
    this.email,
    this.phone,
    this.priority,
    this.isActive,
    this.clearPhone = false,
    this.clearRelationshipLabel = false,
  });

  final String? name;
  final ContactRelationship? relationship;
  final String? relationshipLabel;
  final String? email;
  final String? phone;
  final int? priority;
  final bool? isActive;
  final bool clearPhone;
  final bool clearRelationshipLabel;

  bool get isEmpty => toJson().isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'display_name': ?name?.trim(),
    'relationship': ?relationship?.name,
    if (clearRelationshipLabel)
      'relationship_label': null
    else
      'relationship_label': ?relationshipLabel?.trim(),
    'email': ?email?.trim(),
    if (clearPhone) 'phone_e164': null else 'phone_e164': ?phone?.trim(),
    'priority': ?priority,
    'is_active': ?isActive,
  };
}

/// Trusted contacts and the plan limits that apply to them (API_SPEC.md §7).
///
/// Every method throws an `AppFailure` on error (see `toAppFailure`). The server is
/// authoritative for validation, ownership and tier limits; implementations never log
/// names or addresses.
abstract interface class ContactsRepository {
  /// `GET /v1/contacts`: priority order, as the server returns it.
  Future<List<TrustedContact>> list();

  /// `POST /v1/contacts`: creates the contact and queues the invitation.
  Future<TrustedContact> create(ContactDraft draft);

  /// `GET /v1/contacts/{id}`.
  Future<TrustedContact> get(String id);

  /// `PATCH /v1/contacts/{id}`. Changing the email resets verification and re-invites.
  Future<TrustedContact> update(String id, ContactPatch patch);

  /// `DELETE /v1/contacts/{id}`.
  Future<void> delete(String id);

  /// `POST /v1/contacts/{id}/invitation`: queues the invitation again.
  Future<void> resendInvitation(String id);

  /// `GET /v1/me/entitlements`.
  Future<Entitlements> entitlements();
}
