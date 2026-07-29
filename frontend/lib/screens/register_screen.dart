/// New account creation form: name + email + password + phone, with a
/// phone-OTP second factor that must be verified before the account is
/// created.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../app_state.dart';
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
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();
  bool _submitting = false;
  bool _requestingOtp = false;
  String? _otpReference;
  String? _otpHint;

  @override
  void dispose() {
    _nameCtrl.dispose();
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
            purpose: 'register',
          );
      if (!mounted) return;
      setState(() {
        _otpReference = result.reference;
        _otpHint = result.hint;
      });
      _toast('OTP sent. Check the server console in dev mode.');
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
        purpose: 'register',
      );
      if (!verify.verified) {
        _toast('OTP verification failed. Try again.');
        return;
      }
      final authed = await auth.register(
        fullName: _nameCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        password: _passwordCtrl.text,
        phone: _phoneCtrl.text.trim(),
        otpReference: verify.reference.isNotEmpty
            ? verify.reference
            : (_otpReference ?? ''),
      );
      if (!mounted) return;
      if (authed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account created — you are signed in.')),
        );
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const ShellScreen()),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Account created. Please sign in with the same email and password.'),
          ),
        );
        Navigator.of(context).pop();
      }
    } on ApiException catch (e) {
      _toast(e.message);
    } catch (e) {
      _toast('Sign up failed: $e');
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
      appBar: AppBar(title: const Text('Create your account')),
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
                        Text('Tell us about you',
                            style: theme.textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        Text(
                          'Add a phone number and verify it with a one-time '
                          'code before we create the account.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 24),
                        TextFormField(
                          controller: _nameCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Full name'),
                          validator: (v) =>
                              (v ?? '').trim().isEmpty ? 'Required' : null,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                          enabled: !otpReady,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _emailCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Email'),
                          keyboardType: TextInputType.emailAddress,
                          validator: _validateEmail,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.email],
                          enabled: !otpReady,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _passwordCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Password',
                            helperText: 'At least 8 characters',
                          ),
                          obscureText: true,
                          autofillHints: const [AutofillHints.newPassword],
                          validator: (v) {
                            final s = (v ?? '');
                            if (s.length < 8) {
                              return 'Use at least 8 characters';
                            }
                            return null;
                          },
                          textInputAction: TextInputAction.next,
                          enabled: !otpReady,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: _phoneCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Phone number',
                            helperText:
                                'E.164-ish (8–15 digits, optional +)',
                            prefixText: '+',
                          ),
                          keyboardType: TextInputType.phone,
                          validator: _validatePhone,
                          textInputAction: TextInputAction.done,
                          enabled: !otpReady,
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
                                ? 'Paste the code from the server console.'
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
                          onFieldSubmitted:
                              otpReady ? (_) => _submit() : null,
                        ),
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
                              : const Text('Create account'),
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
  final s = (value ?? '').trim();
  if (s.isEmpty) return 'Required';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s)) {
    return 'Enter a valid email';
  }
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
