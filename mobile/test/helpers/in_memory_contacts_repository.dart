import 'dart:async';

import 'package:afterme/core/api/failures/app_failure.dart';
import 'package:afterme/features/contacts/data/contacts_repository.dart';

/// What the server looks at before it lets a trusted contact be taken out of a safety
/// net that is on (SECURITY.md §7): whether check-ins are switched on, whether the
/// contact is in a plan stage or receives an active instruction, and whether the session
/// entered its password recently.
/// `TestFakes` wires it to the check-in and plan fakes.
class ContactStepUp {
  const ContactStepUp({
    required this.scheduleOff,
    required this.inPlan,
    required this.reauthenticated,
    this.receivesInstruction,
  });

  /// Check-ins are `inactive` (onboarding): nothing needs the password.
  final bool Function() scheduleOff;

  /// The contact is in at least one plan stage.
  final bool Function(String contactId) inPlan;

  /// The session re-authenticated within the last 5 minutes.
  final bool Function() reauthenticated;

  /// The contact receives an active instruction (a recipient who is in no stage is held
  /// to the same rule). Null: nobody does.
  final bool Function(String contactId)? receivesInstruction;

  /// Throws 403 `reauth_required` when this contact may not be removed, switched off or
  /// pointed at another address right now.
  void check(String contactId) {
    final guarded =
        inPlan(contactId) || (receivesInstruction?.call(contactId) ?? false);
    if (!scheduleOff() && guarded && !reauthenticated()) {
      throw const ForbiddenFailure(code: 'reauth_required');
    }
  }
}

/// A [ContactsRepository] for tests that behaves like the server: it validates the way
/// the contract describes (own email, duplicates, the free-tier limit, resend rules),
/// numbers contacts by priority, and lets a test script failures and recipient answers.
///
/// It lives in `test/` on purpose: the app itself talks to the real API since Phase 3.
class InMemoryContactsRepository implements ContactsRepository {
  InMemoryContactsRepository({
    this.ownEmail = 'diwakar@example.com',
    this.tier = 'free',
    int? limit,
    List<TrustedContact> initial = const [],
  }) : limit = limit ?? (tier == 'free' ? 1 : 25) {
    _contacts.addAll(initial);
    _next = initial.length + 1;
  }

  final String ownEmail;
  String tier;
  int limit;

  final List<TrustedContact> _contacts = [];
  int _next = 1;
  DateTime now = DateTime.utc(2026, 10, 8, 12);

  /// Names of the calls received, in order.
  final List<String> calls = [];

  /// When set, `list` waits for it (to show the loading state).
  Future<void>? listGate;

  /// Failures thrown by the next calls to the named method, consumed in order.
  final Map<String, List<AppFailure>> failures = {};

  /// How many instructions exist, for `usage.instructions` of the entitlements
  /// (`TestFakes` wires it to the instructions "server").
  int Function()? instructionUsage;

  /// How many stages the plan has, for `usage.stages` (`TestFakes` wires it to the plan
  /// "server").
  int Function()? stageUsage;

  /// The step-up rule (`TestFakes` sets it). Null: a change never asks for the password,
  /// which is what the contact tests that have no plan or schedule need.
  ContactStepUp? stepUp;

  /// Invitation sends per contact id (create, email change and resend each count).
  final Map<String, int> invitations = {};

  List<TrustedContact> get contacts => List.unmodifiable(_contacts);

  void _enter(String method) {
    calls.add(method);
    final queue = failures[method];
    if (queue != null && queue.isNotEmpty) {
      throw queue.removeAt(0);
    }
  }

  static String normalise(String email) => email.trim().toLowerCase();

  /// Plays the recipient: sets the answer of a contact.
  void respond(String id, VerificationStatus status) {
    final index = _contacts.indexWhere((c) => c.id == id);
    _contacts[index] = _contacts[index].copyWith(
      verificationStatus: status,
      verifiedAt: status == VerificationStatus.verified ? now : null,
    );
  }

  void _checkEmail(String email, {String? exceptId}) {
    final normalised = normalise(email);
    if (normalised == normalise(ownEmail)) {
      throw const CannotBeOwnEmailFailure();
    }
    if (_contacts.any(
      (c) => c.id != exceptId && normalise(c.email) == normalised,
    )) {
      throw const ContactDuplicateFailure();
    }
  }

  void _invite(String id) {
    invitations[id] = (invitations[id] ?? 0) + 1;
  }

  @override
  Future<List<TrustedContact>> list() async {
    _enter('list');
    await listGate;
    return List.unmodifiable(_contacts);
  }

  @override
  Future<TrustedContact> create(ContactDraft draft) async {
    _enter('create');
    if (_contacts.length >= limit) {
      throw PlanLimitFailure(
        limit: limit,
        current: _contacts.length,
        resource: 'contacts',
      );
    }
    _checkEmail(draft.email);
    final id = 'contact-${_next++}';
    final contact = TrustedContact(
      id: id,
      displayName: draft.name.trim(),
      relationship: draft.relationship,
      relationshipLabel: draft.relationship == ContactRelationship.other
          ? draft.relationshipLabel?.trim()
          : null,
      email: normalise(draft.email),
      phoneE164: draft.phone,
      priority: _contacts.length + 1,
      verificationStatus: VerificationStatus.pending,
      invitationSentAt: now,
      invitationSendCount: 1,
      createdAt: now,
      updatedAt: now,
    );
    _contacts.add(contact);
    _invite(id);
    return contact;
  }

  int _indexOf(String id) {
    final index = _contacts.indexWhere((c) => c.id == id);
    if (index < 0) {
      throw const NotFoundFailure();
    }
    return index;
  }

  @override
  Future<TrustedContact> get(String id) async {
    _enter('get');
    return _contacts[_indexOf(id)];
  }

  @override
  Future<TrustedContact> update(String id, ContactPatch patch) async {
    _enter('update');
    final index = _indexOf(id);
    final current = _contacts[index];
    final emailChanged =
        patch.email != null &&
        normalise(patch.email!) != normalise(current.email);
    if (patch.email != null) {
      _checkEmail(patch.email!, exceptId: id);
    }
    // After ownership (404) and validation (422, 409), like the server: only a change of
    // address, or switching the contact off, is taken as weakening the safety net.
    if (emailChanged || patch.isActive == false) {
      stepUp?.check(id);
    }
    final relationship = patch.relationship ?? current.relationship;
    var updated = current.copyWith(
      displayName: patch.name?.trim() ?? current.displayName,
      relationship: relationship,
      relationshipLabel: relationship != ContactRelationship.other
          ? null
          : patch.clearRelationshipLabel
          ? null
          : patch.relationshipLabel?.trim() ?? current.relationshipLabel,
      phoneE164: patch.clearPhone ? null : patch.phone ?? current.phoneE164,
      priority: patch.priority ?? current.priority,
      isActive: patch.isActive ?? current.isActive,
      updatedAt: now,
    );
    if (emailChanged) {
      updated = updated.copyWith(
        email: normalise(patch.email!),
        verificationStatus: VerificationStatus.pending,
        verifiedAt: null,
        invitationSentAt: now,
        invitationSendCount: current.invitationSendCount + 1,
      );
      _invite(id);
    }
    return _contacts[index] = updated;
  }

  @override
  Future<void> delete(String id) async {
    _enter('delete');
    final index = _indexOf(id);
    stepUp?.check(id);
    _contacts.removeAt(index);
  }

  @override
  Future<void> resendInvitation(String id) async {
    _enter('resendInvitation');
    final index = _indexOf(id);
    final contact = _contacts[index];
    if (!contact.canResendInvitation) {
      throw const InvalidStateFailure();
    }
    _contacts[index] = contact.copyWith(
      invitationSentAt: now,
      invitationSendCount: contact.invitationSendCount + 1,
    );
    _invite(id);
  }

  @override
  Future<Entitlements> entitlements() async {
    _enter('entitlements');
    return Entitlements(
      tier: tier,
      limits: EntitlementLimits(
        contacts: limit,
        instructions: tier == 'free' ? 3 : 200,
        stages: tier == 'free' ? 2 : 10,
        customOffsets: tier != 'free',
      ),
      usage: EntitlementUsage(
        contacts: _contacts.length,
        instructions: instructionUsage?.call() ?? 0,
        stages: stageUsage?.call() ?? 0,
      ),
    );
  }
}

/// A verified contact for tests.
TrustedContact testContact({
  String id = 'c1',
  String name = 'Mom',
  ContactRelationship relationship = ContactRelationship.mother,
  String email = 'mom@example.com',
  VerificationStatus status = VerificationStatus.verified,
  int priority = 1,
  String? phone,
  String? label,
  int sendCount = 1,
  DateTime? sentAt,
  int receivesInstructions = 0,
}) => TrustedContact(
  id: id,
  displayName: name,
  relationship: relationship,
  relationshipLabel: label,
  email: email,
  phoneE164: phone,
  priority: priority,
  verificationStatus: status,
  verifiedAt: status == VerificationStatus.verified
      ? DateTime.utc(2026, 10, 8, 11)
      : null,
  invitationSentAt: sentAt ?? DateTime.utc(2026, 10, 8, 10, 30),
  invitationSendCount: sendCount,
  receivesInstructions: receivesInstructions,
  createdAt: DateTime.utc(2026, 10, 8, 10),
  updatedAt: DateTime.utc(2026, 10, 8, 10),
);
