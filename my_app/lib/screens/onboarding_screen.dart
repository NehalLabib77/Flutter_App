/// First-launch learning-preference onboarding.
///
/// This sits in front of the existing AuthWrapper, so authentication remains
/// optional. The selected profile is stored locally and immediately powers
/// Home + For You; after login it is also mirrored to Flask.
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
  final _controller = PageController();
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
    _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLast = _page == 3;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('Set up EduCompass'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _skip,
            child: const Text(
              'Skip',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const NeverScrollableScrollPhysics(),
                onPageChanged: (value) => setState(() => _page = value),
                children: [
                  const _WelcomePage(),
                  _ChoicePage(
                    eyebrow: 'INTERESTS',
                    title: 'What subjects interest you?',
                    subtitle:
                        'Pick a few. These immediately shape Popular, Top rated and For you.',
                    icon: Icons.category_outlined,
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
                        'Choose skills or topics you want EduCompass to prioritize.',
                    icon: Icons.auto_awesome_outlined,
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
                    eyebrow: 'LEARNING STYLE',
                    title: 'Fine-tune your recommendations',
                    subtitle:
                        'These are optional. Leave any row on Any if you have no preference.',
                    icon: Icons.tune_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _SingleChoiceGroup(
                          label: 'Level',
                          options: const {
                            '': 'Any',
                            'Beginner': 'Beginner',
                            'Intermediate': 'Intermediate',
                            'Advanced': 'Advanced',
                          },
                          value: _level,
                          onChanged: (value) => setState(() => _level = value),
                        ),
                        const SizedBox(height: Spacing.md),
                        _SingleChoiceGroup(
                          label: 'Course type',
                          options: const {
                            '': 'Any',
                            'Course': 'Course',
                            'Specialization': 'Specialization',
                            'Professional Certificate': 'Professional cert.',
                            'Guided Project': 'Guided project',
                          },
                          value: _courseType,
                          onChanged: (value) =>
                              setState(() => _courseType = value),
                        ),
                        const SizedBox(height: Spacing.md),
                        _SingleChoiceGroup(
                          label: 'Certificate',
                          options: const {
                            '': 'Any',
                            'Certificate': 'Prefer certificate',
                            'No Certificate': 'Not required',
                          },
                          value: _certificateType,
                          onChanged: (value) =>
                              setState(() => _certificateType = value),
                        ),
                        const SizedBox(height: Spacing.md),
                        _SingleChoiceGroup(
                          label: 'Price',
                          options: const {
                            '': 'Any',
                            'Free': 'Free',
                            'Paid': 'Paid',
                          },
                          value: _pricePreference,
                          onChanged: (value) =>
                              setState(() => _pricePreference = value),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.md,
                Spacing.sm,
                Spacing.md,
                Spacing.md,
              ),
              child: Row(
                children: [
                  Row(
                    children: List.generate(4, (index) {
                      final active = index == _page;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(right: 6),
                        width: active ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(20),
                        ),
                      );
                    }),
                  ),
                  const Spacer(),
                  if (_page > 0)
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => _controller.previousPage(
                              duration: const Duration(milliseconds: 240),
                              curve: Curves.easeOut,
                            ),
                      child: const Text('Back'),
                    ),
                  const SizedBox(width: Spacing.xs),
                  FilledButton.icon(
                    onPressed: _saving ? null : (isLast ? _finish : _next),
                    icon: _saving && isLast
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isLast
                                ? Icons.check_rounded
                                : Icons.arrow_forward_rounded,
                          ),
                    label: Text(isLast ? 'Use my preferences' : 'Next'),
                  ),
                ],
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

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    return const _ChoicePage(
      eyebrow: 'PERSONALISE',
      title: 'Courses that start with you',
      subtitle:
          'Tell EduCompass what you want to learn once. Your Home and For you tabs will start personalised even before you sign in.',
      icon: Icons.explore_rounded,
      child: EduCard(
        border: true,
        child: Column(
          children: [
            _BenefitRow(
              icon: Icons.local_fire_department_outlined,
              text: 'Popular right now, adjusted to your interests',
            ),
            SizedBox(height: Spacing.md),
            _BenefitRow(
              icon: Icons.star_outline_rounded,
              text: 'Top-rated courses that also fit your profile',
            ),
            SizedBox(height: Spacing.md),
            _BenefitRow(
              icon: Icons.auto_awesome_outlined,
              text: 'For You improves as you view, save and complete courses',
            ),
          ],
        ),
      ),
    );
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Spacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HeroBanner(
            eyebrow: eyebrow,
            title: title,
            subtitle: subtitle,
            icon: icon,
          ),
          const SizedBox(height: Spacing.lg),
          child,
          const SizedBox(height: Spacing.md),
          Text(
            'You can continue without selecting everything.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
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
      spacing: Spacing.xs,
      runSpacing: Spacing.xs,
      children: [
        for (final option in options)
          FilterChip(
            selected: selected.contains(option),
            label: Text(option),
            onSelected: (_) => onChanged(option),
          ),
      ],
    );
  }
}

class _SingleChoiceGroup extends StatelessWidget {
  const _SingleChoiceGroup({
    required this.label,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final Map<String, String> options;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.xs,
          runSpacing: Spacing.xs,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                selected: value == entry.key,
                label: Text(entry.value),
                onSelected: (_) => onChanged(entry.key),
              ),
          ],
        ),
      ],
    );
  }
}

class _BenefitRow extends StatelessWidget {
  const _BenefitRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: Spacing.sm),
        Expanded(child: Text(text)),
      ],
    );
  }
}
