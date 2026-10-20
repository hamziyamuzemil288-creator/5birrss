import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/city_service.dart';
import '../models/models.dart';
import '../services/supabase_service.dart';
import '../services/provider_presence_service.dart';
import '../utils/friendly_error.dart';
import '../utils/phone_formatter.dart';

/// Application roles matching the Supabase `app_role` enum.
///
/// There is deliberately no `ceo` member. The CEO is NOT an app_role value in
/// the database: `public.is_ceo()` is true for a staff row flagged `is_ceo`,
/// or for the account that holds ADMIN and has no staff row at all — the
/// external true Admin, i.e. the owner's own account. A `ceo` enum member here
/// would parse a role string that is never written, so it would always be
/// false and the CEO would see an empty workspace.
enum AppUserRole { user, vehicleProvider, serviceProvider, admin }

/// Complete auth state for the application.
class AuthState {
  final User? user;
  final UserProfile? profile;
  final List<AppUserRole> roles;
  final AppUserRole? primaryRole;
  final bool isStaffGateway;
  final bool isLoading;
  final String? error;

  /// `public.is_ceo_authority()` — is_ceo() OR is_super_admin() — as the
  /// SERVER answers it, resolved once per session.
  ///
  /// [isCeo] models only one of the two shapes `is_ceo()` accepts. It reads
  /// "holds ADMIN and has no staff gateway row", while the database also accepts
  /// **a staff row flagged `staff.is_ceo`** (the shape 20260922000012 creates).
  /// For an owner whose authority comes from that staff row the client said
  /// "not the CEO" while every server gate — the CEO workspace,
  /// `ceo_account_directory()` and `ceo_delete_user_account()` — said
  /// otherwise: the CEO-only door was missing from the sidebar, the workspace
  /// answered "for the CEO account only", and the account directory (the one
  /// place a full user or provider profile can be deleted outright) was
  /// unreachable. That is the same class of defect as a delete button that
  /// does nothing: the client refusing a door the server opens.
  ///
  /// Asked of the database rather than re-derived, so there is one definition
  /// of "the CEO" instead of two that can drift. False when the call fails:
  /// a failed check must never widen authority.
  final bool isCeoAuthority;

  /// True while the session came from a password-recovery link — the
  /// router must send the user to /update-password before anything else.
  final bool isRecoverySession;

  /// True when this account already runs a business of either kind.
  ///
  /// Used to hide "Become a Partner": a customer turning their existing
  /// account into a business is the case that button is for, and somebody who
  /// is already a provider pressing it would only be told they have one
  /// already. An account can hold USER *and* a provider role at once, so this
  /// checks the provider roles rather than primaryRole.
  bool get isProvider =>
      roles.contains(AppUserRole.serviceProvider) ||
      roles.contains(AppUserRole.vehicleProvider);

  const AuthState({
    this.user,
    this.profile,
    this.roles = const [],
    this.primaryRole,
    this.isStaffGateway = false,
    this.isLoading = true,
    this.error,
    this.isCeoAuthority = false,
    this.isRecoverySession = false,
  });

  AuthState copyWith({
    User? user,
    UserProfile? profile,
    List<AppUserRole>? roles,
    AppUserRole? primaryRole,
    bool? isStaffGateway,
    bool? isLoading,
    String? error,
    bool? isCeoAuthority,
    bool? isRecoverySession,
    bool clearError = false,
  }) {
    return AuthState(
      user: user ?? this.user,
      profile: profile ?? this.profile,
      roles: roles ?? this.roles,
      primaryRole: primaryRole ?? this.primaryRole,
      isStaffGateway: isStaffGateway ?? this.isStaffGateway,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      isCeoAuthority: isCeoAuthority ?? this.isCeoAuthority,
      isRecoverySession: isRecoverySession ?? this.isRecoverySession,
    );
  }

  bool get isAuthenticated => user != null;
  bool get isAdmin => roles.contains(AppUserRole.admin);

  /// True for the CEO: the owner's own account.
  ///
  /// This mirrors `public.is_ceo()` exactly, using state this class already
  /// has. That function is true for the "external true Admin": an account
  /// holding the ADMIN app_role with NO staff row. The negative half is
  /// already computed here — [isStaffMember] is `isStaffGateway && isAdmin`,
  /// and a staff gateway is precisely an admin that DOES have a staff row. So
  /// "ADMIN and no staff row" is `isAdmin && !isStaffMember`, with no second
  /// source of truth and no extra round trip.
  ///
  /// A UI convenience only. Every destructive action is re-checked
  /// server-side (`is_ceo()` in Postgres, and the user-admin Edge Function for
  /// auth deletion); a Flutter gate avoids showing a button that will be
  /// refused, it does not protect one.
  bool get isCeo => isAdmin && !isStaffMember;
  bool get isStaffMember => isStaffGateway && isAdmin;

  /// The CEO-only surfaces — the CEO workspace and the account directory —
  /// open for EITHER answer.
  ///
  /// [isCeo] is the local heuristic; [isCeoAuthority] is what the database says
  /// and is the predicate the two RPCs behind those screens actually check
  /// (`is_ceo_authority()`). Requiring both would hide the door from a real CEO
  /// whose authority comes from a staff row flagged `is_ceo`; requiring only
  /// the heuristic is what left that CEO with a workspace that answered "for
  /// the CEO account only". Neither half grants anything: every screen behind
  /// the door re-checks server-side.
  bool get canOpenCeoOnly => isCeo || isCeoAuthority;
  bool get isVehicleProvider => roles.contains(AppUserRole.vehicleProvider);
  bool get isServiceProvider => roles.contains(AppUserRole.serviceProvider);
  bool get isUser => roles.contains(AppUserRole.user);
  bool get isPendingApproval =>
      profile != null && profile!.status == 'PENDING_APPROVAL';
  bool get isApproved => profile != null && profile!.status == 'APPROVED';
  bool get isRejected => profile != null && profile!.status == 'REJECTED';

  /// SUSPENDED and INACTIVE are terminal account states that the router must
  /// gate. They used to match none of the checks above, so a suspended user
  /// landed on a normal dashboard with no indication anything was wrong —
  /// even though `suspend_provider` had emailed them "Account suspended" and
  /// the revenue scheduler sets SUSPENDED on its own when a subscription fee
  /// cannot be paid.
  ///
  /// INACTIVE is grouped here deliberately: it is the same user-facing
  /// outcome (no access, needs a human) and nothing in the app transitions
  /// between the two.
  bool get isSuspendedOrInactive {
    if (profile == null) return false;
    const blocked = {'SUSPENDED', 'INACTIVE'};
    return blocked.contains(profile!.status);
  }
}

/// Auth state notifier managing Supabase auth + profile + roles.
class AuthNotifier extends StateNotifier<AuthState> {
  final SupabaseService _svc;
  StreamSubscription<dynamic>? _authSub;

  /// Monotonically increasing counter so that an older _loadUserProfile
  /// call cannot overwrite state produced by a newer one.
  int _profileLoadSeq = 0;

  AuthNotifier(this._svc) : super(const AuthState(isLoading: true)) {
    _init();
  }

  void _init() {
    // Listen for auth state changes
    _authSub = _svc.authStateChanges.listen((authState) async {
      final event = authState.event;
      final session = authState.session;

      if (event == AuthChangeEvent.signedIn && session != null) {
        await _loadUserProfile(session.user);
      } else if (event == AuthChangeEvent.signedOut) {
        state = const AuthState(isLoading: false);
      } else if (event == AuthChangeEvent.tokenRefreshed && session != null) {
        await _loadUserProfile(session.user);
      } else if (event == AuthChangeEvent.passwordRecovery && session != null) {
        // The password-reset email was opened on this device. The session
        // is real but must only be used to set a new password — flag the
        // state so the router lands on /update-password.
        await _loadUserProfile(session.user, isRecovery: true);
      }
    });

    // Check existing session
    final currentSession = _svc.client.auth.currentSession;
    if (currentSession != null) {
      _loadUserProfile(currentSession.user);
    } else {
      state = const AuthState(isLoading: false);
    }
  }

  Future<void> _loadUserProfile(User user, {bool isRecovery = false}) async {
    // Bump the sequence so an older in-flight call cannot overwrite our result.
    final seq = ++_profileLoadSeq;

    try {
      // Load profile — timeout so a hanging query can never leave the UI stuck
      final profileData = await _svc.client
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle()
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'profiles query timed out after 10 seconds',
            ),
          );

      // A newer load has started — discard this stale result.
      if (seq != _profileLoadSeq) return;

      UserProfile? profile;
      if (profileData != null) {
        profile = UserProfile.fromJson(profileData);
      }

      // Load roles — also timeout-protected
      final rolesData = await _svc.client
          .from('user_roles')
          .select('role')
          .eq('user_id', user.id)
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException(
              'user_roles query timed out after 10 seconds',
            ),
          );

      // Another stale check after the second query.
      if (seq != _profileLoadSeq) return;

      final roles = (rolesData as List)
          .map((r) => _parseRole(r['role'] as String))
          .toList();

      // Gateway accounts are ADMIN-role identities, but they use the staff
      // workspace rather than the CEO/admin dashboard. This lookup is
      // deliberately user-scoped and contains no password data.
      bool isStaffGateway = false;
      try {
        // Bounded for the same reason the two queries above are: this runs
        // INSIDE signUp()/signIn()'s await chain, on screens that show a
        // blocking spinner. A query that never answers is not an error, so
        // nothing catches it and the spinner never clears.
        final gateway = await _svc.client
            .from('staff_credentials')
            .select('staff_id')
            .eq('user_id', user.id)
            .maybeSingle()
            .timeout(const Duration(seconds: 10));
        isStaffGateway = gateway != null;
      } catch (_) {
        // A pre-Task-12 database has no gateway table. Preserve the existing
        // login behavior until the migration is deployed.
      }

      final primaryRole = roles.firstWhere(
        (r) => r != AppUserRole.user,
        orElse: () => AppUserRole.user,
      );

      // The CEO authority, asked of the server. [isCeo] above is a heuristic
      // that misses the "staff row flagged is_ceo" shape of the same role; the
      // two CEO-only RPCs behind the account directory gate on
      // is_ceo_authority(), so the doors that lead to them must read the same
      // answer. Best-effort: a failure leaves the local rule as the only
      // authority rather than granting anything.
      var isCeoAuthority = false;
      try {
        isCeoAuthority = await _svc.client
                .rpc('is_ceo_authority')
                .timeout(const Duration(seconds: 10)) ==
            true;
      } catch (_) {}

      state = state.copyWith(
        user: user,
        profile: profile,
        roles: roles,
        primaryRole: primaryRole,
        isStaffGateway: isStaffGateway,
        isCeoAuthority: isCeoAuthority,
        isLoading: false,
        error: null,
        // Keeps the recovery flag across later token refreshes, and only
        // ever turns it on here (copyWith keeps the previous value).
        isRecoverySession: isRecovery ? true : null,
      );

      // Presence heartbeat: while a provider is signed in and the app is
      // running, periodically touch last_active_at for online/last-seen.
      if (primaryRole == AppUserRole.serviceProvider ||
          primaryRole == AppUserRole.vehicleProvider) {
        ProviderPresence.instance.startHeartbeat();
      } else {
        ProviderPresence.instance.stopHeartbeat();
      }
    } catch (e) {
      // Only apply error state if no newer load has taken over.
      if (seq != _profileLoadSeq) return;
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth profile-load failed: $e');
      state = state.copyWith(
        user: user,
        isLoading: false,
        error: friendlyError(e, context: 'Could not load your account'),
      );
    }
  }

  AppUserRole _parseRole(String role) {
    switch (role) {
      case 'ADMIN':
        return AppUserRole.admin;
      case 'VEHICLE_PROVIDER':
        return AppUserRole.vehicleProvider;
      case 'SERVICE_PROVIDER':
        return AppUserRole.serviceProvider;
      default:
        return AppUserRole.user;
    }
  }

  /// Sign up a regular user with email + password.
  /// Phone number is stored in the profile but NOT used for auth.
  /// No national ID is collected at user signup — ID is requested later at
  /// booking time for booking-type orders.
  ///
  /// IMPORTANT: all profile data is passed via signUp(data: ...) metadata —
  /// the SECURITY DEFINER handle_new_user() trigger creates the profile
  /// (and the provider profile when provider_type is present), the USER
  /// role, and the approval request. The app never writes tables client-
  /// side during signup, so this works whether or not Supabase returns a
  /// session (e.g. if email confirmation is ever re-enabled).
  Future<void> signUp({
    required String email,
    required String phone,
    required String password,
    required String fullName,
    required AppUserRole role,
    String? city,
    String? kebele,
    String? streetRoad,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Format phone to E.164 for profile storage (not auth)
      final e164 = PhoneFormatter.formatToE164(phone);

      final response = await _svc.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': fullName,
          'phone': e164 ?? phone,
          if (city != null && city.isNotEmpty) 'city': city,
          if (kebele != null && kebele.isNotEmpty) 'kebele': kebele,
          if (streetRoad != null && streetRoad.isNotEmpty)
            'street_road': streetRoad,
        },
        // BOUNDED, deliberately. This is the call the "Creating account…"
        // scrim waits on; GoTrue runs handle_new_user() inside it, so a slow
        // or stalled signup is indistinguishable from a hang and NOTHING will
        // throw to dismiss the scrim. Twenty seconds is well past a healthy
        // signup (a second or two) and short enough to be a message rather
        // than a mystery.
      ).timeout(const Duration(seconds: 20));

      if (response.user == null) {
        throw Exception('Sign up failed: no user returned');
      }

      // Email confirmation is disabled in Supabase Auth (admin approval is
      // the account gate), so a session is issued immediately. If a session
      // is somehow still absent, reset to a logged-out state so the router
      // treats the user as unauthenticated and the UI sends them to sign in.
      if (response.session == null) {
        state = const AuthState(isLoading: false);
        return;
      }

      // Session available — load the profile created by the trigger
      // (status PENDING_APPROVAL, so the router lands on
      // /pending-approval).
      await _loadUserProfile(response.user!);
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not create your account'),
      );
      rethrow;
    }
  }

  /// Sign up as a provider (vehicle or service) with email + password.
  /// Phone number is stored in the profile but NOT used for auth.
  ///
  /// All writes happen server-side: handle_new_user() creates the profile
  /// AND the provider_profiles row (from provider_type in the signup
  /// metadata); trg_provider_profiles_auto_setup then assigns the provider
  /// role and opens the approval request. The app never writes tables
  /// client-side during signup, so this works whether or not Supabase
  /// returns a session.
  /// No national ID is collected here for any role. The document is uploaded
  /// later, in-app, through the verification step before a provider may
  /// upload a product or a vehicle provider may claim a ride.
  Future<void> signUpAsProvider({
    required String email,
    required String phone,
    required String password,
    required String businessName,
    required String providerType,
    String? city,
    String? kebele,
    String? streetRoad,
    // Task 8: optional referral code identifying the sales/staff person who
    // registered this provider. Resolved server-side by handle_new_user()
    // against referral_codes; blank/unknown codes never block registration.
    String? referralCode,
    // The trade this provider is registering as. Asked at the signup gate
    // (20260927000128) because it selects their whole settings form: a hotel
    // is asked for room types, a doctor for an hourly rate. Recorded right
    // after the account exists, through a definer RPC that validates the
    // sector against the provider type.
    String? categoryId,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      // Format phone to E.164 for profile storage (not auth)
      final e164 = PhoneFormatter.formatToE164(phone);

      final response = await _svc.client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': businessName,
          'phone': e164 ?? phone,
          'provider_type': providerType,
          'business_name': businessName,
          if (city != null && city.isNotEmpty) 'city': city,
          if (kebele != null && kebele.isNotEmpty) 'kebele': kebele,
          if (streetRoad != null && streetRoad.isNotEmpty)
            'street_road': streetRoad,
          if (referralCode != null && referralCode.trim().isNotEmpty)
            'referral_code': referralCode.trim(),
        },
      ).timeout(const Duration(seconds: 20));

      if (response.user == null) {
        throw Exception('Sign up failed');
      }

      // No-session fallback — see signUp() above.
      if (response.session == null) {
        state = const AuthState(isLoading: false);
        return;
      }

      // Session available — load the profile + provider profile created
      // by the triggers.
      //
      // The trade the provider picked at the signup gate is recorded first, so
      // the dashboard and the settings screen already know which form to show.
      // Best-effort and never fatal: the provider_profiles row exists already
      // (created by the trigger, with no category), and a failure here leaves
      // it NULL rather than stranding an account that was already made. The
      // category settings screen offers the same picker, so the provider is
      // one tap from fixing it.
      if (categoryId != null && categoryId.isNotEmpty) {
        try {
          // Bounded: best-effort bookkeeping must not hold the signup
          // spinner — the account and its provider row already exist.
          await _svc.client
              .rpc('provider_claim_category',
                  params: {'p_category_id': categoryId})
              .timeout(const Duration(seconds: 10));
        } catch (e) {
          debugPrint('provider_claim_category failed (non-fatal): $e');
        }
      }

      await _loadUserProfile(response.user!);
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not send the reset email'),
      );
      rethrow;
    }
  }

  /// Sends the password-reset email for [email].
  ///
  /// The link opens the app through the Supabase deep-link scheme
  /// (registered in AndroidManifest.xml) and fires AuthChangeEvent
  /// .passwordRecovery, which flags the session and sends the user to
  /// /update-password. Always completes without telling the caller
  /// whether the address exists (account-enumeration safe).
  Future<void> resetPassword({required String email}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'io.supabase.com.amistbirr.myapp://login-callback/',
      );
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not sign in'),
      );
      rethrow;
    }
    state = state.copyWith(isLoading: false);
  }

  /// Sign in with email + password.
  /// Profile loading is handled exclusively by the _authSub listener
  /// when AuthChangeEvent.signedIn fires — no need to call
  /// _loadUserProfile here (it would cause a redundant double-call).
  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      // _authSub listener will pick up AuthChangeEvent.signedIn
      // and call _loadUserProfile automatically.
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      //
      // The context used to say "Could not sign in with Google" here — a
      // copy-paste from signInWithGoogle() below. splash_screen renders
      // state.error verbatim, so a rejected password on the email path
      // surfaced the words "Could not sign in with Google. ..." to a user
      // who never touched the Google button, which is actively misleading
      // about the one thing they just did.
      debugPrint('auth signIn failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not sign in'),
      );
      rethrow;
    }
  }

  /// Task 15: continue with Google (Supabase Auth OAuth provider).
  ///
  /// Opens the system browser for the Google consent screen; Supabase
  /// redirects back into the app via the same deep-link scheme the
  /// password-recovery flow already registers. The session then arrives
  /// through _authSub (AuthChangeEvent.signedIn) and the normal profile
  /// load runs — the account the OAuth trigger creates lands
  /// PENDING_APPROVAL exactly like an email signup, so the router sends
  /// the user to /pending-approval. Nothing else changes for OAuth users.
  ///
  /// [isSignup] only picks the button copy's context — the OAuth flow is
  /// identical for signing in and signing up (Supabase upserts the user).
  Future<void> signInWithGoogle() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      await _svc.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'io.supabase.com.amistbirr.myapp://login-callback/',
      );
      // The browser round-trip continues async; _authSub completes the
      // sign-in when the deep link returns. Reset the spinner here so a
      // user who cancels the consent screen is not stuck loading.
      if (state.isLoading) {
        state = state.copyWith(isLoading: false);
      }
    } catch (e) {
// Keep the raw exception in the console for debugging; only the
      // user-facing text changes. splash_screen renders state.error
      // verbatim, so an unfiltered PostgrestException would put schema
      // detail on screen.
      debugPrint('auth could failed: $e');
      state = state.copyWith(
        isLoading: false,
        error: friendlyError(e, context: 'Could not load your account'),
      );
      rethrow;
    }
  }

  /// Clear the recovery-session flag after the new password was saved,
  /// so the router resumes the normal authenticated flow.
  void clearRecoveryFlag() {
    if (!state.isRecoverySession) return;
    state = state.copyWith(isRecoverySession: false);
  }

  /// Sign out.
  Future<void> signOut() async {
    ProviderPresence.instance.stopHeartbeat();
    await _svc.client.auth.signOut();
    state = const AuthState(isLoading: false);
  }

  /// Refresh profile from database.
  Future<void> refreshProfile() async {
    if (state.user != null) {
      await _loadUserProfile(state.user!);
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    ProviderPresence.instance.stopHeartbeat();
    super.dispose();
  }
}

/// Provider instance.
/// Phase 1: multi-city state (saved city + travel-mode browsing).
/// Exposes the shared singleton so every reader sees the same state;
/// recreated provider stays cheap and sign-out-safe via loadSavedCity.
final cityProvider = Provider<CityService>((ref) => CityService.instance);

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier(SupabaseService.instance);
});

/// Convenience provider: is the user authenticated?
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authProvider).isAuthenticated;
});

/// Convenience provider: the user's primary non-USER role.
final primaryRoleProvider = Provider<AppUserRole?>((ref) {
  return ref.watch(authProvider).primaryRole;
});
