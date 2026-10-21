import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../theme/app_theme.dart';

/// Browsing without an account.
///
/// This is the THIRD session state, and it exists because the app only had two:
/// "no session" (bounced to /login from every route) and "a real account".
/// A visitor could not see the marketplace at all before registering, which is
/// the worst possible first impression of a marketplace — the product is the
/// listings, and they were behind a form.
///
/// A guest is deliberately NOT an anonymous Supabase session. There is no
/// auth token, no profile row and no role, so every read the app makes still
/// runs as `anon` under the same RLS the public web page would get: products,
/// providers, categories and search are readable, and nothing else is. The
/// transaction surfaces do not need a client-side gate to be SAFE (the server
/// refuses an anonymous `create_order_secure`), they need one to be
/// UNDERSTANDABLE: a guest who taps Buy must be told to create an account, not
/// shown an RLS denial.
///
/// So the flag does two things, and only two:
///   1. the router lets a guest into the browsing routes instead of /login;
///   2. the transaction entry points intercept the tap and open the standard
///      user registration, at that exact moment — never earlier, and never
///      into the provider or staff-assisted registration paths.
///
/// It is memory-only on purpose. A guest session is one browsing session; it
/// is not persisted, so closing the app returns the visitor to the welcome
/// screen where "Continue as Guest" is visible, and there is no stored state
/// that could later be mistaken for a real session.
class GuestMode extends StateNotifier<bool> {
  GuestMode() : super(false);

  void start() {
    if (!state) state = true;
  }

  void end() {
    if (state) state = false;
  }
}

final guestModeProvider =
    StateNotifierProvider<GuestMode, bool>((ref) => GuestMode());

/// Routes that CREATE an order, a booking or a ride.
///
/// A guest who reaches one of these — by tapping Buy, the cart's CHECKOUT, a
/// ride request, or a deep link — is sent to the standard user registration.
/// The order receipts and the review forms belong here for the same reason
/// the order detail does: they all attach to an order the guest never placed,
/// and the useful answer for somebody holding one of those links is the
/// registration form, not the sign-in screen.
const List<String> _transactionRoutes = [
  '/user/availability',
  '/user/checkout',
  '/user/payment',
  '/user/order-waiting',
  '/user/ride-request',
  '/documents',
  '/review',
];

/// Routes that belong to an ACCOUNT rather than to the marketplace.
///
/// These are not transactions; a guest simply has nothing to see there, so the
/// honest destination is the sign-in screen (they may already have an account).
const List<String> _accountRoutePrefixes = [
  '/admin',
  // An exact entry, not caught by the '/admin' prefix ('/admin-login' does
  // not start with '/admin/'): a guest gets the same answer /staff/login
  // already gives — the workspace doors are closed until they sign in.
  '/admin-login',
  '/staff',
  '/provider',
  '/vehicle',
  '/ceo',
  '/wallet',
  '/points',
  '/profile',
  '/appeals',
  '/appeal',
  '/help',
  '/account/',
  '/become-partner',
  '/admin-notifications',
  '/update-password',
  '/pending-approval',
  '/rejected',
  '/suspended',
  '/complete-profile',
  '/user/cart',
  '/user/favorites',
  '/user/orders',
  '/user/ride-active',
  '/user/ride-history',
];

/// True when [location] is a route that creates a transaction.
///
/// Checked BEFORE [guestBlockedAccount], because the two would otherwise
/// disagree about `/user/orders/:id`: as a transaction it sends the guest to
/// registration, which is the useful answer for somebody holding an order link
/// they were never able to place.
bool guestBlockedTransaction(String location) {
  if (location.startsWith('/user/orders')) return true;
  for (final route in _transactionRoutes) {
    if (location == route || location.startsWith('$route/')) return true;
  }
  return false;
}

/// True when [location] is an account or workspace route.
bool guestBlockedAccount(String location) {
  for (final raw in _accountRoutePrefixes) {
    // Normalise before comparing. The matcher appends '/', so an entry that
    // already ends with one ('/account/') only ever matched the impossible
    // '/account//…' — which left /account/deletion, /account/password and
    // every other trailing-slash entry OPEN to guests while the list
    // claimed they were closed. Trailing-slash entries are now safe to
    // write; a guest reaches an account surface only through /login.
    final prefix = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    if (location == prefix || location.startsWith('$prefix/')) return true;
  }
  return false;
}

/// The interception itself: a guest tapped something that needs an account.
///
/// Shown as a dialog rather than a silent redirect because the guest must
/// understand what just happened — a Buy button that teleports to a
/// registration form reads as a broken button, and the sentence names the
/// action they were taking so the form is obviously the next step of it.
///
/// Registration here is ALWAYS the standard user signup (`/signup/user`). A
/// buyer, a booker and a rider all need the same account; the provider and
/// staff-assisted paths are about opening a business and are unrelated to the
/// tap that triggered this.
Future<void> requestAccountToContinue(
  BuildContext context, {
  required String action,
}) async {
  final create = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => AlertDialog(
      backgroundColor: AppTheme.lightLemonSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      title: const Text(
        'Create a free account',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: AppTheme.textPrimary,
        ),
      ),
      content: Text(
        'You are browsing as a guest. To $action you need an account — it '
        'takes a minute, and it is what keeps your order and your payment '
        'protected.',
        style: const TextStyle(
          fontSize: 14,
          height: 1.45,
          color: AppTheme.textSecondary,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogCtx, false),
          child: const Text('KEEP BROWSING'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogCtx, true),
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryGreen),
          child: const Text('CREATE ACCOUNT'),
        ),
      ],
    ),
  );

  if (create == true && context.mounted) {
    context.push('/signup/user');
  }
}
