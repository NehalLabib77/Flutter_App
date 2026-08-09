// Favorites list — Flask-backend /me/favorites.
//
// Auth-required: the AuthWrapper already hides the Favorites tab for guests,
// but this screen still defends itself so a deep link through
// `requireLogin` keeps working.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../course_image.dart';
import '../models.dart';
import '../navigation.dart';
import '../widgets/design.dart';

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
    Navigator.of(context).pushNamed(AppRoutes.courseDetails, arguments: c.id);
  }

  Future<void> _removeFavorite(Course c) async {
    try {
      await context.read<UserProvider>().toggleFavorite(c);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"${c.name}" removed from favorites.')),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update favorites.')),
      );
    }
  }

  // Note: this screen is only reachable when a user is signed in (the
  // shell hides the Favorites tab for guests), so the inner actions do
  // not need a `requireLogin` prompt.

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final user = context.watch<UserProvider>();
    return Scaffold(
      appBar: AppBar(title: const Text('Favorites')),
      body: RefreshIndicator(
        onRefresh: () async => context.read<UserProvider>().loadFavorites(),
        child: user.favorites.isEmpty
            ? _empty(theme, user.loadingFavorites, user.favoritesError)
            : ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(
                  top: Spacing.md,
                  bottom: Spacing.xxl,
                ),
                itemCount: user.favorites.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
                itemBuilder: (_, i) {
                  if (i == 0) {
                    return const ResponsiveContent(
                      child: Padding(
                        padding: EdgeInsets.only(bottom: Spacing.sm),
                        child: PageLead(
                          title: 'Saved for later',
                          subtitle: 'Keep your shortlist focused and return to any course when you are ready.',
                          icon: Icons.favorite_rounded,
                        ),
                      ),
                    );
                  }
                  final c = user.favorites[i - 1];
                  return ResponsiveContent(
                    child: Dismissible(
                      key: ValueKey(c.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: Spacing.lg),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(Radii.lg),
                        ),
                        child: Icon(
                          Icons.delete_rounded,
                          color: scheme.onErrorContainer,
                        ),
                      ),
                      onDismissed: (_) => _removeFavorite(c),
                      child: CourseRowCard(
                        title: c.name,
                        provider: c.provider,
                        level: c.level,
                        subject: c.subject,
                        skills: c.skills,
                        rating: c.rating,
                        isFree: c.isFree,
                        thumbnail: CourseThumbnail(course: c, size: 68),
                        trailing: IconButton(
                          tooltip: 'Remove from favorites',
                          icon: Icon(
                            Icons.favorite_rounded,
                            color: scheme.primary,
                          ),
                          onPressed: () => _removeFavorite(c),
                        ),
                        onTap: () => _open(c),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _empty(ThemeData theme, bool loading, String? error) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // ListView keeps pull-to-refresh available for both error and empty
    // states without introducing a nested scroll view.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: Spacing.xxl),
        if (error != null)
          ResponsiveContent(
            maxWidth: 680,
            child: EmptyState(
            icon: Icons.cloud_off_rounded,
            message: error,
            action: FilledButton.icon(
              onPressed: () => context.read<UserProvider>().loadFavorites(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ),
          )
        else
          ResponsiveContent(
            maxWidth: 680,
            child: EmptyState(
            icon: Icons.favorite_border_rounded,
            message: 'No favorites yet',
            action: Padding(
              padding: const EdgeInsets.only(top: Spacing.sm),
              child: Text(
                'Tap the heart on any course to save it for later.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          ),
      ],
    );
  }
}
