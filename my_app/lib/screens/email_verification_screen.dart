/// Full-screen interstitial shown after registration or after the user
/// signs in with an unverified address. Auto-detects verification by
/// polling the Firebase user + a resume hook (lifecycle + manual
/// tap-out-and-back). Offers a 60-second cooldown-gated resend and a
/// "Use another account" sign-out escape hatch — but *no* manual
/// "I have verified" button. The AuthWrapper's `userChanges` stream
/// is the source of truth; this screen just keeps the local
/// `FirebaseAuth` instance fresh so the cached `emailVerified`
/// flag catches up.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/firebase_auth_service.dart';

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({
    super.key,
    required this.email,
    this.service,
    this.onVerified,
    this.onUseAnotherAccount,
    this.pollInterval = const Duration(seconds: 4),
  });

  /// Email address the verification link was sent to. Displayed in the
  /// body so the user knows where to look.
  final String email;

  /// Dependency-injected so unit tests can supply a fake.
  final FirebaseAuthService? service;

  /// Called when the user has successfully verified their email and the
  /// screen is about to be popped. The AuthWrapper observes the
  /// Firebase auth state and would swap screens automatically, but this
  /// callback lets the caller force a rebuild immediately.
  final VoidCallback? onVerified;

  /// Called when the user taps "Use another account" and we have
  /// signed them out. AuthWrapper handles the route swap.
  final VoidCallback? onUseAnotherAccount;

  /// How often to poll for verification while the screen is in the
  /// foreground. Overridable so widget tests can crank it down.
  final Duration pollInterval;

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen>
    with WidgetsBindingObserver {
  static const Duration _resendCooldown = Duration(seconds: 60);

  bool _sending = false;
  int _resendSeconds = 0;
  Timer? _cooldownTimer;
  Timer? _pollTimer;
  bool _pollInFlight = false;

  /// Single-flight guard: once we've handed the verified user off to
  /// the AuthWrapper (via `onVerified`) we MUST NOT fire onVerified
  /// again or restart polling — that would race with the AuthWrapper's
  /// own rebuild.
  bool _navigated = false;

  FirebaseAuthService get _service =>
      widget.service ?? FirebaseAuthServiceFactory.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startCooldown();
    _startPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // When the user comes back from their mail app the verification
    // may have just landed. Force a reload + check on resume.
    if (state == AppLifecycleState.resumed && !_navigated) {
      _checkVerification(triggeredByResume: true);
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(widget.pollInterval, (_) {
      if (!mounted || _navigated) return;
      _checkVerification();
    });
    // Kick off an immediate check too — the user might already have
    // verified before this screen mounted.
    _checkVerification();
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    if (!mounted) return;
    setState(() => _resendSeconds = _resendCooldown.inSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendSeconds <= 1) {
        timer.cancel();
        setState(() => _resendSeconds = 0);
      } else {
        setState(() => _resendSeconds--);
      }
    });
  }

  Future<void> _checkVerification({bool triggeredByResume = false}) async {
    if (_navigated) return;
    if (_pollInFlight) return; // overlap guard — never start a check
    // while the previous one is still on the wire.
    if (!mounted) return;
    _pollInFlight = true;
    try {
      await _service.reloadCurrentUser();
      final verified = await _service.isCurrentEmailVerified();
      if (!mounted || _navigated) return;
      if (verified) {
        _navigated = true;
        _stopPolling();
        _cooldownTimer?.cancel();
        widget.onVerified?.call();
        return;
      }
      if (triggeredByResume) {
        // Only nag on a user-initiated resume; the periodic poll
        // should stay silent so we don't spam SnackBars.
        _showSnack(
          'Still waiting — tap the link in the verification email.',
        );
      }
    } on FirebaseAuthFailure catch (e) {
      if (!mounted || _navigated) return;
      _showSnack(e.message);
    } catch (_) {
      if (!mounted || _navigated) return;
      // Best-effort: polling must never crash the screen. The next
      // tick will try again.
    } finally {
      _pollInFlight = false;
    }
  }

  Future<void> _resendEmail() async {
    if (_resendSeconds > 0 || _sending) return;
    if (!mounted) return;
    setState(() => _sending = true);
    try {
      await _service.sendVerificationEmailToCurrent();
      _startCooldown();
      if (!mounted) return;
      _showSnack('Verification email sent again.');
    } on FirebaseAuthFailure catch (e) {
      if (!mounted) return;
      _showSnack(e.message);
    } catch (_) {
      if (!mounted) return;
      _showSnack('Unable to send verification email.');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _signOut() async {
    _navigated = true;
    _stopPolling();
    _cooldownTimer?.cancel();
    try {
      await _service.signOutCurrent();
    } catch (_) {
      // Best-effort. AuthWrapper will treat a null current user as
      // signed-out regardless.
    }
    if (!mounted) return;
    widget.onUseAnotherAccount?.call();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _stopPolling();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.mark_email_unread_outlined,
                size: 72,
                color: Colors.blueGrey,
              ),
              const SizedBox(height: 24),
              const Text(
                'Check your inbox',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                'We sent a verification link to:\n${widget.email}',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'This screen will update automatically once you tap '
                'the verification link. You can keep using the app '
                'in the meantime.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 32),
              TextButton(
                onPressed:
                    (_sending || _resendSeconds > 0) ? null : _resendEmail,
                child: Text(
                  _resendSeconds > 0
                      ? 'Resend in $_resendSeconds seconds'
                      : 'Resend verification email',
                ),
              ),
              TextButton(
                onPressed: _signOut,
                child: const Text('Use another account'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}