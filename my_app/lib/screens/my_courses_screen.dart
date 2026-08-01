/// "My Courses" — local enrollment list (SharedPreferences-backed).
///
/// Mirrors `favorites_screen.dart` so the two screens feel consistent.
/// Only reachable from the bottom-nav when the user is signed in; guests
/// are gated out by `shell_screen.dart`.
///
/// Course titles / providers are fetched lazily from the Flask
/// `/courses/{id}` endpoint and cached for the lifetime of the screen so
/// a list of 20 enrolled courses only issues 20 calls (no N per rebuild).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';

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
    final theme = Theme.of(context);
    final enrolled = context.watch<EnrollmentProvider>();
    final ids = enrolled.ids.toList()..sort();

    // Kick off missing lookups after each rebuild.
    for (final id in ids) {
      if (!_resolved.containsKey(id) && !_inflight.containsKey(id)) {
        final future = context.read<UserProvider>().courseDetail(id);
        _inflight[id] = future;
        future.then((c) {
          if (!mounted) return;
          setState(() => _resolved[id] = c);
        }).catchError((Object _) {
          if (!mounted) return;
          setState(() => _resolved[id] = null);
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My Courses')),
      body: ids.isEmpty
          ? _empty(theme)
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: ids.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (_, i) => _SwipeableCourseTile(
                id: ids[i],
                course: _resolved[ids[i]],
                onDropped: (droppedId) async {
                  await _dropOne(context, droppedId);
                },
              ),
            ),
    );
  }

  /// Drops [id] from every store and surfaces a SnackBar with the
  /// outcome. Errors from the remote sync are non-fatal — the local
  /// list already reflects the drop, so we only mention them.
  Future<void> _dropOne(BuildContext context, String id) async {
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
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(syncError == null
            ? 'Removed "$label" from My Courses.'
            : 'Removed "$label" locally — could not sync to server.'),
      ),
    );
  }

  Widget _empty(ThemeData theme) {
    return ListView(
      // ListView keeps the screen pull-downable when empty.
      children: [
        const SizedBox(height: 120),
        Icon(Icons.school_outlined,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'No enrolled courses yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Open a course, tap Enroll, and complete the demo payment to '
            'see it here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.id, required this.course});
  final String id;
  final Course? course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<UserProvider>();
    final progress = user.progressFor(id);
    final completed = user.completedFor(id);

    final title = course?.name ?? id;
    final subtitle = [
      course?.provider,
      course?.subject,
    ].where((s) => (s ?? '').isNotEmpty).join(' • ');

    return Card(
      child: ListTile(
        onTap: () => Navigator.of(context).pushNamed(
          AppRoutes.courseDetails,
          arguments: id,
        ),
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            completed
                ? Icons.verified_rounded
                : Icons.school_rounded,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(title,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: SizedBox(
          width: 56,
          child: Text(
            '$progress%',
            textAlign: TextAlign.end,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps [_CourseTile] in a swipe-to-remove gesture. The tile is
/// rebuilt on the next frame after [onDropped] completes, by which
/// point `EnrollmentProvider.drop` has already removed the id from
/// the local set.
class _SwipeableCourseTile extends StatelessWidget {
  const _SwipeableCourseTile({
    required this.id,
    required this.course,
    required this.onDropped,
  });

  final String id;
  final Course? course;
  final Future<void> Function(String id) onDropped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('my-course-$id'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.delete_outline_rounded,
                color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Text(
              'Unenroll',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onErrorContainer,
                fontWeight: FontWeight.w700,
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
      child: _CourseTile(id: id, course: course),
    );
  }
}