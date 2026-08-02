/// Reusable labelled text field used across all auth forms.
///
/// Wraps a `TextFormField` with:
///   * a Material-style floating label,
///   * a leading icon for context,
///   * an optional suffix password-visibility toggle.
library;

import 'package:flutter/material.dart';

class CustomTextField extends StatefulWidget {
  final TextEditingController controller;

  /// Field label rendered in the floating-label slot.
  final String label;

  /// Leading icon. Provide any Material `IconData`.
  final IconData prefixIcon;

  /// Whether to obscure the input. A tap-to-toggle eye icon is appended.
  final bool obscureText;

  /// Visible hint when the field is empty and unfocused.
  final String? hint;

  /// Kept in sync with the form validator from the parent `Form`.
  final String? Function(String?)? validator;

  /// Auto-fill hints (e.g. `AutofillHints.email`).
  final List<String>? autofillHints;

  /// `TextInputType` — email, text, etc.
  final TextInputType? keyboardType;

  /// Default is `TextInputAction.next`; pass `done` on the last field.
  final TextInputAction? textInputAction;

  /// Called when the user submits via the keyboard.
  final ValueChanged<String>? onFieldSubmitted;

  /// Disables the field (and the password toggle).
  final bool enabled;

  const CustomTextField({
    super.key,
    required this.controller,
    required this.label,
    required this.prefixIcon,
    this.obscureText = false,
    this.hint,
    this.validator,
    this.autofillHints,
    this.keyboardType,
    this.textInputAction,
    this.onFieldSubmitted,
    this.enabled = true,
  });

  @override
  State<CustomTextField> createState() => _CustomTextFieldState();
}

class _CustomTextFieldState extends State<CustomTextField> {
  late bool _obscured;

  @override
  void initState() {
    super.initState();
    _obscured = widget.obscureText;
  }

  @override
  void didUpdateWidget(covariant CustomTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.obscureText != widget.obscureText) {
      _obscured = widget.obscureText;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      enabled: widget.enabled,
      obscureText: _obscured,
      autofillHints: widget.autofillHints,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onFieldSubmitted,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: Icon(widget.prefixIcon),
        suffixIcon: widget.obscureText
            ? IconButton(
                tooltip: _obscured ? 'Show password' : 'Hide password',
                onPressed: widget.enabled
                    ? () => setState(() => _obscured = !_obscured)
                    : null,
                icon: Icon(
                  _obscured
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
              )
            : null,
      ),
    );
  }
}
