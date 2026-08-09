/// Multi-step learning-preference onboarding.
///
/// This screen only changes presentation. It keeps the existing
/// [LearningPreferences] shape and saves through [PreferenceProvider.complete].
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../widgets/design.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const int _stepCount = 6;

  final PageController _controller = PageController();
  int _page = 0;
  bool _saving = false;

  final Set<String> _subjects = <String>{};
  final Set<String> _skills = <String>{};
  String _level = '';
  String _courseType = '';
  String _certificateType = '';
  String _pricePreference = '';

  static const _subjectOptions = <String>[
    'Data Science',
    'Computer Science',
    'Information Technology',
    'Business',
    'Engineering',
    'Math and Logic',
    'Health',
    'Arts and Humanities',
    'Language Learning',
    'Personal Development',
  ];

  static const _skillOptions = <String>[
    'Python',
    'Machine Learning',
    'Artificial Intelligence',
    'Data Analysis',
    'SQL',
    'Flutter',
    'Dart',
    'Web Development',
    'Cybersecurity',
    'Cloud Computing',
    'Project Management',
    'Marketing',
    'Finance',
    'Design',
  ];

  LearningPreferences get _preferences => LearningPreferences(
    subjects: _subjects.toList(),
    skills: _skills.toList(),
    level: _level,
    courseType: _courseType,
    certificateType: _certificateType,
    pricePreference: _pricePreference,
  );

  Future<void> _finish() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await context.read<PreferenceProvider>().complete(_preferences);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _skip() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await context.read<PreferenceProvider>().skip();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _next() {
    if (_page >= _stepCount - 1) return;
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _back() {
    if (_page <= 0) return;
    _controller.previousPage(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isLast = _page == _stepCount - 1;
    final progress = (_page + 1) / _stepCount;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Personalize learning'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _skip,
            child: const Text('Skip', style: TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ResponsiveContent(
              maxWidth: 760,
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.md,
                Spacing.lg,
                Spacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Step ${_page + 1} of $_stepCount',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      Text(
                        '${(progress * 100).round()}%',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Spacing.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 7,
                      backgroundColor: scheme.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (value) => setState(() => _page = value),
                children: [
                  _ChoicePage(
                    eyebrow: 'SUBJECTS',
                    title: 'What subjects interest you?',
                    subtitle:
                        'Choose a few broad areas. These help shape Popular, Top Rated and For You.',
                    icon: Icons.category_rounded,
                    child: _MultiChoiceChips(
                      options: _subjectOptions,
                      selected: _subjects,
                      onChanged: (value) => setState(() {
                        _subjects.contains(value)
                            ? _subjects.remove(value)
                            : _subjects.add(value);
                      }),
                    ),
                  ),
                  _ChoicePage(
                    eyebrow: 'SKILLS',
                    title: 'What do you want to learn?',
                    subtitle:
                        'Pick practical skills or topics you want EduCompass to prioritize.',
                    icon: Icons.psychology_alt_rounded,
                    child: _MultiChoiceChips(
                      options: _skillOptions,
                      selected: _skills,
                      onChanged: (value) => setState(() {
                        _skills.contains(value)
                            ? _skills.remove(value)
                            : _skills.add(value);
                      }),
                    ),
                  ),
                  _ChoicePage(
                    eyebrow: 'LEVEL',
                    title: 'Choose your learning level',
                    subtitle:
                        'Select the level that best matches where you want to start.',
                    icon: Icons.stairs_rounded,
                    child: _SingleChoiceGroup(
                      options: const {
                        '': 'Any level',
                        'Beginner': 'Beginner',
                        'Intermediate': 'Intermediate',
                        'Advanced': 'Advanced',
                      },
                      value: _level,
                      onChanged: (value) => setState(() => _level = value),
                    ),
                  ),
                  _ChoicePage(
                    eyebrow: 'COURSE TYPE',
                    title: 'What format do you prefer?',
                    subtitle:
                        'Choose a format, or keep Any if you are open to everything.',
                    icon: Icons.view_module_rounded,
                    child: _SingleChoiceGroup(
                      options: const {
                        '': 'Any format',
                        'Course': 'Course',
                        'Specialization': 'Specialization',
                        'Professional Certificate': 'Professional certificate',
                        'Guided Project': 'Guided project',
                      },
                      value: _courseType,
                      onChanged: (value) => setState(() => _courseType = value),
                    ),
                  ),
                  _ChoicePage(
                    eyebrow: 'CERTIFICATE',
                    title: 'Do you want a certificate?',
                    subtitle:
                        'Tell us whether certification matters for your learning goal.',
                    icon: Icons.workspace_premium_rounded,
                    child: _SingleChoiceGroup(
                      options: const {
                        '': 'Any',
                        'Certificate': 'Certificate preferred',
                        'No Certificate': 'Certificate not required',
                      },
                      value: _certificateType,
                      onChanged: (value) =>
                          setState(() => _certificateType = value),
                    ),
                  ),
                  _ChoicePage(
                    eyebrow: 'PRICE',
                    title: 'Choose your price preference',
                    subtitle:
                        'This helps EduCompass prioritize courses that fit your budget.',
                    icon: Icons.payments_outlined,
                    child: _SingleChoiceGroup(
                      options: const {
                        '': 'Any price',
                        'Free': 'Free',
                        'Paid': 'Paid',
                      },
                      value: _pricePreference,
                      onChanged: (value) =>
                          setState(() => _pricePreference = value),
                    ),
                  ),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(
                  top: BorderSide(color: scheme.outlineVariant),
                ),
              ),
              child: ResponsiveContent(
                maxWidth: 760,
                padding: const EdgeInsets.fromLTRB(
                  Spacing.md,
                  Spacing.sm,
                  Spacing.md,
                  Spacing.md,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 360;
                    final backButton = TextButton.icon(
                      onPressed: (_saving || _page == 0) ? null : _back,
                      icon: const Icon(Icons.arrow_back_rounded),
                      label: const Text('Back'),
                    );
                    final nextButton = FilledButton.icon(
                      onPressed: _saving ? null : (isLast ? _finish : _next),
                      icon: _saving && isLast
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(
                              isLast
                                  ? Icons.check_rounded
                                  : Icons.arrow_forward_rounded,
                            ),
                      label: Text(isLast ? 'Finish' : 'Next'),
                    );

                    if (compact) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          nextButton,
                          if (_page > 0) ...[
                            const SizedBox(height: Spacing.xs),
                            backButton,
                          ],
                        ],
                      );
                    }

                    return Row(
                      children: [
                        if (_page > 0) backButton else const SizedBox(width: 88),
                        const Spacer(),
                        nextButton,
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _ChoicePage extends StatelessWidget {
  const _ChoicePage({
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final String eyebrow;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final horizontal = constraints.maxWidth >= 760;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HeroBanner(
              eyebrow: eyebrow,
              title: title,
              subtitle: subtitle,
              icon: icon,
            ),
            const SizedBox(height: Spacing.lg),
            EduCard(
              border: true,
              padding: EdgeInsets.all(horizontal ? Spacing.xl : Spacing.lg),
              child: child,
            ),
            const SizedBox(height: Spacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Spacing.xs),
                Flexible(
                  child: Text(
                    'You can continue without selecting an option.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        );

        return SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: horizontal ? Spacing.xl : Spacing.md,
            vertical: Spacing.sm,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: content,
            ),
          ),
        );
      },
    );
  }
}

class _MultiChoiceChips extends StatelessWidget {
  const _MultiChoiceChips({
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<String> options;
  final Set<String> selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final option in options)
          FilterChip(
            selected: selected.contains(option),
            label: Text(option),
            avatar: selected.contains(option)
                ? const Icon(Icons.check_rounded, size: 16)
                : null,
            onSelected: (_) => onChanged(option),
          ),
      ],
    );
  }
}

class _SingleChoiceGroup extends StatelessWidget {
  const _SingleChoiceGroup({
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final Map<String, String> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final twoColumns = constraints.maxWidth >= 560;
        final itemWidth = twoColumns
            ? (constraints.maxWidth - Spacing.sm) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final entry in options.entries)
              SizedBox(
                width: itemWidth,
                child: InkWell(
                  borderRadius: BorderRadius.circular(Radii.md),
                  onTap: () => onChanged(entry.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: Spacing.md,
                      vertical: Spacing.md,
                    ),
                    decoration: BoxDecoration(
                      color: value == entry.key
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(
                        color: value == entry.key
                            ? scheme.primary
                            : scheme.outlineVariant,
                        width: value == entry.key ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          value == entry.key
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                          color: value == entry.key
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            entry.value,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: value == entry.key
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
