/// Bottom navigation shell.
///
/// Three tabs for guests (Home, For you, Profile) and five tabs for signed-in
/// users (Home, For you, My Courses, Favorites, Profile). The My Courses and
/// Favorites tabs are hidden when no user is signed in so guests no longer
/// see empty screens they have no way to populate.
///
/// We use [IndexedStack] (not TabBarView) so each tab keeps its own scroll
/// state and avoids rebuilding every time the user switches tabs.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../theme.dart';
import '../widgets/design.dart';
import 'favorites_screen.dart';
import 'home_screen.dart';
import 'my_courses_screen.dart';
import 'profile_screen.dart';
import 'recommendations_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({
    super.key,
    this.initialTabIndex = 0,
    this.initialQuery = '',
  });

  /// Opens the shell with a specific tab selected. Used by deep-link
  /// / pushNamed routes that want to land the user on the "For you"
  /// tab after typing a query on the home screen. Index is clamped
  /// against the active tab list so an out-of-range value falls back
  /// to Home without crashing.
  final int initialTabIndex;

  /// Forwarded to the embedded [RecommendationsScreen] so the goal
  /// search input is pre-filled and the search runs immediately. Has
  /// no effect on tabs other than "For you".
  final String initialQuery;

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialTabIndex;
  }

  static const _coreTabsTemplate = <_TabItem>[
    _TabItem(icon: Icons.home_rounded, label: 'Home', screen: HomeScreen()),
    // The "For you" tab is rebuilt each build so it can pick up
    // [widget.initialQuery] from the shell. We keep the entry in the
    // template purely so the icon/label/length stay aligned with the
    // signed-in branch (which appends Favorites + My Courses).
    _TabItem(
      icon: Icons.auto_awesome_rounded,
      label: 'For you',
      screen: RecommendationsScreen(),
    ),
    _TabItem(
      icon: Icons.person_rounded,
      label: 'Profile',
      screen: ProfileScreen(),
    ),
  ];

  static const _favoritesTab = _TabItem(
    icon: Icons.favorite_rounded,
    label: 'Favorites',
    screen: FavoritesScreen(),
  );

  static const _myCoursesTab = _TabItem(
    icon: Icons.school_rounded,
    label: 'My Courses',
    screen: MyCoursesScreen(),
  );

  /// Build the live tab list. The "For you" entry is constructed
  /// fresh on every build so it can carry the latest
  /// [widget.initialQuery] from a deep-link route — the rest stay
  /// `const` for parity with the previous implementation.
  List<_TabItem> _tabsFor(bool signedIn) {
    final forYou = _TabItem(
      icon: Icons.auto_awesome_rounded,
      label: 'For you',
      screen: RecommendationsScreen(initialQuery: widget.initialQuery),
    );
    if (!signedIn) {
      return [
        _coreTabsTemplate[0],
        forYou,
        _coreTabsTemplate[2],
      ];
    }
    // Insert My Courses and Favorites after "For you" so they sit at
    // indices 2 and 3 for signed-in users.
    return [
      _coreTabsTemplate[0],
      forYou,
      _myCoursesTab,
      _favoritesTab,
      _coreTabsTemplate[2],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    // Watch user state so a loading badge on "For you" appears the moment
    // personalised recommendations start fetching.
    final user = context.watch<UserProvider>();
    final isSignedIn = auth.isLoggedIn;
    final tabs = _tabsFor(isSignedIn);
    // Clamp the current index so a previously-selected Favorites tab doesn't
    // leave us on a phantom page after the user signs out.
    final safeIndex = _index.clamp(0, tabs.length - 1);
    // Presentation tokens come from the active theme so selected icons
    // remain readable in dark mode instead of using the light-mode navy.
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final navBackground = isDark ? AppColors.darkPage : Colors.white;
    final navIdle = scheme.onSurfaceVariant;
    final navActive = scheme.primary;
    final badgeBackground = navBackground;
    return Scaffold(
      body: IndexedStack(
        index: safeIndex,
        children: [for (final t in tabs) t.screen],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: NavigationBar(
        height: 72,
        selectedIndex: safeIndex,
        onDestinationSelected: (i) => setState(() => _index = i),
        backgroundColor: navBackground,
        indicatorColor: navActive.withValues(alpha: isDark ? 0.30 : 0.12),
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            color: selected ? navActive : navIdle,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          );
        }),
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              icon: _iconFor(
                t,
                user.loadingPersonalized,
                foreground: navIdle,
                badgeBackground: badgeBackground,
              ),
              selectedIcon: Icon(t.icon, color: navActive),
              label: t.label,
            ),
        ],
        ),
      ),
    );
  }

  /// Wraps the For-you icon in a small IconBadge dot when personalised
  /// recommendations are loading so the user gets a visible affordance
  /// that something is happening in the background.
  Widget _iconFor(
    _TabItem tab,
    bool personalizedLoading, {
    required Color foreground,
    required Color badgeBackground,
  }) {
    final icon = Icon(tab.icon, color: foreground);
    if (tab.label == 'For you' && personalizedLoading) {
      return Badge(
        backgroundColor: badgeBackground,
        label: const SizedBox.shrink(),
        alignment: AlignmentDirectional.topEnd,
        offset: const Offset(-2, 2),
        child: IconBadge(
          icon: tab.icon,
          size: 24,
          iconSize: 14,
          background: badgeBackground,
          foreground: foreground,
        ),
      );
    }
    return icon;
  }
}

class _TabItem {
  final IconData icon;
  final String label;
  final Widget screen;
  const _TabItem({
    required this.icon,
    required this.label,
    required this.screen,
  });
}
