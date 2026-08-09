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
import '../theme.dart';
import '../widgets/design.dart';
import 'edit_preferences_screen.dart';
import 'login_screen.dart';
import 'order_history_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _loggingOut = false;
  bool _switchingAccount = false;
  bool _savingProfile = false;
  bool _deletingAccount = false;
  bool _savingPreferences = false;

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


  Future<void> _switchAccount() async {
    if (_switchingAccount || _loggingOut) return;
    setState(() => _switchingAccount = true);

    // Capture the navigator before logout. AuthProvider.logout() notifies the
    // root AuthWrapper and may dispose this Profile screen immediately.
    final navigator = Navigator.of(context);
    final auth = context.read<AuthProvider>();

    try {
      await auth.logout();
      if (!navigator.mounted) return;
      navigator.pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not switch accounts. Try again.')),
      );
      setState(() => _switchingAccount = false);
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
        const SnackBar(
          content: Text('Email did not match. Account not deleted.'),
        ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
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


  Future<void> _editPreferences() async {
    if (_savingPreferences) return;
    final current = context.read<PreferenceProvider>().preferences;
    final updated = await Navigator.of(context).push<LearningPreferences>(
      MaterialPageRoute(
        builder: (_) => EditPreferencesScreen(initialPreferences: current),
      ),
    );
    if (updated == null || !mounted) return;

    setState(() => _savingPreferences = true);
    final auth = context.read<AuthProvider>();
    final preferenceProvider = context.read<PreferenceProvider>();
    String? syncWarning;

    try {
      // Device-local persistence updates guest recommendations immediately.
      await preferenceProvider.complete(updated);

      // Signed-in users also persist the same profile server-side so the
      // hybrid ranker and legacy interests table stay in sync.
      if (auth.isLoggedIn) {
        try {
          await context.read<ApiClient>().savePreferences(updated);
          await auth.refreshUser();
        } on ApiException catch (e) {
          syncWarning = e.message;
        } catch (_) {
          syncWarning = 'Could not sync preferences to your account.';
        }
      }

      // Refresh every recommendation surface now; switching tabs after this
      // shows the new ranking instead of waiting for an app restart.
      await Future.wait([
        context.read<CourseProvider>().loadPopular(preferences: updated),
        context.read<CourseProvider>().loadTopRated(preferences: updated),
        context.read<UserProvider>().loadPersonalized(
          preferences: updated,
          authenticated: auth.isLoggedIn,
        ),
      ]);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            syncWarning == null
                ? 'Preferences saved. Recommendations updated.'
                : 'Preferences saved on this device. $syncWarning',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingPreferences = false);
    }
  }

  void _openOrderHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const OrderHistoryScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final user = auth.user;

    if (user == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Profile')),
        body: _GuestProfile(
          onSignIn: _signIn,
          onEditPreferences: _editPreferences,
          preferencesBusy: _savingPreferences,
        ),
      );
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          IconButton(
            tooltip: 'Account menu',
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
            icon: const Icon(Icons.menu_rounded),
          ),
          const SizedBox(width: Spacing.xs),
        ],
      ),
      endDrawer: _ProfileAccountDrawer(
        user: user,
        signingOut: _loggingOut,
        deleting: _deletingAccount,
        onOrderHistory: _openOrderHistory,
        onEditPreferences: _editPreferences,
        onSignOut: _logout,
        onDeleteAccount: () => _deleteAccount(user),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.md,
          Spacing.md,
          Spacing.md,
          Spacing.xxl,
        ),
        children: [
          ProfileHeader(
            fullName: user.fullName,
            email: user.email,
            interests: user.interests,
            busy: _savingProfile,
            switchingAccount: _switchingAccount,
            onEdit: () => _editProfile(user),
            onSwitchAccount: _switchAccount,
          ),
          const SizedBox(height: Spacing.lg),
          _RecommendationPreferencesCard(
            busy: _savingPreferences,
            onEdit: _editPreferences,
          ),
          const SizedBox(height: Spacing.md),
          const _ThemeCard(),
          const SizedBox(height: Spacing.md),
          const _InfoCard(),
        ],
      ),
    );
  }
}

class _ProfileAccountDrawer extends StatelessWidget {
  const _ProfileAccountDrawer({
    required this.user,
    required this.signingOut,
    required this.deleting,
    required this.onOrderHistory,
    required this.onEditPreferences,
    required this.onSignOut,
    required this.onDeleteAccount,
  });

  final AppUser user;
  final bool signingOut;
  final bool deleting;
  final VoidCallback onOrderHistory;
  final VoidCallback onEditPreferences;
  final VoidCallback onSignOut;
  final VoidCallback onDeleteAccount;

  void _afterClose(BuildContext context, VoidCallback action) {
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) => action());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              margin: const EdgeInsets.all(Spacing.md),
              padding: const EdgeInsets.all(Spacing.lg),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, scheme.secondary],
                ),
                borderRadius: BorderRadius.circular(Radii.xl),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 26,
                    backgroundColor: Colors.white.withValues(alpha: 0.16),
                    child: Text(
                      user.initials,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.fullName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user.email,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.sm,
                Spacing.lg,
                Spacing.xs,
              ),
              child: Text(
                'ACCOUNT',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Order history'),
              subtitle: const Text('View enrolled course payment details'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _afterClose(context, onOrderHistory),
            ),
            ListTile(
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Edit preferences'),
              subtitle: const Text('Update recommendation choices'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => _afterClose(context, onEditPreferences),
            ),
            const Divider(height: Spacing.lg),
            ListTile(
              leading: signingOut
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout_rounded),
              title: Text(signingOut ? 'Signing out…' : 'Sign out'),
              onTap: signingOut ? null : () => _afterClose(context, onSignOut),
            ),
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              iconColor: scheme.error,
              textColor: scheme.error,
              leading: deleting
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.error,
                      ),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              title: Text(deleting ? 'Deleting account…' : 'Delete account'),
              subtitle: Text(
                'Permanently remove your account',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              onTap: deleting
                  ? null
                  : () => _afterClose(context, onDeleteAccount),
            ),
            const SizedBox(height: Spacing.sm),
          ],
        ),
      ),
    );
  }
}

class _GuestProfile extends StatelessWidget {
  const _GuestProfile({
    required this.onSignIn,
    required this.onEditPreferences,
    required this.preferencesBusy,
  });
  final VoidCallback onSignIn;
  final VoidCallback onEditPreferences;
  final bool preferencesBusy;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.md,
        Spacing.md,
        Spacing.md,
        Spacing.xxl,
      ),
      children: [
        const _GuestIdentityCard(),
        const SizedBox(height: Spacing.md),
        _GuestSignInCard(onSignIn: onSignIn),
        const SizedBox(height: Spacing.md),
        _RecommendationPreferencesCard(
          busy: preferencesBusy,
          onEdit: onEditPreferences,
        ),
        const SizedBox(height: Spacing.md),
        const _ThemeCard(),
        const SizedBox(height: Spacing.md),
        const _InfoCard(),
      ],
    );
  }
}

class _GuestIdentityCard extends StatelessWidget {
  const _GuestIdentityCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF1D4B87), Color(0xFF24477B)]
              : const [AppColors.navy, Color(0xFF5D7FAF)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.48),
                width: 1.5,
              ),
            ),
            child: const Text(
              'G',
              style: TextStyle(
                color: Colors.white,
                fontSize: 25,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: Spacing.lg),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Guest',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Browsing without an account',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.circle,
                      size: 10,
                      color: Color(0xFF68E0A2),
                    ),
                    const SizedBox(width: Spacing.xs),
                    Flexible(
                      child: Text(
                        'Not signed in',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GuestSignInCard extends StatelessWidget {
  const _GuestSignInCard({required this.onSignIn});
  final VoidCallback onSignIn;

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
            'Sign in to unlock EduCompass',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            'Save favorites, enroll in courses, and pick up where you left off.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onSignIn,
              icon: const Icon(Icons.login_rounded),
              label: const Text('Sign in'),
            ),
          ),
        ],
      ),
    );
  }
}


class _RecommendationPreferencesCard extends StatelessWidget {
  const _RecommendationPreferencesCard({
    required this.busy,
    required this.onEdit,
  });

  final bool busy;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final preferences = context.watch<PreferenceProvider>().preferences;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final summaryItems = <String>[
      ...preferences.subjects.take(2),
      ...preferences.skills.take(2),
      if (preferences.level.isNotEmpty) preferences.level,
      if (preferences.courseType.isNotEmpty) preferences.courseType,
      if (preferences.pricePreference.isNotEmpty) preferences.pricePreference,
    ];
    final summary = preferences.isEmpty
        ? 'No preferences selected yet. EduCompass will rely more on quality, popularity and your activity.'
        : summaryItems.take(5).join(' • ');

    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RECOMMENDATIONS',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tune_rounded, color: scheme.primary),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recommendation preferences',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Controls Popular right now, Top rated, By your goal and For you.',
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Spacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onEdit,
              icon: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.edit_rounded),
              label: Text(busy ? 'Updating recommendations…' : 'Edit preferences'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard();

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'APPEARANCE',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.palette_outlined, size: 22, color: scheme.primary),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Theme mode',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Pick how EduCompass looks across the app.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_rounded),
                  label: Text('Auto'),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_rounded),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_rounded),
                  label: Text('Dark'),
                ),
              ],
              selected: {themeProvider.mode},
              onSelectionChanged: (m) => themeProvider.setMode(m.first),
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
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ABOUT',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, color: scheme.primary),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  'About EduCompass',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            'EduCompass helps you discover courses, save favourites, and build '
            'a learning path that fits your goals.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.md),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Version 1.0.0',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccountActionCard extends StatelessWidget {
  const _AccountActionCard({required this.busy, required this.onSignOut});
  final bool busy;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ACCOUNT ACTIONS',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.primary,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Icon(Icons.lock_outline_rounded, color: scheme.primary),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  'Session',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : onSignOut,
              icon: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout_rounded),
              label: Text(busy ? 'Signing out…' : 'Sign out'),
            ),
          ),
        ],
      ),
    );
  }
}

class _DangerZoneCard extends StatelessWidget {
  const _DangerZoneCard({
    required this.busy,
    required this.disabled,
    required this.onDelete,
  });

  final bool busy;
  final bool disabled;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DANGER ZONE',
            style: theme.textTheme.labelMedium?.copyWith(
              color: scheme.error,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: scheme.error),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delete account',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Permanently remove your account, data, and enrollments.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (busy || disabled) ? null : onDelete,
              icon: busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_forever_outlined),
              label: Text(busy ? 'Deleting account…' : 'Delete account'),
              style: OutlinedButton.styleFrom(
                foregroundColor: scheme.error,
                side: BorderSide(color: scheme.error.withValues(alpha: 0.75)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
