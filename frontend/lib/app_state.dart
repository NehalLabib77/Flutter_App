/// The four app-wide state holders wired together by `app.dart`.
///
/// Each provider extends [ChangeNotifier] so any widget can call
/// `context.watch<T>()` and rebuild when state changes.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'models.dart';

const _tokenKey = 'auth_token';

/// Tracks the JWT and the current user.
class AuthProvider extends ChangeNotifier {
  final ApiClient _api;
  String? _token;
  AppUser? _user;
  bool _bootstrapping = true;

  AuthProvider(this._api);

  String? get token => _token;
  AppUser? get user => _user;
  bool get isLoggedIn => _token != null && _user != null;
  bool get isBootstrapping => _bootstrapping;

  Future<void> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(_tokenKey);
    if (_token != null) {
      _api.setToken(_token);
      try {
        _user = await _api.me();
      } on ApiException catch (_) {
        _token = null;
        _user = null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_tokenKey);
      }
    }
    _bootstrapping = false;
    notifyListeners();
  }

  /// Returns true when registration + immediate sign-in both succeed.
  /// Returns false when the account was created but the auto-login call
  /// failed (the caller should send the user back to the login screen).
  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
    required String phone,
    required String otpReference,
  }) async {
    await _api.register(
      fullName: fullName,
      email: email,
      password: password,
      phone: phone,
      otpReference: otpReference,
    );
    // The backend returns only the user on /auth/register (no token), so we
    // try to log in immediately to obtain access/refresh tokens. If that
    // fails for any reason we surface it so the screen can fall back.
    try {
      final data = await _api.login(
        email: email,
        password: password,
        phone: phone,
        otpReference: otpReference,
      );
      await _afterAuth(data);
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<AppUser> login({
    required String email,
    required String password,
    required String phone,
    required String otpReference,
  }) async {
    await _afterAuth(await _api.login(
      email: email,
      password: password,
      phone: phone,
      otpReference: otpReference,
    ));
    return _user!;
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    _api.setToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    notifyListeners();
  }

  Future<AppUser> updateProfile({
    required String fullName,
    required List<String> interests,
  }) async {
    final user = await _api.updateProfile(
      fullName: fullName,
      interests: interests,
    );
    _user = user;
    notifyListeners();
    return user;
  }

  Future<void> _afterAuth(Map<String, dynamic> data) async {
    final token = (data['access_token'] ?? data['token'] ?? '').toString();
    if (token.isEmpty) {
      throw const ApiException(500, 'Server did not return a token');
    }
    _token = token;
    _api.setToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    final userRaw = data['user'];
    if (userRaw is Map) {
      _user = AppUser.fromJson(userRaw.cast<String, dynamic>());
    } else {
      _user = await _api.me();
    }
    notifyListeners();
  }
}

/// Owns browse/search state and the in-memory cache of recent queries.
class CourseProvider extends ChangeNotifier {
  final ApiClient _api;

  CourseProvider(this._api);

  List<Course> _popular = const [];
  List<Course> _topRated = const [];
  bool _loadingPopular = false;
  bool _loadingTopRated = false;

  List<Course> get popular => _popular;
  List<Course> get topRated => _topRated;
  bool get loadingPopular => _loadingPopular;
  bool get loadingTopRated => _loadingTopRated;

  Future<void> loadPopular() async {
    _loadingPopular = true;
    notifyListeners();
    try {
      _popular = await _api.popularCourses();
    } finally {
      _loadingPopular = false;
      notifyListeners();
    }
  }

  Future<void> loadTopRated() async {
    _loadingTopRated = true;
    notifyListeners();
    try {
      _topRated = await _api.topRatedCourses();
    } finally {
      _loadingTopRated = false;
      notifyListeners();
    }
  }

  Future<List<Course>> search(String query) =>
      _api.searchCourses(query).catchError((Object _) => <Course>[]);

  Future<List<Course>> autocomplete(String query) =>
      _api.autocomplete(query).catchError((Object _) => <Course>[]);
}

/// Favourites, history, course progress, and personalised recommendations.
class UserProvider extends ChangeNotifier {
  final ApiClient _api;

  UserProvider(this._api);

  Set<String> _favoriteIds = <String>{};
  List<Course> _favorites = const [];
  final Map<String, int> _progress = {};
  final Map<String, bool> _completed = {};
  bool _loadingFavorites = false;
  List<Course> _personalized = const [];
  bool _loadingPersonalized = false;

  Set<String> get favoriteIds => _favoriteIds;
  List<Course> get favorites => _favorites;
  bool get loadingFavorites => _loadingFavorites;
  List<Course> get personalized => _personalized;
  bool get loadingPersonalized => _loadingPersonalized;

  bool isFavorite(String courseId) => _favoriteIds.contains(courseId);

  Future<void> loadFavorites() async {
    _loadingFavorites = true;
    notifyListeners();
    try {
      _favorites = await _api.favorites();
      _favoriteIds = _favorites.map((c) => c.id).toSet();
    } finally {
      _loadingFavorites = false;
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(Course course) async {
    if (_favoriteIds.contains(course.id)) {
      await _api.removeFavorite(course.id);
      _favoriteIds.remove(course.id);
      _favorites = _favorites.where((c) => c.id != course.id).toList();
    } else {
      await _api.addFavorite(course.id);
      _favoriteIds.add(course.id);
      _favorites = [..._favorites, course];
    }
    notifyListeners();
  }

  int progressFor(String courseId) => _progress[courseId] ?? 0;
  bool completedFor(String courseId) => _completed[courseId] ?? false;

  Future<void> setProgress(String courseId, int percent) async {
    final clamped = percent.clamp(0, 100);
    _progress[courseId] = clamped;
    final done = clamped >= 100;
    _completed[courseId] = done;
    notifyListeners();
    try {
      await _api.updateCourseProgress(courseId, clamped,
          completed: done);
    } catch (_) {
      // Network failure is non-fatal; keep local state and retry later.
    }
  }

  Future<void> loadPersonalized() async {
    _loadingPersonalized = true;
    notifyListeners();
    try {
      _personalized = await _api.recommendPersonalized();
    } finally {
      _loadingPersonalized = false;
      notifyListeners();
    }
  }

  Future<List<Course>> recommendByGoal(String query, {int limit = 10}) async {
    return _api.recommendByGoal(query, limit: limit);
  }

  Future<Course> courseDetail(String courseId) => _api.courseDetail(courseId);

  Future<List<Course>> similarCourses(String courseId,
          {int limit = 6}) =>
      _api.similarCourses(courseId, limit: limit);

  Future<List<LearningPath>> learningPaths() => _api.learningPaths();

  Future<LearningPath> learningPath(String pathId) =>
      _api.learningPath(pathId);

  Future<Map<String, dynamic>> learningPathProgress(String pathId) =>
      _api.learningPathProgress(pathId);

  Future<void> updateLearningPathProgress(String pathId, String stepId,
          {required bool completed}) =>
      _api.updateLearningPathProgress(pathId, stepId, completed: completed);
}

/// Tracks the user's enrollments (local + persisted via SharedPreferences).
///
/// The backend does not expose an enrollment endpoint yet, so we keep the
/// list on-device. This lets "Enroll" -> "Pay" add a course to the user's
/// learning list immediately, and survive a cold restart.
class EnrollmentProvider extends ChangeNotifier {
  static const _key = 'enrolled_course_ids';

  final SharedPreferences _prefs;
  final Set<String> _ids;

  EnrollmentProvider(this._prefs)
      : _ids = (_prefs.getStringList(_key) ?? const []).toSet();

  Set<String> get ids => _ids;
  bool isEnrolled(String courseId) => _ids.contains(courseId);

  Future<void> enroll(String courseId) async {
    if (_ids.contains(courseId)) return;
    _ids.add(courseId);
    await _prefs.setStringList(_key, _ids.toList());
    notifyListeners();
  }

  Future<void> unenroll(String courseId) async {
    if (!_ids.contains(courseId)) return;
    _ids.remove(courseId);
    await _prefs.setStringList(_key, _ids.toList());
    notifyListeners();
  }
}

/// Light/dark/system theme with persistence via SharedPreferences.
class ThemeProvider extends ChangeNotifier {
  static const _key = 'theme_mode';

  final SharedPreferences _prefs;
  ThemeMode _mode;

  ThemeProvider(this._prefs)
      : _mode = _decode(_prefs.getString(_key));

  ThemeMode get mode => _mode;

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    await _prefs.setString(_key, _encode(mode));
    notifyListeners();
  }

  static ThemeMode _decode(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}