import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/resilience/failure_mapper.dart';
import '../../core/widgets/async_view.dart';

/// Where tapping a notification row takes the reader.
///
/// Every `notify_*` call in this project writes a payload with the id of the
/// thing it is about -- `order_id`, `ride_id`, `document_id`,
/// `appeal_case_id`, `recharge_id` -- and until now the inbox read that
/// payload and did nothing with it. The list had no `onTap` at all, so
/// "A customer is asking whether you have 2 items available. Open it to
/// confirm." was a sentence telling the reader to open something they had no
/// way to reach from where they were reading it.
///
/// Returned as a path rather than navigated to directly so the mapping can be
/// tested without a router: the ids come from JSON, and a cast on them is
/// exactly the kind of thing that throws inside a build() and blanks the
/// screen (the failure the content-control gallery had).
///
/// [viewerRole] is threaded into the order route because
/// `/user/orders/:id` renders a different screen for the provider on the order
/// -- that is where "Confirm Availability" lives -- and the router defaults it
/// to 'user', which would hand a provider the buyer's view of their own
/// request.
///
/// Returns null when the payload names nothing the router has a screen for.
/// The row is still marked read; it just does not navigate, which is the
/// honest outcome rather than a push to a route that does not exist.
String? notificationTargetPath(
  Map<String, dynamic> notification, {
  String viewerRole = 'user',
}) {
  Map<String, dynamic> payload =
      (notification['data'] as Map?)?.cast<String, dynamic>() ?? const {};

  String? id(String key) {
    final raw = payload[key];
    if (raw == null) return null;
    final text = raw.toString().trim();
    return text.isEmpty ? null : text;
  }

  final event = '${payload['event'] ?? ''}'.trim().toLowerCase();
  final role = payload['recipient_role']?.toString().trim().toLowerCase() ??
      viewerRole.trim().toLowerCase();
  final isAdmin = role == 'admin';
  final isProvider = role == 'provider';

  // A notification about a checkout request belongs to the admin queue, not
  // to the buyer's order screen. This is the one event whose destination is
  // decided by the event rather than by the id.
  if (event == 'checkout_request') return '/admin/checkout-requests';

  // Driver assignment is a delivery job, even though its notification type is
  // an ORDER type. Without this branch a driver tapping it would land on the
  // buyer's order page.
  if (event == 'delivery_assigned' || event == 'driver_assigned') {
    return '/vehicle/delivery-jobs';
  }

  final orderId = id('order_id');
  if (orderId != null) {
    // The admin approved the checkout: the buyer's useful screen is the live
    // delivery map, not the waiting room. A provider's own order queue is the
    // equivalent screen for them.
    if (event == 'checkout_approved') {
      if (isProvider) return '/provider/orders';
      if (!isAdmin) return '/user/orders/$orderId/delivery';
    }
    if (event == 'checkout_rejected') {
      return isProvider ? '/provider/orders' : '/user/orders/$orderId';
    }
    if (event == 'checkout_pending' || event == 'order_awaiting_approval') {
      return isAdmin
          ? '/admin/checkout-requests'
          : '/user/checkout/waiting/$orderId';
    }
    if (isAdmin) return '/admin/checkout-requests';
    if (isProvider) return '/provider/orders';
    return '/user/orders/$orderId';
  }

  // Availability is checked before the generic request_id branch: a stock
  // check carries no ride id, but a provider/admin ask must not be sent to the
  // rider's active-ride screen.
  final availabilityId = id('availability_request_id');
  if (availabilityId != null) {
    if (isAdmin) return '/admin/availability';
    if (isProvider) return '/provider';
    // A buyer who was told "available" continues at the cart. A refusal has
    // no next screen to open, so the inbox itself is the honest destination.
    final accepted = payload['accepted'] == true ||
        '${payload['accepted'] ?? ''}'.toLowerCase() == 'true';
    return accepted ? '/user/cart' : '/user/orders';
  }

  final rideId = id('ride_id') ?? id('request_id');
  if (rideId != null) {
    return isProvider ? '/vehicle/ride-requests' : '/user/ride-active';
  }

  if (event == 'test_notification') return '/admin-notifications';

  final appealId = id('appeal_case_id') ?? id('appeal_id');
  if (appealId != null) return '/appeals';

  final rechargeId = id('recharge_id');
  if (rechargeId != null) return '/wallet';

  // A document decision. There is no per-document screen a reader can open --
  // the owner reads it on their profile and a reviewer reads the queue -- so
  // the owner is sent to the profile, which is where the verdict is shown.
  final documentId = id('document_id');
  if (documentId != null) return '/profile';

  return null;
}

/// How many of this account's notifications are unread.
///
/// One query, used by the bell in every dashboard header. It exists because a
/// bell with no count is indistinguishable from a dead feature: notifications
/// were being written and delivered, but nothing on screen said so until the
/// reader opened the inbox and scrolled. Zero on any failure or when signed
/// out — a badge is never worth an error.
///
/// Invalidate it after reading a row (see `_open`) so the badge clears on the
/// same tap that marks it read.
final unreadNotificationsCountProvider = FutureProvider<int>((ref) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return 0;
  try {
    final rows = await Supabase.instance.client
        .from('notifications')
        .select('id')
        .eq('user_id', uid)
        .eq('is_read', false);
    return (rows as List).length;
  } catch (_) {
    return 0;
  }
});

class UserNotificationsScreen extends ConsumerStatefulWidget {
  const UserNotificationsScreen({super.key});
  @override
  ConsumerState<UserNotificationsScreen> createState() =>
      _UserNotificationsScreenState();
}

class _UserNotificationsScreenState
    extends ConsumerState<UserNotificationsScreen> {

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Returns the inbox, or throws a classified [AppFailure].
  ///
  /// AsyncView owns the three states, so this returns data rather than
  /// calling setState: the widget holds the loading/error/empty branches and
  /// keeps the last good list on screen when a refresh fails.
  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final data = await Supabase.instance.client
          .from('notifications')
          .select()
          .order('created_at', ascending: false)
          .limit(50);
      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw AppFailureMapper.map(e, context: 'loading your notifications');
    }
  }

  /// Which half of the app this reader belongs to. An order notification
  /// opens the provider's queue for a provider, the admin queue for an admin,
  /// and the buyer's order for everyone else.
  ///
  /// Resolved once and cached rather than asked per row: it is one query, and
  /// a tap that awaits it would make the list feel dead.
  String? _viewerRoleCache;

  Future<String> _viewerRole() async {
    if (_viewerRoleCache != null) return _viewerRoleCache!;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return 'buyer';
    try {
      final admin = await Supabase.instance.client
          .from('user_roles')
          .select('user_id')
          .eq('user_id', userId)
          .eq('role', 'ADMIN')
          .limit(1);
      if ((admin as List).isNotEmpty) {
        _viewerRoleCache = 'admin';
        return 'admin';
      }
      final provider = await Supabase.instance.client
          .from('provider_profiles')
          .select('id')
          .eq('user_id', userId)
          .limit(1);
      _viewerRoleCache = (provider as List).isNotEmpty ? 'provider' : 'buyer';
      return _viewerRoleCache!;
    } catch (_) {
      // Never fatal. A reader who cannot be classified still gets their
      // notifications, opened with the buyer's view -- the order detail screen
      // loads the same row either way.
      return 'buyer';
    }
  }

  bool _markingAll = false;

  /// Mark every unread row of the signed-in account read, then refresh.
  ///
  /// Scoped by `user_id` as well as `is_read` on purpose: RLS already limits
  /// this reader to their own rows, and the explicit filter means a future
  /// policy change cannot turn this into a blanket UPDATE.
  Future<void> _markAllRead() async {
    if (_markingAll) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    setState(() => _markingAll = true);
    try {
      await Supabase.instance.client
          .from('notifications')
          .update({
            'is_read': true,
            'read_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('user_id', uid)
          .eq('is_read', false);
      ref.invalidate(unreadNotificationsCountProvider);
    } catch (_) {
      // Best-effort: a failed sweep leaves the rows unread, which is the
      // truthful state and is still readable on the next open.
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  /// Mark the row read, then follow the payload.
  ///
  /// The mark happens FIRST and is never awaited before the navigation. A
  /// failed write must not strand the reader on a list they have already read,
  /// and an unread dot on a row they acted on is a smaller lie than a tap that
  /// does nothing.
  Future<void> _open(Map<String, dynamic> n) async {
    if (n['is_read'] != true) {
      try {
        await Supabase.instance.client
            .from('notifications')
            .update({'is_read': true, 'read_at': DateTime.now().toUtc().toIso8601String()})
            .eq('id', n['id']);
      } catch (_) {
        // Best-effort; the navigation below is the part that matters.
      }
      // The badge counts unread rows, so it is wrong the moment one is read.
      ref.invalidate(unreadNotificationsCountProvider);
    }

    final role = await _viewerRole();
    final path = notificationTargetPath(n, viewerRole: role);
    if (path == null || !mounted) return;
    // The order route reads `extra` as the viewer role; anything else takes no
    // argument, and passing one to a route that ignores it is harmless but
    // passing one where the builder casts it is not.
    context.push(
      path,
      extra: path.startsWith('/user/orders/')
          ? (role == 'provider' ? 'provider' : 'user')
          : null,
    );
  }

  Color _iconColor(String type) {
    if (type.contains('ORDER')) return AppTheme.info;
    if (type.contains('APPROVAL') || type.contains('APPROVE'))
      return AppTheme.success;
    if (type.contains('REJECT')) return AppTheme.error;
    if (type.contains('WALLET')) return AppTheme.gold;
    if (type.contains('RIDE')) return AppTheme.teal;
    // Points awards and appeal decisions are their own colours rather than
    // the default green, so the list reads at a glance without a filter.
    if (type.contains('POINTS')) return AppTheme.gold;
    if (type.contains('APPEAL')) return AppTheme.warning;
    return AppTheme.primaryGreen;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          // One tap clears the badge. It marks the same rows the list shows
          // (the reader's own, unread) and nothing else, so it cannot be used
          // to hide somebody else's notification.
          TextButton(
            onPressed: _markAllRead,
            child: const Text('Mark all read',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: AppTheme.primaryGreen,
        child: AsyncListView<Map<String, dynamic>>(
          loader: _load,
          errorContext: 'loading your notifications',
          padding: const EdgeInsets.all(16),
          itemBuilder: (_, n, __) {
                      final isRead = n['is_read'] == true;
                      final color = _iconColor(n['type'] ?? '');
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: isRead
                              ? AppTheme.surface
                              : AppTheme.primaryGreen.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: isRead
                                  ? AppTheme.cardBorder
                                  : AppTheme.primaryGreen.withOpacity(0.15),
                              width: 0.5),
                        ),
                        child: ListTile(
                          onTap: () => _open(n),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 4),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              _iconForType(n['type'] ?? ''),
                              color: color,
                              size: 20,
                            ),
                          ),
                          title: Text(n['title'] ?? '',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: isRead
                                      ? FontWeight.w500
                                      : FontWeight.w600)),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(n['body'] ?? '',
                                // Three lines, not two. The money notifications
                                // are receipts — "Payment of ETB 12,400.00 for
                                // Order #1841 has been verified. The buyer's
                                // contact details are now available in the
                                // order." — and at two lines on a narrow phone
                                // that ellipsizes before the amount is even
                                // visible, which defeats the point of quoting
                                // it. Status pings are shorter and simply leave
                                // the third line empty.
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: AppTheme.textSecondary)),
                          ),
                          trailing: !isRead
                              ? Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppTheme.primaryGreen,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.primaryGreen
                                            .withOpacity(0.3),
                                        blurRadius: 3,
                                      ),
                                    ],
                                  ))
                              : null,
                        ),
                      );
          },
          emptyBuilder: (context) => _buildEmptyState(),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Decorative icon with animated ring
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.teal.withOpacity(0.12),
                  width: 2,
                ),
              ),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.teal.withOpacity(0.06),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.notifications_none_rounded,
                    color: AppTheme.teal, size: 36),
              ),
            ),
            const SizedBox(height: 24),
            const Text('No notifications yet',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary)),
            const SizedBox(height: 10),
            Text(
              "You'll see updates about your orders,\napprovals, and account activity here",
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: AppTheme.textMuted.withOpacity(0.8)),
            ),
          ],
        ),
      ),
    );
  }


  IconData _iconForType(String type) {
    if (type.contains('ORDER')) return Icons.receipt_outlined;
    if (type.contains('APPROVAL') || type.contains('APPROVE'))
      return Icons.check_circle_outline;
    if (type.contains('REJECT')) return Icons.cancel_outlined;
    if (type.contains('WALLET')) return Icons.account_balance_wallet_outlined;
    if (type.contains('RIDE')) return Icons.directions_car_outlined;
    // Points (POINTS_EARNED and POINTS_REDEEMED) were already given a gold
    // tint in _iconColor but had no branch here, so a points-conversion
    // receipt rendered as the generic bell. The two helpers are read together
    // for that reason; a type that is coloured but unlabelled reads as noise.
    if (type.contains('POINTS')) return Icons.stars_rounded;
    if (type.contains('APPEAL')) return Icons.gavel_outlined;
    if (type.contains('WELCOME')) return Icons.waving_hand_outlined;
    return Icons.notifications_outlined;
  }
}
