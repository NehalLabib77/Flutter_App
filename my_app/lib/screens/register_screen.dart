/// Sign-up screen — Flask backend email + password (JWT).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import 'auth_chrome.dart';
import 'login_screen.dart';
import 'shell_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

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

    final auth = context.read<AuthProvider>();

    try {
      final bool ok = await auth.register(
        fullName: _nameCtrl.text.trim(),
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );

      if (!mounted) return;

      if (ok) {
        // Registration and automatic login succeeded.
        // Clear all authentication pages and open the home shell.
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const ShellScreen()),
          (route) => false,
        );
      } else {
        // The account was created, but automatic login failed.
        _showMessage(
          'Account created, but automatic sign-in failed. '
          'Please log in using your new account.',
        );

        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    } on ApiException catch (e) {
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
              body: 'Enter your details below to create your account.',
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
