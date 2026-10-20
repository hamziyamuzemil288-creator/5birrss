import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/providers/auth_provider.dart';
import '../core/services/guest_session.dart';
import '../features/splash/splash_screen.dart';
import '../features/auth/login_screen.dart';
import '../features/auth/signup_screen.dart' show SignupScreen, SignupRole;
import '../features/auth/otp_verification_screen.dart';
import '../features/auth/role_selection_screen.dart';
import '../features/auth/admin_login_screen.dart';
import '../features/auth/staff_login_screen.dart';
import '../features/staff/staff_dashboard_screen.dart';
import '../features/auth/terms_of_service_screen.dart';
import '../features/auth/terms_policy_screen.dart';
import '../features/auth/update_password_screen.dart';
import '../features/user/user_dashboard.dart';
import '../features/user/user_profile_screen.dart';
import '../features/user/user_notifications_screen.dart';
import '../features/user/user_product_detail_screen.dart';
import '../features/user/user_provider_detail_screen.dart';
import '../features/provider/provider_location_detail_screen.dart';
import '../features/user/user_category_group_screen.dart';
import '../features/user/user_category_screen.dart';
import '../features/user/user_favorites_screen.dart';
import '../features/user/user_cart_screen.dart';
import '../features/user/user_checkout_screen.dart';
import '../features/user/user_payment_screen.dart';
import '../features/user/user_availability_screen.dart';
import '../features/user/user_order_detail_screen.dart';
import '../features/user/provider_order_waiting_screen.dart';
import '../features/user/user_search_screen.dart';
import '../features/user/live_map_screen.dart';
import '../features/user/review_form_screen.dart';
import '../features/provider/service_provider_dashboard.dart';
import '../features/provider/provider_orders_screen.dart';
import '../features/about/about_us_screen.dart';
import '../features/provider/provider_category_settings_screen.dart';
import '../features/provider/provider_business_profile_screen.dart';
import '../features/provider/provider_documents_screen.dart';
import '../features/admin/admin_category_fields_screen.dart';
import '../features/provider/provider_subscription_screen.dart';
import '../features/provider/provider_payment_methods_screen.dart';
import '../features/provider/provider_product_list_screen.dart';
import '../features/provider/provider_product_form_screen.dart';
import '../features/vehicle/vehicle_provider_dashboard.dart';
import '../features/vehicle/vehicle_management_screen.dart';
import '../features/vehicle/vehicle_form_screen.dart';
import '../features/wallet/wallet_screen.dart';
import '../features/wallet/recharge_screen.dart';
import '../features/wallet/points_screen.dart';
import '../features/admin/admin_dashboard.dart';
import '../features/ceo/ceo_dashboard.dart';
import '../features/admin/admin_provider_management_screen.dart';
import '../features/admin/admin_history_screen.dart';
import '../features/admin/admin_orders_screen.dart';
import '../features/admin/admin_availability_screen.dart';
import '../features/admin/admin_payment_accounts_screen.dart';
import '../features/admin/admin_staff_screen.dart';
import '../features/admin/admin_account_directory_screen.dart';
import '../features/admin/admin_user_management_screen.dart';
import '../features/admin/admin_payment_methods_screen.dart';
import '../features/admin/admin_payment_verification_screen.dart';
import '../features/admin/admin_document_verification_screen.dart';
import '../features/admin/admin_cash_recharge_screen.dart';
import '../features/admin/admin_provider_wallet_screen.dart';
import '../features/admin/admin_transaction_history_screen.dart';
import '../features/admin/admin_registration_history_screen.dart';
import '../features/admin/admin_income_summary_screen.dart';
import '../features/admin/admin_expense_screen.dart';
import '../features/admin/admin_reports_screen.dart';
import '../features/admin/admin_support_tickets_screen.dart';
import '../features/admin/admin_appeals_screen.dart';
import '../features/admin/admin_disputes_screen.dart';
import '../features/admin/admin_order_payments_screen.dart';
import '../features/admin/admin_staff_assignment_screen.dart';
import '../features/admin/admin_role_permissions_screen.dart';
import '../features/admin/admin_settings_screen.dart';
import '../features/admin/admin_platform_settings_screen.dart';
import '../features/admin/admin_app_releases_screen.dart';
import '../features/admin/fee_settings_screen.dart';
import '../features/admin/admin_content_control_screen.dart';
import '../features/admin/widgets/image_delete_sheet.dart';
import '../features/shared/transaction_documents_screen.dart';
import '../features/admin/admin_categories_screen.dart';
import '../features/admin/category_fee_settings_screen.dart';
import '../features/appeal/appeal_screen.dart';
import '../features/appeal/my_appeals_screen.dart';
import '../features/settings/account_deletion_screen.dart';
import '../features/admin/admin_deletion_requests_screen.dart';
import '../features/auth/change_password_screen.dart';
import '../features/provider/provider_gallery_screen.dart';
import '../features/auth/complete_profile_screen.dart';
import '../features/user/edit_profile_screen.dart';
import '../features/provider/become_partner_screen.dart';
import '../features/user/rate_customer_screen.dart';
import '../features/admin/admin_notification_send_screen.dart';
import '../features/approval/pending_approval_screen.dart';
import '../features/approval/rejected_screen.dart';
import '../features/approval/suspended_screen.dart';
import '../features/vehicle/driver_ride_requests_screen.dart';
import '../features/vehicle/driver_trip_screen.dart';
import '../features/user/user_ride_request_screen.dart';
import '../features/user/user_active_ride_screen.dart';
import '../features/shared/ride_history_screen.dart';
import '../features/help_chat/help_chat_screen.dart';

/// A [ChangeNotifier] that fires whenever [authProvider] state changes,
/// allowing [GoRouter] to re-evaluate its redirect callback.
///
/// Also handles a one-time retry for missing profiles right after signup:
/// the database trigger may not have completed by the time
/// [GoRouter] first evaluates the redirect, so we wait briefly and
/// refresh the profile once.
///
/// It listens to the GUEST flag as well, and clears it the moment a real
/// session exists. Both halves matter: the router has to re-run its redirect
/// when somebody taps "Continue as Guest", and a guest who then signs in must
/// not keep carrying the flag into an authenticated session — a lingering
/// `isGuest` would keep the account routes closed for a signed-in user, which
/// is a worse bug than the one guest mode fixes.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(this._ref) {
    _sub = _ref.listen<AuthState>(authProvider, (_, next) {
      if (next.isAuthenticated) {
        // Real session: guest browsing is over. Safe here (outside the
        // redirect callback) — ending it inside redirect() would mutate a
        // provider while go_router is deciding where to go.
        _ref.read(guestModeProvider.notifier).end();
      }
      notifyListeners();
    });
    _guestSub =
        _ref.listen<bool>(guestModeProvider, (_, __) => notifyListeners());
  }

  final Ref _ref;
  late final ProviderSubscription<AuthState> _sub;
  late final ProviderSubscription<bool> _guestSub;
  bool _profileRetryScheduled = false;

  /// Call when redirect sees an authenticated user with no profile.
  /// Schedules a single retry after 1 second to give the database
  /// trigger time to complete.
  void scheduleProfileRetry() {
    if (_profileRetryScheduled) return;
    _profileRetryScheduled = true;
    Future.delayed(const Duration(seconds: 1), () {
      _profileRetryScheduled = false;
      _ref.read(authProvider.notifier).refreshProfile();
    });
  }

  @override
  void dispose() {
    _sub.close();
    _guestSub.close();
    super.dispose();
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  // Create a ChangeNotifier that fires on every auth state change.
  // GoRouter listens to this via refreshListenable and re-evaluates
  // the redirect callback each time it fires.
  //
  // IMPORTANT: We do NOT ref.watch(authProvider) here. Watching it would
  // destroy and recreate the GoRouter on every auth state change, losing
  // all navigation state. Instead, the redirect callback reads the
  // current auth state via ref.read() each time it is invoked.
  final refreshNotifier = _AuthRefreshNotifier(ref);
  ref.onDispose(refreshNotifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      // Read the CURRENT auth state each time the redirect is evaluated.
      // This is safe because refreshListenable fires on every auth change,
      // and ref.read() returns the latest state synchronously.
      final authState = ref.read(authProvider);
      final isLoading = authState.isLoading;
      final isAuthenticated = authState.isAuthenticated;
      // The third session state (guest_session.dart). Read, never watched:
      // this callback is the reader, and _AuthRefreshNotifier above is what
      // makes go_router re-evaluate when the flag moves.
      final isGuest = ref.read(guestModeProvider);
      final loc = state.matchedLocation;
      final isAuthRoute = loc == '/login' ||
          loc == '/role-select' ||
          loc == '/admin-login' ||
          loc == '/staff/login' ||
          loc == '/terms' ||
          loc == '/update-password' ||
          // Task 13 fix: signup hands off to email verification BEFORE the
          // account exists, so the OTP screen is reached with no session.
          // Without this entry the redirect bounced every signup straight
          // to /login — the code-entry screen never mounted and the OTP
          // email was never requested (the reported "no OTP at signup" bug).
          loc == '/otp-verify';
      final isSignupRoute = loc.startsWith('/signup/');
      final isApprovalRoute = _isApprovalRoute(loc);

      // Still loading — don't redirect yet.
      if (isLoading) return null;

      // ── No session ──
      // Two different visitors arrive here, and they must not be treated
      // alike any more:
      //
      //   * a GUEST ("Continue as Guest" on the welcome screen) browses the
      //     marketplace. The account and workspace routes are closed, and the
      //     transaction routes open the standard user registration at the
      //     exact moment they are attempted — Buy, Book, CHECKOUT, a ride
      //     request. Nothing is gated earlier than that.
      //   * everybody else is sent to sign in, exactly as before.
      if (!isAuthenticated) {
        if (isGuest) {
          // The splash screen is a spinner that only exists so the router can
          // decide; a guest has already decided, so it goes straight in.
          if (loc == '/') return '/user';
          if (guestBlockedTransaction(loc)) return '/signup/user';
          if (guestBlockedAccount(loc)) return '/login';
          if (isApprovalRoute) return '/user';
          // Browsing routes, the marketplace detail pages, search, the map,
          // the legal pages, and the sign-in/sign-up screens are open.
          return null;
        }
        if (isAuthRoute || isSignupRoute) return null;
        return '/login';
      }

      // Authenticated but profile or roles haven't loaded yet — stay put
      // and schedule a retry (the DB trigger may still be in-flight).
      if (authState.profile == null || authState.roles.isEmpty) {
        refreshNotifier.scheduleProfileRetry();
        return null;
      }

      // ── Profile completeness (an extension of the gate above, not a
      // replacement for it) ──
      // A Google sign-in produces a profile row the app cannot verify:
      // handle_new_user() fills full_name/phone/kebele/street_road from
      // raw_user_meta_data, and Google supplies none of them, so the account
      // arrives with full_name = 'New User' and no phone or address. The
      // document upload still SUCCEEDS (user_documents needs only user_id,
      // document_type, storage_path) — what fails is verification, because
      // the admin reviewing it has no phone to call and no ID to match.
      //
      // Routed rather than warned, so it cannot be bypassed: there is no way
      // to reach any other screen first, because this redirect runs on every
      // navigation.
      //
      // Admins and staff gateway accounts are exempt. They are created by
      // the app, not by a self-service signup, and are not verified against
      // a national ID — gating them would lock the CEO out of their own
      // dashboard over a phone number they never had a reason to enter.
      //
      // APPROVED accounts are exempt too, and that exemption is the fix for a
      // hard crash found on device:
      //
      //   / => /complete-profile => /complete-profile => /user => /user
      //
      // An account that is already APPROVED but predates kebele/street_road
      // has an incomplete profile forever. It reaches the completion screen,
      // the "approval resolved" branch below forwards it to its dashboard (it
      // is approved, so it is neither pending nor rejected), the gate here
      // sends it back, and the two repeat until go_router gives up with
      // "redirect loop detected" and the app renders Page Not Found.
      //
      // An approved account has already been through verification once;
      // re-gating it locks a working customer out of the app over a field
      // they could not have known was added. It can still be corrected,
      // voluntarily, from Edit Profile.
      final needsProfileCompletion = !authState.isAdmin &&
          !authState.isStaffMember &&
          !authState.isApproved &&
          !authState.profile!.isVerifiable;

      if (needsProfileCompletion && loc != '/complete-profile') {
        return '/complete-profile';
      }

      // Staff gateway accounts are authenticated but intentionally land in
      // their own workspace, not the broad admin dashboard.
      if (authState.isStaffMember) {
        if (loc == '/staff/login' || loc == '/' || isAuthRoute || isSignupRoute) {
          return '/staff/dashboard';
        }
      }

      // ── Password recovery — checked BEFORE every other gate ──
      // A recovery session is a real session but must only be used to set
      // a new password. Send them to /update-password from anywhere else;
      // clear the flag the moment the new password is saved.
      if (authState.isRecoverySession && loc != '/update-password') {
        return '/update-password';
      }

      // ── Pending / rejected status (checked BEFORE dashboard redirect) ──
      // Admins bypass the approval gate — they authenticate directly via
      // Supabase Auth + has_role('ADMIN') and never need admin approval.
      if (!authState.isAdmin) {
        if (authState.isPendingApproval && !isApprovalRoute) {
          return '/pending-approval';
        }
        if (authState.isRejected && !isApprovalRoute) {
          return '/rejected';
        }
        // SUSPENDED and INACTIVE matched none of the checks above, so these
        // accounts fell through to a fully working dashboard with no
        // explanation. The revenue scheduler sets provider status to
        // SUSPENDED on its own when a subscription fee cannot be paid, so
        // this is reachable without the user doing anything.
        if (authState.isSuspendedOrInactive && !isApprovalRoute) {
          return '/suspended';
        }
      }

      // Approval resolved (e.g. admin approved while the user sat on the
      // pending screen and tapped REFRESH STATUS) — move to the dashboard
      // instead of dead-ending on the approval screen.
      //
      // The condition is "is APPROVED", not "is not pending and not
      // rejected". The looser form also matched SUSPENDED and INACTIVE, and
      // those are approval routes too: a suspended account sitting on
      // /suspended was forwarded to its dashboard, the suspended gate above
      // bounced it straight back, and the pair looped until go_router gave
      // up. The revenue scheduler suspends providers on its own when a
      // subscription fee cannot be paid, so that state is reached without
      // anybody doing anything.
      //
      // `/complete-profile` rides the same rule and needs no special case
      // here: a user who has finished completing their profile is either
      // APPROVED or still PENDING, and neither combination loops.
      if (isApprovalRoute && authState.isApproved) {
        return _getDashboardPath(authState);
      }

      // ── On an auth route (login, signup, role-select) — redirect away ──
      // The guest flag is already cleared by _AuthRefreshNotifier on the same
      // auth change that got us here, so a guest who signs in is forwarded to
      // their real dashboard with no trace of guest mode.
      if (isAuthRoute || isSignupRoute) {
        return _getDashboardPath(authState);
      }

      // ── On the splash screen — redirect to the correct dashboard ──
      if (loc == '/') {
        return _getDashboardPath(authState);
      }

      // Already on a dashboard or approval route — no redirect needed.
      return null;
    },
    routes: [
      GoRoute(path: '/', builder: (_, __) => const SplashScreen()),
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/role-select', builder: (_, __) => const RoleSelectionScreen()),
      // Google sign-in lands here when the profile the trigger built is
      // missing the fields verification needs. See the gate in redirect().
      GoRoute(
          path: '/complete-profile',
          builder: (_, __) => const CompleteProfileScreen()),
      GoRoute(
        path: '/signup/:role',
        builder: (_, state) {
          final r = state.pathParameters['role']!;
          // Part 6: `?assisted=1` is the staff door — the staff workspace's
          // "Register a provider" action pushes it, and the flag makes the
          // form demand a VALID staff referral code (the server keeps the
          // provider pending for document review through that code) and walk
          // the pair straight into /provider/documents afterwards. Ordinary
          // self-service signups never carry the parameter.
          final assisted = state.uri.queryParameters['assisted'] == '1';
          return SignupScreen(
            role: switch (r) {
              'user' => SignupRole.user,
              'vehicle' => SignupRole.vehicleProvider,
              'service' => SignupRole.serviceProvider,
              _ => SignupRole.user,
            },
            assistedByStaff: assisted,
          );
        },
      ),
      GoRoute(path: '/admin-login', builder: (_, __) => const AdminLoginScreen()),
      GoRoute(path: '/staff/login', builder: (_, __) => const StaffLoginScreen()),
      GoRoute(path: '/staff/dashboard', builder: (_, __) => const StaffDashboardScreen()),

      // Task 7 item 1: email OTP verification between the signup form and
      // account creation. Returns `true` when the code was verified.
      GoRoute(
        path: '/otp-verify',
        builder: (_, s) => OtpVerificationScreen(args: s.extra as OtpArgs),
      ),
      GoRoute(
        path: '/update-password',
        builder: (_, __) => const UpdatePasswordScreen(),
      ),
      GoRoute(
        path: '/terms',
        builder: (_, s) => TermsPolicyScreen(returnToSignup: s.extra == true),
      ),
      // The operative agreement on its own, reachable from the About screen and
      // the profile menu exactly as the policy is. The combined Terms & Privacy
      // Policy above is what the registration checkbox accepts; this page is
      // the Terms half, and mirrors docs/terms-of-service.html (the URL Play
      // Console can open next to the privacy policy).
      GoRoute(
        path: '/terms-of-service',
        builder: (_, __) => const TermsOfServiceScreen(),
      ),
      // What Aliob is, and how to reach a human. The profile's "About Aliob"
      // row pushed /terms before this screen existed -- legal copy where a
      // description belonged. The Terms screen is still reachable from signup,
      // the help chat and this screen's own footer.
      GoRoute(path: '/about', builder: (_, __) => const AboutUsScreen()),
      // Standalone profile. UserProfileScreen is normally a tab inside
      // /user, so providers and vehicle owners had no way to reach their own
      // account details — both dashboards offered a "Profile" button that
      // just said "Coming soon". The screen already carries its own Scaffold
      // and AppBar, so it routes as-is.
      GoRoute(path: '/profile', builder: (_, __) => const UserProfileScreen()),
      // The account screen's "Edit Profile" row pointed at nothing at all
      // before this route existed -- the tile had no onTap.
      GoRoute(path: '/profile/edit', builder: (_, __) => const EditProfileScreen()),
      GoRoute(path: '/pending-approval', builder: (_, __) => const PendingApprovalScreen()),
      GoRoute(path: '/rejected', builder: (_, __) => const RejectedScreen()),
      GoRoute(path: '/suspended', builder: (_, __) => const SuspendedScreen()),

      // ── User ──
      GoRoute(path: '/user', builder: (_, __) => const UserDashboard()),
      GoRoute(path: '/user/product/:id', builder: (_, s) => UserProductDetailScreen(productId: s.pathParameters['id']!)),
      GoRoute(path: '/user/provider/:id', builder: (_, s) => UserProviderDetailScreen(providerId: s.pathParameters['id']!)),
      GoRoute(path: '/user/category/:id', builder: (_, s) => UserCategoryScreen(categoryId: s.pathParameters['id']!)),
      // One big category's own screen: its sub-categories, searchable. The
      // 3-up card grid this replaces used to sit on Home, where it showed
      // tiny labels and number-only tiles.
      GoRoute(
        path: '/user/category-group/:group',
        builder: (_, s) =>
            UserCategoryGroupScreen(group: s.pathParameters['group']!),
      ),
      GoRoute(path: '/user/favorites', builder: (_, __) => const UserFavoritesScreen()),
      GoRoute(path: '/user/cart', builder: (_, __) => const UserCartScreen()),
      GoRoute(path: '/user/checkout', builder: (_, s) => UserCheckoutScreen(providerId: s.extra as String)),
      // The payment step, reached from checkout once the fulfillment choice is
      // settled: the platform's account, what the buyer wrote down, the proof
      // of payment and the place-order call. The draft arrives as `extra`; a
      // deep link has none, and the screen says so and sends the buyer to
      // their cart rather than rendering a payment form for nothing.
      GoRoute(
        path: '/user/payment',
        builder: (_, s) => UserPaymentScreen(draft: s.extra as OrderDraft?),
      ),
      // The availability gate every checkout entry funnels through: Buy/Book,
      // the product page's buy-now and the cart's CHECKOUT push this route,
      // and user_checkout_screen pushReplaces itself with it as the deep-link
      // backstop — no path reaches payment without the provider's YES.
      GoRoute(
        path: '/user/availability',
        builder: (_, s) {
          final args = (s.extra as Map?) ?? const {};
          return UserAvailabilityScreen(
              providerId: args['providerId'] as String? ?? '');
        },
      ),
      GoRoute(
        path: '/user/order-waiting',
        builder: (_, s) {
          final args = (s.extra as Map?) ?? const {};
          return ProviderOrderWaitingScreen(
            providerId: args['providerId'] as String? ?? '',
            providerName: args['providerName'] as String? ?? 'The provider',
            providerNotActivated: (args['providerNotActivated'] as bool?) ?? false,
          );
        },
      ),
      GoRoute(path: '/user/orders/:id', builder: (_, s) => UserOrderDetailScreen(orderId: s.pathParameters['id']!, viewerRole: s.extra as String? ?? 'user')),
      GoRoute(
        path: '/review/new',
        builder: (_, s) {
          final args = (s.extra as Map?) ?? const {};
          return ReviewFormScreen(
            orderId: args['orderId'] as String?,
            productId: args['productId'] as String?,
            providerId: args['providerId'] as String?,
          );
        },
      ),
      // Standalone search route: the screen is a bare Column (tab content),
      // so it must get a Material/Scaffold ancestor here — otherwise the
      // TextField crashes with "No Material widget found" and the in-build
      // error box overflows the unscrollable column.
      GoRoute(
        path: '/user/search',
        builder: (_, __) => Scaffold(
          appBar: AppBar(title: const Text('Search')),
          body: const SafeArea(child: UserSearchScreen()),
        ),
      ),
      // Destination may be handed over by the live map's "Where to?" flow as
      // `extra`; anything else arrives as null and the screen behaves exactly
      // as before. Parsed defensively because `extra` is untyped and a stale
      // deep link must not crash the route (it lands on an unset destination,
      // which the screen already requires the user to pick).
      GoRoute(
        path: '/user/ride-request',
        builder: (_, state) {
          final extra = state.extra;
          final map = extra is Map ? Map<String, dynamic>.from(extra) : const <String, dynamic>{};
          return UserRideRequestScreen(
            initialDestinationLabel: map['label'] as String?,
            initialDestinationLat: (map['lat'] as num?)?.toDouble(),
            initialDestinationLng: (map['lng'] as num?)?.toDouble(),
          );
        },
      ),
      GoRoute(path: '/user/ride-active', builder: (_, __) => const UserActiveRideScreen()),
      GoRoute(path: '/user/ride-history', builder: (_, __) => const RideHistoryScreen(isProvider: false)),
      // The live map hub: nearby vehicles moving in real time, "Where to?"
      // search, category shortcuts and the Safety Center. Reachable from the
      // user dashboard, which is what the earlier finding (GPS features
      // absent from navigation entirely) asked for.
      GoRoute(
          path: '/map',
          builder: (_, __) => const LiveMapScreen(mode: LiveMapMode.rider)),

      // ── Service Provider ──
      GoRoute(path: '/provider', builder: (_, __) => const ServiceProviderDashboard()),
      GoRoute(
        path: '/provider/payment-methods',
        builder: (_, __) => const ProviderPaymentMethodsScreen(),
      ),
      // Buyer-visible approved destination: the exact GPS + contact a buyer
      // reads only after a payment screenshot is uploaded and approved by the
      // provider or an admin.
      GoRoute(
        path: '/provider/location/:id',
        builder: (_, s) => ProviderLocationDetailScreen(providerId: s.pathParameters['id']!),
      ),
      // The trade-specific settings and pricing form. The fields are defined
      // per category by an administrator; this is where a provider fills them
      // in.
      GoRoute(
          path: '/provider/category-settings',
          builder: (_, __) => const ProviderCategorySettingsScreen()),
      // The provider's own business profile: name, description, contact, GPS,
      // photo, and the price range a buyer reads on their public page.
      // `/provider/business` is what the dashboard's Business Profile card and
      // the readiness banner already push -- with no route registered those
      // taps went nowhere, and `provider_profiles.price_range` had no editor
      // anywhere in the app.
      GoRoute(
          path: '/provider/business',
          builder: (_, __) => const ProviderBusinessProfileScreen()),
      // Parts 1 and 8: document verification is voluntary and self-serve —
      // the provider's own "Verify Documents" screen (Settings → Verify
      // Documents), and the first stop after a staff-assisted signup. Nothing
      // else routes here as a gate: posting and trading never require it.
      GoRoute(
          path: '/provider/documents',
          builder: (_, __) => const ProviderDocumentsScreen()),
      GoRoute(path: '/provider/orders', builder: (_, __) => const ProviderOrdersScreen()),
      // Provider-side buyer-payment verification. A payment from a buyer INTO
      // the provider's own account may be confirmed by the provider (who can
      // see the money arrived) or by an admin. A platform wallet top-up stays
      // admin-only and lives at /admin/payments instead.
      GoRoute(
        path: '/provider/payment-verification',
        builder: (_, __) =>
            const AdminOrderPaymentsScreen(providerMode: true),
      ),
      GoRoute(path: '/provider/products', builder: (_, __) => const ProviderProductListScreen()),
      // Read-only billing view. The charge itself is performed server-side by
      // subscription-process on an n8n schedule, so this never writes.
      GoRoute(path: '/provider/subscription', builder: (_, __) => const ProviderSubscriptionScreen()),
      GoRoute(path: '/provider/products/new', builder: (_, __) => const ProviderProductFormScreen()),
      GoRoute(path: '/provider/products/:id', builder: (_, s) => ProviderProductFormScreen(productId: s.pathParameters['id'])),

      // ── Wallet (provider) ──
      GoRoute(path: '/wallet', builder: (_, __) => const WalletScreen()),
      GoRoute(path: '/wallet/recharge', builder: (_, __) => const RechargeScreen()),
      // Points, rank and the conversion into wallet credit. Reachable by any
      // signed-in account: a customer earns points too and can see what they
      // would be worth once they hold a business account.
      GoRoute(path: '/points', builder: (_, __) => const PointsScreen()),

      // ── Vehicle Provider ──
      GoRoute(path: '/vehicle', builder: (_, __) => const VehicleProviderDashboard()),
      GoRoute(path: '/vehicle/vehicles', builder: (_, __) => const VehicleManagementScreen()),
      GoRoute(path: '/vehicle/vehicles/new', builder: (_, __) => const VehicleFormScreen()),
      GoRoute(path: '/vehicle/vehicles/:id', builder: (_, s) => VehicleFormScreen(vehicleId: s.pathParameters['id'])),
      GoRoute(path: '/vehicle/ride-requests', builder: (_, __) => const DriverRideRequestsScreen()),
      // No :id parameter — DriverTripScreen resolves the driver's active ride
      // itself via RideService.getMyActiveDriverRide(). The route previously
      // declared `:id`, but both call sites (driver_ride_requests_screen and
      // vehicle_provider_dashboard) pushed a bare '/vehicle/trip', which does
      // not match a ':id' route — so a driver who claimed a ride landed on
      // go_router's "no routes for location" error page instead of the trip.
      GoRoute(path: '/vehicle/trip', builder: (_, __) => const DriverTripScreen()),
      GoRoute(path: '/vehicle/history', builder: (_, __) => const RideHistoryScreen(isProvider: true)),
      // The driver's live map: availability, their own moving pin, and the open
      // ride requests around them. Same screen as the rider's, different mode.
      GoRoute(
          path: '/vehicle/map',
          builder: (_, __) => const LiveMapScreen(mode: LiveMapMode.driver)),

      // ── CEO ──
      // Above the admin tier, not replacing it. A CEO account also holds
      // ADMIN, so /admin/* stays reachable; this route only adds the views and
      // the one destructive act an admin does not have. The screen re-checks
      // isCeo and renders an explanation rather than the workspace for anyone
      // else, and every query behind it is checked again server-side by
      // is_ceo() -- this route registration is navigation, not protection.
      GoRoute(path: '/ceo', builder: (_, __) => const CeoDashboard()),

      // ── Admin ──
      GoRoute(path: '/admin', builder: (_, __) => const AdminDashboard()),
      GoRoute(path: '/admin/approvals', builder: (_, __) => const AdminProviderManagementScreen()),
      GoRoute(path: '/admin/providers', builder: (_, __) => const AdminProviderManagementScreen()),
      GoRoute(path: '/admin/users', builder: (_, __) => const AdminUserManagementScreen()),
      GoRoute(path: '/admin/payment-methods', builder: (_, __) => const AdminPaymentMethodsScreen()),
      // Item 5: the banks table (what a valid account number IS) and every
      // provider's accounts, disableable from here.
      GoRoute(path: '/admin/payment-accounts', builder: (_, __) => const AdminPaymentAccountsScreen()),
      GoRoute(path: '/admin/payments', builder: (_, __) => const AdminPaymentVerificationScreen()),
      // The queue of identity documents waiting for a decision.
      // review_user_document() existed since 20260927000030 but was only
      // reachable from a dialog inside one user row, so the only way to work
      // the queue was to already know whose document to open. Admin-only by
      // construction: the RPC re-checks is_admin() server-side, and the SELECT
      // policy is `user_id = auth.uid() OR is_admin()`.
      GoRoute(
          path: '/admin/document-verification',
          builder: (_, __) => const AdminDocumentVerificationScreen()),
      GoRoute(path: '/admin/order-payments', builder: (_, __) => const AdminOrderPaymentsScreen()),
      // Every order on the platform — the screen the dashboard's "Orders"
      // quick-stat tile opens. There was no admin order list at all before
      // this: the tile counted orders and went nowhere.
      GoRoute(path: '/admin/orders', builder: (_, __) => const AdminOrdersScreen()),
      // The buyer/provider availability queue — who asked, who answered,
      // how long it took. The pre-order gate's rows, visible to the person
      // who has to arbitrate a dispute about them.
      GoRoute(path: '/admin/availability', builder: (_, __) => const AdminAvailabilityScreen()),
      GoRoute(path: '/admin/providers/:id/wallet', builder: (_, s) => AdminProviderWalletScreen(providerId: s.pathParameters['id']!)),
      GoRoute(path: '/admin/providers/:id/wallet/recharge', builder: (_, s) => AdminCashRechargeScreen(providerId: s.pathParameters['id']!)),
      // ── Admin — New sections ──
      GoRoute(path: '/admin/transactions', builder: (_, __) => const AdminTransactionHistoryScreen()),
      GoRoute(path: '/admin/registrations', builder: (_, __) => const AdminRegistrationHistoryScreen()),
      GoRoute(path: '/admin/income', builder: (_, __) => const AdminIncomeSummaryScreen()),
      GoRoute(path: '/admin/expenses', builder: (_, __) => const AdminExpenseScreen()),
      GoRoute(path: '/admin/reports', builder: (_, __) => const AdminReportsScreen()),
      GoRoute(path: '/admin/support-tickets', builder: (_, __) => const AdminSupportTicketsScreen()),
      GoRoute(path: '/admin/appeals', builder: (_, __) => const AdminAppealsScreen()),
      GoRoute(path: '/admin/disputes', builder: (_, __) => const AdminDisputesScreen()),
      GoRoute(path: '/admin/history', builder: (_, __) => const AdminHistoryScreen()),
      GoRoute(path: '/admin/staff', builder: (_, __) => const AdminStaffScreen()),
      // CEO account directory: every registered account, with the delete
      // action that runs through the shared deletion cascade. Navigation is
      // not protection — the RPCs behind the screen re-derive the CEO
      // authority server-side on every call.
      GoRoute(path: '/admin/accounts', builder: (_, __) => const AdminAccountDirectoryScreen()),
      // Task 3: role management console (true-Admin-only page + per-staff
      // permission control; server paths re-check authorization).
      GoRoute(path: '/admin/staff-assignment', builder: (_, __) => const AdminStaffAssignmentScreen()),
      GoRoute(path: '/admin/roles/permissions', builder: (_, __) => const AdminRolePermissionsScreen()),
      GoRoute(path: '/admin/send-notifications', builder: (_, __) => const AdminNotificationSendScreen()),
      // The generic settings editor: fees, thresholds, the points awards and
      // the points-to-birr rate, editable without a migration.
      GoRoute(path: '/admin/settings', builder: (_, __) => const AdminSettingsScreen()),
      // Parts 3 and 4: the platform's contact number and payment account, as
      // data. Admin → Contact Settings and Admin → Payment Settings are two
      // doors into this one screen (`initialSection` focuses the right half);
      // every buyer-facing card reads the values through
      // public_app_settings() (migration 20261014000003).
      GoRoute(
          path: '/admin/platform-settings',
          builder: (_, s) {
            final section = s.uri.queryParameters['section'];
            return AdminPlatformSettingsScreen(
              initialSection: section == 'payment' ? 'payment' : 'contact',
            );
          }),
      // Item I: the forced-update policy — latest/minimum build per platform,
      // the store link, the per-locale message, the force switch, and the
      // "notify all users" blast. Admin-only; the server gates every write on
      // is_admin() and refuses a force without the store confirmation.
      GoRoute(
          path: '/admin/app-releases',
          builder: (_, __) => const AdminAppReleasesScreen()),
      // Fee & pricing control panel. Editing is CEO/owner-only, enforced inside
      // admin_update_setting() — a non-owner admin sees the values and why
      // they cannot change them, instead of buttons that would fail.
      GoRoute(path: '/admin/fees', builder: (_, __) => const FeeSettingsScreen()),
      // Per-category and per-city overrides. Separate from /admin/fees
      // because that one edits the global rates in system_settings and this
      // one edits what a specific category (or a specific category in a
      // specific city) pays instead.
      GoRoute(
          path: '/admin/fees/categories',
          builder: (_, __) => const CategoryFeeSettingsScreen()),

      // The category tree itself, and the door that grows it. The sibling
      // routes above are about what a category CHARGES and what a provider is
      // ASKED; this one is about which categories exist. Before it, adding one
      // meant a migration — see admin_categories_screen.dart.
      GoRoute(
          path: '/admin/categories',
          builder: (_, __) => const AdminCategoriesScreen()),

      // What each trade's provider is asked for, and what it costs. The
      // control surface for the provider's own settings form: a hotel is
      // asked for room types and a nightly rate, a doctor for an hourly price.
      GoRoute(
          path: '/admin/category-fields',
          builder: (_, __) => const AdminCategoryFieldsScreen()),

      // Content control: the report queue, the moderation log, and the two
      // actions nothing else could do — remove one uploaded image, suspend an
      // account. Admin-only by construction: the server refuses every call to
      // a non-admin before doing anything.
      GoRoute(
          path: '/admin/content',
          builder: (_, __) => const AdminContentControlScreen()),

      // The dedicated image-delete list, reached from Content Control's own
      // delete strip. Content Control renders a short strip of the gallery it
      // already loaded; this is the full-page tool over the same
      // `admin_public_image_gallery` rows.
      GoRoute(
          path: '/admin/content/image-delete',
          builder: (_, __) => const ImageDeleteSheet()),

      // The slips for one order or one ride. Both parties and admins may read
      // them; `my_transaction_documents` decides who, not this route.
      GoRoute(
        path: '/documents/:type/:id',
        builder: (_, state) => TransactionDocumentsScreen(
          subjectType: state.pathParameters['type']!.toUpperCase(),
          subjectId: state.pathParameters['id']!,
          title: state.pathParameters['type']!.toUpperCase() == 'RIDE'
              ? 'Ride documents'
              : 'Order documents',
        ),
      ),

      // ── Help (signed-in users) ──
      GoRoute(path: '/help', builder: (_, __) => const HelpChatScreen()),
      // User-submitted appeal / spam-report form (linked from the help chat).
      GoRoute(path: '/appeal', builder: (_, __) => const AppealScreen()),
      // Both sides of an appeal: what I filed (status + resolution + reply)
      // and what was filed against me (with the Respond action).
      GoRoute(path: '/appeals', builder: (_, __) => const MyAppealsScreen()),

      // ── Self-service account actions (any signed-in account) ──
      // Submission opens a request; staff decide. Nothing deletes on submit.
      GoRoute(path: '/account/deletion', builder: (_, __) => const AccountDeletionScreen()),
      GoRoute(path: '/account/password', builder: (_, __) => const ChangePasswordScreen()),
      // Become a Partner: an existing user applying to run a business, through
      // the same approval pipeline a fresh provider signup uses.
      GoRoute(path: '/become-partner', builder: (_, __) => const BecomePartnerScreen()),

      // ── Provider extras ──
      GoRoute(
        path: '/provider/gallery/:id',
        builder: (_, s) => ProviderGalleryScreen(providerId: s.pathParameters['id']!),
      ),
      // A provider rating the customer on a completed order.
      GoRoute(
        path: '/review/customer',
        builder: (_, s) => RateCustomerScreen(
          orderId: s.extra is Map ? '${(s.extra as Map)['order_id']}' : '',
          customerId: s.extra is Map ? '${(s.extra as Map)['customer_id']}' : '',
          customerName: s.extra is Map ? (s.extra as Map)['customer_name'] as String? : null,
        ),
      ),

      // ── Staff queue: account deletion requests ──
      GoRoute(path: '/admin/deletions', builder: (_, __) => const AdminDeletionRequestsScreen()),

      // Task 7 item 2: standalone notification inbox for providers/vehicle
      // owners (their dashboards' bell). Users get the same screen as a
      // dashboard tab; staff in the admin panel have /admin/send-notifications.
      GoRoute(
          path: '/admin-notifications',
          builder: (_, __) => const Scaffold(body: UserNotificationsScreen())),
    ],
  );
});

String _getDashboardPath(AuthState auth) {
  if (auth.isStaffMember) return '/staff/dashboard';
  if (auth.isAdmin) return '/admin';
  if (auth.primaryRole == AppUserRole.vehicleProvider) return '/vehicle';
  if (auth.primaryRole == AppUserRole.serviceProvider) return '/provider';
  return '/user';
}

bool _isApprovalRoute(String path) {
  // /complete-profile belongs here, not in isAuthRoute. An OAuth account is
  // PENDING_APPROVAL, so the pending/rejected/suspended gates would bounce the
  // user straight off the completion screen and the completeness gate would
  // send them back — an infinite loop. Listing it as an approval route makes
  // all three gates skip it in one place, and the "approval resolved" branch
  // then correctly forwards a user who has finished it.
  return path == '/pending-approval' ||
      path == '/rejected' ||
      path == '/suspended' ||
      path == '/complete-profile';
}
