/// Shared design primitives used across the app.
///
/// This file is intentionally additive — it does not change any existing
/// screen, it just gives new screens a coherent vocabulary for spacing,
/// radii, durations, and small visual widgets so the UI stops drifting
/// from screen to screen.
///
/// Conventions:
///
/// * Spacing follows the 4dp grid: 4 / 8 / 12 / 16 / 24 / 32.
/// * Radii stay between 8dp (pill chips) and 20dp (cards).
/// * Motion is short (≤ 240ms) to keep the app feeling responsive on
///   mid-range Android devices; longer fades are reserved for hero
///   transitions.
/// * All colours come from the active [ColorScheme] so light, dark and
///   AMOLED themes stay consistent.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

// ---------------------------------------------------------------------------
// Layout primitives — re-export the canonical tokens from [AppSpacing] /
// [AppRadii] so existing call-sites continue to work after the rename.
// ---------------------------------------------------------------------------

/// Standard spacing scale (in logical pixels). Prefer these constants
/// over hand-picked numeric padding/margin values so the rhythm stays
/// uniform across screens.
class Spacing {
  const Spacing._();

  /// 4dp — icon-to-label gaps, pill internal padding.
  static const double xs = AppSpacing.xs;

  /// 8dp — chip spacing, dense stack gaps.
  static const double sm = AppSpacing.sm;

  /// 12dp — small section gaps, button-to-button spacing.
  static const double md = AppSpacing.md;

  /// 16dp — card internal padding, list-row gaps.
  static const double lg = AppSpacing.lg;

  /// 24dp — section-to-section breathing room.
  static const double xl = AppSpacing.xl;

  /// 32dp — page-level top/bottom margins.
  static const double xxl = AppSpacing.xxl;
}

/// Corner-radius scale used throughout the app.
class Radii {
  const Radii._();

  /// 8dp — pills, dense chips.
  static const double sm = AppRadii.sm;

  /// 12dp — small cards, list tiles.
  static const double md = AppRadii.md;

  /// 16dp — hero blocks, feature cards, standard card surface.
  static const double lg = AppRadii.lg;

  /// 20dp — full-width modal sheets, hero cards with an image header.
  static const double xl = AppRadii.xl;

  /// Fully-rounded — buttons, pills.
  static const BorderRadius pill = AppRadii.pillRadius;
}

/// Animation durations. Kept short to feel responsive on slow devices.
class EduDurations {
  const EduDurations._();

  /// 120ms — colour / size crossfades, hover states.
  static const Duration fast = Duration(milliseconds: 120);

  /// 200ms — standard widget transitions (cards sliding in, sheet snaps).
  static const Duration medium = Duration(milliseconds: 200);

  /// 320ms — long-form transitions (hero, route push, page-level reveals).
  static const Duration slow = Duration(milliseconds: 320);
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------

/// Soft-edged container that picks up the active colour scheme and stays
/// legible on light, dark and AMOLED themes.
///
/// Use this instead of raw `Card` for any new screen so cards share the
/// same shadow / radius / surface tone without per-screen tweaking.
class EduCard extends StatelessWidget {
  const EduCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.borderRadius = const BorderRadius.all(Radius.circular(Radii.xl)),
    this.color,
    this.onTap,
    this.elevation = 0,
    this.border = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? color;
  final VoidCallback? onTap;
  final double elevation;

  /// Draw a subtle outline (useful on AMOLED where shadows vanish).
  final bool border;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bg = color ?? scheme.surfaceContainerHigh;
    final showBorder = border || isDark;
    final shape = RoundedRectangleBorder(
      borderRadius: borderRadius,
      side: showBorder
          ? BorderSide(
              color: scheme.outlineVariant.withValues(
                alpha: isDark ? 0.72 : 0.52,
              ),
              width: 1,
            )
          : BorderSide.none,
    );
    final card = Card(
      elevation: elevation,
      color: bg,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.black.withValues(alpha: isDark ? 0.22 : 0.08),
      shape: shape,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        splashColor: scheme.primary.withValues(alpha: 0.10),
        highlightColor: scheme.primary.withValues(alpha: 0.05),
        child: card,
      ),
    );
  }
}

/// A small uppercase-or-titled label that sits above a section's body.
/// Renders a leading icon (when given) and a trailing widget slot for
/// action links (e.g. "View all").
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.onTrailingTap,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;

  /// Tap handler for the [trailing] widget. When provided, the trailing
  /// becomes an InkWell-able pill so callers can wire "see all" links
  /// or quick actions without rebuilding the row.
  final VoidCallback? onTrailingTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget? trailingWidget = trailing;
    if (trailingWidget != null && onTrailingTap != null) {
      trailingWidget = Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          onTap: onTrailingTap,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.xs),
            child: trailingWidget,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: Spacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          ?trailingWidget,
        ],
      ),
    );
  }
}

/// A small icon-on-circle affordance used to anchor badges, step
/// indicators, and inline profile avatars. Renders an [Icon] inside a
/// filled circle tinted from the active scheme so the visual weight is
/// consistent across screens.
class IconBadge extends StatelessWidget {
  const IconBadge({
    super.key,
    required this.icon,
    this.size = 36,
    this.iconSize,
    this.background,
    this.foreground,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background ?? scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        icon,
        size: iconSize ?? (size * 0.5),
        color: foreground ?? scheme.onPrimaryContainer,
      ),
    );
  }
}

/// Full-bleed header card used at the top of screens like Home,
/// Recommendations, and the empty path detail. Renders an optional
/// eyebrow text, a large title, an optional subtitle, and a trailing
/// widget slot for an avatar / icon / CTA.
///
/// The card uses a subtle gradient from `primaryContainer` to
/// `surface` so it always reads as a "welcome" surface without
/// needing an image asset.
class HeroBanner extends StatelessWidget {
  const HeroBanner({
    super.key,
    required this.title,
    this.subtitle,
    this.eyebrow,
    this.icon,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.lg),
  });

  final String title;
  final String? subtitle;
  final String? eyebrow;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: const BorderRadius.all(Radius.circular(Radii.xl)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.all(Radius.circular(Radii.xl)),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primaryContainer,
                Color.lerp(scheme.primaryContainer, scheme.surface, 0.55) ??
                    scheme.surface,
              ],
            ),
          ),
          child: Padding(
            padding: padding,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  IconBadge(
                    icon: icon!,
                    background: scheme.primary,
                    foreground: scheme.onPrimary,
                  ),
                  const SizedBox(width: Spacing.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (eyebrow != null) ...[
                        Text(
                          eyebrow!.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer.withValues(
                              alpha: 0.75,
                            ),
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.6,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                      ],
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: scheme.onPrimaryContainer,
                          height: 1.15,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: Spacing.xs),
                        Text(
                          subtitle!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onPrimaryContainer.withValues(
                              alpha: 0.85,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded search field with leading icon, optional clear button, and
/// an optional busy spinner. Used by the Recommendations "tell us your
/// goal" input and anywhere we need a clean Material 3 search affordance.
///
/// Named `EduSearchBar` (rather than `SearchBar`) to avoid a name clash
/// with the Material `SearchBar` widget (which renders a search anchor).
class EduSearchBar extends StatelessWidget {
  const EduSearchBar({
    super.key,
    required this.controller,
    this.hint,
    this.leading = Icons.search_rounded,
    this.busy = false,
    this.onChanged,
    this.onSubmitted,
    this.onClear,
    this.enabled = true,
    this.textInputAction = TextInputAction.search,
    this.minLines = 1,
    this.maxLines = 1,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String? hint;
  final IconData leading;
  final bool busy;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onClear;
  final bool enabled;
  final TextInputAction textInputAction;
  final int minLines;
  final int maxLines;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      minLines: minLines,
      maxLines: maxLines,
      autofocus: autofocus,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(leading, color: scheme.primary),
        suffixIcon: busy
            ? Padding(
                padding: const EdgeInsets.all(Spacing.md),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
              )
            : (controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: enabled
                          ? () {
                              controller.clear();
                              if (onClear != null) onClear!();
                              if (onChanged != null) onChanged!('');
                            }
                          : null,
                    )),
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          borderSide: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.85),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
    );
  }
}

/// Standard horizontal course row used by Home, Recommendations,
/// Favorites, and Learning Paths. Renders a thumbnail + 2-line title +
/// provider + skills chips + optional trailing widget (e.g. score).
///
/// All fields are optional except [title] and [onTap] — the card adapts
/// to whatever data is available.
class CourseRowCard extends StatelessWidget {
  const CourseRowCard({
    super.key,
    required this.title,
    this.thumbnail,
    this.provider,
    this.level,
    this.subject,
    this.skills = const [],
    this.rating,
    this.score,
    this.reason,
    this.isFree = false,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.all(Spacing.md),
  });

  /// Widget rendered on the leading edge. Typically a [CourseThumbnail].
  final Widget? thumbnail;
  final String title;
  final String? provider;
  final String? level;
  final String? subject;
  final List<String> skills;
  final double? rating;
  final double? score;
  final String? reason;
  final bool isFree;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final metaParts = <String>[
      if (provider != null && provider!.isNotEmpty) provider!,
      if (level != null && level!.isNotEmpty) level!,
      if (subject != null && subject!.isNotEmpty) subject!,
    ];
    return EduCard(
      onTap: onTap,
      padding: padding,
      border: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (thumbnail != null) ...[
            thumbnail!,
            const SizedBox(width: Spacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          height: 1.22,
                        ),
                      ),
                    ),
                    if (isFree) ...[
                      const SizedBox(width: Spacing.sm),
                      Pill(text: 'FREE', color: Colors.green.shade600),
                    ],
                  ],
                ),
                if (reason != null && reason!.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    reason!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.primary,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
                if (metaParts.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    metaParts.join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                if (skills.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: [
                      for (final s in skills.take(2))
                        Pill(text: s, dense: true),
                    ],
                  ),
                ],
                if (rating != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Row(
                    children: [
                      Icon(
                        Icons.star_rounded,
                        size: 14,
                        color: Colors.amber.shade700,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        rating!.toStringAsFixed(1),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: Spacing.sm),
            trailing!,
          ] else if (score != null) ...[
            const SizedBox(width: Spacing.sm),
            Text(
              '${(score! * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Compact profile header used at the top of the Profile screen. Shows
/// the user's initial inside an avatar, full name, email, and an
/// interests row (up to 4 chips).
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({
    super.key,
    required this.fullName,
    required this.email,
    this.interests = const [],
    this.busy = false,
    this.onEdit,
  });

  final String fullName;
  final String email;
  final List<String> interests;
  final bool busy;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final initial = fullName.trim().isNotEmpty
        ? fullName.trim()[0].toUpperCase()
        : '?';
    return EduCard(
      padding: const EdgeInsets.all(Spacing.lg),
      border: true,
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    initial,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fullName,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (interests.isNotEmpty) ...[
                  const SizedBox(height: Spacing.sm),
                  Wrap(
                    spacing: Spacing.xs,
                    runSpacing: Spacing.xs,
                    children: [
                      for (final i in interests.take(4))
                        Pill(text: i, dense: true),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              tooltip: 'Edit name',
              icon: const Icon(Icons.edit_outlined),
              onPressed: busy ? null : onEdit,
            ),
        ],
      ),
    );
  }
}

/// Inline placeholder shown when a section has nothing to render. The
/// icon + message pair keeps empty states visually consistent instead of
/// dropping a bare grey `Text` into the layout.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.padding = const EdgeInsets.symmetric(
      horizontal: Spacing.lg,
      vertical: Spacing.xl,
    ),
  });

  final String message;
  final IconData icon;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 36,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[const SizedBox(height: Spacing.md), action!],
        ],
      ),
    );
  }
}

/// Tiny coloured pill used for tags like "Beginner", "Coursera", "FREE".
/// Pick a colour that contrasts with the surface, or omit it to use the
/// primary colour.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.text,
    this.icon,
    this.color,
    this.dense = true,
  });

  final String text;
  final IconData? icon;
  final Color? color;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = color ?? theme.colorScheme.primary;
    final maxWidth = MediaQuery.sizeOf(context).width * 0.58;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? Spacing.sm : Spacing.md,
          vertical: dense ? 4 : 7,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(
            color: accent.withValues(alpha: 0.16),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.15,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline stat block (icon + label + optional value) used for the
/// metadata strip on Course Details: level, duration, language, etc.
class StatChip extends StatelessWidget {
  const StatChip({
    super.key,
    required this.icon,
    required this.label,
    this.value,
  });

  final IconData icon;
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.sm,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: Spacing.xs),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (value != null)
                  Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
