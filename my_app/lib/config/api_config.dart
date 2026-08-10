
/// [ApiClient].
library;

import 'package:flutter/foundation.dart';

class ApiConfig {
  ApiConfig._();


  static const String _productionBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://educompass-api.onrender.com',
  );


  static String get baseUrl => _sanitize(_productionBaseUrl);

  /// Whether debug logging of full URLs, status codes and response
  /// bodies is enabled. Defaults to `true` while running in debug
  /// (which is what `flutter run` does) and `false` for release builds.
  ///
  /// **No secrets are ever logged** — passwords, JWTs, Firebase ID
  /// tokens and refresh tokens are redacted by [redact].
  static bool get verboseNetworkLogging => kDebugMode;

  /// Timeouts applied to every outbound HTTP call. Render free-tier
  /// services sleep after inactivity and take ~30 s to cold-start, so
  /// the read timeout is intentionally generous.
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration readTimeout = Duration(seconds: 45);
  static const Duration writeTimeout = Duration(seconds: 30);

  // -------------------------------------------------------------------------
  // Sanitisation
  // -------------------------------------------------------------------------

  static String _sanitize(String input) {
    var url = input.trim();

    // Strip a trailing slash so `$baseUrl/api/v1` never becomes
    // `$baseUrl//api/v1`.
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    // Strip accidental `/api/v1` / `/api` suffix — the client owns
    // those prefixes and would otherwise produce
    // `https://host/api/v1/api/v1/...`.
    final lowered = url.toLowerCase();
    for (final suffix in ['/api/v1', '/api/']) {
      if (lowered.endsWith(suffix)) {
        url = url.substring(0, url.length - suffix.length);
        break;
      }
    }
    if (url.toLowerCase().endsWith('/api')) {
      url = url.substring(0, url.length - 4);
    }


    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }

    return url;
  }

  /// Redact any secret-looking fields from a JSON-like map before
  /// logging. The matcher is intentionally conservative — better to
  /// redact a few non-secrets than to leak a JWT.
  static Object? redact(Object? value) {
    if (value is Map) {
      return value.map((k, v) {
        final key = k.toString().toLowerCase();
        final isSecret =
            key.contains('password') ||
            key.contains('token') ||
            key.contains('secret') ||
            key.contains('authorization') ||
            key.contains('refresh') ||
            key.contains('id_token');
        return MapEntry(k.toString(), isSecret ? '***redacted***' : redact(v));
      });
    }
    if (value is List) {
      return value.map(redact).toList();
    }
    return value;
  }
}
