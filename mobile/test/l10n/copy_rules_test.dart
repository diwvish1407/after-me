import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The wording rules of USER_FLOWS.md §15 as a test, for every string in the app
/// (`lib/l10n/app_en.arb`). The backend has the same test for emails, web pages and push
/// copy (`backend/tests/unit/test_copy_rules.py`); this is the phone's half.
///
/// A machine can check three things: no vocabulary the product promised never to use, no
/// exclamation marks, and no shouting (ALL CAPS) except the two buttons that are named
/// that way. Whether a sentence is *kind* still takes a person (the manual copy review).

/// USER_FLOWS §15, "Avoid" column. Word boundaries, case-insensitive.
final _forbidden = RegExp(
  r'\b('
  r'death|dead|die|died|dies|dying|deceased|passed away|pass away|late husband|late wife|'
  r'beneficiar\w*|heirs?|next of kin|'
  r'countdown|ticking|time is running out|'
  r'unlock (?:the )?secrets?|reveal\w*|'
  r'triggers?|triggered|payload|'
  r'urgent|immediately|hurry|act now|danger(?:ous)?'
  r')\b',
  caseSensitive: false,
);

/// Phrases that may contain a forbidden word because the product must say them, with the
/// reason. Every entry must still occur in the strings (a stale allowance fails).
const _allowedPhrases = <String, String>{
  'in danger':
      'The emergency line every alert carries: "If you believe someone is in danger, '
      'contact your local emergency services." It is the only place the word appears.',
};

/// Purchase vocabulary (PRD D5, decided 2026-10-15: no Play Billing in 1.0; Premium is
/// only granted by an operator). Nothing may offer a purchase, name a price or point to a
/// payment: with no billing it would be a dead end, and a link to pay outside Google Play
/// is against Play's payments policy. Word boundaries, case-insensitive; currency signs
/// anywhere.
final _purchase = RegExp(
  r'\b('
  r'buy|buying|bought|purchase\w*|subscribe\w*|subscriptions?|'
  r'price\w*|pricing|upgrade\w*|checkout|pay now|payment\w*|'
  r'per month|per year|free trial'
  r')\b'
  r'|[₹$€£]',
  caseSensitive: false,
);

/// Keys whose value may contain purchase vocabulary, with the reason. Every entry must
/// still match (a stale allowance fails).
const _purchaseAllowed = <String, String>{
  'starterHomeBillsBody':
      "An instruction starter about the person's own household bills "
      '("Subscriptions to cancel or keep"): their streaming or utility '
      "subscriptions, not AfterMe's.",
  'starterDigitalSocialTitle':
      "An instruction starter title about the person's own online accounts "
      '("Social media and subscriptions").',
  'starterDigitalMoneyTitle':
      "An instruction starter title about the person's own online banking "
      '("Online banking and payments").',
  'starterDigitalMoneyBody':
      "An instruction starter about the person's own payment apps.",
  'starterDigitalSocialBody':
      "An instruction starter about the person's own subscriptions to cancel.",
};

/// The only key whose value may say "Premium": the tier's name, shown to an account an
/// operator made Premium (Settings > Your plan). A free account is never told about a
/// Premium it cannot get.
const _premiumAllowed = <String>{'yourPlanTierPremium'};

/// Keys whose value may contain an exclamation mark, with the reason. None today: the
/// product never raises its voice.
const _exclamationAllowed = <String, String>{};

/// All-caps words that are allowed: the two buttons, written the way the product names
/// them (USER_FLOWS §4, §7), and the abbreviations a person meets elsewhere.
const _capsAllowed = <String>{
  "I'M OK",
  "I'M SAFE",
  'OK',
  // The word the person types to confirm deleting the account: it is an instruction
  // about what to type exactly, not a raised voice.
  'DELETE',
  'PIN',
  // Abbreviations (not shouting): file formats, protocols and standards.
  'AM',
  'PM',
  'PDF',
  'JSON',
  'SMS',
  'URL',
  'ID',
  'FAQ',
  'UTC',
  'GMT',
  'IANA',
  'SOS',
  'USB',
  'NFC',
  'FCM',
};

Map<String, String> _strings() {
  final raw = jsonDecode(
    File('lib/l10n/app_en.arb').readAsStringSync(),
  ) as Map<String, Object?>;
  return {
    for (final entry in raw.entries)
      if (!entry.key.startsWith('@') && entry.value is String)
        entry.key: entry.value! as String,
  };
}

/// The words a reader sees: the placeholders are not copy.
String _plain(String message) =>
    message.replaceAll(RegExp(r'\{[A-Za-z_]+\}'), 'X');

String _scrub(String text) {
  var out = text;
  for (final phrase in _allowedPhrases.keys) {
    out = out.replaceAll(phrase, '');
  }
  return out;
}

/// Words of three letters or more that are all capitals, after removing the allowed ones.
List<String> _shouting(String text) {
  var rest = text;
  for (final phrase in _capsAllowed.where(
    (p) => p.contains(' ') || p.contains("'"),
  )) {
    rest = rest.replaceAll(phrase, '');
  }
  return [
    for (final m in RegExp(r"[A-Z][A-Z']{2,}").allMatches(rest))
      if (!_capsAllowed.contains(m.group(0))) m.group(0)!,
  ];
}

void main() {
  final strings = _strings();

  test('the scan reads the whole file', () {
    expect(strings.length, greaterThan(1000));
    expect(strings['appName'], 'AfterMe');
  });

  test('no vocabulary the product promised never to use', () {
    final found = <String>[];
    strings.forEach((key, value) {
      final match = _forbidden.firstMatch(_scrub(_plain(value)));
      if (match != null) {
        found.add('$key: "${match.group(0)}" in "$value"');
      }
    });
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('every allowed phrase still occurs (no stale allowance)', () {
    for (final phrase in _allowedPhrases.keys) {
      expect(
        strings.values.any((v) => v.contains(phrase)),
        isTrue,
        reason: '"$phrase" is allowed but no string has it any more',
      );
    }
  });

  test('nothing offers a purchase, names a price or asks for a payment '
      '(PRD D5: no billing in 1.0)', () {
    final found = <String>[];
    strings.forEach((key, value) {
      final match = _purchase.firstMatch(_plain(value));
      if (match != null && !_purchaseAllowed.containsKey(key)) {
        found.add('$key: "${match.group(0)}" in "$value"');
      }
    });
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test(
    'every purchase-vocabulary allowance still applies (no stale entry)',
    () {
      for (final key in _purchaseAllowed.keys) {
        expect(strings, contains(key), reason: '$key is allowed but gone');
        expect(
          _purchase.hasMatch(_plain(strings[key]!)),
          isTrue,
          reason: '$key is allowed but no longer needs it',
        );
      }
    },
  );

  test('"Premium" is only the tier name, never an offer', () {
    final found = [
      for (final entry in strings.entries)
        if (RegExp(
              r'\bpremium\b',
              caseSensitive: false,
            ).hasMatch(entry.value) &&
            !_premiumAllowed.contains(entry.key))
          '${entry.key}: "${entry.value}"',
    ];
    expect(found, isEmpty, reason: found.join('\n'));
    expect(strings['yourPlanTierPremium'], 'Premium');
  });

  test('the purchase scan catches what it is for', () {
    for (final sample in [
      'Upgrade to Premium',
      'Buy more contacts',
      'Subscribe now',
      'Only ₹99',
      r'From $4.99',
      'See the price',
      'Purchase more stages',
    ]) {
      expect(_purchase.hasMatch(sample), isTrue, reason: sample);
    }
    expect(_purchase.hasMatch("More stages aren't available yet."), isFalse);
  });

  test('no exclamation marks', () {
    final found = <String>[];
    strings.forEach((key, value) {
      if (value.contains('!') && !_exclamationAllowed.containsKey(key)) {
        found.add('$key: "$value"');
      }
    });
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test(
    'no shouting: ALL CAPS only for I\'M OK and I\'M SAFE (and abbreviations)',
    () {
      final found = <String>[];
      strings.forEach((key, value) {
        final words = _shouting(_plain(value));
        if (words.isNotEmpty) {
          found.add('$key: $words in "$value"');
        }
      });
      expect(found, isEmpty, reason: found.join('\n'));
    },
  );

  test('the two named buttons are spelled the way the product names them', () {
    final values = strings.values.join('\n');
    expect(values, contains("I'M OK"));
    expect(values, contains("I'M SAFE"));
    expect(values, isNot(contains("I'm OK")));
    expect(values, isNot(contains("I'm SAFE")));
  });
}
