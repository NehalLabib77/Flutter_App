import 'package:flutter/material.dart';

import '../models.dart';
import '../widgets/design.dart';

/// Profile-level editor for the learning preferences that drive EduCompass
/// ranking. The screen only edits values; the caller decides how to persist
/// and refresh recommendations after Navigator.pop returns the result.
class EditPreferencesScreen extends StatefulWidget {
  const EditPreferencesScreen({
    super.key,
    required this.initialPreferences,
    this.requiredCompletion = false,
  });

  final LearningPreferences initialPreferences;

  /// When true this is the first-account setup step. Back navigation is
  /// disabled and the learner must choose at least one subject or skill so
  /// the new account starts with meaningful recommendations.
  final bool requiredCompletion;

  @override
  State<EditPreferencesScreen> createState() => _EditPreferencesScreenState();
}

class _EditPreferencesScreenState extends State<EditPreferencesScreen> {
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

  late final Set<String> _subjects;
  late final Set<String> _skills;
  late String _level;
  late String _courseType;
  late String _certificateType;
  late String _pricePreference;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPreferences;
    _subjects = initial.subjects.toSet();
    _skills = initial.skills.toSet();
    _level = initial.level;
    _courseType = initial.courseType;
    _certificateType = initial.certificateType;
    _pricePreference = initial.pricePreference;
  }

  LearningPreferences get _value => LearningPreferences(
        subjects: _subjects.toList(),
        skills: _skills.toList(),
        level: _level,
        courseType: _courseType,
        certificateType: _certificateType,
        pricePreference: _pricePreference,
      );

  void _clearAll() {
    setState(() {
      _subjects.clear();
      _skills.clear();
      _level = '';
      _courseType = '';
      _certificateType = '';
      _pricePreference = '';
    });
  }

  void _save() {
    if (widget.requiredCompletion && _subjects.isEmpty && _skills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Choose at least one subject or skill to continue.'),
        ),
      );
      return;
    }
    Navigator.of(context).pop(_value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pageWidth = MediaQuery.sizeOf(context).width;
    final horizontalPadding = pageWidth > 860
        ? (pageWidth - 820) / 2
        : pageWidth > 600
            ? Spacing.lg
            : Spacing.md;
    return PopScope(
      canPop: !widget.requiredCompletion,
      child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.requiredCompletion,
        title: Text(
          widget.requiredCompletion
              ? 'Set your learning preferences'
              : 'Recommendation preferences',
        ),
        actions: [
          if (!widget.requiredCompletion) TextButton(
            onPressed: _clearAll,
            child: const Text(
              'Clear',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          horizontalPadding,
          Spacing.md,
          horizontalPadding,
          Spacing.xxl,
        ),
        children: [
          HeroBanner(
            eyebrow: 'PERSONALISATION',
            title: widget.requiredCompletion
                ? 'What do you want to learn?'
                : 'Tune what EduCompass recommends',
            subtitle: widget.requiredCompletion
                ? 'This new account needs a learning profile before you continue. Your choices shape Popular, Top rated, By your goal and For you.'
                : 'Changes update Popular right now, Top rated, By your goal and For you. Your activity still helps the hybrid ranking improve over time.',
            icon: Icons.tune_rounded,
          ),
          const SizedBox(height: Spacing.lg),
          _PreferenceSection(
            title: 'Subjects',
            subtitle: 'Choose the areas you want to see more often.',
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
          const SizedBox(height: Spacing.md),
          _PreferenceSection(
            title: 'Skills and topics',
            subtitle: 'Choose what you are actively trying to learn.',
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
          const SizedBox(height: Spacing.md),
          _PreferenceSection(
            title: 'Learning style',
            subtitle: 'Optional filters. Keep Any when you do not mind.',
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
                  onChanged: (value) => setState(() => _courseType = value),
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
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('Save preferences'),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Provider and organization remain EduCompass automatically.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _PreferenceSection extends StatelessWidget {
  const _PreferenceSection({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.md),
          child,
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
      spacing: Spacing.sm,
      runSpacing: Spacing.sm,
      children: [
        for (final option in options)
          FilterChip(
            label: Text(option),
            selected: selected.contains(option),
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
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: Spacing.xs),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: value == entry.key,
                onSelected: (_) => onChanged(entry.key),
              ),
          ],
        ),
      ],
    );
  }
}
