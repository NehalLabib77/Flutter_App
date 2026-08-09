/// Sign-in screen — Firebase email + password, gated on `emailVerified`,
/// then exchanges the verified Firebase session for an EduCompass JWT.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../services/firebase_auth_service.dart';
import 'auth_chrome.dart';
import 'register_screen.dart';
import 'shell_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.firebaseAuthService});

  final FirebaseAuthService? firebaseAuthService;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _submitting = false;

  FirebaseAuthService get _service =>
      widget.firebaseAuthService ?? FirebaseAuthServiceFactory.instance;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _completePostVerificationLogin() async {
    final authProvider = context.read<AuthProvider>();

    try {
      await authProvider.login(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
      return;
    }

    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const ShellScreen()),
      (_) => false,
    );
  }

  Future<void> _submit() async {
    if (_submitting) return;

    FocusManager.instance.primaryFocus?.unfocus();

    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() => _submitting = true);

    try {
      await _service.signInWithEmail(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );

      if (!mounted) return;
      await _completePostVerificationLogin();
    } on FirebaseAuthFailure catch (error) {
      if (!mounted) return;

      if (error.kind == FirebaseAuthFailureKind.emailNotVerified) {
        // Keep the Firebase session alive. AuthWrapper observes the
        // unverified user and opens EmailVerificationScreen.
        _showMessage(error.message);
        return;
      }

      _showMessage(error.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('Sign in failed. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _resendVerification() async {
    if (_submitting) return;

    FocusManager.instance.primaryFocus?.unfocus();

    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;

    setState(() => _submitting = true);

    try {
      await _service.resendVerificationWithPassword(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );

      if (!mounted) return;
      _showMessage('Verification email has been sent again. Check your inbox.');
    } on FirebaseAuthFailure catch (error) {
      if (!mounted) return;
      _showMessage(error.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('Unable to resend the verification email.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _openRegistration() {
    if (_submitting) return;

    FocusManager.instance.primaryFocus?.unfocus();

    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegisterScreen(firebaseAuthService: _service),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message, maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Sign in',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthHeading(
                kicker: 'Welcome back',
                title: 'Sign in to continue',
                body:
                    'Use the email and password you used when you '
                    'created your account.',
              ),
              InsetField(
                controller: _emailCtrl,
                label: 'Email',
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                textInputAction: TextInputAction.next,
                validator: _validateEmail,
              ),
              InsetField(
                controller: _passwordCtrl,
                label: 'Password',
                icon: Icons.lock_outline,
                obscure: true,
                autofillHints: const [AutofillHints.password],
                textInputAction: TextInputAction.done,
                validator: _validatePassword,
                onSubmitted: (_) {
                  if (!_submitting) _submit();
                },
              ),
              AuthPrimaryButton(
                label: _submitting ? 'Signing in' : 'Sign in',
                icon: Icons.login_rounded,
                busy: _submitting,
                onPressed: _submitting ? null : _submit,
              ),
              const SizedBox(height: 6),
              AuthFootnoteLink(
                prefix: 'Didn\'t receive the verification email?',
                linkLabel: 'Resend verification email',
                onTap: _submitting ? () {} : _resendVerification,
              ),
              const SizedBox(height: 8),
              AuthFootnoteLink(
                prefix: 'Don\'t have an account?',
                linkLabel: 'Sign up',
                onTap: _submitting ? () {} : _openRegistration,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String? _validateEmail(String? value) {
  final email = (value ?? '').trim();

  if (email.isEmpty) return 'Email is required';

  final pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  if (!pattern.hasMatch(email)) return 'Please enter a valid email address';

  return null;
}

String? _validatePassword(String? value) {
  final password = value ?? '';

  if (password.isEmpty) return 'Password is required';
  if (password.length < 8) return 'Password must be at least 8 characters';

  return null;
}
