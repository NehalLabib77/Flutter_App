/// Single course view: rounded hero image, provider / level pills,
/// title with favorite + share, rating / level stat chips, "About this
/// course" with read more, "What you will learn" skills wrap,
/// "You might also like" horizontal rail, and a sticky bottom CTA
/// (`open_in_new` + `Enroll now`).
///
/// The public API (`CourseDetailsScreen({required String courseId})`)
/// is unchanged so the route map in `app.dart` keeps wiring the screen
/// in the exact same way. Every existing interaction — favorite
/// toggle, enroll / paid checkout, progress slider, unenroll,
/// open-course-url, progress persistence, remote enrollment mirror —
/// is preserved.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../services/enrollment_service.dart';
import '../theme.dart';
import '../widgets/design.dart';
import '../widgets/login_required.dart';
import 'course_lessons_screen.dart';
import 'mock_payment_screen.dart';

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
  bool _enrolledRemote = false;
  String? _error;

  final ScrollController _scroll = ScrollController();

  /// Local "Read more" toggle for the description block.
  bool _expandedAbout = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
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
      if (mounted) {
        try {
          final enrolled = await EnrollmentService().isEnrolled(course.id);
          if (!mounted) return;
          setState(() => _enrolledRemote = enrolled);
        } catch (_) {
          // Non-fatal — the local prefs flag still drives the UI.
        }
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
    final ok = await requireLogin(context, action: 'save favorites');
    if (!ok) return;
    if (!mounted) return;
    try {
      await context.read<UserProvider>().toggleFavorite(c);
      if (!mounted) return;
      final isFav = context.read<UserProvider>().isFavorite(c.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isFav
                ? '"${c.name}" added to favorites.'
                : '"${c.name}" removed from favorites.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update favorites: $e')));
    }
  }

  Future<void> _updateProgress(double value) async {
    final c = _course;
    if (c == null || _savingProgress) return;
    setState(() => _savingProgress = true);
    try {
      await context.read<UserProvider>().setProgress(c.id, value.round());
    } finally {
      if (mounted) setState(() => _savingProgress = false);
    }
  }

  /// Parses a price string ("Free", "BDT 500", "$49.99", "49.99") into a
  /// `double`. Returns `0.0` for free / blank / unparseable values.
  double _parseAmount(String? raw) {
    final s = (raw ?? '').toString();
    final m = RegExp(r'(\d+(?:[.,]\d+)?)').firstMatch(s);
    if (m == null) return 0.0;
    final n = m.group(1)!.replaceAll(',', '.');
    return double.tryParse(n) ?? 0.0;
  }

  Future<void> _enroll() async {
    final c = _course;
    if (c == null) return;
    final ok = await requireLogin(
      context,
      action: c.isFree
          ? 'enroll in free courses'
          : 'enroll in this paid course',
    );
    if (!ok) return;
    if (!mounted) return;
    final enrolled = context.read<EnrollmentProvider>();
    if (enrolled.isEnrolled(c.id) || _enrolledRemote) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Already enrolled in "${c.name}".')),
      );
      return;
    }
    final parsedAmount = _parseAmount(c.price);
    final amount = c.isFree ? 0.0 : (parsedAmount > 0 ? parsedAmount : 0.01);
    if (!c.isFree) {
      final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          // Route-pushed screens live above the root provider scope,
          // so they cannot resolve `ApiClient`, `DeepLinkService`,
          // `EnrollmentProvider`, etc. unless we re-wrap them here.
          // Without this the payment screen crashes with
          // "Could not find the correct Provider<DeepLinkService>"
          // the moment it calls `context.read<DeepLinkService>()` in
          // `initState()`. Same pattern as the other route-pushed
          // screens (CourseLessonsScreen, LearningPathDetailScreen).
          builder: (_) => wrapWithProviders(
            context,
            MockPaymentScreen(
              courseId: c.id,
              courseName: c.name,
              amount: amount,
              // Flag the payment screen with the course's free/paid
              // state so it can refuse to take the free-enrollment
              // shortcut when the backend is misconfigured (e.g. SSLC
              // credentials missing on Render → free provider returns
              // a "validated" session for a paid course). Without
              // this, paying users would silently get free enrollment.
              isCourseFree: c.isFree,
            ),
          ),
        ),
      );
      if (!mounted) return;
      if (result?['success'] != true) return;
      if (!mounted) return;
      enrolled.refreshFromRemote();
    }
    if (!mounted) return;
    await enrolled.enroll(c.id);
    if (!mounted) return;
    setState(() => _enrolledRemote = true);
    await context.read<UserProvider>().setProgress(c.id, 0);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.check_circle, size: 60),
          title: const Text('Enrollment Successful'),
          content: Text('You are now enrolled in ${c.name}.'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Start Course'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmUnenroll() async {
    final c = _course;
    if (c == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Unenroll from "${c.name}"?'),
          content: const Text(
            'You will lose access to the course on every device. '
            'You can re-enroll at any time.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Unenroll'),
            ),
          ],
        );
      },
    );
    if (!mounted) return;
    if (confirmed != true) return;
    final messenger = ScaffoldMessenger.of(context);
    String? syncError;
    await context.read<EnrollmentProvider>().drop(
      c.id,
      onSyncError: (e, [StackTrace? _]) {
        syncError ??= e.toString();
      },
    );
    if (!mounted) return;
    setState(() => _enrolledRemote = false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          syncError == null
              ? 'Unenrolled from "${c.name}".'
              : 'Unenrolled locally — could not sync to server.',
        ),
      ),
    );
  }

  Future<void> _shareCourse() async {
    final c = _course;
    if (c == null) return;
    final url = c.url;
    if (url == null || url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Course link copied to clipboard.')),
    );
  }

@override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null || _course == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error ?? 'Course not found',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final c = _course!;
    final user = context.watch<UserProvider>();
    final enrolled = context.watch<EnrollmentProvider>();
    final isFavorite = user.isFavorite(c.id);
    final isEnrolled = enrolled.isEnrolled(c.id) || _enrolledRemote;
    final progress = user.progressFor(c.id).toDouble();

    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        title: Text(
          c.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (isEnrolled)
            IconButton(
              tooltip: 'Unenroll',
              onPressed: _confirmUnenroll,
              icon: const Icon(Icons.logout_rounded),
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.only(bottom: 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      Spacing.md,
                      Spacing.lg,
                      Spacing.md,
                    ),
                    child: _HeroImage(course: c),
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: _PillRow(
                      course: c,
                      isEnrolled: isEnrolled,
                      isFavorite: isFavorite,
                      onFavorite: _toggleFavorite,
                      onShare: (c.url == null || c.url!.isEmpty)
                          ? null
                          : _shareCourse,
                    ),
                  ),
                  const SizedBox(height: Spacing.md),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: _TitleBlock(course: c),
                  ),
                  const SizedBox(height: Spacing.md),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: _StatsRow(course: c),
                  ),
                  const SizedBox(height: Spacing.md),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: _PriceRow(course: c),
                  ),
                  const SizedBox(height: Spacing.lg),
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: Spacing.lg),
                    child: _AboutCard(
                      description: c.description ?? '',
                      expanded: _expandedAbout,
                      onToggle: () =>
                          setState(() => _expandedAbout = !_expandedAbout),
                    ),
                  ),
                  if (c.skills.isNotEmpty) ...[
                    const SizedBox(height: Spacing.lg),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      child: _SkillsCard(skills: c.skills),
                    ),
                  ],
                  if (isEnrolled) ...[
                    const SizedBox(height: Spacing.lg),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      child: _ProgressCard(
                        value: progress,
                        saving: _savingProgress,
                        onChanged: _updateProgress,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    Padding(
                      padding:
                          const EdgeInsets.symmetric(horizontal: Spacing.lg),
                      child: FilledButton.tonalIcon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => wrapWithProviders(
                              context,
                              CourseLessonsScreen(courseId: c.id),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.play_circle_filled_rounded),
                        label: const Text('Watch course lessons'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    if (c.url != null && c.url!.isNotEmpty)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(horizontal: Spacing.lg),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: () => openCourseUrl(context, c.url!),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text(
                                'Open original course on the web'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                          ),
                        ),
                      ),
                  ],
                  if (_similar.isNotEmpty) ...[
                    const SizedBox(height: Spacing.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.lg,
                      ),
                      child: _SimilarHeader(remaining: _similar.length),
                    ),
                    const SizedBox(height: Spacing.md),
                    _SimilarRail(courses: _similar),
                  ],
                  const SizedBox(height: Spacing.xl),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BottomCTA(
              course: c,
              isEnrolled: isEnrolled,
              onPrimary: _enroll,
              onSecondary: (c.url == null || c.url!.isEmpty)
                  ? null
                  : () => openCourseUrl(context, c.url!),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero image
// ---------------------------------------------------------------------------

class _HeroImage extends StatelessWidget {
  const _HeroImage({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final url = course.imageUrl ?? '';
    final radius = BorderRadius.circular(Radii.lg);
    return ClipRRect(
      borderRadius: radius,
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: url.isEmpty
            ? _heroFallback(scheme)
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) => _heroFallback(scheme),
                errorWidget: (_, _, _) => _heroFallback(scheme),
              ),
      ),
    );
  }

  Widget _heroFallback(ColorScheme scheme) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primaryContainer, scheme.tertiaryContainer],
          ),
        ),
        child: Icon(
          Icons.menu_book_rounded,
          size: 72,
          color: scheme.onPrimaryContainer.withValues(alpha: 0.6),
        ),
      );
}

// ---------------------------------------------------------------------------
// Provider / bookmark pills + favorite / share row
// ---------------------------------------------------------------------------

class _PillRow extends StatelessWidget {
  const _PillRow({
    required this.course,
    required this.isEnrolled,
    required this.isFavorite,
    required this.onFavorite,
    required this.onShare,
  });

  final Course course;
  final bool isEnrolled;
  final bool isFavorite;
  final VoidCallback onFavorite;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final providerLabel = (course.provider ?? '').trim().isNotEmpty
        ? course.provider!
        : 'coursera';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Pill(
          text: providerLabel,
          icon: Icons.school_rounded,
          color: scheme.primary,
        ),
        const SizedBox(width: Spacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Icon(
            Icons.bookmark_outline_rounded,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        if (onShare != null)
          IconButton(
            tooltip: 'Share',
            onPressed: onShare,
            icon: Icon(Icons.ios_share_rounded, color: scheme.onSurface),
          ),
        const SizedBox(width: Spacing.xs),
        IconButton(
          tooltip: isFavorite ? 'Remove favorite' : 'Add favorite',
          onPressed: onFavorite,
          icon: Icon(
            isFavorite
                ? Icons.favorite_rounded
                : Icons.favorite_outline_rounded,
            color: isFavorite ? Colors.redAccent : scheme.onSurface,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Title + meta line
// ---------------------------------------------------------------------------

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final meta = <String>[
      if ((course.provider ?? '').trim().isNotEmpty) course.provider!,
      if ((course.level ?? '').trim().isNotEmpty) course.level!,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          course.name,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
            height: 1.15,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Text(
          meta.join(' • '),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rating + level stat chips
// ---------------------------------------------------------------------------

class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final rating = course.rating;
    final level = (course.level ?? '').trim();
    if (rating == null && level.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        if (rating != null)
          Expanded(
            child: StatChip(
              icon: Icons.star_rounded,
              label: 'rating',
              value: rating.toStringAsFixed(1),
            ),
          ),
        if (rating != null && level.isNotEmpty)
          const SizedBox(width: Spacing.sm),
        if (level.isNotEmpty)
          Expanded(
            child: StatChip(
              icon: Icons.signal_cellular_alt_rounded,
              label: 'level',
              value: level,
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// "Paid one-time" price row
// ---------------------------------------------------------------------------

class _PriceRow extends StatelessWidget {
  const _PriceRow({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final priceLabel =
        course.isFree ? 'Free' : 'Paid';
    final sub = course.isFree
        ? 'Free for everyone'
        : ((course.price ?? '').trim().isNotEmpty
            ? course.price!.trim()
            : 'one-time');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.6)),
        const SizedBox(height: Spacing.md),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              priceLabel,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: Spacing.sm),
            Flexible(
              child: Text(
                sub,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// About this course card
// ---------------------------------------------------------------------------

class _AboutCard extends StatelessWidget {
  const _AboutCard({
    required this.description,
    required this.expanded,
    required this.onToggle,
  });

  final String description;
  final bool expanded;
  final VoidCallback onToggle;

  static const int _collapsedLines = 4;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (description.trim().isEmpty) {
      return EduCard(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.menu_book_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'About this course',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    'No description provided for this course yet.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return EduCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: Spacing.md),
              Text(
                'About this course',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          AnimatedCrossFade(
            firstChild: Text(
              'Description: $description',
              maxLines: _collapsedLines,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            secondChild: Text(
              'Description: $description',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            crossFadeState:
                expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: EduDurations.medium,
            sizeCurve: Curves.easeInOut,
          ),
          const SizedBox(height: Spacing.xs),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onToggle,
              icon: Icon(
                expanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
              ),
              label: Text(expanded ? 'Read less' : 'Read more'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// What you will learn card
// ---------------------------------------------------------------------------

class _SkillsCard extends StatelessWidget {
  const _SkillsCard({required this.skills});
  final List<String> skills;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline_rounded, color: scheme.primary),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  'What you will learn',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                'skills',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          for (var i = 0; i < skills.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(Icons.check_rounded, size: 18, color: scheme.primary),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    skills[i],
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (i != skills.length - 1) const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress card (signed-in enrolled only)
// ---------------------------------------------------------------------------

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.value,
    required this.saving,
    required this.onChanged,
  });
  final double value;
  final bool saving;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EduCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${value.round()}% complete',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (saving)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          Slider(
            value: value.clamp(0, 100),
            max: 100,
            divisions: 20,
            label: '${value.round()}%',
            onChanged: saving ? null : onChanged,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// "You might also like" header + horizontal rail
// ---------------------------------------------------------------------------

class _SimilarHeader extends StatelessWidget {
  const _SimilarHeader({required this.remaining});
  final int remaining;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.auto_awesome_rounded,
            size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            'You might also like',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        if (remaining > 0)
          TextButton(
            onPressed: () =>
                Navigator.of(context).pushNamed(AppRoutes.recommendations),
            child: const Text('View all'),
          ),
      ],
    );
  }
}

class _SimilarRail extends StatelessWidget {
  const _SimilarRail({required this.courses});
  final List<Course> courses;

  static const int _maxVisible = 6;

  @override
  Widget build(BuildContext context) {
    final visible = courses.take(_maxVisible).toList();
    return SizedBox(
      height: 200,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
        itemBuilder: (context, i) => _SimilarCard(course: visible[i]),
      ),
    );
  }
}

class _SimilarCard extends StatelessWidget {
  const _SimilarCard({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 168,
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).pushReplacementNamed(
            AppRoutes.courseDetails,
            arguments: course.id,
          ),
          child: Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: CourseThumbnail(
                      course: course,
                      size: 156,
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  course.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                if ((course.provider ?? '').trim().isNotEmpty)
                  Text(
                    course.provider!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sticky bottom CTA
// ---------------------------------------------------------------------------

class _BottomCTA extends StatelessWidget {
  const _BottomCTA({
    required this.course,
    required this.isEnrolled,
    required this.onPrimary,
    required this.onSecondary,
  });

  final Course course;
  final bool isEnrolled;
  final VoidCallback onPrimary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final primaryLabel = isEnrolled ? 'Continue learning' : 'Enroll now';
    final primaryIcon =
        isEnrolled ? Icons.play_arrow_rounded : Icons.lock_outline_rounded;

    return Material(
      color: scheme.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.md,
          ),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border(
              top: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: 0.6),
                width: 1,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: scheme.outlineVariant.withValues(alpha: 0.7),
                    width: 1.2,
                  ),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: IconButton(
                  tooltip: 'Open course page',
                  onPressed: onSecondary,
                  icon: Icon(
                    Icons.open_in_new_rounded,
                    color: scheme.onSurface,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: onPrimary,
                    icon: Icon(primaryIcon, size: 20),
                    label: Text(
                      primaryLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.navy,
                      foregroundColor: Colors.white,
                      shape: const RoundedRectangleBorder(
                        borderRadius: Radii.pill,
                      ),
                      textStyle: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// end_marker
