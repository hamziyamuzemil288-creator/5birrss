import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/active_order_store.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/primary_button.dart';

/// The buyer's live waiting room after a checkout request is submitted.
///
/// It is driven by the order row itself: an admin decision flips `status` from
/// AWAITING_APPROVAL to APPROVED (or REJECTED), and the Realtime subscription
/// moves this screen without a poll that could miss the moment. The 10-second
/// read underneath is a reconnect fallback for a dead socket, not the primary
/// path.
///
/// It survives an app restart: the order id is stored on the device
/// (ActiveOrderStore) and the dashboard reopens this screen. It also survives
/// the app being backgrounded, because nothing here depends on an in-memory
/// timer.
class CheckoutWaitingScreen extends StatefulWidget {
  const CheckoutWaitingScreen({super.key, required this.orderId});

  final String orderId;

  @override
  State<CheckoutWaitingScreen> createState() => _CheckoutWaitingScreenState();
}

class _CheckoutWaitingScreenState extends State<CheckoutWaitingScreen> {
  Map<String, dynamic>? _order;
  String? _error;
  String _status = 'AWAITING_APPROVAL';
  bool _loading = true;
  bool _cancelling = false;
  bool _movingToMap = false;

  ResilientSubscription<List<Map<String, dynamic>>>? _subscription;
  Timer? _fallback;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    ActiveOrderStore.save(widget.orderId);
    _load();
    _subscribe();
    _fallback = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _fallback?.cancel();
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final row = await _client
          .from('orders')
          .select('id, order_number, status, total_amount, currency, '
              'delivery_address, buyer_name, checkout_rejection_reason, '
              'provider_id, delivery_driver_provider_id')
          .eq('id', widget.orderId)
          .maybeSingle();
      if (!mounted) return;
      if (row == null) {
        if (!silent) {
          setState(() {
            _loading = false;
            _error = 'This order could not be found.';
          });
        }
        return;
      }
      setState(() {
        _order = Map<String, dynamic>.from(row);
        _status = (row['status'] as String?) ?? 'AWAITING_APPROVAL';
        _loading = false;
        _error = null;
      });
      _reactToStatus(_status);
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your order');
        });
      }
    }
  }

  /// Realtime first. Replacing the subscription on every rebuild would leak
  /// channels, so it is attached exactly once with the order's own row as the
  /// primary key.
  void _subscribe() {
    _subscription = ResilientSubscription<List<Map<String, dynamic>>>(
      stream: _client
          .from('orders')
          .stream(primaryKey: ['id'])
          .eq('id', widget.orderId),
      onData: (rows) {
        if (!mounted || rows.isEmpty) return;
        final row = rows.first;
        setState(() {
          _order = Map<String, dynamic>.from(row);
          _status = (row['status'] as String?) ?? _status;
          _loading = false;
        });
        _reactToStatus(_status);
      },
      onState: (_) {},
    );
  }

  /// The one place the screen moves itself.
  ///
  /// APPROVED means the admin approved the request and assigned the vehicle and
  /// driver, so the buyer's next screen is the live map. REJECTED and
  /// CANCELLED close the request and stay here with the reason.
  void _reactToStatus(String status) {
    if (!mounted) return;
    if (status == 'APPROVED' || status == 'STARTED' || status == 'COMPLETED') {
      if (_movingToMap) return;
      _movingToMap = true;
      // The stored order id is deliberately KEPT: an approval is not the end
      // of the journey. If the app is killed on the map, reopening it has to
      // return the guest to that map, not to a dashboard with no way back.
      // The tracking screen clears it once the order is complete/cancelled.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.go('/user/orders/${widget.orderId}/delivery');
        }
      });
      return;
    }
    if (status == 'REJECTED' || status == 'CANCELLED') {
      ActiveOrderStore.clear();
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this request?'),
        content: const Text(
          'The administration has not decided yet. Cancelling closes the '
          'request and you can start a new checkout at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('KEEP WAITING'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('CANCEL REQUEST'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _cancelling = true);
    try {
      // The status change is a server write; a direct RPC is refused by the
      // order guard. The endpoint verifies this buyer and calls the RPC.
      await _client.functions.invoke(
        'checkout-cancel',
        body: {'order_id': widget.orderId},
      );
      await ActiveOrderStore.clear();
      if (!mounted) return;
      setState(() {
        _cancelling = false;
        _status = 'CANCELLED';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Request cancelled.')),
      );
      context.go('/user');
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancelling = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(friendlyError(e, context: 'Could not cancel the request')),
      ));
    }
  }

  String get _reference {
    final raw = _order?['order_number'] as String?;
    if (raw != null && raw.trim().isNotEmpty) return '#$raw';
    final id = widget.orderId;
    return '#${id.length >= 8 ? id.substring(0, 8).toUpperCase() : id}';
  }

  @override
  Widget build(BuildContext context) {
    final rejected = _status == 'REJECTED';
    final cancelled = _status == 'CANCELLED';

    return Scaffold(
      appBar: AppBar(title: const Text('Waiting for approval')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                  ),
                )
              : SafeArea(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          margin: const EdgeInsets.only(bottom: 20),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: (rejected
                                    ? AppTheme.error
                                    : cancelled
                                        ? AppTheme.textMuted
                                        : AppTheme.gold)
                                .withOpacity(0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            rejected
                                ? Icons.close
                                : cancelled
                                    ? Icons.remove_circle_outline
                                    : Icons.hourglass_top_rounded,
                            size: 38,
                            color: rejected
                                ? AppTheme.error
                                : cancelled
                                    ? AppTheme.textMuted
                                    : AppTheme.gold,
                          ),
                        ),
                        Text(
                          rejected
                              ? 'This request was not approved'
                              : cancelled
                                  ? 'Request cancelled'
                                  : 'Your checkout is with the team',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          rejected
                              ? (_order?['checkout_rejection_reason']
                                          as String?)?.trim().isNotEmpty ==
                                      true
                                  ? 'Reason: ${_order!['checkout_rejection_reason']}'
                                  : 'The administrator did not approve this '
                                      'request. Start a new checkout or contact '
                                      'support for the details.'
                              : cancelled
                                  ? 'You closed this request before it was '
                                      'decided.'
                                  : 'We are checking your delivery and choosing '
                                      'the vehicle and driver. This screen '
                                      'updates by itself the moment the '
                                      'decision is made — you can close the app '
                                      'and come back.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 26),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppTheme.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppTheme.cardBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text('Order',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textSecondary)),
                                  const Spacer(),
                                  Text(_reference,
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700)),
                                ],
                              ),
                              if ((_order?['buyer_name'] as String?)
                                      ?.trim()
                                      .isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 8),
                                Text('For ${_order!['buyer_name']}',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        color: AppTheme.textSecondary)),
                              ],
                              if ((_order?['delivery_address'] as String?)
                                      ?.trim()
                                      .isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 8),
                                Text('To ${_order!['delivery_address']}',
                                    style: const TextStyle(
                                        fontSize: 13,
                                        height: 1.4,
                                        color: AppTheme.textSecondary)),
                              ],
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  const Text('Amount',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color: AppTheme.textSecondary)),
                                  const Spacer(),
                                  Text(
                                    '${((_order?['total_amount'] as num?) ?? 0).toStringAsFixed(2)} '
                                    '${(_order?['currency'] as String?) ?? 'ETB'}',
                                    style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w700,
                                        color: AppTheme.primaryGreen),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (!rejected && !cancelled)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 16),
                            child: LinearProgressIndicator(
                              minHeight: 4,
                              backgroundColor: AppTheme.creamDark,
                              valueColor: AlwaysStoppedAnimation(
                                  AppTheme.primaryGreen),
                            ),
                          ),
                        if (!rejected && !cancelled)
                          PrimaryButton(
                            label: 'CANCEL REQUEST',
                            isLoading: _cancelling,
                            onPressed: _cancelling ? null : _cancel,
                          )
                        else
                          PrimaryButton(
                            label: 'BACK TO DASHBOARD',
                            onPressed: () => context.go('/user'),
                          ),
                      ],
                    ),
                  ),
                ),
    );
  }
}
