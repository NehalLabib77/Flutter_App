library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'app_state.dart';
import 'navigation.dart';
import 'screens/course_details_screen.dart';
import 'screens/favorites_screen.dart';
import 'screens/learning_path_detail_screen.dart';
import 'screens/learning_paths_screen.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/recommendations_screen.dart';
import 'screens/register_screen.dart';
import 'screens/shell_screen.dart';
import 'screens/splash_screen.dart';
import 'theme.dart';

/// Returns a [Widget] that rebuilds the same providers used by the root
/// [MultiProvider] above the supplied [child]. Named-route screens pushed
/// from `MaterialApp.routes` live above the root provider scope, so they
/// cannot resolve [ApiClient] / [AuthProvider] / etc. unless we wrap them.
///
/// Captures the live [ApiClient] / [AuthProvider] / [SharedPreferences] from
/// the outer context and re-exposes them.
Widget wrapWithProviders(BuildContext context, Widget child) {
  final api = context.read<ApiClient>();
  final auth = context.read<AuthProvider>();
  final prefs = context.read<SharedPreferences>();
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider<CourseProvider>(create: (_) => CourseProvider(api)),
      ChangeNotifierProvider<UserProvider>(create: (_) => UserProvider(api)),
      ChangeNotifierProvider<EnrollmentProvider>(
          create: (_) => EnrollmentProvider(prefs, api)),
      ChangeNotifierProvider<ThemeProvider>(
          create: (_) => ThemeProvider(prefs)),
    ],
    child: child,
  );
}

/// Top-level widget that wires the four providers and exposes the route map.
class EduCompassApp extends StatelessWidget {
  final ApiClient api;
  final AuthProvider auth;
  final SharedPreferences prefs;

  const EduCompassApp({
    super.key,
    required this.api,
    required this.auth,
    required this.prefs,
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
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, theme, _) => MaterialApp(
          title: 'EduCompass',
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: theme.mode,
          initialRoute: AppRoutes.splash,
          routes: {
            AppRoutes.splash: (_) => const SplashScreen(),
            AppRoutes.onboarding: (_) => const OnboardingScreen(),
            AppRoutes.login: (_) => const LoginScreen(),
            AppRoutes.register: (_) => const RegisterScreen(),
            AppRoutes.home: (_) => const ShellScreen(),
            AppRoutes.recommendations: (_) => const RecommendationsScreen(),
            AppRoutes.favorites: (_) => const FavoritesScreen(),
            AppRoutes.learningPaths: (_) => const LearningPathsScreen(),
            AppRoutes.profile: (_) => const ProfileScreen(),
            AppRoutes.courseDetails: (ctx) {
              final id = ModalRoute.of(ctx)?.settings.arguments as String? ?? '';
              return wrapWithProviders(ctx, CourseDetailsScreen(courseId: id));
            },
            AppRoutes.learningPathDetail: (ctx) {
              final id = ModalRoute.of(ctx)?.settings.arguments as String? ?? '';
              return wrapWithProviders(ctx, LearningPathDetailScreen(pathId: id));
            },
          },
        ),
      ),
    );
  }
}
