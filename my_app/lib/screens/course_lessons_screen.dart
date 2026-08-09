/// Course-specific video lessons for enrolled courses.
///
/// In a production app these would come from the Flask backend (or a
/// dedicated CMS); for the demo build we ship a small curated catalog
/// so the "after enrolling → watch videos" flow works end-to-end on
/// every supported platform.
///
/// Each entry maps a course id to:
///   * a list of [Lesson] objects with title, duration, summary, and a
///     YouTube / original-platform URL;
///   * an optional `originalUrl` that is exposed as
///     "Open original course on the web" and uses `url_launcher` so the
///     user lands on the official Coursera / edX / etc. page.
///
/// Adding a new course is a single map entry — no backend changes
/// required for the demo.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../widgets/design.dart';

class CourseLesson {
  const CourseLesson({
    required this.title,
    required this.videoUrl,
    this.durationMinutes,
    this.summary,
  });

  final String title;
  final String videoUrl;
  final int? durationMinutes;
  final String? summary;
}

class CourseLessonsScreen extends StatelessWidget {
  const CourseLessonsScreen({super.key, required this.courseId});

  final String courseId;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<UserProvider>();
    Course? cached;
    for (final c in user.favorites) {
      if (c.id == courseId) {
        cached = c;
        break;
      }
    }
    cached ??= user.personalized.firstWhere(
      (c) => c.id == courseId,
      orElse: () => _placeholderCourse(courseId),
    );
    final course = cached;
    final lessons = courseLessons[courseId] ?? const <CourseLesson>[];
    final originalUrl = courseOriginalUrls[courseId];

    return Scaffold(
      appBar: AppBar(
        title: Text(course.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: lessons.isEmpty
          ? _NoLessons(course: course)
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
              itemCount: lessons.length + 1,
              separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
              itemBuilder: (context, i) {
                if (i == 0) {
                  return ResponsiveContent(
                    maxWidth: 900,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const PageLead(
                          title: 'Course lessons',
                          subtitle: 'Work through the lessons at your own pace and return whenever you need.',
                          icon: Icons.play_circle_outline_rounded,
                        ),
                        const SizedBox(height: Spacing.md),
                        _Header(
                          course: course,
                          lessonCount: lessons.length,
                          originalUrl: originalUrl,
                        ),
                      ],
                    ),
                  );
                }
                final lesson = lessons[i - 1];
                return ResponsiveContent(
                  maxWidth: 900,
                  child: _LessonTile(lesson: lesson, courseTitle: course.name),
                );
              },
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.course,
    required this.lessonCount,
    required this.originalUrl,
  });

  final Course course;
  final int lessonCount;
  final String? originalUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EduCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CourseThumbnail(course: course, size: 56),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      course.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      '$lessonCount video lessons • Tap to open in browser',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (originalUrl != null && originalUrl!.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                onPressed: () => openCourseUrl(context, originalUrl!),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open original course on the web'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LessonTile extends StatelessWidget {
  const _LessonTile({required this.lesson, required this.courseTitle});

  final CourseLesson lesson;
  final String courseTitle;

  Future<void> _open(BuildContext context) async {
    final uri = Uri.tryParse(lesson.videoUrl);
    if (uri == null || !uri.hasScheme) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Invalid video URL: ${lesson.videoUrl}')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not open video.')));
    }
  }

  String get _durationLabel {
    final m = lesson.durationMinutes;
    if (m == null) return '—';
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final rem = m % 60;
    return rem == 0 ? '${h}h' : '${h}h ${rem}m';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      onTap: () => _open(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.play_arrow_rounded, color: Colors.white),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  lesson.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (lesson.summary != null && lesson.summary!.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    lesson.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _durationLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.open_in_new_rounded,
                      size: 14,
                      color: scheme.primary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NoLessons extends StatelessWidget {
  const _NoLessons({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      children: [
        ResponsiveContent(
          maxWidth: 720,
          child: HeroBanner(
          eyebrow: 'NO VIDEOS YET',
          title: 'Lessons coming soon',
          subtitle: 'We are still indexing video lessons for "${course.name}".',
          icon: Icons.video_library_outlined,
        ),
        ),
        const SizedBox(height: Spacing.lg),
        ResponsiveContent(
          maxWidth: 720,
          child: FilledButton.icon(
          onPressed: () => Navigator.of(
            context,
          ).pushReplacementNamed(AppRoutes.courseDetails, arguments: course.id),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Back to course'),
        ),
        ),
      ],
    );
  }
}

/// Placeholder used when the `CourseProvider` cache hasn't yet fetched
/// the details. Avoids a hard crash when navigating to a course that
/// hasn't been opened before.
Course _placeholderCourse(String id) {
  return Course(id: id, name: 'Course lessons');
}

// ---------------------------------------------------------------------------
// Static lesson catalog
// ---------------------------------------------------------------------------

/// Vector Calculus for Engineers — five weeks of instructor video from
/// Coursera (HKUST, Jeffrey R. Chasnov). URLs are the original Coursera
/// lesson pages so the user always lands on the canonical source.
final Map<String, List<CourseLesson>> courseLessons = {
  '1': [
    const CourseLesson(
      title: 'Week 1 — Scalar and vector fields',
      videoUrl: 'https://www.coursera.org/learn/vector-calculus-engineers',
      durationMinutes: 28,
      summary:
          'Introduction to scalar fields, directional derivatives and '
          'the geometric meaning of vectors in 2D / 3D space.',
    ),
    const CourseLesson(
      title: 'Week 2 — Differentiating fields',
      videoUrl: 'https://www.coursera.org/learn/vector-calculus-engineers',
      durationMinutes: 32,
      summary:
          'Gradient, divergence and curl — the three derivatives you '
          'will use everywhere in engineering maths.',
    ),
    const CourseLesson(
      title: 'Week 3 — Multidimensional integration',
      videoUrl: 'https://www.coursera.org/learn/vector-calculus-engineers',
      durationMinutes: 35,
      summary:
          'Double and triple integrals in Cartesian, cylindrical and '
          'spherical coordinates, with change of variables.',
    ),
    const CourseLesson(
      title: 'Week 4 — Line and surface integrals',
      videoUrl: 'https://www.coursera.org/learn/vector-calculus-engineers',
      durationMinutes: 30,
      summary:
          'Worked examples of line integrals and surface integrals '
          'including parametrisation tricks.',
    ),
    const CourseLesson(
      title: 'Week 5 — Fundamental theorems',
      videoUrl: 'https://www.coursera.org/learn/vector-calculus-engineers',
      durationMinutes: 34,
      summary:
          'Gradient theorem, divergence theorem and Stokes\' theorem — '
          'the three identities tying everything together.',
    ),
  ],
};

/// Original (non-YouTube) course page URL. Surfaced as the
/// "Open original course on the web" button so the user lands on the
/// authoritative Coursera / edX page even if our lesson proxy links
/// expire.
final Map<String, String> courseOriginalUrls = {
  '1': 'https://www.coursera.org/learn/vector-calculus-engineers',
};
