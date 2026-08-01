/// Favorites list — Flask-backend /me/favorites.
///
/// Auth-required: the AuthWrapper already hides the Favorites tab for guests,
/// but this screen still defends itself so a deep link through
/// `requireLogin` keeps working.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_state.dart';
import '../models.dart';
import '../navigation.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  bool _initialLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_initialLoaded) {
        _initialLoaded = true;
        if (context.read<AuthProvider>().isLoggedIn) {
          context.read<UserProvider>().loadFavorites();
        }
      }
    });
  }

  void _open(Course c) {
    Navigator.of(context).pushNamed(
      AppRoutes.courseDetails,
      arguments: c.id,
    );
  }

  Future<void> _removeFavorite(Course c) async {
    try {
      await context.read<UserProvider>().toggleFavorite(c);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${c.name}" removed from favorites.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update favorites: $e')),
      );
    }
  }

  // Note: this screen is only reachable when a user is signed in (the
  // shell hides the Favorites tab for guests), so the inner actions do
  // not need a `requireLogin` prompt.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = context.watch<UserProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: RefreshIndicator(
        onRefresh: () async => context.read<UserProvider>().loadFavorites(),
        child: user.favorites.isEmpty
            ? _empty(theme, user.loadingFavorites)
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: user.favorites.length,
                separatorBuilder: (_, _) => const SizedBox(height: 6),
                itemBuilder: (_, i) {
                  final c = user.favorites[i];
                  return Dismissible(
                    key: ValueKey(c.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: theme.colorScheme.errorContainer,
                      child: Icon(Icons.delete_rounded,
                          color: theme.colorScheme.onErrorContainer),
                    ),
                    onDismissed: (_) => _removeFavorite(c),
                    child: Card(
                      child: ListTile(
                        onTap: () => _open(c),
                        leading: CircleAvatar(
                          backgroundColor:
                              theme.colorScheme.primaryContainer,
                          child: Icon(Icons.menu_book_rounded,
                              color: theme.colorScheme.onPrimaryContainer),
                        ),
                        title: Text(c.name,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [c.provider, c.subject]
                              .where((s) => (s ?? '').isNotEmpty)
                              .join(' • '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.heart_broken_rounded),
                          onPressed: () => _removeFavorite(c),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _empty(ThemeData theme, bool loading) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      // ListView lets the RefreshIndicator pull down on an empty screen.
      children: [
        const SizedBox(height: 120),
        Icon(Icons.favorite_border_rounded,
            size: 56, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          'No favorites yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            'Tap the heart on any course to save it for later.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
