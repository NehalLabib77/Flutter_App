/// Sign-in screen — Flask backend email + password (JWT).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import 'auth_chrome.dart';
import 'register_screen.dart';
import 'shell_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _submitting = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
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
      await auth.login(
        email: _emailCtrl.text.trim().toLowerCase(),
        password: _passwordCtrl.text,
      );

      if (!mounted) return;

      // Login succeeded.
      // Remove LoginScreen/RegisterScreen from the route stack
      // and open the main home shell.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const ShellScreen()),
        (route) => false,
      );
    } on ApiException catch (e) {
      _showMessage(e.message);
    } catch (e) {
      _showMessage('Sign in failed. Please try again.');
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
            const SizedBox(height: 20),
            AuthFootnoteLink(
              prefix: "Don't have an account?",
              linkLabel: 'Sign up',
              onTap: _submitting
                  ? () {}
                  : () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const RegisterScreen(),
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
