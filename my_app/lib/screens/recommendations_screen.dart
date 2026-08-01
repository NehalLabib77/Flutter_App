/// Goal-based and personalized recommendations.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';

class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({super.key});

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  final _ctrl = TextEditingController();
  List<Course> _goalResults = const [];
  bool _searchingGoal = false;
  String? _goalError;
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_initialLoaded) {
        _initialLoaded = true;
        context.read<UserProvider>().loadPersonalized();
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _runGoalSearch() async {
    final q = _ctrl.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searchingGoal = true;
      _goalError = null;
    });
    try {
      final list = await context.read<UserProvider>().recommendByGoal(q);
      if (!mounted) return;
      setState(() => _goalResults = list);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _goalError = e.message);
    } finally {
      if (mounted) setState(() => _searchingGoal = false);
    }
  }

  Future<void> _refreshPersonalized() =>
      context.read<UserProvider>().loadPersonalized();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Recommendations')),
      body: RefreshIndicator(
        onRefresh: _refreshPersonalized,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _GoalCard(
              controller: _ctrl,
              searching: _searchingGoal,
              onSubmit: _runGoalSearch,
            ),
            if (_goalError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_goalError!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_goalResults.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _SectionTitle('By your goal'),
              for (final c in _goalResults)
                _CourseRow(
                  course: c,
                  onTap: () => _open(context, c.id),
                ),
            ],
            const SizedBox(height: 24),
            const _SectionTitle('Picks for you'),
            const _PersonalizedList(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, String courseId) {
    Navigator.of(context).pushNamed(
      AppRoutes.courseDetails,
      arguments: courseId,
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.controller,
    required this.searching,
    required this.onSubmit,
  });
  final TextEditingController controller;
  final bool searching;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tell us your goal',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'For example: "I want to become a data scientist" or "learn React Native".',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'What do you want to learn?',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: searching ? null : onSubmit,
              icon: searching
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded),
              label: const Text('Get recommendations'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _PersonalizedList extends StatelessWidget {
  const _PersonalizedList();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<UserProvider>();
    final api = context.read<ApiClient>();
    if (user.loadingPersonalized && user.personalized.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (user.personalized.isEmpty) {
      final error = user.personalizedError;
      if (error != null) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 36,
                    color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => context
                      .read<UserProvider>()
                      .loadPersonalized(),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
                Text(
                  'API: ${api.baseUrl}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color:
                            Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        );
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(Icons.tips_and_updates_outlined,
                  size: 36,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              Text(
                'Add favourites or set a goal to unlock personalised picks.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final c in user.personalized)
          _CourseRow(
            course: c,
            onTap: () => Navigator.of(context).pushNamed(
              AppRoutes.courseDetails,
              arguments: c.id,
            ),
          ),
      ],
    );
  }
}

class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.course, required this.onTap});
  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reason =
        course.reasons.isEmpty ? null : course.reasons.first;
    final hasUrl = course.url != null && course.url!.isNotEmpty;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CourseThumbnail(course: course, size: 64),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(course.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                    if (reason != null) ...[
                      const SizedBox(height: 4),
                      Text(reason,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontStyle: FontStyle.italic,
                          )),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      [course.provider, course.level, course.subject]
                          .where((s) => (s ?? '').isNotEmpty)
                          .join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (course.skills.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final s in course.skills.take(2))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.tertiaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                s,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onTertiaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (course.finalScore != null)
                    Text(
                      '${(course.finalScore! * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  if (hasUrl)
                    IconButton(
                      tooltip: 'Open in browser',
                      icon: Icon(Icons.open_in_new_rounded,
                          color: theme.colorScheme.primary),
                      onPressed: () => openCourseUrl(context, course.url!),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}