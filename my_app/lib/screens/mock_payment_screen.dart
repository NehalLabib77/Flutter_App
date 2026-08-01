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

  final List<String> paymentMethods = [
    'bKash',
    'Nagad',
    'Rocket',
    'Card',
  ];

  void sendOtp() {
    final phone = phoneController.text.trim();

    if (phone.length < 11) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid mobile number'),
        ),
      );
      return;
    }

    setState(() {
      otpSent = true;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Verification code sent. Use 123456'),
      ),
    );
  }

  Future<void> completePayment() async {
    if (otpController.text.trim() != _demoOtp) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect verification code'),
        ),
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

    Navigator.pop(
      context,
      {
        'success': true,
        'courseId': widget.courseId,
        'paymentMethod': selectedMethod,
        'transactionId':
            'DEMO-${DateTime.now().millisecondsSinceEpoch}',
      },
    );
  }

  @override
  void dispose() {
    phoneController.dispose();
    otpController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Course Payment'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.courseName,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${widget.currencySymbol}${widget.amount.toStringAsFixed(2)}',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              const Text(
                'Select payment method',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),

              DropdownButtonFormField<String>(
                initialValue: selectedMethod,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                ),
                items: paymentMethods.map((method) {
                  return DropdownMenuItem(
                    value: method,
                    child: Text(method),
                  );
                }).toList(),
                onChanged: processing
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            selectedMethod = value;
                          });
                        }
                      },
              ),
              const SizedBox(height: 16),

              TextField(
                controller: phoneController,
                keyboardType: TextInputType.phone,
                enabled: !otpSent && !processing,
                decoration: const InputDecoration(
                  labelText: 'Mobile number',
                  hintText: '01XXXXXXXXX',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),

              if (!otpSent)
                FilledButton(
                  onPressed: processing ? null : sendOtp,
                  child: const Text('Continue'),
                ),

              if (otpSent) ...[
                TextField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  enabled: !processing,
                  decoration: const InputDecoration(
                    labelText: 'Verification code',
                    hintText: 'Enter 123456',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: processing ? null : completePayment,
                  child: processing
                      ? const SizedBox(
                          height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : Text(
                          'Pay ${widget.currencySymbol}${widget.amount.toStringAsFixed(2)}',
                        ),
                ),
              ],

              const SizedBox(height: 20),
              const Text(
                'Demonstration payment only. No money will be charged.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
