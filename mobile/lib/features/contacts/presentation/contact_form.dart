import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/dimens.dart';
import '../../../core/api/failures/app_failure.dart';
import '../../../core/api/models/api_problem.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/forms/validators.dart';
import '../../../core/platform/contact_picker.dart';
import '../../../core/security/app_lock/app_lock_controller.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../application/contacts_controller.dart';
import '../data/contacts_repository.dart';
import 'contact_labels.dart';
import 'contact_limit_sheet.dart';

/// What the person entered in [ContactForm], already trimmed and validated on the
/// device. The server validates again.
@immutable
class ContactFormValues {
  const ContactFormValues({
    required this.name,
    required this.relationship,
    required this.email,
    this.label,
    this.phone,
  });

  final String name;
  final ContactRelationship relationship;

  /// Only set for [ContactRelationship.other].
  final String? label;
  final String email;
  final String? phone;

  ContactDraft toDraft() => ContactDraft(
    name: name,
    relationship: relationship,
    relationshipLabel: label,
    email: email,
    phone: phone,
  );
}

/// The fields for adding or editing a trusted contact (USER_FLOWS §8), shared by the
/// Add and Edit screens and onboarding step 4: the system contact picker (no
/// `READ_CONTACTS` permission), name, relationship chips (with a description for
/// "Other"), email and an optional phone, then the primary action.
///
/// [onSubmit] performs the save and throws an `AppFailure` when it fails. The form maps
/// what the server said back onto the fields (own email, duplicate, validation errors),
/// opens the plan-limit sheet for `plan_limit_reached`, and shows any other failure in
/// a calm notice. It does not navigate: the caller does, after [onSubmit] returns.
class ContactForm extends ConsumerStatefulWidget {
  const ContactForm({
    required this.submitLabel,
    required this.onSubmit,
    this.initial,
    super.key,
  });

  final String submitLabel;

  /// The contact being edited, or null when adding.
  final TrustedContact? initial;
  final Future<void> Function(ContactFormValues values) onSubmit;

  @override
  ConsumerState<ContactForm> createState() => _ContactFormState();
}

class _ContactFormState extends ConsumerState<ContactForm> {
  late final TextEditingController _name;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _label;
  ContactRelationship? _relationship;
  bool _busy = false;
  bool _relationshipMissing = false;
  String? _pickerNotice;
  AppFailure? _failure;
  FieldIssue? _nameIssue;
  FieldIssue? _emailIssue;
  FieldIssue? _phoneIssue;
  FieldIssue? _labelIssue;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.displayName);
    _email = TextEditingController(text: initial?.email);
    _phone = TextEditingController(text: initial?.phoneE164);
    _label = TextEditingController(text: initial?.relationshipLabel);
    _relationship = initial?.relationship;
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _pickerNotice = null);
    try {
      // The picker is a separate activity: it must not count as leaving the app.
      final picked = await ref
          .read(appLockControllerProvider.notifier)
          .runWithoutLocking(() => ref.read(contactPickerProvider).pick());
      if (!mounted || picked == null) {
        return;
      }
      setState(() {
        if (picked.name.isNotEmpty) {
          _name.text = picked.name;
        }
        _email.text = picked.email;
        _nameIssue = null;
        _emailIssue = null;
      });
    } on ContactPickException {
      if (mounted) {
        setState(() => _pickerNotice = l10n.contactPickUnavailable);
      }
    }
  }

  bool get _emailChanged {
    final initial = widget.initial;
    final typed = Validators.cleanEmail(_email.text).toLowerCase();
    return initial != null &&
        typed.isNotEmpty &&
        typed != initial.email.trim().toLowerCase();
  }

  Future<void> _submit() async {
    final other = _relationship == ContactRelationship.other;
    final nameIssue = Validators.displayName(_name.text);
    final emailIssue = Validators.email(_email.text);
    final phoneIssue = Validators.phone(Validators.cleanPhone(_phone.text));
    final labelIssue = other ? Validators.relationshipLabel(_label.text) : null;
    setState(() {
      _nameIssue = nameIssue;
      _emailIssue = emailIssue;
      _phoneIssue = phoneIssue;
      _labelIssue = labelIssue;
      _relationshipMissing = _relationship == null;
      _failure = null;
    });
    if (nameIssue != null ||
        emailIssue != null ||
        phoneIssue != null ||
        labelIssue != null ||
        _relationship == null) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final phone = Validators.cleanPhone(_phone.text);
    try {
      await widget.onSubmit(
        ContactFormValues(
          name: _name.text.trim(),
          relationship: _relationship!,
          label: other && _label.text.trim().isNotEmpty
              ? _label.text.trim()
              : null,
          email: Validators.cleanEmail(_email.text),
          phone: phone.isEmpty ? null : phone,
        ),
      );
      if (mounted) {
        setState(() => _busy = false);
      }
    } on AppFailure catch (failure) {
      if (mounted) {
        _showFailure(failure);
      }
    }
  }

  void _showFailure(AppFailure failure) {
    var general = true;
    FieldIssue? name;
    FieldIssue? email;
    FieldIssue? phone;
    FieldIssue? label;
    var relationshipMissing = false;
    switch (failure) {
      case PlanLimitFailure():
        general = false;
        final entitlements = ref.read(entitlementsProvider).value;
        ref.invalidate(entitlementsProvider);
        unawaited(
          showContactLimitSheet(
            context,
            limit: failure.limit ?? entitlements?.limits.contacts,
            free:
                entitlements?.isFree ??
                (failure.limit ?? freeContactLimit) <= freeContactLimit,
          ),
        );
      case CannotBeOwnEmailFailure():
        general = false;
        email = FieldIssue.ownEmail;
      case ContactDuplicateFailure():
        general = false;
        email = FieldIssue.duplicateEmail;
      case ValidationFailure(:final fieldErrors) when fieldErrors.isNotEmpty:
        name = _fieldIssue(fieldErrors, 'display_name', FieldIssue.nameInvalid);
        email = _fieldIssue(fieldErrors, 'email', FieldIssue.invalidEmail);
        phone = _fieldIssue(fieldErrors, 'phone_e164', FieldIssue.invalidPhone);
        label = _fieldIssue(
          fieldErrors,
          'relationship_label',
          FieldIssue.labelInvalid,
        );
        relationshipMissing = fieldErrors.any((e) => e.field == 'relationship');
        general =
            name == null &&
            email == null &&
            phone == null &&
            label == null &&
            !relationshipMissing;
      default:
    }
    setState(() {
      _busy = false;
      _failure = general ? failure : null;
      _nameIssue = name;
      _emailIssue = email;
      _phoneIssue = phone;
      _labelIssue = label;
      _relationshipMissing = relationshipMissing;
    });
  }

  /// The inline issue for [field]: the specific one when the app has copy for the
  /// server's code, [fallback] for any other error on that field.
  FieldIssue? _fieldIssue(
    List<ApiFieldError> errors,
    String field,
    FieldIssue fallback,
  ) =>
      issueForField(errors, field) ??
      (errors.any((e) => e.field == field) ? fallback : null);

  String? _message(AppLocalizations l10n, FieldIssue? issue) =>
      issue == null ? null : issueMessage(l10n, issue);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final editing = widget.initial != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_failure != null) ...[FailureNotice.of(context, _failure!), Gap.md],
        AppButton.secondary(
          label: l10n.contactPickFromPhone,
          icon: Icons.contacts_outlined,
          onPressed: _busy ? null : _pick,
          expand: true,
        ),
        if (_pickerNotice != null) ...[Gap.xs, BodyText(_pickerNotice!)],
        Gap.md,
        AppTextField(
          label: l10n.fieldContactName,
          controller: _name,
          errorText: _message(l10n, _nameIssue),
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          enabled: !_busy,
          onChanged: (_) => setState(() => _nameIssue = null),
        ),
        Gap.md,
        Semantics(
          header: true,
          child: Text(
            l10n.fieldRelationship,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Gap.xs,
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xxs,
          children: [
            for (final value in ContactRelationship.values)
              ChoiceChip(
                label: Text(relationshipName(l10n, value)),
                selected: _relationship == value,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _relationship = value;
                        _relationshipMissing = false;
                      }),
              ),
          ],
        ),
        if (_relationshipMissing) ...[
          Gap.xs,
          Semantics(
            liveRegion: true,
            child: Text(
              l10n.relationshipRequired,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
        if (_relationship == ContactRelationship.other) ...[
          Gap.md,
          AppTextField(
            label: l10n.fieldContactRelationshipLabel,
            controller: _label,
            errorText: _message(l10n, _labelIssue),
            textInputAction: TextInputAction.next,
            textCapitalization: TextCapitalization.sentences,
            enabled: !_busy,
            onChanged: (_) => setState(() => _labelIssue = null),
          ),
        ],
        Gap.md,
        AppTextField(
          label: l10n.fieldContactEmail,
          controller: _email,
          errorText: _message(l10n, _emailIssue),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          enabled: !_busy,
          onChanged: (_) => setState(() => _emailIssue = null),
        ),
        Gap.md,
        AppTextField(
          label: l10n.fieldContactPhone,
          helperText: l10n.fieldContactPhoneHelper,
          controller: _phone,
          errorText: _message(l10n, _phoneIssue),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          enabled: !_busy,
          onChanged: (_) => setState(() => _phoneIssue = null),
          onSubmitted: (_) => _submit(),
        ),
        Gap.md,
        if (editing && _emailChanged)
          StatusBanner(
            kind: StatusBannerKind.attention,
            message: l10n.contactFormEmailChangeWarning,
            liveRegion: true,
          )
        else if (!editing)
          BodyText(l10n.contactFormInviteExplain),
        Gap.lg,
        AppButton.primary(
          label: widget.submitLabel,
          onPressed: _submit,
          isLoading: _busy,
          expand: true,
        ),
      ],
    );
  }
}
