// List of curated learning paths.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';
import '../widgets/design.dart';

class LearningPathsScreen extends StatefulWidget {
  const LearningPathsScreen({super.key});

  @override
  State<LearningPathsScreen> createState() => _LearningPathsScreenState();
}

class _LearningPathsScreenState extends State<LearningPathsScreen> {
  List<LearningPath> _paths = const [];
  bool _loading = true;
  String? _error;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_loaded) {
        _loaded = true;
        _load();
      }
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<UserProvider>().learningPaths();
      if (!mounted) return;
      setState(() => _paths = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Learning paths')),
      body: RefreshIndicator(onRefresh: _load, child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const LoadingState(message: 'Loading learning paths…');
    }
    if (_error != null) {
      return _ErrorState(error: _error!, onRetry: _load);
    }
    if (_paths.isEmpty) {
      return const _EmptyState();
    }
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      itemCount: _paths.length + 1,
      separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
      itemBuilder: (_, i) {
        if (i == 0) {
          return const ResponsiveContent(
            child: Padding(
              padding: EdgeInsets.only(bottom: Spacing.sm),
              child: HeroBanner(
              eyebrow: 'GUIDED TRACKS',
              title: 'Learn with a path',
              subtitle:
                  'Curated multi-step paths group related courses so you can '
                  'follow a structured arc end-to-end.',
              icon: Icons.route_rounded,
            ),
            ),
          );
        }
        final p = _paths[i - 1];
        return ResponsiveContent(
          child: _PathCard(
          path: p,
          onTap: () => Navigator.of(
            context,
          ).pushNamed(AppRoutes.learningPathDetail, arguments: p.id),
        ),
        );
      },
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({required this.path, required this.onTap});
  final LearningPath path;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stepCount = path.steps.length;
    return EduCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconBadge(
            icon: Icons.route_rounded,
            size: 48,
            background: scheme.tertiaryContainer,
            foreground: scheme.onTertiaryContainer,
            iconSize: 24,
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  path.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if ((path.description ?? '').isNotEmpty) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(
                    path.description!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: Spacing.sm),
                Row(
                  children: [
                    StatChip(
                      icon: Icons.format_list_numbered_rounded,
                      label: 'STEPS',
                      value: '$stepCount',
                    ),
                    const SizedBox(width: Spacing.sm),
                    const Pill(
                      icon: Icons.collections_bookmark_rounded,
                      text: 'Curated',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Spacing.sm),
          Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        ],
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
      padding: const EdgeInsets.symmetric(vertical: Spacing.md),
      children: const [
        ResponsiveContent(
          maxWidth: 820,
          child: HeroBanner(
          eyebrow: 'GUIDED TRACKS',
          title: 'No learning paths yet',
          subtitle:
              'Curated multi-step paths will appear here. Pull down to '
              'refresh once they are available.',
          icon: Icons.route_outlined,
        ),
        ),
        SizedBox(height: Spacing.lg),
        ResponsiveContent(
          maxWidth: 720,
          child: EmptyState(
          icon: Icons.route_outlined,
          message: 'No learning paths have been published yet.',
        ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error, required this.onRetry});
  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
      children: [
        ResponsiveContent(
          maxWidth: 720,
          child: ErrorState(
            title: 'Could not load paths',
            message: error,
            onRetry: onRetry,
          ),
        ),
      ],
    );
  }
}
