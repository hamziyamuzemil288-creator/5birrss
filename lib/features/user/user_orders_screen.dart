import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/resilience/failure_mapper.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/async_view.dart';
import '../../core/utils/order_number_format.dart';
import 'pending_availability_section.dart';

class UserOrdersScreen extends StatefulWidget {
  const UserOrdersScreen({super.key});
  @override
  State<UserOrdersScreen> createState() => _UserOrdersScreenState();
}

class _UserOrdersScreenState extends State<UserOrdersScreen> {
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      // A signed-out user is not an error and not an empty list: it is a
      // signed-out screen, and saying "no orders yet" there would be a lie.
      // Returning empty lets the empty state render; the router sends an
      // unauthenticated visitor to /login before this is ever shown.
      if (userId == null) return const [];
      // Buyer orders only. The orders RLS also exposes orders sold by the
      // signed-in user's business (owns_provider_profile) so providers can
      // manage sales from /provider/orders — without this filter a provider
      // browsing as a buyer would see their sales mixed into this list.
      final data = await Supabase.instance.client
          .from('orders')
          .select('*, provider_profiles(business_name)')
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      // Typed and classified here rather than stringified at the call site,
      // so the user reads a sentence and the log keeps the real cause.
      throw AppFailureMapper.map(e, context: 'loading your orders');
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'PENDING':
        return AppTheme.warning;
      case 'CONFIRMED':
      case 'IN_PROGRESS':
        return AppTheme.info;
      case 'COMPLETED':
        return AppTheme.success;
      case 'CANCELLED':
      case 'REJECTED':
        return AppTheme.error;
      default:
        return AppTheme.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Orders')),
      // AsyncView owns all three states. The important behaviour change is
      // not visual: on a failed REFRESH it keeps the last good list on screen
      // and puts a quiet "couldn't refresh" strip above it, where the old
      // code replaced the list with a full-screen error. Pull-to-refresh on a
      // weak connection used to throw away a user's order history.
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: AsyncListView<Map<String, dynamic>>(
          loader: _load,
          errorContext: 'loading your orders',
          itemBuilder: (_, o, __) {
            final status = (o['status'] ?? '').toString();
            final color = _statusColor(status);
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => context.push('/user/orders/${o['id']}'),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            _orderIcon(status),
                            color: color,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                o['provider_profiles']?['business_name'] ??
                                    'Order',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${orderLabel(o)} · '
                                '${o['total_amount']} ${o['currency'] ?? 'ETB'}',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            status,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: color),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
          // Part 9b: an availability request that is WAITING is not an order
          // yet, so it has no row in this list — but it is the thing the buyer
          // is waiting on, and Orders is where they go to check. It reads the
          // live row (realtime + poll), so it is correct after an app
          // minimise, a navigation away, or a fresh cold start.
          header: const PendingAvailabilitySection(),
          emptyBuilder: (context) => _buildEmptyState(),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A buyer with a pending request and no orders yet is the common
            // case, not the edge one: the request is made BEFORE the order
            // exists. Empty means "no orders", not "nothing to see".
            const PendingAvailabilitySection(),
            // Decorative icon with animated ring
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.primaryGreen.withOpacity(0.12),
                  width: 2,
                ),
              ),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.06),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.receipt_long_outlined,
                    color: AppTheme.primaryGreen, size: 36),
              ),
            ),
            const SizedBox(height: 24),
            const Text('No orders yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Text(
              'When you place an order from a shop\nor provider, it will appear here',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppTheme.textMuted.withOpacity(0.8)),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: () => context.push('/user/search'),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('Explore Products'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
      ),
    );
  }


  IconData _orderIcon(String status) {
    switch (status) {
      case 'PENDING':
        return Icons.schedule;
      case 'CONFIRMED':
      case 'IN_PROGRESS':
        return Icons.autorenew;
      case 'COMPLETED':
        return Icons.check_circle_outline;
      case 'CANCELLED':
      case 'REJECTED':
        return Icons.cancel_outlined;
      default:
        return Icons.receipt_outlined;
    }
  }
}
