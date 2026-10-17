import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:postgrest/postgrest.dart' show CountOption;
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/location_service.dart';
import '../../core/services/location_prompt.dart';
import '../../core/services/points_service.dart';
import '../../core/services/rank_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/rank_badge.dart';
import '../../core/widgets/dashboard_top_tabs.dart';
import '../../core/widgets/quick_action_pill.dart';
import '../user/user_profile_screen.dart' show AccountDashboard;

class VehicleProviderDashboard extends ConsumerStatefulWidget {
  const VehicleProviderDashboard({super.key});
  @override
  ConsumerState<VehicleProviderDashboard> createState() =>
      _VehicleProviderDashboardState();
}

class _VehicleProviderDashboardState
    extends ConsumerState<VehicleProviderDashboard>
    with WidgetsBindingObserver {
  Map<String, dynamic>? _providerProfile;
  Map<String, dynamic>? _driverStatus;
  int _vehicleCount = 0;
  int _points = 0;
  RankProgress? _rankProgress;
  double? _walletBalance;
  bool _loading = true;
  String? _error;
  final bool _togglingOnline = false;
  StreamSubscription? _posSub;

  @override
  void initState() {
    super.initState();
    // The user leaves for the OS location settings and comes back. That is
    // the single most likely moment for the location state to have changed,
    // and it is the moment the driver is least willing to do anything else,
    // so re-check on resume rather than making them toggle again.
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      final client = Supabase.instance.client;
      final userId = client.auth.currentUser?.id;
      if (userId == null) return;
      final prov = await client
          .from('provider_profiles')
          .select()
          .eq('user_id', userId)
          .eq('provider_type', 'VEHICLE_PROVIDER')
          .maybeSingle();
      if (prov == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final vehicles = await client
          .from('vehicles')
          .select('id')
          .eq('provider_id', prov['id'])
          .count(CountOption.exact);
      final status = await client
          .from('driver_status')
          .select()
          .eq('provider_id', prov['id'])
          .maybeSingle();
      final points =
          await PointsService.instance.getProviderPoints(prov['id'] as String);
      // Ladder from the server; best-effort so a rank hiccup never blocks the
      // dashboard itself.
      RankProgress? progress;
      try {
        progress = await RankService.instance.progressForPoints(points);
      } catch (_) {
        progress = null;
      }
      final wallet = await client
          .from('wallets')
          .select('balance')
          .eq('provider_id', prov['id'])
          .maybeSingle();
      if (mounted) {
        setState(() {
          _providerProfile = prov;
          _vehicleCount = vehicles.count;
          _driverStatus = status;
          _points = points;
          _rankProgress = progress;
          _walletBalance = (wallet?['balance'] as num?)?.toDouble();
          _loading = false;
          _error = null;
        });
      }
      // Resume GPS pushes for an already-online driver. Updates used to start
      // ONLY from the online toggle, so reopening the dashboard (or restarting
      // the app) while online left the driver shown as online but frozen at
      // their last fix — the rider could not track them.
      if ((status?['is_online'] ?? false) == true && _posSub == null) {
        _startLocationUpdates(prov['id'] as String);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e, context: 'Could not load your dashboard');
        });
      }
    }
  }

  /// The availability switch is now an entrance to the map, not a second,
  /// parallel way of going online.
  ///
  /// It used to prompt, then bounce the driver out to the OS settings app, then
  /// try to dispatch them from whatever fix the phone happened to have. Three
  /// places to fix one problem, and the failure the driver actually hit --
  /// "I turned location on and nothing happened" -- was invisible here
  /// because the fix happened somewhere else.
  ///
  /// The map is where the position, the nearby work and the same switch all
  /// live, and it recovers from a missing fix in place: it opens the phone's
  /// location settings itself, and if the radio cannot be turned on at all it
  /// offers to take the driver's location in words so they can still work.
  Future<void> _toggleOnline() async {
    if (_providerProfile == null) return;
    await context.push('/vehicle/map');
    if (!mounted) return;
    // Re-read on the way back: the driver may have gone online, opened the
    // phone settings, or typed their location while they were over there.
    _load();
  }

  void _startLocationUpdates(String providerId) {
    _posSub?.cancel();
    // watchPosition self-heals: a GPS hiccup mid-shift must not close the
    // stream (the raw geolocator stream would) — it retries automatically.
    _posSub = LocationService.instance.watchPosition(
      distanceFilter: 100,
      onError: () {},
      onData: (pos) {
        LocationService.instance
            .updateDriverLocation(providerId, pos.latitude, pos.longitude);
      },
    );
  }

  /// The live location state, kept so the dashboard can show a quiet hint
  /// while the driver is available without a fix. Null means there is
  /// nothing to say.
  LocationStatus? _locationHint;

  /// Re-checks location and clears the hint when it is healthy.
  ///
  /// Called on resume as well as from the hint's own button, so returning
  /// from the OS location settings updates the state without the driver
  /// having to toggle anything again.
  Future<void> _checkLocation() async {
    final r = await LocationService.instance.getCurrentPositionDetailed();
    if (!mounted) return;
    setState(() {
      if (r.success) {
        _locationHint = null;
      } else {
        _locationHint = r.status;
      }
    });
    if (r.success && _providerProfile?['id'] != null && _isOnline) {
      _startLocationUpdates(_providerProfile!['id']);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkLocation();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _posSub?.cancel();
    super.dispose();
  }

  bool get _isOnline => _driverStatus?['is_online'] ?? false;

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Aliob Transport'),
        actions: [
          // Task 7 item 2: real notification inbox (admin broadcasts land
          // here), not a placeholder snackbar.
          IconButton(
              icon: const Icon(Icons.notifications_outlined),
              onPressed: () => context.push('/admin-notifications')),
          IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () => ref.read(authProvider.notifier).signOut()),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.teal))
          : _error != null
              ? LoadErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header with online toggle
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                            colors: _isOnline
                                ? [AppTheme.teal, const Color(0xFF00695C)]
                                : [AppTheme.textMuted, AppTheme.textSecondary]),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        _providerProfile?['business_name'] ??
                                            auth.profile?.fullName ??
                                            'Provider',
                                        style: const TextStyle(
                                            fontSize: 20,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white)),
                                    const SizedBox(height: 4),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                          (_providerProfile?['status'] ??
                                                  'UNKNOWN')
                                              .replaceAll('_', ' '),
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.white)),
                                    ),
                                  ],
                                ),
                              ),
                              // Online/offline toggle
                              GestureDetector(
                                onTap: _togglingOnline ? null : _toggleOnline,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: _togglingOnline
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: Colors.white))
                                      : Text(_isOnline ? 'ONLINE' : 'OFFLINE',
                                          style: const TextStyle(
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                              color: Colors.white)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    // The one shortcut this role opens most. A vehicle
                    // provider's whole shift is claiming rides, so the feed is
                    // the shortcut -- deliberately NOT the service provider's
                    // "My Gallery", and not "My Vehicles" either: the fleet
                    // changes a few times a month, the ride feed several times
                    // an hour. Live Map is the near neighbour and stays in the
                    // Drive tab; this is the action that earns money, so it is
                    // the one that gets the pill.
                    //
                    // Additive, not a move: the Drive tab entry stays.
                    QuickActionPill(
                      icon: Icons.local_taxi_outlined,
                      label: 'Ride Requests',
                      onTap: () => context.push('/vehicle/ride-requests'),
                    ),
                    const SizedBox(height: 20),
                    // Rank: the business's standing on the loyalty ladder. A
                    // trust signal only — nothing is gated on it.
                    RankProgressCard(
                      points: _points,
                      progress: _rankProgress,
                      subjectLabel: 'Business',
                      onTap: () => context.push('/points'),
                    ),
                    const SizedBox(height: 20),
                    // Wallet balance strip
                    _walletCard(),
                    const SizedBox(height: 20),
                    // Stats
                    Row(
                      children: [
                        _stat(
                            Icons.directions_car, 'Vehicles', '$_vehicleCount'),
                        const SizedBox(width: 12),
                        _stat(Icons.stars_rounded, 'Points', '$_points'),
                        const SizedBox(width: 12),
                        _stat(Icons.star_outline, 'Rating', '0.0'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    // Grouped per the founder's top-tab sketch: the
                    // shift-related work a driver opens several times a shift
                    // is separated from fleet management and account setup.
                    // Same entries, same destinations, same screens.
                    DashboardTopTabs(
                      tabs: [
                        DashboardTab(
                          label: 'Drive',
                          icon: Icons.map_outlined,
                          builder: (_) => Column(
                            children: [
                              _action(Icons.map_outlined, 'Live Map',
                                  () => context.push('/vehicle/map')),
                              _action(Icons.local_taxi_outlined, 'Ride Requests',
                                  () => context.push('/vehicle/ride-requests')),
                              _action(Icons.play_circle_outline, 'Active Trip',
                                  () => context.push('/vehicle/trip')),
                              _action(Icons.history, 'Ride History',
                                  () => context.push('/vehicle/history')),
                            ],
                          ),
                        ),
                        DashboardTab(
                          label: 'Fleet',
                          icon: Icons.directions_car_outlined,
                          builder: (_) => Column(
                            children: [
                              _action(Icons.directions_car_outlined,
                                  'Manage Vehicles',
                                  () => context.push('/vehicle/vehicles')),
                              _action(Icons.add_circle_outline, 'Add Vehicle',
                                  () => context.push('/vehicle/vehicles/new')),
                            ],
                          ),
                        ),
                        // The SAME account dashboard a buyer gets — see
                        // [AccountDashboard]. The other tabs are unchanged.
                        DashboardTab(
                          label: 'Account',
                          icon: Icons.person_outline,
                          builder: (_) => const AccountDashboard(
                            embedded: true,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                        DashboardTab(
                          label: 'Shop',
                          icon: Icons.shopping_bag_outlined,
                          builder: (_) => Column(
                            children: [
                              // Buyer mode: vehicle providers can shop from
                              // service providers using the regular user
                              // experience while keeping this dashboard.
                              _action(Icons.shopping_bag_outlined,
                                  'Browse & Shop', () => context.push('/user')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// Compact wallet balance strip: balance at a glance + one-tap recharge.
  Widget _walletCard() {
    final balance = _walletBalance ?? 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.teal.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.account_balance_wallet_outlined,
                color: AppTheme.teal, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Wallet Balance',
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text('${balance.toStringAsFixed(2)} ETB',
                    style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary)),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => context.push('/wallet/recharge'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Recharge',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: TextButton.styleFrom(foregroundColor: AppTheme.teal),
          ),
        ],
      ),
    );
  }

  Widget _stat(IconData icon, String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),                child: Column(
                  children: [
                    // Persistent location hint. Present only after a driver
                    // went available without a fix, and worded as a
                    // LOCATION problem - the whole point of this bar is that
                    // "Not now" leaves an explanation behind rather than
                    // silence, without turning into a nagging dialog.
                    if (_locationHint != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: LocationHintBar(
                          status: _locationHint!,
                          onOpenSettings: () async {
                            if (LocationMessages.needsSettings(_locationHint!)) {
                              await LocationService.instance
                                  .openLocationSettings();
                            }
                            _checkLocation();
                          },
                          onDismiss: () => setState(() => _locationHint = null),
                        ),
                      ),
            Icon(icon, color: AppTheme.teal, size: 22),
            const SizedBox(height: 6),
            Text(value,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            Text(label,
                style:
                    const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback? onTap) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: AppTheme.teal),
        title: Text(label,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        trailing: const Icon(Icons.chevron_right,
            color: AppTheme.textMuted, size: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        tileColor: AppTheme.surface,
      ),
    );
  }
}
