/// Sign-in screen — Firebase email + password, gated on `emailVerified`,
/// then exchanges the verified Firebase session for an EduCompass JWT.
///
/// The user can:
///  * sign in with email + password;
///  * if their email isn't verified yet, the screen surfaces a friendly
///    message and lets AuthWrapper's `userChanges` stream route them to
///    [EmailVerificationScreen] (the screen pushes itself, we do not
///    push a duplicate here);
///  * tap "Resend verification email" on the verification screen to ask
///    Firebase to send a fresh link (cooldown handled by the screen).
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

  /// Exchange the verified Firebase session for the EduCompass JWT
  /// and push the user into the shell. Extracted so the verification
  /// screen can trigger the same completion path after the email is
  /// verified.
  Future<void> _completePostVerificationLogin() async {
    final auth = context.read<AuthProvider>();
    try {
      await auth.login(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const ShellScreen()),
      (route) => false,
    );
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _submitting = true);

    try {
      await _service.signInWithEmail(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );
      // Verified! Exchange Firebase session for the EduCompass JWT so
      // the API client can call protected routes.
      await _completePostVerificationLogin();
    } on FirebaseAuthFailure catch (e) {
      if (e.kind == FirebaseAuthFailureKind.emailNotVerified) {
        // Keep the Firebase session alive (signInWithEmail did not
        // sign it out) and let AuthWrapper's `userChanges` stream
        // route to EmailVerificationScreen. We do NOT push the screen
        // ourselves — that would race with the StreamBuilder tick
        // and produce a double-navigation. We just stay put so the
        // wrapper can take over.
        if (!mounted) return;
        _showMessage(e.message);
        return;
      }
      _showMessage(e.message);
    } catch (e) {
      _showMessage('Sign in failed. Please try again.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  /// Resend the verification email without first signing in. Uses the
  /// user's email + password as proof of account ownership so
  /// Firebase will accept the OOB request.
  Future<void> _resendVerification() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _submitting = true);
    try {
      await _service.resendVerificationWithPassword(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );
      if (!mounted) return;
      _showMessage(
        'Verification email has been sent again. Check your inbox.',
      );
    } on FirebaseAuthFailure catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    } catch (e) {
      if (!mounted) return;
      _showMessage('Unable to resend verification email.');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Sign in',
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
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
              autofillHints: const [AutofillHints.email],
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
              onSubmitted: (_) => _submit(),
            ),
            AuthPrimaryButton(
              label: _submitting ? 'Signing in' : 'Sign in',
              icon: Icons.login_rounded,
              busy: _submitting,
              onPressed: _submitting ? null : _submit,
            ),
            const SizedBox(height: 8),
            AuthFootnoteLink(
              prefix: 'Didn\'t receive the verification email?',
              linkLabel: 'Resend verification email',
              onTap: _submitting ? () {} : _resendVerification,
            ),
            const SizedBox(height: 12),
            AuthFootnoteLink(
              prefix: "Don't have an account?",
              linkLabel: 'Sign up',
              onTap: _submitting
                  ? () {}
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RegisterScreen(
                            firebaseAuthService: _service,
                          ),
                        ),
                      );
                    },
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Validators
// -----------------------------------------------------------------------------

String? _validateEmail(String? value) {
  final email = (value ?? '').trim();

  if (email.isEmpty) {
    return 'Email is required';
  }

  final pattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  if (!pattern.hasMatch(email)) {
    return 'Please enter a valid email address';
  }

  return null;
}

String? _validatePassword(String? value) {
  final password = value ?? '';

  if (password.isEmpty) {
    return 'Password is required';
  }

  if (password.length < 8) {
    return 'Password must be at least 8 characters';
  }

  return null;
}
