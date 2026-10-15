import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/city_service.dart';
import '../../core/services/points_service.dart';
import '../../core/services/rank_service.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/rank_badge.dart';
import '../../core/widgets/verification_status_tile.dart';

/// The user's own profile picture, and the only control in the app that sets
/// it.
///
/// Separate from the provider's BUSINESS photo on purpose. That one lives on
/// `provider_profiles.photo_storage_path` in the `provider-photos` bucket
/// (20260927000106) and is edited from the provider dashboard. This is
/// `profiles.avatar_storage_path` in `profile-avatars` (20260927000119), it is
/// on every signed-in person's profile rather than only providers', and until
/// 0119 the column and the bucket did not exist at all -- so "change my
/// profile picture" was not broken, it was absent.
///
/// The write policies scope on the first path segment being the caller's uid,
/// which is why the path below is built client-side and MUST start with the
/// caller's own id. The server has never seen the row.
class ProfileAvatar extends ConsumerStatefulWidget {
  const ProfileAvatar({super.key, this.size = 76});

  final double size;

  @override
  ConsumerState<ProfileAvatar> createState() => _ProfileAvatarState();
}

class _ProfileAvatarState extends ConsumerState<ProfileAvatar> {
  static const _bucket = 'profile-avatars';

  final _picker = ImagePicker();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final path = ref.watch(authProvider).profile?.avatarStoragePath;
    final ring = widget.size + 6;

    return Column(
      children: [
        GestureDetector(
          onTap: _busy ? null : _pick,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.primaryGreen.withOpacity(0.3),
                width: 2,
              ),
            ),
            child: Container(
              width: widget.size,
              height: widget.size,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: _busy
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.primaryGreen,
                        ),
                      ),
                    )
                  : (path == null
                      ? const Icon(Icons.person,
                          color: AppTheme.primaryGreen, size: 38)
                      : Image.network(
                          Supabase.instance.client.storage
                              .from(_bucket)
                              .getPublicUrl(path),
                          fit: BoxFit.cover,
                          // A broken image is worse than no image: this is the
                          // one place a person expects to see their own face,
                          // and a silent grey box reads as "the app lost it".
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.person,
                            color: AppTheme.primaryGreen,
                            size: 38,
                          ),
                        )),
            ),
          ),
        ),
        const SizedBox(height: 6),
        // A camera badge is the only honest affordance here. Without it the
        // avatar reads as decoration and nobody discovers it is editable.
        SizedBox(
          width: ring,
          child: Text(
            _busy ? 'Uploading…' : 'Change photo',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.primaryGreenDark,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pick() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      _toast('Please sign in again.');
      return;
    }

    // Downscaled, not forwarded. The bucket is 5MB and accepts only
    // jpeg/png/webp, and a HEIC from an iPhone is refused inside storage where
    // it surfaces as a generic failure. Same convention as every other picker
    // in this app.
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final client = Supabase.instance.client;
      final file = File(picked.path);
      final name = Uri.encodeComponent(file.uri.pathSegments.last);
      final path =
          '$uid/avatar/${DateTime.now().microsecondsSinceEpoch}/$name';

      await client.storage
          .from(_bucket)
          .upload(path, file, fileOptions: const FileOptions(upsert: true));
      await client
          .from('profiles')
          .update({'avatar_storage_path': path})
          .eq('id', uid);

      // The write is saved on its own rather than waiting for a form submit:
      // a person who picks a photo and navigates away should not lose it. The
      // auth provider holds the cached profile row, so it has to be told or the
      // avatar keeps showing the old (or no) picture until the next launch.
      ref.invalidate(authProvider);
      if (!mounted) return;
      _toast('Photo updated');
    } catch (e) {
      if (mounted) {
        _toast(friendlyError(e, context: 'Could not upload your photo'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }
}

class UserProfileScreen extends ConsumerWidget {
  const UserProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final profile = auth.profile;

    // The status badge used to be hard-coded to success green whatever the
    // account's real status was, so an approved and a pending account looked
    // identical. Colour AND wording now follow the status.
    final status = profile?.status;
    final statusColor = switch (status) {
      'APPROVED' => AppTheme.success,
      'PENDING_APPROVAL' => AppTheme.warning,
      'REJECTED' => AppTheme.error,
      _ => AppTheme.textSecondary,
    };
    final statusLabel = (status ?? 'ACTIVE').replaceAll('_', ' ').toLowerCase();

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            // Profile header card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Avatar with ring. It was a hard-coded Icons.person with no
                  // tap target, which is the whole of Bug 1: there was no way
                  // to set your own picture because there was nothing to press.
                  const ProfileAvatar(),
                  const SizedBox(height: 14),
                  Text(profile?.fullName ?? 'User',
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  if (profile?.phone != null && profile!.phone!.isNotEmpty)
                    Text(profile.phone!,
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textSecondary)),
                  if (profile?.email != null && profile!.email!.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(profile.email!,
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textMuted)),
                  ],
                  const SizedBox(height: 12),
                  // Status badge (colour + wording follow the real status)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      statusLabel,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: statusColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // Loyalty points card
            _PointsCard(),
            const SizedBox(height: 20),
            // Menu card
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder, width: 0.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                children: [
                  _menuTile(Icons.person_outline, 'Edit Profile',
                      AppTheme.primaryGreen,
                      onTap: () => context.push('/profile/edit')),
                  _divider(),
                  _menuTile(Icons.location_city_outlined, 'My City',
                      AppTheme.teal, onTap: () => _changeCity(context, ref)),
                  _divider(),                  // No address book exists yet. It says so on the tap rather
                  // than doing nothing, because a row that looks tappable and
                  // is not reads as a broken app.
                  _menuTile(Icons.location_on_outlined, 'Addresses',
                      AppTheme.teal,
                      onTap: () => _notBuiltYet(context, 'Addresses')),
                  _divider(),
                  _menuTile(Icons.favorite_border, 'Favorites', AppTheme.error,
                      onTap: () => context.push('/user/favorites')),
                  _divider(),
                  _menuTile(Icons.notifications_outlined,
                      'Notification Settings', AppTheme.info,
                      onTap: () => _notBuiltYet(
                          context, 'Notification Settings')),
                  _divider(),
                  // GPS / ride tracking: live map + directions to the driver.
                  _menuTile(Icons.map_outlined, 'My Rides (Live Tracking)',
                      AppTheme.teal,
                      onTap: () => context.push('/user/ride-active')),
                  _divider(),
                  _menuTile(Icons.history, 'Ride History', AppTheme.info,
                      onTap: () => context.push('/user/ride-history')),
                  _divider(),
                  // Task 13 item 3: persistent, non-blocking entry point to
                  // the document upload flow — the same ProviderDocGate sheet
                  // the protected-action gate opens (Task 9 gate unchanged).
                  //
                  // Status-aware on purpose. This was a static tile, so a
                  // verified and an unverified account rendered identically
                  // and a successful upload left no visible trace anywhere.
                  const VerificationStatusTile(),
                  _divider(),
                  // Both sides of the appeal flow: what I filed (and where it
                  // stands) and what was filed against me (with the reply).
                  _menuTile(Icons.outlined_flag, 'My Appeals', AppTheme.gold,
                      onTap: () => context.push('/appeals')),
                  _divider(),
                  // Offered only to someone who is not already a provider: a
                  // customer turning their existing account into a business is
                  // the case this is for, and a provider pressing it would only
                  // ever be told they already have one.
                  _menuTile(Icons.map_outlined, 'Live Map', AppTheme.teal,
                      onTap: () => context.push('/map')),
                  if (!auth.isProvider)
                    _menuTile(Icons.storefront_outlined, 'Become a Partner',
                        AppTheme.primaryGreen,
                        onTap: () => context.push('/become-partner')),
                  if (!auth.isProvider) _divider(),
                  _menuTile(Icons.lock_outline, 'Change Password',
                      AppTheme.textSecondary,
                      onTap: () => context.push('/account/password')),
                  _divider(),
                  _menuTile(Icons.help_outline, 'Help & Support', AppTheme.gold,
                      onTap: () => context.push('/help')),
                  _divider(),
                  // Destructive, so it sits last and is styled as the
                  // deliberate act it is. It opens a request; it does not
                  // delete anything on the spot.
                  _menuTile(Icons.delete_outline, 'Delete Account',
                      AppTheme.error,
                      onTap: () => context.push('/account/deletion')),
                  _divider(),
                  // Opens the About screen, not the Terms policy it used to
                  // point at -- the one place a user goes to find out what the
                  // app is should not show them a legal document.
                  _menuTile(Icons.info_outline, 'About Aliob',
                      AppTheme.textSecondary,
                      onTap: () => context.push('/about')),
                  _divider(),
                  // The Terms of Service, on their own page. The Terms used to
                  // be reachable only as half of the combined policy document
                  // the registration checkbox accepts, so a user looking for
                  // "the rules" found a data-handling document instead.
                  _menuTile(Icons.description_outlined, 'Terms of Service',
                      AppTheme.textSecondary,
                      onTap: () => context.push('/terms-of-service')),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Logout button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => ref.read(authProvider.notifier).signOut(),
                icon: const Icon(Icons.logout, color: AppTheme.error, size: 18),
                label: const Text('Logout',
                    style: TextStyle(color: AppTheme.error)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: AppTheme.error, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  /// Phase 1: edit the saved city (profiles.city). Browsing follows the
  /// saved city unless travel mode is on.
  Future<void> _changeCity(BuildContext context, WidgetRef ref) async {
    final cityService = ref.read(cityProvider);
    final saved = cityService.savedCity ?? CityService.fallbackCity;
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('My City'),
        children: [
          for (final c in CityService.knownCities)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(c),
              child: Row(
                children: [
                  Icon(
                    c == saved
                        ? Icons.check_circle
                        : Icons.location_city_outlined,
                    size: 18,
                    color: c == saved ? AppTheme.primaryGreen : AppTheme.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(c),
                ],
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == saved) return;
    final ok = await ref.read(cityProvider).updateSavedCity(picked);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ok
            ? 'City updated to $picked'
            : 'Could not update the city — try again'),
      ));
    }
  }

  Widget _menuTile(IconData icon, String label, Color iconColor,
      {VoidCallback? onTap}) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, color: iconColor, size: 18),
      ),
      onTap: onTap,
      title: Text(label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      trailing:
          const Icon(Icons.chevron_right, color: AppTheme.textMuted, size: 20),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
    );
  }

  /// A menu row for a feature that is not built yet.
  ///
  /// The alternative — leaving the row with no `onTap` — is what "Edit
  /// Profile" was doing: a tappable-looking row that swallowed the tap with
  /// no feedback at all, which is indistinguishable from a broken app. Saying
  /// so is honest, costs one line, and keeps the row from being a silent
  /// dead end.
  void _notBuiltYet(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$feature is not available yet.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Divider(height: 1, thickness: 0.5, color: AppTheme.cardBorder),
    );
  }
}

/// The signed-in user's points AND their rank, with the distance to the next
/// rung and a way into the full breakdown (Feature 3, extended).
class _PointsCard extends StatefulWidget {
  @override
  State<_PointsCard> createState() => _PointsCardState();
}

class _PointsCardState extends State<_PointsCard> {
  int _points = 0;
  RankProgress? _progress;
  bool _loading = true;
  // A failed read used to leave _points at 0, so the card confidently showed
  // "0 points" to a user who may well have a balance. Say we do not know
  // instead, and let them retry in place.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await PointsService.instance.getMyPoints();
      // The ladder is read from the server (the rank_tiers setting), never
      // from thresholds compiled into the app, so the CEO can retune it.
      // Best-effort: points without a rank still beats no card at all.
      RankProgress? progress;
      try {
        progress = await RankService.instance.progressForPoints(p);
      } catch (_) {
        progress = null;
      }
      if (mounted)
        setState(() {
          _points = p;
          _progress = progress;
          _loading = false;
          _failed = false;
        });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return RankProgressCard(
      points: _points,
      progress: _progress,
      loading: _loading,
      failed: _failed,
      onRetry: () {
        setState(() {
          _loading = true;
          _failed = false;
        });
        _load();
      },
      onTap: () => context.push('/points'),
    );
  }
}
