import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_client.dart';
import '../course_image.dart';
import '../models.dart';
import '../widgets/design.dart';
import 'course_details_screen.dart';

/// Enrollment/order history backed by the existing payment + enrollment rows.
class OrderHistoryScreen extends StatefulWidget {
  const OrderHistoryScreen({super.key});

  @override
  State<OrderHistoryScreen> createState() => _OrderHistoryScreenState();
}

class _OrderHistoryScreenState extends State<OrderHistoryScreen> {
  bool _loading = true;
  String? _error;
  List<OrderHistoryItem> _orders = const [];

  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final orders = await context.read<ApiClient>().orderHistory();
      if (!mounted) return;
      setState(() => _orders = orders);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _error = context.read<ApiClient>().describeNetworkError(e),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order history')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(
            top: Spacing.md,
            bottom: Spacing.xxl,
          ),
          children: [
            const ResponsiveContent(
              maxWidth: 900,
              child: HeroBanner(
              eyebrow: 'ENROLLMENTS',
              title: 'Your course orders',
              subtitle:
                  'Payment and enrollment details for courses you joined.',
              icon: Icons.receipt_long_rounded,
            ),
            ),
            const SizedBox(height: Spacing.lg),
            if (_loading && _orders.isEmpty)
              const ResponsiveContent(
                maxWidth: 900,
                child: LoadingState(message: 'Loading order history…'),
              )
            else if (_error != null && _orders.isEmpty)
              ResponsiveContent(
                maxWidth: 720,
                child: EmptyState(
                icon: Icons.cloud_off_rounded,
                message: _error!,
                action: FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ),
              )
            else if (_orders.isEmpty)
              const ResponsiveContent(
                maxWidth: 720,
                child: EmptyState(
                icon: Icons.shopping_bag_outlined,
                message:
                    'No enrolled-course orders yet. Your completed enrollments will appear here.',
              ),
              )
            else ...[
              for (final order in _orders) ...[
                ResponsiveContent(
                  maxWidth: 900,
                  child: _OrderCard(order: order),
                ),
                const SizedBox(height: Spacing.md),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({required this.order});

  final OrderHistoryItem order;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final course = order.course;
    final title = course?.name.trim().isNotEmpty == true
        ? course!.name
        : 'Course ${order.courseId}';
    final status = order.paymentStatus.trim().isEmpty
        ? 'completed'
        : order.paymentStatus.trim();
    final success = order.enrollmentCompleted ||
        status.toUpperCase() == 'VALIDATED' ||
        status.toLowerCase() == 'completed';

    return EduCard(
      border: true,
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (course != null) CourseThumbnail(course: course, size: 72),
              if (course != null) const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (course?.provider?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: 2),
                      Text(
                        course!.provider!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: Spacing.sm),
                    _StatusChip(label: status, success: success),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          _DetailRow(
            icon: Icons.payments_outlined,
            label: 'Amount',
            value: _amountLabel(order),
          ),
          _DetailRow(
            icon: Icons.credit_card_rounded,
            label: 'Payment method',
            value: _paymentMethod(order),
          ),
          _DetailRow(
            icon: Icons.confirmation_number_outlined,
            label: 'Transaction ID',
            value: order.transactionId.isEmpty ? 'Not available' : order.transactionId,
          ),
          if (order.bankTransactionId?.trim().isNotEmpty == true)
            _DetailRow(
              icon: Icons.account_balance_outlined,
              label: 'Bank transaction',
              value: order.bankTransactionId!,
            ),
          _DetailRow(
            icon: Icons.event_available_outlined,
            label: 'Enrolled',
            value: _formatDate(order.enrolledAt ?? order.updatedAt),
          ),
          _DetailRow(
            icon: Icons.school_outlined,
            label: 'Enrollment',
            value: order.enrollmentCompleted ? 'Completed' : 'Pending',
          ),
          if (course != null) ...[
            const SizedBox(height: Spacing.md),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CourseDetailsScreen(courseId: order.courseId),
                    ),
                  );
                },
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('View course'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _amountLabel(OrderHistoryItem order) {
    final amount = order.amount?.trim();
    if (amount == null || amount.isEmpty) return 'Not recorded';
    final parsed = double.tryParse(amount);
    if (parsed != null && parsed == 0) return 'Free';
    return '${order.currency} $amount';
  }

  static String _paymentMethod(OrderHistoryItem order) {
    final card = order.cardType?.trim();
    if (card != null && card.isNotEmpty) return card;
    final method = order.paymentMethod.trim();
    return method.isEmpty ? 'EduCompass' : method;
  }

  static String _formatDate(DateTime? value) {
    if (value == null) return 'Not recorded';
    final local = value.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final amPm = local.hour >= 12 ? 'PM' : 'AM';
    return '${local.day} ${months[local.month - 1]} ${local.year}, '
        '$hour:$minute $amPm';
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.success});

  final String label;
  final bool success;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = success
        ? scheme.secondaryContainer
        : scheme.tertiaryContainer;
    final foreground = success
        ? scheme.onSecondaryContainer
        : scheme.onTertiaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.replaceAll('_', ' ').toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 360;
          final labelWidget = Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          );
          final valueWidget = Text(
            value,
            textAlign: compact ? TextAlign.left : TextAlign.right,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          );
          if (compact) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: scheme.primary),
                const SizedBox(width: Spacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [labelWidget, const SizedBox(height: 2), valueWidget],
                  ),
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: Spacing.sm),
              SizedBox(width: 116, child: labelWidget),
              const SizedBox(width: Spacing.xs),
              Expanded(child: valueWidget),
            ],
          );
        },
      ),
    );
  }
}
