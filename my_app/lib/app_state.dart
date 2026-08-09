/// The four app-wide state holders wired together by `app.dart`.
///
/// Each provider extends [ChangeNotifier] so any widget can call
/// `context.watch<T>()` and rebuild when state changes.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'models.dart';
import 'services/enrollment_service.dart';
import 'services/firebase_auth_service.dart';

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
  /// Throws [ApiException] when the registration call itself failed —
  /// the screen surfaces the server-side message instead of misleadingly
  /// sending the user back to the login screen.
  Future<bool> register({
    required String fullName,
    required String email,
    required String password,
  }) async {
    // Registration must succeed before we even attempt auto-login; an
    // ApiException here is a real failure (e.g. email already taken,
    // Firebase not configured on the backend, network unreachable) and
    // should bubble up to the screen.
    await _api.register(fullName: fullName, email: email, password: password);
    // The backend returns only the user on /auth/register (no token), so we
    // try to log in immediately to obtain access/refresh tokens. If that
    // fails for any reason we surface it so the screen can fall back.
    try {
      final data = await _api.login(email: email, password: password);
      await _afterAuth(data);
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<AppUser> login({
    required String email,
    required String password,
  }) async {
    await _afterAuth(await _api.login(email: email, password: password));
    return _user!;
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    _api.setToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    // Also clear the Firebase session so the verification gate stops
    // intercepting the user. Wrapped so a missing Firebase init on
    // Web / Linux doesn't block the local sign-out.
    try {
      await FirebaseAuthServiceFactory.instance.signOutCurrent();
    } catch (_) {}
    notifyListeners();
  }

  /// Permanently delete the caller's account on the backend, then
  /// clear the local JWT so [AuthWrapper] drops the user back to the
  /// login screen. Throws [ApiException] if the backend rejects the
  /// request — in that case the local session stays intact and the
  /// caller can surface the error.
  Future<void> deleteAccount() async {
    await _api.deleteAccount();
    _token = null;
    _user = null;
    _api.setToken(null);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    // Drop the Firebase session too so the AuthWrapper doesn't keep
    // showing the verification screen for a deleted account.
    try {
      await FirebaseAuthServiceFactory.instance.signOutCurrent();
    } catch (_) {}
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


  /// Reload the signed-in user from Flask. Preference updates mirror the
  /// selected subjects/skills into the legacy interests table, so refreshing
  /// here keeps ProfileHeader and any interest-aware UI immediately current.
  Future<AppUser?> refreshUser() async {
    if (_token == null) return _user;
    final user = await _api.me();
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


/// First-launch learning preferences. These are device-local so guest users
/// immediately receive preference-aware recommendations; after sign-in the
/// same profile is mirrored to Flask by [UserProvider.loadPersonalized].
class PreferenceProvider extends ChangeNotifier {
  static const _doneKey = 'learning_preferences_onboarding_v2';
  static const _subjectsKey = 'learning_preferences_subjects';
  static const _skillsKey = 'learning_preferences_skills';
  static const _levelKey = 'learning_preferences_level';
  static const _courseTypeKey = 'learning_preferences_course_type';
  static const _certificateKey = 'learning_preferences_certificate_type';
  static const _priceKey = 'learning_preferences_price';

  final SharedPreferences _prefs;
  bool _onboardingDone;
  LearningPreferences _preferences;

  PreferenceProvider(this._prefs)
    : _onboardingDone = _prefs.getBool(_doneKey) ?? false,
      _preferences = LearningPreferences(
        subjects: _prefs.getStringList(_subjectsKey) ?? const [],
        skills: _prefs.getStringList(_skillsKey) ?? const [],
        level: _prefs.getString(_levelKey) ?? '',
        courseType: _prefs.getString(_courseTypeKey) ?? '',
        certificateType: _prefs.getString(_certificateKey) ?? '',
        pricePreference: _prefs.getString(_priceKey) ?? '',
      );

  bool get onboardingDone => _onboardingDone;
  LearningPreferences get preferences => _preferences;

  Future<void> complete(LearningPreferences preferences) async {
    _preferences = preferences;
    _onboardingDone = true;
    await Future.wait([
      _prefs.setBool(_doneKey, true),
      _prefs.setStringList(_subjectsKey, preferences.subjects),
      _prefs.setStringList(_skillsKey, preferences.skills),
      _prefs.setString(_levelKey, preferences.level),
      _prefs.setString(_courseTypeKey, preferences.courseType),
      _prefs.setString(_certificateKey, preferences.certificateType),
      _prefs.setString(_priceKey, preferences.pricePreference),
    ]);
    notifyListeners();
  }

  /// Clears the deleted account's recommendation profile from this device
  /// without reopening the install-time guest onboarding. The next signed-in
  /// account is still checked against /me/preferences during login; when the
  /// server preference row is absent, that account must complete setup again.
  Future<void> clearForDeletedAccount() async {
    _preferences = const LearningPreferences();
    _onboardingDone = true;
    await Future.wait([
      _prefs.setBool(_doneKey, true),
      _prefs.remove(_subjectsKey),
      _prefs.remove(_skillsKey),
      _prefs.remove(_levelKey),
      _prefs.remove(_courseTypeKey),
      _prefs.remove(_certificateKey),
      _prefs.remove(_priceKey),
    ]);
    notifyListeners();
  }

  /// Finishes onboarding without forcing a choice. Ranking then falls back
  /// to quality/popularity until the user supplies preferences or behavior.
  Future<void> skip() => complete(const LearningPreferences());
}

/// Owns browse/search state and the in-memory cache of recent queries.
class CourseProvider extends ChangeNotifier {
  final ApiClient _api;

  CourseProvider(this._api);

  List<Course> _popular = const [];
  List<Course> _topRated = const [];
  bool _loadingPopular = false;
  bool _loadingTopRated = false;
  String? _popularError;
  String? _topRatedError;

  List<Course> get popular => _popular;
  List<Course> get topRated => _topRated;
  bool get loadingPopular => _loadingPopular;
  bool get loadingTopRated => _loadingTopRated;
  String? get popularError => _popularError;
  String? get topRatedError => _topRatedError;

  Future<void> loadPopular({LearningPreferences? preferences}) async {
    _loadingPopular = true;
    _popularError = null;
    notifyListeners();
    try {
      _popular = await _api.popularCourses(preferences: preferences);
    } on ApiException catch (e) {
      _popularError = e.message;
    } catch (e) {
      _popularError = _api.describeNetworkError(e);
    } finally {
      _loadingPopular = false;
      notifyListeners();
    }
  }

  Future<void> loadTopRated({LearningPreferences? preferences}) async {
    _loadingTopRated = true;
    _topRatedError = null;
    notifyListeners();
    try {
      _topRated = await _api.topRatedCourses(preferences: preferences);
    } on ApiException catch (e) {
      _topRatedError = e.message;
    } catch (e) {
      _topRatedError = _api.describeNetworkError(e);
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
  String? _favoritesError;
  List<Course> _personalized = const [];
  bool _loadingPersonalized = false;
  String? _personalizedError;

  Set<String> get favoriteIds => _favoriteIds;
  List<Course> get favorites => _favorites;
  bool get loadingFavorites => _loadingFavorites;
  String? get favoritesError => _favoritesError;
  List<Course> get personalized => _personalized;
  bool get loadingPersonalized => _loadingPersonalized;
  String? get personalizedError => _personalizedError;

  bool isFavorite(String courseId) => _favoriteIds.contains(courseId);

  Future<void> loadFavorites() async {
    _loadingFavorites = true;
    _favoritesError = null;
    notifyListeners();
    try {
      _favorites = await _api.favorites();
      _favoriteIds = _favorites.map((c) => c.id).toSet();
    } on ApiException catch (error) {
      _favoritesError = _authenticatedErrorMessage(error);
    } catch (error) {
      _favoritesError = _api.describeNetworkError(error);
    } finally {
      _loadingFavorites = false;
      notifyListeners();
    }
  }

  Future<void> toggleFavorite(Course course) async {
    try {
      if (_favoriteIds.contains(course.id)) {
        await _api.removeFavorite(course.id);
        _favoriteIds.remove(course.id);
        _favorites = _favorites.where((c) => c.id != course.id).toList();
      } else {
        await _api.addFavorite(course.id);
        _favoriteIds.add(course.id);
        _favorites = [..._favorites, course];
      }
      _favoritesError = null;
      notifyListeners();
    } on ApiException catch (error) {
      throw ApiException(
        error.statusCode,
        _authenticatedErrorMessage(error),
        code: error.code,
      );
    }
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
      await _api.updateCourseProgress(courseId, clamped, completed: done);
    } catch (_) {
      // Network failure is non-fatal; keep local state and retry later.
    }
  }

  Future<void> loadPersonalized({
    required LearningPreferences preferences,
    required bool authenticated,
  }) async {
    _loadingPersonalized = true;
    _personalizedError = null;
    notifyListeners();
    try {
      if (authenticated) {
        // Save the first-launch profile server-side for cross-device use.
        // Recommendation still sends the same profile in this request so a
        // transient preference-save issue never blocks the results.
        if (!preferences.isEmpty) {
          try {
            await _api.savePreferences(preferences);
          } catch (_) {}
        }
        _personalized = await _api.recommendPersonalized(
          preferences: preferences,
        );
      } else {
        _personalized = await _api.recommendByPreferences(preferences);
      }
    } on ApiException catch (e) {
      _personalizedError = authenticated
          ? _authenticatedErrorMessage(e)
          : e.message;
    } catch (e) {
      _personalizedError = _api.describeNetworkError(e);
    } finally {
      _loadingPersonalized = false;
      notifyListeners();
    }
  }

  Future<void> recordInteraction(String courseId, String type) async {
    try {
      await _api.recordInteraction(courseId, type);
    } catch (_) {
      // Behavioral telemetry should never stop course browsing.
    }
  }

  String _authenticatedErrorMessage(ApiException error) {
    if (error.code == 'EMAIL_NOT_VERIFIED') {
      return 'Your signed-in session could not be confirmed. '
          'Please sign out and sign in again.';
    }
    return error.message;
  }

  Future<List<Course>> recommendByGoal(
    String query, {
    int limit = 10,
    LearningPreferences? preferences,
  }) async {
    return _api.recommendByGoal(
      query,
      limit: limit,
      preferences: preferences,
    );
  }

  Future<Course> courseDetail(String courseId) => _api.courseDetail(courseId);

  Future<List<Course>> similarCourses(String courseId, {int limit = 6}) =>
      _api.similarCourses(courseId, limit: limit);

  Future<List<LearningPath>> learningPaths() => _api.learningPaths();

  Future<LearningPath> learningPath(String pathId) => _api.learningPath(pathId);

  Future<Map<String, dynamic>> learningPathProgress(String pathId) =>
      _api.learningPathProgress(pathId);

  Future<void> updateLearningPathProgress(
    String pathId,
    String stepId, {
    required bool completed,
  }) => _api.updateLearningPathProgress(pathId, stepId, completed: completed);
}

/// Tracks the signed-in user's enrollments.
///
/// Enrollment ids are cached locally for fast UI rendering, but the cache is
/// strictly account-scoped. Each backend user gets its own SharedPreferences
/// key (`enrolled_course_ids_user_<userId>`), so switching accounts can never
/// reuse another account's "My Courses" list.
///
/// Remote sync stays unchanged architecturally: Flask and Firestore are both
/// queried for the currently authenticated account and merged into that
/// account's local cache. The old device-global `enrolled_course_ids` key is
/// deliberately discarded because it may contain enrollments from multiple
/// accounts and therefore cannot be migrated safely.
class EnrollmentProvider extends ChangeNotifier {
  static const _legacyKey = 'enrolled_course_ids';
  static const _userKeyPrefix = 'enrolled_course_ids_user_';

  final SharedPreferences _prefs;
  final ApiClient _api;
  final Set<String> _ids = <String>{};

  // Enrollment taps can happen in the first frame after login, before the
  // root auth-to-enrollment bridge has rebound this provider. Keep those
  // ids temporarily so the UI updates immediately, then attach/persist them
  // to the account as soon as bindToUser() runs.
  final Set<String> _pendingIds = <String>{};

  String? _accountKey;
  String? _storageKey;

  /// Active Firestore subscription, if any. Non-null while a signed-in
  /// user is being mirrored from the remote source.
  StreamSubscription<List<String>>? _remoteSub;

  /// Set when [refreshFromRemote] is in-flight; lets the UI show a
  /// spinner without spamming Firestore/backend.
  bool _syncingFromRemote = false;
  bool get syncingFromRemote => _syncingFromRemote;

  EnrollmentProvider(this._prefs, this._api);

  Set<String> get ids => Set.unmodifiable(_ids);
  bool isEnrolled(String courseId) => _ids.contains(courseId);
  bool get isBoundToAccount => _accountKey != null;

  String _keyForAccount(String accountKey) =>
      '$_userKeyPrefix${accountKey.trim()}';

  /// Switches the local enrollment cache to [accountKey].
  ///
  /// This is intentionally synchronous because SharedPreferences reads are
  /// synchronous once the instance has been created. That lets the UI clear
  /// Account A immediately before Account B is shown.
  void bindToUser(String accountKey) {
    final normalized = accountKey.trim();
    if (normalized.isEmpty) {
      unbindUser();
      return;
    }
    if (_accountKey == normalized) return;

    cancelRemoteSubscription();
    _accountKey = normalized;
    _storageKey = _keyForAccount(normalized);

    final pending = Set<String>.of(_pendingIds);
    _pendingIds.clear();

    _ids
      ..clear()
      ..addAll(_prefs.getStringList(_storageKey!) ?? const <String>[])
      ..addAll(pending);

    // A tap that arrived just before binding now belongs to this authenticated
    // account. Persist it immediately so My Courses survives navigation/restart.
    if (pending.isNotEmpty) {
      unawaited(_prefs.setStringList(_storageKey!, _ids.toList()));
    }

    // Never import the legacy device-global list: it is exactly the source
    // of the cross-account leak and may already contain mixed ownership.
    unawaited(_prefs.remove(_legacyKey));

    _syncingFromRemote = false;
    notifyListeners();
  }

  /// Removes the active account from memory while keeping its own persisted
  /// cache for the next time that same account signs in.
  void unbindUser() {
    cancelRemoteSubscription();
    final hadState = _accountKey != null || _ids.isNotEmpty || _syncingFromRemote;
    _accountKey = null;
    _storageKey = null;
    _ids.clear();
    _pendingIds.clear();
    _syncingFromRemote = false;
    if (hadState) notifyListeners();
  }

  Future<void> _persistCurrentAccount() async {
    final key = _storageKey;
    if (key == null) return;
    await _prefs.setStringList(key, _ids.toList());
  }

  /// Adds [courseId] to the active account cache.
  ///
  /// AuthProvider and this provider are bridged at the root with a post-frame
  /// callback. On a very fast enrollment tap just after login that callback
  /// may not have executed yet. Previously we threw here, which made a valid
  /// enrollment look successful elsewhere but never appear in My Courses.
  /// We now optimistically expose the id and hold it in [_pendingIds] until
  /// bindToUser() assigns it to the authenticated account.
  Future<void> enroll(String courseId) async {
    final normalized = courseId.trim();
    if (normalized.isEmpty || _ids.contains(normalized)) return;

    _ids.add(normalized);
    if (_storageKey == null) {
      _pendingIds.add(normalized);
      notifyListeners();
      return;
    }

    await _persistCurrentAccount();
    notifyListeners();
  }

  Future<void> unenroll(String courseId) async {
    if (_storageKey == null || !_ids.contains(courseId)) return;
    _ids.remove(courseId);
    await _persistCurrentAccount();
    notifyListeners();
  }

  /// Drops [courseId] from Firestore, SQL, and the current account's local
  /// cache. Remote failures remain non-fatal exactly as before.
  Future<void> drop(
    String courseId, {
    void Function(Object error, [StackTrace? stack])? onSyncError,
  }) async {
    try {
      await EnrollmentService().deleteEnrollment(courseId);
    } catch (e, st) {
      if (onSyncError != null) onSyncError(e, st);
    }
    try {
      await _api.removeEnrollment(courseId);
    } catch (e, st) {
      if (onSyncError != null) onSyncError(e, st);
    }
    if (_ids.remove(courseId)) {
      await _persistCurrentAccount();
      notifyListeners();
    }
  }

  /// Pushes a previously-saved enrollment to the Flask backend. Safe to call
  /// after payment succeeds; the server row is idempotent.
  Future<void> pushRemote({
    required String courseId,
    required String paymentMethod,
    required String transactionId,
    String paymentStatus = 'completed',
  }) async {
    try {
      await _api.addEnrollment(
        courseId: courseId,
        paymentMethod: paymentMethod,
        transactionId: transactionId,
        paymentStatus: paymentStatus,
      );
    } catch (e, st) {
      debugPrint('EnrollmentProvider.pushRemote failed: $e\n$st');
    }
  }

  /// Pull the authenticated account's durable SQL enrollments immediately.
  ///
  /// This is deliberately awaitable. Preserved enrollments can outlive a
  /// Firebase identity (Delete Account -> re-register with the same email),
  /// so screens that must know ownership cannot rely only on the Firestore
  /// listener or a post-frame root sync. The backend user id remains the
  /// durable enrollment owner and `/me/enrollments` is the source of truth
  /// for restoring those rows.
  Future<void> refreshFromBackend() async {
    final accountKey = _accountKey;
    final storageKey = _storageKey;
    if (accountKey == null || storageKey == null) return;

    _syncingFromRemote = true;
    notifyListeners();
    try {
      final backendIds = await _api.enrollments();
      if (_accountKey != accountKey || _storageKey != storageKey) return;

      var changed = false;
      for (final rawId in backendIds) {
        final id = rawId.trim();
        if (id.isNotEmpty && _ids.add(id)) changed = true;
      }
      if (changed) {
        await _prefs.setStringList(storageKey, _ids.toList());
      }
    } finally {
      if (_accountKey == accountKey) {
        _syncingFromRemote = false;
        notifyListeners();
      }
    }
  }

  /// Refreshes enrollments for only the currently bound account.
  ///
  /// Flask is pulled immediately in the background, while the existing
  /// Firestore listener keeps live changes flowing. Every callback captures
  /// the account key and ignores stale results after an account switch.
  void refreshFromRemote([EnrollmentService? service]) {
    final accountKey = _accountKey;
    final storageKey = _storageKey;
    if (accountKey == null || storageKey == null) return;

    cancelRemoteSubscription();
    final svc = service ?? EnrollmentService();
    unawaited(
      refreshFromBackend().catchError((Object error, StackTrace stack) {
        // Local cache / Firestore can still drive the UI when Flask is
        // temporarily unavailable.
        debugPrint('Enrollment backend refresh failed: $error\n$stack');
      }),
    );

    _remoteSub = svc.myEnrolledCourseIds().listen(
      (remoteIds) {
        if (_accountKey != accountKey || _storageKey != storageKey) return;
        var changed = false;
        for (final id in remoteIds) {
          if (_ids.add(id)) changed = true;
        }
        if (changed) {
          unawaited(
            _prefs
                .setStringList(storageKey, _ids.toList())
                .then((_) => true, onError: (_) => true),
          );
        }
        _syncingFromRemote = false;
        // Always notify here so a visible sync indicator can stop even when
        // the list itself did not change.
        notifyListeners();
      },
      onError: (Object _) {
        if (_accountKey != accountKey) return;
        _syncingFromRemote = false;
        notifyListeners();
      },
    );
  }

  /// Cancels the active Firestore subscription.
  void cancelRemoteSubscription() {
    _remoteSub?.cancel();
    _remoteSub = null;
  }

  @override
  void dispose() {
    cancelRemoteSubscription();
    super.dispose();
  }
}

/// Light/dark/system theme with persistence via SharedPreferences.
class ThemeProvider extends ChangeNotifier {
  static const _key = 'theme_mode';

  final SharedPreferences _prefs;
  ThemeMode _mode;

  ThemeProvider(this._prefs) : _mode = _decode(_prefs.getString(_key));

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
