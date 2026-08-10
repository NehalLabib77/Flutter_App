/// Shared widgets for displaying a course thumbnail with caching and a
/// uniform fallback icon. Decouples CachedNetworkImage from every screen.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';

class CourseThumbnail extends StatelessWidget {
  const CourseThumbnail({
    super.key,
    required this.course,
    this.size = 72,
    this.borderRadius = const BorderRadius.all(Radius.circular(14)),
  });

  final Course course;
  final double size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = course.imageUrl;
    final hasUrl = url != null && url.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    final image = hasUrl
        ? CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            alignment: Alignment.center,
            fadeInDuration: const Duration(milliseconds: 180),
            fadeOutDuration: const Duration(milliseconds: 90),
            useOldImageOnUrlChange: true,
            filterQuality: FilterQuality.high,
            placeholder: (_, _) => _EnhancedPlaceholder(
              size: size,
              course: course,
              borderRadius: borderRadius,
            ),
            errorWidget: (_, _, _) => _EnhancedPlaceholder(
              size: size,
              course: course,
              borderRadius: borderRadius,
            ),
          )
        : _EnhancedPlaceholder(
            size: size,
            course: course,
            borderRadius: borderRadius,
          );

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: image,
    );
  }
}


/// Edge-to-edge course artwork for larger promotional cards.
///
/// Unlike [CourseThumbnail], this widget expands to the constraints supplied
/// by its parent and therefore works as a full Stack background. It uses the
/// same cached image source and visually compatible fallback treatment.
class CourseBackgroundImage extends StatelessWidget {
  const CourseBackgroundImage({
    super.key,
    required this.course,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
  });

  final Course course;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = course.imageUrl;
    final hasUrl = url != null && url.trim().isNotEmpty;

    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox.expand(
        child: hasUrl
            ? CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                alignment: Alignment.center,
                fadeInDuration: const Duration(milliseconds: 180),
                fadeOutDuration: const Duration(milliseconds: 90),
                useOldImageOnUrlChange: true,
                filterQuality: FilterQuality.high,
                placeholder: (_, _) => _WidePlaceholder(course: course),
                errorWidget: (_, _, _) => _WidePlaceholder(course: course),
              )
            : _WidePlaceholder(course: course),
      ),
    );
  }
}

class _WidePlaceholder extends StatelessWidget {
  const _WidePlaceholder({required this.course});

  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = (course.subject?.trim().isNotEmpty ?? false)
        ? course.subject!
        : (course.provider?.trim().isNotEmpty ?? false)
            ? course.provider!
            : 'EduCompass';

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary,
            Color.lerp(scheme.primary, scheme.secondary, 0.72) ??
                scheme.secondary,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            right: -30,
            top: -34,
            child: Container(
              width: 140,
              height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.09),
              ),
            ),
          ),
          Positioned(
            left: -22,
            bottom: -48,
            child: Container(
              width: 170,
              height: 170,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withValues(alpha: 0.08),
              ),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 44,
                  color: Colors.white.withValues(alpha: 0.88),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.92),
                      fontWeight: FontWeight.w800,
                    ),
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

class _EnhancedPlaceholder extends StatelessWidget {
  const _EnhancedPlaceholder({
    required this.size,
    required this.course,
    required this.borderRadius,
  });

  final double size;
  final Course course;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = scheme.primaryContainer;
    final accent = scheme.secondary;
    final initials = _initialsFor(course.provider ?? course.name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, Color.lerp(base, accent, 0.45) ?? accent],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -size * 0.18,
            bottom: -size * 0.18,
            child: Container(
              width: size * 0.7,
              height: size * 0.7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.10),
              ),
            ),
          ),
          Positioned(
            left: size * 0.16,
            top: size * 0.14,
            child: Icon(
              Icons.menu_book_rounded,
              size: size * 0.30,
              color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
            ),
          ),
          Positioned(
            left: size * 0.16,
            bottom: size * 0.16,
            right: size * 0.16,
            child: Text(
              initials,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _initialsFor(String value) {
    final parts = value
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'C';
    if (parts.length == 1) {
      final w = parts.first;
      return w.length <= 3 ? w.toUpperCase() : w.substring(0, 2).toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }
}


Future<void> openCourseUrl(BuildContext context, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || uri.scheme.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text('Invalid course URL: $url')));
    return;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') {
    messenger.showSnackBar(
      const SnackBar(content: Text('Only http(s) links are supported.')),
    );
    return;
  }
  if (uri.host.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text('Invalid course URL: $url')));
    return;
  }
  try {
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  } catch (e) {
    if (context.mounted) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not open $url: $e')),
      );
    }
  }
}
