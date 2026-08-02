// Home screen — first tab of the bottom-nav shell.
//
// Layout, top-to-bottom:
//   1. AppBar (title + optional "Sign in" for guests).
//   2. HeroBanner greeting that adapts to signed-in vs guest.
//   3. SearchBar (routes to search / browse screen).
//   4. SectionHeader + horizontal rail of CourseRowCard for "Popular right now".
//   5. SectionHeader + horizontal rail of CourseRowCard for "Top rated".
//
// All data flows through [CourseProvider] (popular + top rated lists).
// Pull-to-refresh re-runs both providers in parallel. Tapping a card
// pushes the course-details route. No business logic is touched here —
// this screen only lays out widgets from the shared design vocabulary.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../theme.dart';
import '../widgets/design.dart';
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
    // Kick off both providers in parallel — they're independently cached.
    Future.microtask(() {
      if (!mounted) return;
      final c = context.read<CourseProvider>();
      c.loadPopular();
      c.loadTopRated();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Hot-reload-safe fallback: if either list is empty (e.g. after a
    // hot reload that wiped provider state but never re-ran initState),
    // re-issue the fetches so the rails are not stuck on the empty /
    // retry placeholder.
    final c = context.read<CourseProvider>();
    if (c.popular.isEmpty && !c.loadingPopular) {
      c.loadPopular();
    }
    if (c.topRated.isEmpty && !c.loadingTopRated) {
      c.loadTopRated();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final courses = context.watch<CourseProvider>();
    final user = auth.user;

    // Use the part of the email before '@' as a fallback display name.
    final displayName = (user?.fullName ?? '').trim().isNotEmpty
        ? user!.fullName.split(' ').first
        : (user?.email.split('@').first ?? '');

    final isGuest = user == null;
    final eyebrow = isGuest ? 'EDUCOMPASS' : 'TODAY';
    final title = isGuest ? 'Welcome to EduCompass' : 'Hi $displayName 👋';
    final subtitle = isGuest
        ? 'Sign in for personalised picks, or browse as a guest.'
        : 'What will you learn today?';

    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        backgroundColor: AppColors.navy,
        foregroundColor: Colors.white,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: const Row(
          children: [
            Icon(
              Icons.explore_rounded,
              color: Colors.white,
              size: 22,
            ),
            SizedBox(width: Spacing.xs),
            Text(
              'EduCompass',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 19,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
        actions: [
          if (isGuest)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.xs),
              child: TextButton.icon(
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
                icon: const Icon(Icons.login_rounded, size: 18, color: Colors.white),
                label: const Text(
                  'Sign in',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
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
          padding: const EdgeInsets.symmetric(vertical: Spacing.md),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              child: HeroBanner(
                eyebrow: eyebrow,
                title: title,
                subtitle: subtitle,
                icon: Icons.school_rounded,
                onTap: () {
                  // Tap = open profile / browse. Guests → login, signed-in
                  // users → profile tab via shell.
                  if (isGuest) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const LoginScreen()),
                    );
                  } else {
                    Navigator.of(context).pushNamed(AppRoutes.profile);
                  }
                },
              ),
            ),
            const SizedBox(height: Spacing.lg),
            _Section(
              title: 'Popular right now',
              subtitle: 'What other learners are enrolling in this week',
              icon: Icons.local_fire_department_rounded,
              courses: courses.popular,
              loading: courses.loadingPopular,
              errorMessage: courses.popularError,
              onRetry: () => context.read<CourseProvider>().loadPopular(),
            ),
            const SizedBox(height: Spacing.md),
            _Section(
              title: 'Top rated',
              subtitle: 'Highest-rated picks across every subject',
              icon: Icons.star_rate_rounded,
              courses: courses.topRated,
              loading: courses.loadingTopRated,
              errorMessage: courses.topRatedError,
              onRetry: () => context.read<CourseProvider>().loadTopRated(),
            ),
            const SizedBox(height: Spacing.xl),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.courses,
    required this.loading,
    required this.onRetry,
    this.errorMessage,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final List<Course> courses;
  final bool loading;
  final Future<void> Function() onRetry;
  final String? errorMessage;

  void _open(BuildContext context, Course course) {
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.courseDetails, arguments: course.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          icon: icon,
          title: title,
          subtitle: subtitle,
          trailing: IconBadge(
            icon: Icons.arrow_forward_rounded,
            size: 32,
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer,
          ),
          onTrailingTap: () {
            Navigator.of(context).pushNamed(AppRoutes.recommendations);
          },
        ),
        const SizedBox(height: Spacing.sm),
        // Horizontal rail of cards. We give the rail an explicit height so
        // the horizontal ListView has a bounded layout context — wrapping
        // a viewport in IntrinsicHeight is illegal (the viewport cannot
        // answer intrinsic-dimension queries), which used to crash the
        // frame with a 2px RenderFlex overflow on small screens.
        SizedBox(
          height: 168,
          child: courses.isEmpty
              ? _EmptyOrLoading(
                  loading: loading,
                  errorMessage: errorMessage,
                  onRetry: onRetry,
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                  itemCount: courses.length,
                  separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
                  itemBuilder: (_, i) {
                    final c = courses[i];
                    return SizedBox(
                      width: 320,
                      child: CourseRowCard(
                        title: c.name,
                        provider: c.provider,
                        level: c.level,
                        subject: c.subject,
                        skills: c.skills,
                        rating: c.rating,
                        isFree: c.isFree,
                        thumbnail: CourseThumbnail(course: c, size: 64),
                        trailing: c.url != null && c.url!.isNotEmpty
                            ? IconButton(
                                tooltip: 'Open in browser',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minHeight: 32,
                                  minWidth: 32,
                                ),
                                icon: Icon(
                                  Icons.open_in_new_rounded,
                                  color: scheme.primary,
                                ),
                                onPressed: () => openCourseUrl(context, c.url!),
                              )
                            : null,
                        onTap: () => _open(context, c),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _EmptyOrLoading extends StatelessWidget {
  const _EmptyOrLoading({
    required this.loading,
    required this.onRetry,
    this.errorMessage,
  });
  final bool loading;
  final Future<void> Function() onRetry;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (errorMessage != null && errorMessage!.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, color: theme.colorScheme.error),
            const SizedBox(height: Spacing.sm),
            Text(
              errorMessage!,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Spacing.sm),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
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
