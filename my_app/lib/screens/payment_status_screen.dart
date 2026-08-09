library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api_client.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/design.dart';

/// Authoritative payment result screen.
///
/// The deep link only opens the app. Every refresh on this screen calls the
/// JWT-protected backend status endpoint before displaying a final result.
class PaymentStatusScreen extends StatefulWidget {
  const PaymentStatusScreen({
    super.key,
    required this.api,
    required this.initialStatus,
    required this.courseName,
    this.onStatusChanged,
  });

  final ApiClient api;
  final SslCommerzPaymentStatus initialStatus;
  final String courseName;
  final ValueChanged<SslCommerzPaymentStatus>? onStatusChanged;

  @override
  State<PaymentStatusScreen> createState() => _PaymentStatusScreenState();
}

class _PaymentStatusScreenState extends State<PaymentStatusScreen> {
  late SslCommerzPaymentStatus _status;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _status = widget.initialStatus;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final updated = await widget.api.getSslCommerzPaymentStatus(
        _status.transactionId,
      );
      if (!mounted) return;
      setState(() => _status = updated);
      widget.onStatusChanged?.call(updated);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not refresh payment status.');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  String get _title {
    if (_status.isValid) return 'Completed';
    if (_status.isReviewRequired) return 'Under review';
    switch (_status.normalizedStatus) {
      case 'CANCELLED':
        return 'Cancelled';
      case 'FAILED':
        return 'Payment failed';
      case 'VALIDATION_FAILED':
        return 'Validation failed';
      default:
        return 'Processing payment';
    }
  }

  String get _message {
    if (_status.isValid) {
      return 'The transaction was verified and your course enrollment is ready.';
    }
    if (_status.isReviewRequired) {
      return 'The payment was received but requires a security review before enrollment.';
    }
    switch (_status.normalizedStatus) {
      case 'CANCELLED':
        return 'The checkout was cancelled. No course access was granted.';
      case 'FAILED':
        return 'The payment was not completed. You can return and try again.';
      case 'VALIDATION_FAILED':
        return 'The gateway response did not pass secure server validation.';
      default:
        return 'We are waiting for confirmation from SSLCOMMERZ. Refresh in a moment.';
    }
  }

  IconData get _icon {
    if (_status.isValid) return Icons.verified_rounded;
    if (_status.isReviewRequired) return Icons.manage_search_rounded;
    if (_status.isFailure) return Icons.error_rounded;
    return Icons.hourglass_top_rounded;
  }

  Color _accent(ColorScheme scheme) {
    if (_status.isValid) return AppColors.success;
    if (_status.isReviewRequired) return scheme.tertiary;
    if (_status.isFailure) return scheme.error;
    return scheme.primary;
  }

  String get _amount {
    final amount = _status.amount;
    if (amount == null) return 'Not available';
    return '${_status.currency ?? 'BDT'} ${amount.toStringAsFixed(2)}';
  }

  String get _method {
    final value = _status.cardType ?? _status.paymentMethod;
    return (value == null || value.trim().isEmpty) ? 'SSLCOMMERZ' : value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = _accent(scheme);

    return Scaffold(
      appBar: AppBar(title: const Text('Payment status')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
          child: ResponsiveContent(
            maxWidth: 720,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.xl,
                  vertical: Spacing.xxl,
                ),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.08),
                  border: Border.all(color: accent.withValues(alpha: 0.55)),
                  borderRadius: BorderRadius.circular(Radii.xl),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(_icon, size: 44, color: accent),
                    ),
                    const SizedBox(height: Spacing.lg),
                    Text(
                      _title,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: Spacing.sm),
                    Text(
                      _message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              EduCard(
                border: true,
                child: Column(
                  children: [
                    _DetailRow(label: 'Course', value: widget.courseName),
                    const Divider(height: Spacing.xl),
                    _DetailRow(
                      label: 'Transaction ID',
                      value: _status.transactionId,
                      copyable: true,
                    ),
                    const Divider(height: Spacing.xl),
                    _DetailRow(label: 'Amount', value: _amount),
                    const Divider(height: Spacing.xl),
                    _DetailRow(label: 'Method', value: _method),
                    if ((_status.bankTransactionId ?? '').isNotEmpty) ...[
                      const Divider(height: Spacing.xl),
                      _DetailRow(
                        label: 'Bank transaction',
                        value: _status.bankTransactionId!,
                        copyable: true,
                      ),
                    ],
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: Spacing.lg),
              if (_status.isValid)
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Continue to course'),
                )
              else ...[
                OutlinedButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(
                    _refreshing ? 'Checking status…' : 'Refresh status',
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(
                    _status.isPending || _status.isReviewRequired
                        ? 'Return to course'
                        : 'Back to retry',
                  ),
                ),
              ],
            ],
          ),
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.copyable = false,
  });

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 380;
        final labelWidget = Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        );
        final valueWidget = Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        );
        final copyButton = copyable
            ? IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Copy',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard.')),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
              )
            : null;
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelWidget,
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(child: valueWidget),
                  if (copyButton != null) copyButton,
                ],
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 118, child: labelWidget),
            Expanded(child: valueWidget),
            if (copyButton != null) copyButton,
          ],
        );
      },
    );
  }
}
