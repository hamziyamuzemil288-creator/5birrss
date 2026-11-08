import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/active_order_store.dart';
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
    extends ConsumerState<DeliveryTrackingScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? _data;
  String? _error;

  LatLng? _driverPosition;

  /// Bearing between the last two REAL fixes, so the pin points the way the
  /// driver is actually travelling. Null until there are two fixes; the
  /// simulated marker uses its own north/south bearing instead.
  double? _driverHeading;
  Map<String, String>? _sellerContact;

  /// Progress, computed from whichever position is trusted: the driver's real
  /// GPS, or (when no fix has ever arrived) the clearly-labelled simulated
  /// marker below.
  double? _distanceKm;
  int? _etaMinutes;

  /// True while the marker is moving on a SIMULATED path, because the
  /// assigned driver has not shared a GPS fix. It is shown to the buyer as
  /// "approximate" rather than passed off as a live location, and it stops the
  /// moment a real fix arrives.
  bool _simulated = false;
  LatLng? _simPosition;
  Timer? _simTimer;

  bool _confirming = false;
  bool _contactLoading = false;

  Timer? _poll;
  ResilientSubscription<List<Map<String, dynamic>>>? _driverStream;
  String? _streamedDriverId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // State, not GPS: the delivery can flip to ARRIVED while the driver stands
    // still, and only the server knows when that happened.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _driverStream?.cancel();
    _simTimer?.cancel();
    super.dispose();
  }

  /// A phone that was in a pocket for ten minutes has a stale map. Re-read the
  /// delivery and, if there is still no GPS fix, put the simulated marker back
  /// on its path (the timer does not run while the app is suspended).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
    }
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
      // The order reached a terminal state: stop remembering it on this device,
      // so the next launch opens the dashboard instead of a finished delivery.
      final orderStatus = data['order_status'] as String?;
      if (orderStatus == 'COMPLETED' ||
          orderStatus == 'CANCELLED' ||
          orderStatus == 'REJECTED') {
        await ActiveOrderStore.clear();
      }
      _watchDriver(data['driver_provider_id'] as String?);
      _maybeStartSimulation(data);
      _recomputeProgress();
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
        final next = LatLng(point.lat, point.lng);
        final previous = _driverPosition;
        final heading = previous == null || previous == next
            ? _driverHeading
            : const Distance().bearing(previous, next);
        setState(() {
          _driverPosition = next;
          _driverHeading = heading;
          // A real fix wins over the simulated path, immediately.
          _simulated = false;
          _simTimer?.cancel();
          _simTimer = null;
        });
        _recomputeProgress();
      },
      onState: (_) {},
    );
  }

  /// No GPS from the driver (radio off, app backgrounded, a provider that has
  /// never published a fix). The buyer still deserves to see progress, so the
  /// marker walks a straight line toward the delivery point at ~27 km/h and
  /// the UI says it is approximate. This is code-marked simulation, not a
  /// claim of live tracking.
  void _maybeStartSimulation(Map<String, dynamic> data) {
    final destLat = (data['dest_lat'] as num?)?.toDouble();
    final destLng = (data['dest_lng'] as num?)?.toDouble();
    if (destLat == null || destLng == null) return;
    if (data['driver_provider_id'] == null) return;
    if (_driverPosition != null) return;
    if (_deliveryStatus == 'DELIVERED' || data['order_status'] == 'CANCELLED') {
      _simTimer?.cancel();
      return;
    }
    if (_simTimer != null) return;

    final dest = LatLng(destLat, destLng);
    // A deterministic start, ~1.3 km north of the drop-off, so the same order
    // looks the same after a restart rather than jumping around.
    _simPosition ??= LatLng(dest.latitude + 0.012, dest.longitude);
    _simulated = true;
    _simTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final current = _simPosition ?? dest;
      final metres =
          const Distance().as(LengthUnit.Meter, current, dest).toDouble();
      if (metres < 40) {
        _simTimer?.cancel();
        _simTimer = null;
        _recomputeProgress();
        return;
      }
      // ~15 m every two seconds.
      final fraction = (15.0 / metres).clamp(0.0, 1.0);
      setState(() {
        _simPosition = LatLng(
          current.latitude + (dest.latitude - current.latitude) * fraction,
          current.longitude + (dest.longitude - current.longitude) * fraction,
        );
      });
      _recomputeProgress();
    });
  }

  /// Distance and minutes left, from the trusted position. 22 km/h is a
  /// conservative city average; the number is labelled "about" on screen.
  void _recomputeProgress() {
    final destLat = (_data?['dest_lat'] as num?)?.toDouble();
    final destLng = (_data?['dest_lng'] as num?)?.toDouble();
    final pos = _driverPosition ?? _simPosition;
    if (pos == null || destLat == null || destLng == null) return;
    final km = const Distance()
        .as(LengthUnit.Kilometer, pos, LatLng(destLat, destLng))
        .toDouble();
    if (!mounted) return;
    setState(() {
      _distanceKm = km;
      _etaMinutes = km <= 0.05 ? 0 : ((km / 22.0) * 60).ceil();
    });
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
    // The real fix when there is one; the simulated path only while the
    // driver has never published one. The map and the ETA both read this, so
    // they can never disagree about where the vehicle is.
    final driverPos = _driverPosition ?? _simPosition;
    final cancelled = (_data!['order_status'] as String?) == 'CANCELLED';

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
              _statusCard(driverName, cancelled: cancelled),
              const SizedBox(height: 12),
              if (_distanceKm != null && !cancelled)
                _progressCard(),
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
                                    // A real marker points along its last two
                                    // fixes; the simulated one can only move
                                    // north/south along the drawn line, so that
                                    // is the only honest bearing for it.
                                    headingDegrees: !_simulated
                                        ? _driverHeading
                                        : (destLat == null
                                            ? null
                                            : (driverPos.latitude <= destLat
                                                ? 0
                                                : 180)),
                                  )
                                ],
                          routePoints: driverPos != null && destLat != null
                              ? [driverPos, LatLng(destLat, destLng ?? 0)]
                              : const [],
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

  /// "About 8 min · 3.1 km left". The wording is deliberately approximate:
  /// the line is a straight line and the speed is a city average, not a routed
  /// turn-by-turn ETA.
  Widget _progressCard() {
    final minutes = _etaMinutes ?? 0;
    final km = _distanceKm ?? 0;
    final arriving = minutes <= 1 || km <= 0.25;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.route_outlined,
              size: 16, color: AppTheme.primaryGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              arriving
                  ? 'Arriving now · ${km.toStringAsFixed(2)} km left'
                  : 'About $minutes min · ${km.toStringAsFixed(2)} km left',
              style: const TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
          if (_simulated)
            const Text(
              'APPROXIMATE',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.gold),
            ),
        ],
      ),
    );
  }

  Widget _statusCard(String driverName, {bool cancelled = false}) {
    final String headline;
    final String detail;
    final IconData icon;
    final Color color;
    if (cancelled) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.error.withOpacity(0.07),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.error.withOpacity(0.35)),
        ),
        child: const Row(
          children: [
            Icon(Icons.cancel_outlined, size: 18, color: AppTheme.error),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'This delivery was cancelled. Nothing is moving.',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }
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
