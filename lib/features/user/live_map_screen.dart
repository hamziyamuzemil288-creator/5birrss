import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/services/geocoding_service.dart';
import '../../core/services/guest_session.dart';
import '../../core/services/live_map_service.dart';
import '../../core/services/location_service.dart';
import '../../core/services/location_prompt.dart';
import '../../core/services/points_service.dart';
import '../../core/services/resilient_subscription.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/live_map.dart';
import '../../core/widgets/load_error_view.dart';
import '../../core/widgets/where_to_picker.dart';

/// Whether this map is being used to hail a ride or to find work.
enum LiveMapMode { rider, driver }

/// The live map screen: a real, interactive map of nearby vehicles that move
/// as their drivers do, with a ride-hailing style sheet on top.
///
/// The same widget serves riders and drivers. For a rider it answers "what is
/// around me and how do I book it"; for a driver it answers "am I online, and
/// where is the work" — the two halves of the product that this screen exists
/// to connect.
class LiveMapScreen extends ConsumerStatefulWidget {
  const LiveMapScreen({super.key, this.mode = LiveMapMode.rider});

  final LiveMapMode mode;

  @override
  ConsumerState<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends ConsumerState<LiveMapScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final MapController _map = MapController();
  final LiveMapService _service = LiveMapService();

  LatLng? _self;
  double? _accuracy;
  List<LiveMapVehicle> _vehicles = const [];
  List<LiveMapOpenRide> _openRides = const [];
  List<Map<String, dynamic>> _chips = const [];

  bool _loading = true;
  String? _loadError;
  RealtimeConnState _conn = RealtimeConnState.connecting;
  bool _sheetExpanded = false;
  bool _pickMode = false;
  bool _busyDestination = false;

  LatLng? _destination;
  String? _destinationLabel;

  /// "Bole, Addis Ababa" -- the area the rider is actually standing in.
  ///
  /// The map had no way to say this. It resolved the rider's position and
  /// used it for the marker, the camera and the nearby-vehicle query, and
  /// that was all -- so a rider who did not know the name of their own
  /// kebele had nothing to tell a driver. Resolved from the GPS fix, shown
  /// on the sheet, and never required: a failed lookup leaves it null.
  String? _areaLabel;

  /// The point [_areaLabel] was resolved for, so a position update does not
  /// re-hit the geocoder on every metre travelled.
  LatLng? _areaResolvedFor;

  /// Map | Nearby. The two questions this screen answers are "where am I and
  /// what is around me" and "what exactly is around me" -- and the second one
  /// used to be hidden behind dragging the sheet taller, which is a gesture
  /// nobody discovers and a fact nobody can act on without zooming out and
  /// counting pins. A tab says it is there.
  late final TabController _tabs =
      TabController(length: 2, vsync: this);

  /// Why there is no position, when there is none.
  ///
  /// Null means either "we have a fix" or "nothing has been tried yet", so it
  /// is cleared the moment a fix lands -- including one the user typed in by
  /// hand, which is why the typed location is stored beside it rather than
  /// in the same slot.
  LocationStatus? _locationProblem;

  /// A location the user typed instead of a GPS fix. Kept apart from [_self]
  /// so the map can keep saying which one it is showing: a hand-typed point
  /// drawn as a live pulsing dot would be a lie about where someone is.
  LatLng? _manualLocation;
  String? _manualLocationLabel;

  /// The phone's location settings have been opened once from this screen.
  ///
  /// Android hands control straight back to the app when the user comes back,
  /// so the screen needs to know it already asked; without this, every rebuild
  /// would re-launch the settings app and trap the user in a loop they cannot
  /// escape. One offer per visit, then the screen waits for them.
  bool _offeredSystemSettings = false;

  // Driver mode.
  String? _providerId;
  bool _driverApproved = false;
  bool _online = false;
  bool _togglingOnline = false;

  int _points = 0;

  Timer? _poll;
  Timer? _chipPoll;
  StreamSubscription<Position>? _posSub;
  ResilientSubscription<List<Map<String, dynamic>>>? _movement;
  ResilientSubscription<List<Map<String, dynamic>>>? _rides;

  bool get _isDriver => widget.mode == LiveMapMode.driver;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _chipPoll?.cancel();
    _posSub?.cancel();
    _movement?.cancel();
    _rides?.cancel();
    _tabs.dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _resolveSelf();
    if (!mounted) return;
    if (_self == null) {
      setState(() {
        _loading = false;
        _loadError = null;
      });
      // No fix is a state this screen now RECOVERS from rather than a dead
      // end: the map still draws, and the location panel offers the two
      // things that actually help -- turning the radio on, or saying where
      // you are in words. See _locationPanel().
      await _offerLocationRecovery();
      return;
    }

    setState(() {
      _loading = false;
      _loadError = null;
      _locationProblem = null;
    });

    await _loadChips();
    await _resolveArea(_self);
    if (_isDriver) await _loadDriverIdentity();
    await _refresh();
    _startPolling();
    _subscribeSignals();
    _watchSelf();
    _loadPoints();
  }

  /// The phone has no usable position. Open the OS location settings ONCE,
  /// unprompted, because that is the whole fix on both platforms and a
  /// second tap of the same kind is the thing people learn to dismiss.
  ///
  /// Not for a permission that was simply denied: the user said no at the
  /// dialog, and re-opening a settings page over that is nagging, not
  /// helping. Those two cases get the panel instead, which offers the same
  /// buttons without taking the screen away first.
  Future<void> _offerLocationRecovery() async {
    final problem = _locationProblem;
    if (problem == null) return;
    if (problem != LocationStatus.serviceDisabled) return;
    if (_offeredSystemSettings) return;
    _offeredSystemSettings = true;
    await LocationService.instance.openLocationSettings();
  }

  /// Re-read the position after the user says they have turned location on.
  Future<void> _retryLocation() async {
    setState(() => _loading = true);
    await _resolveSelf();
    if (!mounted) return;
    if (_self == null) {
      setState(() => _loading = false);
      return;
    }
    await _bootstrap();
  }

  /// "I am at Bole, near the airport" -- typed, because the GPS is off and
  /// cannot be turned on from inside an app.
  ///
  /// This is the half of the recovery that does not depend on the OS at all.
  /// Without it a driver whose location services are switched off cannot
  /// work from their phone at all; with it they can work, and the map is
  /// honest about the difference because the typed point is drawn as an
  /// ordinary pin rather than as the pulsing live dot.
  Future<void> _typeMyLocation() async {
    final centre = _self ?? _map.camera.center;
    final picked = await WhereToPicker.open(
      context,
      title: 'Where are you?',
      initialCenter: GeoPoint(centre.latitude, centre.longitude),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _manualLocation = LatLng(picked.lat, picked.lng);
      _manualLocationLabel = picked.label;
      _loading = false;
      _loadError = null;
    });
    _map.move(_manualLocation!, 16);
    await _bootstrap();
  }

  /// The rider's own GPS fix. `getCurrentPositionDetailed` already falls back
  /// to the OS's last known position when a fresh fix is not available, which
  /// is what lets the map centre itself indoors.
  Future<void> _resolveSelf() async {
    try {
      final result = await LocationService.instance.getCurrentPositionDetailed();
      final position = result.position;
      if (position != null) {
        _self = LatLng(position.latitude, position.longitude);
        _accuracy = position.accuracy;
        if (mounted) setState(() => _locationProblem = null);
        return;
      }
      // No position. Remember WHY, because "turn on location" and "allow
      // location" are different instructions sent to the same person, and a
      // screen that says only "no location" gets the wrong one tried.
      if (mounted) setState(() => _locationProblem = result.status);
    } catch (_) {
      // Non-fatal: the map still works, it just cannot centre on the user.
      if (mounted) setState(() => _locationProblem = LocationStatus.error);
    }
  }

  /// Resolve the small area around [point], at most once per ~1 km of
  /// travel.
  ///
  /// The distance gate matters: `watchPosition` fires every 25 m, and
  /// reverse-geocoding on every one of those would hammer a public Nominatim
  /// instance that allows one request per second and get the app
  /// rate-limited for it. A kebele does not change while a rider crosses
  /// one, so the work is repeated only when it could actually differ.
  Future<void> _resolveArea(LatLng? point) async {
    if (point == null) return;
    final last = _areaResolvedFor;
    if (last != null) {
      final moved = const Distance().as(LengthUnit.Meter, last, point);
      if (moved < 1000) return;
    }
    _areaResolvedFor = point;
    try {
      final rev = await GeocodingService.instance
          .reverseGeocode(point.latitude, point.longitude);
      if (!mounted) return;
      if (rev == null || !rev.hasArea) return;
      setState(() => _areaLabel = rev.areaLabel);
    } catch (_) {
      // Best-effort. The map works fine without the label.
    }
  }

  void _watchSelf() {
    _posSub = LocationService.instance.watchPosition(
      distanceFilter: 25,
      onData: (pos) {
        if (!mounted) return;
        final here = LatLng(pos.latitude, pos.longitude);
        setState(() {
          _self = here;
          _accuracy = pos.accuracy;
          _locationProblem = null;
        });
        _resolveArea(here);
        // A driver's own position is what makes them discoverable, so it is
        // pushed on the same cadence the map reads everyone else's.
        final id = _providerId;
        if (_isDriver && _online && id != null) {
          LocationService.instance
              .updateDriverLocation(id, pos.latitude, pos.longitude)
              .catchError((_) {});
        }
      },
    );
  }

  Future<void> _loadPoints() async {
    try {
      final points = await PointsService.instance.getMyPoints();
      if (mounted) setState(() => _points = points);
    } catch (_) {
      // The promo strip is decorative; never take the map down for it.
    }
  }

  Future<void> _loadChips() async {
    try {
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id,name,slug')
          .eq('is_active', true)
          .isFilter('parent_id', null)
          .order('sort_order')
          .limit(8);
      if (!mounted) return;
      setState(() {
        _chips = List<Map<String, dynamic>>.from(rows as List);
      });
    } catch (_) {
      // Shortcuts are a nicety; an empty row is better than an error banner.
    }
  }

  Future<void> _loadDriverIdentity() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;
      final row = await Supabase.instance.client
          .from('provider_profiles')
          .select('id,status')
          .eq('user_id', uid)
          .eq('provider_type', 'VEHICLE_PROVIDER')
          .maybeSingle();
      if (row == null) return;
      final status = await LocationService.instance.getDriverStatus(row['id'] as String);
      if (!mounted) return;
      setState(() {
        _providerId = row['id'] as String;
        _driverApproved = row['status'] == 'APPROVED';
        _online = (status?['is_online'] as bool?) ?? false;
      });
    } catch (_) {
      // Treated as "not a driver"; the sheet then explains how to become one.
    }
  }

  Future<void> _refresh() async {
    final self = _self;
    if (self == null) return;

    try {
      final vehicles = await _service.nearbyVehicles(
        lat: self.latitude,
        lng: self.longitude,
        previous: _vehicles,
      );
      if (!mounted) return;
      setState(() {
        _vehicles = vehicles;
        _loadError = null;
      });
    } catch (e) {
      if (mounted && _vehicles.isEmpty) {
        setState(() => _loadError = friendlyError(e, context: 'Could not load nearby vehicles'));
      }
    }

    // Driver mode additionally shows open work. A non-driver is refused by
    // the function itself, which is a normal answer rather than an error.
    if (_isDriver && _providerId != null) {
      try {
        final rides = await _service.openRidesNearby(lat: self.latitude, lng: self.longitude);
        if (mounted) setState(() => _openRides = rides);
      } catch (_) {
        if (mounted && _openRides.isNotEmpty) setState(() => _openRides = const []);
      }
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(LiveMapService.defaultRefreshInterval, (_) => _refresh());
    // Categories change rarely; four times a minute would be waste.
    _chipPoll?.cancel();
    _chipPoll = Timer.periodic(const Duration(minutes: 2), (_) => _loadChips());
  }

  void _subscribeSignals() {
    _movement?.cancel();
    _movement = _service.watchMovement(
      onSignal: _refresh,
      onState: (state) {
        if (mounted) setState(() => _conn = state);
      },
    );

    if (_isDriver) {
      _rides?.cancel();
      _rides = _service.watchOpenRides(
        onSignal: _refresh,
        onState: (_) {},
      );
    }
  }

  Future<void> _toggleOnline(bool value) async {
    final id = _providerId;
    if (id == null) return;
    setState(() => _togglingOnline = true);
    try {
      final self = _self;
      await LocationService.instance.setDriverOnline(
        id,
        value,
        lat: self?.latitude,
        lng: self?.longitude,
      );
      if (!mounted) return;
      setState(() {
        _online = value;
        _togglingOnline = false;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _togglingOnline = false);
      _snack(friendlyError(e, context: 'Could not change your availability'));
    }
  }

  void _recenter() {
    final self = _self ?? _manualLocation;
    if (self == null) {
      _snack('Waiting for a GPS fix');
      return;
    }
    _animateTo(self, 16);
  }

  /// One zoom step in or out, around whatever the camera is already looking
  /// at.
  ///
  /// Around the CURRENT centre rather than the user, deliberately: a zoom
  /// button that yanks the camera back to your own dot every time it is
  /// pressed is unusable while panning, which is the one thing a rider does
  /// with a map. The recentre button is where "go back to me" lives.
  void _zoomIn() => _zoomBy(1);

  void _zoomOut() => _zoomBy(-1);

  void _zoomBy(double steps) {
    final camera = _map.camera;
    final target = zoomTarget(camera.zoom, steps,
        minZoom: _minZoom, maxZoom: _maxZoom);
    if (target == camera.zoom) return;
    _animateTo(camera.center, target);
  }

  /// Bounds shared with [LiveMap] so the buttons grey out at exactly the
  /// levels the camera refuses to pass. 18 is the last zoom OpenStreetMap
  /// standard tiles are published for; past it the map is grey squares.
  static const double _minZoom = 3;
  static const double _maxZoom = 18;

  /// flutter_map's controller moves instantly. A short tween reads as the
  /// app following you rather than as the map jumping under you.
  Future<void> _animateTo(LatLng target, double zoom) async {
    final start = _map.camera.center;
    final startZoom = _map.camera.zoom;
    const steps = 14;
    for (var i = 1; i <= steps; i++) {
      if (!mounted) return;
      final t = Curves.easeOutCubic.transform(i / steps);
      _map.move(
        LatLng(
          start.latitude + (target.latitude - start.latitude) * t,
          start.longitude + (target.longitude - start.longitude) * t,
        ),
        startZoom + (zoom - startZoom) * t,
      );
      await Future<void>.delayed(const Duration(milliseconds: 22));
    }
  }

  /// Opens the SHARED "Where to?" picker.
  ///
  /// This used to open `_DestinationSearchSheet`, a private second copy of the
  /// same idea that lived only here. Two things it could not do, and both were
  /// reported: it had no NEARBY-AREAS list (so "the where button is on the
  /// request page but not on the map"), and it had no GPS action of its own,
  /// relying on the map beneath it instead. One picker, reached from both
  /// screens, is the only way those two surfaces can stay in step.
  Future<void> _openDestinationSearch() async {
    // Bias to the rider's fix when there is one, otherwise to whatever the map
    // is currently looking at, so the nearby list describes where the sheet
    /// opened rather than always the same city centre.
    final centre = _self ?? _map.camera.center;
    final picked = await WhereToPicker.open(
      context,
      title: 'Where to?',
      initialCenter: GeoPoint(centre.latitude, centre.longitude),
    );
    if (picked != null) _setDestination(LatLng(picked.lat, picked.lng), picked.label);
  }

  Future<void> _confirmPickedCentre() async {
    final centre = _map.camera.center;
    setState(() => _busyDestination = true);
    String? label;
    try {
      final resolved = await GeocodingService.instance
          .reverseGeocode(centre.latitude, centre.longitude);
      label = resolved?.address;
    } catch (_) {
      // A dropped pin is still a valid destination without a street name.
    }
    if (!mounted) return;
    setState(() => _busyDestination = false);
    _setDestination(centre, label ?? 'Pinned location');
  }

  void _setDestination(LatLng point, String label) {
    setState(() {
      _destination = point;
      _destinationLabel = label;
      _pickMode = false;
      _sheetExpanded = true;
    });
  }

  Future<void> _startRideRequest() async {
    final dest = _destination;
    if (dest == null) return;
    // GUEST INTERCEPTION — the map is a guest-open surface and this button
    // starts a transaction. Same dialog as Buy/Book: explain, then the
    // standard user registration. The router's transaction gate stays as
    // the safety net for any path this misses.
    if (ref.read(guestModeProvider)) {
      await requestAccountToContinue(context, action: 'request a ride');
      return;
    }
    context.push('/user/ride-request', extra: {
      'label': _destinationLabel,
      'lat': dest.latitude,
      'lng': dest.longitude,
    });
  }

  void _openSafetyCenter() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SafetyCenterSheet(),
    );
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final self = _self;
    final center = self ?? const LatLng(9.0108, 38.7613); // Addis Ababa

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(context),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryGreen))
          : _loadError != null && _vehicles.isEmpty
              ? LoadErrorView(message: _loadError!, onRetry: _bootstrap)
              : Stack(
                  children: [
                    LiveMap(
                      mapController: _map,
                      center: center,
                      zoom: 15,
                      vehicles: _vehicles,
                      openRides: _isDriver && _online ? _openRides : const [],
                      selfPosition: self,
                      selfAccuracyMeters: _accuracy,
                      handTypedPoint: _manualLocation,
                      handTypedLabel: _manualLocationLabel,
                      destinationPoint: _destination,
                      onRecenter: _recenter,
                      onZoomIn: _zoomIn,
                      onZoomOut: _zoomOut,
                      minZoom: _minZoom,
                      maxZoom: _maxZoom,
                      onTapMap: _pickMode ? (_) {} : null,
                      overlayBottomInset: _sheetExpanded ? 250 : 170,
                    ),
                    if (_self == null) _locationPanel(),
                    _buildTopBar(),
                    if (_pickMode) _buildPickModeBar(),
                    _buildSheet(),
                  ],
                ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: MediaQuery.of(context).padding.top + 10,
      left: 12,
      right: 12,
      child: Row(
        children: [
          _MapPill(
            icon: Icons.menu,
            label: null,
            onTap: () => _scaffoldKey.currentState?.openDrawer(),
            tooltip: 'Menu',
          ),
          const SizedBox(width: 8),
          _ConnectionPill(state: _conn, vehicles: _vehicles.length),
          const Spacer(),
          _MapPill(
            icon: Icons.shield_outlined,
            label: 'Safety',
            onTap: _openSafetyCenter,
            tooltip: 'Safety Center',
          ),
        ],
      ),
    );
  }

  Widget _buildPickModeBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.of(context).size.height * 0.42,
      child: Column(
        children: [
          const Icon(Icons.add_location_alt, size: 42, color: AppTheme.primaryGreenDark),
          const SizedBox(height: 110),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 10)],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Drag the map to your destination',
                    style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                  ),
                ),
                _SheetButton(
                  label: _busyDestination ? 'Saving…' : 'Set',
                  onPressed: _busyDestination ? null : _confirmPickedCentre,
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => setState(() => _pickMode = false),
                  child: const Text('Cancel'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSheet() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * (_sheetExpanded ? 0.62 : 0.34),
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 18, offset: Offset(0, -4))],
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + MediaQuery.of(context).padding.bottom),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: GestureDetector(
                  onTap: () {
                    setState(() => _sheetExpanded = !_sheetExpanded);
                    // Dragging the sheet taller used to reveal the nearby
                    // list. It now lives in its own tab, and the gesture
                    // keeps meaning the same thing by taking you there.
                    if (_sheetExpanded) _tabs.animateTo(1);
                  },
                  child: Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: AppTheme.cardBorder,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _tabBar(),
              const SizedBox(height: 12),
              if (_tabs.index == 0)
                if (_isDriver) ..._driverSheet() else ..._riderSheet()
              else
                _nearbyTab(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _riderSheet() {
    return [
      Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _openDestinationSearch,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 19, color: AppTheme.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _destinationLabel ?? 'Where to?',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          color: _destinationLabel == null
                              ? AppTheme.textMuted
                              : AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Pick on the map',
            child: Material(
              color: AppTheme.primaryGreen.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _pickMode = !_pickMode),
                child: const SizedBox(
                  width: 48,
                  height: 48,
                  child: Icon(Icons.add_location_alt_outlined, color: AppTheme.primaryGreen),
                ),
              ),
            ),
          ),
        ],
      ),
      if (_destination != null) ...[
        const SizedBox(height: 10),
        _SheetButton(
          label: 'Find a ride to this destination',
          onPressed: _startRideRequest,
          expanded: true,
        ),
      ],
      // The rider's own area, when the geocoder could name it. Null
      // otherwise -- see _areaPanel.
      if (_areaPanel() case final panel?) panel,
      const SizedBox(height: 12),
      _chipRow(),
      const SizedBox(height: 12),
      const _TrustBanner(),
      const SizedBox(height: 8),
      _pointsBanner(),
    ];
  }

  /// Map | Nearby.
  ///
  /// A real [TabBar], not two buttons that look like one: the selection is
  /// announced to accessibility services, the tabs are reachable by keyboard,
  /// and the indicator animates. The label carries the count, because "is
  /// anything actually around me" is the question the tab exists to answer
  /// and an empty list alone does not tell a rider whether to wait.
  Widget _tabBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabs,
        onTap: (_) => setState(() {}),
        labelColor: AppTheme.primaryGreenDark,
        unselectedLabelColor: AppTheme.textSecondary,
        indicatorColor: AppTheme.primaryGreen,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(
          fontSize: 13.5,
          fontWeight: FontWeight.w700,
        ),
        tabs: [
          const Tab(text: 'Map', icon: Icon(Icons.map_outlined, size: 17)),
          Tab(
            text: _isDriver
                ? 'Nearby (${_openRides.length})'
                : 'Nearby (${_vehicles.length})',
            icon: const Icon(Icons.near_me_outlined, size: 17),
          ),
        ],
      ),
    );
  }

  /// The Nearby tab. Riders get what is moving around them; a driver gets the
  /// open requests, which is the same question asked of a different side of
  /// the market.
  Widget _nearbyTab() {
    if (_isDriver) return _driverNearbyTab();
    return _nearbyList();
  }

  Widget _driverNearbyTab() {
    if (_openRides.isEmpty) {
      return const Text(
        'No open ride requests within range right now.',
        style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Open requests nearby (${_openRides.length})',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        _SheetButton(
          label: 'Open the request queue',
          onPressed: () => context.push('/vehicle/ride-requests'),
          expanded: true,
        ),
        const SizedBox(height: 8),
        Text(
          'Ride requests appear here as riders ask for them. Pull the queue '
          'to accept one.',
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.4,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  /// The no-position state, laid over the map rather than replacing it.
  ///
  /// The map draws perfectly well without a centre -- the city is still there
  /// -- so replacing it with an error screen took away the one thing that
  /// helps someone work out where they are. Two buttons, and both of them do
  /// something: switch the radio on, or say where you are instead.
  Widget _locationPanel() {
    final problem = _locationProblem;
    final needsSettings = LocationMessages.needsSettings(
      problem ?? LocationStatus.serviceDisabled,
    );

    return Positioned(
      left: 16,
      right: 16,
      top: MediaQuery.of(context).padding.top + 62,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.14),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_off_outlined,
                    color: AppTheme.primaryGreen, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    LocationMessages.forStatus(
                      problem ?? LocationStatus.serviceDisabled,
                    ),
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _retryLocation,
                    icon: const Icon(Icons.my_location, size: 17),
                    label: Text(needsSettings ? 'Retry' : 'Try again'),
                  ),
                ),
                if (needsSettings) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await LocationService.instance.openLocationSettings();
                        if (mounted) await _retryLocation();
                      },
                      icon: const Icon(Icons.settings_outlined, size: 17),
                      label: const Text('Phone settings'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: _typeMyLocation,
                icon: const Icon(Icons.edit_location_alt_outlined, size: 17),
                label: const Text('Type where I am instead'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "You are in <area>" -- the nearest small area to the rider, plus the
  /// nearest ones as one-tap chips.
  ///
  /// Rendered only when a label actually resolved. A blank or "unknown"
  /// area is worse than nothing: it tells the rider the app cannot see where
  /// they are when in fact it simply has no name for it.
  Widget? _areaPanel() {
    if (_areaLabel == null) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openDestinationSearch(),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreen.withOpacity(0.07),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.22)),
          ),
          child: Row(
            children: [
              const Icon(Icons.my_location,
                  size: 18, color: AppTheme.primaryGreenDark),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('You are in',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textSecondary)),
                    Text(
                      _areaLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.search,
                  size: 18, color: AppTheme.primaryGreenDark),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _driverSheet() {
    return [
      if (!_driverApproved)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.warning.withOpacity(0.10),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Text(
            'Your vehicle provider account is not approved yet. Once it is, going online here puts you on the map.',
            style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
          ),
        )
      else
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _online ? 'You are online' : 'You are offline',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _online
                        ? 'Riders nearby can see your vehicle moving on the map.'
                        : 'Go online to appear on the map and receive ride requests.',
                    style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
            if (_togglingOnline)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryGreen),
              )
            else
              Switch(
                value: _online,
                activeColor: AppTheme.primaryGreen,
                onChanged: _toggleOnline,
              ),
          ],
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          const Icon(Icons.local_taxi_outlined, size: 18, color: AppTheme.primaryGreen),
          const SizedBox(width: 8),
          Text(
            _openRides.isEmpty
                ? 'No open ride requests nearby'
                : '${_openRides.length} open ride request${_openRides.length == 1 ? '' : 's'} nearby',
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      if (_openRides.isNotEmpty) ...[
        const SizedBox(height: 10),
        _SheetButton(
          label: 'Open the request queue',
          onPressed: () => context.push('/vehicle/ride-requests'),
          expanded: true,
        ),
      ],
      const SizedBox(height: 12),
      _chipRow(),
      const SizedBox(height: 12),
      const _TrustBanner(),
    ];
  }

  Widget _chipRow() {
    if (_chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _chips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final chip = _chips[i];
          final name = (chip['name'] as String?) ?? 'Category';
          return ActionChip(
            avatar: Icon(
              _chipIcon(chip['slug'] as String?, name),
              size: 16,
              color: AppTheme.primaryGreen,
            ),
            label: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            visualDensity: VisualDensity.compact,
            backgroundColor: AppTheme.primaryGreen.withOpacity(0.06),
            side: BorderSide(color: AppTheme.primaryGreen.withOpacity(0.28)),
            labelStyle: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary),
            onPressed: () => context.push('/user/category/${chip['id']}'),
          );
        },
      ),
    );
  }

  Widget _pointsBanner() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => context.push('/points'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AppTheme.gold.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.gold.withOpacity(0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.stars_rounded, size: 20, color: AppTheme.gold),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _points <= 0
                    ? 'Earn points on every completed ride — convert them to wallet cash'
                    : '$_points points — convertible to wallet cash',
                style: const TextStyle(fontSize: 12.5, color: AppTheme.textPrimary),
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: AppTheme.textMuted),
          ],
        ),
      ),
    );
  }

  Widget _nearbyList() {
    if (_vehicles.isEmpty) {
      return const Text(
        'No vehicles online in range right now.',
        style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Nearby (${_vehicles.length})',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        ..._vehicles.take(8).map((v) {
          final style = vehicleMarkerStyle(
            categorySlug: v.categorySlug,
            categoryName: v.categoryName,
            providerType: v.providerType,
          );
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: style.color.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(style.icon, size: 17, color: style.color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        v.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                      ),
                      Text(
                        v.onRide ? '${style.label} • on a trip' : style.label,
                        style: const TextStyle(fontSize: 11.5, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                Text(
                  v.secondsSinceFix < 60
                      ? '${v.secondsSinceFix}s ago'
                      : '${(v.secondsSinceFix / 60).floor()}m ago',
                  style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final auth = ref.watch(authProvider);
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: const BoxDecoration(color: AppTheme.primaryGreen),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.map_outlined, color: Colors.white),
                      const SizedBox(width: 8),
                      Text(
                        _isDriver ? 'Driver map' : 'Live map',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isDriver
                        ? '${_openRides.length} open request${_openRides.length == 1 ? '' : 's'} in range'
                        : '${_vehicles.length} vehicles moving nearby',
                    style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            _drawerTile(context, Icons.home_outlined, 'Home', '/user'),
            _drawerTile(context, Icons.search, 'Search', '/user/search'),
            if (!_isDriver)
              _drawerTile(context, Icons.directions_car_outlined, 'Request a ride', '/user/ride-request',
                  onTap: () async {
                Navigator.of(context).pop();
                // GUEST INTERCEPTION — same rule as the map's own ride CTA.
                if (ref.read(guestModeProvider)) {
                  await requestAccountToContinue(this.context,
                      action: 'request a ride');
                  return;
                }
                context.push('/user/ride-request');
              }),
            if (!_isDriver)
              _drawerTile(context, Icons.history, 'Ride history', '/user/ride-history'),
            _drawerTile(context, Icons.account_balance_wallet_outlined, 'Wallet', '/wallet'),
            _drawerTile(context, Icons.stars_rounded, 'Points & rank', '/points'),
            _drawerTile(context, Icons.person_outline, 'Profile', '/profile'),
            const Divider(),
            if (auth.isVehicleProvider) ...[
              _drawerTile(context, Icons.local_taxi_outlined, 'My vehicles', '/vehicle/vehicles'),
              _drawerTile(context, Icons.inbox_outlined, 'Ride requests', '/vehicle/ride-requests'),
              _drawerTile(context, Icons.map_outlined, 'Driver map', '/vehicle/map'),
            ],
            if (auth.isProvider && !auth.isVehicleProvider)
              _drawerTile(context, Icons.storefront_outlined, 'Provider orders', '/provider/orders'),
            if (auth.isAdmin) ...[
              const Divider(),
              _drawerTile(context, Icons.admin_panel_settings_outlined, 'Admin panel', '/admin'),
              _drawerTile(context, Icons.payments_outlined, 'Fees & pricing', '/admin/fees'),
            ],
            const Divider(),
            _drawerTile(context, Icons.shield_outlined, 'Safety Center', null, onTap: () {
              Navigator.of(context).pop();
              _openSafetyCenter();
            }),
            _drawerTile(context, Icons.help_outline, 'Help & support', '/help'),
          ],
        ),
      ),
    );
  }

  Widget _drawerTile(BuildContext context, IconData icon, String label, String? route,
      {VoidCallback? onTap}) {
    return ListTile(
      leading: Icon(icon, color: AppTheme.primaryGreen),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: onTap ??
          () {
            Navigator.of(context).pop();
            if (route != null) context.push(route);
          },
    );
  }
}

/// A pill floating over the map.
class _MapPill extends StatelessWidget {
  const _MapPill({required this.icon, this.label, this.onTap, this.tooltip});

  final IconData icon;
  final String? label;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final content = Material(
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: label == null ? 11 : 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 19, color: AppTheme.primaryGreenDark),
              if (label != null) ...[
                const SizedBox(width: 7),
                Text(
                  label!,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.primaryGreenDark,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? content : Tooltip(message: tooltip!, child: content);
  }
}

/// Live-refresh state and the number of vehicles currently drawn.
class _ConnectionPill extends StatelessWidget {
  const _ConnectionPill({required this.state, required this.vehicles});

  final RealtimeConnState state;
  final int vehicles;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      RealtimeConnState.live => (AppTheme.success, 'Live'),
      RealtimeConnState.connecting => (AppTheme.info, 'Connecting'),
      RealtimeConnState.retrying => (AppTheme.warning, 'Reconnecting'),
      RealtimeConnState.offline => (AppTheme.textMuted, 'Polling'),
    };

    return Material(
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              '$label • $vehicles',
              style: const TextStyle(fontSize: 12, color: AppTheme.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustBanner extends StatelessWidget {
  const _TrustBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppTheme.primaryGreen.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.primaryGreen.withOpacity(0.18)),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_user_outlined, size: 19, color: AppTheme.primaryGreen),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Verified providers, secure trades',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryGreenDark,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Safety Center: only real, wired actions. An emergency dialler, the support
/// desk that exists, and this account's live trip if there is one.
class _SafetyCenterSheet extends StatelessWidget {
  const _SafetyCenterSheet();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(18, 18, 18, 18 + MediaQuery.of(context).padding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: AppTheme.primaryGreen),
              const SizedBox(width: 8),
              const Text('Safety Center',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'If you are in immediate danger, call emergency services first.',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('tel:911'),
                    mode: LaunchMode.externalApplication,
                  ).catchError((_) => false),
                  icon: const Icon(Icons.phone, size: 18),
                  label: const Text('Emergency 911'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                    side: const BorderSide(color: AppTheme.error),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.directions_car_outlined, color: AppTheme.primaryGreen),
            title: const Text('My active ride', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Share or check your current trip',
                style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/user/ride-active');
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.report_problem_outlined, color: AppTheme.primaryGreen),
            title: const Text('Report a problem', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Support ticket, with your trip attached',
                style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/help');
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.gavel_outlined, color: AppTheme.primaryGreen),
            title: const Text('Appeals', style: TextStyle(fontSize: 14)),
            subtitle: const Text('Contest a decision on your account',
                style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.of(context).pop();
              context.push('/appeals');
            },
          ),
        ],
      ),
    );
  }
}

/// Small filled button, matching the app's primary action styling.
class _SheetButton extends StatelessWidget {
  const _SheetButton({required this.label, this.onPressed, this.expanded = false});

  final String label;
  final VoidCallback? onPressed;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final button = ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppTheme.primaryGreen,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
    );
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Category slug/name -> shortcut icon, for the chips on the sheet.
IconData _chipIcon(String? slug, String name) {
  final haystack = '${slug ?? ''} $name'.toLowerCase();
  bool has(List<String> k) => k.any(haystack.contains);

  if (has(const ['vehicle', 'ride', 'transport', 'car', 'taxi'])) return Icons.directions_car_outlined;
  if (has(const ['food', 'restaurant', 'cafe', 'grocery', 'market'])) return Icons.restaurant_outlined;
  if (has(const ['shop', 'store', 'retail'])) return Icons.storefront_outlined;
  if (has(const ['electronic', 'phone', 'laptop'])) return Icons.devices_other_outlined;
  if (has(const ['service', 'repair', 'maintenance'])) return Icons.handyman_outlined;
  if (has(const ['health', 'pharmacy', 'medical'])) return Icons.local_pharmacy_outlined;
  if (has(const ['property', 'house', 'rent'])) return Icons.home_work_outlined;
  if (has(const ['job', 'work', 'employ'])) return Icons.work_outline;
  return Icons.category_outlined;
}
