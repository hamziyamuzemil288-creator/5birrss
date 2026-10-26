import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/services/delivery_service.dart';
import '../../core/services/location_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/primary_button.dart';

/// The assigned driver's deliveries: where to go, how far along each one is,
/// and the two moves that end them.
///
/// Everything server-decided. This screen holds no state of its own beyond
/// the list and the buyer contacts the database has already agreed to release
/// (`get_delivery_buyer_contact` refuses until arrival is recorded): the
/// arrival, the reveal and the notifications all live in migration
/// 20261026000002. The order row itself is never read here — the driver has
/// no access to it by design, and `my_delivery_jobs()` is the only door.
class DriverDeliveryJobsScreen extends StatefulWidget {
  const DriverDeliveryJobsScreen({super.key});

  @override
  State<DriverDeliveryJobsScreen> createState() =>
      _DriverDeliveryJobsScreenState();
}

class _DriverDeliveryJobsScreenState extends State<DriverDeliveryJobsScreen> {
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  String? _error;

  /// Which job (if any) an action is running for, so only that card spins.
  String? _busyId;

  /// Buyer contacts released so far, keyed by order id. Loaded lazily the
  /// moment arrival is recorded — never earlier, because the server refuses
  /// the read before then and there is nothing to cache.
  final Map<String, Map<String, String>> _contacts = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final jobs = await DeliveryService.instance.myJobs();
      if (!mounted) return;
      setState(() {
        _jobs = jobs;
        _error = null;
        _loading = false;
      });
      // Anything already arrived shows its contact card, so re-read the
      // releases the database already granted on this pass.
      for (final job in jobs) {
        final id = job['id'] as String?;
        if (id != null && _reachedArrival(job)) unawaited(_loadContact(id));
      }
    } catch (e) {
      if (!mounted) return;
      if (silent) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e, context: 'Could not load your delivery jobs');
      });
    }
  }

  /// Arrival is what unlocks the buyer's number server-side; this only
  /// mirrors that state so the card knows whether to offer the call button.
  bool _reachedArrival(Map<String, dynamic> job) =>
      (job['delivery_status'] as String?) == 'ARRIVED' ||
      (job['delivery_status'] as String?) == 'DELIVERED';

  bool _isActive(Map<String, dynamic> job) {
    final status = job['order_status'] as String?;
    return status == 'APPROVED' || status == 'STARTED';
  }

  Future<void> _loadContact(String orderId) async {
    if (_contacts.containsKey(orderId)) return;
    try {
      final contact = await DeliveryService.instance.buyerContact(orderId);
      if (contact != null && mounted) {
        setState(() => _contacts[orderId] = contact);
      }
    } catch (_) {
      // Released or not, a missing number is never worth a red screen on a
      // driver's phone mid-job — the button simply stays unavailable.
    }
  }

  /// "I am here". One confirm dialog first, because the arrival is what tells
  /// the buyer and what opens their number — it is not a tap that can be
  /// quietly undone from this screen.
  Future<void> _markArrived(Map<String, dynamic> job) async {
    final orderId = job['id'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('You have arrived?'),
        content: const Text(
            'This tells the buyer you are at the delivery point and releases '
            'their number to you so you can call them.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('NOT YET')),
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('I AM HERE')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = orderId);
    try {
      await DeliveryService.instance.markArrived(orderId);
      await _load(silent: true);
      await _loadContact(orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Arrival recorded — the buyer has been told.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(friendlyError(e, context: 'Could not record your arrival'))));
      await _load(silent: true);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _navigate(Map<String, dynamic> job) async {
    final lat = (job['dest_lat'] as num?)?.toDouble();
    final lng = (job['dest_lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;
    setState(() => _busyId = job['id'] as String?);
    final ok = await LocationService.instance.openDirectionsTo(
      destLat: lat,
      destLng: lng,
      label: (job['dest_label'] as String?) ?? 'Delivery point',
    );
    if (mounted) {
      setState(() => _busyId = null);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No maps app available on this device')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery Jobs')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.teal))
          : _error != null
              ? LoadErrorView(
                  message: _error!,
                  icon: Icons.local_shipping_outlined,
                  onRetry: _load)
              : _jobs.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.local_shipping_outlined,
                              size: 64, color: AppTheme.textMuted),
                          SizedBox(height: 16),
                          Text('No delivery jobs yet',
                              style: TextStyle(color: AppTheme.textMuted)),
                          SizedBox(height: 8),
                          Text(
                              'When an admin assigns you a delivery it appears '
                              'here.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 12, color: AppTheme.textMuted)),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: () => _load(silent: true),
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _jobs.length,
                        itemBuilder: (_, i) => _jobCard(_jobs[i]),
                      ),
                    ),
    );
  }

  Widget _jobCard(Map<String, dynamic> job) {
    final id = job['id'] as String? ?? '';
    final deliveryStatus = (job['delivery_status'] as String?) ?? 'ASSIGNED';
    final dest = ((job['dest_label'] as String?) ?? '').trim();
    final active = _isActive(job);
    final busy = _busyId == id;
    final arrived = _reachedArrival(job);
    final amount = (job['total_amount'] as num?)?.toDouble();
    final currency = (job['currency'] as String?) ?? 'ETB';
    final contact = _contacts[id];

    final (String stateLabel, Color stateColor) = switch (deliveryStatus) {
      'ARRIVED' => ('Arrived', AppTheme.gold),
      'DELIVERED' => ('Delivered', AppTheme.success),
      _ => active
          ? ('To deliver', AppTheme.teal)
          : ('Finished', AppTheme.textMuted),
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.local_shipping_outlined,
                    size: 16, color: stateColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dest.isEmpty ? 'Delivery address on the order' : dest,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: stateColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(stateLabel,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: stateColor)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('Order #${id.substring(0, id.length >= 8 ? 8 : id.length)}',
                    style: const TextStyle(
                        fontSize: 12, color: AppTheme.textSecondary)),
                const SizedBox(width: 10),
                if (amount != null)
                  Text('${amount.toStringAsFixed(2)} $currency',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                const Spacer(),
                Text(_fmtDate(DateTime.parse(job['created_at'] as String)),
                    style:
                        const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              ],
            ),
            if (contact != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryGreen.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.primaryGreen.withOpacity(0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.person_outline,
                        size: 16, color: AppTheme.primaryGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(contact['name'] ?? 'Buyer',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700)),
                          Text(contact['phone'] ?? '',
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primaryGreen)),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final ok = await LocationService.instance
                            .openPhoneCall(contact['phone'] ?? '');
                        if (ok == false && mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Could not open the dialler — copy ${contact['phone']} instead.')));
                        }
                      },
                      icon: const Icon(Icons.call,
                          size: 16, color: AppTheme.primaryGreen),
                      label: const Text('CALL',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryGreen)),
                    ),
                  ],
                ),
              ),
            ],
            if (active && (job['dest_lat'] as num?) != null) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'NAVIGATE',
                  icon: Icons.navigation_outlined,
                  isOutlined: true,
                  isLoading: busy && !arrived,
                  onPressed: busy ? null : () => _navigate(job),
                ),
              ),
            ],
            if (active && !arrived) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'I AM HERE',
                  icon: Icons.place_outlined,
                  isLoading: busy,
                  onPressed: busy ? null : () => _markArrived(job),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Press once you are at the delivery point — it tells the buyer '
                'and opens their number for you.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
              ),
            ],
            if (active && arrived && deliveryStatus == 'ARRIVED') ...[
              const SizedBox(height: 8),
              const Text(
                'Waiting for the buyer to confirm they received it. Call if '
                'nobody comes to the door.',
                style: TextStyle(fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtDate(DateTime dt) {
    final l = dt.toLocal();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String two(int v) => v.toString().padLeft(2, '0');
    return '${months[l.month - 1]} ${l.day} · ${two(l.hour)}:${two(l.minute)}';
  }
}
