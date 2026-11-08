import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/providers/auth_provider.dart';
import '../../core/services/active_order_store.dart';
import '../../core/services/guest_session.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_error_boundary.dart';
import '../../core/widgets/birr_bottom_nav.dart';
import 'user_favorites_screen.dart';
import 'user_home_screen.dart';
import 'user_orders_screen.dart';
import 'user_profile_screen.dart';

/// The signed-in shell: four tabs behind a bottom bar.
///
/// ## Guest mode
///
/// The same shell serves a guest, because the marketplace is the product and
/// Home is where it lives. Two differences, and only two:
///
///   * Home is real and fully browsable — products, providers, categories,
///     search, the map. Reads run as `anon` under the same RLS the public
///     catalogue uses, so nothing is "leaked" to a guest that a visitor could
///     not already get.
///   * Order, Favourite and Account are not queried at all. They would run
///     owner-scoped reads with no owner and, worse, the account screen would
///     render a null profile. Each becomes a short panel that explains what an
///     account is for and offers the two doors (create one, or sign in) —
///     which is also how a guest leaves guest mode.
///
/// The tabs are keyed on the mode as well as the name, so switching between
/// guest and member rebuilds them rather than reusing a subtree built for the
/// other state.
///
/// ## Why every tab is wrapped in an error boundary
///
/// The tabs live in an [IndexedStack], which means all four are *built* at
/// once even though one is visible. Before this, a throw in any one of them
/// propagated out of the whole shell and the app went to a blank white
/// screen — the exact regression this work exists to make impossible. Each
/// tab now has its own boundary, so a broken Favourite tab shows a recovery
/// screen inside its own slot and Home, Order and Account keep working.
///
/// The boundaries are also keyed, so switching to a tab that crashed and back
/// re-runs it rather than leaving a permanently poisoned subtree.
class UserDashboard extends ConsumerStatefulWidget {
  const UserDashboard({super.key});

  @override
  ConsumerState<UserDashboard> createState() => _UserDashboardState();
}

class _UserDashboardState extends ConsumerState<UserDashboard> {
  int _navIndex = 0;
  bool _initFromRoute = false;
  bool _resumedActiveOrder = false;

  @override
  void initState() {
    super.initState();
    _resumeActiveOrder();
  }

  /// The order this device was in the middle of, before it was closed.
  ///
  /// A guest has no account to sign back into, so without this a killed app
  /// loses the waiting screen entirely. The stored value is an order id; the
  /// read that follows is still scoped by RLS to the anonymous session that
  /// placed it. Terminal orders clear the key instead of reopening it.
  Future<void> _resumeActiveOrder() async {
    if (_resumedActiveOrder) return;
    _resumedActiveOrder = true;
    final orderId = await ActiveOrderStore.read();
    if (orderId == null || !mounted) return;
    try {
      final row = await Supabase.instance.client
          .from('orders')
          .select('id, status')
          .eq('id', orderId)
          .maybeSingle();
      if (!mounted) return;
      final status = row?['status'] as String?;
      if (status == 'AWAITING_APPROVAL') {
        context.go('/user/checkout/waiting/$orderId');
      } else if (status == 'APPROVED' || status == 'STARTED') {
        context.go('/user/orders/$orderId/delivery');
      } else {
        await ActiveOrderStore.clear();
      }
    } catch (_) {
      // No session or no access: stay on the dashboard and keep browsing.
    }
  }

  /// Tab order matches [BirrBottomNav]: Home, Order, Favourite, Account.
  ///
  /// The ?tab= values this is reached with are a contract — see
  /// chat_deep_links.dart, user_checkout_screen.dart and the home header
  /// icons. They were updated together with the nav; the mapping is:
  /// 0 Home, 1 Order, 2 Favourite, 3 Account.
  static const List<Widget> _screens = [
    Material(child: UserHomeScreen()),
    Material(child: UserOrdersScreen()),
    Material(child: UserFavoritesScreen()),
    Material(child: UserProfileScreen()),
  ];

  static const List<String> _tabNames = ['Home', 'Order', 'Favourite', 'Account'];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initFromRoute) {
      _initFromRoute = true;
      final tab = GoRouterState.of(context).uri.queryParameters['tab'];
      if (tab != null) {
        final parsed = int.tryParse(tab);
        if (parsed != null && parsed >= 0 && parsed < _screens.length) {
          _navIndex = parsed;
        }
      }
    }
  }

  void _goTo(int index) {
    if (index == _navIndex) return;
    setState(() => _navIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    // An anonymous session is still a guest for Favourites and Account, which
    // belong to a real profile. The ORDER tab is different: an anonymous
    // session is a real auth subject, and the order it placed is its own row
    // under RLS — hiding it from the buyer who just placed it would be the one
    // place the guest model loses their order. So Orders is shown whenever a
    // session exists, and only a visitor with no session gets the guest door.
    final auth = ref.watch(authProvider);
    final isGuest = ref.watch(guestModeProvider) || auth.isGuest;
    final hasSession = auth.user != null;

    return AppErrorBoundary(
      screenName: 'user-dashboard',
      child: Scaffold(
        // Non-blocking "Verify your account" notice after registration.
        // Pure UI; the real gate still sits on the first protected action.
        // Not shown to a guest: there is no account to verify, and the check
        // behind it is an owner-scoped read.
        body: Column(
          children: [
            // No "verify your account" banner: a buyer does not verify
            // documents any more (migration 20261108000002 makes the guest
            // profile APPROVED on arrival), so a reminder would point at a
            // task the product no longer asks for.
            Expanded(
              child: IndexedStack(
                index: _navIndex,
                children: [
                  for (var i = 0; i < _screens.length; i++)
                    AppErrorBoundary(
                      // Keyed on the tab name AND the session mode so a tab
                      // that crashed — or that was built for the other
                      // session — is rebuilt from scratch.
                      key: ValueKey(
                          'tab-${_tabNames[i]}-$i-${isGuest ? 'guest' : 'member'}'),
                      screenName: 'user/${_tabNames[i]}',
                      child: isGuest && i > 0 && !(i == 1 && hasSession)
                          ? _GuestTab(index: i)
                          : _screens[i],
                    ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: BirrBottomNav(
          currentIndex: _navIndex,
          onTap: _goTo,
        ),
      ),
    );
  }
}

/// What replaces Order / Favourite / Account while browsing as a guest.
///
/// Deliberately not an empty state: an empty "no orders yet" would be a lie
/// (this visitor has no account to have orders on), and a disabled tab would
/// leave them with no visible way to register. It states the situation and
/// puts both doors in reach.
class _GuestTab extends StatelessWidget {
  const _GuestTab({required this.index});

  /// 1 Order, 2 Favourite, 3 (and any other) Account.
  final int index;

  ({IconData icon, String title, String body}) get _copy {
    switch (index) {
      case 1:
        return (
          icon: Icons.receipt_long_outlined,
          title: 'Track an order',
          body:
              'An order you place as a guest opens its own live screen and is '
              'remembered on this device. Sign in if you already have an '
              'account and want its history on this tab.',
        );
      case 2:
        return (
          icon: Icons.favorite_border,
          title: 'Save what you like',
          body:
              'Favourites are kept on an account. Browsing and ordering work '
              'without one — sign in to keep a list across your devices.',
        );
      default:
        return (
          icon: Icons.person_outline,
          title: 'You are browsing as a guest',
          body:
              'Everything in the marketplace is open to you, including '
              'checkout. Sign in if you already have an account, or open a '
              'business account to sell on Aliob.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryGreen.withOpacity(0.08),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(copy.icon,
                      size: 38, color: AppTheme.primaryGreen),
                ),
                const SizedBox(height: 22),
                Text(
                  copy.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  copy.body,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    // A BUYER does not register any more. This is the sign-in
                    // door for an account that already exists.
                    onPressed: () => context.push('/login'),
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('SIGN IN'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      textStyle: const TextStyle(
                          fontSize: 13.5, fontWeight: FontWeight.w700),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => context.push('/signup/service'),
                    icon: const Icon(Icons.storefront_outlined, size: 18),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.teal,
                      side: BorderSide(color: AppTheme.teal.withOpacity(0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('BECOME A PROVIDER'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
