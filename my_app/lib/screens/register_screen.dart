/// Sign-up screen — Flask backend email + password (JWT).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../widgets/custom_text_field.dart';
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
          MaterialPageRoute(
            builder: (_) => const ShellScreen(),
          ),
          (route) => false,
        );
      } else {
        // The account was created, but automatic login failed.
        _showMessage(
          'Account created, but automatic sign-in failed. '
          'Please log in using your new account.',
        );

        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => const LoginScreen(),
          ),
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
      ..showSnackBar(
        SnackBar(content: Text(message)),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create account'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _Header(),
                    const SizedBox(height: 24),

                    CustomTextField(
                      controller: _nameCtrl,
                      label: 'Full name',
                      prefixIcon: Icons.person_outline,
                      autofillHints: const [
                        AutofillHints.name,
                      ],
                      textInputAction: TextInputAction.next,
                      validator: _validateName,
                      enabled: !_submitting,
                    ),

                    const SizedBox(height: 16),

                    CustomTextField(
                      controller: _emailCtrl,
                      label: 'Email',
                      prefixIcon: Icons.email_outlined,
                      autofillHints: const [
                        AutofillHints.newUsername,
                      ],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      validator: _validateEmail,
                      enabled: !_submitting,
                    ),

                    const SizedBox(height: 16),

                    CustomTextField(
                      controller: _passwordCtrl,
                      label: 'Password',
                      prefixIcon: Icons.lock_outline,
                      obscureText: true,
                      autofillHints: const [
                        AutofillHints.newPassword,
                      ],
                      textInputAction: TextInputAction.next,
                      validator: _validatePassword,
                      enabled: !_submitting,
                    ),

                    const SizedBox(height: 16),

                    CustomTextField(
                      controller: _confirmCtrl,
                      label: 'Confirm password',
                      prefixIcon: Icons.lock_outline,
                      obscureText: true,
                      autofillHints: const [
                        AutofillHints.newPassword,
                      ],
                      textInputAction: TextInputAction.done,
                      validator: (value) {
                        return _validateConfirm(
                          value,
                          _passwordCtrl.text,
                        );
                      },
                      onFieldSubmitted: (_) => _submit(),
                      enabled: !_submitting,
                    ),

                    const SizedBox(height: 24),

                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.person_add_alt_1_rounded,
                              ),
                        label: Text(
                          _submitting
                              ? 'Creating account...'
                              : 'Sign up',
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextButton(
                      onPressed: _submitting
                          ? null
                          : () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (_) => const LoginScreen(),
                                ),
                              );
                            },
                      child: const Text(
                        'Already have an account? Log in',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Create your account',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter your details below to create your account.',
          style: theme.textTheme.bodyMedium,
        ),
      ],
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

  final pattern = RegExp(
    r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
  );

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

String? _validateConfirm(
  String? value,
  String password,
) {
  final confirmPassword = value ?? '';

  if (confirmPassword.isEmpty) {
    return 'Please confirm your password';
  }

  if (confirmPassword != password) {
    return 'Passwords do not match';
  }

  return null;
}