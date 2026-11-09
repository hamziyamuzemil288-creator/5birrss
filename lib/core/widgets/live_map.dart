import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/live_map_service.dart';
import '../theme/app_theme.dart';
import 'map_tile_layer.dart';

/// A live, animated map of moving vehicles.
///
/// Movement is interpolated between the fixes the server reports rather than
/// snapped to them: a marker glides from where it was to where it now is,
/// keeps pointing the way it was last seen travelling, and — when it was
/// actually moving — continues along that heading until the next fix arrives.
/// Without this, an 8-second poll looks like a slideshow of teleporting pins.
///
/// Everything that moves is driven by one [Ticker], repainted at ~30 fps.
/// A per-marker animation controller would mean one vsync callback per
/// vehicle on screen; on a busy street that is dozens of them, for the same
/// result.
class LiveMap extends StatefulWidget {
  const LiveMap({
    super.key,
    required this.center,
    this.zoom = 15,
    this.mapController,
    this.vehicles = const [],
    this.openRides = const [],
    this.selfPosition,
    this.selfAccuracyMeters,
    this.handTypedPoint,
    this.handTypedLabel,
    this.pickupPoint,
    this.destinationPoint,
    this.routePoints = const [],
    this.showRecenter = true,
    this.recenterLabel = 'My location',
    this.onRecenter,
    this.onZoomIn,
    this.onZoomOut,
    this.minZoom = 3,
    this.maxZoom = 18,
    this.onMapReady,
    this.onCameraChanged,
    this.onTapMap,
    this.maxVehicles = 60,
    this.overlayBottomInset = 0,
  });

  final LatLng center;
  final double zoom;

  /// Supply one when the caller needs to move the camera itself (recentring
  /// on a GPS fix, pick mode). One is created internally otherwise.
  final MapController? mapController;

  final List<LiveMapVehicle> vehicles;
  final List<LiveMapOpenRide> openRides;

  /// The signed-in user's own position. Drawn as a pulsing dot, which is what
  /// makes "you" instantly distinguishable from the traffic around you.
  final LatLng? selfPosition;
  final double? selfAccuracyMeters;

  /// Where the user SAYS they are, when GPS could not tell us.
  ///
  /// Deliberately not [selfPosition]. The pulsing live dot means "the phone
  /// knows where you are, to within this many metres", and drawing a typed
  /// address in that same dot would claim a precision nobody has -- and would
  /// put a placeholder in the middle of a traffic map as though it were a
  /// real fix. Amber pin with a label instead.
  final LatLng? handTypedPoint;
  final String? handTypedLabel;

  final LatLng? pickupPoint;
  final LatLng? destinationPoint;

  /// The line a tracked delivery (or ride) is following, drawn under the
  /// markers. Empty means no line — callers that do not have one (the general
  /// traffic map) simply draw nothing extra.
  final List<LatLng> routePoints;

  final bool showRecenter;
  final String recenterLabel;
  final VoidCallback? onRecenter;

  /// Zoom controls. Supplied together or not at all: the caller owns the
  /// camera (it passes [mapController]) and therefore owns what "one step
  /// closer" means. Supplying only one of the two draws a single button, which
  /// is never what anyone wants, so the pair is rendered together.
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  /// Bounds the buttons refuse to step past, so a user can neither zoom out
  /// into an empty grey void nor into a tile level the bucket does not serve.
  final double minZoom;
  final double maxZoom;

  final VoidCallback? onMapReady;
  final ValueChanged<LatLng>? onCameraChanged;
  final ValueChanged<LatLng>? onTapMap;

  /// Ceiling on markers drawn at once. The feed caps itself at 60; this is a
  /// second guard so a crowded city centre cannot turn the map into a lag.
  final int maxVehicles;

  /// Room to leave at the bottom for whatever the caller floats over the map
  /// (a sheet handle, a status bar), so its own controls stay clear of it.
  final double overlayBottomInset;

  @override
  State<LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<LiveMap> with SingleTickerProviderStateMixin {
  late final MapController _map = widget.mapController ?? MapController();
  Ticker? _clock;
  Duration _lastFrame = Duration.zero;

  /// Last known track per vehicle, keyed by provider id.
  final Map<String, _VehicleTrack> _tracks = {};

  /// Icon inputs per vehicle, kept beside the track so a later fix that
  /// arrives without its category still draws the right vehicle type.
  final Map<String, _StyleHint> _hints = {};

  @override
  void initState() {
    super.initState();
    _clock = createTicker(_onTick)..start();
    _seedTracks();
  }

  @override
  void didUpdateWidget(covariant LiveMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.vehicles, widget.vehicles)) {
      _seedTracks();
    }
  }

  void _onTick(Duration elapsed) {
    // ~30 fps. A marker layer that cannot be read is not smoother.
    if (elapsed - _lastFrame < const Duration(milliseconds: 33)) return;
    _lastFrame = elapsed;
    if (!mounted) return;
    setState(() {});
  }

  void _seedTracks() {
    final now = DateTime.now();
    final live = widget.vehicles.take(widget.maxVehicles).toList();
    final seen = <String>{};

    for (final v in live) {
      seen.add(v.providerId);
      _hints[v.providerId] = _StyleHint(
        slug: v.categorySlug,
        name: v.categoryName,
        providerType: v.providerType,
      );

      final track = _tracks[v.providerId];
      if (track == null) {
        _tracks[v.providerId] = _VehicleTrack.idle(v.position, v.headingDegrees, v.speedMps);
        continue;
      }

      // Only start a new glide when the SERVER sent a different position.
      // Re-seeding on every parent rebuild would snap a moving marker back to
      // its last reported point and freeze it there.
      //
      // Same position again means the vehicle is not moving at the speed we
      // last derived. Carrying the old number forward is what made a parked
      // car's pin drive itself 250 m down the road and stay there: the feed
      // rounds to ~110 m, so a stationary car reports an identical point every
      // poll, forever, and each poll re-asserted the speed it had when it was
      // last seen moving.
      if (track.serverTarget == v.position) {
        track.speedMps = v.speedMps ?? 0;
        continue;
      }

      // Start the new segment from where the marker currently *is*, so an
      // interpolation already in flight is continued rather than discarded.
      track.from = track.positionAt(now);
      track.fromHeading = track.renderedHeading;
      track.to = v.position;
      track.serverTarget = v.position;
      track.toHeading = v.headingDegrees ?? track.renderedHeading;
      track.speedMps = v.speedMps ?? track.speedMps;
      track.startedAt = now;
    }

    // Vehicles that dropped out of the feed (went offline, drove away) are
    // forgotten rather than frozen on the map.
    _tracks.removeWhere((id, _) => !seen.contains(id));
    _hints.removeWhere((id, _) => !seen.contains(id));
  }

  @override
  void dispose() {
    _clock?.dispose();
    if (widget.mapController == null) _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final pulse = (now.millisecondsSinceEpoch % 2200) / 2200.0;

    final markers = <Marker>[
      ..._vehicleMarkers(now),
      if (widget.pickupPoint != null)
        Marker(
          point: widget.pickupPoint!,
          width: 40,
          height: 40,
          alignment: Alignment.topCenter,
          child: const Icon(Icons.trip_origin, color: AppTheme.primaryGreen, size: 26),
        ),
      if (widget.destinationPoint != null)
        Marker(
          point: widget.destinationPoint!,
          width: 44,
          height: 44,
          alignment: Alignment.topCenter,
          child: const Icon(Icons.location_pin, color: AppTheme.error, size: 42),
        ),
      ...widget.openRides
          .take(widget.maxVehicles)
          .map((r) => Marker(
                point: r.position,
                width: 48,
                height: 48,
                alignment: Alignment.topCenter,
                child: _OpenRidePin(ride: r),
              )),
      if (widget.selfPosition != null)
        Marker(
          point: widget.selfPosition!,
          width: 62,
          height: 62,
          child: _SelfDot(pulse: pulse),
        ),
      if (widget.handTypedPoint != null)
        Marker(
          point: widget.handTypedPoint!,
          width: 46,
          height: 46,
          alignment: Alignment.topCenter,
          child: Tooltip(
            message: widget.handTypedLabel ?? 'Your typed location',
            child: const Icon(Icons.place, color: AppTheme.gold, size: 38),
          ),
        ),
    ];

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: widget.center,
            initialZoom: widget.zoom,
            onMapReady: widget.onMapReady,
            onPositionChanged: (_, __) => widget.onCameraChanged?.call(_map.camera.center),
            onTap: widget.onTapMap == null ? null : (_, point) => widget.onTapMap!(point),
          ),
          children: [
            // Tile failures degrade to a placeholder instead of crashing the
            // screen — see ResilientTileLayer.
            const ResilientTileLayer(),
            if (widget.routePoints.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: widget.routePoints,
                    strokeWidth: 4,
                    color: AppTheme.primaryGreen.withOpacity(0.65),
                  ),
                ],
              ),
            MarkerLayer(markers: markers),
            // Required by the OpenStreetMap tile usage policy.
            const RichAttributionWidget(
              attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
            ),
          ],
        ),
        if (widget.selfAccuracyMeters != null && widget.selfPosition != null)
          Positioned(
            left: 12,
            bottom: 12 + widget.overlayBottomInset,
            child: _AccuracyChip(meters: widget.selfAccuracyMeters!),
          ),
        if (widget.showRecenter)
          Positioned(
            right: 12,
            bottom: 12 + widget.overlayBottomInset,
            child: _RecenterButton(label: widget.recenterLabel, onPressed: widget.onRecenter),
          ),
        // Above the recentre button, in the same right-hand column. Below it
        // rather than beside it, so a thumb reaching for either one never has
        // to cross over the map, and so neither control can cover the other's
        // tap target when the sheet is expanded.
        if (widget.onZoomIn != null && widget.onZoomOut != null)
          Positioned(
            right: 12,
            bottom: 12 + widget.overlayBottomInset +
                (widget.showRecenter ? 44 + 10 : 0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ZoomButton(
                  icon: Icons.add,
                  tooltip: 'Zoom in',
                  onPressed: widget.maxZoom > _map.camera.zoom
                      ? widget.onZoomIn
                      : null,
                ),
                const SizedBox(height: 8),
                _ZoomButton(
                  icon: Icons.remove,
                  tooltip: 'Zoom out',
                  onPressed: widget.minZoom < _map.camera.zoom
                      ? widget.onZoomOut
                      : null,
                ),
              ],
            ),
          ),
      ],
    );
  }

  List<Marker> _vehicleMarkers(DateTime now) {
    return _tracks.entries.map((entry) {
      final hint = _hints[entry.key];
      final style = vehicleMarkerStyle(
        categorySlug: hint?.slug,
        categoryName: hint?.name,
        providerType: hint?.providerType,
      );
      return Marker(
        point: entry.value.positionAt(now),
        width: 46,
        height: 46,
        child: _VehiclePin(
          key: ValueKey<String>(entry.key),
          style: style,
          headingDegrees: entry.value.renderedHeading,
        ),
      );
    }).toList();
  }
}

class _StyleHint {
  const _StyleHint({this.slug, this.name, this.providerType});

  final String? slug;
  final String? name;
  final String? providerType;
}

/// A single vehicle's motion between two reported fixes.
class _VehicleTrack {
  _VehicleTrack({
    required this.from,
    required this.to,
    required this.serverTarget,
    required this.fromHeading,
    required this.toHeading,
    required this.speedMps,
    required this.startedAt,
  });

  factory _VehicleTrack.idle(LatLng at, double? heading, double? speedMps) => _VehicleTrack(
        from: at,
        to: at,
        serverTarget: at,
        fromHeading: heading,
        toHeading: heading,
        speedMps: speedMps,
        startedAt: DateTime.now(),
      );

  LatLng from;
  LatLng to;

  /// The last position the server actually reported. Used to tell a genuine
  /// new fix from a rebuild with unchanged data.
  LatLng serverTarget;

  double? fromHeading;
  double? toHeading;
  double? speedMps;
  DateTime startedAt;

  /// How long the glide to the newly reported position takes. Shorter than
  /// the poll interval, so the marker visibly *arrives* and then keeps
  /// drifting — which reads as live rather than as a stutter.
  static const double _glideSeconds = 2.6;

  /// Cap on dead-reckoning after a fix. Past this the vehicle has almost
  /// certainly stopped, parked, or gone offline, and a pin that keeps driving
  /// across the city on its own is worse than one that sits still.
  static const double _maxExtrapolationMetres = 250;

  /// How long after a fix dead-reckoning is still believable.
  ///
  /// The point of extrapolating is to bridge the gap until the *next* fix
  /// arrives, which is one poll interval away (8 s). Holding a heading for far
  /// longer than that stops being a bridge and becomes a guess: a car that
  /// stopped at a light, or turned into a driveway, keeps gliding along its
  /// last heading for as long as the app is open. Bounding the extrapolation
  /// by time as well as distance means an un-refreshed vehicle always comes to
  /// rest on the last position the server actually reported, rather than
  /// somewhere it was never seen.
  static const double _maxExtrapolationSeconds = 10;

  LatLng positionAt(DateTime now) {
    final elapsedSeconds = now.difference(startedAt).inMilliseconds / 1000.0;
    final t = (elapsedSeconds / _glideSeconds).clamp(0.0, 1.0);
    final base = _lerp(from, to, Curves.easeOutCubic.transform(t));

    final speed = speedMps ?? 0;
    if (t >= 1.0 && speed > 0.6 && toHeading != null) {
      final sinceArrival = elapsedSeconds - _glideSeconds;
      if (sinceArrival <= _maxExtrapolationSeconds) {
        final extra =
            (sinceArrival * speed).clamp(0.0, _maxExtrapolationMetres);
        if (extra > 0.5) return _offset(base, toHeading!, extra);
      }
    }
    return base;
  }

  /// Heading to draw. The icon turns rather than snaps, and it turns the
  /// short way round: 350° -> 10° is a 20° turn to the right, not 340° left.
  double? get renderedHeading {
    final a = fromHeading;
    final b = toHeading;
    if (a == null) return b;
    if (b == null) return a;
    var delta = (b - a) % 360;
    if (delta > 180) delta -= 360;
    return (a + delta) % 360;
  }
}

LatLng _lerp(LatLng a, LatLng b, double t) =>
    LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);

/// Move [from] by [metres] along [headingDeg]. Flat-earth maths, which is
/// exact enough at marker scale and far cheaper than a geodesic on every
/// frame for every vehicle.
LatLng _offset(LatLng from, double headingDeg, double metres) {
  const metresPerDegreeLat = 111320.0;
  final rad = headingDeg * math.pi / 180.0;
  final dLat = (metres * math.cos(rad)) / metresPerDegreeLat;
  final cosLat = math.cos(from.latitude * math.pi / 180.0);
  final dLng = cosLat.abs() < 1e-6 ? 0.0 : (metres * math.sin(rad)) / (metresPerDegreeLat * cosLat);
  return LatLng(from.latitude + dLat, from.longitude + dLng);
}

/// A vehicle marker: a round badge with the type's own glyph, outlined in the
/// type's colour, rotated to the direction of travel.
class _VehiclePin extends StatelessWidget {
  const _VehiclePin({super.key, required this.style, this.headingDegrees});

  final VehicleMarkerStyle style;
  final double? headingDegrees;

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: style.color, width: 2),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Icon(style.icon, size: 19, color: style.color),
    );

    return Transform.translate(
      offset: const Offset(0, -8),
      child: headingDegrees == null
          ? badge
          : Transform.rotate(angle: headingDegrees! * math.pi / 180.0, child: badge),
    );
  }
}

/// The user's own position, with a halo that breathes outwards.
class _SelfDot extends StatelessWidget {
  const _SelfDot({required this.pulse});

  final double pulse;

  @override
  Widget build(BuildContext context) {
    final t = Curves.easeOut.transform(pulse);
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 24 + 34 * t,
          height: 24 + 34 * t,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.info.withOpacity(0.22 * (1 - t)),
          ),
        ),
        Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.info,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 5)],
          ),
        ),
      ],
    );
  }
}

/// An open ride request, for the driver's map.
class _OpenRidePin extends StatelessWidget {
  const _OpenRidePin({required this.ride});

  final LiveMapOpenRide ride;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.primaryGreenDark,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.2), blurRadius: 4)],
          ),
          child: Text(
            ride.fareEstimate == null ? 'Open ride' : 'ETB ${ride.fareEstimate!.toStringAsFixed(0)}',
            style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ),
        const Icon(Icons.location_on, color: AppTheme.primaryGreenDark, size: 22),
      ],
    );
  }
}

class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: const SizedBox(
            width: 44,
            height: 44,
            child: Icon(Icons.my_location, size: 21, color: AppTheme.primaryGreen),
          ),
        ),
      ),
    );
  }
}

/// The zoom a [+1]/[-1] step actually lands on.
///
/// Pure, and clamped, and therefore the only part of the zoom control worth
/// pinning down on its own: the buttons and the tween are paint, but this is
/// the rule, and the rule has two ways to be wrong that a tap cannot reveal.
/// An unclamped step lets a held-down button zoom past the last published
/// OpenStreetMap tile into grey squares; a clamp applied before the step
/// instead of after it refuses the last legitimate step, so the order matters.
/// Returns [currentZoom] unchanged when the step would not move, which is what
/// makes "already at the limit" a no-op rather than a jump.
double zoomTarget(double currentZoom, double steps,
    {double minZoom = 3, double maxZoom = 18}) {
  final target = (currentZoom + steps).clamp(minZoom, maxZoom);
  return target == currentZoom ? currentZoom : target;
}

/// One half of the zoom pair. A disabled step is drawn greyed and does not
/// fire, so reaching the last zoom level is visibly the end rather than a
/// button that silently does nothing.
class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 21,
              color: enabled ? AppTheme.primaryGreen : AppTheme.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _AccuracyChip extends StatelessWidget {
  const _AccuracyChip({required this.meters});

  final double meters;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.gps_fixed, size: 12, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text('±${meters.round()} m',
              style: const TextStyle(fontSize: 10, color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}
