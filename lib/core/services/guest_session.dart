import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'notification_service.dart';

/// Browsing without an account — the default way into the app.
///
/// The first screen is the dashboard. There is no welcome wall and no login
/// wall in front of the marketplace: a visitor lands on Home, browses, and only
/// meets an identity when a transaction actually needs one. Providers, drivers
/// and administrators sign in deliberately from the dashboard, or from
/// "Become a provider".
///
/// A guest is an ANONYMOUS Supabase session, opened lazily at the first
/// transaction (see [ensureGuestCheckoutSession]). It is deliberately not a
/// fake local flag: an order is scoped by `auth.uid()`, a push token belongs to
/// an account, and Realtime applies RLS to the waiting screen, so the guest
/// needs a real (anonymous) auth subject for those to work. It is a BUYER and
/// nothing else — the database creates no provider or staff row for it, and
/// the privileged tables refuse an anonymous JWT (migration 20261108000002).
///
/// [GuestMode] therefore describes "no real account yet", not "read-only".
/// It is memory-only: closing the app returns to the dashboard, not to a login
/// screen.
class GuestMode extends StateNotifier<bool> {
  GuestMode() : super(true);

  void start() {
    if (!state) state = true;
  }

  void end() {
    if (state) state = false;
  }
}

final guestModeProvider =
    StateNotifierProvider<GuestMode, bool>((ref) => GuestMode());

/// Open the anonymous session a guest checkout needs, or confirm the session
/// that already exists.
///
/// Returns false only when the project refuses anonymous sign-ins or the device
/// is offline. The caller stops there and the buyer reads a plain sentence —
/// never a spinner over an identity that cannot be created.
Future<bool> ensureGuestCheckoutSession(BuildContext context) async {
  final client = Supabase.instance.client;
  if (client.auth.currentSession != null) {
    // A restored anonymous session already has an auth.uid(); keep its device
    // token current for the order that is about to be placed.
    unawaited(NotificationService.instance.registerToken());
    return true;
  }

  try {
    await client.auth.signInAnonymously();
    // The guest now has a real auth.uid(). Register this device against it
    // BEFORE the order is submitted: checkout approval, vehicle assignment
    // and "driver arriving" are pushed to the buyer, and a buyer who never
    // registers a token can only ever see them in the inbox after reopening
    // the app. Best-effort — checkout must not fail because push did.
    unawaited(NotificationService.instance.registerToken());
    return true;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Guest checkout is unavailable right now. Please try again in a '
            'moment.',
          ),
        ),
      );
    }
    return false;
  }
}

/// Routes that belong to an ACCOUNT or a workspace rather than to the
/// marketplace.
///
/// These are not transactions; a guest simply has nothing to see there, so the
/// honest destination is the sign-in screen (they may already have an account).
/// The buyer's own orders are deliberately NOT here: a guest places real orders
/// under their anonymous identity and must be able to read them.
const List<String> _accountRoutePrefixes = [
  '/admin',
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
];

/// True when [location] is an account or workspace route.
bool guestBlockedAccount(String location) {
  for (final raw in _accountRoutePrefixes) {
    final prefix = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    if (location == prefix || location.startsWith('$prefix/')) return true;
  }
  return false;
}
