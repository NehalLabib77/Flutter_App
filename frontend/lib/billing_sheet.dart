/// Real bKash OTP billing flow: a 3-step bottom sheet that
///   1) collects the user's phone number and chosen plan,
///   2) requests a one-time-password via the backend (`/billing/otp/request`),
///   3) verifies the code (`/billing/otp/verify`) and activates the
///      subscription (`/billing/subscription/activate`).
///
/// All three calls are round-tripped through the JWT-authenticated
/// [ApiClient]. The backend writes a `BillingEvent` audit row and persists the
/// masked subscriber id, provider reference, started/expires timestamps.
///
/// On success the sheet returns `true` so the caller can record the
/// enrollment in [EnrollmentProvider].
library;

import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";

import "api_client.dart";
import "models.dart";
import "package:provider/provider.dart";

/// Shows the real billing bottom sheet for [course]. Returns `true` when the
/// subscription is fully activated, `false` when the user cancels or any
/// step fails.
///
/// The [ApiClient] is resolved from the surrounding [Provider] scope. The
/// optional [client] parameter is for unit tests only.
Future<bool> showBillingSheet(
  BuildContext context, {
  required Course course,
  required String userEmail,
  ApiClient? client,
}) async {
  final api = client ?? context.read<ApiClient>();
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sheetContext) => _BillingSheet(
      course: course,
      userEmail: userEmail,
      client: api,
    ),
  );
  return result ?? false;
}

class _BillingSheet extends StatefulWidget {
  const _BillingSheet({
    required this.course,
    required this.userEmail,
    required this.client,
  });

  final Course course;
  final String userEmail;
  final ApiClient client;

  @override
  State<_BillingSheet> createState() => _BillingSheetState();
}

enum _Step { phone, otp, receipt }

class _BillingSheetState extends State<_BillingSheet> {
  late final ApiClient _client;
  final _phoneCtrl = TextEditingController();
  final _otpCtrl = TextEditingController();

  _Step _step = _Step.phone;
  bool _processing = false;
  String? _error;
  SubscriptionInfo? _receipt;

  // Plan picker state.
  static const _plans = <_PlanOption>[
    _PlanOption(
      code: "monthly",
      title: "Monthly",
      priceLabel: "BDT 299 / month",
      billingNote: "Renews every 30 days",
    ),
    _PlanOption(
      code: "yearly",
      title: "Yearly",
      priceLabel: "BDT 2,499 / year",
      billingNote: "Renews every 365 days. Save 30%.",
    ),
  ];
  _PlanOption _selectedPlan = _plans.first;

  // OTP step state.
  String? _otpReference;
  String _otpHint = "";

  @override
  void initState() {
    super.initState();
    _client = widget.client;
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _otpCtrl.dispose();
    super.dispose();
  }

  bool get _phoneValid => RegExp(r"^\+?[0-9]{8,15}$")
      .hasMatch(_phoneCtrl.text.replaceAll(RegExp(r"\s+"), ""));
  bool get _otpValid => RegExp(r"^[0-9]{4,8}$").hasMatch(_otpCtrl.text.trim());

  Future<void> _requestOtp() async {
    if (!_phoneValid || _processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final res = await _client.requestBillingOtp(
        _phoneCtrl.text.replaceAll(RegExp(r"\s+"), ""),
      );
      if (!mounted) return;
      setState(() {
        _otpReference = res.reference;
        _otpHint = res.hint;
        _step = _Step.otp;
      });
    } on ApiException catch (e) {
      _setError(_humanize(e));
    } catch (_) {
      _setError("Could not start the billing session. Please try again.");
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  Future<void> _verifyAndActivate() async {
    if (!_otpValid || _processing || _otpReference == null) return;
    setState(() {
      _processing = true;
      _error = null;
    });
    try {
      final verified = await _client.verifyBillingOtp(
        _phoneCtrl.text.replaceAll(RegExp(r"\s+"), ""),
        _otpCtrl.text.trim(),
      );
      if (!verified.verified) {
        _setError("That code did not match. Please try again.");
        return;
      }
      final sub = await _client.activateSubscription(
        plan: _selectedPlan.code,
        phone: _phoneCtrl.text.replaceAll(RegExp(r"\s+"), ""),
        providerReference: verified.reference,
      );
      if (!mounted) return;
      setState(() {
        _step = _Step.receipt;
        _receipt = sub;
      });
    } on ApiException catch (e) {
      _setError(_humanize(e));
    } catch (_) {
      _setError("Activation failed. Please try again.");
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  String _humanize(ApiException e) {
    if (e.statusCode == 429) {
      return "Too many attempts. Please wait a minute and try again.";
    }
    if (e.statusCode == 400 || e.statusCode == 422) {
      return e.message.isNotEmpty
          ? e.message
          : "The request was rejected. Please check your details.";
    }
    return "Billing service is temporarily unavailable. Please try again.";
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 4, 20, 20 + viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(theme, scheme),
            const SizedBox(height: 12),
            _courseCard(theme, scheme),
            const SizedBox(height: 16),
            if (_step == _Step.phone) ...[
              _planPicker(theme, scheme),
              const SizedBox(height: 16),
              _phoneForm(theme, scheme),
            ] else if (_step == _Step.otp) ...[
              _otpForm(theme, scheme),
            ] else
              _receiptView(theme, scheme),
          ],
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, ColorScheme scheme) {
    final titles = {
      _Step.phone: "Activate your subscription",
      _Step.otp: "Enter the verification code",
      _Step.receipt: "Subscription active",
    };
    return Row(
      children: [
        Icon(Icons.lock_outline_rounded, color: scheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            titles[_step]!,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bolt_rounded,
                  size: 14, color: scheme.onPrimaryContainer),
              const SizedBox(width: 4),
              Text(
                "bKash",
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _courseCard(ThemeData theme, ColorScheme scheme) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.menu_book_rounded,
                  color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.course.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  if (widget.course.provider != null)
                    Text(
                      widget.course.provider!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Text(
              widget.course.isFree ? "FREE" : r"$0.00",
              style: theme.textTheme.titleMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planPicker(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("Choose a plan",
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ..._plans.map((p) {
          final selected = p.code == _selectedPlan.code;
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _processing
                  ? null
                  : () => setState(() => _selectedPlan = p),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: selected
                        ? scheme.primary
                        : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      selected
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_off_rounded,
                      color: selected ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.title,
                              style: theme.textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                          Text(p.billingNote,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              )),
                        ],
                      ),
                    ),
                    Text(p.priceLabel,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          );
        }),
      ],
    );
  }

  Widget _phoneForm(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          initialValue: widget.userEmail,
          readOnly: true,
          decoration: const InputDecoration(
            labelText: "Account email",
            prefixIcon: Icon(Icons.alternate_email_rounded),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r"[0-9+\s]")),
            LengthLimitingTextInputFormatter(20),
          ],
          decoration: InputDecoration(
            labelText: "bKash-registered phone",
            prefixIcon: const Icon(Icons.phone_iphone_rounded),
            border: const OutlineInputBorder(),
            helperText: "We will send a one-time code to this number.",
            errorText: _phoneCtrl.text.isEmpty || _phoneValid
                ? null
                : "Enter a valid phone number",
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _phoneValid && !_processing ? _requestOtp : null,
          icon: _processing
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded),
          label: Text(_processing
              ? "Sending code\u2026"
              : "Send verification code"),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _processing
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text("Cancel"),
        ),
        const SizedBox(height: 4),
        Text(
          "You will receive a 6-digit code by SMS. Standard SMS rates may apply.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _otpForm(ThemeData theme, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "We sent a code to +${_phoneCtrl.text.replaceAll(RegExp(r"\s+"), "")}.",
          style: theme.textTheme.bodyMedium,
        ),
        if (_otpHint.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(_otpHint,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        const SizedBox(height: 12),
        TextFormField(
          controller: _otpCtrl,
          keyboardType: TextInputType.number,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(8),
          ],
          decoration: InputDecoration(
            labelText: "6-digit code",
            prefixIcon: const Icon(Icons.sms_rounded),
            border: const OutlineInputBorder(),
            errorText: _otpCtrl.text.isEmpty || _otpValid
                ? null
                : "Enter the 4-8 digit code",
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: scheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _otpValid && !_processing ? _verifyAndActivate : null,
          icon: _processing
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.verified_user_rounded),
          label: Text(_processing ? "Activating\u2026" : "Verify & activate"),
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _processing
              ? null
              : () => setState(() {
                    _step = _Step.phone;
                    _otpCtrl.clear();
                    _otpReference = null;
                    _error = null;
                  }),
          child: const Text("Change phone number"),
        ),
      ],
    );
  }

  Widget _receiptView(ThemeData theme, ColorScheme scheme) {
    final sub = _receipt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  color: scheme.onPrimaryContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "${_selectedPlan.title} plan active",
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    if (sub != null && sub.expiresAt != null)
                      Text(
                        "Renews on ${_formatDate(sub.expiresAt!)}",
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (sub != null) ...[
          const SizedBox(height: 12),
          _kvRow(theme, scheme, "Provider", sub.provider.toUpperCase()),
          if (sub.subscriberIdMasked != null)
            _kvRow(theme, scheme, "Subscriber", sub.subscriberIdMasked!),
          if (sub.providerReference != null)
            _kvRow(theme, scheme, "Reference", sub.providerReference!),
        ],
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const Icon(Icons.check_rounded),
          label: const Text("Done"),
        ),
        const SizedBox(height: 4),
        Text(
          "A receipt has been sent to your account email.",
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _kvRow(ThemeData theme, ColorScheme scheme, String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 96,
            child: Text(k,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                )),
          ),
          Expanded(
            child: Text(v, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime d) {
    final l = d.toLocal();
    String two(int n) => n.toString().padLeft(2, "0");
    return "${l.year}-${two(l.month)}-${two(l.day)}";
  }
}

class _PlanOption {
  final String code;
  final String title;
  final String priceLabel;
  final String billingNote;
  const _PlanOption({
    required this.code,
    required this.title,
    required this.priceLabel,
    required this.billingNote,
  });
}
