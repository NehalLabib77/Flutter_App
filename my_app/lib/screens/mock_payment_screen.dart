/// SSLCOMMERZ-hosted checkout for EduCompass course enrollment.
///
/// The client sends only course_id. The Flask backend resolves the official
/// price, creates the gateway session, validates callbacks and completes the
/// enrollment. A deep link is only a return signal; this screen always checks
/// the protected backend status endpoint before showing success.
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
import 'payment_status_screen.dart';

class MockPaymentScreen extends StatefulWidget {
  const MockPaymentScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    this.amount,
    this.currencySymbol = '৳',
    this.isCourseFree = false,
  });

  final String courseId;
  final String courseName;

  /// Display-only hint from the course record. The backend response is the
  /// authoritative amount and replaces this value as soon as a session exists.
  final double? amount;
  final String currencySymbol;
  final bool isCourseFree;

  @override
  State<MockPaymentScreen> createState() => _MockPaymentScreenState();
}

class _MockPaymentScreenState extends State<MockPaymentScreen>
    with WidgetsBindingObserver {
  static const String _pendingTxnKey = 'pending_sslc_transaction_id';
  static const String _pendingCourseKey = 'pending_sslc_course_id';
  static const String _pendingCreatedKey = 'pending_sslc_created_at';
  static const int _statusPollMax = 6;
  static const Duration _statusPollDelay = Duration(seconds: 2);

  StreamSubscription<PaymentReturn>? _deepLinkSubscription;
  Timer? _pollTimer;
  DeepLinkService? _deepLinks;

  bool _providerLoading = true;
  bool _busy = false;
  bool _checkingStatus = false;
  bool _showingStatus = false;
  bool _awaitingReturn = false;
  String? _providerName;
  bool? _providerSandbox;
  String? _error;
  String? _pendingTransactionId;
  double? _serverAmount;
  String _serverCurrency = 'BDT';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadProvider());
      unawaited(_restorePendingTransaction());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_deepLinks != null) return;
    _deepLinks = context.read<DeepLinkService>();
    unawaited(_deepLinks!.start());
    _deepLinkSubscription = _deepLinks!.paymentReturnStream.listen(
      _onPaymentReturn,
      onError: (_) {},
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _pendingTransactionId != null &&
        !_showingStatus) {
      unawaited(_verifyAndShow(_pendingTransactionId!));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _deepLinkSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadProvider() async {
    try {
      final info = await context.read<ApiClient>().paymentProviderInfo();
      if (!mounted) return;
      final provider = info['provider']?.toString().trim().toLowerCase();
      setState(() {
        _providerName = provider;
        _providerSandbox = info['sandbox'] == true;
        _providerLoading = false;
        if (!widget.isCourseFree &&
            (provider == null ||
                provider.isEmpty ||
                provider == BillingConfig.freeProviderName)) {
          _error = 'SSLCOMMERZ is not configured on the server.';
        } else {
          _error = null;
        }
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _providerLoading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _providerLoading = false;
        _error = 'Could not load the payment provider.';
      });
    }
  }

  Future<void> _restorePendingTransaction() async {
    final prefs = await SharedPreferences.getInstance();
    final transactionId = prefs.getString(_pendingTxnKey)?.trim() ?? '';
    final courseId = prefs.getString(_pendingCourseKey)?.trim() ?? '';
    if (!mounted || transactionId.isEmpty || courseId != widget.courseId) return;
    setState(() {
      _pendingTransactionId = transactionId;
      _awaitingReturn = true;
    });

    final coldReturn = _deepLinks?.consumeInitialPaymentReturn();
    if (coldReturn != null && coldReturn.transactionId == transactionId) {
      await _verifyAndShow(transactionId);
      return;
    }
    await _verifyAndShow(transactionId, poll: false);
  }

  Future<void> _savePendingTransaction(String transactionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pendingTxnKey, transactionId);
    await prefs.setString(_pendingCourseKey, widget.courseId);
    await prefs.setString(
      _pendingCreatedKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<void> _clearPendingTransaction() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingTxnKey);
    await prefs.remove(_pendingCourseKey);
    await prefs.remove(_pendingCreatedKey);
    if (mounted) {
      setState(() {
        _pendingTransactionId = null;
        _awaitingReturn = false;
      });
    }
  }

  void _onPaymentReturn(PaymentReturn event) {
    final active = _pendingTransactionId;
    if (active == null || active.isEmpty) return;
    if (event.transactionId.isNotEmpty && event.transactionId != active) return;
    // event.status is deliberately ignored. The backend status is authoritative.
    unawaited(_verifyAndShow(active));
  }

  Future<bool> _launchExternal(String url) {
    return UrlLauncherPlatform.instance.launchUrl(
      url,
      const LaunchOptions(
        mode: PreferredLaunchMode.externalApplication,
        webOnlyWindowName: '_self',
      ),
    );
  }

  Future<void> _startCheckout() async {
    if (_busy || _checkingStatus) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = context.read<ApiClient>();
      final session = await api.createSslCommerzSession(
        courseId: widget.courseId,
      );
      if (!mounted) return;

      if (session.transactionId.trim().isEmpty) {
        throw const ApiException(
          502,
          'The server returned an invalid transaction reference.',
          code: 'INVALID_PAYMENT_SESSION',
        );
      }

      setState(() {
        _pendingTransactionId = session.transactionId;
        _serverAmount = session.amount ?? _serverAmount;
        _serverCurrency = session.currency ?? _serverCurrency;
        _providerSandbox = session.mode == 'sandbox' || _providerSandbox == true;
        _awaitingReturn = true;
      });
      await _savePendingTransaction(session.transactionId);

      if ((session.status ?? '').toUpperCase() == 'VALIDATED') {
        await _verifyAndShow(session.transactionId);
        return;
      }

      final gatewayUrl = session.gatewayUrl.trim();
      if (!gatewayUrl.startsWith('https://')) {
        throw const ApiException(
          502,
          'The gateway did not return a secure checkout URL.',
          code: 'INVALID_GATEWAY_URL',
        );
      }
      final launched = await _launchExternal(gatewayUrl);
      if (!launched) {
        throw const ApiException(
          0,
          'Could not open the SSLCOMMERZ checkout page.',
          code: 'CHECKOUT_LAUNCH_FAILED',
        );
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not start the payment checkout.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<SslCommerzPaymentStatus> _fetchSettledStatus(
    String transactionId, {
    required bool poll,
  }) async {
    final api = context.read<ApiClient>();
    var status = await api.getSslCommerzPaymentStatus(transactionId);
    if (!poll || !status.isPending) return status;

    for (var attempt = 0; attempt < _statusPollMax; attempt++) {
      await _wait(_statusPollDelay);
      if (!mounted) return status;
      status = await api.getSslCommerzPaymentStatus(transactionId);
      if (!status.isPending) break;
    }
    return status;
  }

  Future<void> _wait(Duration duration) async {
    final completer = Completer<void>();
    final timer = Timer(duration, completer.complete);
    _pollTimer = timer;
    try {
      await completer.future;
    } finally {
      timer.cancel();
      if (identical(_pollTimer, timer)) _pollTimer = null;
    }
  }

  Future<void> _verifyAndShow(
    String transactionId, {
    bool poll = true,
  }) async {
    if (_checkingStatus || _showingStatus || !mounted) return;
    setState(() {
      _checkingStatus = true;
      _error = null;
    });

    try {
      var latest = await _fetchSettledStatus(transactionId, poll: poll);
      if (!mounted) return;
      setState(() {
        _serverAmount = latest.amount ?? _serverAmount;
        _serverCurrency = latest.currency ?? _serverCurrency;
        _showingStatus = true;
      });

      final completed = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) => PaymentStatusScreen(
            api: context.read<ApiClient>(),
            initialStatus: latest,
            courseName: widget.courseName,
            onStatusChanged: (updated) {
              latest = updated;
              if (!mounted) return;
              setState(() {
                _serverAmount = updated.amount ?? _serverAmount;
                _serverCurrency = updated.currency ?? _serverCurrency;
              });
            },
          ),
        ),
      );
      if (!mounted) return;

      if (completed == true) {
        await _clearPendingTransaction();
        context.read<EnrollmentProvider>().refreshFromRemote();
        if (!mounted) return;
        Navigator.pop<Map<String, dynamic>>(context, {
          'success': true,
          'courseId': widget.courseId,
          'paymentMethod': latest.cardType ??
              latest.paymentMethod ??
              BillingConfig.sslcommerzProviderName,
          'transactionId': latest.transactionId,
          'amount': latest.amount,
          'currency': latest.currency,
        });
        return;
      }

      if (latest.isFailure) {
        await _clearPendingTransaction();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not verify the payment status.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _checkingStatus = false;
          _showingStatus = false;
        });
      }
    }
  }

  String get _displayAmount {
    final amount = _serverAmount ?? widget.amount;
    if (amount == null || amount <= 0) return 'Confirmed securely by server';
    final prefix = _serverCurrency == 'BDT'
        ? widget.currencySymbol
        : '$_serverCurrency ';
    return '$prefix${amount.toStringAsFixed(2)}';
  }

  String get _buttonLabel {
    final amount = _serverAmount ?? widget.amount;
    if (amount == null || amount <= 0) return 'Continue to secure checkout';
    return 'Pay $_displayAmount';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paidProviderUnavailable = !widget.isCourseFree &&
        !_providerLoading &&
        (_providerName == null ||
            _providerName!.isEmpty ||
            _providerName == BillingConfig.freeProviderName);
    final disabled = _busy ||
        _checkingStatus ||
        _providerLoading ||
        paidProviderUnavailable;

    return Scaffold(
      appBar: AppBar(title: const Text('Course Payment')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroBanner(
                eyebrow: 'PAYMENT',
                title: widget.courseName,
                subtitle: 'Total due: $_displayAmount',
                icon: Icons.receipt_long_rounded,
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.md),
                EduCard(
                  color: scheme.errorContainer,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline_rounded,
                          color: scheme.onErrorContainer),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          _error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
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
                border: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Billing provider',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      widget.isCourseFree
                          ? 'This course will be enrolled directly by the server.'
                          : 'You will be redirected to SSLCOMMERZ for secure checkout.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Spacing.lg),
                    Row(
                      children: [
                        Icon(
                          widget.isCourseFree
                              ? Icons.workspace_premium_rounded
                              : Icons.lock_outline_rounded,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: Spacing.sm),
                        Expanded(
                          child: Text(
                            widget.isCourseFree
                                ? 'Free enrollment'
                                : (_providerLoading
                                    ? 'Checking provider…'
                                    : 'Pay with SSLCOMMERZ'),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (!widget.isCourseFree && _providerSandbox == true)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.sm,
                              vertical: Spacing.xs,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.tertiaryContainer,
                              borderRadius: Radii.pill,
                            ),
                            child: Text(
                              'SANDBOX',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onTertiaryContainer,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                      ],
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
                      _awaitingReturn ? 'Waiting for confirmation' : 'Checkout',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      _awaitingReturn
                          ? 'Complete the payment in your browser. EduCompass will verify it automatically when you return.'
                          : 'The backend confirms the official price and creates a protected checkout session.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: Spacing.lg),
                    FilledButton.icon(
                      onPressed: disabled
                          ? null
                          : (_awaitingReturn && _pendingTransactionId != null
                              ? () => _verifyAndShow(_pendingTransactionId!)
                              : _startCheckout),
                      icon: _busy || _checkingStatus
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _awaitingReturn
                                  ? Icons.refresh_rounded
                                  : Icons.open_in_new_rounded,
                            ),
                      label: Text(
                        _checkingStatus
                            ? 'Verifying payment…'
                            : _awaitingReturn
                                ? 'Check payment status'
                                : _buttonLabel,
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: Spacing.sm),
                      Center(
                        child: TextButton.icon(
                          onPressed: _providerLoading ? null : _loadProvider,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry provider check'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      'Course access is granted only after secure server validation.',
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
