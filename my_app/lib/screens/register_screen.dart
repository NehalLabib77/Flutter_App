/// Sign-up screen — Firebase email + password + verification link.
///
/// The screen creates a Firebase Auth user, sends the verification
/// email, and stays on the registration screen. AuthWrapper's
/// `userChanges` stream observes the new (unverified) user and routes
/// to [EmailVerificationScreen] on the next tick. We deliberately do
/// NOT push the screen ourselves — that would race with the
/// StreamBuilder and cause a double rebuild.
///
/// The EduCompass backend's SQL mirror row is **not** created here —
/// that happens on the first successful backend login, which only
/// happens once the user has verified. (See `routes.register` and the
/// `verified_user_required` decorator.)
library;

import 'package:flutter/material.dart';

import '../services/firebase_auth_service.dart';
import 'auth_chrome.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, this.firebaseAuthService});

  /// Optional override for tests.
  final FirebaseAuthService? firebaseAuthService;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _submitting = false;

  FirebaseAuthService get _service =>
      widget.firebaseAuthService ?? FirebaseAuthServiceFactory.instance;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() => _submitting = true);

    try {
      await _service.registerWithEmail(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
        name: _nameCtrl.text.trim(),
      );

      if (!mounted) return;

      // Firebase created the user and fired the verification email.
      // The user remains signed in (signOut was removed from the auth
      // service) so AuthWrapper's `userChanges` stream will see the
      // unverified user and rebuild into EmailVerificationScreen on
      // its own. We deliberately do not push the screen ourselves —
      // doing so would race with the StreamBuilder tick and cause a
      // double-navigation. Just stay put and let the wrapper take
      // over. If the stream is somehow delayed we nudge the user.
      _showMessage(
        'Account created. Please check your inbox to verify your '
        'email before signing in.',
      );
    } on FirebaseAuthFailure catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('Sign up failed. Please try again.');
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
      title: 'Create account',
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeading(
              kicker: 'Get started',
              title: 'Create your account',
              body:
                  'Enter your details below. We will email you a '
                  'verification link.',
            ),
            InsetField(
              controller: _nameCtrl,
              label: 'Full name',
              icon: Icons.person_outline,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.next,
              validator: _validateName,
            ),
            InsetField(
              controller: _emailCtrl,
              label: 'Email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.newUsername],
              textInputAction: TextInputAction.next,
              validator: _validateEmail,
            ),
            InsetField(
              controller: _passwordCtrl,
              label: 'Password',
              icon: Icons.lock_outline,
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.next,
              validator: _validatePassword,
            ),
            InsetField(
              controller: _confirmCtrl,
              label: 'Confirm password',
              icon: Icons.lock_outline,
              obscure: true,
              autofillHints: const [AutofillHints.newPassword],
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              validator: (value) => _validateConfirm(value, _passwordCtrl.text),
            ),
            AuthPrimaryButton(
              label: _submitting ? 'Creating account' : 'Create account',
              icon: Icons.person_add_alt_1_rounded,
              busy: _submitting,
              onPressed: _submitting ? null : _submit,
            ),
            const SizedBox(height: 20),
            AuthFootnoteLink(
              prefix: 'Already have an account?',
              linkLabel: 'Log in',
              onTap: _submitting
                  ? () {}
                  : () {
                      Navigator.of(context).pushReplacement(
                        MaterialPageRoute(builder: (_) => const LoginScreen()),
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

String? _validateName(String? value) {
  final fullName = (value ?? '').trim();

  if (fullName.isEmpty) {
    return 'Full name is required';
  }

  if (fullName.length < 2) {
    return 'Full name must be at least 2 characters';
  }

  return null;
}

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

String? _validateConfirm(String? value, String password) {
  final confirmPassword = value ?? '';

  if (confirmPassword.isEmpty) {
    return 'Please confirm your password';
  }

  if (confirmPassword != password) {
    return 'Passwords do not match';
  }

  return null;
}
