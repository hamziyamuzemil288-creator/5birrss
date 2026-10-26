import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/delivery_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/services/live_map_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/live_map.dart';
import '../../core/widgets/primary_button.dart';

/// The buyer's delivery, live.
///
/// Built on the ride-tracking instruments rather than beside them: the driver
/// is the same `driver_status` GPS channel the Active Ride screen streams
/// (watchDriverStatus), the pin is the same animated `LiveMap` widget, and the
/// order state is polled from the one server reader
/// (`get_delivery_tracking`) that decides what each party may see.
///
/// What it is NOT: a second realtime system. The poll refreshes the delivery
/// STATE (assigned / arrived / confirmed) and acts as the fallback when the
/// socket is down; the stream is what makes the marker MOVE.
class DeliveryTrackingScreen extends ConsumerStatefulWidget {
  final String orderId;
  const DeliveryTrackingScreen({super.key, required this.orderId});

  @override
  ConsumerState<DeliveryTrackingScreen> createState() =>
      _DeliveryTrackingScreenState();
}

class _DeliveryTrackingScreenState
    extends ConsumerState<DeliveryTrackingScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  LatLng? _driverPosition;
  Map<String, String>? _sellerContact;

  bool _confirming = false;
  bool _contactLoading = false;

  Timer? _poll;
  ResilientSubscription<List<Map<String, dynamic>>>? _driverStream;
  String? _streamedDriverId;

  @override
  void initState() {
    super.initState();
    _load();
    // State, not GPS: the delivery can flip to ARRIVED while the driver stands
    // still, and only the server knows when that happened.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _driverStream?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final data = await DeliveryService.instance.tracking(widget.orderId);
      if (!mounted) return;
      if (data == null || data['ok'] != true) {
        if (!silent) {
          setState(() => _error = 'This delivery could not be loaded');
        }
        return;
      }
      setState(() {
        _data = data;
        _error = null;
      });
      _watchDriver(data['driver_provider_id'] as String?);
      // The seller's number rides along: the buyer may need to reach the shop
      // while the parcel is moving, through the SAME escrow RPC the order
      // screen uses (release_order_contact, APPROVED onwards).
      _loadSellerContact();
    } catch (e) {
      if (!mounted) return;
      if (!silent) {
        setState(() =>
            _error = friendlyError(e, context: 'Could not load this delivery'));
      }
    }
  }

  /// Attach the driver's live stream once, and re-attach only when the driver
  /// changes (a reassignment).
  void _watchDriver(String? driverId) {
    if (driverId == null || driverId == _streamedDriverId) return;
    _streamedDriverId = driverId;
    _driverStream?.cancel();
    _driverStream = ResilientSubscription<List<Map<String, dynamic>>>(
      stream: DeliveryService.instance.watchDriverStatus(driverId),
      onData: (rows) {
        if (!mounted || rows.isEmpty) return;
        final loc = rows.first['current_location'];
        if (loc == null) return;
        final point = GeoPoint.parse(loc);
        if (point == null) return;
        setState(() => _driverPosition = LatLng(point.lat, point.lng));
      },
      onState: (_) {},
    );
  }

  Future<void> _loadSellerContact() async {
    if (_sellerContact != null || _contactLoading) return;
    _contactLoading = true;
    try {
      final rows = await Supabase.instance.client
          .rpc('release_order_contact', params: {'p_order_id': widget.orderId});
      final list = (rows as List?) ?? const [];
      if (list.isNotEmpty && mounted) {
        final row = Map<String, dynamic>.from(list.first as Map);
        final phone = row['provider_phone'] as String?;
        if (phone != null && phone.trim().isNotEmpty) {
          setState(() => _sellerContact = {
            'phone': phone,
            'name': (row['provider_name'] as String?) ?? 'Provider',
          });
        }
      }
    } catch (_) {
      // Best-effort: the seller contact is a convenience here, never the
      // reason a tracking screen fails to load.
    } finally {
      _contactLoading = false;
    }
  }

  String get _deliveryStatus =>
      (_data?['delivery_status'] as String?) ?? 'ASSIGNED';

  bool get _buyerMayConfirm => _deliveryStatus == 'ARRIVED';

  /// "I received it": mark the delivery, then complete the order through the
  /// existing transition path. Two server calls on purpose — the receipt is
  /// delivery state, the completion is order state, and the second one is
  /// still guarded by the whitelist (STARTED -> COMPLETED).
  Future<void> _confirmReceived() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Confirm you received it?'),
        content: const Text(
            'Confirm only once the order is in your hands. This completes the '
            'order and tells the driver and the seller.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(false),
              child: const Text('NOT YET')),
          TextButton(
              onPressed: () => Navigator.of(dctx).pop(true),
              child: const Text('I RECEIVED IT')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _confirming = true);
    try {
      await DeliveryService.instance.confirmReceived(widget.orderId);
      await DeliveryService.instance.completeOrder(widget.orderId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Delivery confirmed — thank you!')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      // The receipt is already recorded server-side even if the completion
      // step failed, so the seller (or the admin) can still finish the order
      // from its screen — say what actually happened rather than pretending.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(friendlyError(
              e, context: 'Receipt saved, but the order could not complete'))));
      await _load();
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null && _data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Delivery')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted)),
          ),
        ),
      );
    }
    if (_data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Delivery')),
        body: const Center(
            child: CircularProgressIndicator(color: AppTheme.primaryGreen)),
      );
    }

    final driverName =
        (_data!['driver_name'] as String?) ?? 'Your driver';
    final destLat = (_data!['dest_lat'] as num?)?.toDouble();
    final destLng = (_data!['dest_lng'] as num?)?.toDouble();
    final destLabel = (_data!['dest_label'] as String?) ?? '';
    final driverPos = _driverPosition;

    return Scaffold(
      appBar: AppBar(title: const Text('Delivery')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _statusCard(driverName),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  height: 280,
                  child: driverPos == null && destLat == null
                      ? Container(
                          color: AppTheme.surface,
                          alignment: Alignment.center,
                          child: const Text(
                            'Waiting for the driver to start sharing their '
                            'location…',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5, color: AppTheme.textMuted),
                          ),
                        )
                      : LiveMap(
                          center: driverPos ??
                              LatLng(destLat ?? 0, destLng ?? 0),
                          zoom: 15,
                          vehicles: driverPos == null
                              ? const []
                              : [
                                  LiveMapVehicle(
                                    providerId:
                                        (_data!['driver_provider_id'] as String?) ??
                                            'driver',
                                    providerType: 'VEHICLE_PROVIDER',
                                    displayName: driverName,
                                    lat: driverPos.latitude,
                                    lng: driverPos.longitude,
                                    onRide: true,
                                    secondsSinceFix: 0,
                                    categorySlug: 'delivery',
                                    categoryName: 'Delivery',
                                  )
                                ],
                          destinationPoint: destLat == null
                              ? null
                              : LatLng(destLat, destLng ?? 0),
                          showRecenter: false,
                        ),
                ),
              ),
              if (destLabel.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Delivering to: $destLabel',
                    style: const TextStyle(
                        fontSize: 12.5, color: AppTheme.textSecondary)),
              ],
              const SizedBox(height: 16),
              if (_sellerContact != null) _sellerCard(),
              if (_buyerMayConfirm) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    label: 'I RECEIVED IT',
                    icon: Icons.check_circle_outline,
                    isLoading: _confirming,
                    onPressed: _confirming ? null : _confirmReceived,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Confirm once the order is in your hands — this completes '
                  'the order for everyone.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 11.5, height: 1.4, color: AppTheme.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard(String driverName) {
    final String headline;
    final String detail;
    final IconData icon;
    final Color color;
    switch (_deliveryStatus) {
      case 'ARRIVED':
        headline = 'Your driver is there';
        detail = '$driverName marked arrival at your delivery point.';
        icon = Icons.place_outlined;
        color = AppTheme.gold;
        break;
      case 'DELIVERED':
        headline = 'Delivered';
        detail = 'You confirmed this delivery. Thank you!';
        icon = Icons.check_circle_outline;
        color = AppTheme.success;
        break;
      default:
        if (_data!['driver_provider_id'] == null) {
          // Before an admin assigns somebody there is no driver to follow,
          // and saying "on the way" would be a small lie the map then
          // contradicts with an empty street.
          headline = 'Finding your driver';
          detail = 'Your payment is confirmed. As soon as a driver takes this '
              'delivery you will watch them move on the map below.';
          icon = Icons.hourglass_empty;
          color = AppTheme.teal;
        } else {
          headline = 'On the way';
          detail = '$driverName is bringing your order. You will see them '
              'move on the map as they get closer.';
          icon = Icons.local_shipping_outlined;
          color = AppTheme.teal;
        }
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(headline,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(detail,
              style: const TextStyle(fontSize: 12.5, height: 1.4)),
        ],
      ),
    );
  }

  /// The seller's number, released by release_order_contact — the same escrow
  /// RPC the order screen calls, so this screen adds no reveal logic of its
  /// own.
  Widget _sellerCard() {
    final contact = _sellerContact!;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: AppTheme.primaryGreen.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.store_outlined,
              size: 18, color: AppTheme.primaryGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(contact['name'] ?? 'Provider',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700)),
                Text(contact['phone'] ?? '',
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primaryGreen)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () async {
              final ok = await LocationService.instance
                  .openPhoneCall(contact['phone'] ?? '');
              if (!ok && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(
                        'Could not open the dialler — copy ${contact['phone']} instead.')));
              }
            },
            icon: const Icon(Icons.call, size: 16,
                color: AppTheme.primaryGreen),
            label: const Text('CALL',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.primaryGreen)),
          ),
        ],
      ),
    );
  }
}
