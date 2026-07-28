/// List of curated learning paths.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';

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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Learning paths')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _errorState(theme);
    }
    if (_paths.isEmpty) {
      return _emptyState(theme);
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _paths.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) {
        final p = _paths[i];
        return Card(
          child: ListTile(
            onTap: () => Navigator.of(context).pushNamed(
              AppRoutes.learningPathDetail,
              arguments: p.id,
            ),
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.tertiaryContainer,
              child: Icon(Icons.route_rounded,
                  color: theme.colorScheme.onTertiaryContainer),
            ),
            title: Text(p.title),
            subtitle: Text(
              '${p.steps.length} step${p.steps.length == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
        );
      },
    );
  }

  Widget _emptyState(ThemeData theme) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Icon(Icons.route_outlined,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'No learning paths yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Curated multi-step paths will appear here.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorState(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 80),
        Icon(Icons.error_outline_rounded,
            size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text('Could not load paths',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_error!,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 16),
        Center(
          child: FilledButton.tonal(
            onPressed: _load,
            child: const Text('Retry'),
          ),
        ),
      ],
    );
  }
}