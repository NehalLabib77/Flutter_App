/// Three-page intro explaining the app, then routes to the home shell.
///
/// Sign-in is optional and is offered from the Home AppBar / Profile tab,
/// so the onboarding flow does not push [LoginScreen].
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/design.dart';
import 'shell_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _slides = [
    _Slide(
      eyebrow: 'DISCOVER',
      icon: Icons.explore_outlined,
      title: 'Find your path',
      body: 'Browse thousands of curated courses across every subject.',
    ),
    _Slide(
      eyebrow: 'PERSONALISE',
      icon: Icons.auto_awesome_rounded,
      title: 'Recommendations that learn',
      body: 'Tell us your interests and we surface what truly fits.',
    ),
    _Slide(
      eyebrow: 'PROGRESS',
      icon: Icons.bolt_rounded,
      title: 'Track and finish',
      body: 'Save favourites, follow learning paths, mark progress.',
    ),
  ];

  Future<void> _finish() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_done', true);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      // After onboarding, guests land on the Home tab — sign-in is
      // optional and is offered from the Home AppBar / Profile tab.
      MaterialPageRoute(builder: (_) => const ShellScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) => _SlideView(slide: _slides[i]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.lg,
                vertical: Spacing.md,
              ),
              child: Row(
                children: [
                  Row(
                    children: List.generate(_slides.length, (i) {
                      final active = i == _page;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOut,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: active ? 20 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(4),
                          ),
                        ),
                      );
                    }),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _page == _slides.length - 1
                        ? _finish
                        : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOut,
                          ),
                    icon: Icon(
                      _page == _slides.length - 1
                          ? Icons.rocket_launch_rounded
                          : Icons.arrow_forward_rounded,
                    ),
                    label: Text(
                      _page == _slides.length - 1 ? 'Get started' : 'Next',
                    ),
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

class _Slide {
  final String eyebrow;
  final IconData icon;
  final String title;
  final String body;
  const _Slide({
    required this.eyebrow,
    required this.icon,
    required this.title,
    required this.body,
  });
}

class _SlideView extends StatelessWidget {
  const _SlideView({required this.slide});
  final _Slide slide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Per-slide gradient header that anchors the page with the
          // same HeroBanner vocabulary used by Home / Recommendations /
          // Learning Paths. Renders icon-on-circle inside a tinted card.
          HeroBanner(
            eyebrow: slide.eyebrow,
            title: slide.title,
            icon: slide.icon,
          ),
          const SizedBox(height: Spacing.xl),
          IconBadge(
            icon: slide.icon,
            size: 96,
            iconSize: 44,
            background: scheme.primaryContainer,
            foreground: scheme.onPrimaryContainer,
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            slide.body,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
