/// Single HTTP client used by every provider in the app.
///
/// Wraps every Flask endpoint, injects the JWT bearer token, maps errors to
/// [ApiException], and applies a global timeout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;
  final String? code;

  const ApiException(this.statusCode, this.message, {this.code});

  @override
  String toString() => 'ApiException($statusCode, $code): $message';
}

class ApiConfig {
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:5000',
  );
}

class ApiClient {
  final String baseUrl;
  final http.Client _http;
  String? _cachedBearer;

  ApiClient({String? baseUrl, http.Client? httpClient})
      : baseUrl = (baseUrl ?? ApiConfig.defaultBaseUrl)
            .replaceAll(RegExp(r'/$'), ''),
        _http = httpClient ?? http.Client();

  Uri _url(String path, [Map<String, dynamic>? query]) {
    final qp = query
        ?.map((k, v) => MapEntry(k, v?.toString()))
      ?..removeWhere((k, v) => v == null);
    return Uri.parse('$baseUrl/api/v1$path').replace(queryParameters: qp);
  }

  void setToken(String? token) {
    _cachedBearer = (token != null && token.isNotEmpty) ? 'Bearer $token' : null;
  }

  Map<String, String> _headers({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    if (_cachedBearer != null) headers['Authorization'] = _cachedBearer!;
    return headers;
  }

  Future<Map<String, dynamic>> _decode(http.Response response) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      body = {'success': false, 'message': response.body};
    }
    if (response.statusCode >= 200 && response.statusCode < 300 &&
        body['success'] == true) {
      final data = body['data'];
      if (data is Map<String, dynamic>) return data;
      return {'value': data};
    }
    throw ApiException(
      response.statusCode,
      (body['message'] ?? 'Request failed').toString(),
      code: body['error_code']?.toString(),
    );
  }

  Future<Map<String, dynamic>> _get(String path,
      [Map<String, dynamic>? query]) async {
    final uri = _url(path, query);
    final response = await _http
        .get(uri, headers: _headers(json: false))
        .timeout(const Duration(seconds: 12));
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
      String path, Map<String, dynamic> body,
      {bool auth = true}) async {
    final uri = _url(path);
    final headers = _headers();
    if (!auth) headers.remove('Authorization');
    final response = await _http
        .post(uri, headers: headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return _decode(response);
  }

  Future<Map<String, dynamic>> _put(String path,
      [Map<String, dynamic>? body]) async {
    final uri = _url(path);
    final response = await _http
        .put(uri,
            headers: _headers(),
            body: body == null ? null : jsonEncode(body))
        .timeout(const Duration(seconds: 12));
    return _decode(response);
  }

  Future<Map<String, dynamic>> _delete(String path) async {
    final uri = _url(path);
    final response = await _http
        .delete(uri, headers: _headers(json: false))
        .timeout(const Duration(seconds: 12));
    return _decode(response);
  }

  // --- Auth ----------------------------------------------------------------

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

  // --- Courses -------------------------------------------------------------

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

  Future<List<Course>> similarCourses(String courseId,
      {int limit = 6}) async {
    final data = await _get('/courses/$courseId/similar', {'limit': limit});
    return _mapCourses(data['results']);
  }

  // --- Recommendations -----------------------------------------------------

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
    final data = await _post(
      '/recommendations/personalized',
      {'top_n': limit},
    );
    return _mapCourses(data['recommendations']);
  }

  // --- Favourites, progress ----------------------------------------------

  Future<List<Course>> favorites() async {
    final data = await _get('/me/favorites');
    final hydrated = _mapCourses(data['results']);
    if (hydrated.isNotEmpty) return hydrated;
    // Fallback: when the server returns only the legacy summary, rehydrate
    // each entry by hitting the course-detail endpoint. This is a one-time
    // cost on the empty-state cold start.
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

  Future<void> updateCourseProgress(String courseId, int percent,
      {bool completed = false}) {
    return _put('/me/progress/$courseId', {
      'progress': percent,
      'completed': completed,
    });
  }

  // --- Learning paths ------------------------------------------------------

  Future<List<LearningPath>> learningPaths() async {
    final data = await _get('/learning-paths');
    final raw = (data['paths'] as List?) ??
        (data['results'] as List?) ??
        const [];
    return raw
        .whereType<Map>()
        .map((m) => LearningPath.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  Future<LearningPath> learningPath(String pathId) async {
    final data = await _get('/learning-paths/$pathId');
    return LearningPath.fromJson(
        (data['path'] as Map).cast<String, dynamic>());
  }

  Future<Map<String, dynamic>> learningPathProgress(String pathId) async {
    final data = await _get('/learning-paths/$pathId/progress');
    return (data['progress'] as Map?)?.cast<String, dynamic>() ?? const {};
  }

  Future<void> updateLearningPathProgress(String pathId, String stepId,
      {required bool completed}) {
    return _put('/learning-paths/$pathId/progress', {
      'step_id': stepId,
      'completed': completed,
    });
  }


  // --- Billing --------------------------------------------------------------

  Future<BillingOtpRequest> requestBillingOtp(String phone) async {
    final data = await _post('/billing/otp/request', {'phone': phone},
        auth: false);
    return BillingOtpRequest(
      reference: (data['reference'] ?? '').toString(),
      hint: (data['hint'] ?? '').toString(),
    );
  }

  Future<BillingOtpVerify> verifyBillingOtp(String phone, String code) async {
    final data = await _post('/billing/otp/verify', {
      'phone': phone,
      'code': code,
    }, auth: false);
    return BillingOtpVerify(
      verified: data['verified'] == true,
      reference: (data['reference'] ?? '').toString(),
    );
  }

  Future<SubscriptionInfo?> getSubscription() async {
    final data = await _get('/billing/subscription');
    final raw = data['subscription'];
    if (raw is! Map) return null;
    return SubscriptionInfo.fromJson(raw.cast<String, dynamic>());
  }

  Future<SubscriptionInfo> activateSubscription({
    required String plan,
    required String phone,
    required String providerReference,
  }) async {
    final data = await _post('/billing/subscription/activate', {
      'plan': plan,
      'phone': phone,
      'provider_reference': providerReference,
    });
    final raw = data['subscription'];
    if (raw is! Map) {
      throw ApiException(500, 'Server did not return a subscription');
    }
    return SubscriptionInfo.fromJson(raw.cast<String, dynamic>());
  }

  List<Course> _mapCourses(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((m) => Course.fromJson(m.cast<String, dynamic>()))
        .toList();
  }
}


/// Server response wrapper for `/billing/otp/request`.
class BillingOtpRequest {
  final String reference;
  final String hint;
  const BillingOtpRequest({required this.reference, required this.hint});
}


/// Server response wrapper for `/billing/otp/verify`.
class BillingOtpVerify {
  final bool verified;
  final String reference;
  const BillingOtpVerify({required this.verified, required this.reference});
}


/// Server response wrapper for `/billing/subscription` and the activate call.
class SubscriptionInfo {
  final String provider;
  final String planCode;
  final String status;
  final String? providerReference;
  final String? subscriberIdMasked;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final bool isPremium;

  const SubscriptionInfo({
    required this.provider,
    required this.planCode,
    required this.status,
    this.providerReference,
    this.subscriberIdMasked,
    this.startedAt,
    this.expiresAt,
    required this.isPremium,
  });

  factory SubscriptionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? parse(Object? v) {
      if (v is String && v.isNotEmpty) {
        return DateTime.tryParse(v)?.toLocal();
      }
      return null;
    }

    return SubscriptionInfo(
      provider: (json['provider'] ?? '').toString(),
      planCode: (json['plan_code'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      providerReference: json['provider_reference']?.toString(),
      subscriberIdMasked: json['subscriber_id_masked']?.toString(),
      startedAt: parse(json['started_at']),
      expiresAt: parse(json['expires_at']),
      isPremium: json['is_premium'] == true,
    );
  }
}
