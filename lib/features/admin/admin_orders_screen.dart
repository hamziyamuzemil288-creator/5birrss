import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/delivery_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/utils/order_number_format.dart' as onf;
import '../../core/widgets/load_error_view.dart';
import '../user/user_order_detail_screen.dart' show orderStatusColor;

/// Every order on the platform, newest first.
///
/// Exists because the dashboard's "Orders" quick-stat tile counts orders but
/// had nowhere to go: a tile that shows a number a tap cannot open is a
/// decoy, and the admin panel had no order list at all — only the
/// payment-verification queue, which shows one status of one kind.
class AdminOrdersScreen extends StatefulWidget {
  const AdminOrdersScreen({super.key});

  @override
  State<AdminOrdersScreen> createState() => _AdminOrdersScreenState();
}

class _AdminOrdersScreenState extends State<AdminOrdersScreen> {
  static const _filters = [
    'All',
    'Pending',
    'In Progress',
    'Completed',
    'Cancelled',
  ];

  List<Map<String, dynamic>> _orders = [];
  Map<String, String> _providerNames = {};
  Map<String, String> _driverNames = {};
  String _filter = 'All';
  bool _loading = true;
  String? _error;

  /// One assignment at a time, keyed by the order it is running for.
  String? _assigningId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('orders')
          // The buyer's payment reference lives in the creation note of
          // order_status_history — orders itself has no note column.
          .select('*, provider_profiles(business_name), '
              'order_status_history(note, created_at)')
          .order('created_at', ascending: false)
          .limit(300);
      final orders = List<Map<String, dynamic>>.from(data as List);
      final names = <String, String>{};
      for (final o in orders) {
        final prov = o['provider_profiles'];
        if (prov is Map && prov['business_name'] is String) {
          names[o['id'] as String] = prov['business_name'] as String;
        }
      }

      // Who is driving each delivery, so the card can say it without
      // opening the order. Best-effort like every other read here: a failed
      // lookup leaves "Driver assigned" rather than a blank row.
      final driverIds = orders
          .map((o) => o['delivery_driver_provider_id'] as String?)
          .whereType<String>()
          .toSet()
          .toList(growable: false);
      final driverNames = <String, String>{};
      if (driverIds.isNotEmpty) {
        try {
          final rows = await Supabase.instance.client
              .from('provider_profiles')
              .select('id, business_name')
              .inFilter('id', driverIds);
          for (final r in rows as List) {
            final id = r['id'] as String?;
            final label = (r['business_name'] as String?)?.trim();
            if (id != null && label != null && label.isNotEmpty) {
              driverNames[id] = label;
            }
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _orders = orders;
          _providerNames = names;
          _driverNames = driverNames;
          _loading = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load orders');
        });
      }
    }
  }

  List<Map<String, dynamic>> get _filtered {
    switch (_filter) {
      case 'Pending':
        return _orders
            .where((o) => const {
                  'CREATED',
                  'PENDING_PROVIDER',
                  'ACCEPTED',
                  'PAYMENT_PENDING',
                  'PAYMENT_VERIFICATION',
                }.contains(o['status']))
            .toList();
      case 'In Progress':
        return _orders
            .where((o) => const {'APPROVED', 'STARTED', 'DISPUTED'}
                .contains(o['status']))
            .toList();
      case 'Completed':
        return _orders.where((o) => o['status'] == 'COMPLETED').toList();
      case 'Cancelled':
        return _orders
            .where((o) => const {
                  'CANCELLED',
                  'REJECTED',
                  'REFUNDED',
                }.contains(o['status']))
            .toList();
      default:
        return _orders;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All Orders')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : Column(
                  children: [
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        itemCount: _filters.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) {
                          final f = _filters[i];
                          return ChoiceChip(
                            label: Text(f,
                                style: const TextStyle(fontSize: 12)),
                            selected: _filter == f,
                            onSelected: (_) => setState(() => _filter = f),
                            selectedColor: AppTheme.primaryGreen
                                .withOpacity(0.15),
                            labelStyle: TextStyle(
                                color: _filter == f
                                    ? AppTheme.primaryGreen
                                    : null,
                                fontWeight: _filter == f
                                    ? FontWeight.w600
                                    : FontWeight.w400),
                          );
                        },
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: _filtered.isEmpty
                            ? const Center(
                                child: Text('No orders in this status',
                                    style:
                                        TextStyle(color: AppTheme.textMuted)))
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _filtered.length,
                                itemBuilder: (_, i) =>
                                    _orderCard(_filtered[i]),
                              ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _orderCard(Map<String, dynamic> o) {
    final status = (o['status'] as String?) ?? 'UNKNOWN';
    final currency = o['currency'] as String? ?? 'ETB';
    final amount = (o['total_amount'] as num?)?.toDouble() ?? 0;
    final provider = _providerNames[o['id']] ?? 'Provider';
    final ref = _paymentRef(o);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: () async {
          await context.push('/user/orders/${o['id']}', extra: 'admin');
          if (mounted) _load();
        },
        title: Row(
          children: [
            Expanded(
              child: Text(
                onfRef(o),
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: orderStatusColor(status).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(status.replaceAll('_', ' '),
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: orderStatusColor(status))),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(provider,
                style: const TextStyle(
                    fontSize: 13, color: AppTheme.textSecondary)),
            Text(
                'Placed ${_fmtDate(DateTime.parse(o['created_at'] as String))}',
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textMuted)),
            if (ref != null)
              Text('Payment ref: $ref',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
            if (_isDelivery(o)) _deliveryRow(o),
          ],
        ),
        trailing: Text('${amount.toStringAsFixed(2)} $currency',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppTheme.primaryGreen)),
      ),
    );
  }

  /// A delivery order: the only kind that needs a driver at all. The column
  /// is written once by create_order_secure and never changes, so the row
  /// itself decides — this screen does not guess from the items.
  bool _isDelivery(Map<String, dynamic> o) =>
      (o['fulfillment_mode'] as String?) == 'DELIVERY';

  /// Assignable window: exactly what `assign_delivery_driver` accepts
  /// server-side (payment verified, delivery not finished). Outside it the
  /// card still SAYS who is driving, it just offers no button that would
  /// come back as a refusal.
  bool _canAssignDriver(Map<String, dynamic> o) {
    final status = o['status'] as String?;
    return status == 'APPROVED' || status == 'STARTED';
  }

  /// The delivery line on each delivery order: who is taking it, and the
  /// door to giving it to somebody. Assignment is the one part of the
  /// delivery flow with no other admin surface — rides claim themselves, a
  /// delivery is an `orders` row and only an admin can attach a driver.
  Widget _deliveryRow(Map<String, dynamic> o) {
    final id = o['id'] as String? ?? '';
    final driverId = o['delivery_driver_provider_id'] as String?;
    final deliveryStatus = (o['delivery_status'] as String?) ?? 'ASSIGNED';
    final assignable = _canAssignDriver(o);
    final busy = _assigningId == id;

    final String stateText;
    if (driverId == null) {
      stateText = 'No driver assigned';
    } else {
      final name = _driverNames[driverId] ?? 'Driver assigned';
      stateText = deliveryStatus == 'ARRIVED'
          ? '$name · arrived'
          : deliveryStatus == 'DELIVERED'
              ? '$name · delivered'
              : '$name · on the way';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            Icons.local_shipping_outlined,
            size: 14,
            color: driverId == null ? AppTheme.gold : AppTheme.primaryGreen,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              stateText,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textSecondary),
            ),
          ),
          if (assignable)
            busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.primaryGreen),
                  )
                : TextButton(
                    onPressed: () => _assignDriver(o),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 32),
                      foregroundColor: AppTheme.primaryGreen,
                    ),
                    child: Text(
                      driverId == null ? 'ASSIGN DRIVER' : 'CHANGE DRIVER',
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ),
        ],
      ),
    );
  }

  /// The whole assignment: roster, pick, server decision, one reload.
  ///
  /// Both calls are the SECURITY DEFINER functions from migration
  /// 20261026000002 through DeliveryService — the roster is admin-only
  /// there, the assignment re-checks the escrow window and the driver's
  /// approved vehicle-provider status, and this screen never decides any of
  /// it itself.
  Future<void> _assignDriver(Map<String, dynamic> o) async {
    final orderId = o['id'] as String;
    if (_assigningId != null) return;
    setState(() => _assigningId = orderId);
    try {
      final roster = await DeliveryService.instance.adminDrivers();
      if (!mounted) return;

      if (roster.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'No approved vehicle providers yet — approve a vehicle provider first.')));
        return;
      }

      final current = o['delivery_driver_provider_id'] as String?;
      final picked = await showModalBottomSheet<String>(
        context: context,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (sheetCtx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('Assign a driver',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              const Text('Approved vehicle providers, online first',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: roster.length,
                  itemBuilder: (_, i) {
                    final d = roster[i];
                    final did = d['id'] as String?;
                    final name = (d['name'] as String?) ?? 'Driver';
                    final online = d['is_online'] == true;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        Icons.circle,
                        size: 10,
                        color: online ? AppTheme.success : AppTheme.textMuted,
                      ),
                      title: Text(name,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(online ? 'Online now' : 'Offline',
                          style: const TextStyle(
                              fontSize: 11, color: AppTheme.textMuted)),
                      trailing: did == current
                          ? const Text('CURRENT',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primaryGreen))
                          : null,
                      onTap: () => Navigator.of(sheetCtx).pop(did),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;

      await DeliveryService.instance.assignDriver(orderId, picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Driver assigned — both sides have been notified.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(friendlyError(e, context: 'Could not assign a driver'))));
    } finally {
      if (mounted) setState(() => _assigningId = null);
    }
  }

  /// Short order label: the same first-eight-of-id reference everywhere.
  String onfRef(Map<String, dynamic> o) {
    final id = o['id'] as String? ?? '';
    final short = id.length >= 8
        ? '#${id.substring(0, 8).toUpperCase()}'
        : 'Order';
    final raw = o['order_number'] as String?;
    if (raw == null || raw.isEmpty) return short;
    return onf.formatOrderNumber(raw) ?? short;
  }

  /// The buyer's payment reference, parsed out of the creation note in
  /// order_status_history (orders has no note column).
  String? _paymentRef(Map<String, dynamic> order) {
    final raw = order['order_status_history'];
    final history = raw is List
        ? raw.whereType<Map<String, dynamic>>().toList()
        : raw is Map<String, dynamic>
            ? [raw]
            : const <Map<String, dynamic>>[];
    history.sort((a, b) {
      final ta = a['created_at'] as String? ?? '';
      final tb = b['created_at'] as String? ?? '';
      return ta.compareTo(tb);
    });
    for (final row in history) {
      final note = row['note'] as String?;
      if (note == null || note.trim().isEmpty) continue;
      for (final part in note.split('|')) {
        final match = RegExp(r'Payment ref:\s*(.+)', caseSensitive: false)
            .firstMatch(part.trim());
        final ref = match?.group(1)?.trim();
        if (ref != null && ref.isNotEmpty) return ref;
      }
    }
    return null;
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day}, ${l.year} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
