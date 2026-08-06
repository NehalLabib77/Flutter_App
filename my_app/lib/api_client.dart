/// Single HTTP client used by every provider in the app.
///
/// Wraps every Flask endpoint, injects the JWT bearer token, maps
/// errors to [ApiException], and applies a global timeout.
///
/// The base URL is read from `lib/config/api_config.dart`. Override at
/// build time with
///   --dart-define=API_BASE_URL=https://my-other-host.example.com
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config/api_config.dart';
import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String? code;

  const ApiException(this.statusCode, this.message, {this.code});

  /// True when the failure was a network problem (DNS, socket, TLS)
  /// rather than a server-side HTTP error.
  bool get isNetwork => statusCode == 0;

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

class ApiClient {
  final String baseUrl;
  final http.Client _http;

  /// The JWT (or Firebase ID token) used as `Authorization: Bearer …`.
  /// Set by [setToken] / [setFirebaseIdToken].
  String? _cachedBearer;

  ApiClient({String? baseUrl, http.Client? httpClient})
    : baseUrl = baseUrl ?? ApiConfig.baseUrl,
      _http = httpClient ?? http.Client();

  // ---------------------------------------------------------------------------
  // URL helpers
  // ---------------------------------------------------------------------------

  /// Build the full URL for a path under the `/api/v1` prefix.
  Uri _url(String path, [Map<String, dynamic>? query]) {
    final qp = query?.map((k, v) => MapEntry(k, v?.toString()))
      ?..removeWhere((k, v) => v == null);
    return Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: qp);
  }

  /// Build the full URL for a path under the unprefixed `/api`
  /// namespace (health probes, etc.).
  Uri _apiUrl(String path, [Map<String, dynamic>? query]) {
    final qp = query?.map((k, v) => MapEntry(k, v?.toString()))
      ?..removeWhere((k, v) => v == null);
    return Uri.parse('$baseUrl/api$path').replace(queryParameters: qp);
  }

  // ---------------------------------------------------------------------------
  // Auth header management
  // ---------------------------------------------------------------------------

  /// Set the Flask JWT (`access_token`) returned by `/auth/login`.
  void setToken(String? token) {
    _cachedBearer = (token != null && token.isNotEmpty)
        ? 'Bearer $token'
        : null;
  }

  /// Alias used by the Firebase flow — the wire format is the same,
  /// just a different source.
  void setFirebaseIdToken(String? token) => setToken(token);

  Map<String, String> _headers({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (_cachedBearer != null) headers['Authorization'] = _cachedBearer!;
    return headers;
  }

  // ---------------------------------------------------------------------------
  // Response decoding
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _decode(http.Response response) async {
    final raw = response.body;
    Map<String, dynamic> body;
    try {
      final decoded = jsonDecode(raw);
      body = decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'success': false, 'data': decoded};
    } catch (_) {
      // Server returned HTML (Render 404 page, captive portal, etc.).
      // Show a clean hint instead of a JSON parse error.
      throw ApiException(
        response.statusCode,
        'Backend returned a non-JSON response. '
        'Status ${response.statusCode}.',
        code: 'NON_JSON_RESPONSE',
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final successFlag = body['success'];

      // Most EduCompass endpoints use the standard
      // {"success": true, "data": {...}} envelope.
      if (successFlag == true) {
        final data = body['data'];
        if (data is Map<String, dynamic>) return data;
        return {'value': data};
      }

      // Payment callbacks/provider routes intentionally return a plain
      // JSON object so older clients and gateway tooling can consume
      // them. Accept successful 2xx payloads that do not declare an
      // explicit success flag.
      if (successFlag == null) {
        return body;
      }
    }

    final message = (body['message'] ?? 'Request failed').toString();
    final code =
        (body['error_code'] ?? body['error'] ?? body['code'])?.toString();
    throw ApiException(response.statusCode, message, code: code);
  }

  /// Wrap any caught error into either an [ApiException] (status-code
  /// errors) or a network [ApiException] (status code 0).
  Future<T> _guarded<T>(
    Future<T> Function() body,
    Uri uri,
    String method,
  ) async {
    try {
      return await body();
    } on ApiException {
      rethrow;
    } on SocketException catch (e) {
      _log(method, uri, statusCode: 0, error: e);
      throw ApiException(0, describeNetworkError(e), code: 'NETWORK_ERROR');
    } on TimeoutException catch (e) {
      _log(method, uri, statusCode: 0, error: e);
      throw ApiException(0, describeNetworkError(e), code: 'TIMEOUT');
    } on http.ClientException catch (e) {
      _log(method, uri, statusCode: 0, error: e);
      throw ApiException(0, describeNetworkError(e), code: 'CLIENT_ERROR');
    } catch (e) {
      _log(method, uri, statusCode: 0, error: e);
      throw ApiException(0, describeNetworkError(e), code: 'UNKNOWN');
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    final uri = _url(path, query);
    return _guarded(
      () async {
        final response = await _http
            .get(uri, headers: _headers(json: false))
            .timeout(ApiConfig.readTimeout);
        _log('GET', uri, statusCode: response.statusCode, response: response);
        return _decode(response);
      },
      uri,
      'GET',
    );
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool auth = true,
  }) async {
    final uri = _url(path);
    return _guarded(
      () async {
        final headers = _headers();
        if (!auth) headers.remove('Authorization');
        final response = await _http
            .post(uri, headers: headers, body: jsonEncode(body))
            .timeout(ApiConfig.readTimeout);
        _log(
          'POST',
          uri,
          statusCode: response.statusCode,
          body: body,
          response: response,
        );
        return _decode(response);
      },
      uri,
      'POST',
    );
  }

  Future<Map<String, dynamic>> _put(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = _url(path);
    return _guarded(
      () async {
        final response = await _http
            .put(
              uri,
              headers: _headers(),
              body: body == null ? null : jsonEncode(body),
            )
            .timeout(ApiConfig.readTimeout);
        _log(
          'PUT',
          uri,
          statusCode: response.statusCode,
          body: body,
          response: response,
        );
        return _decode(response);
      },
      uri,
      'PUT',
    );
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    final uri = _url(path);
    return _guarded(
      () async {
        final response = await _http
            .delete(uri, headers: _headers(json: false))
            .timeout(ApiConfig.readTimeout);
        _log(
          'DELETE',
          uri,
          statusCode: response.statusCode,
          response: response,
        );
        return _decode(response);
      },
      uri,
      'DELETE',
    );
  }

  // ---------------------------------------------------------------------------
  // Debug logging
  // ---------------------------------------------------------------------------

  void _log(
    String method,
    Uri uri, {
    required int statusCode,
    Map<String, dynamic>? body,
    http.Response? response,
    Object? error,
  }) {
    if (!ApiConfig.verboseNetworkLogging) return;
    final tag = '[EduCompass API]';
    final url = uri.toString();
    if (error != null) {
      // ignore: avoid_print
      print('$tag $method $url -> error: $error');
      return;
    }
    final resp = response;
    // ignore: avoid_print
    print('$tag $method $url -> $statusCode');
    if (body != null) {
      // ignore: avoid_print
      print(
        '$tag   request body (sanitised): '
        '${jsonEncode(ApiConfig.redact(body))}',
      );
    }
    if (resp != null && resp.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(resp.body);
        // ignore: avoid_print
        print(
          '$tag   response body (sanitised): '
          '${jsonEncode(ApiConfig.redact(decoded)).substring(0, resp.body.length.clamp(0, 2000))}',
        );
      } catch (_) {
        // ignore: avoid_print
        print(
          '$tag   response body (non-JSON, first 240 chars): '
          '${resp.body.substring(0, resp.body.length.clamp(0, 240))}',
        );
      }
    }
  }

  /// Human-readable hint for connection-level failures so screens
  /// don't have to translate `SocketException` / `TimeoutException`
  /// themselves. Includes the configured base URL so the developer
  /// can confirm they're pointed at the right host.
  String describeNetworkError(Object error) {
    if (error is SocketException) {
      return 'Cannot reach the EduCompass server at $baseUrl. '
          'Check your internet connection or build with '
          '--dart-define=API_BASE_URL=https://educompass-api.onrender.com';
    }
    if (error is TimeoutException) {
      return 'The EduCompass server at $baseUrl took too long to '
          'respond. Render free-tier services sleep after inactivity — '
          'try again in a few seconds.';
    }
    if (error is http.ClientException) {
      return 'Network error talking to $baseUrl: ${error.message}';
    }
    return 'Unexpected error contacting $baseUrl: $error';
  }

  // ---------------------------------------------------------------------------
  // Health
  // ---------------------------------------------------------------------------

  /// Hits the unprefixed `/api/health` route (Render health check).
  /// Returns the JSON body from the success envelope, or throws an
  /// [ApiException] when the server is unreachable.
  Future<Map<String, dynamic>> health() async {
    final uri = _apiUrl('/health');
    return _guarded(
      () async {
        final response = await _http
            .get(uri, headers: _headers(json: false))
            .timeout(ApiConfig.readTimeout);
        _log('GET', uri, statusCode: response.statusCode, response: response);
        return _decode(response);
      },
      uri,
      'GET',
    );
  }

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> register({
    required String fullName,
    required String email,
    required String password,
  }) {
    return _post('/auth/register', {
      'full_name': fullName,
      'email': email,
      'password': password,
    }, auth: false);
  }

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
  }) {
    return _post('/auth/login', {
      'email': email,
      'password': password,
    }, auth: false);
  }

  Future<AppUser> me() async {
    final data = await _get('/auth/me');
    return AppUser.fromJson(data.cast<String, dynamic>());
  }

  Future<AppUser> updateProfile({
    required String fullName,
    required List<String> interests,
  }) async {
    final data = await _put('/auth/profile', {
      'full_name': fullName,
      'interests': interests,
    });
    return AppUser.fromJson(data.cast<String, dynamic>());
  }

  /// Permanently delete the caller's account on the backend. After
  /// this returns, the JWT is no longer valid — the caller must call
  /// [setToken] with `null` (see [AuthProvider.deleteAccount]).
  Future<void> deleteAccount() async {
    await _delete('/auth/account');
  }

  // ---------------------------------------------------------------------------
  // Courses
  // ---------------------------------------------------------------------------

  Future<List<Course>> searchCourses(
    String query, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final data = await _get('/courses/search', {
      'q': query,
      'page': page,
      'page_size': pageSize,
    });
    final raw = (data['results'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => Course.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<List<Course>> autocomplete(String query, {int limit = 10}) async {
    final data = await _get('/courses/autocomplete', {
      'q': query,
      'limit': limit,
    });
    final raw = (data['suggestions'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => Course.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<List<Course>> popularCourses({int limit = 12}) async {
    final data = await _get('/courses/popular', {'limit': limit});
    return _mapCourses(data['results']);
  }

  Future<List<Course>> topRatedCourses({int limit = 12}) async {
    final data = await _get('/courses/top-rated', {'limit': limit});
    return _mapCourses(data['results']);
  }

  Future<Course> courseDetail(String courseId) async {
    final data = await _get('/courses/$courseId');
    return Course.fromJson((data['course'] as Map).cast<String, dynamic>());
  }

  Future<List<Course>> similarCourses(String courseId, {int limit = 6}) async {
    final data = await _get('/courses/$courseId/similar', {'limit': limit});
    return _mapCourses(data['results']);
  }

  // ---------------------------------------------------------------------------
  // Recommendations
  // ---------------------------------------------------------------------------

  Future<List<Course>> recommendByGoal(
    String query, {
    int limit = 10,
    Map<String, String>? filters,
  }) async {
    final data = await _post('/recommendations/query', {
      'query': query,
      'top_n': limit,
      'filters': filters ?? const {},
    });
    return _mapCourses(data['recommendations']);
  }

  Future<List<Course>> recommendPersonalized({int limit = 10}) async {
    final data = await _post('/recommendations/personalized', {'top_n': limit});
    return _mapCourses(data['recommendations']);
  }

  // ---------------------------------------------------------------------------
  // Favourites, progress
  // ---------------------------------------------------------------------------

  Future<List<Course>> favorites() async {
    final data = await _get('/me/favorites');
    final hydrated = _mapCourses(data['results']);
    if (hydrated.isNotEmpty) return hydrated;
    // Fallback: when the server returns only the legacy summary,
    // rehydrate each entry by hitting the course-detail endpoint.
    final ids = ((data['favorites'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => (m['course_id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (ids.isEmpty) return const [];
    final out = <Course>[];
    for (final cid in ids) {
      try {
        out.add(await courseDetail(cid));
      } on ApiException {
        // Skip rows the model no longer knows about.
      }
    }
    return out;
  }

  Future<void> addFavorite(String courseId) =>
      _post('/me/favorites', {'course_id': courseId});

  Future<void> removeFavorite(String courseId) =>
      _delete('/me/favorites/$courseId');

  Future<void> updateCourseProgress(
    String courseId,
    int percent, {
    bool completed = false,
  }) {
    return _put('/me/progress/$courseId', {
      'progress': percent,
      'completed': completed,
    });
  }

  // ---------------------------------------------------------------------------
  // Enrollments (paid + free courses the user has signed up for)
  // ---------------------------------------------------------------------------

  Future<List<String>> enrollments() async {
    final data = await _get('/me/enrollments');
    final raw = (data['enrollments'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => (m['course_id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> addEnrollment({
    required String courseId,
    required String paymentMethod,
    required String transactionId,
    String paymentStatus = 'completed',
  }) {
    return _post('/me/enrollments', {
      'course_id': courseId,
      'payment_method': paymentMethod,
      'transaction_id': transactionId,
      'payment_status': paymentStatus,
    });
  }

  Future<void> removeEnrollment(String courseId) =>
      _delete('/me/enrollments/$courseId');

  // ---------------------------------------------------------------------------
  // Payments (SSLCOMMERZ)
  // ---------------------------------------------------------------------------

  /// Returns the active billing provider exposed by the backend. The
  /// shape is intentionally permissive (a `Map<String, dynamic>`) so we
  /// can stay forward-compatible with future providers.
  Future<Map<String, dynamic>> paymentProviderInfo() async {
    final data = await _get('/payments/provider');
    return (data as Map).cast<String, dynamic>();
  }

  /// Mints a new SSLCOMMERZ transaction and returns the gateway URL
  /// the client should open via `url_launcher`. The backend resolves
  /// the course price from `courseId`; the client **must not** send an
  /// amount. Doing so would let a tampered client under-pay for a
  /// course, so the parameter was removed.
  Future<SslCommerzSession> createSslCommerzSession({
    required String courseId,
  }) async {
    final data = await _post('/payments/sslcommerz/session', {
      'course_id': courseId,
    });
    // Backend nests the session under ``session``; fall back to the raw
    // payload for older mock endpoints.
    final raw = (data['session'] as Map?)?.cast<String, dynamic>() ?? data;
    return SslCommerzSession.fromJson(raw);
  }

  /// Polls the backend for the status of a transaction. Used as a
  /// fallback when the deep-link redirect is delayed or never arrives.
  Future<SslCommerzPaymentStatus> getSslCommerzPaymentStatus(
    String transactionId,
  ) async {
    final data = await _get('/payments/sslcommerz/status/$transactionId');
    final raw = (data['payment'] as Map?)?.cast<String, dynamic>() ?? data;
    return SslCommerzPaymentStatus.fromJson(raw);
  }

  // ---------------------------------------------------------------------------
  // Learning paths
  // ---------------------------------------------------------------------------

  Future<List<LearningPath>> learningPaths() async {
    final data = await _get('/learning-paths');
    final raw =
        (data['paths'] as List?) ?? (data['results'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => LearningPath.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<LearningPath> learningPath(String pathId) async {
    final data = await _get('/learning-paths/$pathId');
    return LearningPath.fromJson((data['path'] as Map).cast<String, dynamic>());
  }

  Future<Map<String, dynamic>> learningPathProgress(String pathId) async {
    final data = await _get('/learning-paths/$pathId/progress');
    return (data['progress'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<void> updateLearningPathProgress(
    String pathId,
    String stepId, {
    required bool completed,
  }) {
    return _put('/learning-paths/$pathId/progress', {
      'step_id': stepId,
      'completed': completed,
    });
  }

  List<Course> _mapCourses(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Course.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
}
