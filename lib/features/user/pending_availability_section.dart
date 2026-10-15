import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/error_logger.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/theme/app_theme.dart';

/// The buyer's availability requests, shown in Orders.
///
/// ## Why this exists (Part 9b)
///
/// The waiting screen is a *view* of a database row, and the row is what
/// decides: `create_availability_requests` resumes an existing PENDING request
/// rather than inserting a second one, so closing the screen, minimising the
/// app or navigating away loses nothing. What was missing was a way to CHECK
/// from somewhere the buyer actually goes — a request could be pending while
/// the buyer had no way to see it without re-entering the specific flow.
///
/// So this is the same question asked in a second place, answered the same way:
/// a live read of `availability_requests` (realtime, with an unhurried poll as
/// the fallback), rendered as a list item with the status word from the ROW —
/// "Waiting for provider confirmation", "Available", "Not available" — never
/// from a local timer.
///
/// Nothing in memory outlives the widget on purpose: the countdown belongs to
/// the waiting screen, where 15 minutes of seconds matter. Here the question is
/// only ever "what does the row say now", which is exactly the property that
/// makes the request survive an app minimise.
class PendingAvailabilitySection extends StatefulWidget {
  const PendingAvailabilitySection({super.key});

  @override
  State<PendingAvailabilitySection> createState() =>
      _PendingAvailabilitySectionState();
}

class _PendingAvailabilitySectionState extends State<PendingAvailabilitySection> {
  List<Map<String, dynamic>> _rows = const [];
  ResilientSubscription<List<Map<String, dynamic>>>? _live;
  Timer? _poll;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _refresh();
    _subscribe();
    // The realtime socket is the fast path. This poll is the fallback for a
    // connection that is down, so an answered request never sits unnoticed
    // behind a dead socket — the same two-layer design the waiting screen
    // uses.
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _live?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return;
    try {
      // Only asks over a window that can still be acted on: a request is
      // 15 minutes long, so a day of history is enough to still show an
      // answer from earlier today without turning this into an archive.
      final since = DateTime.now().toUtc().subtract(const Duration(days: 1));
      final data = await _client
          .from('availability_requests')
          .select('id, product_id, provider_id, quantity, status, reason, '
              'created_at, expires_at, responded_at, products(name, currency)')
          .eq('buyer_id', uid)
          .gte('created_at', since.toIso8601String())
          .order('created_at', ascending: false)
          .limit(20);
      if (!mounted) return;
      setState(() =>
          _rows = List<Map<String, dynamic>>.from(data as List));
    } catch (e) {
      // A database that has not run 20261006000006 has no such table: the
      // section renders nothing rather than an error, exactly as the waiting
      // screen degrades. Logged, so a real failure is not invisible.
      ErrorLogger.instance.logError(
        e,
        null,
        source: 'availability-orders-section',
        context: 'PendingAvailabilitySection._refresh',
      );
    }
  }

  void _subscribe() {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return;
    _live = ResilientSubscription<List<Map<String, dynamic>>>(
      stream: _client
          .from('availability_requests')
          .stream(primaryKey: ['id'])
          .eq('buyer_id', uid),
      onData: (_) => _refresh(),
      onState: (_) {},
    );
  }

  /// What the row says. PENDING is spelled out as the wait it is, because
  /// "PENDING" on an order list reads like the buyer has something to do.
  ({String label, Color color, IconData icon}) _statusOf(String status) {
    switch (status) {
      case 'PENDING':
        return (
          label: 'Waiting for provider confirmation',
          color: AppTheme.warning,
          icon: Icons.hourglass_top,
        );
      case 'ACCEPTED':
        return (
          label: 'Available — finish your order',
          color: AppTheme.success,
          icon: Icons.check_circle_outline,
        );
      case 'REJECTED':
        return (
          label: 'Not available',
          color: AppTheme.error,
          icon: Icons.cancel_outlined,
        );
      case 'EXPIRED':
        return (
          label: 'No answer — the request expired',
          color: AppTheme.textMuted,
          icon: Icons.timer_off_outlined,
        );
      case 'CANCELLED':
        return (
          label: 'Cancelled',
          color: AppTheme.textMuted,
          icon: Icons.block_outlined,
        );
      default:
        return (
          label: status,
          color: AppTheme.textMuted,
          icon: Icons.help_outline,
        );
    }
  }

  /// A request that is still actionable (or worth reading) beats one that
  /// expired yesterday: PENDING and ACCEPTED first, then the rest.
  int _rank(String status) => switch (status) {
        'PENDING' => 0,
        'ACCEPTED' => 1,
        'REJECTED' => 2,
        'EXPIRED' => 3,
        'CANCELLED' => 4,
        _ => 5,
      };

  @override
  Widget build(BuildContext context) {
    final visible = _rows.where((r) {
      final status = r['status'] as String?;
      // An expired/cancelled request from hours ago is noise. The live ones
      // and the day's answers are what is worth a row.
      return status == 'PENDING' ||
          status == 'ACCEPTED' ||
          status == 'REJECTED';
    }).toList()
      ..sort((a, b) => _rank(a['status'] as String? ?? '')
          .compareTo(_rank(b['status'] as String? ?? '')));

    if (visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text('Availability requests',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
          ),
          for (final r in visible) _card(r),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final status = r['status'] as String? ?? '';
    final meta = _statusOf(status);
    final product = r['products'] as Map<String, dynamic>?;
    final name = (product?['name'] as String?) ?? 'A listing';
    final currency = (product?['currency'] as String?) ?? 'ETB';
    final quantity = r['quantity'];
    final reason = r['reason'] as String?;
    final accepted = status == 'ACCEPTED';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder, width: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          // An accepted request leads back into the flow that can finish it;
          // anything else opens the listing so the buyer can act on the answer.
          onTap: () {
            if (accepted) {
              context.push('/user/availability',
                  extra: {'providerId': r['provider_id']});
            } else {
              context.push('/user/product/${r['product_id']}');
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: meta.color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(meta.icon, color: meta.color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        quantity == null
                            ? meta.label
                            : '${_fmtQty(quantity)} · ${meta.label}',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                      if (status == 'REJECTED' &&
                          reason != null &&
                          reason.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text('Provider said: $reason',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5,
                                height: 1.3,
                                color: AppTheme.textMuted)),
                      ],
                      if (accepted) ...[
                        const SizedBox(height: 2),
                        Text(
                          'You can order this now — the confirmation is held '
                          'for you.',
                          style: TextStyle(
                              fontSize: 11.5,
                              height: 1.3,
                              color: AppTheme.success.withOpacity(0.9)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text('$currency',
                    style: const TextStyle(
                        fontSize: 11, color: AppTheme.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whole quantities print without a trailing ".0" — a request for 2 units
  /// should not read "2.0", while a request for 1.5 kg should keep the half.
  static String _fmtQty(dynamic v) {
    final n = (v as num?)?.toDouble() ?? 0;
    return n == n.roundToDouble()
        ? n.toInt().toString()
        : n.toStringAsFixed(2);
  }
}
