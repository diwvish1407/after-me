import 'package:afterme/core/api/models/api_problem.dart';
import 'package:afterme/core/forms/digits_formatter.dart';
import 'package:afterme/core/forms/validators.dart';
import 'package:afterme/l10n/gen/app_localizations.dart';
import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Validators.email', () {
    test('accepts ordinary addresses and trims', () {
      for (final ok in [
        'a@b.co',
        ' diwakar@example.com ',
        'first.last+tag@sub.example.org',
      ]) {
        expect(Validators.email(ok), isNull, reason: ok);
      }
      expect(Validators.cleanEmail('  a@b.co '), 'a@b.co');
    });

    test('rejects empty and malformed addresses', () {
      expect(Validators.email('  '), FieldIssue.required);
      for (final bad in [
        'abc',
        'a@b',
        '@b.co',
        'a@@b.co',
        'a b@c.de',
        'a@b..co',
      ]) {
        expect(Validators.email(bad), FieldIssue.invalidEmail, reason: bad);
      }
      expect(Validators.email('${'a' * 250}@b.co'), FieldIssue.invalidEmail);
    });
  });

  group('Validators.displayName', () {
    test('accepts names in any script', () {
      for (final ok in ['Diwakar', 'Asha Rao', 'दिवाकर', '李小龙', "O'Neil"]) {
        expect(Validators.displayName(ok), isNull, reason: ok);
      }
    });

    test('applies the server rules', () {
      expect(Validators.displayName('   '), FieldIssue.required);
      expect(Validators.displayName('x' * 81), FieldIssue.nameTooLong);
      expect(Validators.displayName('a\u0000b'), FieldIssue.nameInvalid);
      expect(
        Validators.displayName('visit www.spam.com'),
        FieldIssue.nameHasLink,
      );
      expect(Validators.displayName('me@spam'), FieldIssue.nameHasLink);
      expect(Validators.displayName('Team After-Me'), FieldIssue.nameReserved);
      expect(
        Validators.displayName('AFTERME support'),
        FieldIssue.nameReserved,
      );
    });

    test('counts characters, not UTF-16 units', () {
      expect(Validators.displayName('👩‍👩‍👧' * 80), isNull);
    });
  });

  group('Validators.newPassword', () {
    test('needs 10 to 128 characters', () {
      expect(Validators.newPassword(''), FieldIssue.required);
      expect(Validators.newPassword('123456789'), FieldIssue.passwordTooShort);
      expect(Validators.newPassword('1234567890'), isNull);
      expect(Validators.newPassword('a' * 128), isNull);
      expect(Validators.newPassword('a' * 129), FieldIssue.passwordTooLong);
    });

    test('rejects the email address and its local part', () {
      expect(
        Validators.newPassword(
          'diwakar@example.com',
          email: 'Diwakar@Example.com',
        ),
        FieldIssue.passwordMatchesEmail,
      );
      expect(
        Validators.newPassword(
          'longlocalpart',
          email: 'longlocalpart@example.com',
        ),
        FieldIssue.passwordMatchesEmail,
      );
      expect(
        Validators.newPassword('something else entirely', email: 'a@b.co'),
        isNull,
      );
      expect(
        Validators.newPassword('longlocalpart', email: '   '),
        isNull,
        reason: 'an empty email gives nothing to compare with',
      );
    });

    test('existingPassword only requires a value', () {
      expect(Validators.existingPassword(''), FieldIssue.required);
      expect(Validators.existingPassword('x'), isNull);
    });
  });

  group('Validators.phone and code', () {
    test('phone is optional and E.164', () {
      expect(Validators.phone(''), isNull);
      expect(Validators.phone(' +919876543210 '), isNull);
      for (final bad in [
        '9876543210',
        '+0123456789',
        '+12',
        '+1234567890123456',
        'abc',
      ]) {
        expect(Validators.phone(bad), FieldIssue.invalidPhone, reason: bad);
      }
    });

    test('code accepts pasted separators', () {
      expect(Validators.code(''), FieldIssue.required);
      expect(Validators.code('12345'), FieldIssue.invalidCode);
      expect(Validators.code('123456'), isNull);
      expect(Validators.code('123 456'), isNull);
      expect(Validators.code('123-456'), isNull);
      expect(Validators.normalizeCode(' 12-34 56 '), '123456');
    });
  });

  group('contact form validators', () {
    test(
      'the relationship description: at most 40 characters, no controls',
      () {
        expect(Validators.relationshipLabel(''), isNull);
        expect(Validators.relationshipLabel('  '), isNull);
        expect(Validators.relationshipLabel('Neighbour upstairs'), isNull);
        expect(Validators.relationshipLabel('x' * 40), isNull);
        expect(Validators.relationshipLabel('x' * 41), FieldIssue.labelTooLong);
        expect(
          Validators.relationshipLabel('a\u0000b'),
          FieldIssue.labelInvalid,
        );
        expect(Validators.relationshipLabel('e\u0301' * 20), isNull);
        expect(
          Validators.relationshipLabel('see example.com'),
          FieldIssue.labelHasLink,
        );
        expect(Validators.relationshipLabel('mail@x'), FieldIssue.labelHasLink);
      },
    );

    test('phone numbers are cleaned of spaces, dashes, dots and brackets', () {
      expect(Validators.cleanPhone(' +1 (415) 555-0123 '), '+14155550123');
      expect(Validators.cleanPhone('+49.151.1234'), '+491511234');
      expect(
        Validators.phone(Validators.cleanPhone('+1 415 555 0123')),
        isNull,
      );
      expect(
        Validators.phone(Validators.cleanPhone('415 555 0123')),
        isNotNull,
      );
    });

    test('the new issues have calm copy and server codes map to them', () {
      final l10n = AppLocalizationsEn();
      for (final issue in [
        FieldIssue.ownEmail,
        FieldIssue.duplicateEmail,
        FieldIssue.labelTooLong,
        FieldIssue.labelInvalid,
        FieldIssue.labelHasLink,
      ]) {
        final text = issueMessage(l10n, issue);
        expect(text, isNotEmpty);
        expect(text, isNot(contains('!')));
      }
      expect(
        issueFromFieldError(
          const ApiFieldError(field: 'email', code: 'cannot_be_own_email'),
        ),
        FieldIssue.ownEmail,
      );
      expect(
        issueFromFieldError(
          const ApiFieldError(field: 'email', code: 'contact_duplicate'),
        ),
        FieldIssue.duplicateEmail,
      );
      const label = 'relationship_label';
      expect(
        issueFromFieldError(
          const ApiFieldError(field: label, code: 'too_long'),
        ),
        FieldIssue.labelTooLong,
      );
      expect(
        issueFromFieldError(
          const ApiFieldError(field: label, code: 'invalid_characters'),
        ),
        FieldIssue.labelInvalid,
      );
      expect(
        issueFromFieldError(
          const ApiFieldError(field: label, code: 'contains_link'),
        ),
        FieldIssue.labelHasLink,
      );
      expect(
        issueFromFieldError(
          const ApiFieldError(field: label, code: 'invalid_relationship_label'),
        ),
        FieldIssue.labelInvalid,
      );
      expect(
        issueFromFieldError(
          const ApiFieldError(
            field: 'display_name',
            code: 'invalid_characters',
          ),
        ),
        FieldIssue.nameInvalid,
        reason: 'names keep their own wording',
      );
    });
  });

  group('DigitsOnlyFormatter', () {
    TextEditingValue run(String text) => const DigitsOnlyFormatter()
        .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text));

    test('keeps digits only and at most six', () {
      expect(run('123456').text, '123456');
      expect(run('482 913').text, '482913');
      expect(run('482-913-77').text, '482913');
      expect(run('abc').text, '');
      expect(run('4829130').selection.baseOffset, 6);
    });
  });

  group('password strength', () {
    test('is gentle and graded', () {
      expect(passwordStrength(''), PasswordStrength.empty);
      expect(passwordStrength('short'), PasswordStrength.tooShort);
      expect(passwordStrength('abcdefghij'), PasswordStrength.fine);
      expect(passwordStrength('Abcdefg1hijk!'), PasswordStrength.strong);
      expect(
        passwordStrength('correct horse battery staple'),
        PasswordStrength.strong,
      );
      expect(
        passwordStrength('diwakar@example.com', email: 'diwakar@example.com'),
        PasswordStrength.tooShort,
      );
    });

    test('every strength has calm copy without exclamation marks', () {
      final l10n = AppLocalizationsEn();
      for (final s in PasswordStrength.values) {
        final text = passwordStrengthHint(l10n, s);
        expect(text, isNotEmpty);
        expect(text, isNot(contains('!')));
      }
    });
  });

  group('server field errors', () {
    ApiFieldError e(String field, String code) =>
        ApiFieldError(field: field, code: code);

    test('map to issues', () {
      expect(
        issueFromFieldError(e('password', 'too_short')),
        FieldIssue.passwordTooShort,
      );
      expect(
        issueFromFieldError(e('new_password', 'too_long')),
        FieldIssue.passwordTooLong,
      );
      expect(
        issueFromFieldError(e('display_name', 'too_short')),
        FieldIssue.required,
      );
      expect(
        issueFromFieldError(e('display_name', 'too_long')),
        FieldIssue.nameTooLong,
      );
      expect(
        issueFromFieldError(e('password', 'password_too_common')),
        FieldIssue.passwordTooCommon,
      );
      expect(
        issueFromFieldError(e('password', 'password_matches_email')),
        FieldIssue.passwordMatchesEmail,
      );
      expect(
        issueFromFieldError(e('display_name', 'invalid_characters')),
        FieldIssue.nameInvalid,
      );
      expect(
        issueFromFieldError(e('display_name', 'display_name_link')),
        FieldIssue.nameHasLink,
      );
      expect(
        issueFromFieldError(e('display_name', 'display_name_reserved')),
        FieldIssue.nameReserved,
      );
      expect(
        issueFromFieldError(e('phone_e164', 'invalid_phone')),
        FieldIssue.invalidPhone,
      );
      expect(
        issueFromFieldError(e('timezone', 'invalid_timezone')),
        FieldIssue.invalidTimezone,
      );
      expect(
        issueFromFieldError(e('country_code', 'invalid_country_code')),
        FieldIssue.invalidCountry,
      );
      expect(
        issueFromFieldError(e('email', 'invalid_email')),
        FieldIssue.invalidEmail,
      );
      expect(
        issueFromFieldError(e('code', 'invalid_code_format')),
        FieldIssue.invalidCode,
      );
      expect(issueFromFieldError(e('email', 'required')), FieldIssue.required);
      expect(issueFromFieldError(e('x', 'something_new')), isNull);
    });

    test('issueForField finds the first known error for a field', () {
      final errors = [
        e('x', 'unknown'),
        e('password', 'too_short'),
        e('email', 'invalid_email'),
      ];
      expect(issueForField(errors, 'password'), FieldIssue.passwordTooShort);
      expect(issueForField(errors, 'email'), FieldIssue.invalidEmail);
      expect(issueForField(errors, 'x'), isNull);
      expect(issueForField(errors, 'missing'), isNull);
    });
  });

  test('every FieldIssue has a message', () {
    final AppLocalizations l10n = AppLocalizationsEn();
    for (final issue in FieldIssue.values) {
      final text = issueMessage(l10n, issue);
      expect(text, isNotEmpty, reason: '$issue');
      expect(text, isNot(contains('!')), reason: '$issue');
    }
  });
}
