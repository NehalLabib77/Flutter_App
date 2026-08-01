/// Shared visual chrome for the sign-in / create-account screens.
///
// This file is the single source of truth for the auth flow's look —
// every widget here is bespoke (no `InputDecoration.outlineBorder` /
// `FilledButton` / `TextFormField`-with-floating-label) so the screens
// read as a distinct editorial style instead of the default Material
// scaffolded forms.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Palette anchors. AppBar uses [AppColors.seed]; the body uses muted,
/// paper-like tones so the two regions stay distinct.
class _AuthPalette {
  static const Color canvas = Color(0xFFF3F5FA);
  static const Color paper = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF0E1B33);
  static const Color inkSoft = Color(0xFF4F5B73);
  static const Color hairline = Color(0xFFE2E7F1);
  static const Color accent = AppColors.seed;
  static const Color accentDeep = Color(0xFF155CC1);
  static const Color danger = Color(0xFFB3261E);
}

/// Wraps the screen in the AppBar + body styling used by every auth page.
///
/// The AppBar is blue [AppColors.seed] with a compact custom glyph in the
/// leading position (so it doesn't look like the default ← back-button).
/// The body is a full-bleed [Stack]: a soft diagonal band painted in muted
/// blue, an oversized compass mark in the top-right corner, and the
/// page-specific content pinned to the right-half with asymmetric padding.
class AuthScaffold extends StatelessWidget {
  final String title;
  final Widget child;

  const AuthScaffold({
    super.key,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Scaffold(
      backgroundColor: _AuthPalette.canvas,
      // Blue AppBar with a hairline so it doesn't bleed into the body.
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Container(
          decoration: const BoxDecoration(
            color: _AuthPalette.accent,
            border: Border(
              bottom: BorderSide(
                color: Color(0x9915305A),
                width: 1,
              ),
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                const SizedBox(width: 16),
                const _CompassMark(size: 30, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'EduCompass',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        title,
                        style: const TextStyle(
                          color: Color(0xCCE6F0FF),
                          fontWeight: FontWeight.w400,
                          letterSpacing: 0.2,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          // Diagonal band that runs from top-right to bottom-left.
          Positioned.fill(
            child: CustomPaint(painter: _DiagonalBandPainter()),
          ),
          // Background compass mark — oversized and very faint.
          Positioned(
            right: -120,
            top: media.size.height * 0.42,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.06,
                child: CustomPaint(
                  size: const Size(360, 360),
                  painter: _BigCompassPainter(),
                ),
              ),
            ),
          ),
          // Scrollable content, right-justified card on wide screens.
          SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: EdgeInsets.fromLTRB(
                    24,
                    28,
                    24,
                    28 + MediaQuery.viewInsetsOf(context).bottom,
                  ),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: _PaperCard(child: child),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The white "page" with a 1px hairline border and a soft drop shadow.
/// We intentionally avoid [Card] so the radius + shadow don't match the
/// rest of the app.
class _PaperCard extends StatelessWidget {
  final Widget child;
  const _PaperCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _AuthPalette.paper,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(22),
          topRight: Radius.circular(22),
          bottomLeft: Radius.circular(6),
          bottomRight: Radius.circular(22),
        ),
        border: Border.all(color: _AuthPalette.hairline),
        boxShadow: const [
          BoxShadow(
            color: Color(0x141B3F8C),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
      child: child,
    );
  }
}

/// Section header at the top of an auth card. Editorial-style title with a
/// thin divider rule below it.
class AuthHeading extends StatelessWidget {
  final String kicker;
  final String title;
  final String body;

  const AuthHeading({
    super.key,
    required this.kicker,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 28,
              height: 2,
              color: _AuthPalette.accent,
            ),
            const SizedBox(width: 10),
            Text(
              kicker.toUpperCase(),
              style: const TextStyle(
                color: _AuthPalette.accentDeep,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(
            color: _AuthPalette.ink,
            fontSize: 28,
            fontWeight: FontWeight.w700,
            height: 1.1,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          body,
          style: const TextStyle(
            color: _AuthPalette.inkSoft,
            fontSize: 13.5,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 22),
        Container(height: 1, color: _AuthPalette.hairline),
      ],
    );
  }
}

/// Hairline-underlined text field. No Material outline / filled variant —
/// we draw our own underline + label-row.
class InsetField extends StatefulWidget {
  final String label;
  final String? helper;
  final IconData icon;
  final bool obscure;
  final TextInputType keyboardType;
  final TextEditingController controller;
  final String? Function(String?)? validator;
  final List<TextInputFormatter>? formatters;
  final void Function(String)? onSubmitted;
  final TextInputAction textInputAction;
  final List<String> autofillHints;

  const InsetField({
    super.key,
    required this.label,
    required this.controller,
    required this.icon,
    this.helper,
    this.obscure = false,
    this.keyboardType = TextInputType.text,
    this.validator,
    this.formatters,
    this.onSubmitted,
    this.textInputAction = TextInputAction.next,
    this.autofillHints = const <String>[],
  });

  @override
  State<InsetField> createState() => _InsetFieldState();
}

class _InsetFieldState extends State<InsetField> {
  final _focus = FocusNode();
  bool _focused = false;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorText = (widget.validator ?? _noValidator)(
      widget.controller.text,
    );
    final hasError = errorText != null;
    final showObscureToggle = widget.obscure;
    final underlineColor = hasError
        ? _AuthPalette.danger
        : (_focused ? _AuthPalette.accent : _AuthPalette.hairline);
    final underlineWidth = (_focused || hasError) ? 2.0 : 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              widget.icon,
              size: 16,
              color: _focused
                  ? _AuthPalette.accentDeep
                  : _AuthPalette.inkSoft,
            ),
            const SizedBox(width: 8),
            Text(
              widget.label.toUpperCase(),
              style: TextStyle(
                color: hasError
                    ? _AuthPalette.danger
                    : (_focused
                        ? _AuthPalette.accentDeep
                        : _AuthPalette.inkSoft),
                fontWeight: FontWeight.w600,
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            ),
            const Spacer(),
            if (showObscureToggle)
              GestureDetector(
                onTap: () => setState(() => _showPassword = !_showPassword),
                child: Text(
                  _showPassword ? 'HIDE' : 'SHOW',
                  style: TextStyle(
                    color: _focused
                        ? _AuthPalette.accentDeep
                        : _AuthPalette.inkSoft,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: widget.controller,
          focusNode: _focus,
          obscureText: widget.obscure && !_showPassword,
          keyboardType: widget.keyboardType,
          autofillHints: widget.autofillHints,
          inputFormatters: widget.formatters,
          validator: widget.validator,
          textInputAction: widget.textInputAction,
          onFieldSubmitted: widget.onSubmitted,
          cursorColor: _AuthPalette.accentDeep,
          cursorWidth: 1.4,
          style: const TextStyle(
            color: _AuthPalette.ink,
            fontSize: 16,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.1,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            focusedBorder: InputBorder.none,
            enabledBorder: InputBorder.none,
            errorBorder: InputBorder.none,
            focusedErrorBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 6),
            errorStyle: TextStyle(height: 0),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.only(top: 4),
          height: underlineWidth,
          color: underlineColor,
        ),
        const SizedBox(height: 6),
        Text(
          hasError ? errorText : (widget.helper ?? ''),
          style: TextStyle(
            color: hasError
                ? _AuthPalette.danger
                : _AuthPalette.inkSoft,
            fontSize: 11.5,
            height: 1.3,
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  static String? _noValidator(String? _) => null;
}

/// Hand-drawn-style primary action button.
///
/// [FilledButton] would have given us a Material pill. Instead we use a
/// [Stack] with a 4-px leading accent strip in white at 40% so the button
/// reads as a distinct CTA.
class AuthPrimaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool busy;
  final VoidCallback? onPressed;

  const AuthPrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.busy,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || busy;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onPressed,
          borderRadius: BorderRadius.circular(10),
          splashColor: const Color(0x33FFFFFF),
          highlightColor: const Color(0x22FFFFFF),
          child: Ink(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _AuthPalette.accent,
                  _AuthPalette.accentDeep,
                ],
              ),
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x331F6FEB),
                  blurRadius: 14,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 4,
                      decoration: const BoxDecoration(
                        color: Color(0x66FFFFFF),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(10),
                          bottomLeft: Radius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  if (busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  else
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: Colors.white, size: 18),
                        const SizedBox(width: 10),
                        Text(
                          label.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Footnote-style link ("Already have an account?") rendered as plain text
/// rather than a Material [TextButton] — matches the editorial tone.
class AuthFootnoteLink extends StatelessWidget {
  final String prefix;
  final String linkLabel;
  final VoidCallback onTap;

  const AuthFootnoteLink({
    super.key,
    required this.prefix,
    required this.linkLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            prefix,
            style: const TextStyle(
              color: _AuthPalette.inkSoft,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: _AuthPalette.accent,
                    width: 1.4,
                  ),
                ),
              ),
              child: Text(
                linkLabel,
                style: const TextStyle(
                  color: _AuthPalette.accentDeep,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compass-rose glyph used in the AppBar leading position.
class _CompassMark extends StatelessWidget {
  final double size;
  final Color color;
  const _CompassMark({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _CompassPainter(color: color)),
    );
  }
}

class _CompassPainter extends CustomPainter {
  final Color color;
  _CompassPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final outline = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(c, r * 0.92, outline);
    canvas.drawLine(
      Offset(c.dx - r * 0.85, c.dy),
      Offset(c.dx + r * 0.85, c.dy),
      outline,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy - r * 0.85),
      Offset(c.dx, c.dy + r * 0.85),
      outline,
    );
    final north = Path()
      ..moveTo(c.dx, c.dy - r * 0.9)
      ..lineTo(c.dx + r * 0.25, c.dy)
      ..lineTo(c.dx - r * 0.25, c.dy)
      ..close();
    canvas.drawPath(north, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Huge background compass used as a watermark — same geometry, just larger
/// and rendered very faint.
class _BigCompassPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..color = _AuthPalette.accentDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawCircle(c, r * 0.95, paint);
    canvas.drawCircle(c, r * 0.62, paint..strokeWidth = 1.0);
    final tickPaint = Paint()
      ..color = _AuthPalette.accentDeep
      ..strokeWidth = 1.2;
    const twoPi = 6.283185307179586;
    for (var i = 0; i < 24; i++) {
      final a = (i / 24) * twoPi;
      final outer = Offset(
        c.dx + r * 0.95 * math.cos(a),
        c.dy + r * 0.95 * math.sin(a),
      );
      final inner = Offset(
        c.dx + r * 0.86 * math.cos(a),
        c.dy + r * 0.86 * math.sin(a),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }
    canvas.drawLine(
      Offset(c.dx - r * 0.85, c.dy),
      Offset(c.dx + r * 0.85, c.dy),
      paint,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy - r * 0.85),
      Offset(c.dx, c.dy + r * 0.85),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _DiagonalBandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()..color = const Color(0xFFEBF1FB);
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.55)
      ..lineTo(size.width * 0.55, 0)
      ..close();
    canvas.drawPath(path, paint1);

    final paint2 = Paint()..color = const Color(0xFFDDE7F7);
    final path2 = Path()
      ..moveTo(size.width, size.height * 0.55)
      ..lineTo(size.width * 0.62, size.height * 0.55)
      ..lineTo(size.width, size.height * 0.18)
      ..close();
    canvas.drawPath(path2, paint2);

    final paint3 = Paint()..color = const Color(0xFFEAF0F9);
    final path3 = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width * 0.45, size.height)
      ..lineTo(0, size.height * 0.6)
      ..close();
    canvas.drawPath(path3, paint3);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
