/// Single course view: editorial hero, About-with-read-more, scrollable
/// skills box, horizontal similar-courses rail, and a sticky bottom CTA
/// that collapses on scroll but never disappears.
///
/// The public API (`CourseDetailsScreen({required String courseId})`) is
/// unchanged so the route map in `app.dart` keeps wiring the screen in
/// the exact same way. Every existing interaction — favorite toggle,
/// enroll / paid checkout, progress slider, unenroll, open-course-url,
/// progress persistence, remote enrollment mirror — is preserved.
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

  /// Scroll controller. Drives the compact-CTA switch and the AppBar
  /// title swap once the hero has scrolled off.
  final ScrollController _scroll = ScrollController();

  /// True after the user scrolls past the hero section. Used to:
  ///  * swap the AppBar title in (when the hero has scrolled off),
  ///  * collapse the CTA height slightly (without hiding it),
  ///  * hide the secondary "Open course page" button when compact.
  bool _compact = false;

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
    final shouldCompact = _scroll.offset > 220;
    if (shouldCompact != _compact) {
      setState(() => _compact = shouldCompact);
    }
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
      // Check Firestore for an existing enrollment so a second device
      // (or a re-install on the same device) reflects the paid state.
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
    // For any non-free course we MUST route through the mock checkout,
    // even when the price string is missing or unparseable — otherwise
    // the user would be silently auto-enrolled without paying.
    final parsedAmount = _parseAmount(c.price);
    final amount = c.isFree ? 0.0 : (parsedAmount > 0 ? parsedAmount : 0.01);
    if (!c.isFree) {
      // Paid course — run the mock checkout before adding the course.
      final result = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => MockPaymentScreen(
            courseId: c.id,
            courseName: c.name,
            amount: amount,
          ),
        ),
      );
      if (!mounted) return;
      if (result?['success'] != true) return;
      // Persist the enrollment to Firestore so it survives device
      // changes and re-installs. The local prefs flag is still useful
      // for offline "My Courses" lists. Field reads use safe fallbacks
      // because the mock payment screen returns dynamic values that
      // can legitimately be null (e.g. free checkout omits a tx id).
      try {
        await EnrollmentService().saveEnrollment(
          courseId: (result!['courseId'] ?? c.id).toString(),
          paymentMethod: (result['paymentMethod'] ?? 'unknown').toString(),
          transactionId: (result['transactionId'] ?? '').toString(),
        );
      } catch (e) {
        // Don't bail out — fall through to local enrollment so the
        // user still sees the course in "My Courses". The Firestore
        // sync error is surfaced as a SnackBar but never blocks the
        // UX.
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved locally — remote sync failed: $e')),
        );
      }
    }
    if (!mounted) return;
    await enrolled.enroll(c.id);
    if (!mounted) return;
    setState(() => _enrolledRemote = true);
    // Seed progress so the new course shows 0% in the slider.
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

  /// Confirms with the user, then drops the course from every store
  /// via [EnrollmentProvider.drop]. The remote sync errors are
  /// surfaced as a single SnackBar at the end — the local UI state
  /// always reflects the drop.
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
    // share_plus is not in pubspec — fall back to the clipboard so the
    // user can paste the link wherever they want.
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
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          _HeroSliver(
            course: c,
            isFavorite: isFavorite,
            isEnrolled: isEnrolled,
            compact: _compact,
            onBack: () => Navigator.of(context).maybePop(),
            onFavorite: _toggleFavorite,
            onUnenroll: isEnrolled ? _confirmUnenroll : null,
            onShare: (c.url == null || c.url!.isEmpty) ? null : _shareCourse,
          ),
          SliverToBoxAdapter(child: _MetadataStrip(course: c)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.lg,
              Spacing.lg,
              Spacing.xxl,
            ),
            sliver: SliverList.list(
              children: [
                _AboutSection(
                  description: c.description ?? '',
                  expanded: _expandedAbout,
                  onToggle: () =>
                      setState(() => _expandedAbout = !_expandedAbout),
                ),
                if (c.skills.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xl),
                  const _SectionTitle(
                    icon: Icons.bolt_rounded,
                    title: 'What you’ll learn',
                    subtitle: 'Skills this course builds across.',
                  ),
                  const SizedBox(height: Spacing.md),
                  SizedBox(
                    height: _SkillsGrid._boxHeight,
                    child: _SkillsGrid(skills: c.skills),
                  ),
                ],
                if (isEnrolled) ...[
                  const SizedBox(height: Spacing.xl),
                  const _SectionTitle(
                    icon: Icons.insights_rounded,
                    title: 'Your progress',
                  ),
                  const SizedBox(height: Spacing.md),
                  _ProgressCard(
                    value: progress,
                    saving: _savingProgress,
                    onChanged: _updateProgress,
                  ),
                  const SizedBox(height: Spacing.md),
                  FilledButton.tonalIcon(
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
                  const SizedBox(height: Spacing.md),
                  if (c.url != null && c.url!.isNotEmpty)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => openCourseUrl(context, c.url!),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Open original course on the web'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                      ),
                    ),
                ],
                if (_similar.isNotEmpty) ...[
                  const SizedBox(height: Spacing.xl),
                  const _SectionTitle(
                    icon: Icons.auto_awesome_rounded,
                    title: 'Similar courses',
                    subtitle: 'More picks based on this course.',
                  ),
                  const SizedBox(height: Spacing.md),
                  _SimilarRail(courses: _similar),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _BottomCTA(
        course: c,
        isEnrolled: isEnrolled,
        compact: _compact,
        onPrimary: _enroll,
        onSecondary: (c.url == null || c.url!.isEmpty)
            ? null
            : () => openCourseUrl(context, c.url!),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero
// ---------------------------------------------------------------------------

class _HeroSliver extends StatelessWidget {
  const _HeroSliver({
    required this.course,
    required this.isFavorite,
    required this.isEnrolled,
    required this.compact,
    required this.onBack,
    required this.onFavorite,
    required this.onUnenroll,
    required this.onShare,
  });

  final Course course;
  final bool isFavorite;
  final bool isEnrolled;
  final bool compact;
  final VoidCallback onBack;
  final VoidCallback onFavorite;
  final VoidCallback? onUnenroll;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasImage = (course.imageUrl ?? '').isNotEmpty;
    final rating = course.rating;
    final enrolled = course.studentsEnrolled;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 180,
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      leading: _CircleIconButton(
        icon: Icons.arrow_back_rounded,
        onPressed: onBack,
        tooltip: 'Back',
      ),
      actions: [
        if (onUnenroll != null)
          _CircleIconButton(
            icon: Icons.event_busy_rounded,
            onPressed: onUnenroll!,
            tooltip: 'Unenroll',
          ),
        if (onShare != null)
          _CircleIconButton(
            icon: Icons.ios_share_rounded,
            onPressed: onShare!,
            tooltip: 'Share',
          ),
        _CircleIconButton(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          onPressed: onFavorite,
          tooltip: 'Favorite',
          color: isFavorite ? Colors.redAccent : null,
        ),
        const SizedBox(width: Spacing.sm),
      ],
      title: AnimatedSwitcher(
        duration: EduDurations.fast,
        child: compact
            ? Text(
                course.name,
                key: ValueKey(course.id),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : const SizedBox.shrink(key: ValueKey('empty')),
      ),
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          fit: StackFit.expand,
          children: [
            if (hasImage)
              CachedNetworkImage(
                imageUrl: course.imageUrl!,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    Container(color: scheme.surfaceContainerHighest),
                errorWidget: (_, _, _) => Container(
                  color: scheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.menu_book_rounded,
                    size: 64,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              Container(
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
                  color: scheme.onPrimaryContainer.withValues(alpha: 0.5),
                ),
              ),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    Color(0x66000000),
                    Color(0xCC000000),
                  ],
                  stops: [0.0, 0.45, 0.75, 1.0],
                ),
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
                  if (isEnrolled) ...[
                    const _EnrolledPill(),
                    const SizedBox(height: Spacing.sm),
                  ],
                  if (course.subject != null) ...[
                    Pill(text: course.subject!, icon: Icons.school_rounded),
                    const SizedBox(height: Spacing.sm),
                  ],
                  Text(
                    course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Wrap(
                    spacing: Spacing.md,
                    runSpacing: 4,
                    children: [
                      if (course.provider != null)
                        _MetaText(
                          icon: Icons.account_balance_rounded,
                          text: course.provider!,
                        ),
                      if (rating != null)
                        _MetaText(
                          icon: Icons.star_rounded,
                          iconColor: Colors.amber,
                          text:
                              rating.toStringAsFixed(1) +
                              (course.reviewsCount == null
                                  ? ''
                                  : ' (${_formatCount(course.reviewsCount!)})'),
                        ),
                      if (enrolled != null)
                        _MetaText(
                          icon: Icons.people_alt_rounded,
                          text: '${_formatCount(enrolled)} learners',
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EnrolledPill extends StatelessWidget {
  const _EnrolledPill();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.sm, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1B873F),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 14, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'Enrolled',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaText extends StatelessWidget {
  const _MetaText({required this.icon, required this.text, this.iconColor});
  final IconData icon;
  final String text;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: iconColor ?? Colors.white),
        const SizedBox(width: 4),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.color,
  });
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // Keep these compact — the hero AppBar can stack 4 of them plus the
    // leading button on narrow phones, and the default 48dp IconButton
    // width pushes the title text right off-screen and triggers a
    // horizontal RenderFlex overflow in the actions Row.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 20),
        style: IconButton.styleFrom(
          backgroundColor: Colors.black.withValues(alpha: 0.32),
          foregroundColor: Colors.white,
          minimumSize: const Size(36, 36),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Metadata strip
// ---------------------------------------------------------------------------

class _MetadataStrip extends StatelessWidget {
  const _MetadataStrip({required this.course});
  final Course course;

  @override
  Widget build(BuildContext context) {
    final chips = <Widget>[
      StatChip(
        icon: Icons.signal_cellular_alt_rounded,
        label: 'Level',
        value: course.level ?? 'All',
      ),
      const StatChip(
        icon: Icons.public_rounded,
        label: 'Language',
        value: 'English',
      ),
      StatChip(
        icon: Icons.workspace_premium_rounded,
        label: 'Certificate',
        value: course.isFree ? 'No' : 'Yes',
      ),
      const StatChip(
        icon: Icons.bookmark_added_rounded,
        label: 'Mode',
        value: 'Self-paced',
      ),
    ];
    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.md,
        ),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

class _AboutSection extends StatelessWidget {
  const _AboutSection({
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
      return Text(
        'No description provided for this course yet.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'About this course',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Spacing.sm),
        AnimatedCrossFade(
          firstChild: Text(
            description,
            maxLines: _collapsedLines,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          secondChild: Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          crossFadeState: expanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: EduDurations.medium,
          sizeCurve: Curves.easeInOut,
        ),
        const SizedBox(height: Spacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onToggle,
            icon: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
            ),
            label: Text(expanded ? 'Read less' : 'Read more'),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Skills grid
// ---------------------------------------------------------------------------

class _SkillsGrid extends StatelessWidget {
  const _SkillsGrid({required this.skills});
  final List<String> skills;

  // Fixed visual height: the box keeps the page compact regardless of how
  // many skills a course advertises. Anything beyond this view is reached by
  // scrolling inside the box.
  static const double _boxHeight = 168;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Scrollbar(
        thumbVisibility: true,
        radius: const Radius.circular(8),
        child: ListView.separated(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(
            horizontal: Spacing.md,
            vertical: Spacing.sm,
          ),
          itemCount: skills.length,
          separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
          itemBuilder: (context, i) {
            final s = skills[i];
            return Row(
              children: [
                Icon(
                  Icons.check_circle_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Text(
                    s,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Progress
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
// Similar rail
// ---------------------------------------------------------------------------

class _SimilarRail extends StatelessWidget {
  const _SimilarRail({required this.courses});
  final List<Course> courses;

  static const int _maxVisible = 6;

  @override
  Widget build(BuildContext context) {
    final visible = courses.take(_maxVisible).toList();
    final hasMore = courses.length > _maxVisible;
    return SizedBox(
      height: 184,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        itemCount: visible.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(width: Spacing.sm),
        itemBuilder: (context, i) {
          if (hasMore && i == visible.length) {
            return _ViewAllCard(
              remaining: courses.length - _maxVisible,
              onTap: () {
                // Funnel the user into recommendations, which already
                // shows a personalised + popular mix. Keeping the
                // navigation graph inside the existing routes avoids
                // adding a new "similar" page.
                Navigator.of(context).pushNamed(AppRoutes.recommendations);
              },
            );
          }
          return _SimilarCard(course: visible[i]);
        },
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
    final rating = course.rating;
    return SizedBox(
      width: 156,
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(
            context,
          ).pushReplacementNamed(AppRoutes.courseDetails, arguments: course.id),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: CourseThumbnail(
                  course: course,
                  size: 156,
                  borderRadius: BorderRadius.zero,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      course.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    if (course.provider != null)
                      Text(
                        course.provider!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(height: Spacing.xs),
                    Row(
                      children: [
                        if (rating != null) ...[
                          Icon(
                            Icons.star_rounded,
                            size: 14,
                            color: Colors.amber.shade700,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            rating.toStringAsFixed(1),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: Spacing.sm),
                        ],
                        if (course.isFree)
                          const Pill(text: 'FREE', color: Colors.green),
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

class _ViewAllCard extends StatelessWidget {
  const _ViewAllCard({required this.remaining, required this.onTap});
  final int remaining;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: 132,
      child: Material(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Spacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 28,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(height: Spacing.sm),
                Text(
                  'View all',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '+${_formatCount(remaining)} more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
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

/// Sticky bottom CTA that:
///  * respects the device safe area (via [SafeArea]);
///  * never disappears — it only collapses in height when the user
///    scrolls past the hero;
///  * shows the current price / free status;
///  * prioritises the primary Enroll / Continue action.
class _BottomCTA extends StatelessWidget {
  const _BottomCTA({
    required this.course,
    required this.isEnrolled,
    required this.compact,
    required this.onPrimary,
    required this.onSecondary,
  });

  final Course course;
  final bool isEnrolled;
  final bool compact;
  final VoidCallback onPrimary;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final priceLabel = _priceLabel(course);
    final primaryLabel = isEnrolled ? 'Continue learning' : 'Enroll now';
    final primaryIcon = isEnrolled
        ? Icons.play_arrow_rounded
        : Icons.school_rounded;

    return Material(
      color: scheme.surface,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: AnimatedContainer(
          duration: EduDurations.fast,
          curve: Curves.easeOut,
          padding: EdgeInsets.symmetric(
            horizontal: Spacing.lg,
            vertical: compact ? Spacing.sm : Spacing.md,
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
              // Left: price + sub-line. FittedBox keeps it from
              // overflowing the row on narrow phones (e.g. 320dp),
              // and `min: 0` on the inner Flexible lets the sub-line
              // shrink / ellipsise instead of pushing the buttons off
              // screen.
              Flexible(
                fit: FlexFit.loose,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        priceLabel.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: priceLabel.color,
                        ),
                      ),
                      if (!compact)
                        Text(
                          isEnrolled
                              ? 'You have full access'
                              : (course.isFree
                                    ? 'Free for everyone'
                                    : 'One-time payment'),
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
              if (onSecondary != null && !compact) ...[
                const SizedBox(width: Spacing.sm),
                IconButton.filledTonal(
                  tooltip: 'Open course page',
                  onPressed: onSecondary,
                  icon: const Icon(Icons.open_in_new_rounded),
                ),
              ],
              const SizedBox(width: Spacing.sm),
              // The CTA never goes below 96dp width so the icon + label
              // stay legible even on the smallest supported screens.
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 96, minHeight: 48),
                child: FilledButton.icon(
                  onPressed: onPrimary,
                  icon: Icon(primaryIcon),
                  label: Text(
                    primaryLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
                    shape: const RoundedRectangleBorder(
                      borderRadius: Radii.pill,
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

  _PriceLabel _priceLabel(Course c) {
    if (isEnrolled) {
      return const _PriceLabel(label: 'Enrolled', color: Color(0xFF1B873F));
    }
    if (c.isFree) {
      return const _PriceLabel(label: 'FREE', color: Color(0xFF1B873F));
    }
    final raw = c.price;
    if (raw == null || raw.trim().isEmpty) {
      return const _PriceLabel(label: 'Paid', color: null);
    }
    return _PriceLabel(label: raw, color: null);
  }
}

class _PriceLabel {
  const _PriceLabel({required this.label, required this.color});
  final String label;
  final Color? color;
}

// ---------------------------------------------------------------------------
// Section title (used inside the body)
// ---------------------------------------------------------------------------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _formatCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return n.toString();
}
