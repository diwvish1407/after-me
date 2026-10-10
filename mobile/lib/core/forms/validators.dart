import 'package:characters/characters.dart';

import '../../l10n/gen/app_localizations.dart';
import '../api/models/api_problem.dart';

/// Why a form field was rejected on the device. The server stays authoritative: it
/// applies the same rules (and a common-password blocklist) and its answer is mapped
/// with [issueFromFieldError].
enum FieldIssue {
  required,
  invalidEmail,
  passwordTooShort,
  passwordTooLong,
  passwordMatchesEmail,
  passwordTooCommon,
  nameTooLong,
  nameInvalid,
  nameHasLink,
  nameReserved,
  invalidPhone,
  invalidCode,
  sameEmail,
  samePassword,
  passwordsDiffer,
  invalidTimezone,
  invalidCountry,
  ownEmail,
  duplicateEmail,
  labelTooLong,
  labelInvalid,
  labelHasLink,
  titleTooLong,
  bodyTooLong,
  textInvalid,
}

/// Maps a [FieldIssue] to the calm copy in the ARB.
String issueMessage(AppLocalizations l10n, FieldIssue issue) => switch (issue) {
  FieldIssue.required => l10n.fieldRequired,
  FieldIssue.invalidEmail => l10n.fieldInvalidEmail,
  FieldIssue.passwordTooShort => l10n.fieldPasswordTooShort,
  FieldIssue.passwordTooLong => l10n.fieldPasswordTooLong,
  FieldIssue.passwordMatchesEmail => l10n.fieldPasswordMatchesEmail,
  FieldIssue.passwordTooCommon => l10n.fieldPasswordTooCommon,
  FieldIssue.nameTooLong => l10n.fieldNameTooLong,
  FieldIssue.nameInvalid => l10n.fieldNameInvalid,
  FieldIssue.nameHasLink => l10n.fieldNameHasLink,
  FieldIssue.nameReserved => l10n.fieldNameReserved,
  FieldIssue.invalidPhone => l10n.fieldInvalidPhone,
  FieldIssue.invalidCode => l10n.fieldInvalidCode,
  FieldIssue.sameEmail => l10n.fieldSameEmail,
  FieldIssue.samePassword => l10n.fieldSamePassword,
  FieldIssue.passwordsDiffer => l10n.fieldPasswordsDiffer,
  FieldIssue.invalidTimezone => l10n.fieldInvalidTimezone,
  FieldIssue.invalidCountry => l10n.fieldInvalidCountry,
  FieldIssue.ownEmail => l10n.fieldOwnEmail,
  FieldIssue.duplicateEmail => l10n.fieldDuplicateEmail,
  FieldIssue.labelTooLong => l10n.fieldLabelTooLong,
  FieldIssue.labelInvalid => l10n.fieldLabelInvalid,
  FieldIssue.labelHasLink => l10n.fieldLabelHasLink,
  FieldIssue.titleTooLong => l10n.fieldTitleTooLong,
  FieldIssue.bodyTooLong => l10n.fieldBodyTooLong,
  FieldIssue.textInvalid => l10n.fieldTextInvalid,
};

/// Maps a server field error code (API_SPEC.md §1.1) to a [FieldIssue], or null for
/// codes the app has no specific copy for.
FieldIssue? issueFromFieldError(ApiFieldError error) {
  final field = error.field;
  final isPassword = field.endsWith('password');
  return switch (error.code) {
    'required' => FieldIssue.required,
    // An instruction's title and text (API_SPEC.md §10).
    'too_long' when field == 'title' => FieldIssue.titleTooLong,
    'too_long' when field == 'body' => FieldIssue.bodyTooLong,
    'invalid_characters' when field == 'title' || field == 'body' =>
      FieldIssue.textInvalid,
    'invalid_email' => FieldIssue.invalidEmail,
    'too_long' when field.contains('label') => FieldIssue.labelTooLong,
    'invalid_characters' when field.contains('label') =>
      FieldIssue.labelInvalid,
    'invalid_relationship_label' => FieldIssue.labelInvalid,
    'contains_link' => FieldIssue.labelHasLink,
    'too_short' when isPassword => FieldIssue.passwordTooShort,
    'too_long' when isPassword => FieldIssue.passwordTooLong,
    'too_short' when field.contains('name') => FieldIssue.required,
    'too_long' when field.contains('name') => FieldIssue.nameTooLong,
    'password_matches_email' => FieldIssue.passwordMatchesEmail,
    'password_too_common' => FieldIssue.passwordTooCommon,
    'invalid_display_name' || 'invalid_characters' => FieldIssue.nameInvalid,
    'display_name_link' => FieldIssue.nameHasLink,
    'display_name_reserved' => FieldIssue.nameReserved,
    'invalid_phone' || 'invalid_phone_e164' => FieldIssue.invalidPhone,
    'invalid_timezone' => FieldIssue.invalidTimezone,
    'invalid_country_code' => FieldIssue.invalidCountry,
    'invalid_code_format' => FieldIssue.invalidCode,
    'cannot_be_own_email' => FieldIssue.ownEmail,
    'contact_duplicate' => FieldIssue.duplicateEmail,
    _ => null,
  };
}

/// The first server message for [field] (or one of its sub-fields), if the app has
/// copy for it.
FieldIssue? issueForField(List<ApiFieldError> errors, String field) {
  for (final error in errors) {
    if (error.field == field) {
      final issue = issueFromFieldError(error);
      if (issue != null) {
        return issue;
      }
    }
  }
  return null;
}

/// Pure client-side validators. They return null when the value is acceptable.
abstract final class Validators {
  static const int passwordMin = 10;
  static const int passwordMax = 128;
  static const int displayNameMax = 80;
  static const int emailMax = 254;
  static const int relationshipLabelMax = 40;
  static const int instructionTitleMax = 120;
  static const int instructionBodyMax = 20000;

  static final RegExp _email = RegExp(
    r'^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?'
    r'(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$',
  );
  static final RegExp _phone = RegExp(r'^\+[1-9]\d{6,14}$');
  static final RegExp _link = RegExp(
    r'(://|www\.|@|\b[a-z0-9-]+\.(?:[a-z]{2,24})\b)',
    caseSensitive: false,
  );

  /// Trims [value]; the API normalises case itself.
  static String cleanEmail(String value) => value.trim();

  static FieldIssue? email(String value) {
    final email = cleanEmail(value);
    if (email.isEmpty) {
      return FieldIssue.required;
    }
    if (email.length > emailMax || !_email.hasMatch(email)) {
      return FieldIssue.invalidEmail;
    }
    return null;
  }

  static FieldIssue? displayName(String value) {
    final name = value.trim();
    if (name.isEmpty) {
      return FieldIssue.required;
    }
    if (name.characters.length > displayNameMax) {
      return FieldIssue.nameTooLong;
    }
    if (name.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0))) {
      return FieldIssue.nameInvalid;
    }
    if (_link.hasMatch(name)) {
      return FieldIssue.nameHasLink;
    }
    if (name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .contains('afterme')) {
      return FieldIssue.nameReserved;
    }
    return null;
  }

  /// Signup / reset policy: 10-128 characters, not the email or its local part.
  /// The common-password blocklist is applied by the server.
  static FieldIssue? newPassword(String value, {String? email}) {
    if (value.isEmpty) {
      return FieldIssue.required;
    }
    final length = value.characters.length;
    if (length < passwordMin) {
      return FieldIssue.passwordTooShort;
    }
    if (length > passwordMax) {
      return FieldIssue.passwordTooLong;
    }
    if (email != null && email.trim().isNotEmpty) {
      final folded = value.toLowerCase();
      final address = email.trim().toLowerCase();
      final local = address.split('@').first;
      if (folded == address || folded == local) {
        return FieldIssue.passwordMatchesEmail;
      }
    }
    return null;
  }

  /// An existing password is not policy-checked, only required.
  static FieldIssue? existingPassword(String value) =>
      value.isEmpty ? FieldIssue.required : null;

  /// The optional free-text description used with the "Other" relationship: at most
  /// 40 characters, no control characters and no links. Empty is fine.
  static FieldIssue? relationshipLabel(String value) {
    final label = value.trim();
    if (label.isEmpty) {
      return null;
    }
    if (label.characters.length > relationshipLabelMax) {
      return FieldIssue.labelTooLong;
    }
    if (label.runes.any((r) => r < 0x20 || (r >= 0x7f && r < 0xa0))) {
      return FieldIssue.labelInvalid;
    }
    if (_link.hasMatch(label)) {
      return FieldIssue.labelHasLink;
    }
    return null;
  }

  /// Reordering and invisible characters that can make text read differently than it is
  /// (embeddings, overrides, isolates, directional marks, word joiner, BOM): refused by
  /// the server in instructions.
  static const Set<int> _textDirection = {
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, //
    0x200E, 0x200F, 0x061C, 0x2060, 0xFEFF,
  };

  /// Plain text rules of an instruction (API_SPEC.md §10): no control characters (the
  /// body may have line breaks and tabs) and no text-direction characters.
  static bool _hasForbiddenCharacters(String text, {required bool multiline}) =>
      text.runes.any((r) {
        if (_textDirection.contains(r)) {
          return true;
        }
        final control = r < 0x20 || (r >= 0x7f && r < 0xa0);
        final allowed = multiline && (r == 0x0a || r == 0x09 || r == 0x0d);
        return control && !allowed;
      });

  /// An instruction's title: 1-120 characters, one line, plain text.
  static FieldIssue? instructionTitle(String value) {
    final title = value.trim();
    if (title.isEmpty) {
      return FieldIssue.required;
    }
    if (title.runes.length > instructionTitleMax) {
      return FieldIssue.titleTooLong;
    }
    if (_hasForbiddenCharacters(title, multiline: false)) {
      return FieldIssue.textInvalid;
    }
    return null;
  }

  /// An instruction's text: 1-20,000 characters (code points, like the server), plain
  /// text with line breaks.
  static FieldIssue? instructionBody(String value) {
    final body = value.replaceAll('\r\n', '\n').trim();
    if (body.isEmpty) {
      return FieldIssue.required;
    }
    if (body.runes.length > instructionBodyMax) {
      return FieldIssue.bodyTooLong;
    }
    if (_hasForbiddenCharacters(body, multiline: true)) {
      return FieldIssue.textInvalid;
    }
    return null;
  }

  /// Removes the spaces, dashes, dots and brackets people type in a phone number.
  static String cleanPhone(String value) =>
      value.trim().replaceAll(RegExp(r'[\s\-().]'), '');

  /// Optional E.164 phone number: `+` and 7-15 digits. Empty is fine.
  static FieldIssue? phone(String value) {
    final phone = value.trim();
    if (phone.isEmpty) {
      return null;
    }
    return _phone.hasMatch(phone) ? null : FieldIssue.invalidPhone;
  }

  /// A 6-digit code (spaces and dashes pasted by the user are removed first).
  static FieldIssue? code(String value) {
    final digits = normalizeCode(value);
    if (digits.isEmpty) {
      return FieldIssue.required;
    }
    return digits.length == 6 ? null : FieldIssue.invalidCode;
  }

  /// Keeps only the digits: pasted codes often carry spaces or dashes.
  static String normalizeCode(String value) =>
      value.replaceAll(RegExp(r'[^0-9]'), '');
}

/// How strong a new password looks. Deliberately gentle: it is a hint, not a rule
/// (USER_FLOWS.md §15 wording rules).
enum PasswordStrength { empty, tooShort, fine, strong }

PasswordStrength passwordStrength(String value, {String? email}) {
  if (value.isEmpty) {
    return PasswordStrength.empty;
  }
  if (Validators.newPassword(value, email: email) != null) {
    return PasswordStrength.tooShort;
  }
  final length = value.characters.length;
  final classes = [
    RegExp('[a-z]'),
    RegExp('[A-Z]'),
    RegExp('[0-9]'),
    RegExp('[^A-Za-z0-9]'),
  ].where((r) => r.hasMatch(value)).length;
  final words = value.trim().split(RegExp(r'\s+')).length;
  if (length >= 16 || (length >= 12 && classes >= 3) || words >= 4) {
    return PasswordStrength.strong;
  }
  return PasswordStrength.fine;
}

String passwordStrengthHint(AppLocalizations l10n, PasswordStrength strength) =>
    switch (strength) {
      PasswordStrength.empty => l10n.passwordHintEmpty,
      PasswordStrength.tooShort => l10n.passwordHintTooShort,
      PasswordStrength.fine => l10n.passwordHintFine,
      PasswordStrength.strong => l10n.passwordHintStrong,
    };
