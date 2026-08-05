/// Listens for OS-level deep links and exposes them as a Dart [Stream].
///
/// EduCompass uses the `educompass://` scheme to bounce users back from
/// the SSLCOMMERZ sandbox gateway. The backend's success / fail / cancel
/// endpoints redirect the browser (or external app) to
///
///   `educompass://payment/return?transaction_id=<id>&status=<...>`
///
/// and this service is responsible for:
///   1. parsing the cold-start URI on Android (delivered as `getInitialAppLink`)
///   2. streaming warm-start URIs as they arrive
///   3. verifying the scheme/host before forwarding so unrelated URIs
///      (e.g. universal links, OAuth callbacks) are ignored.
///
/// The Flutter app constructs a single instance at startup; widgets
/// listen via [paymentReturnStream] or [stream] filtered by
/// [Uri.host] == 'payment'.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Topics emitted by [DeepLinkService.paymentReturnStream].
class PaymentReturn {
  final String transactionId;
  final String status; // 'valid' | 'failed' | 'cancelled' | raw
  final Uri sourceUri;
  const PaymentReturn({
    required this.transactionId,
    required this.status,
    required this.sourceUri,
  });
}

class DeepLinkService {
  final AppLinks _appLinks;
  final StreamController<Uri> _all = StreamController<Uri>.broadcast();
  bool _started = false;
  StreamSubscription<Uri>? _platformSubscription;

  /// Cold-start URI captured before the first listener attaches. We
  /// stash it here so a caller that asks for it on the very first
  /// build (before the broadcast stream has anyone listening) still
  /// gets to see it. Cleared by [consumeInitialVerificationCode].
  Uri? _pendingVerificationInitial;
  Uri? _pendingPaymentInitial;

  DeepLinkService({AppLinks? appLinks})
      : _appLinks = appLinks ?? AppLinks();

  /// Stream of every deep link the OS hands us, after the [schemeFilter]
  /// (default: `educompass`) is applied. Tests can substitute this with
  /// a [StreamController.broadcast] by overriding the constructor.
  Stream<Uri> get stream => _all.stream;

  /// Stream of only the `educompass://payment/return?transaction_id=...`
  /// deep links the backend emits. Emits parsed [PaymentReturn] events
  /// so consumers don't have to do their own URL parsing.
  Stream<PaymentReturn> get paymentReturnStream =>
      _all.stream.where(_isPaymentReturn).map(_parsePaymentReturn);

  /// Stream of `educompass://verify-email?oobCode=...` deep links that
  /// Firebase rewrites the verification-email URL into. Emits the raw
  /// `oobCode` string so the consumer (AuthWrapper) can hand it to
  /// `FirebaseAuthService.applyVerificationCode`.
  Stream<String> get verificationReturnStream =>
      _all.stream.where(_isVerificationReturn).map(_extractOobCode);

  /// Synchronously check the cold-start URI for a verification code.
  /// Returns `null` if the app was launched normally (i.e. the initial
  /// deep link was the payment flow or none at all). Used by
  /// AuthWrapper on first build so a user who tapped the link on a
  /// cold-installed app still gets bounced straight into the shell.
  String? consumeInitialVerificationCode() {
    final initial = _pendingVerificationInitial;
    _pendingVerificationInitial = null;
    if (initial == null) return null;
    return _extractOobCode(initial);
  }

  /// Returns a payment return that launched the app before the payment
  /// screen attached to the broadcast stream. Consuming verification does
  /// not discard this URI, and vice versa.
  PaymentReturn? consumeInitialPaymentReturn() {
    final initial = _pendingPaymentInitial;
    _pendingPaymentInitial = null;
    if (initial == null) return null;
    return _parsePaymentReturn(initial);
  }

  /// Initialise the platform channel listener. Idempotent — safe to
  /// call more than once. Returns a [Future] that completes once the
  /// cold-start URI (if any) has been emitted or skipped.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      // Warm path: listen for URIs while the app is in the foreground.
      _platformSubscription =
          _appLinks.uriLinkStream.listen(_safeEmit, onError: _handleError);
    } catch (e) {
      _handleError(e);
    }
    // Cold path: if the app was launched *because of* a deep link,
    // the URI lands here. We delay briefly so the broadcast stream has
    // time to attach a listener first.
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null && _isEduCompass(initial)) {
        // Also stash it on the instance so a synchronous caller on the
        // first frame (AuthWrapper) can read it before any listener
        // attaches to the broadcast stream.
        if (_isVerificationReturn(initial)) {
          _pendingVerificationInitial = initial;
        } else if (_isPaymentReturn(initial)) {
          _pendingPaymentInitial = initial;
        }
        _safeEmit(initial);
      }
    } catch (e) {
      _handleError(e);
    }
  }

  Future<void> dispose() async {
    await _platformSubscription?.cancel();
    _platformSubscription = null;
    if (!_all.isClosed) await _all.close();
  }

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------

  void _safeEmit(Uri uri) {
    if (!_all.isClosed && _isEduCompass(uri)) {
      _all.add(uri);
    }
  }

  void _handleError(Object error) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[DeepLinkService] error: $error');
    }
  }

  bool _isEduCompass(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'educompass';
  }

  bool _isPaymentReturn(Uri uri) {
    if (!_isEduCompass(uri)) return false;
    final host = uri.host.toLowerCase();
    final segments = uri.pathSegments;
    return host == 'payment' && segments.isNotEmpty &&
        segments.first.toLowerCase() == 'return';
  }

  PaymentReturn _parsePaymentReturn(Uri uri) {
    final params = uri.queryParameters;
    return PaymentReturn(
      transactionId: params['transaction_id'] ?? '',
      status: params['status'] ?? 'unknown',
      sourceUri: uri,
    );
  }

  bool _isVerificationReturn(Uri uri) {
    if (!_isEduCompass(uri)) return false;
    return uri.host.toLowerCase() == 'verify-email';
  }

  String _extractOobCode(Uri uri) {
    return uri.queryParameters['oobCode'] ?? '';
  }
}
