import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Words and signs that would offer, price or ask for a purchase. There is no billing in
/// 1.0 (PRD D5) and Play's payments policy forbids pointing to a payment outside Google
/// Play, so none of them may be on a screen about the plan or its limits.
final RegExp purchaseLanguage = RegExp(
  r'\b(upgrade|buy|buying|purchase\w*|subscribe\w*|subscription\w*|price\w*|'
  r'pricing|pay|payment\w*|checkout|per month|per year|premium)\b|[₹$€£]',
  caseSensitive: false,
);

Finder _texts(Finder? within) => within == null
    ? find.byType(Text)
    : find.descendant(of: within, matching: find.byType(Text));

/// Every text on screen (or inside [within]), plain and rich.
List<String> visibleTexts({Finder? within}) => [
  for (final element in _texts(within).evaluate())
    if (element.widget case final Text text)
      text.data ?? text.textSpan?.toPlainText() ?? '',
];

/// Fails when anything on screen (or inside [within], e.g. a sheet) offers, prices or
/// asks for a purchase, or when it has a labelled button whose label is not in
/// [allowedButtons]: a limit is explained, never sold.
void expectNoPurchaseOffer({
  Finder? within,
  Set<String> allowedButtons = const {},
}) {
  final offending = [
    for (final text in visibleTexts(within: within))
      if (purchaseLanguage.hasMatch(text)) text,
  ];
  expect(offending, isEmpty, reason: 'purchase language on screen');
  final buttons = within == null
      ? find.bySubtype<ButtonStyleButton>()
      : find.descendant(
          of: within,
          matching: find.bySubtype<ButtonStyleButton>(),
        );
  for (final element in buttons.evaluate()) {
    final labels = [
      for (final e
          in find
              .descendant(
                of: find.byWidget(element.widget),
                matching: find.byType(Text),
              )
              .evaluate())
        (e.widget as Text).data ?? '',
    ];
    if (labels.isEmpty) {
      // An icon-only button (the app bar's Back): its words are checked above, if any.
      continue;
    }
    expect(
      labels.any(allowedButtons.contains),
      isTrue,
      reason: 'unexpected button: $labels',
    );
  }
}
