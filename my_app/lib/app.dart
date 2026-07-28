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
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider(create: (_) => CourseProvider(api)),
        ChangeNotifierProvider(create: (_) => UserProvider(api)),
        ChangeNotifierProvider(create: (_) => EnrollmentProvider(prefs)),
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
              return CourseDetailsScreen(courseId: id);
            },
            AppRoutes.learningPathDetail: (ctx) {
              final id = ModalRoute.of(ctx)?.settings.arguments as String? ?? '';
              return LearningPathDetailScreen(pathId: id);
            },
          },
        ),
      ),
    );
  }
}
