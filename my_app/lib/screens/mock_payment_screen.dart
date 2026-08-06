/// Gateway-based payment screen for EduCompass.
///
/// The previous fake bKash/Nagad/Rocket/Card form with the hard-coded
/// OTP `123456` has been replaced by a thin wrapper around the Flask
/// SSLCOMMERZ integration:
///
///   1. On entry we ask the backend which billing provider is active.
///      If it is the free provider, the user is enrolled in-place
///      without ever leaving the app.
///   2. Otherwise the user taps **Pay with SSLCOMMERZ**. We POST to
///      ``/payments/sslcommerz/session`` to mint a transaction id and
///      resolve the gateway URL, then launch it via ``url_launcher``
///      in ``externalApplication`` mode so the system browser (or the
///      SSLCOMMERZ-hosted webview) handles the checkout.
///   3. The user pays at the gateway. On success / fail / cancel the
///      gateway redirects back to a tiny HTML page on our backend that
///      bounces the browser to
///        ``educompass://payment/return?transaction_id=<id>&status=<...>``.
///      ``DeepLinkService`` re-emits those URIs as ``PaymentReturn``
///      events; this screen matches them against the transaction id
///      we minted and then calls
///      ``GET /payments/status/<transaction_id>`` to confirm the row
///      was actually promoted to ``validated``.
///   4. The result is forwarded via ``Navigator.pop`` using the same
///      contract the rest of the app already understands:
///        ``{success, courseId, paymentMethod, transactionId}``
///
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../models.dart';
import '../services/billing_provider.dart';
import '../services/deep_link_service.dart';
import '../widgets/design.dart';

class MockPaymentScreen extends StatefulWidget {
  const MockPaymentScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    this.amount = 0,
    this.currencySymbol = '৳',
    // Whether the course the user is enrolling into is actually free.
    // When the course is paid but the backend reports the free billing
    // provider (e.g. SSLCOMMERZ credentials are missing on the
    // server) we MUST NOT silently enroll for free — that would let
    // paying users get the course without paying. The screen uses
    // this flag to surface a clear "gateway not configured" error
    // instead.
    this.isCourseFree = false,
  });

  final String courseId;
  final String courseName;
  final double amount;
  final String currencySymbol;
  final bool isCourseFree;

  @override
  State<MockPaymentScreen> createState() => _MockPaymentScreenState();
}

class _MockPaymentScreenState extends State<MockPaymentScreen> {
  /// Maximum number of times we re-poll the status endpoint while we
  /// wait for the gateway to confirm a redirect that the IPN hasn't
  /// beaten us to yet.
  static const int _statusPollMax = 5;
  static const Duration _statusPollDelay = Duration(seconds: 1);
  static const Duration _deepLinkTimeout = Duration(seconds: 60);
  static const String _pendingTxnKey = 'pending_sslc_transaction_id';
  static const String _pendingCourseKey = 'pending_sslc_course_id';

  String? _providerName;
  bool? _providerSandbox;
  bool _providerLoading = true;
  double? _confirmedAmount;
  bool _busy = false;
  // Latest provider-info error, surfaced through the build tree so the
  // user can see the message even if the screen is torn down before
  // the post-await snack fires. Null when there is no error to show.
  String? _providerErrorMessage;
  StreamSubscription<PaymentReturn>? _deepLinkSub;
  // Active poll-timer owned by `_pollStatusUntilSettled`. Held on the
  // State so dispose() can cancel it; without this the binding flags
  // "A Timer is still pending even after the widget tree was disposed"
  // whenever the user navigates away during a pending-payment poll.
  Timer? _pollTimer;

  /// 60s deep-link wait timer owned by the state, not by the
  /// closure inside `_attachDeepLinkListener`. Promoting it to an
  /// instance field lets `dispose()` cancel it when the widget is
  /// torn down before the timer fires — otherwise the Timer leaks
  /// past the State lifecycle and trips
  /// `TestWidgetsFlutterBinding._verifyInvariants`
  /// ("A Timer is still pending even after the widget tree was
  /// disposed").
  Timer? _deepLinkTimer;

  /// Completer the deep-link handler awaits; disposing the widget
  /// before the redirect arrives must complete it so the await
  /// unwinds and the test framework doesn't see a hanging future.
  Completer<void>? _waitForDeepLink;

  /// Cached `ScaffoldMessengerState` resolved once during the first
  /// build. Reusing this captured reference for every snack call
  /// avoids re-walking the element tree after `dispose()`, which is
  /// when the original crash happened — `ScaffoldMessenger.of(
  /// context)` triggered "Looking up a deactivated widget's ancestor
  /// is unsafe" on devices where the user navigated away while the
  /// `paymentProviderInfo` request was still in flight.
  ScaffoldMessengerState? _messenger;

  /// Captured `DeepLinkService` resolved in `didChangeDependencies`.
  /// Belt-and-braces: if the screen was ever mounted without the
  /// `wrapWithProviders` wrapper (stale build / misconfigured route),
  /// `Provider<DeepLinkService>` is missing and `context.read` throws.
  /// Caching lets the start() call degrade gracefully.
  DeepLinkService? _deepLinks;

  @override
  void initState() {
    super.initState();
    _refreshProviderInfo();
    unawaited(_resumePendingTransaction());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the messenger and the deep-link service once we know
    // the inherited widget tree is stable. Doing this here (rather
    // than in initState) makes sure `Provider.of` does not run
    // before the element tree has finished mounting.
    _messenger = ScaffoldMessenger.maybeOf(context);
    // Capture the deep-link service. `context.read` would throw
    // "Could not find the correct Provider<DeepLinkService>" if a
    // caller forgot to wrap the route with `wrapWithProviders`; we
    // tolerate that and leave `_deepLinks` null so the rest of the
    // flow degrades cleanly (the timeout-based polling fallback is
    // still wired up).
    final dl = context.read<DeepLinkService?>();
    if (_deepLinks == null && dl != null) {
      _deepLinks = dl;
      // Make sure the deep-link stream is attached (no-op if already
      // started by the app shell).
      unawaited(_deepLinks!.start());
    }
  }

  @override
  void dispose() {
    _deepLinkTimer?.cancel();
    _deepLinkTimer = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _deepLinkSub?.cancel();
    _deepLinkSub = null;
    final wait = _waitForDeepLink;
    if (wait != null && !wait.isCompleted) wait.complete();
    _waitForDeepLink = null;
    super.dispose();
  }

  Future<void> _refreshProviderInfo() async {
    if (!mounted) return;

    setState(() {
      _providerLoading = true;
      _providerErrorMessage = null;
    });

    final api = context.read<ApiClient>();

    try {
      final info = await api.paymentProviderInfo();
      if (!mounted) return;

      final provider = info['provider']?.toString().trim().toLowerCase();
      final sandbox = info['sandbox'] == true;

      String? errorMessage;
      if (!widget.isCourseFree &&
          !BillingConfig.useMockPayment &&
          provider != BillingConfig.sslcommerzProviderName) {
        errorMessage =
            'Payment gateway is not configured on the server. '
            'Please contact support.';
      }

      setState(() {
        _providerName = provider;
        _providerSandbox = sandbox;
        _providerLoading = false;
        _providerErrorMessage = errorMessage;
      });

      if (errorMessage != null) {
        _showSnack(errorMessage);
      }
    } on ApiException catch (error) {
      if (!mounted) return;

      final message = widget.isCourseFree
          ? 'Provider information is temporarily unavailable.'
          : 'Payment gateway is unreachable (${error.message}). '
              'Please try again.';

      setState(() {
        // A failed provider request must never be interpreted as a free
        // provider for a paid course. Keep the provider unknown and block
        // checkout until a retry succeeds.
        _providerName = null;
        _providerSandbox = null;
        _providerLoading = false;
        _providerErrorMessage = message;
      });

      _showSnack(message);
    }
  }

  /// Free enrollment is determined by the course itself, never by a failed
  /// provider-info request. This prevents a paid course from silently falling
  /// back to the free-enrollment UI when the network is unavailable.
  bool get _isFreeProvider => widget.isCourseFree;

  bool get _providerUnavailable {
    if (widget.isCourseFree || BillingConfig.useMockPayment) return false;
    if (_providerLoading) return false;
    return _providerErrorMessage != null ||
        _providerName != BillingConfig.sslcommerzProviderName;
  }

  /// Resolve the [BillingProvider] implementation that this screen
  /// should drive. The factory honours the build-time
  /// `--dart-define=USE_MOCK_PAYMENT` flag — which is **false** by
  /// default in production builds — so paid courses always flow
  /// through [SslCommerzBillingProvider] unless the developer
  /// explicitly opts in.
  BillingProvider _billingProvider(ApiClient api) =>
      billingProviderFactory(api);

  Future<void> _savePendingTransaction(String transactionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTxnKey, transactionId);
    await prefs.setString(_pendingCourseKey, widget.courseId);
  }

  Future<void> _clearPendingTransaction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTxnKey);
    await prefs.remove(_pendingCourseKey);
  }

  Future<void> _resumePendingTransaction() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingCourse = prefs.getString(_pendingCourseKey) ?? '';
    final pendingTxn = prefs.getString(_pendingTxnKey) ?? '';
    debugPrint(
      '[MockPaymentScreen] resume check: txn=$pendingTxn course=$pendingCourse '
      'want=${widget.courseId}',
    );
    if (pendingTxn.isEmpty || pendingCourse != widget.courseId) return;

    // Re-check `mounted` after each `await` so we never read from a
    // `context` whose element tree has been deactivated. The
    // analyzer's `use_build_context_synchronously` rule wants this
    // check adjacent to every post-await `context` use.
    if (!mounted) return;
    // `api` is a Provider-scoped singleton and is safe to capture here.
    final api = context.read<ApiClient>();
    debugPrint('[MockPaymentScreen] resume: polling status for $pendingTxn');
    final status = await _pollStatusUntilSettled(api, pendingTxn);
    debugPrint(
      '[MockPaymentScreen] resume: poll returned ${status?.transactionId} '
      '${status?.status}',
    );
    if (!mounted) return;
    if (status == null || status.isPending) {
      _showSnack('Pending payment was not confirmed yet. You can retry.');
      return;
    }
    await _clearPendingTransaction();
    if (!mounted) return;
    if (status.isValid) {
      _popResult(
        transactionId: pendingTxn,
        success: true,
        method: status.paymentMethod ?? 'sslcommerz',
      );
      // The resume path skips `_confirmAndPop`/`_handleReturn`, so
      // the escalation into [EnrollmentProvider] would otherwise be
      // dropped — the user would see "Paid" in the snack but the
      // course would never appear in "My Courses". Mirror the
      // happy-path behaviour explicitly.
      await _escalateEnrollment(
        transactionId: pendingTxn,
        paymentMethod: status.paymentMethod ?? 'sslcommerz',
      );
      return;
    }
    if (status.isReviewRequired) {
      _showSnack(
        'Payment is under review. Enrollment will be updated after review.',
      );
      _popResult(
        transactionId: pendingTxn,
        success: false,
        method: status.paymentMethod ?? 'sslcommerz',
      );
      return;
    }
    _showSnack('Previous payment did not complete. Please retry.');
  }

  Future<void> _startCheckout() async {
    // Hard guard against duplicate taps. Even though the FilledButton
    // is disabled while `_busy` is true, the OS can deliver two taps
    // faster than the first setState runs (especially on low-end
    // devices or with the button rendered in a list). Treat the
    // guard as load-bearing rather than decorative.
    if (_busy || _providerLoading) return;
    if (_providerUnavailable) {
      await _refreshProviderInfo();
      return;
    }
    if (!mounted) return;
    final api = context.read<ApiClient>();
    final deepLinks = _deepLinks;
    if (deepLinks == null) {
      // The screen was mounted without `wrapWithProviders`. Degrade
      // gracefully: skip the deep-link path and let the polling
      // fallback resolve the result.
      _finishWithFailure(
        transactionId: '',
        method: BillingConfig.sslcommerzProviderName,
        message: 'Deep-link service is not available in this build.',
      );
      return;
    }
    final billing = _billingProvider(api);

    setState(() => _busy = true);

    try {
      // Route session creation through the BillingProvider abstraction
      // rather than calling ApiClient directly. This keeps a single
      // source of truth for "where do paid courses go?" — production
      // builds always reach the SSLCOMMERZ endpoint unless the
      // developer passes `--dart-define=USE_MOCK_PAYMENT=true`.
      final session = await billing.createSession(courseId: widget.courseId);

      final serverAmount = session.amount;
      if (mounted && serverAmount != null && serverAmount > 0) {
        setState(() => _confirmedAmount = serverAmount);
      }

      // Free-provider path: the backend (or the in-memory mock) may
      // mark the session as already validated when no gateway is
      // involved. We still always re-confirm via the status endpoint
      // before declaring success, because the deep-link is just a
      // UX hint — see the comment in `_confirmAndPop`.
      //
      // Misconfiguration guard: when the course IS paid but the
      // backend reports the session as already validated, the gateway
      // is unconfigured on the server (`SSLC_STORE_ID` /
      // `SSLC_STORE_PASSWORD` missing on Render) — the backend is
      // returning the free-provider response for a paid course. Treat
      // that as a hard failure rather than silently enrolling for
      // free, which would let a paying user bypass payment.
      if (session.status?.toUpperCase() == 'VALIDATED') {
        if (!widget.isCourseFree) {
          _finishWithFailure(
            transactionId: session.transactionId,
            method: BillingConfig.freeProviderName,
            message:
                'Payment gateway is not configured on the server. '
                'Please contact support.',
          );
          return;
        }
        await _clearPendingTransaction();
        final confirmed = await _confirmAndPop(api, session.transactionId);
        if (confirmed) {
          await _escalateEnrollment(
            transactionId: session.transactionId,
            paymentMethod: BillingConfig.freeProviderName,
          );
        }
        return;
      }

      if (session.gatewayPageUrl.isEmpty) {
        _finishWithFailure(
          transactionId: session.transactionId,
          method: BillingConfig.sslcommerzProviderName,
          message: 'Gateway URL missing in backend response.',
        );
        return;
      }

      await _savePendingTransaction(session.transactionId);

      // 2. Listen for the matching deep-link before launching the
      // browser, so we never miss the redirect. The listener
      // drives the flow directly so we don't depend on a Completer
      // whose continuation races with subscription cancellation in
      // tests using a fake clock.
      _deepLinkSub?.cancel();
      var handled = false;
      // Cancellable deep-link wait — the listener cancels the
      // timer as soon as a redirect arrives, otherwise the timer
      // fires and we fall back to polling the backend status.
      // The completer is owned by the State so dispose() can
      // resolve it (otherwise the await keeps the Future alive,
      // holding on to the timer's closure and the stream
      // subscription that the listener relies on).
      _deepLinkTimer?.cancel();
      final waitCompleter = _waitForDeepLink = Completer<void>();
      void markHandled() {
        if (handled) return;
        handled = true;
        _deepLinkTimer?.cancel();
        _deepLinkTimer = null;
        if (!waitCompleter.isCompleted) waitCompleter.complete();
      }

      _deepLinkSub = deepLinks.paymentReturnStream
          .where(
            (p) =>
                p.transactionId == session.transactionId ||
                p.transactionId.isEmpty,
          )
          .listen((p) {
            debugPrint(
              '[MockPaymentScreen] deep-link received: ${p.status} '
              'tx=${p.transactionId}',
            );
            if (handled) return;
            unawaited(_handleReturn(api, session.transactionId, p));
            markHandled();
          });

      final launched = await _launchExternal(session.gatewayPageUrl);
      debugPrint(
        '[MockPaymentScreen] launchUrl returned: $launched, '
        'waiting for deep-link',
      );
      if (!launched) {
        await _deepLinkSub?.cancel();
        _deepLinkSub = null;
        _finishWithFailure(
          transactionId: session.transactionId,
          method: BillingConfig.sslcommerzProviderName,
          message: 'Could not open the SSLCOMMERZ checkout page.',
        );
        return;
      }

      // 3. Wait for the deep-link (or fall back to polling). The
      // listener above calls markHandled() once a redirect
      // arrives, so this future resolves either when the listener
      // completes or when the timer fires. We keep the timer on
      // the State so dispose() can cancel it when the widget
      // tree is torn down early (otherwise it leaks past the
      // TestWidgetsFlutterBinding assertion).
      _deepLinkTimer?.cancel();
      _deepLinkTimer = Timer(_deepLinkTimeout, () {
        if (handled) return;
        debugPrint('[MockPaymentScreen] deep-link timeout, polling');
        unawaited(() async {
          if (handled) return;
          final polled = await _pollStatusUntilSettled(
            api,
            session.transactionId,
          );
          if (handled) return;
          // When polling finds no settled row, the deep-link slot is
          // already too late to drive the result. Synthesise a
          // return signal so the handler treats this branch the same
          // as a redirect that omitted the `status` query (i.e.
          // fall through to the authoritative backend status call).
          await _handleReturn(
            api,
            session.transactionId,
            PaymentReturn(
              transactionId: polled?.transactionId.isNotEmpty == true
                  ? polled!.transactionId
                  : session.transactionId,
                  status: 'unknown',
                  sourceUri: Uri.parse('educompass://payment/return'),
                ),
          );
          markHandled();
        }());
        if (!handled) markHandled();
      });

      try {
        await waitCompleter.future;
      } finally {
        _deepLinkTimer?.cancel();
        _deepLinkTimer = null;
        await _deepLinkSub?.cancel();
        _deepLinkSub = null;
        _waitForDeepLink = null;
      }
    } on ApiException catch (e) {
      _finishWithFailure(
        transactionId: '',
        method: 'sslcommerz',
        message: e.message,
      );
    } catch (e) {
      _finishWithFailure(
        transactionId: '',
        method: 'sslcommerz',
        message: 'Unexpected error: $e',
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Apply the result of either the deep-link or the polling fallback.
  /// Called directly from the stream listener so we never depend on a
  /// Completer continuation racing with subscription cancellation.
  Future<void> _handleReturn(
    ApiClient api,
    String transactionId,
    PaymentReturn ret,
  ) async {
    debugPrint('[MockPaymentScreen] handler branch: ret=${ret.status}');
    // The deep link is only a signal. The backend status endpoint is authoritative.
    final billing = _billingProvider(api);
    final deepLinkStatus = ret.status.toUpperCase();
    if (deepLinkStatus == 'FAILED' || deepLinkStatus == 'CANCELLED') {
      final verified = await billing.getStatus(transactionId);
      await _clearPendingTransaction();
      if (verified.isFailure) {
        _finishWithFailure(
          transactionId: transactionId,
          method: verified.paymentMethod ??
              BillingConfig.sslcommerzProviderName,
          message: verified.normalizedStatus == 'CANCELLED'
              ? 'Payment was cancelled at the gateway.'
              : 'Gateway declined the payment.',
        );
        return;
      }
    }
    final escalated = await _confirmAndPop(api, transactionId);
    if (escalated) {
      // Only refresh the local enrollment provider when the backend
      // confirmed a real, completed enrollment. REVIEW_REQUIRED and
      // the various failure paths all return `false` here and skip
      // this branch — the user MUST NOT see a half-paid course in
      // "My Courses".
      await _escalateEnrollment(
        transactionId: transactionId,
        paymentMethod: BillingConfig.sslcommerzProviderName,
      );
    }
  }

  Future<SslCommerzPaymentStatus?> _pollStatusUntilSettled(
    ApiClient api,
    String transactionId,
  ) async {
    SslCommerzPaymentStatus? last;
    for (var i = 0; i < _statusPollMax; i++) {
      // Use an owned Timer instead of `Future.delayed` so dispose()
      // can cancel any in-flight wait. Without this the test binding
      // flags a "Timer is still pending" assertion when the widget
      // tree is torn down mid-poll (e.g. a screen remount in a
      // test or the user navigating away during a pending
      // payment).
      final completer = Completer<void>();
      final timer = Timer(_statusPollDelay, () {
        if (!completer.isCompleted) completer.complete();
      });
      _pollTimer = timer;
      try {
        await completer.future;
      } finally {
        timer.cancel();
        if (identical(_pollTimer, timer)) _pollTimer = null;
      }
      // The widget may have been disposed while we were waiting.
      if (!mounted) return last;
      try {
        final status = await api.getSslCommerzPaymentStatus(transactionId);
        last = status;
        if (!status.isPending) return status;
      } catch (_) {
        // Keep polling — backend callbacks may not have landed yet.
      }
    }
    return last;
  }

  /// Drives the final outcome of a payment flow. Returns `true` when
  /// the backend confirmed a validated, completed enrollment — that
  /// is the only case where the caller should escalate into
  /// [EnrollmentProvider]. All other outcomes (review, failure,
  /// pending-timeout) return `false` so the caller does NOT refresh
  /// the enrollment provider; doing so would pollute the user's
  /// "My Courses" list with courses whose payment is still in
  /// review or has failed.
  Future<bool> _confirmAndPop(ApiClient api, String transactionId) async {
    // Always go through the protected backend status endpoint —
    // the deep-link query string is just a hint that the user
    // bounced back, not proof of payment.
    var status = await api.getSslCommerzPaymentStatus(transactionId);
    if (status.isPending) {
      final polled = await _pollStatusUntilSettled(api, transactionId);
      if (polled != null) {
        status = polled;
      }
    }

    if (status.isValid) {
      await _clearPendingTransaction();
      _popResult(
        transactionId: transactionId,
        success: true,
        method: status.paymentMethod ?? BillingConfig.sslcommerzProviderName,
      );
      return true;
    }

    if (status.isReviewRequired) {
      await _clearPendingTransaction();
      _finishWithFailure(
        transactionId: transactionId,
        method: status.paymentMethod ?? BillingConfig.sslcommerzProviderName,
        message:
            'Payment is under review. Enrollment will be enabled after review.',
      );
      return false;
    }

    if (status.isFailure) {
      await _clearPendingTransaction();
      _finishWithFailure(
        transactionId: transactionId,
        method: status.paymentMethod ?? BillingConfig.sslcommerzProviderName,
        message: 'Gateway reported ${status.normalizedStatus}.',
      );
      return false;
    }

    _finishWithFailure(
      transactionId: transactionId,
      method: BillingConfig.sslcommerzProviderName,
      message: 'Payment stayed pending too long. Please retry.',
    );
    return false;
  }

  /// Pushes a confirmed enrollment to the Flask backend and asks
  /// [EnrollmentProvider] to refresh its remote snapshot. Called
  /// ONLY when the backend has reported
  /// `status == validated && enrollment_completed == true` —
  /// REVIEW_REQUIRED / FAILED / CANCELLED / pending-timeout outcomes
  /// deliberately skip this path so unconfirmed courses never land
  /// in "My Courses".
  Future<void> _escalateEnrollment({
    required String transactionId,
    required String paymentMethod,
  }) async {
    if (!mounted) return;
    final enrollments = context.read<EnrollmentProvider>();
    await enrollments.pushRemote(
      courseId: widget.courseId,
      paymentMethod: paymentMethod,
      transactionId: transactionId,
      paymentStatus: 'completed',
    );
    // Trigger the Firestore → prefs merge so a second device that
    // doesn't have this enrollment locally picks it up. The
    // subscription is owned by `_EnrollmentRemoteSync` at the root,
    // so `refreshFromRemote` is idempotent.
    enrollments.refreshFromRemote();
  }

  Future<void> _freeEnrol() async {
    // Hard guard: never let the user enroll for free when the course
    // is paid. The backend reports the free billing provider when the
    // SSLCOMMERZ credentials are missing on the server; that's a
    // server-side misconfiguration, not a reason to bypass payment.
    // Without this guard a paying user could end up enrolled without
    // ever paying, which would be a billing bypass.
    if (!widget.isCourseFree) {
      _showSnack(
        'Payment gateway is not configured on the server. '
        'Please contact support.',
      );
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _popResult(
        transactionId: 'FREE-${DateTime.now().millisecondsSinceEpoch}',
        success: true,
        method: 'free',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finishWithFailure({
    required String transactionId,
    required String method,
    required String message,
  }) {
    if (!mounted) return;
    setState(() => _busy = false);
    _showSnack(message);
    _popResult(transactionId: transactionId, success: false, method: method);
  }

  void _popResult({
    required String transactionId,
    required bool success,
    required String method,
  }) {
    if (!mounted) return;
    unawaited(_clearPendingTransaction());
    Navigator.pop(context, {
      'success': success,
      'courseId': widget.courseId,
      'paymentMethod': method,
      'transactionId': transactionId,
    });
  }

  void _showSnack(String message) {
    // Two layers of guard:
    //   * `mounted` is the State getter. Reading `context` after
    //     `dispose()` throws "This widget has been unmounted, so the
    //     State no longer has a context" — `context.mounted` does
    //     NOT catch that case (it only triggers when the *element*
    //     is deactivated but the State is still associated with
    //     it). Always check `mounted` first.
    //   * The captured `_messenger` is the `ScaffoldMessengerState`
    //     resolved during `didChangeDependencies`. Reusing it skips
    //     the `ScaffoldMessenger.of(context)` ancestor lookup that
    //     was crashing with "Looking up a deactivated widget's
    //     ancestor is unsafe" when the user navigated away while a
    //     post-await snack fired.
    if (!mounted) return;
    final messenger = _messenger;
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  double? get _displayAmount {
    final confirmed = _confirmedAmount;
    if (confirmed != null && confirmed > 0) return confirmed;
    if (widget.amount > 0) return widget.amount;
    return null;
  }

  String get _formattedAmount {
    final amount = _displayAmount;
    if (amount == null) return 'server-confirmed amount';
    return '${widget.currencySymbol}${amount.toStringAsFixed(2)}';
  }

  String get _totalDueLabel {
    final amount = _displayAmount;
    if (amount == null) return 'Amount confirmed securely by server';
    return 'Total due ${widget.currencySymbol}${amount.toStringAsFixed(2)}';
  }

  Future<bool> _launchExternal(String url) async {
    final platform = UrlLauncherPlatform.instance;
    return platform.launchUrl(
      url,
      const LaunchOptions(
        mode: PreferredLaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final free = _isFreeProvider;
    final unavailable = _providerUnavailable;

    return Scaffold(
      appBar: AppBar(title: const Text('Course Payment')),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.lg,
            Spacing.lg,
            Spacing.xxl + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroBanner(
                key: const Key('payment_total_due'),
                eyebrow: 'PAYMENT',
                title: widget.courseName,
                subtitle: _totalDueLabel,
                icon: Icons.receipt_long_rounded,
              ),
              if (_providerErrorMessage != null) ...[
                const SizedBox(height: Spacing.md),
                // Inline error card so the user sees the problem even
                // when the screen was reopened after the post-await
                // snack fired.
                EduCard(
                  key: const Key('provider_error_banner'),
                  color: scheme.errorContainer,
                  border: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          _providerErrorMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onErrorContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Spacing.lg),
              EduCard(
                key: const Key('payment_provider_summary'),
                border: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Billing provider',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      free
                          ? 'No payment is required for this course.'
                          : _providerLoading
                              ? 'Checking the payment gateway configuration…'
                              : unavailable
                                  ? 'The payment gateway is currently unavailable.'
                                  : 'You will be redirected to SSLCOMMERZ to complete payment.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        return Wrap(
                          spacing: Spacing.sm,
                          runSpacing: Spacing.sm,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Icon(
                              free
                                  ? Icons.workspace_premium_rounded
                                  : unavailable
                                      ? Icons.cloud_off_rounded
                                      : _providerLoading
                                          ? Icons.sync_rounded
                                          : Icons.lock_outline_rounded,
                              color: scheme.primary,
                            ),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth - 48,
                              ),
                              child: Text(
                                free
                                    ? 'Free enrollment'
                                    : unavailable
                                        ? 'Payment unavailable'
                                        : _providerLoading
                                            ? 'Checking gateway'
                                            : 'Pay with SSLCOMMERZ',
                                key: free
                                    ? const Key('free_enrollment_label')
                                    : null,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            if (!free && !unavailable && _providerSandbox == true)
                              Pill(
                                text: 'SANDBOX',
                                icon: Icons.science_outlined,
                                color: scheme.tertiary,
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              EduCard(
                border: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      free
                          ? 'Confirm enrollment'
                          : unavailable
                              ? 'Gateway connection'
                              : 'Checkout',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      free
                          ? 'You can enrol in this course without paying. The backend will record your enrollment immediately.'
                          : unavailable
                              ? 'Retry the gateway check. Paid enrollment remains blocked until the server confirms SSLCOMMERZ is available.'
                              : _providerLoading
                                  ? 'Please wait while EduCompass checks the payment gateway.'
                                  : 'Tap the button below to open the secure SSLCOMMERZ checkout in your browser. After paying, you will return to the app.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                      key: free
                          ? const Key('free_enrollment_cta')
                          : const Key('payment_primary_cta'),
                      onPressed: _busy || _providerLoading
                          ? null
                          : free
                              ? _freeEnrol
                              : unavailable
                                  ? _refreshProviderInfo
                                  : _startCheckout,
                      icon: _busy || _providerLoading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              free
                                  ? Icons.check_circle_outline_rounded
                                  : unavailable
                                      ? Icons.refresh_rounded
                                      : Icons.open_in_new_rounded,
                            ),
                      label: Text(
                        free
                            ? 'Enrol for free'
                            : _providerLoading
                                ? 'Checking gateway…'
                                : unavailable
                                    ? 'Retry gateway'
                                    : _busy
                                        ? 'Opening gateway…'
                                        : _displayAmount == null
                                            ? 'Continue to SSLCOMMERZ'
                                            : 'Pay $_formattedAmount',
                        key: _busy && !free
                            ? const Key('payment_loading_label')
                            : null,
                      ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      free
                          ? 'Free courses do not call the gateway.'
                          : unavailable
                              ? 'Paid enrollment cannot continue until the gateway check succeeds.'
                              : 'Complete checkout in the secure SSLCOMMERZ page, then return to EduCompass.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
