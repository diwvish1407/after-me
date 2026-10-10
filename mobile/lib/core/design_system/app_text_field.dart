import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../l10n/gen/app_localizations.dart';

/// A labelled text field built on the theme's input decoration.
///
/// * The label is always visible (no placeholder-only fields).
/// * [errorText] is shown inline, under the field (USER_FLOWS.md §14).
/// * [obscureText] fields get a show/hide toggle with an accessible tooltip.
class AppTextField extends StatefulWidget {
  const AppTextField({
    required this.label,
    this.controller,
    this.hint,
    this.helperText,
    this.errorText,
    this.obscureText = false,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.focusNode,
    this.autofocus = false,
    this.readOnly = false,
    this.onTap,
    this.textCapitalization = TextCapitalization.none,
    this.suffixIcon,
    this.textAlign = TextAlign.start,
    this.enableIMEPersonalizedLearning = true,
    super.key,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helperText;
  final String? errorText;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int maxLines;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool readOnly;
  final VoidCallback? onTap;
  final TextCapitalization textCapitalization;

  /// Replaces nothing on password fields (they always get the show/hide toggle).
  final Widget? suffixIcon;
  final TextAlign textAlign;

  /// Whether the keyboard may learn from what is typed. Off for content that must not
  /// end up in a personal dictionary (instructions).
  final bool enableIMEPersonalizedLearning;

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscured = widget.obscureText;

  @override
  void didUpdateWidget(covariant AppTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText != widget.obscureText) {
      _obscured = widget.obscureText;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      readOnly: widget.readOnly,
      onTap: widget.onTap,
      textCapitalization: widget.textCapitalization,
      textAlign: widget.textAlign,
      enabled: widget.enabled,
      obscureText: _obscured,
      enableSuggestions: !widget.obscureText,
      enableIMEPersonalizedLearning: widget.enableIMEPersonalizedLearning,
      autocorrect: !widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      maxLines: widget.obscureText ? 1 : widget.maxLines,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        helperText: widget.helperText,
        errorText: widget.errorText,
        suffixIcon: widget.obscureText
            ? IconButton(
                tooltip: _obscured ? l10n.showPassword : l10n.hidePassword,
                icon: Icon(
                  _obscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: widget.enabled
                    ? () => setState(() => _obscured = !_obscured)
                    : null,
              )
            : widget.suffixIcon,
      ),
    );
  }
}
