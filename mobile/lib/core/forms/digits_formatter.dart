import 'package:flutter/services.dart';

import 'validators.dart';

/// A formatter that keeps only digits and at most [length] of them, so a pasted
/// "482 913" or "482-913" becomes "482913".
class DigitsOnlyFormatter extends TextInputFormatter {
  const DigitsOnlyFormatter({this.length = 6});

  final int length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = Validators.normalizeCode(newValue.text);
    final clipped = digits.length > length
        ? digits.substring(0, length)
        : digits;
    if (clipped == newValue.text) {
      return newValue;
    }
    return TextEditingValue(
      text: clipped,
      selection: TextSelection.collapsed(offset: clipped.length),
    );
  }
}
