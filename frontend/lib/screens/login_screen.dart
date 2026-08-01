/// Email + password sign-in screen with a phone-OTP second factor.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
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
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _submitting = false;
  bool _requestingOtp = false;
  String? _otpReference;
  String? _otpHint;
  String _otpDevCode = '';

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  Future<void> _requestOtp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _requestingOtp = true);
    try {
      final result = await context.read<ApiClient>().requestAuthOtp(
            phone: _phoneCtrl.text.trim(),
            purpose: 'login',
            email: _emailCtrl.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _otpReference = result.reference;
        _otpHint = result.hint;
        _otpDevCode = result.devCode;
        if (result.devCode.isNotEmpty) {
          _otpCtrl.text = result.devCode;
        }
      });
      _toast(
        result.devCode.isNotEmpty
            ? 'Code received: ${result.devCode}'
            : 'OTP sent. Check the server console in dev mode.',
      );
    } on ApiException catch (e) {
      _toast('OTP request failed: ${e.message}');
    } catch (e) {
      _toast('OTP request failed: $e');
    } finally {
      if (mounted) setState(() => _requestingOtp = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final api = context.read<ApiClient>();
    final auth = context.read<AuthProvider>();
    setState(() => _submitting = true);
    try {
      final verify = await api.verifyAuthOtp(
        phone: _phoneCtrl.text.trim(),
        code: _otpCtrl.text.trim(),
        purpose: 'login',
      );
      if (!verify.verified) {
        _toast('OTP verification failed. Try again.');
        return;
      }
      await auth.login(
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        phone: _phoneCtrl.text.trim(),
        otpReference: verify.reference.isNotEmpty
            ? verify.reference
            : (_otpReference ?? ''),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ShellScreen()),
      );
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Sign in failed: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final otpReady = _otpReference != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome back')),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                24,
                24,
                24,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('Sign in',
                            style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        Text(
                          'Enter your credentials and the phone number on '
                          'file. We\'ll send a one-time code to verify it\'s you.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _emailCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Email'),
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          validator: _validateEmail,
                          textInputAction: TextInputAction.next,
                          enabled: !otpReady,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            helperText: 'At least 6 characters',
                          ),
                          obscureText: true,
                          autofillHints: const [AutofillHints.password],
                          validator: _validatePassword,
                          textInputAction: TextInputAction.next,
                          enabled: !otpReady,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _phoneCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Phone number',
                            helperText:
                                'Must match the phone on your account',
                            prefixText: '+',
                          ),
                          keyboardType: TextInputType.phone,
                          enabled: !otpReady,
                          validator: _validatePhone,
                          textInputAction: TextInputAction.done,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          onPressed: (_requestingOtp || otpReady)
                              ? null
                              : _requestOtp,
                          icon: _requestingOtp
                              ? const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Icon(Icons.sms_outlined),
                          label: Text(
                              otpReady ? 'Code sent' : 'Send OTP code'),
                        ),
                        if ((_otpHint ?? '').isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            _otpHint!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        Text('OTP code',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        TextFormField(
                          controller: _otpCtrl,
                          decoration: InputDecoration(
                            labelText: 'Enter the 6-digit code',
                            helperText: otpReady
                                ? (_otpDevCode.isNotEmpty
                                    ? 'Dev mode — auto-filled below.'
                                    : 'Paste the code from the server console.')
                                : 'Tap "Send OTP code" above first.',
                          ),
                          keyboardType: TextInputType.number,
                          enabled: otpReady,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(6),
                          ],
                          validator: (v) {
                            if (!otpReady) return null;
                            final s = (v ?? '').trim();
                            if (s.length < 4) return 'Enter the code';
                            return null;
                          },
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: otpReady ? (_) => _submit() : null,
                        ),
                        if (otpReady && _otpDevCode.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Dev code: $_otpDevCode',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: (!otpReady || _submitting)
                              ? null
                              : _submit,
                          child: _submitting
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                )
                              : const Text('Sign in'),
                        ),
                        if (otpReady) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _requestingOtp
                                ? null
                                : () {
                                    setState(() {
                                      _otpReference = null;
                                      _otpHint = null;
                                      _otpCtrl.clear();
                                    });
                                  },
                            child: const Text('Use a different phone'),
                          ),
                        ],
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const RegisterScreen()),
                          ),
                          child: const Text('Create an account'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

String? _validateEmail(String? value) {
  final v = (value ?? '').trim();
  if (v.isEmpty) return 'Email is required';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
    return 'Enter a valid email';
  }
  return null;
}

String? _validatePassword(String? value) {
  if ((value ?? '').length < 6) return 'At least 6 characters';
  return null;
}

String? _validatePhone(String? value) {
  final v = (value ?? '').replaceAll(RegExp(r'\s+'), '');
  if (v.isEmpty) return 'Phone is required';
  if (!RegExp(r'^\+?[0-9]{8,15}$').hasMatch(v)) {
    return 'Enter 8–15 digits, optional leading +';
  }
  return null;
}
