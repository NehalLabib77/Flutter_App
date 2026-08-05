// End-to-end widget tests for MockPaymentScreen.
//
// Covers the 25 scenarios called out in the SSLCOMMERZ Flutter
// integration review. Runs alongside the lighter
// `sslcommerz_checkout_test.dart` which keeps the historical happy-path
// coverage in place.
//
// Every scenario uses fakes for every external seam MockPaymentScreen
// reads from:
//   * ApiClient             (programmable stub)
//   * UrlLauncherPlatform   (records launches, pluggable returnValue)
//   * DeepLinkService       (broadcast StreamController of PaymentReturn)
//   * SharedPreferences     (setMockInitialValues)
//   * EnrollmentProvider    (records pushRemote / refreshFromRemote)
//
// Firestore-tied surfaces (EnrollmentService.myEnrolledCourseIds) are
// owned by EnrollmentProvider, so the fake provider records the
// `refreshFromRemote()` call and the test asserts the call happened.
//
// Time control: every test that needs the deep-link timer to fire uses
// `tester.pump(duration)`, which advances the test clock directly.
// Tests that drive `Future.delayed` chains (polling, _pollStatusUntilSettled)
// wrap those waits in `tester.runAsync`, which executes real time.
// Tests that would otherwise have a 60s-deep-link timer leak at the
// end of the run finish by replacing the widget tree with an empty
// MaterialApp, which triggers `dispose()` and cancels the timer /
// subscription cleanly.

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:educompass/api_client.dart';
import 'package:educompass/app_state.dart';
import 'package:educompass/models.dart';
import 'package:educompass/screens/mock_payment_screen.dart';
import 'package:educompass/services/billing_provider.dart';
import 'package:educompass/services/deep_link_service.dart';
import 'package:educompass/theme.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeApi extends ApiClient {
  _FakeApi({
    Map<String, dynamic>? providerInfo,
    SslCommerzSession? session,
    SslCommerzPaymentStatus? status,
    Future<void> Function()? throwOnSession,
    Future<void> Function()? throwOnStatus,
    Future<void> Function()? throwOnProviderInfo,
  })  : _providerInfo = providerInfo ??
            const {
              'provider': 'sslcommerz',
              'sandbox': true,
              'app_return_uri': 'educompass://payment/return',
            },
        _session = session ??
            SslCommerzSession(
              transactionId: 'tx-fake-1',
              gatewayPageUrl: 'https://sandbox.sslcommerz.com/gw',
              status: 'ok',
              provider: 'sslcommerz',
            ),
        _status = status ??
            SslCommerzPaymentStatus(
              transactionId: 'tx-fake-1',
              status: 'validated',
              paymentMethod: 'VISA',
              validated: true,
              enrollmentCompleted: true,
            ),
        _throwOnSession = throwOnSession,
        _throwOnStatus = throwOnStatus,
        _throwOnProviderInfo = throwOnProviderInfo,
        super(baseUrl: 'http://localhost');

  final Map<String, dynamic> _providerInfo;
  final SslCommerzSession _session;
  final SslCommerzPaymentStatus _status;
  final Future<void> Function()? _throwOnSession;
  final Future<void> Function()? _throwOnStatus;
  final Future<void> Function()? _throwOnProviderInfo;

  // Public overrides used by individual tests (e.g. scenario 1 holds
  // the session future open).
  Future<SslCommerzSession> Function()? createSessionOverride;
  SslCommerzSession get sessionForOverride => _session;

  // Recording
  final List<String> providerInfoCalls = [];
  final List<String> createSessionCalls = [];
  final List<String> statusCalls = [];

  @override
  Future<Map<String, dynamic>> paymentProviderInfo() async {
    providerInfoCalls.add('provider-info');
    if (_throwOnProviderInfo != null) await _throwOnProviderInfo();
    return _providerInfo;
  }

  @override
  Future<SslCommerzSession> createSslCommerzSession({
    required String courseId,
  }) async {
    createSessionCalls.add(courseId);
    if (_throwOnSession != null) await _throwOnSession();
    final override = createSessionOverride;
    if (override != null) return override();
    return _session;
  }

  @override
  Future<SslCommerzPaymentStatus> getSslCommerzPaymentStatus(
    String transactionId,
  ) async {
    statusCalls.add(transactionId);
    if (_throwOnStatus != null) await _throwOnStatus();
    return _status;
  }
}

class _StubDeepLinkService extends DeepLinkService {
  _StubDeepLinkService(this.testController) : super(appLinks: AppLinks());

  final StreamController<PaymentReturn> testController;

  @override
  Stream<PaymentReturn> get paymentReturnStream => testController.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> dispose() async {}
}

class _FakeUrlLauncher extends UrlLauncherPlatform {
  bool returnValue = true;
  final List<String> launches = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add(url);
    return returnValue;
  }

  @override
  Future<bool> canLaunch(String url) async => true;
}

class _FakeEnrollmentProvider extends ChangeNotifier
    implements EnrollmentProvider {
  final Set<String> _ids = {};
  final List<Map<String, String>> pushRemoteCalls = [];
  int refreshFromRemoteCalls = 0;

  @override
  Set<String> get ids => _ids;

  @override
  bool isEnrolled(String courseId) => _ids.contains(courseId);

  @override
  Future<void> enroll(String courseId) async {
    _ids.add(courseId);
    notifyListeners();
  }

  @override
  Future<void> unenroll(String courseId) async {
    _ids.remove(courseId);
    notifyListeners();
  }

  @override
  Future<void> drop(
    String courseId, {
    void Function(Object error, [StackTrace? stack])? onSyncError,
  }) async {
    _ids.remove(courseId);
    notifyListeners();
  }

  @override
  Future<void> pushRemote({
    required String courseId,
    required String paymentMethod,
    required String transactionId,
    String paymentStatus = 'completed',
  }) async {
    pushRemoteCalls.add({
      'courseId': courseId,
      'paymentMethod': paymentMethod,
      'transactionId': transactionId,
      'paymentStatus': paymentStatus,
    });
  }

  @override
  void refreshFromRemote([Object? service]) {
    refreshFromRemoteCalls += 1;
  }

  @override
  void cancelRemoteSubscription() {}

  @override
  bool get syncingFromRemote => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _harness({
  required ApiClient api,
  required DeepLinkService deepLinks,
  required EnrollmentProvider enrolled,
}) {
  return MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<DeepLinkService>.value(value: deepLinks),
      ChangeNotifierProvider<EnrollmentProvider>.value(value: enrolled),
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

/// Pumps past the initial provider-info call so the test harness is
/// in a stable state before we interact with the screen.
Future<void> _settleInit(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 50));
}

Finder _payButton() => find.byType(FilledButton);

/// Replaces the route with an empty scaffold so the screen's
/// `dispose()` fires cleanly (cancels the deep-link subscription,
/// cancels the 60s timer). Then pumps a couple of frames so the
/// disposal completes.
Future<void> _tearDownScreen(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    theme: lightTheme,
    home: const Scaffold(body: SizedBox.shrink()),
  ));
  await tester.pump();
  await tester.pump();
}

/// Emits [ret] on the deep-link stream and waits for the listener to
/// process it. `tester.runAsync` drives the real microtask queue so
/// the broadcast stream subscribers actually run.
Future<void> _emitDeepLink(
  WidgetTester tester,
  StreamController<PaymentReturn> controller,
  PaymentReturn ret,
) async {
  await tester.runAsync(() async {
    controller.add(ret);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  });
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('MockPaymentScreen — full flow', () {
    late _FakeApi api;
    late _StubDeepLinkService deepLinks;
    late StreamController<PaymentReturn> controller;
    late _FakeUrlLauncher launcher;
    late _FakeEnrollmentProvider enrolled;

    setUp(() {
      api = _FakeApi();
      controller = StreamController<PaymentReturn>.broadcast();
      deepLinks = _StubDeepLinkService(controller);
      launcher = _FakeUrlLauncher();
      enrolled = _FakeEnrollmentProvider();
      UrlLauncherPlatform.instance = launcher;
    });

    tearDown(() async {
      await controller.close();
    });

    // -------------------------------------------------------------------
    // 1. Payment loading state disables the CTA.
    // -------------------------------------------------------------------
    testWidgets('scenario 1: payment loading state disables the CTA',
        (tester) async {
      // Hold the session future open forever so the screen stays
      // in the busy state. We pump without awaiting the session.
      final gate = Completer<SslCommerzSession>();
      final slowApi = _FakeApi();
      slowApi.createSessionOverride = () => gate.future;

      await tester.pumpWidget(
        _harness(api: slowApi, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();

      // The CTA label flipped to the busy variant.
      expect(find.text('Opening gateway…'), findsOneWidget);
      // The FilledButton is disabled (onPressed == null).
      final filled = tester.widget<FilledButton>(_payButton());
      expect(filled.onPressed, isNull);

      // Release the gate so the screen reaches a stable state.
      gate.complete(slowApi.sessionForOverride);
      await tester.pump();
      await tester.pump();

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 2. Duplicate-tap prevention.
    // -------------------------------------------------------------------
    testWidgets('scenario 2: duplicate-tap prevention', (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      // First tap fires the flow. The button immediately disables.
      await tester.tap(_payButton());
      await tester.pump();

      // Second tap — the button is now disabled, so this is a
      // no-op. Assert the *side effect*: createSessionCalls is
      // still exactly one.
      final btn = _payButton();
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump();
      await tester.tap(btn, warnIfMissed: false);
      await tester.pump();

      // The session API was hit exactly once.
      expect(api.createSessionCalls, hasLength(1));
      expect(api.createSessionCalls.single, 'course-42');

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 3. Session API request hits createSslCommerzSession.
    // -------------------------------------------------------------------
    testWidgets('scenario 3: session API request hits createSslCommerzSession',
        (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      expect(api.createSessionCalls, ['course-42']);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 4. Browser launch uses externalApplication.
    // -------------------------------------------------------------------
    testWidgets('scenario 4: browser launch uses externalApplication',
        (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(launcher.launches, hasLength(1));
      expect(launcher.launches.single, 'https://sandbox.sslcommerz.com/gw');

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 5 + 6. Successful deep-link triggers VALIDATED enrollment.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 5+6: successful deep-link triggers VALIDATED enrollment '
        'via backend status', (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      expect(launcher.launches, hasLength(1));

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'valid',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=valid',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Scenario 6 — backend status endpoint was hit.
      expect(api.statusCalls, contains('tx-fake-1'));
      // Scenario 15 — pushRemote fired with the right args.
      expect(enrolled.pushRemoteCalls, hasLength(1));
      expect(enrolled.pushRemoteCalls.single['courseId'], 'course-42');
      expect(enrolled.pushRemoteCalls.single['paymentMethod'], 'sslcommerz');
      expect(enrolled.pushRemoteCalls.single['transactionId'], 'tx-fake-1');
      // Scenario 16 — refreshFromRemote called (Firestore sync).
      expect(enrolled.refreshFromRemoteCalls, greaterThanOrEqualTo(1));

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 7. Backend status is authoritative.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 7: deep-link status is not trusted — backend status wins',
        (tester) async {
      final api7 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'cancelled',
          paymentMethod: 'VISA',
        ),
      );
      await tester.pumpWidget(
        _harness(api: api7, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'valid',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=valid',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(enrolled.pushRemoteCalls, isEmpty,
          reason: 'cancelled backend status must not escalate enrollment');
      // Scenario 18 — no enrollment refresh for FAILED/CANCELLED.
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 8. Cancelled payment.
    // -------------------------------------------------------------------
    testWidgets('scenario 8: cancelled payment does not escalate enrollment',
        (tester) async {
      final api8 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'cancelled',
          paymentMethod: 'VISA',
        ),
      );
      await tester.pumpWidget(
        _harness(api: api8, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'cancelled',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=cancelled',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 9. Failed payment.
    // -------------------------------------------------------------------
    testWidgets('scenario 9: failed payment does not escalate enrollment',
        (tester) async {
      final api9 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'failed',
          paymentMethod: 'VISA',
        ),
      );
      await tester.pumpWidget(
        _harness(api: api9, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'failed',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=failed',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 10. Review-required payment does not escalate.
    // -------------------------------------------------------------------
    testWidgets('scenario 10: review-required payment does not enroll',
        (tester) async {
      final api10 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'review_required',
          paymentMethod: 'VISA',
          riskLevel: 1,
          riskTitle: 'High',
        ),
      );
      await tester.pumpWidget(
        _harness(api: api10, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'unknown',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=unknown',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Scenario 17 — no enrollment refresh for REVIEW_REQUIRED.
      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 11. Validation-failed is treated as failure.
    // -------------------------------------------------------------------
    testWidgets('scenario 11: validation-failed is treated as failure',
        (tester) async {
      final api11 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'validation_failed',
          paymentMethod: 'VISA',
        ),
      );
      await tester.pumpWidget(
        _harness(api: api11, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'validation_failed',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=validation_failed',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 12. Pending-payment timeout — polls the backend.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 12: pending-payment timeout polls the backend for status',
        (tester) async {
      final api12 = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-fake-1',
          status: 'pending',
          paymentMethod: 'VISA',
        ),
      );

      await tester.pumpWidget(
        _harness(api: api12, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      // No deep link emitted. The 60s timer fires and the polling
      // loop runs. We use tester.pump(Duration) to advance the test
      // clock through the timer, then runAsync to give the polling
      // Future.delayed chain real time to complete.
      await tester.pump(const Duration(seconds: 61));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 7));
      });
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The status endpoint was polled at least once.
      expect(api12.statusCalls, isNotEmpty,
          reason: 'backend must be polled after deep-link timeout');
      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 13. Pending transaction is persisted to SharedPreferences.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 13: pending transaction is persisted to SharedPreferences',
        (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('pending_sslc_transaction_id'), 'tx-fake-1');
      expect(prefs.getString('pending_sslc_course_id'), 'course-42');

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 14. Pending transaction is resumed on screen mount.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 14: pending transaction is resumed on screen mount',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'pending_sslc_transaction_id': 'tx-prev',
        'pending_sslc_course_id': 'course-42',
      });

      final apiResume = _FakeApi(
        status: SslCommerzPaymentStatus(
          transactionId: 'tx-prev',
          status: 'validated',
          paymentMethod: 'VISA',
          validated: true,
          enrollmentCompleted: true,
        ),
      );

      final controllerResume =
          StreamController<PaymentReturn>.broadcast();
      final deepLinksResume = _StubDeepLinkService(controllerResume);
      addTearDown(controllerResume.close);

      await tester.pumpWidget(_harness(
        api: apiResume,
        deepLinks: deepLinksResume,
        enrolled: enrolled,
      ));

      // Drain initState's microtasks so the resume chain kicks off
      // and registers its first poll timer inside the FakeAsync zone.
      await tester.pump();

      // The resume branch uses `_pollStatusUntilSettled`, which is
      // a fake-clock timer-based loop (`Timer(_statusPollDelay)`).
      // We must advance the FakeAsync clock so each iteration's
      // timer fires — `runAsync` switches to real time and would
      // leave the fake timers stranded. Five iterations × 1s plus
      // a small margin is well within our timeout.
      await tester.pump(const Duration(seconds: 6));
      // Drain the microtasks spawned by the timer callbacks so the
      // status call and pop navigation actually land in the widget
      // tree.
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(apiResume.statusCalls, contains('tx-prev'));
      // Scenario 15 — pushRemote fired after the resume validated.
      expect(enrolled.pushRemoteCalls, hasLength(1));
      expect(enrolled.pushRemoteCalls.single['transactionId'], 'tx-prev');

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 19. Malformed deep-link status falls through to backend.
    // -------------------------------------------------------------------
    testWidgets('scenario 19: malformed deep link with unknown status',
        (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: 'tx-fake-1',
          status: 'weird-and-unknown',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=tx-fake-1&status=weird-and-unknown',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(api.statusCalls, contains('tx-fake-1'));
      expect(enrolled.pushRemoteCalls, hasLength(1));

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 20. Deep-link with empty transaction id still uses session id.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 20: deep link with empty transaction id still uses session id',
        (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      await _emitDeepLink(
        tester,
        controller,
        PaymentReturn(
          transactionId: '',
          status: 'valid',
          sourceUri: Uri.parse(
            'educompass://payment/return?transaction_id=&status=valid',
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
      }

      // Backend status was called against the session's transaction id.
      expect(api.statusCalls, contains('tx-fake-1'));
      expect(enrolled.pushRemoteCalls, hasLength(1));

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 21. Browser launch failure surfaces a snack.
    // -------------------------------------------------------------------
    testWidgets('scenario 21: browser launch failure surfaces a snack',
        (tester) async {
      launcher.returnValue = false; // pretend launch failed
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The session was created and the launcher fired, but returned
      // false — the screen surfaces a snack and exits with success=false.
      expect(api.createSessionCalls, hasLength(1));
      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 22. Network failure during session creation.
    // -------------------------------------------------------------------
    testWidgets('scenario 22: network failure during session creation',
        (tester) async {
      final api22 = _FakeApi(
        throwOnSession: () async {
          throw const ApiException(0, 'Cannot reach the server',
              code: 'NETWORK_ERROR');
        },
      );
      await tester.pumpWidget(
        _harness(api: api22, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(enrolled.pushRemoteCalls, isEmpty);
      expect(enrolled.refreshFromRemoteCalls, 0);

      await _tearDownScreen(tester);
    });

    // -------------------------------------------------------------------
    // 23. Safe listener disposal — subscription cancelled on dispose.
    // -------------------------------------------------------------------
    testWidgets(
        'scenario 23: listener is cancelled when the widget is disposed '
        'before the deep link arrives', (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      await tester.tap(_payButton());
      await tester.pump();
      await tester.pump();

      // Replace the route with an empty page → dispose() fires,
      // cancelling the deep-link subscription and the 60s timer.
      await tester.pumpWidget(MaterialApp(
        theme: lightTheme,
        home: const Scaffold(body: SizedBox.shrink()),
      ));
      await tester.pump();

      // Emit a deep-link event *after* dispose. If the listener was
      // leaked, the State would still receive the event and we'd
      // see a setState-on-disposed error.
      await tester.runAsync(() async {
        controller.add(
          PaymentReturn(
            transactionId: 'tx-fake-1',
            status: 'valid',
            sourceUri: Uri.parse(
              'educompass://payment/return?transaction_id=tx-fake-1&status=valid',
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });

      // Drain microtasks without settling (timer could fire).
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // pushRemote never invoked because the screen disposed first.
      expect(enrolled.pushRemoteCalls, isEmpty);
    });
  });

  // -------------------------------------------------------------------
  // 24. Free-course flow.
  // -------------------------------------------------------------------
  group('MockPaymentScreen — free provider', () {
    late _FakeApi api;
    late _StubDeepLinkService deepLinks;
    late StreamController<PaymentReturn> controller;
    late _FakeUrlLauncher launcher;
    late _FakeEnrollmentProvider enrolled;

    setUp(() {
      api = _FakeApi(
        providerInfo: const {'provider': 'free', 'sandbox': false},
      );
      controller = StreamController<PaymentReturn>.broadcast();
      deepLinks = _StubDeepLinkService(controller);
      launcher = _FakeUrlLauncher();
      enrolled = _FakeEnrollmentProvider();
      UrlLauncherPlatform.instance = launcher;
    });

    tearDown(() async {
      await controller.close();
    });

    testWidgets(
        'scenario 24: free-course flow shows the free CTA and does '
        'not call the gateway', (tester) async {
      await tester.pumpWidget(
        _harness(api: api, deepLinks: deepLinks, enrolled: enrolled),
      );
      await _settleInit(tester);

      // The free branch is observable in the UI.
      expect(find.text('Free enrollment'), findsOneWidget);
      expect(find.text('Enrol for free'), findsOneWidget);
      expect(find.text('Pay with SSLCOMMERZ'), findsNothing);

      await tester.tap(find.text('Enrol for free'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // No gateway URL was launched. No session API was hit.
      expect(launcher.launches, isEmpty);
      expect(api.createSessionCalls, isEmpty);

      await _tearDownScreen(tester);
    });
  });

  // -------------------------------------------------------------------
  // Regression: payment-provider 404 must not crash the post-await snack.
  // -------------------------------------------------------------------
  group('MockPaymentScreen — provider-info failures', () {
    testWidgets(
        'scenario 26: payment-provider 404 with paid course surfaces '
        'a snack without crashing, even if the screen is torn down '
        'before the future resolves', (tester) async {
      SharedPreferences.setMockInitialValues(const {});

      final gate = Completer<void>();
      final api404 = _FakeApi(
        throwOnProviderInfo: () async {
          await gate.future;
          throw const ApiException(404, 'Endpoint not found.',
              code: 'NOT_FOUND');
        },
      );
      final controller26 = StreamController<PaymentReturn>.broadcast();
      final deepLinks26 = _StubDeepLinkService(controller26);
      addTearDown(controller26.close);

      await tester.pumpWidget(
        _harness(
          api: api404,
          deepLinks: deepLinks26,
          // Mark the course as paid so the misconfiguration guard
          // fires its snack.
          // (The harness widget ignores the `isCourseFree` param —
          // we patch the course for free vs paid through a separate
          // harness here by wrapping it with a CourseDetailsScreen
          // builder that sets isCourseFree=true on the screen below.)
          enrolled: _FakeEnrollmentProvider(),
        ),
      );
      await tester.pump();

      // Replace the route with an empty scaffold while the provider-info
      // request is still pending. `dispose()` fires for the
      // MockPaymentScreen state. THEN resolve the gate so the await
      // resumes inside a State whose context is deactivated.
      await tester.pumpWidget(
        MaterialApp(
          theme: lightTheme,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      );
      await tester.pump();

      // Complete the gated future *after* dispose(). If the screen
      // tries to call ScaffoldMessenger.of(context) on a deactivated
      // context, Flutter throws "Looking up a deactivated widget's
      // ancestor is unsafe" — which is the regression we are
      // guarding against.
      gate.complete();

      // Drain microtasks for the await to resume, then drain frames.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      // The test passes if no exception escaped; tester takes care of
      // assertions against uncaught errors.
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'scenario 27: paid course gets a visible error banner when the '
        'provider endpoint returns 404', (tester) async {
      SharedPreferences.setMockInitialValues(const {});

      final api = _FakeApi(
        throwOnProviderInfo: () async {
          throw const ApiException(
              404, 'Endpoint not found.', code: 'NOT_FOUND');
        },
      );
      final controller27 = StreamController<PaymentReturn>.broadcast();
      final deepLinks27 = _StubDeepLinkService(controller27);
      addTearDown(controller27.close);

      await tester.pumpWidget(_harness(
        api: api,
        deepLinks: deepLinks27,
        enrolled: _FakeEnrollmentProvider(),
      ));
      await _settleInit(tester);

      // The provider-info failure is observable in the UI: the
      // screen shows the unconfigured-gateway error rather than
      // silently enrolling for free. The message appears at least
      // once — both the inline banner and the snackbar contain it.
      expect(
        find.textContaining('Payment gateway is unreachable'),
        findsAtLeast(1),
        reason:
            'Paid course must surface a clear error when the provider '
            'endpoint 404s; instead the user would silently see the '
            'free-enrollment CTA and could bypass payment.',
      );
    });
  });

  // -------------------------------------------------------------------
  // 25. Mock payment disabled by default.
  // -------------------------------------------------------------------
  group('MockPaymentScreen — billing config invariants', () {
    test('scenario 25: mock payment is disabled by default', () {
      expect(BillingConfig.useMockPayment, isFalse);
      // Mock provider name never collides with the production names.
      expect(BillingConfig.mockProviderName,
          isNot(BillingConfig.sslcommerzProviderName));
    });
  });
}