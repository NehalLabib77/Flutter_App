// Detail view for a learning path: title + steps + per-step completion.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';
import '../theme.dart';
import '../widgets/design.dart';

class LearningPathDetailScreen extends StatefulWidget {
  const LearningPathDetailScreen({super.key, required this.pathId});
  final String pathId;

  @override
  State<LearningPathDetailScreen> createState() =>
      _LearningPathDetailScreenState();
}

class _LearningPathDetailScreenState extends State<LearningPathDetailScreen> {
  LearningPath? _path;
  final Set<String> _completedSteps = {};
  bool _loading = true;
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
      final path = await user.learningPath(widget.pathId);
      if (!mounted) return;
      setState(() => _path = path);
      try {
        final prog = await user.learningPathProgress(widget.pathId);
        final raw = prog['completed_steps'] ?? prog['completed'] ?? const [];
        final list = raw is List ? raw : const [];
        _completedSteps
          ..clear()
          ..addAll(list.map((e) => e.toString()));
      } catch (_) {
        // No prior progress is fine.
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleStep(LearningPathStep step) async {
    final wasDone = _completedSteps.contains(step.id);
    setState(() {
      if (wasDone) {
        _completedSteps.remove(step.id);
      } else {
        _completedSteps.add(step.id);
      }
    });
    try {
      await context.read<UserProvider>().updateLearningPathProgress(
        widget.pathId,
        step.id,
        completed: !wasDone,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (!wasDone) {
          _completedSteps.remove(step.id);
        } else {
          _completedSteps.add(step.id);
        }
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _openCourse(String courseId) {
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.courseDetails, arguments: courseId);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _path == null) {
      return Scaffold(
        appBar: AppBar(),
        body: _ErrorState(message: _error ?? 'Path not found', onRetry: _load),
      );
    }
    final p = _path!;
    final total = p.steps.length;
    final done = p.steps.where((s) => _completedSteps.contains(s.id)).length;
    final pct = total == 0 ? 0.0 : done / total;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.md),
        children: [
          _PathSummary(
            title: p.title,
            description: p.description,
            done: done,
            total: total,
            pct: pct,
          ),
          const SizedBox(height: Spacing.lg),
          SectionHeader(
            icon: Icons.format_list_numbered_rounded,
            title: 'Path outline',
            subtitle: '$done of $total steps complete',
            trailing: Text(
              '${(pct * 100).round()}%',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          for (var i = 0; i < p.steps.length; i++) ...[
            _StepCard(
              index: i + 1,
              step: p.steps[i],
              done: _completedSteps.contains(p.steps[i].id),
              onToggle: () => _toggleStep(p.steps[i]),
              onCourseTap: _openCourse,
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

class _PathSummary extends StatelessWidget {
  const _PathSummary({
    required this.title,
    required this.description,
    required this.done,
    required this.total,
    required this.pct,
  });

  final String title;
  final String? description;
  final int done;
  final int total;
  final double pct;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final pctLabel = '${(pct * 100).round()}%';
    return HeroBanner(
      eyebrow: 'LEARNING PATH',
      title: title,
      subtitle: (description ?? '').isEmpty ? null : description,
      icon: Icons.route_rounded,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            pctLabel,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w900,
              color: scheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Pill(text: '$done of $total', icon: Icons.check_circle_rounded),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({
    required this.index,
    required this.step,
    required this.done,
    required this.onToggle,
    required this.onCourseTap,
  });
  final int index;
  final LearningPathStep step;
  final bool done;
  final VoidCallback onToggle;
  final ValueChanged<String> onCourseTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconBadge(
                icon: done
                    ? Icons.check_rounded
                    : Icons.fiber_manual_record_rounded,
                size: 40,
                background: done
                    ? scheme.primary
                    : scheme.surfaceContainerHighest,
                foreground: done ? scheme.onPrimary : scheme.onSurfaceVariant,
                iconSize: 20,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Step $index',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const SizedBox(width: Spacing.sm),
                        if (done) ...[
                          const Pill(
                            text: 'Done',
                            icon: Icons.verified_rounded,
                            color: AppColors.success,
                          ),
                        ] else
                          const Pill(text: 'Pending'),
                      ],
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      step.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if ((step.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: Spacing.xs),
                      Text(
                        step.description!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              IconButton.filledTonal(
                tooltip: done ? 'Mark as pending' : 'Mark as done',
                onPressed: onToggle,
                icon: Icon(
                  done
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                ),
              ),
            ],
          ),
          if (step.courseIds.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            const Divider(height: 1),
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final id in step.courseIds)
                  _CourseChip(id: id, onTap: () => onCourseTap(id)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CourseChip extends StatelessWidget {
  const _CourseChip({required this.id, required this.onTap});
  final String id;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.md,
          vertical: Spacing.sm,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.play_lesson_rounded,
              size: 18,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: Spacing.sm),
            Text(
              id,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(Spacing.lg),
      children: [
        const SizedBox(height: Spacing.xl),
        Icon(Icons.error_outline_rounded, size: 48, color: scheme.error),
        const SizedBox(height: Spacing.md),
        Text(
          'Could not open this path',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Spacing.md),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ),
      ],
    );
  }
}
