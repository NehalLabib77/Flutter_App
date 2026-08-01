/// Home: greeting + Popular and Top Rated course lists from the Flask backend.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final courses = context.read<CourseProvider>();
      if (courses.popular.isEmpty) courses.loadPopular();
      if (courses.topRated.isEmpty) courses.loadTopRated();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    final courses = context.watch<CourseProvider>();
    final user = auth.user;
    // Use the part of the email before '@' as a fallback display name.
    final displayName = (user?.fullName ?? '').trim().isNotEmpty
        ? user!.fullName.split(' ').first
        : (user?.email.split('@').first ?? '');
    final greeting = user == null
        ? 'Welcome to EduCompass'
        : 'Hi $displayName 👋';

    final isGuest = user == null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('EduCompass'),
        actions: [
          if (isGuest)
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LoginScreen()),
              ),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text('Sign in'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            context.read<CourseProvider>().loadPopular(),
            context.read<CourseProvider>().loadTopRated(),
          ]);
        },
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                greeting,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: Text(
                'What will you learn today?',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            _Section(
              title: 'Popular right now',
              courses: courses.popular,
              loading: courses.loadingPopular,
              onRetry: () => context.read<CourseProvider>().loadPopular(),
            ),
            const SizedBox(height: 16),
            _Section(
              title: 'Top rated',
              courses: courses.topRated,
              loading: courses.loadingTopRated,
              onRetry: () => context.read<CourseProvider>().loadTopRated(),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.courses,
    required this.loading,
    required this.onRetry,
  });
  final String title;
  final List<Course> courses;
  final bool loading;
  final Future<void> Function() onRetry;

  void _open(BuildContext context, Course course) {
    Navigator.of(context).pushNamed(
      AppRoutes.courseDetails,
      arguments: course.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 140,
          child: courses.isEmpty
              ? _EmptyOrLoading(
                  loading: loading,
                  onRetry: onRetry,
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  itemCount: courses.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => SizedBox(
                    width: 300,
                    child: _CourseTile(
                      course: courses[i],
                      onTap: () => _open(context, courses[i]),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _EmptyOrLoading extends StatelessWidget {
  const _EmptyOrLoading({required this.loading, required this.onRetry});
  final bool loading;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: TextButton.icon(
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Retry'),
      ),
    );
  }
}

class _CourseTile extends StatelessWidget {
  const _CourseTile({required this.course, required this.onTap});
  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CourseThumbnail(course: course, size: 72),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            course.provider ?? 'Course',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (course.isFree)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green.shade600,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'FREE',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800,
                                fontSize: 10,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Flexible(
                      child: Text(
                        course.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    if (course.skills.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 4,
                        runSpacing: 0,
                        children: [
                          for (final s in course.skills.take(1))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                s,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onSecondaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (course.rating != null) ...[
                          Icon(Icons.star_rounded,
                              size: 14, color: Colors.amber.shade700),
                          const SizedBox(width: 2),
                          Text(
                            course.rating!.toStringAsFixed(1),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            [course.level, course.subject]
                                .where((s) => (s ?? '').isNotEmpty)
                                .join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        if (course.url != null && course.url!.isNotEmpty)
                          SizedBox(
                            height: 32,
                            width: 32,
                            child: IconButton(
                              tooltip: 'Open in browser',
                              padding: EdgeInsets.zero,
                              iconSize: 18,
                              icon: Icon(Icons.open_in_new_rounded,
                                  color: theme.colorScheme.primary),
                              onPressed: () =>
                                  openCourseUrl(context, course.url!),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}