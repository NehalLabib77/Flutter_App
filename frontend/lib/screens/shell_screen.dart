/// Bottom navigation shell that hosts the four main app sections.
///
/// We use [IndexedStack] (not TabBarView) so each tab keeps its own scroll
/// state and avoids rebuilding every time the user switches tabs.
library;

import 'package:flutter/material.dart';

import 'favorites_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'recommendations_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _index = 0;

  static const _tabs = <_TabItem>[
    _TabItem(icon: Icons.home_rounded, label: 'Home', screen: HomeScreen()),
    _TabItem(
        icon: Icons.auto_awesome_rounded,
        label: 'For you',
        screen: RecommendationsScreen()),
    _TabItem(
        icon: Icons.favorite_rounded,
        label: 'Favorites',
        screen: FavoritesScreen()),
    _TabItem(icon: Icons.person_rounded, label: 'Profile', screen: ProfileScreen()),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [for (final t in _tabs) t.screen],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final t in _tabs)
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
