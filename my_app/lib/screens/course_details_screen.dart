/// Single course view: full description + similar courses + progress slider.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../billing_sheet.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';

class CourseDetailsScreen extends StatefulWidget {
  const CourseDetailsScreen({super.key, required this.courseId});
  final String courseId;

  @override
  State<CourseDetailsScreen> createState() => _CourseDetailsScreenState();
}

class _CourseDetailsScreenState extends State<CourseDetailsScreen> {
  Course? _course;
  List<Course> _similar = const [];
  bool _loading = true;
  bool _savingProgress = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = context.read<UserProvider>();
      final course = await user.courseDetail(widget.courseId);
      if (!mounted) return;
      setState(() => _course = course);
      try {
        final sim = await user.similarCourses(widget.courseId);
        if (!mounted) return;
        setState(() => _similar = sim);
      } catch (_) {
        // Similar is a non-critical nice-to-have.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleFavorite() async {
    final c = _course;
    if (c == null) return;
    await context.read<UserProvider>().toggleFavorite(c);
  }

  Future<void> _updateProgress(double value) async {
    final c = _course;
    if (c == null || _savingProgress) return;
    setState(() => _savingProgress = true);
    try {
      await context
          .read<UserProvider>()
          .setProgress(c.id, value.round());
    } finally {
      if (mounted) setState(() => _savingProgress = false);
    }
  }

  Future<void> _enroll() async {
    final c = _course;
    if (c == null) return;
    final enrolled = context.read<EnrollmentProvider>();
    if (enrolled.isEnrolled(c.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Already enrolled in "${c.name}".')),
      );
      return;
    }
    final user = context.read<AuthProvider>().user;
    final paid = await showBillingSheet(
      context,
      course: c,
      userEmail: user?.email ?? 'guest@example.com',
    );
    if (!paid || !mounted) return;
    await enrolled.enroll(c.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Subscription active — " ${c.name} " is now in '
            'your learning list.'),
      ),
    );
    // Seed progress so the new course shows 0% in the slider.
    await context.read<UserProvider>().setProgress(c.id, 0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _course == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error ?? 'Course not found',
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final c = _course!;
    final user = context.watch<UserProvider>();
    final enrolled = context.watch<EnrollmentProvider>();
    final isFavorite = user.isFavorite(c.id);
    final isEnrolled = enrolled.isEnrolled(c.id);
    final progress = user.progressFor(c.id).toDouble();
    return Scaffold(
      appBar: AppBar(
        title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (isEnrolled)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Chip(
                label: Text('Enrolled'),
                avatar: Icon(Icons.check_circle_rounded, size: 16),
                visualDensity: VisualDensity.compact,
              ),
            ),
          IconButton(
            icon: Icon(
              isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              color: isFavorite ? Colors.redAccent : null,
            ),
            onPressed: _toggleFavorite,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if ((c.imageUrl ?? '').isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: CachedNetworkImage(
                  imageUrl: c.imageUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  errorWidget: (_, _, _) => Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: Icon(Icons.menu_book_rounded,
                        size: 48,
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          if ((c.imageUrl ?? '').isNotEmpty) const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      )),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      _Pill(text: c.provider ?? 'Unknown'),
                      if (c.level != null) _Pill(text: c.level!),
                      if (c.subject != null) _Pill(text: c.subject!),
                      if (c.isFree)
                        const _Pill(
                          text: 'FREE',
                          color: Colors.green,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      if (c.rating != null) ...[
                        Icon(Icons.star_rounded,
                            color: Colors.amber.shade700, size: 20),
                        const SizedBox(width: 4),
                        Text(c.rating!.toStringAsFixed(1)),
                        const SizedBox(width: 12),
                      ],
                      if (c.studentsEnrolled != null)
                        Text('${_formatCount(c.studentsEnrolled!)} learners'),
                    ],
                  ),
                  if ((c.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(c.description!,
                        style: theme.textTheme.bodyMedium),
                  ],
                  if (c.url != null && c.url!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _enroll,
                          icon: Icon(isEnrolled
                              ? Icons.check_circle_rounded
                              : Icons.school_rounded),
                          label: Text(isEnrolled ? 'Enrolled' : 'Enroll'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => openCourseUrl(context, c.url!),
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('Open course page'),
                        ),
                      ],
                    ),
                  ] else ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _enroll,
                      icon: Icon(isEnrolled
                          ? Icons.check_circle_rounded
                          : Icons.school_rounded),
                      label: Text(isEnrolled ? 'Enrolled' : 'Enroll'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Your progress',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Slider(
                    value: progress.clamp(0, 100),
                    max: 100,
                    divisions: 20,
                    label: '${progress.round()}%',
                    onChanged: _savingProgress ? null : _updateProgress,
                  ),
                  Text('${progress.round()}% complete'),
                ],
              ),
            ),
          ),
          if (c.skills.isNotEmpty) ...[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Skills',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in c.skills)
                          Chip(label: Text(s)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_similar.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Similar courses',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            for (final s in _similar)
              Card(
                child: ListTile(
                  title: Text(s.name,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: s.provider == null
                      ? null
                      : Text(s.provider!,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: s.similarityScore == null
                      ? null
                      : Text(
                          '${(s.similarityScore! * 100).toStringAsFixed(0)}%',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                  onTap: () => Navigator.of(context).pushReplacementNamed(
                    AppRoutes.courseDetails,
                    arguments: s.id,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: c,
                fontWeight: FontWeight.w700,
              )),
    );
  }
}

String _formatCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return n.toString();
}