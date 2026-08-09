/// Billing abstraction for EduCompass.
///
/// Why an abstraction here
/// ------------------------
/// Every paid-course code path in the app talks to the backend over
/// HTTPS using the JWT that [ApiClient] already manages. The gateway
/// credentials (SSLCOMMERZ `store_id` / `store_password`) live on the
/// server, never on the device. We still want a layer between the
/// screens and [ApiClient] so that:
///
///   * The free-provider case is handled without an HTTP round-trip.
///   * Tests can swap the gateway for an in-memory fake without
///     touching network code.
///   * Production code never accidentally picks the mock provider —
///     a build-time flag has to be flipped for that to happen.
///
/// **Security invariants the abstraction enforces**
///
///   * `createSession` takes only a `courseId`. There is no amount
///     parameter; tampering with the client cannot under-pay because
///     the price is resolved server-side from the course id.
///   * `createSession` takes no user id. The backend identifies the
///     user from the bearer JWT that [ApiClient] already attaches.
///   * `getStatus` is the source of truth. Callers must gate
///     enrollment on `SslCommerzPaymentStatus.isValid` rather than
///     on the deep-link redirect's `status` query parameter.
///   * Nullable gateway fields (`card_type`, `bank_transaction_id`,
///     `risk_level`, etc.) are parsed defensively — missing values
///     become `null`, never throw.
///   * The mock provider is opt-in via `--dart-define=USE_MOCK_PAYMENT=true`
///     and is never the default for paid courses.
library;

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../models.dart';

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Compile-time configuration for the billing abstraction.
///
/// The mock provider is **never** the default for paid courses. The
/// only way to enable it is to pass
/// `--dart-define=USE_MOCK_PAYMENT=true` at build time:
///
///   flutter run --dart-define=USE_MOCK_PAYMENT=true
///
/// At runtime, [useMockPayment] therefore reflects an explicit
/// developer choice, not a default — which is what we want for a
/// production build where the gateway MUST be SSLCOMMERZ.
class BillingConfig {
  BillingConfig._();

  /// `true` only when the build was launched with
  /// `--dart-define=USE_MOCK_PAYMENT=true`. Defaults to `false`,
  /// which routes paid courses through [SslCommerzBillingProvider].
  static const bool useMockPayment = bool.fromEnvironment(
    'USE_MOCK_PAYMENT',
    defaultValue: false,
  );

  /// Identifier the factory exposes when the user has opted into
  /// the mock provider via [useMockPayment]. The backend's
  /// `/payments/provider` endpoint never returns this value, so it
  /// is exclusively a client-side signal.
  static const String mockProviderName = 'mock';

  /// Identifier the factory exposes for the free (no-gateway) path.
  /// Mirrors the backend's `'free'` provider name so log lines and
  /// UI copy stay consistent.
  static const String freeProviderName = 'free';

  /// Identifier the factory exposes for the SSLCOMMERZ-backed
  /// provider. Mirrors the backend's `'sslcommerz'` provider name.
  static const String sslcommerzProviderName = 'sslcommerz';
}

// ---------------------------------------------------------------------------
// Abstract billing provider
// ---------------------------------------------------------------------------

/// Contract every billing implementation must satisfy.
///
/// Two of the three implementations below make a network call
/// ([SslCommerzBillingProvider], [MockBillingProvider]); the third
/// ([FreeBillingProvider]) short-circuits before any HTTP traffic.
abstract class BillingProvider {
  /// Identifier surfaced in logs and `/payments/provider`-style
  /// introspection. Implementations should return a stable, lower-case
  /// token (e.g. `'sslcommerz'`, `'free'`, `'mock'`).
  String get name;

  /// Whether the implementation short-circuits to a free enrollment
  /// without contacting a gateway. Used by callers that want to skip
  /// the deep-link / polling dance entirely.
  bool get isFree;

  /// Mints a new transaction for [courseId] and returns the session
  /// details (transaction id, gateway URL, etc.).
  ///
  /// Implementations MUST NOT accept an amount — doing so would let
  /// a tampered client under-pay for a course. The backend resolves
  /// the price from `courseId` server-side.
  ///
  /// Throws [ApiException] when the backend refuses or is
  /// unreachable. Free providers return a synthetic
  /// [SslCommerzSession] without making a network call.
  Future<SslCommerzSession> createSession({required String courseId});

  /// Polls the authoritative status endpoint for [transactionId].
  ///
  /// **Always prefer this over the deep-link redirect.** The redirect
  /// is a UX hint, not a proof of payment. A payment may complete
  /// server-side without the redirect ever arriving (network drop,
  /// user closed the browser tab, etc.).
  ///
  /// Throws [ApiException] when the backend is unreachable or
  /// returns a non-2xx status. A 404 surfaces as
  /// `ApiException(statusCode: 404)` so callers can distinguish
  /// "unknown transaction" from "server is down".
  Future<SslCommerzPaymentStatus> getStatus(String transactionId);
}

// ---------------------------------------------------------------------------
// Free provider — used when the backend reports no gateway is active
// ---------------------------------------------------------------------------

/// No-gateway implementation. Never makes a network call. Returns
/// a synthetic [SslCommerzSession] that callers can immediately
/// treat as validated.
class FreeBillingProvider implements BillingProvider {
  const FreeBillingProvider();

  @override
  String get name => BillingConfig.freeProviderName;

  @override
  bool get isFree => true;

  @override
  Future<SslCommerzSession> createSession({required String courseId}) async {
    // No HTTP round-trip — the backend's free provider path already
    // resolved the price; the client just needs a session token to
    // bind the result UI to. We synthesise one with a stable prefix
    // so logs and analytics can still tell free enrollments apart
    // from SSLCOMMERZ transactions.
    final stamp = DateTime.now().microsecondsSinceEpoch.toString();
    return SslCommerzSession(
      transactionId: 'FREE-$courseId-$stamp',
      gatewayPageUrl: '',
      status: 'validated',
      provider: name,
      courseId: courseId,
    );
  }

  @override
  Future<SslCommerzPaymentStatus> getStatus(String transactionId) async {
    // Free providers short-circuit; there is no row on the backend
    // to poll. We return a synthetic `validated` status so callers
    // can use the same `isValid` check regardless of provider.
    return SslCommerzPaymentStatus(
      transactionId: transactionId,
      status: 'validated',
      paymentMethod: 'free',
      enrolled: true,
      enrollmentStatus: 'active',
      validated: true,
      enrollmentCompleted: true,
    );
  }
}

// ---------------------------------------------------------------------------
// SSLCOMMERZ provider — production default
// ---------------------------------------------------------------------------

/// Production billing provider. Delegates to [ApiClient], which:
///
///   * already attaches the JWT bearer header,
///   * already serialises JSON correctly,
///   * already surfaces backend failures as [ApiException].
///
/// This class exists so screens can depend on [BillingProvider]
/// instead of on [ApiClient] directly, which makes them testable
/// without the HTTP layer and keeps the "paid courses go through
/// SSLCOMMERZ" invariant in one place.
class SslCommerzBillingProvider implements BillingProvider {
  SslCommerzBillingProvider({required ApiClient api}) : _api = api;

  final ApiClient _api;

  @override
  String get name => BillingConfig.sslcommerzProviderName;

  @override
  bool get isFree => false;

  @override
  Future<SslCommerzSession> createSession({required String courseId}) async {
    // `ApiClient.createSslCommerzSession` enforces the no-amount,
    // no-user-id invariant in its own doc-comment; we deliberately
    // don't take those parameters here either.
    return _api.createSslCommerzSession(courseId: courseId);
  }

  @override
  Future<SslCommerzPaymentStatus> getStatus(String transactionId) {
    return _api.getSslCommerzPaymentStatus(transactionId);
  }
}

// ---------------------------------------------------------------------------
// Mock provider — opt-in only, never the default for paid courses
// ---------------------------------------------------------------------------

/// In-memory fake for unit tests. Not wired into the app at runtime
/// unless [BillingConfig.useMockPayment] is `true`.
///
/// The mock has its own internal transaction store so tests can
/// drive the full `createSession` → `getStatus` round-trip without
/// any HTTP traffic, and without touching the backend's `/payments/*`
/// endpoints.
class MockBillingProvider implements BillingProvider {
  MockBillingProvider();

  /// Pre-seeded responses used by [createSession] and [getStatus].
  /// Tests can mutate these between calls to simulate different
  /// gateway states.
  SslCommerzSession Function(String courseId)? sessionBuilder;
  SslCommerzPaymentStatus Function(String transactionId)? statusBuilder;

  final List<String> createdTransactions = [];
  final List<String> polledTransactions = [];

  @override
  String get name => BillingConfig.mockProviderName;

  @override
  bool get isFree => false;

  @override
  Future<SslCommerzSession> createSession({required String courseId}) async {
    createdTransactions.add(courseId);
    final builder = sessionBuilder;
    if (builder != null) return builder(courseId);
    return SslCommerzSession(
      transactionId: 'MOCK-$courseId-${createdTransactions.length}',
      gatewayPageUrl: '',
      status: 'ok',
      provider: name,
      courseId: courseId,
    );
  }

  @override
  Future<SslCommerzPaymentStatus> getStatus(String transactionId) async {
    polledTransactions.add(transactionId);
    final builder = statusBuilder;
    if (builder != null) return builder(transactionId);
    return SslCommerzPaymentStatus(
      transactionId: transactionId,
      status: 'validated',
      paymentMethod: 'mock',
      validated: true,
      enrollmentCompleted: true,
    );
  }
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Resolves the [BillingProvider] used by paid courses.
///
/// Routing rules:
///
///   1. If [BillingConfig.useMockPayment] is `true` (set via
///      `--dart-define=USE_MOCK_PAYMENT=true`), the factory returns
///      a [MockBillingProvider]. This is the ONLY way the mock is
///      reachable in production builds, and is intended for
///      developer-mode / offline development only.
///   2. Otherwise it returns an [SslCommerzBillingProvider] backed by
///      the supplied [ApiClient]. The free path is detected at the
///      backend layer via `/payments/provider`, not in the factory,
///      so callers can always go through [BillingProvider.createSession]
///      and let the backend decide whether the gateway is needed.
///
/// [forceMock] is provided for tests so a Dart test can exercise the
/// mock branch even when the build was not launched with the
/// `--dart-define`. It MUST NOT be passed from production code; the
/// factory logs a warning if it is used outside an assertion context.
BillingProvider billingProviderFactory(
  ApiClient api, {
  bool forceMock = false,
}) {
  if (forceMock || BillingConfig.useMockPayment) {
    if (forceMock && !BillingConfig.useMockPayment) {
      // Tests deliberately opt into the mock; that's expected. We
      // log in debug mode so production callers passing `forceMock`
      // by accident are easy to spot.
      assert(() {
        debugPrint(
          '[billingProviderFactory] forceMock=true outside a test — '
          'check the call site.',
        );
        return true;
      }());
    }
    return MockBillingProvider();
  }
  return SslCommerzBillingProvider(api: api);
}
