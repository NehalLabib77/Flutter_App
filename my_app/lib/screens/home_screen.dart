// Home screen — first tab of the bottom-nav shell.
//
// Layout, top-to-bottom:
//   1. AppBar (theme-driven navy with brand mark + optional "Sign in" CTA).
//   2. HeroBanner greeting that adapts to signed-in vs guest.
//   3. EduSearchBar (routes the query to the "For you" goal-search).
//   4. SectionHeader + horizontal rail of CourseRowCard for "Popular right now".
//   5. SectionHeader + horizontal rail of CourseRowCard for "Top rated".
//
// All data flows through [CourseProvider] (popular + top rated lists).
// Pull-to-refresh re-runs both providers in parallel. Tapping a card
// pushes the course-details route. No business logic is touched here —
// this screen only lays out widgets from the shared design vocabulary.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../widgets/design.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _searchCtrl;
  late final FocusNode _searchFocus;
  Timer? _welcomeTimer;
  int? _welcomeUserId;
  int? _welcomeLoadingUserId;
  bool _showWelcome = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    _searchFocus = FocusNode();
    // Kick off both providers in parallel — they're independently cached.
    Future.microtask(() {
      if (!mounted) return;
      final c = context.read<CourseProvider>();
      final preferences = context.read<PreferenceProvider>().preferences;
      c.loadPopular(preferences: preferences);
      c.loadTopRated(preferences: preferences);
    });
  }

  @override
  void dispose() {
    _welcomeTimer?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadWelcomeForUser(int? userId) async {
    _welcomeTimer?.cancel();
    _welcomeLoadingUserId = userId;

    if (userId == null) {
      if (!mounted) return;
      setState(() {
        _welcomeUserId = null;
        _showWelcome = false;
      });
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final key = 'home_welcome_seen_user_$userId';
    final alreadySeen = prefs.getBool(key) ?? false;
    if (!mounted || _welcomeLoadingUserId != userId) return;

    if (alreadySeen) {
      setState(() {
        _welcomeUserId = userId;
        _showWelcome = false;
      });
      return;
    }

    // Mark it before displaying so an app restart during the short welcome
    // does not make the same account see it repeatedly. The card itself stays
    // visible for this first Home visit, then disappears automatically.
    await prefs.setBool(key, true);
    if (!mounted || _welcomeLoadingUserId != userId) return;
    setState(() {
      _welcomeUserId = userId;
      _showWelcome = true;
    });
    _welcomeTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || _welcomeUserId != userId) return;
      setState(() => _showWelcome = false);
    });
  }

  /// Push the "For you" tab with the user's query pre-filled so the goal
  /// search on that screen picks it up and runs immediately. We route to
  /// the existing `/recommendations` tab rather than introducing a new
  /// search screen — the goal-search flow already lives there.
  void _submitSearch(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    // Drop focus before navigation so the keyboard isn't left floating
    // over the pushed screen for the brief moment before it builds.
    _searchFocus.unfocus();
    Navigator.of(
      context,
    ).pushNamed(AppRoutes.recommendations, arguments: {'query': q});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Hot-reload-safe fallback: if either list is empty (e.g. after a
    // hot reload that wiped provider state but never re-ran initState),
    // re-issue the fetches so the rails are not stuck on the empty /
    // retry placeholder.
    //
    // CRITICAL: must NOT call loadPopular()/loadTopRated() synchronously
    // here — they call notifyListeners() at the start, and
    // didChangeDependencies() runs *during* the build phase, which
    // throws "setState() or markNeedsBuild() called during build".
    // Defer to the post-frame callback so the first build completes
    // before the provider is told to repaint.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<CourseProvider>();
      final preferences = context.read<PreferenceProvider>().preferences;
      if (c.popular.isEmpty && !c.loadingPopular) {
        c.loadPopular(preferences: preferences);
      }
      if (c.topRated.isEmpty && !c.loadingTopRated) {
        c.loadTopRated(preferences: preferences);
      }
    });
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
    final userId = user?.id;
    if (userId != null &&
        _welcomeUserId != userId &&
        _welcomeLoadingUserId != userId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadWelcomeForUser(userId);
      });
    } else if (userId == null && (_welcomeUserId != null || _showWelcome)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadWelcomeForUser(null);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.explore_rounded, color: Colors.white, size: 22),
            SizedBox(width: Spacing.xs),
            Flexible(
              child: Text(
                'EduCompass',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 19,
                  letterSpacing: 0.1,
                ),
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
                icon: const Icon(
                  Icons.login_rounded,
                  size: 18,
                  color: Colors.white,
                ),
                label: const Text(
                  'Sign in',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          final preferences = context.read<PreferenceProvider>().preferences;
          await Future.wait([
            context.read<CourseProvider>().loadPopular(
              preferences: preferences,
            ),
            context.read<CourseProvider>().loadTopRated(
              preferences: preferences,
            ),
          ]);
        },
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(0, Spacing.md, 0, Spacing.xl),
          children: [
            if (!isGuest && _showWelcome) ...[
              ResponsiveContent(
                maxWidth: 1120,
                child: HeroBanner(
                  eyebrow: 'WELCOME',
                  title: 'Hi $displayName 👋',
                  subtitle:
                      'Your preferences are ready. We’ll use them to shape '
                      'the courses you see.',
                  icon: Icons.school_rounded,
                  onTap: () =>
                      Navigator.of(context).pushNamed(AppRoutes.profile),
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],
            // Search is the permanent first element on Home after the one-time
            // welcome disappears.
            // the goal-search flow on the "For you" tab. Wrapped in a
            // padding that mirrors the rest of the page so it lines up
            // with the hero block edges.
            ResponsiveContent(
              maxWidth: 1120,
              child: EduSearchBar(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                hint: 'Search courses, skills, goals…',
                onSubmitted: _submitSearch,
                onClear: () => _searchCtrl.clear(),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            ResponsiveContent(
              maxWidth: 1120,
              padding: EdgeInsets.zero,
              child: _Section(
              title: 'Popular right now',
              subtitle: 'Trending courses, re-ranked for your interests',
              icon: Icons.local_fire_department_rounded,
              courses: courses.popular,
              loading: courses.loadingPopular,
              errorMessage: courses.popularError,
              onRetry: () => context.read<CourseProvider>().loadPopular(
                preferences: context.read<PreferenceProvider>().preferences,
              ),
            ),
            ),
            const SizedBox(height: Spacing.md),
            ResponsiveContent(
              maxWidth: 1120,
              padding: EdgeInsets.zero,
              child: _Section(
              title: 'Top rated',
              subtitle: 'Strong ratings, adjusted to your preferences',
              icon: Icons.star_rate_rounded,
              courses: courses.topRated,
              loading: courses.loadingTopRated,
              errorMessage: courses.topRatedError,
              onRetry: () => context.read<CourseProvider>().loadTopRated(
                preferences: context.read<PreferenceProvider>().preferences,
              ),
            ),
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        final cardWidth = (viewport * (viewport < 420 ? 0.86 : 0.72)).clamp(276.0, 372.0).toDouble();
        final baseHeight = (cardWidth * 0.66).clamp(190.0, 246.0).toDouble();
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        final scaleExtra = ((textScale - 1.0).clamp(0.0, 2.0) * 56).toDouble();
        final railHeight = (baseHeight + scaleExtra)
            .clamp(baseHeight, 340.0)
            .toDouble();

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
            SizedBox(
              height: railHeight,
              child: courses.isEmpty
                  ? _EmptyOrLoading(
                      loading: loading,
                      errorMessage: errorMessage,
                      onRetry: onRetry,
                    )
                  : ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                      ),
                      itemCount: courses.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: Spacing.md),
                      itemBuilder: (_, i) {
                        final course = courses[i];
                        return SizedBox(
                          width: cardWidth,
                          child: _HomeCourseImageCard(
                            course: course,
                            onTap: () => _open(context, course),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _HomeCourseImageCard extends StatelessWidget {
  const _HomeCourseImageCard({
    required this.course,
    required this.onTap,
  });

  final Course course;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final provider = (course.provider ?? '').trim();
    final subject = (course.subject ?? '').trim();
    final level = (course.level ?? '').trim();

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.xl),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: 0.75),
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              CourseBackgroundImage(
                course: course,
                borderRadius: BorderRadius.circular(Radii.xl),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.xl),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.0, 0.38, 0.72, 1.0],
                    colors: [
                      Colors.black.withValues(alpha: 0.12),
                      Colors.black.withValues(alpha: 0.18),
                      Colors.black.withValues(alpha: 0.58),
                      Colors.black.withValues(alpha: 0.90),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: Spacing.md,
                left: Spacing.md,
                right: Spacing.md,
                child: Row(
                  children: [
                    if (course.rating != null)
                      _OverlayBadge(
                        icon: Icons.star_rounded,
                        label: course.rating!.toStringAsFixed(1),
                        iconColor: const Color(0xFFFFC857),
                      ),
                    const Spacer(),
                    if (course.isFree)
                      const _OverlayBadge(
                        icon: Icons.bolt_rounded,
                        label: 'FREE',
                        iconColor: Color(0xFF7EE2B8),
                      ),
                    if (course.url != null && course.url!.trim().isNotEmpty) ...[
                      const SizedBox(width: Spacing.xs),
                      Material(
                        color: Colors.black.withValues(alpha: 0.35),
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Open course website',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.open_in_new_rounded,
                            color: Colors.white,
                            size: 19,
                          ),
                          onPressed: () => openCourseUrl(context, course.url!),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Positioned(
                left: Spacing.lg,
                right: Spacing.lg,
                bottom: Spacing.lg,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (provider.isNotEmpty)
                      Text(
                        provider.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        ),
                      ),
                    if (provider.isNotEmpty) const SizedBox(height: 5),
                    Text(
                      course.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        height: 1.08,
                        shadows: const [
                          Shadow(
                            color: Color(0x66000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Wrap(
                      spacing: Spacing.xs,
                      runSpacing: Spacing.xs,
                      children: [
                        if (level.isNotEmpty)
                          _TextOverlayPill(
                            icon: Icons.stairs_rounded,
                            text: level,
                          ),
                        if (subject.isNotEmpty)
                          _TextOverlayPill(
                            icon: Icons.school_outlined,
                            text: subject,
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

class _OverlayBadge extends StatelessWidget {
  const _OverlayBadge({
    required this.icon,
    required this.label,
    required this.iconColor,
  });

  final IconData icon;
  final String label;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _TextOverlayPill extends StatelessWidget {
  const _TextOverlayPill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.48;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
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
