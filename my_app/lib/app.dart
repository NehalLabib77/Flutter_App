library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'navigation.dart';
import 'screens/auth_wrapper.dart';
import 'screens/course_details_screen.dart';
import 'screens/learning_path_detail_screen.dart';
import 'screens/shell_screen.dart';
import 'services/deep_link_service.dart';
import 'theme.dart';

/// Re-exposes the providers used by the root [MultiProvider] to a child
/// that was pushed via the [MaterialApp] route table. Route-pushed screens
/// live above the root provider scope, so they cannot resolve
/// [ApiClient] / [AuthProvider] / etc. unless we wrap them.
Widget wrapWithProviders(BuildContext context, Widget child) {
  final api = context.read<ApiClient>();
  final auth = context.read<AuthProvider>();
  final courses = context.read<CourseProvider>();
  final user = context.read<UserProvider>();
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<CourseProvider>.value(value: courses),
      ChangeNotifierProvider<UserProvider>.value(value: user),
      ChangeNotifierProvider<EnrollmentProvider>.value(
        value: context.read<EnrollmentProvider>(),
      ),
      ChangeNotifierProvider<ThemeProvider>.value(
        value: context.read<ThemeProvider>(),
      ),
      // DeepLinkService lives above the root provider scope, so any
      // route-pushed screen (e.g. MockPaymentScreen) needs it
      // re-exposed here too. Without this the payment screen crashes
      // with "Could not find the correct Provider<DeepLinkService>"
      // the moment it calls `context.read<DeepLinkService>()`.
      Provider<DeepLinkService>.value(value: context.read<DeepLinkService>()),
    ],
    child: child,
  );
}

/// Top-level widget that wires the providers and exposes the route map.
class EduCompassApp extends StatelessWidget {
  final ApiClient api;
  final AuthProvider auth;
  final SharedPreferences prefs;
  final DeepLinkService deepLinks;

  const EduCompassApp({
    super.key,
    required this.api,
    required this.auth,
    required this.prefs,
    required this.deepLinks,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => CourseProvider(api)),
        ChangeNotifierProvider(create: (_) => UserProvider(api)),
        ChangeNotifierProvider(create: (_) => EnrollmentProvider(prefs, api)),
        ChangeNotifierProvider(create: (_) => ThemeProvider(prefs)),
        // Expose the singleton DeepLinkService constructed in
        // `main.dart` so MockPaymentScreen (and any future deep-link
        // consumers) can `context.read<DeepLinkService>()` instead of
        // crashing with a missing-provider assertion.
        Provider<DeepLinkService>.value(value: deepLinks),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) => MaterialApp(
          title: 'EduCompass',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: theme.mode,
          // AuthWrapper subscribes to AuthProvider.user and swaps between
          // LoginScreen and ShellScreen. The JWT lives in SharedPreferences
          // so a cold restart lands back on the right screen.
          home: const _EnrollmentRemoteSync(child: AuthWrapper()),
          routes: {
            // The "For you" tab lives inside the bottom-nav shell, so
            // routing to it from a screen outside the shell (e.g. the
            // home search bar) needs to push a fresh ShellScreen with
            // the requested tab selected. We unpack the optional
            // `{query}` payload so the search box can be prefilled —
            // see [RecommendationsScreen] for the read side.
            AppRoutes.recommendations: (ctx) {
              final args = ModalRoute.of(ctx)?.settings.arguments;
              final initialQuery = args is Map && args['query'] is String
                  ? args['query'] as String
                  : '';
              // 1 = "For you" tab in both the guest and signed-in
              // tab orderings (Home at 0, For you at 1, then My
              // Courses/Favorites/Profile). The shell clamps the
              // index at build time so an out-of-range value falls
              // back to Home without crashing.
              return wrapWithProviders(
                ctx,
                ShellScreen(
                  initialTabIndex: 1,
                  initialQuery: initialQuery,
                ),
              );
            },
            AppRoutes.courseDetails: (ctx) {
              final id =
                  ModalRoute.of(ctx)?.settings.arguments as String? ?? '';
              return wrapWithProviders(ctx, CourseDetailsScreen(courseId: id));
            },
            AppRoutes.learningPathDetail: (ctx) {
              final id =
                  ModalRoute.of(ctx)?.settings.arguments as String? ?? '';
              return wrapWithProviders(
                ctx,
                LearningPathDetailScreen(pathId: id),
              );
            },
          },
        ),
      ),
    );
  }
}

/// Bridges [AuthProvider.isLoggedIn] → [EnrollmentProvider]'s remote
/// subscription. On login we kick off `refreshFromRemote(...)` so any
/// Firestore-only enrollments get merged into the local prefs-backed set;
/// on logout we tear the subscription down so we don't keep listening for
/// a user who has just signed out.
///
/// Lives at the root of the widget tree (above [AuthWrapper]) so the
/// subscription outlives any screen swaps inside the shell.
class _EnrollmentRemoteSync extends StatefulWidget {
  const _EnrollmentRemoteSync({required this.child});
  final Widget child;

  @override
  State<_EnrollmentRemoteSync> createState() => _EnrollmentRemoteSyncState();
}

class _EnrollmentRemoteSyncState extends State<_EnrollmentRemoteSync> {
  bool _lastSignedIn = false;

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final signedIn = auth.isLoggedIn;
    if (signedIn != _lastSignedIn) {
      _lastSignedIn = signedIn;
      // Schedule after this build so we don't call setState / mutate
      // providers during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final enrollments = context.read<EnrollmentProvider>();
        if (signedIn) {
          enrollments.refreshFromRemote();
        } else {
          enrollments.cancelRemoteSubscription();
        }
      });
    }
    return widget.child;
  }
}
