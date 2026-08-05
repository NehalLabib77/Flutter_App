// Widget tests for the SSLCOMMERZ-backed payment flow.
//
// MockPaymentScreen now goes through:
//   1. GET  /payments/provider              — discover the active billing provider
//   2. POST /payments/sslcommerz/session    — mint a gateway URL
//   3. url_launcher(externalApplication)   — open the gateway
//   4. DeepLinkService                      — listen for educompass://payment/return
//   5. GET  /payments/status/<id>           — confirm the row was validated
//
// We stub each of those seams so the test runs offline, then assert
// that tapping the "Pay" button drives the legacy result contract.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:educompass/api_client.dart';
import 'package:educompass/models.dart';
import 'package:educompass/screens/mock_payment_screen.dart';
import 'package:educompass/services/deep_link_service.dart';
import 'package:educompass/theme.dart';

/// Stub [ApiClient] that intercepts the three payment endpoints and
/// records every call.
class _StubApiClient extends ApiClient {
  _StubApiClient() : super(baseUrl: 'http://localhost');

  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> paymentProviderInfo() async {
    calls.add('paymentProviderInfo');
    return {
      'provider': 'sslcommerz',
      'sandbox': true,
      'app_return_uri': 'educompass://payment/return',
    };
  }

  @override
  Future<SslCommerzSession> createSslCommerzSession({
    required String courseId,
    String currency = 'BDT',
  }) async {
    calls.add('createSslCommerzSession($courseId,$currency)');
    return SslCommerzSession(
      transactionId: 'educompass-tx-1',
      status: 'ok',
      provider: 'sslcommerz',
      gatewayPageUrl:
          'https://sandbox.sslcommerz.com/gwprocess/v4/gw.php?ID=abc123',
      sessionKey: 'abc123',
      amount: 250.0,
      currency: currency,
    );
  }

  @override
  Future<SslCommerzPaymentStatus> getSslCommerzPaymentStatus(
    String transactionId,
  ) async {
    calls.add('getSslCommerzPaymentStatus($transactionId)');
    return SslCommerzPaymentStatus(
      transactionId: transactionId,
      status: 'validated',
      paymentMethod: 'VISA',
      amount: 250.0,
      currency: 'BDT',
      enrolled: true,
      enrollmentStatus: 'active',
    );
  }
}

/// A second stub that reports the free provider so we can verify the
/// alternate CTA branch.
class _FreeApiClient extends ApiClient {
  _FreeApiClient() : super(baseUrl: 'http://localhost');

  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> paymentProviderInfo() async {
    calls.add('paymentProviderInfo');
    return {
      'provider': 'free',
      'sandbox': false,
      'app_return_uri': 'educompass://payment/return',
    };
  }
}

/// Stub [DeepLinkService] that replays a pre-canned [PaymentReturn] so
/// the screen completes the flow without needing the OS to actually
/// deliver a deep link.
class _StubDeepLinkService extends DeepLinkService {
  _StubDeepLinkService(this.testController) : super(appLinks: AppLinks());

  final StreamController<PaymentReturn> testController;
  bool started = false;

  @override
  Stream<PaymentReturn> get paymentReturnStream => testController.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> dispose() async {
    // Don't close testController here — the harness owns it.
  }
}

class _FakeUrlLauncher extends UrlLauncherPlatform {
  final List<String> launches = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add(url);
    return true;
  }

  @override
  Future<bool> canLaunch(String url) async => true;
}

Widget _harness({
  required ApiClient api,
  required DeepLinkService deepLinks,
}) {
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<DeepLinkService>.value(value: deepLinks),
    ],
    child: MaterialApp(
      theme: lightTheme,
      home: const MockPaymentScreen(
        courseId: 'course-42',
        courseName: 'Test course',
        amount: 250.0,
      ),
    ),
  );
}

Widget _freeHarness({
  required ApiClient api,
  required DeepLinkService deepLinks,
}) {
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<DeepLinkService>.value(value: deepLinks),
    ],
    child: MaterialApp(
      theme: lightTheme,
      home: const MockPaymentScreen(
        courseId: 'course-42',
        courseName: 'Test course',
        amount: 0,
      ),
    ),
  );
}

void main() {
  late _StubApiClient api;
  late _StubDeepLinkService deepLinks;
  late StreamController<PaymentReturn> controller;
  late _FakeUrlLauncher launcher;

  setUp(() {
    // MockPaymentScreen reads from SharedPreferences during initState
    // (to resume pending transactions) and during the checkout flow
    // (to persist the new transaction id). Without
    // `setMockInitialValues` the plugin throws MissingPluginException,
    // which kills initState before the button can be tapped.
    SharedPreferences.setMockInitialValues(const {});
    api = _StubApiClient();
    controller = StreamController<PaymentReturn>.broadcast();
    deepLinks = _StubDeepLinkService(controller);
    launcher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() async {
    await controller.close();
  });

  testWidgets('renders the pay button and provider summary', (tester) async {
    await tester.pumpWidget(_harness(api: api, deepLinks: deepLinks));
    // Let the initState provider-info call complete.
    await tester.pumpAndSettle();

    expect(find.text('Test course'), findsOneWidget);
    expect(find.text('Total due ৳250.00'), findsOneWidget);
    expect(find.text('Pay with SSLCOMMERZ'), findsOneWidget);
    expect(find.text('Pay ৳250.00'), findsOneWidget);
    expect(find.text('SANDBOX'), findsOneWidget);
    expect(api.calls, contains('paymentProviderInfo'));
  });

  testWidgets('completes the flow when the deep link arrives', (tester) async {
    await tester.pumpWidget(_harness(api: api, deepLinks: deepLinks));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pay ৳250.00'));
    // Pump past the initial _busy=true setState.
    await tester.pump();

    // Drive the async checkout chain (createSession →
    // savePending → deep-link subscription → launchUrl) under
    // runAsync so microtasks scheduled after the synchronous
    // setState actually get a chance to run.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // The screen should have launched the gateway URL exactly once.
    expect(launcher.launches, hasLength(1));
    final parsed = Uri.parse(launcher.launches.single);
    expect(
      parsed.scheme,
      'https',
      reason: 'must hand off to the system browser/external app',
    );

    // Verify network calls fired before the deep-link arrives.
    expect(api.calls, contains('paymentProviderInfo'));
    expect(api.calls, contains('createSslCommerzSession(course-42,BDT)'));

    // Replay the deep-link redirect. Use runAsync so we get real
    // microtask scheduling on the broadcast stream — the screen's
    // 60-second deep-link future is fine, but the listener also
    // races the stream subscription which can be sensitive to the
    // fake clock.
    await tester.runAsync(() async {
      controller.add(
        PaymentReturn(
          transactionId: 'educompass-tx-1',
          status: 'valid',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=educompass-tx-1&status=valid',
          ),
        ),
      );
      // Give the listener time to react and the status call to land.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    // Drain follow-up frames so the Navigator.pop and SnackBar
    // animations settle without re-arming the deep-link timeout.
    for (var i = 0; i < 10; i++) {
      await tester.pump(); // drain microtasks
      await tester.pump(const Duration(milliseconds: 50));
    }

    // The popped map is delivered via Navigator.pop; the framework
    // wraps the home route in a PageRoute that drops the result on
    // the floor for our single-page harness. We verify the side
    // effects instead.
    expect(
      api.calls,
      contains('createSslCommerzSession(course-42,BDT)'),
    );
    expect(
      api.calls,
      contains('getSslCommerzPaymentStatus(educompass-tx-1)'),
    );
    expect(api.calls, contains('paymentProviderInfo'));
  });

  testWidgets('free provider shows free enrolment CTA', (tester) async {
    final freeApi = _FreeApiClient();
    await tester.pumpWidget(_freeHarness(api: freeApi, deepLinks: deepLinks));
    await tester.pumpAndSettle();

    expect(find.text('Free enrollment'), findsOneWidget);
    expect(find.text('Enrol for free'), findsOneWidget);
    expect(find.text('Pay with SSLCOMMERZ'), findsNothing);
    expect(freeApi.calls, contains('paymentProviderInfo'));
  });

  test('SslCommerzSession parses legacy gateway_page_url payload', () {
    final legacy = {
      'session': {
        'transaction_id': 'tx-9',
        'status': 'ok',
        'provider': 'sslcommerz',
        'GatewayPageURL': 'https://example.com/pay',
      },
    };
    final s = SslCommerzSession.fromJson(legacy);
    expect(s.transactionId, 'tx-9');
    expect(s.gatewayPageUrl, 'https://example.com/pay');
  });

  test('SslCommerzPaymentStatus distinguishes valid and failed', () {
    // `isValid` is the screen's enrollment gate. It is intentionally
    // stricter than just `status == 'validated'` — we also require
    // `enrollment_completed == true` so we never trust the gateway
    // alone. See `billing_provider_test.dart` for the defensive-
    // parsing coverage of these fields.
    final valid = SslCommerzPaymentStatus.fromJson({
      'transaction_id': 'tx-1',
      'status': 'validated',
      'enrolled': true,
      'enrollment_completed': true,
    });
    final failed = SslCommerzPaymentStatus.fromJson({
      'transaction_id': 'tx-2',
      'status': 'failed',
    });
    final cancelled = SslCommerzPaymentStatus.fromJson({
      'transaction_id': 'tx-3',
      'status': 'cancelled',
    });
    expect(valid.isValid, isTrue);
    expect(failed.isFailure, isTrue);
    expect(cancelled.isFailure, isTrue);
  });
}
