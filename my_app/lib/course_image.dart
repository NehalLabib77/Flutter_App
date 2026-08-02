/// Shared widgets for displaying a course thumbnail with caching and a
/// uniform fallback icon. Decouples CachedNetworkImage from every screen.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'models.dart';

/// Compact, square-ish course thumbnail with an enhanced fallback.
///
/// - When the remote image loads: clipped, cover-fit.
/// - When missing or loading: an enriched placeholder showing a subtle
///   diagonal gradient + the provider's initials + a small book icon, so the
///   tile still reads as a course card even without a network image.
class CourseThumbnail extends StatelessWidget {
  const CourseThumbnail({
    super.key,
    required this.course,
    this.size = 72,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  final Course course;
  final double size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = course.imageUrl;
    final hasUrl = url != null && url.isNotEmpty;
    if (!hasUrl) {
      return _EnhancedPlaceholder(
        size: size,
        course: course,
        borderRadius: borderRadius,
      );
    }
    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox(
        width: size,
        height: size,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          fadeInDuration: const Duration(milliseconds: 220),
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
        ),
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
    final accent = scheme.primary;
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
              overflow: TextOverflow.clip,
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

/// Open a course URL in the platform browser. Surfaces an error snackbar
/// when launching fails so the user is never silently dropped.
///
/// Only `http://` and `https://` URLs are accepted. Anything else
/// (`javascript:`, `file:`, `data:`, `intent:`, raw schemes, malformed
/// strings) is rejected so a malicious course row cannot smuggle a
/// browser-injection or file-handler payload through the API.
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
