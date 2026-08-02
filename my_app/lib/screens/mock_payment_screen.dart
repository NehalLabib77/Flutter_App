/// Full-screen mock payment for the demo build.
///
/// The flow is intentionally fake:
///   1. Pick a method (bKash / Nagad / Rocket / Card).
///   2. Type a mobile number (any 11+ digits).
///   3. Tap Continue — the screen "sends" a verification code and reveals
///      the OTP field. The code is **always** `123456`.
///   4. Tap Pay — after a 2 second fake processing delay the screen pops
///      with `{success: true, courseId, paymentMethod, transactionId}`.
///
/// No real gateway credentials are needed; nothing leaves the device.
/// Replace this file (and the `EnrollmentService` Firestore write) with a
/// real bKash / SSLCommerz integration when productionising.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/design.dart';

class MockPaymentScreen extends StatefulWidget {
  const MockPaymentScreen({
    super.key,
    required this.courseId,
    required this.courseName,
    required this.amount,
    this.currencySymbol = '৳',
  });

  final String courseId;
  final String courseName;
  final double amount;
  final String currencySymbol;

  @override
  State<MockPaymentScreen> createState() => _MockPaymentScreenState();
}

class _MockPaymentScreenState extends State<MockPaymentScreen> {
  static const String _demoOtp = '123456';

  final TextEditingController phoneController = TextEditingController();
  final TextEditingController otpController = TextEditingController();

  String selectedMethod = 'bKash';
  bool otpSent = false;
  bool processing = false;

  final List<String> paymentMethods = ['bKash', 'Nagad', 'Rocket', 'Card'];

  void sendOtp() {
    final phone = phoneController.text.trim();

    if (phone.length < 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid mobile number')),
      );
      return;
    }

    setState(() {
      otpSent = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Verification code sent. Use 123456')),
    );
  }

  Future<void> completePayment() async {
    if (otpController.text.trim() != _demoOtp) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Incorrect verification code')),
      );
      return;
    }

    setState(() {
      processing = true;
    });

    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    setState(() {
      processing = false;
    });

    Navigator.pop(context, {
      'success': true,
      'courseId': widget.courseId,
      'paymentMethod': selectedMethod,
      'transactionId': 'DEMO-${DateTime.now().millisecondsSinceEpoch}',
    });
  }

  @override
  void dispose() {
    phoneController.dispose();
    otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Three-step progress: method chosen → verify code → pay.
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final step = otpSent
        ? 2
        : 1; // 1=Method, 2=Verify, 3=Pay (reached when paying)
    final formattedAmount =
        '${widget.currencySymbol}${widget.amount.toStringAsFixed(2)}';

    return Scaffold(
      appBar: AppBar(title: const Text('Course Payment')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroBanner(
                eyebrow: 'PAYMENT',
                title: widget.courseName,
                subtitle: 'Total due $formattedAmount',
                icon: Icons.receipt_long_rounded,
              ),
              const SizedBox(height: Spacing.lg),
              _StepIndicator(current: step),
              const SizedBox(height: Spacing.lg),
              EduCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Select payment method',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      'Pick how you want to pay — you can change this later.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    Wrap(
                      spacing: Spacing.sm,
                      runSpacing: Spacing.sm,
                      children: [
                        for (final method in paymentMethods)
                          _MethodChip(
                            label: method,
                            icon: _iconForMethod(method),
                            selected: selectedMethod == method,
                            enabled: !processing,
                            onTap: () => setState(() {
                              selectedMethod = method;
                            }),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              EduCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      otpSent ? 'Verification code' : 'Mobile number',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: Spacing.xs),
                    Text(
                      otpSent
                          ? 'Enter the 6-digit code we sent to your phone.'
                          : 'We will send a verification code to this number.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Spacing.md),
                    if (!otpSent) ...[
                      TextField(
                        controller: phoneController,
                        keyboardType: TextInputType.phone,
                        enabled: !processing,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(14),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Mobile number',
                          hintText: '01XXXXXXXXX',
                          prefixIcon: Icon(Icons.phone_iphone_rounded),
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: Spacing.md),
                      FilledButton.icon(
                        onPressed: processing ? null : sendOtp,
                        icon: const Icon(Icons.send_rounded),
                        label: const Text('Send verification code'),
                      ),
                    ] else ...[
                      TextField(
                        controller: otpController,
                        keyboardType: TextInputType.number,
                        enabled: !processing,
                        maxLength: 6,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Verification code',
                          hintText: 'Enter 123456',
                          prefixIcon: Icon(Icons.lock_open_rounded),
                          border: OutlineInputBorder(),
                          counterText: '',
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: processing
                              ? null
                              : () {
                                  phoneController.clear();
                                  otpController.clear();
                                  setState(() => otpSent = false);
                                },
                          icon: const Icon(Icons.edit_rounded, size: 16),
                          label: const Text('Change number'),
                        ),
                      ),
                      const SizedBox(height: Spacing.sm),
                      FilledButton.icon(
                        onPressed: processing ? null : completePayment,
                        icon: processing
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.lock_rounded),
                        label: Text(
                          processing ? 'Processing…' : 'Pay $formattedAmount',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Text(
                    'Demonstration payment only. No money will be charged.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForMethod(String method) {
    switch (method) {
      case 'bKash':
        return Icons.account_balance_wallet_rounded;
      case 'Nagad':
        return Icons.savings_rounded;
      case 'Rocket':
        return Icons.rocket_launch_rounded;
      case 'Card':
      default:
        return Icons.credit_card_rounded;
    }
  }
}

/// Three-step progress strip: Method → Verify → Pay.
class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const steps = ['Method', 'Verify', 'Pay'];
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 6,
                  decoration: BoxDecoration(
                    color: i < current
                        ? scheme.primary
                        : i == current
                        ? scheme.primary
                        : scheme.outlineVariant,
                    borderRadius: const BorderRadius.all(Radius.circular(3)),
                  ),
                ),
                const SizedBox(height: Spacing.xs),
                Text(
                  steps[i],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: i <= current
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                    fontWeight: i == current
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (i != steps.length - 1) const SizedBox(width: Spacing.xs),
        ],
      ],
    );
  }
}

/// Pill-styled method chip that uses the same vocabulary as the rest of
/// the app but supports `selected` / `onTap` semantics.
class _MethodChip extends StatelessWidget {
  const _MethodChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.enabled,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = selected ? scheme.primary : scheme.onSurfaceVariant;
    final bg = selected
        ? scheme.primary.withValues(alpha: 0.14)
        : scheme.surfaceContainerHighest;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.sm,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(
                color: selected
                    ? scheme.primary.withValues(alpha: 0.6)
                    : scheme.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: Spacing.xs),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  ),
                ),
                if (selected) ...[
                  const SizedBox(width: Spacing.xs),
                  Icon(Icons.check_circle_rounded, size: 16, color: accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
