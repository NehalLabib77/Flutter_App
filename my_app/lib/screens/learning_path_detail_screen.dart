/// Detail view for a learning path: title + steps + per-step completion.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';

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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  void _openCourse(String courseId) {
    Navigator.of(context).pushNamed(
      AppRoutes.courseDetails,
      arguments: courseId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _path == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error ?? 'Path not found', textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final p = _path!;
    final total = p.steps.length;
    final done = p.steps.where((s) => _completedSteps.contains(s.id)).length;
    final pct = total == 0 ? 0.0 : done / total;
    return Scaffold(
      appBar: AppBar(
          title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      )),
                  if ((p.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(p.description!, style: theme.textTheme.bodyMedium),
                  ],
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: pct),
                  const SizedBox(height: 6),
                  Text('$done of $total steps complete',
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < p.steps.length; i++)
            _StepTile(
              index: i + 1,
              step: p.steps[i],
              done: _completedSteps.contains(p.steps[i].id),
              onToggle: () => _toggleStep(p.steps[i]),
              onCourseTap: _openCourse,
            ),
        ],
      ),
    );
  }
}

class _StepTile extends StatelessWidget {
  const _StepTile({
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: done
                      ? theme.colorScheme.primary
                      : theme.colorScheme.surfaceContainerHighest,
                  child: done
                      ? Icon(Icons.check_rounded,
                          color: theme.colorScheme.onPrimary, size: 16)
                      : Text('$index',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          )),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(step.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                ),
                IconButton(
                  icon: Icon(done
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded),
                  color: done ? theme.colorScheme.primary : null,
                  onPressed: onToggle,
                ),
              ],
            ),
            if ((step.description ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Text(step.description!, style: theme.textTheme.bodySmall),
              ),
            ],
            if (step.courseIds.isNotEmpty) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 40),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in step.courseIds)
                      ActionChip(
                        label: Text('Course: $id',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onPressed: () => onCourseTap(id),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}