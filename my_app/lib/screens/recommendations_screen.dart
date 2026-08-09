// "For You" tab — goal-based AI recommendations + personalised picks.
//
// Layout, top-to-bottom:
//   1. AppBar (title: "For you").
//   2. Goal card: SearchBar input + Filled CTA inside an EduCard.
//   3. "By your goal" results (CourseRowCard list).
//   4. "Picks for you" personalised list from UserProvider.
//
// All state mutations (text controller, search flag, results list,
// personalised reload) are kept exactly as before. Only the widgets
// that render them are swapped out for shared primitives.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../widgets/design.dart';

class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({super.key, this.initialQuery = ''});

  /// Optional seed text for the goal-search input. Set when the user
  /// submits the home-screen search bar so the "For you" tab lands
  /// already-typed and the search runs immediately. An empty value
  /// preserves the original blank-state behaviour.
  final String initialQuery;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  late final TextEditingController _ctrl;
  List<Course> _goalResults = const [];
  bool _searchingGoal = false;
  String? _goalError;
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialQuery);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_initialLoaded) {
        _initialLoaded = true;
        _loadPersonalized();
      }
      // If we were launched with a prefilled query (e.g. from the
      // home-screen search bar) fire the goal search automatically so
      // the user lands on the results instead of having to retype.
      if (widget.initialQuery.trim().isNotEmpty && !_searchingGoal) {
        _runGoalSearch();
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
      if (mounted) {
        setState(() => _searchingGoal = false);
      }
    }
  }

  Future<void> _loadPersonalized() async {
    final auth = context.read<AuthProvider>();
    final preferences = context.read<PreferenceProvider>().preferences;
    await context.read<UserProvider>().loadPersonalized(
      preferences: preferences,
      authenticated: auth.isLoggedIn,
    );
  }

  Future<void> _refreshPersonalized() => _loadPersonalized();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('For you')),
      body: RefreshIndicator(
        onRefresh: _refreshPersonalized,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(0, Spacing.sm, 0, Spacing.xl),
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.xs,
                Spacing.md,
                Spacing.sm,
              ),
              child: _IntroLine(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: _GoalCard(
                controller: _ctrl,
                searching: _searchingGoal,
                onSubmit: _runGoalSearch,
              ),
            ),
            if (_goalError != null)
              Padding(
                padding: const EdgeInsets.only(
                  top: Spacing.sm,
                  left: Spacing.md,
                  right: Spacing.md,
                ),
                child: _ErrorBanner(
                  message: _goalError!,
                  onRetry: _runGoalSearch,
                ),
              ),
            if (_goalResults.isNotEmpty) ...[
              const SizedBox(height: Spacing.lg),
              const SectionHeader(
                icon: Icons.flag_rounded,
                title: 'By your goal',
                subtitle: 'Matches the text you typed',
              ),
              const SizedBox(height: Spacing.sm),
              for (final c in _goalResults) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.md,
                    0,
                    Spacing.md,
                    Spacing.sm,
                  ),
                  child: CourseRowCard(
                    title: c.name,
                    provider: c.provider,
                    level: c.level,
                    subject: c.subject,
                    skills: c.skills,
                    isFree: c.isFree,
                    reason: c.reasons.isEmpty ? null : c.reasons.first,
                    score: c.finalScore,
                    thumbnail: CourseThumbnail(course: c, size: 68),
                    onTap: () => _open(context, c.id),
                  ),
                ),
              ],
            ],
            const SizedBox(height: Spacing.lg),
            const SectionHeader(
              icon: Icons.recommend_rounded,
              title: 'Picks for you',
              subtitle: 'Preferences first, then refined by your activity',
            ),
            const SizedBox(height: Spacing.sm),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Spacing.md),
              child: _PersonalizedList(),
            ),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, String courseId) {
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.courseDetails, arguments: courseId);
  }
}

/// Goal-input card: a title, helper text, [SearchBar], and a primary
/// CTA. While the search is in-flight the CTA shows a spinner.
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
    return EduCard(
      padding: const EdgeInsets.all(Spacing.lg),
      border: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tell us your goal',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'For example: "I want to become a data scientist" or '
            '"learn React Native".',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.md),
          EduSearchBar(
            controller: controller,
            hint: 'What do you want to learn?',
            busy: searching,
            onSubmitted: (_) => onSubmit(),
            onChanged: (_) {},
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
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
          ),
        ],
      ),
    );
  }
}

/// Error banner reused by goal search / personalized load failures.
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EduCard(
      padding: const EdgeInsets.all(Spacing.md),
      color: theme.colorScheme.errorContainer,
      border: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 330;
          final messageWidget = Text(
            message,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          );
          final retry = TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(child: messageWidget),
                  ],
                ),
                Align(alignment: Alignment.centerRight, child: retry),
              ],
            );
          }
          return Row(
            children: [
              Icon(
                Icons.cloud_off_rounded,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: Spacing.md),
              Expanded(child: messageWidget),
              retry,
            ],
          );
        },
      ),
    );
  }
}

/// Single-line subtitle that lives directly under the AppBar's
/// "For you" title. Kept small and muted so the AppBar stays the
/// single primary heading on this screen.
class _IntroLine extends StatelessWidget {
  const _IntroLine();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Your saved preferences start the ranking; activity makes it smarter.',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _PersonalizedList extends StatelessWidget {
  const _PersonalizedList();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<UserProvider>();
    if (user.loadingPersonalized && user.personalized.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Spacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (user.personalized.isEmpty) {
      final error = user.personalizedError;
      if (error != null) {
        return _ErrorBanner(
          message: error,
          onRetry: () {
            final auth = context.read<AuthProvider>();
            final preferences = context.read<PreferenceProvider>().preferences;
            context.read<UserProvider>().loadPersonalized(
              preferences: preferences,
              authenticated: auth.isLoggedIn,
            );
          },
        );
      }
      return const EmptyState(
        icon: Icons.tips_and_updates_outlined,
        message: 'Choose learning preferences or set a goal to improve these picks.',
      );
    }
    return Column(
      children: [
        for (final c in user.personalized)
          Padding(
            padding: const EdgeInsets.only(bottom: Spacing.sm),
            child: CourseRowCard(
              title: c.name,
              provider: c.provider,
              level: c.level,
              subject: c.subject,
              skills: c.skills,
              isFree: c.isFree,
              reason: c.reasons.isEmpty ? null : c.reasons.first,
              score: c.finalScore,
              thumbnail: CourseThumbnail(course: c, size: 68),
              onTap: () => Navigator.of(
                context,
              ).pushNamed(AppRoutes.courseDetails, arguments: c.id),
            ),
          ),
      ],
    );
  }
}
