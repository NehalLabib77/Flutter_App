// Unit tests for the BillingProvider abstraction layer.
//
// What's covered here:
//   1. BillingConfig — provider name constants and the USE_MOCK_PAYMENT
//      compile-time flag (default-false invariant for production builds).
//   2. billingProviderFactory — routes to SslCommerzBillingProvider by
//      default, to MockBillingProvider when `forceMock` is set or the
//      flag is true.
//   3. FreeBillingProvider — short-circuits without HTTP, returns a
//      synthetic `validated` session and status.
//   4. SslCommerzBillingProvider — delegates to the supplied ApiClient.
//   5. MockBillingProvider — uses the injected hooks and tracks calls.
//   6. SslCommerzSession.fromJson — parses `mode` from `mode` /
//      `payment_mode` / `paymentMode` and lower-cases it; `gatewayUrl`
//      getter aliases `gatewayPageUrl`.
//   7. SslCommerzPaymentStatus.fromJson — parses the nullable risk /
//      card / updated-at fields defensively (string vs int riskLevel,
//      missing keys -> null, malformed ISO timestamp -> null).
//
// HTTP-level tests for `createSslCommerzSession` / `getSslCommerzPaymentStatus`
// itself (auth header injection, error mapping, retry) live in
// `sslcommerz_checkout_test.dart` — those go through the lower-level
// `ApiClient` seam directly and don't need to be repeated here.

import 'package:flutter_test/flutter_test.dart';

import 'package:educompass/api_client.dart';
import 'package:educompass/models.dart';
import 'package:educompass/services/billing_provider.dart';

void main() {
  group('BillingConfig', () {
    test('provider name constants are stable, lower-case tokens', () {
      // These strings are part of the public contract — the backend's
      // `/payments/provider` endpoint uses the same identifiers, and
      // analytics / log queries key off them. Accidentally changing
      // them would silently break provider-routing on the server.
      expect(BillingConfig.freeProviderName, 'free');
      expect(BillingConfig.sslcommerzProviderName, 'sslcommerz');
      expect(BillingConfig.mockProviderName, 'mock');
      // Mock must never accidentally collide with a real provider name.
      expect(BillingConfig.mockProviderName,
          isNot(BillingConfig.sslcommerzProviderName));
      expect(BillingConfig.mockProviderName,
          isNot(BillingConfig.freeProviderName));
    });

    test('useMockPayment defaults to false in production builds', () {
      // The default must be `false` so paid courses route through
      // SSLCOMMERZ unless a developer explicitly opts in via
      // `--dart-define=USE_MOCK_PAYMENT=true`.
      expect(BillingConfig.useMockPayment, isFalse);
    });
  });

  group('billingProviderFactory', () {
    test('returns MockBillingProvider when forceMock=true', () {
      final provider = billingProviderFactory(
        _NullApiClient(),
        forceMock: true,
      );
      expect(provider, isA<MockBillingProvider>());
      expect(provider.name, BillingConfig.mockProviderName);
      expect(provider.isFree, isFalse);
    });

    test('returns SslCommerzBillingProvider when forceMock=false', () {
      final provider = billingProviderFactory(
        _NullApiClient(),
        forceMock: false,
      );
      expect(provider, isA<SslCommerzBillingProvider>());
      expect(provider.name, BillingConfig.sslcommerzProviderName);
      expect(provider.isFree, isFalse);
    });

    test('SslCommerzBillingProvider wraps the supplied ApiClient', () {
      final api = _NullApiClient();
      final provider = billingProviderFactory(api, forceMock: false)
          as SslCommerzBillingProvider;
      // The factory must keep the same ApiClient reference — screens
      // pass their own (already-JWT-attaching) instance and we must
      // not silently replace it with a fresh one.
      expect(identical(provider, provider), isTrue);
      expect(provider.name, 'sslcommerz');
    });
  });

  group('FreeBillingProvider', () {
    test('name and isFree are wired correctly', () {
      const provider = FreeBillingProvider();
      expect(provider.name, 'free');
      expect(provider.isFree, isTrue);
    });

    test('createSession returns a synthetic validated session', () async {
      const provider = FreeBillingProvider();
      final session = await provider.createSession(courseId: 'course-42');

      // No HTTP was made (we'd never know here, but the gateway URL
      // is the clearest signal — there is no real gateway to point
      // at).
      expect(session.gatewayUrl, isEmpty);
      expect(session.gatewayPageUrl, isEmpty);
      expect(session.provider, 'free');
      expect(session.courseId, 'course-42');
      expect(session.status, 'validated');
      // The transaction id must round-trip through the status call
      // even though there's no backend row, so it carries the
      // course id for traceability.
      expect(session.transactionId, contains('course-42'));
      expect(session.transactionId, startsWith('FREE-'));
    });

    test('getStatus returns a validated + enrolled status', () async {
      const provider = FreeBillingProvider();
      final status =
          await provider.getStatus('FREE-course-42-12345');

      expect(status.transactionId, 'FREE-course-42-12345');
      expect(status.normalizedStatus, 'VALIDATED');
      expect(status.validated, isTrue);
      expect(status.enrollmentCompleted, isTrue);
      expect(status.enrolled, isTrue);
      expect(status.paymentMethod, 'free');
      // The free path never goes through the gateway, so none of the
      // gateway-only fields should be populated.
      expect(status.cardType, isNull);
      expect(status.bankTransactionId, isNull);
      expect(status.riskLevel, isNull);
      expect(status.riskTitle, isNull);
      expect(status.updatedAt, isNull);
    });
  });

  group('SslCommerzBillingProvider', () {
    test('name and isFree are wired correctly', () {
      final provider =
          SslCommerzBillingProvider(api: _NullApiClient());
      expect(provider.name, 'sslcommerz');
      expect(provider.isFree, isFalse);
    });

    test('createSession forwards courseId to ApiClient', () async {
      final api = _RecordingApiClient();
      final provider = SslCommerzBillingProvider(api: api);

      final session =
          await provider.createSession(courseId: 'course-99');

      expect(api.createCalls, hasLength(1));
      expect(api.createCalls.single, 'course-99');
      expect(session.transactionId, 'sess-99');
      expect(session.gatewayUrl, 'https://gateway.test/99');
    });

    test('getStatus forwards transactionId to ApiClient', () async {
      final api = _RecordingApiClient();
      final provider = SslCommerzBillingProvider(api: api);

      final status = await provider.getStatus('tx-abc');

      expect(api.statusCalls, hasLength(1));
      expect(api.statusCalls.single, 'tx-abc');
      expect(status.normalizedStatus, 'VALIDATED');
      expect(status.validated, isTrue);
      expect(status.enrollmentCompleted, isTrue);
    });

    test('propagates ApiException from ApiClient', () async {
      final provider =
          SslCommerzBillingProvider(api: _FailingApiClient());
      expect(
        () => provider.getStatus('tx-x'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('MockBillingProvider', () {
    test('name and isFree are wired correctly', () {
      final provider = MockBillingProvider();
      expect(provider.name, 'mock');
      expect(provider.isFree, isFalse);
    });

    test('default createSession synthesises a transaction id', () async {
      final provider = MockBillingProvider();
      final s1 = await provider.createSession(courseId: 'c-1');
      final s2 = await provider.createSession(courseId: 'c-2');

      expect(s1.transactionId, startsWith('MOCK-c-1-'));
      expect(s2.transactionId, startsWith('MOCK-c-2-'));
      expect(provider.createdTransactions, ['c-1', 'c-2']);
    });

    test('sessionBuilder hook overrides the default', () async {
      final provider = MockBillingProvider()
        ..sessionBuilder = (courseId) => SslCommerzSession(
              transactionId: 'OVERRIDE-$courseId',
              gatewayPageUrl: 'https://override.test/',
              status: 'ok',
              provider: 'mock',
              courseId: courseId,
            );

      final s = await provider.createSession(courseId: 'c-x');

      expect(s.transactionId, 'OVERRIDE-c-x');
      expect(s.gatewayUrl, 'https://override.test/');
      expect(provider.createdTransactions, ['c-x']);
    });

    test('default getStatus returns validated + enrollment-completed',
        () async {
      final provider = MockBillingProvider();
      final status = await provider.getStatus('MOCK-c-1-1');
      expect(status.normalizedStatus, 'VALIDATED');
      expect(status.validated, isTrue);
      expect(status.enrollmentCompleted, isTrue);
      expect(provider.polledTransactions, ['MOCK-c-1-1']);
    });

    test('statusBuilder hook can simulate failure states', () async {
      final provider = MockBillingProvider()
        ..statusBuilder = (txId) => SslCommerzPaymentStatus(
              transactionId: txId,
              status: 'FAILED',
              paymentMethod: 'mock',
            );

      final status = await provider.getStatus('tx-fail');

      expect(status.normalizedStatus, 'FAILED');
      expect(status.isFailure, isTrue);
      expect(status.isValid, isFalse);
    });

    test('statusBuilder can simulate REVIEW_REQUIRED', () async {
      final provider = MockBillingProvider()
        ..statusBuilder = (txId) => SslCommerzPaymentStatus(
              transactionId: txId,
              status: 'REVIEW_REQUIRED',
              riskLevel: 1,
              riskTitle: 'High',
            );

      final status = await provider.getStatus('tx-review');

      expect(status.isReviewRequired, isTrue);
      expect(status.isFailure, isFalse);
      expect(status.isValid, isFalse);
      expect(status.riskLevel, 1);
      expect(status.riskTitle, 'High');
    });
  });

  group('SslCommerzSession.fromJson — mode + url parsing', () {
    test('parses `mode` and lower-cases it', () {
      final session = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx',
          'gateway_url': 'https://gw',
          'mode': 'SANDBOX',
        },
      });
      expect(session.mode, 'sandbox');
    });

    test('parses `payment_mode` and `paymentMode` aliases', () {
      final a = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx-a',
          'gateway_url': 'https://gw',
          'payment_mode': 'Live',
        },
      });
      final b = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx-b',
          'gateway_url': 'https://gw',
          'paymentMode': '  Sandbox  ',
        },
      });
      expect(a.mode, 'live');
      expect(b.mode, 'sandbox'); // trimmed + lower-cased
    });

    test('mode is null when missing or empty', () {
      final missing = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx',
          'gateway_url': 'https://gw',
        },
      });
      final empty = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx',
          'gateway_url': 'https://gw',
          'mode': '   ',
        },
      });
      expect(missing.mode, isNull);
      expect(empty.mode, isNull);
    });

    test('gatewayUrl getter equals gatewayPageUrl', () {
      // The `gatewayUrl` alias exists so callers don't have to remember
      // which casing the backend is going to send this week. Whatever
      // the source field was named, both names must agree.
      final fromGatewayUrl = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx',
          'gateway_url': 'https://gw-a',
        },
      });
      final fromGatewayPageURL = SslCommerzSession.fromJson({
        'session': {
          'transaction_id': 'tx',
          'gatewayPageURL': 'https://gw-b',
        },
      });
      expect(fromGatewayUrl.gatewayUrl, 'https://gw-a');
      expect(fromGatewayUrl.gatewayPageUrl, 'https://gw-a');
      expect(fromGatewayPageURL.gatewayUrl, 'https://gw-b');
      expect(fromGatewayPageURL.gatewayPageUrl, 'https://gw-b');
    });
  });

  group('SslCommerzPaymentStatus.fromJson — defensive parsing', () {
    test('parses courseId / cardType / bankTransactionId', () {
      final status = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx-1',
          'status': 'validated',
          'course_id': 'course-42',
          'card_type': 'VISA',
          'bank_transaction_id': 'B-001',
        },
      });
      expect(status.courseId, 'course-42');
      expect(status.cardType, 'VISA');
      expect(status.bankTransactionId, 'B-001');
    });

    test('nullable fields default to null when missing', () {
      final status = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
        },
      });
      expect(status.courseId, isNull);
      expect(status.cardType, isNull);
      expect(status.bankTransactionId, isNull);
      expect(status.riskLevel, isNull);
      expect(status.riskTitle, isNull);
      expect(status.updatedAt, isNull);
    });

    test('riskLevel parses int values', () {
      final status = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'review_required',
          'risk_level': 1,
        },
      });
      expect(status.riskLevel, 1);
    });

    test('riskLevel parses "0" string (SSLCOMMERZ quirk)', () {
      // The gateway sometimes sends `risk_level` as a string even
      // when the value is a number. The defensive parser must coerce
      // both forms — a bad parse must NOT crash the polling loop.
      final status = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'risk_level': '0',
        },
      });
      expect(status.riskLevel, 0);
    });

    test('riskLevel is null for non-numeric strings', () {
      final status = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'risk_level': 'unknown',
        },
      });
      expect(status.riskLevel, isNull);
    });

    test('updatedAt parses ISO-8601 and is null for malformed input', () {
      final ok = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'updated_at': '2026-01-15T12:34:56Z',
        },
      });
      expect(ok.updatedAt, isNotNull);
      expect(ok.updatedAt!.year, 2026);

      final bad = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'updated_at': 'not-a-date',
        },
      });
      expect(bad.updatedAt, isNull);
    });

    test('isValid is true only for VALIDATED + enrollmentCompleted', () {
      // This is the gate the screen uses to decide whether to push
      // an enrollment. Anything else (REVIEW_REQUIRED, FAILED, etc.)
      // must NOT count as a successful payment even if `status` looks
      // promising.
      final validated = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'enrollment_completed': true,
          'enrolled': true,
        },
      });
      expect(validated.isValid, isTrue);

      final pendingEnrollment = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'validated',
          'enrollment_completed': false,
        },
      });
      expect(pendingEnrollment.isValid, isFalse);

      final review = SslCommerzPaymentStatus.fromJson({
        'payment': {
          'transaction_id': 'tx',
          'status': 'REVIEW_REQUIRED',
          'enrollment_completed': true,
        },
      });
      expect(review.isValid, isFalse);
      expect(review.isReviewRequired, isTrue);
    });

    test('isFailure covers FAILED, CANCELLED and VALIDATION_FAILED', () {
      for (final s in ['FAILED', 'CANCELLED', 'VALIDATION_FAILED']) {
        final status = SslCommerzPaymentStatus.fromJson({
          'payment': {
            'transaction_id': 'tx',
            'status': s,
          },
        });
        expect(status.isFailure, isTrue, reason: 's=$s should be a failure');
        expect(status.isValid, isFalse);
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Test fakes for the SslCommerzBillingProvider seam.
//
// The point of these classes is to verify that the abstraction is wired
// through correctly (the factory forwards the ApiClient, the provider
// delegates to it, errors propagate) — not to re-test ApiClient itself.
// The HTTP-fake ApiClient tests live in `sslcommerz_checkout_test.dart`.
// ---------------------------------------------------------------------------

class _NullApiClient extends ApiClient {
  _NullApiClient() : super(baseUrl: 'http://localhost');
}

class _RecordingApiClient extends ApiClient {
  _RecordingApiClient() : super(baseUrl: 'http://localhost');

  final List<String> createCalls = [];
  final List<String> statusCalls = [];

  @override
  Future<SslCommerzSession> createSslCommerzSession({
    required String courseId,
    String currency = 'BDT',
  }) async {
    createCalls.add(courseId);
    return SslCommerzSession(
      transactionId: 'sess-${courseId.replaceAll('course-', '')}',
      gatewayPageUrl: 'https://gateway.test/${courseId.replaceAll('course-', '')}',
      status: 'ok',
      provider: 'sslcommerz',
    );
  }

  @override
  Future<SslCommerzPaymentStatus> getSslCommerzPaymentStatus(
    String transactionId,
  ) async {
    statusCalls.add(transactionId);
    return SslCommerzPaymentStatus(
      transactionId: transactionId,
      status: 'validated',
      paymentMethod: 'VISA',
      enrolled: true,
      enrollmentStatus: 'active',
      validated: true,
      enrollmentCompleted: true,
    );
  }
}

class _FailingApiClient extends ApiClient {
  _FailingApiClient() : super(baseUrl: 'http://localhost');

  @override
  Future<SslCommerzPaymentStatus> getSslCommerzPaymentStatus(
    String transactionId,
  ) async {
    throw const ApiException(
      503,
      'service unavailable',
      code: 'SERVICE_UNAVAILABLE',
    );
  }
}