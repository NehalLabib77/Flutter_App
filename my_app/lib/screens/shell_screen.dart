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
import 'favorites_screen.dart';
import 'home_screen.dart';
import 'my_courses_screen.dart';
import 'profile_screen.dart';
import 'recommendations_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  static const _coreTabs = <_TabItem>[
    _TabItem(
        icon: Icons.home_rounded,
        label: 'Home',
        screen: HomeScreen()),
    _TabItem(
        icon: Icons.auto_awesome_rounded,
        label: 'For you',
        screen: RecommendationsScreen()),
    _TabItem(
        icon: Icons.person_rounded,
        label: 'Profile',
        screen: ProfileScreen()),
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

  List<_TabItem> _tabsFor(bool signedIn) {
    if (!signedIn) return _coreTabs;
    // Insert My Courses and Favorites after "For you" so they sit at
    // indices 2 and 3 for signed-in users.
    return [
      _coreTabs[0],
      _coreTabs[1],
      _myCoursesTab,
      _favoritesTab,
      _coreTabs[2],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final isSignedIn = auth.isLoggedIn;
    final tabs = _tabsFor(isSignedIn);
    // Clamp the current index so a previously-selected Favorites tab doesn't
    // leave us on a phantom page after the user signs out.
    final safeIndex = _index.clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(
        index: safeIndex,
        children: [for (final t in tabs) t.screen],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: safeIndex,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in tabs)
            NavigationDestination(icon: Icon(t.icon), label: t.label),
        ],
      ),
    );
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
