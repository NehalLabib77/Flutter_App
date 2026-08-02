// User profile: identity, theme, and logout.
//
// Signed-in users see their live `AppUser` from the Flask backend, plus the
// theme switch and a sign-out button. Guests see a friendly prompt to sign
// in so the screen is useful in both states.
//
// [AuthProvider.logout] drives the auth state; [AuthWrapper] rebuilds and
// drops the user back to the login screen when sign-out completes.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../models.dart';
import '../widgets/design.dart';
import 'login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _loggingOut = false;
  bool _savingProfile = false;
  bool _deletingAccount = false;

  Future<void> _logout() async {
    setState(() => _loggingOut = true);
    final auth = context.read<AuthProvider>();
    try {
      await auth.logout();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _loggingOut = false);
    }
  }

  Future<void> _deleteAccount(AppUser user) async {
    // Two-step confirmation: a plain "Are you sure?" first, then a
    // text-input dialog asking the user to type their email so a
    // stray tap can't destroy the account. The typed value must
    // match the account email case-insensitively.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This permanently removes your account from EduCompass and '
          'from Firebase Authentication. Your favourites, history, '
          'progress, and enrollments will be erased. This cannot be '
          'undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.onErrorContainer,
              backgroundColor: Theme.of(ctx).colorScheme.errorContainer,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final controller = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm deletion'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type your email (${user.email}) to confirm:',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: Spacing.sm),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (typed == null || typed.toLowerCase() != user.email.toLowerCase()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Email did not match. Account not deleted.')),
      );
      return;
    }

    setState(() => _deletingAccount = true);
    if (!mounted) return;
    final auth = context.read<AuthProvider>();
    try {
      await auth.deleteAccount();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _deletingAccount = false);
    }
    // No `finally` — on success the screen is about to be unmounted
    // by [AuthWrapper] flipping to the unauthenticated branch, so we
    // skip the setState to avoid touching a disposed widget.
  }

  Future<void> _editProfile(AppUser user) async {
    final controller = TextEditingController(text: user.fullName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Edit display name'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Full name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
    if (result == null ||
        result.isEmpty ||
        result == user.fullName ||
        !mounted) {
      return;
    }
    setState(() => _savingProfile = true);
    try {
      await context.read<AuthProvider>().updateProfile(
        fullName: result,
        interests: user.interests,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  void _signIn() {
    // Direct push — `/login` is not registered in the MaterialApp routes,
    // and we don't want guests to navigate via the named-route table.
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: _GuestProfile(onSignIn: _signIn),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: Spacing.md),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: ProfileHeader(
              fullName: user.fullName,
              email: user.email,
              interests: user.interests,
              busy: _savingProfile,
              onEdit: () => _editProfile(user),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md),
            child: _ThemeCard(),
          ),
          const SizedBox(height: Spacing.md),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.md),
            child: _InfoCard(),
          ),
          const SizedBox(height: Spacing.lg),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: OutlinedButton.icon(
              onPressed: _loggingOut ? null : _logout,
              icon: _loggingOut
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          // Delete account — destructive, gated by a typed-email
          // confirmation in [_deleteAccount]. Matches the "Sign out"
          // button visually but uses error styling and a different
          // icon so it's distinguishable as permanent.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
            child: TextButton.icon(
              onPressed: (_loggingOut || _deletingAccount)
                  ? null
                  : () => _deleteAccount(user),
              icon: _deletingAccount
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(
                _deletingAccount ? 'Deleting account…' : 'Delete account',
              ),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
                minimumSize: const Size.fromHeight(44),
              ),
            ),
          ),
          const SizedBox(height: Spacing.xl),
        ],
      ),
    );
  }
}

class _GuestProfile extends StatelessWidget {
  const _GuestProfile({required this.onSignIn});
  final VoidCallback onSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.all(Spacing.md),
      children: [
        EduCard(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.person_outline_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: Spacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Browsing as guest',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          'Sign in to save favorites, enroll in courses, '
                          'and pick up where you left off.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Spacing.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: onSignIn,
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('Sign in'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const _ThemeCard(),
        const SizedBox(height: Spacing.md),
        const _InfoCard(),
      ],
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return EduCard(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.palette_outlined,
                size: 20,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                'Appearance',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_rounded),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_rounded),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_rounded),
                  label: Text('Dark'),
                ),
              ],
              selected: {theme.mode},
              onSelectionChanged: (m) => theme.setMode(m.first),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline_rounded, color: scheme.primary),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'All courses',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  'Browse the catalog, save favourites, and tap "Enroll" on '
                  'any course to add it to your learning list.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
