/// Centralized API configuration.
///
/// Every HTTP call in the app goes through [ApiClient] in
/// `lib/api_client.dart`, which reads [ApiConfig.baseUrl] from this file.
/// Keeping the configuration in one place makes it impossible for the
/// app to accidentally call `localhost`, `10.0.2.2`, or two different
/// Render URLs from different screens.
///
/// ---------------------------------------------------------------------------
/// Production / staging / dev override
/// ---------------------------------------------------------------------------
///
/// Override the host at build time without touching source:
///
///   flutter run --dart-define=API_BASE_URL=https://my-other-host.example.com
///
/// Anything else (timeouts, headers, debug logging) is exposed as a
/// public field and can be overridden in tests by passing a custom
/// [ApiClient].
library;

import 'package:flutter/foundation.dart';

class ApiConfig {
  ApiConfig._();

  /// The bare backend host. The HTTP client always appends `/api/v1`
  /// (or `/api` for the health probe), so this string MUST NOT contain
  /// a trailing `/`, must NOT contain `/api/v1`, and MUST start with
  /// `http://` or `https://`.
  ///
  /// The placeholder below is the Render host you configured; replace
  /// it with your actual service URL before shipping a release build.
  static const String _productionBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://educompass-api.onrender.com',
  );

  /// Effective base URL used by [ApiClient].
  ///
  /// We always strip a trailing `/` so joining paths with `$baseUrl/api/v1`
  /// never accidentally produces `https://.../api/v1`.
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

    // Make sure the scheme is present and is http(s). `10.0.2.2`
    // without a scheme used to silently fall back to plain http on
    // some platforms — force https for any host that doesn't start
    // with one.
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
