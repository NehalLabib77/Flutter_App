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
/// paper-like tones so the two regions stay distinct. In dark mode the
/// canvas / paper / ink / hairline invert so the editorial chrome reads
/// on top of the dark Material scaffold without blinding the user.
class _AuthPalette {
  final Color canvas;
  final Color paper;
  final Color ink;
  final Color inkSoft;
  final Color hairline;
  final Color accent;
  final Color accentDeep;
  final Color danger;
  final Color bandLight;
  final Color bandMid;
  final Color bandDark;
  final Color shadow;

  const _AuthPalette({
    required this.canvas,
    required this.paper,
    required this.ink,
    required this.inkSoft,
    required this.hairline,
    required this.accent,
    required this.accentDeep,
    required this.danger,
    required this.bandLight,
    required this.bandMid,
    required this.bandDark,
    required this.shadow,
  });

  static const _AuthPalette light = _AuthPalette(
    canvas: AppColors.pageBg,
    paper: Color(0xFFFFFFFF),
    ink: AppColors.textPrimary,
    inkSoft: AppColors.textSecondary,
    hairline: AppColors.border,
    accent: AppColors.seed,
    accentDeep: AppColors.navyDeep,
    danger: AppColors.danger,
    bandLight: Color(0xFFF0F2FF),
    bandMid: Color(0xFFE4E8FF),
    bandDark: Color(0xFFF3F6FB),
    shadow: Color(0x123730A3),
  );

  static const _AuthPalette dark = _AuthPalette(
    canvas: AppColors.darkPage,
    paper: AppColors.darkCard,
    ink: AppColors.darkTextPrimary,
    inkSoft: AppColors.darkTextSecondary,
    hairline: AppColors.darkBorder,
    accent: AppColors.blueBright,
    accentDeep: Color(0xFFB4BAFF),
    danger: Color(0xFFFFB4AB),
    bandLight: Color(0xFF151C35),
    bandMid: Color(0xFF202751),
    bandDark: Color(0xFF11182E),
    shadow: Color(0x66000000),
  );

  /// Picks the palette for the active [Brightness]. Default to light
  /// when no context is available (e.g. in painters without BuildContext).
  factory _AuthPalette.of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
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

  const AuthScaffold({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final palette = _AuthPalette.of(context);

    return Scaffold(
      backgroundColor: palette.canvas,

      // Keep the auth card at its normal size when the keyboard opens.
      // Android should pan the window to the focused field instead of
      // asking Flutter to resize or scale the complete form.
      resizeToAvoidBottomInset: false,

      // Blue AppBar with a hairline so it does not bleed into the body.
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Container(
          decoration: BoxDecoration(
            color: palette.accent,
            border: Border(
              bottom: BorderSide(
                color: Colors.black.withValues(alpha: 0.18),
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
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

      // Remove only the keyboard inset from descendants. This prevents any
      // child widget from reacting to viewInsets.bottom and shrinking itself.
      body: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: true,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(painter: _DiagonalBandPainter(palette)),
              ),
              Positioned(
                right: -120,
                top: media.size.height * 0.42,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: Theme.of(context).brightness == Brightness.dark
                        ? 0.08
                        : 0.06,
                    child: CustomPaint(
                      size: const Size(360, 360),
                      painter: _BigCompassPainter(palette),
                    ),
                  ),
                ),
              ),
              SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compactWidth = constraints.maxWidth < 380;
                    final horizontal = compactWidth ? 14.0 : 20.0;
                    final vertical = compactWidth ? 10.0 : 16.0;
                    final availableWidth = math.max(
                      0.0,
                      constraints.maxWidth - (horizontal * 2),
                    );
                    final cardWidth = math.min(460.0, availableWidth);

                    return Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontal,
                        vertical: vertical,
                      ),
                      child: Center(
                        // Do not use FittedBox, Transform.scale, or any
                        // keyboard-dependent scale here. Those widgets caused
                        // the complete login/register card to squeeze while
                        // typing.
                        child: ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: cardWidth),
                          child: SizedBox(
                            width: double.infinity,
                            child: _PaperCard(palette: palette, child: child),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The white "page" with a 1px hairline border and a soft drop shadow.
/// We intentionally avoid [Card] so the radius + shadow don't match the
/// rest of the app.
class _PaperCard extends StatelessWidget {
  final _AuthPalette palette;
  final Widget child;
  const _PaperCard({required this.palette, required this.child});

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 380;
    return Container(
      decoration: BoxDecoration(
        color: palette.paper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.hairline),
        boxShadow: [
          BoxShadow(
            color: palette.shadow,
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 22,
        compact ? 16 : 20,
        compact ? 16 : 22,
        compact ? 16 : 20,
      ),
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
    final palette = _AuthPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 24, height: 2, color: palette.accent),
            const SizedBox(width: 8),
            Text(
              kicker.toUpperCase(),
              style: TextStyle(
                color: palette.accentDeep,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          title,
          style: TextStyle(
            color: palette.ink,
            fontSize: 25,
            fontWeight: FontWeight.w800,
            height: 1.08,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          body,
          style: TextStyle(
            color: palette.inkSoft,
            fontSize: 12.5,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        Container(height: 1, color: palette.hairline),
        const SizedBox(height: 10),
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
  final TextCapitalization textCapitalization;

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
    this.textCapitalization = TextCapitalization.none,
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
    final palette = _AuthPalette.of(context);
    final errorText = (widget.validator ?? _noValidator)(
      widget.controller.text,
    );
    final hasError = errorText != null;
    final showObscureToggle = widget.obscure;
    final underlineColor = hasError
        ? palette.danger
        : (_focused ? palette.accent : palette.hairline);
    final underlineWidth = (_focused || hasError) ? 2.0 : 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              widget.icon,
              size: 15,
              color: _focused ? palette.accentDeep : palette.inkSoft,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasError
                      ? palette.danger
                      : (_focused ? palette.accentDeep : palette.inkSoft),
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                  letterSpacing: 1.25,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (showObscureToggle)
              GestureDetector(
                onTap: () => setState(() => _showPassword = !_showPassword),
                child: Text(
                  _showPassword ? 'HIDE' : 'SHOW',
                  style: TextStyle(
                    color: _focused ? palette.accentDeep : palette.inkSoft,
                    fontWeight: FontWeight.w700,
                    fontSize: 10.5,
                    letterSpacing: 1.6,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 3),
        TextFormField(
          controller: widget.controller,
          focusNode: _focus,
          obscureText: widget.obscure && !_showPassword,
          keyboardType: widget.keyboardType,
          autofillHints: widget.autofillHints,
          inputFormatters: widget.formatters,
          validator: widget.validator,
          textInputAction: widget.textInputAction,
          textCapitalization: widget.textCapitalization,
          onFieldSubmitted: widget.onSubmitted,
          cursorColor: palette.accentDeep,
          cursorWidth: 1.4,
          style: TextStyle(
            color: palette.ink,
            fontSize: 14.5,
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
            contentPadding: EdgeInsets.symmetric(vertical: 3),
            errorStyle: TextStyle(height: 0),
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          margin: const EdgeInsets.only(top: 2),
          height: underlineWidth,
          color: underlineColor,
        ),
        const SizedBox(height: 3),
        // Reserve one line for helper/error text so validation messages do
        // not change the total height of the form while the user is typing.
        SizedBox(
          height: 14,
          child: Text(
            hasError ? errorText : (widget.helper ?? ''),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: hasError ? palette.danger : palette.inkSoft,
              fontSize: 10.5,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 8),
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
    final palette = _AuthPalette.of(context);
    final disabled = onPressed == null || busy;
    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled ? null : onPressed,
          borderRadius: BorderRadius.circular(14),
          splashColor: const Color(0x33FFFFFF),
          highlightColor: const Color(0x22FFFFFF),
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [palette.accent, palette.accentDeep],
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: palette.accentDeep.withValues(alpha: 0.35),
                  blurRadius: 14,
                  offset: const Offset(0, 8),
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
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.40),
                        borderRadius: const BorderRadius.only(
                          topLeft: Radius.circular(14),
                          bottomLeft: Radius.circular(14),
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
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.15,
                              fontSize: 14.5,
                            ),
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
    final palette = _AuthPalette.of(context);
    return Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(prefix, style: TextStyle(color: palette.inkSoft, fontSize: 12)),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: palette.accent, width: 1.4),
                ),
              ),
              child: Text(
                linkLabel,
                style: TextStyle(
                  color: palette.accentDeep,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
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
  final _AuthPalette palette;
  _BigCompassPainter(this.palette);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()
      ..color = palette.accentDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawCircle(c, r * 0.95, paint);
    canvas.drawCircle(c, r * 0.62, paint..strokeWidth = 1.0);
    final tickPaint = Paint()
      ..color = palette.accentDeep
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
  bool shouldRepaint(covariant _BigCompassPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

class _DiagonalBandPainter extends CustomPainter {
  final _AuthPalette palette;
  _DiagonalBandPainter(this.palette);

  @override
  void paint(Canvas canvas, Size size) {
    final paint1 = Paint()..color = palette.bandLight;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height * 0.55)
      ..lineTo(size.width * 0.55, 0)
      ..close();
    canvas.drawPath(path, paint1);

    final paint2 = Paint()..color = palette.bandMid;
    final path2 = Path()
      ..moveTo(size.width, size.height * 0.55)
      ..lineTo(size.width * 0.62, size.height * 0.55)
      ..lineTo(size.width, size.height * 0.18)
      ..close();
    canvas.drawPath(path2, paint2);

    final paint3 = Paint()..color = palette.bandDark;
    final path3 = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width * 0.45, size.height)
      ..lineTo(0, size.height * 0.6)
      ..close();
    canvas.drawPath(path3, paint3);
  }

  @override
  bool shouldRepaint(covariant _DiagonalBandPainter oldDelegate) =>
      oldDelegate.palette != palette;
}
