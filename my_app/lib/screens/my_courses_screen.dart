// "My Courses" — local enrollment list (SharedPreferences-backed).
//
// Mirrors `favorites_screen.dart` so the two screens feel consistent.
// Only reachable from the bottom-nav when the user is signed in; guests
// are gated out by `shell_screen.dart`.
//
// Course titles / providers are fetched lazily from the Flask
// `/courses/{id}` endpoint and cached for the lifetime of the screen so
// a list of 20 enrolled courses only issues 20 calls (no N per rebuild).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';
import '../theme.dart';
import '../widgets/design.dart';

class MyCoursesScreen extends StatefulWidget {
  const MyCoursesScreen({super.key});

  @override
  State<MyCoursesScreen> createState() => _MyCoursesScreenState();
}

class _MyCoursesScreenState extends State<MyCoursesScreen> {
  // id -> resolved Course (or null while loading / on failure).
  final Map<String, Course?> _resolved = {};
  // id -> fetch future so we don't double-issue the same call.
  final Map<String, Future<Course>> _inflight = {};

  @override
  Widget build(BuildContext context) {
    final enrolled = context.watch<EnrollmentProvider>();
    final ids = enrolled.ids.toList()..sort();

    // Kick off missing lookups after each rebuild.
    for (final id in ids) {
      if (!_resolved.containsKey(id) && !_inflight.containsKey(id)) {
        final future = context.read<UserProvider>().courseDetail(id);
        _inflight[id] = future;
        future
            .then((c) {
              if (!mounted) return;
              setState(() => _resolved[id] = c);
            })
            .catchError((Object _) {
              if (!mounted) return;
              setState(() => _resolved[id] = null);
            });
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My Courses')),
      body: ids.isEmpty
          ? const _EmptyState()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.md,
                Spacing.md,
                Spacing.xxl,
              ),
              itemCount: ids.length,
              separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
              itemBuilder: (_, i) {
                final id = ids[i];
                return _SwipeableCourseCard(
                  id: id,
                  course: _resolved[id],
                  onDropped: (droppedId) => _dropOne(droppedId),
                  onUnenroll: () => _dropOne(id),
                );
              },
            ),
    );
  }

  /// Drops [id] from every store and surfaces a SnackBar with the
  /// outcome. Errors from the remote sync are non-fatal — the local
  /// list already reflects the drop, so we only mention them.
  Future<void> _dropOne(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final provider = context.read<EnrollmentProvider>();
    final course = _resolved[id];
    final label = course?.name ?? id;
    String? syncError;
    await provider.drop(
      id,
      onSyncError: (e, [StackTrace? _]) {
        syncError ??= e.toString();
      },
    );
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          syncError == null
              ? 'Removed "$label" from My Courses.'
              : 'Removed "$label" locally — could not sync to server.',
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.md,
        vertical: Spacing.xl,
      ),
      children: [
        const HeroBanner(
          eyebrow: 'GET STARTED',
          title: 'Your learning list is empty',
          subtitle:
              'Browse the catalog and tap Enroll on any course to see it here.',
          icon: Icons.school_rounded,
        ),
        const SizedBox(height: Spacing.lg),
        EduCard(
          border: true,
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: Spacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.menu_book_rounded,
                size: 36,
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'No enrolled courses yet',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'Open a course, tap Enroll, and complete the demo payment to '
                'add it here.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.md),
              FilledButton.icon(
                onPressed: () =>
                    Navigator.of(context).pushNamed(AppRoutes.recommendations),
                icon: const Icon(Icons.explore_rounded),
                label: const Text('Browse courses'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CourseCard extends StatelessWidget {
  const _CourseCard({
    required this.id,
    required this.course,
    required this.onUnenroll,
  });
  final String id;
  final Course? course;
  final Future<void> Function() onUnenroll;

  @override
  Widget build(BuildContext context) {
    final user = context.watch<UserProvider>();
    final progress = user.progressFor(id);
    final completed = user.completedFor(id);
    final loading = course == null;

    final title = course?.name ?? (loading ? 'Loading course…' : id);

    return CourseRowCard(
      title: title,
      provider: course?.provider,
      level: course?.level,
      subject: course?.subject,
      rating: course?.rating,
      score: course?.finalScore,
      isFree: course?.isFree ?? false,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _ProgressTrailing(
            progress: progress,
            completed: completed,
            loading: loading,
          ),
          const SizedBox(width: Spacing.xs),
          _CourseMenuButton(id: id, onUnenroll: onUnenroll),
        ],
      ),
      onTap: () => Navigator.of(
        context,
      ).pushNamed(AppRoutes.courseDetails, arguments: id),
      thumbnail: _LeadingThumb(completed: completed, loading: loading),
      reason: completed ? 'Completed' : null,
    );
  }
}

/// Action button shown in the AppBar when at least one course is
/// enrolled. Long-press on a card also surfaces this menu so the
/// "Unenroll" action is never hidden behind the swipe gesture alone.
class _CourseMenuButton extends StatelessWidget {
  const _CourseMenuButton({required this.id, required this.onUnenroll});

  final String id;
  final Future<void> Function() onUnenroll;

  Future<void> _confirmUnenroll(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Unenroll from this course?'),
          content: const Text(
            'You will lose access to the course on every device. '
            'You can re-enroll at any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Unenroll'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    await onUnenroll();
    // The provider-driven list will already have rebuilt by the
    // time the SnackBar shows; we just surface a confirmation.
    if (!context.mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Course removed from My Courses.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      tooltip: 'Course actions',
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (value) async {
        if (value == 'unenroll') {
          await _confirmUnenroll(context);
        } else if (value == 'open') {
          Navigator.of(
            context,
          ).pushNamed(AppRoutes.courseDetails, arguments: id);
        }
      },
      itemBuilder: (ctx) => [
        const PopupMenuItem<String>(
          value: 'open',
          child: ListTile(
            leading: Icon(Icons.open_in_new_rounded),
            title: Text('Open course'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem<String>(
          value: 'unenroll',
          child: ListTile(
            leading: Icon(Icons.event_busy_rounded, color: scheme.error),
            title: Text('Unenroll', style: TextStyle(color: scheme.error)),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// Thumb leading the row. Uses a tinted circle so the row reads at a glance
/// whether the course is in progress, completed, or still loading.
class _LeadingThumb extends StatelessWidget {
  const _LeadingThumb({required this.completed, required this.loading});
  final bool completed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = completed ? scheme.primary : scheme.primaryContainer;
    final fg = completed ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      alignment: Alignment.center,
      child: loading
          ? SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          : Icon(
              completed ? Icons.verified_rounded : Icons.school_rounded,
              color: fg,
              size: 26,
            ),
    );
  }
}

/// Right-side status: completion badge + progress % + thin linear bar.
class _ProgressTrailing extends StatelessWidget {
  const _ProgressTrailing({
    required this.progress,
    required this.completed,
    required this.loading,
  });

  final int progress;
  final bool completed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (completed)
            Pill(text: 'DONE', icon: Icons.check_circle_rounded, color: AppColors.success)
          else if (!loading)
            Text(
              '$progress%',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            )
          else
            Text(
              '…',
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: Spacing.xs),
          ClipRRect(
            borderRadius: Radii.pill,
            child: LinearProgressIndicator(
              value: completed ? 1.0 : progress / 100.0,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps [_CourseCard] in a swipe-to-remove gesture. The tile is
/// rebuilt on the next frame after [onDropped] completes, by which
/// point `EnrollmentProvider.drop` has already removed the id from
/// the local set.
class _SwipeableCourseCard extends StatelessWidget {
  const _SwipeableCourseCard({
    required this.id,
    required this.course,
    required this.onDropped,
    required this.onUnenroll,
  });

  final String id;
  final Course? course;
  final Future<void> Function(String id) onDropped;
  final Future<void> Function() onUnenroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Dismissible(
      key: ValueKey('my-course-$id'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_busy_rounded, color: scheme.onErrorContainer),
            const SizedBox(width: Spacing.sm),
            Text(
              'Unenroll',
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
      confirmDismiss: (_) async {
        // One-step confirm via SnackBar with Undo. The provider's
        // listener removes the tile from the list, so we always
        // accept the dismiss; if the caller wants a true confirm
        // dialog later they can swap this out.
        return true;
      },
      onDismissed: (_) {
        unawaited(onDropped(id));
      },
      child: _CourseCard(id: id, course: course, onUnenroll: onUnenroll),
    );
  }
}
