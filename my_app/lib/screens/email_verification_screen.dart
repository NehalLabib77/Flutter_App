/// Full-screen interstitial shown after registration or after the user
/// signs in with an unverified address. Offers a manual "I have
/// verified my email" check, a 60-second cooldown-gated resend, and a
/// "Use another account" sign-out escape hatch.
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

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  static const Duration _resendCooldown = Duration(seconds: 60);

  bool _checking = false;
  bool _sending = false;
  int _resendSeconds = 0;
  Timer? _timer;

  FirebaseAuthService get _service =>
      widget.service ?? FirebaseAuthServiceFactory.instance;

  @override
  void initState() {
    super.initState();
    _startCooldown();
  }

  void _startCooldown() {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _resendSeconds = _resendCooldown.inSeconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
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

  Future<void> _checkVerification() async {
    if (!mounted) return;
    setState(() => _checking = true);
    try {
      await _service.reloadCurrentUser();
      final verified = await _service.isCurrentEmailVerified();
      if (!mounted) return;
      if (verified) {
        _showSnack('Email verified successfully.');
        widget.onVerified?.call();
        return;
      }
      _showSnack(
        'Email is not verified yet. Click the link in your inbox.',
      );
    } on FirebaseAuthFailure catch (e) {
      if (!mounted) return;
      _showSnack(e.message);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Unable to check verification.');
    } finally {
      if (mounted) {
        setState(() => _checking = false);
      }
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
    } catch (e) {
      if (!mounted) return;
      _showSnack('Unable to send verification email.');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
    }
  }

  Future<void> _signOut() async {
    try {
      await _service.signOutCurrent();
    } catch (e) {
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
    _timer?.cancel();
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
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: _checking ? null : _checkVerification,
                child: _checking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('I have verified my email'),
              ),
              const SizedBox(height: 12),
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