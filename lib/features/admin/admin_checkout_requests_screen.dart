import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/delivery_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// The admin side of the checkout-approval gate.
///
/// A delivery checkout is not an order the provider can accept yet: it waits
/// for a decision here. Approving is also the ONLY place a vehicle and driver
/// are chosen, which is why the queue is separate from the general order list
/// — the general list can assign a driver later, but it cannot decide the
/// request or attach a vehicle.
///
/// Every decision goes through the `checkout-review` Edge Function, which
/// verifies the ADMIN role and then calls `admin_review_checkout_request`.
/// The RPC must run as a server write: an admin JWT is still a client write
/// and the order-status guard refuses it. (The RPC is a SECURITY
/// DEFINER RPC that re-checks the admin role, row-locks the order, refuses a
/// second decision, refuses a busy vehicle or driver, and writes audit_logs.
/// This screen never decides any of those rules itself.
class AdminCheckoutRequestsScreen extends StatefulWidget {
  const AdminCheckoutRequestsScreen({super.key});

  @override
  State<AdminCheckoutRequestsScreen> createState() =>
      _AdminCheckoutRequestsScreenState();
}

class _AdminCheckoutRequestsScreenState
    extends State<AdminCheckoutRequestsScreen> {
  static const _tabs = ['PENDING', 'APPROVED', 'REJECTED', 'ALL'];

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;

  String _tab = 'PENDING';
  List<Map<String, dynamic>> _rows = const [];
  int _pendingCount = 0;
  bool _loading = true;
  String? _error;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _load();
    // Timeout reminders for a queue nobody has opened. Admin-only and
    // deduplicated per order per hour server-side, so this is safe on load.
    _client.rpc('notify_stale_checkout_requests').then((_) {}, onError: (_) {});
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _client.rpc('admin_checkout_requests', params: {
        'p_tab': _tab,
        'p_search': _searchCtrl.text.trim(),
      });
      final count = await _client.rpc('admin_checkout_request_count');
      if (!mounted) return;
      setState(() {
        _rows = List<Map<String, dynamic>>.from(rows as List);
        _pendingCount = (count as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e,
            context: 'Could not load the checkout requests');
      });
    }
  }

  void _onSearch(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), _load);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Checkout Requests'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: BirrTextField(
              label: 'Search',
              controller: _searchCtrl,
              hint: 'Order number, buyer, phone or provider',
              onChanged: _onSearch,
            ),
          ),
          SizedBox(
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              itemCount: _tabs.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final tab = _tabs[i];
                final label = tab[0] + tab.substring(1).toLowerCase();
                return ChoiceChip(
                  label: Text(
                    tab == 'PENDING' && _pendingCount > 0
                        ? '$label ($_pendingCount)'
                        : label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: _tab == tab,
                  onSelected: (_) {
                    if (_tab == tab) return;
                    setState(() => _tab = tab);
                    _load();
                  },
                  selectedColor: AppTheme.primaryGreen.withOpacity(0.15),
                  labelStyle: TextStyle(
                    color:
                        _tab == tab ? AppTheme.primaryGreen : null,
                    fontWeight:
                        _tab == tab ? FontWeight.w600 : FontWeight.w400,
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: _error != null
                ? LoadErrorView(message: _error!, onRetry: _load)
                : _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: AppTheme.primaryGreen))
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _rows.isEmpty
                            ? ListView(
                                children: const [
                                  SizedBox(height: 80),
                                  Center(
                                    child: Text(
                                      'Nothing in this queue',
                                      style: TextStyle(
                                          color: AppTheme.textMuted),
                                    ),
                                  ),
                                ],
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.all(16),
                                itemCount: _rows.length,
                                itemBuilder: (_, i) => _card(_rows[i]),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> row) {
    final status = (row['status'] as String?) ?? 'AWAITING_APPROVAL';
    final buyer = (row['buyer_name'] as String?)?.trim().isNotEmpty == true
        ? row['buyer_name'] as String
        : 'Guest buyer';
    final phone = (row['buyer_phone'] as String?) ?? '';
    final provider = (row['provider_name'] as String?) ?? 'Provider';
    final amount = (row['total_amount'] as num?)?.toDouble() ?? 0;
    final currency = (row['currency'] as String?) ?? 'ETB';
    final pending = status == 'AWAITING_APPROVAL';
    final proofCount = (row['proof_count'] as num?)?.toInt() ?? 0;

    final color = pending
        ? AppTheme.gold
        : status == 'REJECTED' || status == 'CANCELLED'
            ? AppTheme.error
            : AppTheme.primaryGreen;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDetail(row),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _reference(row),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      status.replaceAll('_', ' '),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: color),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text('$buyer${phone.isEmpty ? '' : ' · $phone'}',
                  style: const TextStyle(
                      fontSize: 13, color: AppTheme.textSecondary)),
              Text(provider,
                  style: const TextStyle(
                      fontSize: 12, color: AppTheme.textMuted)),
              if ((row['delivery_address'] as String?)?.trim().isNotEmpty ==
                  true) ...[
                const SizedBox(height: 4),
                Text('To ${row['delivery_address']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '${row['item_count'] ?? 0} item(s) · '
                    '${proofCount > 0 ? 'payment proof attached' : 'no payment proof'}',
                    style: const TextStyle(
                        fontSize: 11.5, color: AppTheme.textMuted),
                  ),
                  const Spacer(),
                  Text('${amount.toStringAsFixed(2)} $currency',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryGreen)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _reference(Map<String, dynamic> row) {
    final number = (row['order_number'] as String?)?.trim();
    if (number != null && number.isNotEmpty) return 'Order #$number';
    final id = (row['id'] as String?) ?? '';
    return id.length >= 8
        ? 'Order #${id.substring(0, 8).toUpperCase()}'
        : 'Order';
  }

  Future<void> _openDetail(Map<String, dynamic> row) async {
    final orderId = row['id'] as String?;
    if (orderId == null) return;

    Map<String, dynamic>? detail;
    try {
      final data = await _client
          .rpc('admin_checkout_request_detail', params: {'p_order_id': orderId});
      if (data is Map) detail = Map<String, dynamic>.from(data);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              friendlyError(e, context: 'Could not open this request'))));
      return;
    }
    if (!mounted || detail == null) return;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetContext) => _CheckoutRequestSheet(
        summary: row,
        detail: detail!,
        onDecided: () {
          Navigator.of(sheetContext).pop();
          _load();
        },
      ),
    );
  }
}

class _CheckoutRequestSheet extends StatefulWidget {
  const _CheckoutRequestSheet({
    required this.summary,
    required this.detail,
    required this.onDecided,
  });

  final Map<String, dynamic> summary;
  final Map<String, dynamic> detail;
  final VoidCallback onDecided;

  @override
  State<_CheckoutRequestSheet> createState() => _CheckoutRequestSheetState();
}

class _CheckoutRequestSheetState extends State<_CheckoutRequestSheet> {
  bool _busy = false;

  Map<String, dynamic> get _order =>
      (widget.detail['order'] as Map?)?.cast<String, dynamic>() ?? const {};
  List<Map<String, dynamic>> get _items =>
      ((widget.detail['items'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  List<Map<String, dynamic>> get _proofs =>
      ((widget.detail['payment_proofs'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

  bool get _pending =>
      (widget.summary['status'] as String?) == 'AWAITING_APPROVAL';

  String get _reference {
    final number = (widget.summary['order_number'] as String?)?.trim();
    if (number != null && number.isNotEmpty) return '#$number';
    final id = (widget.summary['id'] as String?) ?? '';
    return id.length >= 8 ? '#${id.substring(0, 8).toUpperCase()}' : '';
  }

  @override
  Widget build(BuildContext context) {
    final currency = (widget.summary['currency'] as String?) ?? 'ETB';
    final amount =
        ((widget.summary['total_amount'] as num?) ?? 0).toDouble();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 18,
          bottom: 18 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Checkout request $_reference',
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _line('Buyer', '${widget.detail['buyer_name'] ?? 'Guest'}'),
              if ((widget.detail['buyer_phone'] as String?)
                      ?.trim()
                      .isNotEmpty ==
                  true)
                _line('Phone', '${widget.detail['buyer_phone']}'),
              _line('Provider', '${widget.detail['provider_name'] ?? '—'}'),
              if ((_order['delivery_address'] as String?)?.trim().isNotEmpty ==
                  true)
                _line('Delivery', '${_order['delivery_address']}'),
              _line('Payment proof',
                  _proofs.isEmpty ? 'Not attached' : '${_proofs.length} attached'),
              const Divider(height: 26),
              const Text('Items',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final item in _items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${item['product_name'] ?? 'Item'} × '
                          '${item['quantity']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      Text(
                        '${((item['unit_price'] as num?) ?? 0).toStringAsFixed(2)} $currency',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 26),
              Row(
                children: [
                  const Text('Total',
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${amount.toStringAsFixed(2)} $currency',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.primaryGreen)),
                ],
              ),
              if ((_order['checkout_rejection_reason'] as String?)
                      ?.trim()
                      .isNotEmpty ==
                  true) ...[
                const SizedBox(height: 12),
                Text(
                  'Rejection reason: ${_order['checkout_rejection_reason']}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: AppTheme.error),
                ),
              ],
              const SizedBox(height: 22),
              if (_pending)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy ? null : _reject,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.error,
                          side: BorderSide(
                              color: AppTheme.error.withOpacity(0.5)),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('REJECT'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: PrimaryButton(
                        label: 'APPROVE & ASSIGN',
                        isLoading: _busy,
                        onPressed: _busy ? null : _approve,
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    label: 'CLOSE',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(label,
                style: const TextStyle(
                    fontSize: 12.5, color: AppTheme.textMuted)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontSize: 13, height: 1.35)),
          ),
        ],
      ),
    );
  }

  Future<void> _reject() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reject this checkout?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'The buyer sees this reason on their waiting screen. Say what '
              'needs to change.',
              style: TextStyle(fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            BirrTextField(
              label: 'Reason',
              controller: controller,
              maxLines: 3,
              hint: 'e.g. the address is outside the delivery area',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('CANCEL'),
          ),
          TextButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.of(dialogContext).pop(text);
            },
            child: const Text('REJECT'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.trim().isEmpty || !mounted) return;

    await _call(
      decision: 'REJECT',
      reason: reason.trim(),
    );
  }

  Future<void> _approve() async {
    final orderId = widget.summary['id'] as String?;
    if (orderId == null) return;
    setState(() => _busy = true);
    try {
      final roster = await DeliveryService.instance.adminDrivers();
      if (!mounted) return;
      if (roster.isEmpty) {
        _say('No approved vehicle providers yet. Approve a vehicle provider '
            'before assigning a delivery.');
        return;
      }

      final driver = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (sheetContext) => _PickerSheet(
          title: 'Choose the driver',
          subtitle: 'Approved vehicle providers, online first',
          rows: roster,
          labelOf: (row) => (row['name'] as String?) ?? 'Driver',
          detailOf: (row) =>
              row['is_online'] == true ? 'Online now' : 'Offline',
          selectedId: (_order['delivery_driver_provider_id'] as String?),
        ),
      );
      if (driver == null || !mounted) return;

      final driverId = driver['id'] as String?;
      if (driverId == null) return;

      final vehicles =
          await DeliveryService.instance.adminDeliveryVehicles(driverId);
      if (!mounted) return;
      if (vehicles.isEmpty) {
        _say('This driver has no approved vehicle. Approve a vehicle in the '
            'driver\'s fleet first.');
        return;
      }

      final vehicle = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        builder: (sheetContext) => _PickerSheet(
          title: 'Choose the vehicle',
          subtitle: 'Only this driver\'s approved fleet is listed',
          rows: vehicles,
          labelOf: (row) {
            final plate = (row['plate_number'] as String?) ?? 'Vehicle';
            final brand = (row['brand'] as String?) ?? '';
            final model = (row['model'] as String?) ?? '';
            final name = '$brand $model'.trim();
            return name.isEmpty ? plate : '$plate · $name';
          },
          detailOf: (row) {
            final category = (row['category_name'] as String?) ?? 'Vehicle';
            return row['is_available'] == true
                ? '$category · available'
                : '$category · marked busy';
          },
          selectedId: (_order['delivery_vehicle_id'] as String?),
        ),
      );
      if (vehicle == null || !mounted) return;

      final vehicleId = vehicle['id'] as String?;
      if (vehicleId == null) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Approve and assign?'),
          content: Text(
            'The buyer moves to the live map immediately and the driver, the '
            'provider and the buyer are notified. Driver: '
            '${driver['name'] ?? '—'}. Vehicle: '
            '${vehicle['plate_number'] ?? '—'}.',
            style: const TextStyle(fontSize: 13, height: 1.45),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('BACK'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('APPROVE'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      await _call(
        decision: 'APPROVE',
        driverId: driverId,
        vehicleId: vehicleId,
        categoryId: vehicle['category_id'] as String?,
      );
    } catch (e) {
      if (!mounted) return;
      _say(friendlyError(e, context: 'Could not assign the delivery'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _call({
    required String decision,
    String? reason,
    String? driverId,
    String? vehicleId,
    String? categoryId,
  }) async {
    setState(() => _busy = true);
    try {
      await Supabase.instance.client.functions.invoke(
        'checkout-review',
        body: {
          'order_id': widget.summary['id'],
          'decision': decision,
          'reason': reason,
          'vehicle_category_id': categoryId,
          'vehicle_id': vehicleId,
          'driver_provider_id': driverId,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(decision == 'APPROVE'
            ? 'Approved — the buyer is moving to the live map.'
            : 'Rejected — the buyer has been told why.'),
      ));
      widget.onDecided();
    } catch (e) {
      if (!mounted) return;
      _say(friendlyError(
          e,
          context: decision == 'APPROVE'
              ? 'Could not approve this checkout'
              : 'Could not reject this checkout'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// One reusable picker for a driver or a vehicle.
class _PickerSheet extends StatelessWidget {
  const _PickerSheet({
    required this.title,
    required this.subtitle,
    required this.rows,
    required this.labelOf,
    required this.detailOf,
    this.selectedId,
  });

  final String title;
  final String subtitle;
  final List<Map<String, dynamic>> rows;
  final String Function(Map<String, dynamic>) labelOf;
  final String Function(Map<String, dynamic>) detailOf;
  final String? selectedId;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          Text(subtitle,
              style:
                  const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          const SizedBox(height: 8),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: rows.length,
              itemBuilder: (_, i) {
                final row = rows[i];
                final id = row['id'] as String?;
                return ListTile(
                  dense: true,
                  title: Text(labelOf(row),
                      style: const TextStyle(fontSize: 14)),
                  subtitle: Text(detailOf(row),
                      style: const TextStyle(
                          fontSize: 11, color: AppTheme.textMuted)),
                  trailing: id == selectedId
                      ? const Text('CURRENT',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryGreen))
                      : null,
                  onTap: () => Navigator.of(context).pop(row),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
