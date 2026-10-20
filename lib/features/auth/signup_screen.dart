import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/captcha_service.dart';
import '../../core/services/otp_service.dart';
import '../../core/services/city_service.dart';
import '../../core/utils/phone_formatter.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/google_sign_in_button.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/system_banner.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/utils/friendly_error.dart';
import 'terms_policy_screen.dart';
import 'otp_verification_screen.dart';

enum SignupRole { user, vehicleProvider, serviceProvider }

class SignupScreen extends ConsumerStatefulWidget {
  final SignupRole role;

  /// Part 6: staff-assisted registration. A staff member registers a provider
  /// on their behalf from the staff workspace (`/staff/register-provider`).
  /// The only structural differences from self-service: the referral code is
  /// REQUIRED and must resolve to an active staff code (that resolution is
  /// exactly what makes the signup staff-assisted server-side —
  /// `handle_new_user` keeps such a provider at PENDING_APPROVAL until an
  /// administrator approves their documents), and the success step points at
  /// the document upload instead of the dashboard. The CAPTCHA, the privacy
  /// checkbox, the city and the trade picker are the same gates everyone
  /// passes.
  final bool assistedByStaff;

  const SignupScreen({
    super.key,
    required this.role,
    this.assistedByStaff = false,
  });

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  // Phase 1: required city — persisted on the profile and used to scope
  // home/browse queries. Defaults to the service fallback city.
  String? _selectedCity;

  // Task 7: Kebele + Street/Road (after City) — GPS accuracy + identity
  // verification; stored on profiles via the signup metadata.
  final _kebeleController = TextEditingController();
  final _streetRoadController = TextEditingController();

  // Task 8: optional referral code (providers only) — identifies the
  // sales/staff person who registered this provider. Never required; the
  // server resolves it against referral_codes at account creation.
  final _referralController = TextEditingController();
  String? _referralHint; // live lookup result: "Referred by: <name>"

  // The trade a provider is registering as. REQUIRED for providers, because it
  // is what decides the whole settings form they get afterwards: a hotel is
  // asked for room types, a doctor for an hourly rate, a restaurant for a
  // delivery fee. Asking it after approval would mean every provider fills in
  // the wrong form first and then has to redo it.
  String? _selectedCategoryId;
  List<Map<String, dynamic>> _providerCategories = const [];
  bool _loadingCategories = false;

  /// SERVICE for a service provider, VEHICLE for a vehicle provider. The server
  /// refuses a mismatch (provider_claim_category), so the list offered and the
  /// list accepted cannot drift apart.
  String get _categorySector =>
      widget.role == SignupRole.vehicleProvider ? 'VEHICLE' : 'SERVICE';

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _isLoading = false;
  bool _captchaRequired = false;
  String? _captchaId;
  String? _error;

  // Whether a new account must prove an email OTP before it can be created.
  // Defaults to true: if the lookup never completes, the screen asks for a
  // code rather than skipping a gate the server may still enforce. The
  // captcha rides along with it — the challenge exists to throttle OTP
  // requests, so asking a visitor to solve one when no email is ever sent
  // is friction for nothing.
  bool _otpRequired = true;

  // Privacy Policy agreement: required before the submit button enables.
  // Acceptance is stored on the profile (0039) right after the account
  // exists, with the version the user actually saw. Part 1 of the rework
  // names the POLICY the checkbox is about — the Privacy Policy, on the
  // existing policy page at /terms — rather than the old umbrella phrase.
  bool _agreedToTerms = false;

  // Task 9: the document-type choice was removed from signup (it was a
  // leftover from before the Task 3 correction). Providers now choose the
  // document type AND upload the document in the same step, at the first
  // protected action after wallet recharge (see ProviderDocGate).

  bool get _isProvider =>
      widget.role == SignupRole.vehicleProvider ||
      widget.role == SignupRole.serviceProvider;

  String get _roleName {
    switch (widget.role) {
      case SignupRole.user:
        return 'User';
      case SignupRole.vehicleProvider:
        return 'Vehicle Provider';
      case SignupRole.serviceProvider:
        return 'Service Provider';
    }
  }

  String get _providerType {
    switch (widget.role) {
      case SignupRole.vehicleProvider:
        return 'VEHICLE_PROVIDER';
      case SignupRole.serviceProvider:
        return 'SERVICE_PROVIDER';
      default:
        return '';
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSignupRequirements();
  }

  Future<void> _loadSignupRequirements() async {
    // Part 1 of the rework: registration requires a CAPTCHA unconditionally.
    // The challenge is a real one (server-generated question, answer stays
    // server-side, verified through `verify_captcha` before the account
    // exists) — not a tick-box — and it is asked on every signup regardless
    // of whether the email OTP gate is on, because the account-creation
    // endpoint it throttles is the same either way. The server toggle
    // (`captcha_required`) still exists for the login gate and appeals; the
    // signup bar no longer depends on it. The OTP lookup is unchanged: the
    // code screen is still shown exactly when the server asks for a code.
    final results = await Future.wait([
      CaptchaService.instance.isRequired(),
      OtpService.isRequiredAtSignup(),
    ]);
    if (!mounted) return;
    setState(() {
      _otpRequired = results[1];
      _captchaRequired = true;
    });
    if (_isProvider) await _loadProviderCategories();
  }

  /// The trades a provider may register as, for their own sector only.
  ///
  /// A failed load is NOT fatal and does not block the form: the picker simply
  /// renders empty and the submit button reports that a trade is needed. The
  /// alternative -- locking registration behind a catalogue read -- would turn
  /// a slow query into "you cannot sign up today".
  Future<void> _loadProviderCategories() async {
    setState(() => _loadingCategories = true);
    try {
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id, name')
          .eq('sector', _categorySector)
          .isFilter('parent_id', null)
          .eq('is_active', true)
          .order('name');
      if (!mounted) return;
      setState(() {
        _providerCategories =
            List<Map<String, dynamic>>.from(rows as List);
        _loadingCategories = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _providerCategories = const [];
        _loadingCategories = false;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _kebeleController.dispose();
    _streetRoadController.dispose();
    _referralController.dispose();
    super.dispose();
  }

  Timer? _referralDebounce;

  /// Live lookup: shows "Referred by: <name>" while the code matches an
  /// active staff code. Failures are silent — the server re-checks at
  /// signup and an unknown code must never block registration (Task 8).
  void _lookupReferral() {
    _referralDebounce?.cancel();
    final code = _referralController.text.trim();
    if (code.isEmpty) {
      if (mounted && _referralHint != null)
        setState(() => _referralHint = null);
      return;
    }
    _referralDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final name = await Supabase.instance.client
            .rpc('validate_referral_code', params: {'p_code': code});
        if (!mounted) return;
        setState(() {
          _referralHint = (name is String && name.isNotEmpty)
              ? 'Referred by: $name ✓'
              : 'Code not recognized — you can still continue without it.';
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _referralHint = null);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              // Gradient header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 48, 16, 24),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
                    stops: [0.0, 1.0],
                  ),
                ),
                child: SafeArea(
                  bottom: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Back button
                      GestureDetector(
                        onTap: () => context.go('/role-select'),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.arrow_back_ios_new,
                            size: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '$_roleName Registration',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          height: 1.25,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isProvider
                            ? 'Register now — verify your ID when you start selling'
                            : 'Create your account to get started',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          height: 1.4,
                          color: Colors.white.withOpacity(0.85),
                        ),
                      ),
                      if (widget.assistedByStaff) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Staff-assisted: this provider becomes active for '
                          'trading once their documents are reviewed.',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            height: 1.4,
                            color: Colors.white.withOpacity(0.95),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              // Form content — a soft pale-lemon card so the signup form
              // reads as a warm panel instead of bare cream. Inputs keep their
              // own fills; the card is the aesthetic frame around them.
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 460),
                      child: Card(
                        elevation: 0,
                        margin: EdgeInsets.zero,
                        color: AppTheme.lightLemonPale,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                          side: const BorderSide(
                            color: AppTheme.lightLemonAccent,
                            width: 1.25,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 22, vertical: 20),
                          child: Form(
                            key: _formKey,
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                _buildFormFields(),
                                const SizedBox(height: 12),
                                if (_error != null)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: AppTheme.error.withOpacity(0.08),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                          color: AppTheme.error.withOpacity(0.2)),
                                    ),
                                    child: Text(_error!,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            color: AppTheme.error)),
                                  ),
                                const SizedBox(height: 24),
                                // Terms & Privacy agreement (final step, every flow).
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: Checkbox(
                                        value: _agreedToTerms,
                                        activeColor: AppTheme.primaryGreen,
                                        materialTapTargetSize:
                                            MaterialTapTargetSize.shrinkWrap,
                                        onChanged: (v) =>
                                            setState(
                                                () => _agreedToTerms = v ?? false),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          const Text('I agree to the ',
                                              style: AppTheme.bodyMedium),
                                          // Part 1: the checkbox names the
                                          // Privacy Policy and opens the
                                          // existing policy page (/terms
                                          // hosts the full Terms & Privacy
                                          // Policy text). Required to
                                          // proceed — the submit button
                                          // below is disabled until it is
                                          // ticked, and the server records
                                          // the acceptance (accept_terms).
                                          GestureDetector(
                                            onTap: () =>
                                                context.push('/terms',
                                                    extra: true),
                                            child: const Text(
                                                'Privacy Policy',
                                                style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    color: AppTheme.teal,
                                                    decoration: TextDecoration.underline,
                                                    decorationColor: AppTheme.teal)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                if (_captchaRequired) ...[
                                  const SizedBox(height: 16),
                                  CaptchaChallengeField(
                                    onVerified: (id) =>
                                        setState(() => _captchaId = id),
                                  ),
                                ],
                                const SizedBox(height: 16),
                                SizedBox(
                                  width: double.infinity,
                                  child: PrimaryButton(
                                    label: 'CONTINUE',
                                    isLoading: _isLoading,
                                    onPressed: _agreedToTerms &&
                                            (!_captchaRequired ||
                                                _captchaId != null)
                                        ? _handleSubmit
                                        : null,
                                  ),
                                ),
                                // Task 15: Google OAuth signup — the provider-
                                // verified email replaces the OTP step for these
                                // accounts; admin approval still gates the account,
                                // so this button intentionally ignores the CAPTCHA
                                // and terms flow (Google users confirm terms via
                                // the standard approval pipeline).
                                const SizedBox(height: 12),
                                GoogleSignInButton(
                                  isLoading: _isLoading,
                                  onPressed: _handleGoogleSignUp,
                                ),
                                const SizedBox(height: 16),
                                // Sign in link
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    const Text(
                                        'Already have an account? ',
                                        style: TextStyle(
                                            fontSize: 14,
                                            color: AppTheme.textSecondary)),
                                    GestureDetector(
                                      onTap: () => context.go('/login'),
                                      child: const Text('Sign In',
                                          style: TextStyle(
                                              fontSize: 14,
                                              fontWeight:
                                                  FontWeight.w600,
                                          color: AppTheme.teal)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_isLoading)
            Container(
              color: Colors.black26,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: AppTheme.lightLemonSurface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border(
                      top: const BorderSide(
                        color: AppTheme.lightLemonAccent,
                        width: 3,
                      ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.06),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                      BoxShadow(
                        color: AppTheme.lightLemonAccent.withOpacity(0.25),
                        blurRadius: 24,
                        spreadRadius: 2,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: AppTheme.primaryGreen),
                      SizedBox(height: 16),
                      Text(
                        'Creating account...',
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Validate the form, then hand the user to email verification. The
  /// account is only created AFTER the 6-digit code is verified — the
  /// server (handle_new_user trigger) refuses signups without one.
  /// Task 15: Google OAuth signup. The consent screen runs in the browser;
  /// the deep link returns the session and the OAuth-aware signup trigger
  /// (20260925000000) creates the account PENDING_APPROVAL, same pipeline
  /// as email signups minus the OTP email step.
  Future<void> _handleGoogleSignUp() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWithGoogle();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not start Google sign-in. Please try again.';
        });
      }
    }
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;
    // Step markers for the device test that has to confirm this flow. Console
    // only — nothing here is rendered, and no account data is printed. Each
    // marker names the step so a stuck flow says WHERE it stopped instead of
    // leaving one opaque "Creating account…" scrim.
    debugPrint('[signup] 1/6 submit: otpRequired=$_otpRequired '
        'captchaSolved=${_captchaId != null} agreed=$_agreedToTerms');
    if (!_agreedToTerms) {
      setState(() => _error =
          'Please read and accept the Privacy Policy to continue.');
      return;
    }
    if (_captchaRequired && _captchaId == null) {
      setState(() =>
          _error = 'Please complete the security check before continuing.');
      return;
    }
    // Part 6: a staff-assisted signup is ONLY staff-assisted when the code
    // resolves to an active staff member — that resolution (server-side, in
    // handle_new_user) is what keeps the provider pending until their
    // documents are approved. An unvalidated code would silently register an
    // ordinary self-service provider, so it is refused here rather than
    // guessed about downstream.
    if (widget.assistedByStaff &&
        (_referralHint == null || !_referralHint!.contains('✓'))) {
      setState(() => _error =
          'Enter YOUR staff referral code — it must validate — before '
          'registering a provider on their behalf.');
      return;
    }

    // Park everything the account-creation step will need; the OTP screen
    // hands it back when the code is verified (and is never opened when the
    // OTP is switched off).
    final draft = SignupDraft(
      rolePath: switch (widget.role) {
        SignupRole.user => 'user',
        SignupRole.vehicleProvider => 'vehicle-provider',
        SignupRole.serviceProvider => 'service-provider',
      },
      name: _nameController.text.trim(),
      email: _emailController.text.trim().toLowerCase(),
      phone: _phoneController.text.trim(),
      password: _passwordController.text,
      city: _selectedCity,
      kebele: _kebeleController.text.trim(),
      streetRoad: _streetRoadController.text.trim(),
      nationalIdNumber: null,
      referralCode: _isProvider ? _referralController.text.trim() : null,
      captchaId: _captchaId,
      // Parked through OTP verification like every other field, then claimed
      // server-side once the account exists.
      categoryId: _isProvider ? _selectedCategoryId : null,
    );

    // Ask for a code only while the server is asking for one. When the OTP
    // is switched off (the email provider is unconfigured) the account is
    // created immediately and waits for admin approval instead — which is
    // the gate that has always protected a new account.
    if (_otpRequired) {
      debugPrint('[signup] 2/6 waiting for the email code');
      final verified = await context.push<bool>(
        '/otp-verify',
        extra: OtpArgs(draft: draft),
      );
      debugPrint('[signup] 2/6 code step returned $verified');
      if (verified != true || !mounted) return;
    }
    // Code verified (or the server does not require a code at all) — create
    // the account now.
    debugPrint('[signup] 3/6 creating account: role=${widget.role} '
        'provider=$_isProvider assisted=${widget.assistedByStaff}');
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      if (_isProvider) {
        await ref.read(authProvider.notifier).signUpAsProvider(
              email: draft.email,
              phone: draft.phone,
              password: draft.password,
              businessName: draft.name,
              providerType: _providerType,
              categoryId: draft.categoryId,
              city: draft.city,
              kebele: draft.kebele,
              streetRoad: draft.streetRoad,
              referralCode: draft.referralCode,
            );
      } else {
        await ref.read(authProvider.notifier).signUp(
              email: draft.email,
              phone: draft.phone,
              password: draft.password,
              fullName: draft.name,
              role: AppUserRole.user,
              city: draft.city,
              kebele: draft.kebele,
              streetRoad: draft.streetRoad,
            );
      }

      // Email confirmation is disabled in Supabase Auth, so signUp()
      // returns a session immediately and handle_new_user() has already
      // created the account — APPROVED on arrival for a self-service signup
      // (migration 20261014000000; Part 1: no admin wait). The router does
      // the right thing either way: an approved account lands on its
      // dashboard, and a staff-assisted provider (still PENDING_APPROVED on
      // the trading side) still signs in and is walked straight into the
      // document upload below.
      final hasSession = Supabase.instance.client.auth.currentSession != null;
      if (!mounted) return;

      if (!hasSession) {
        // Defensive: only possible if email confirmation gets re-enabled
        // in Supabase Auth. The account was still created — send the user
        // to sign in instead of pretending registration failed.
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Account created. Please sign in to continue.')),
        );
        context.go('/login');
        return;
      }

      debugPrint('[signup] 4/6 account exists, session present '
          'hasSession=$hasSession');

      // Record the user's terms acceptance (version + timestamp) on the
      // profile now that a session exists. Best-effort and BOUNDED: this runs
      // between a created account and the navigation into the app, so a stall
      // here shows "Creating account…" over an account that already exists.
      // Five seconds is far longer than an UPDATE needs; if it is slower than
      // that, the recording is lost and the account is not.
      try {
        await Supabase.instance.client
            .rpc('accept_terms', params: {'p_version': kTermsVersion})
            .timeout(const Duration(seconds: 5));
        debugPrint('[signup] 5/6 terms accepted');
      } catch (e) {
        // Non-fatal: the account itself was already created successfully.
        debugPrint('[signup] 5/6 terms acceptance skipped: $e');
      }

      if (widget.assistedByStaff) {
        // Part 6: the device is now signed in AS the newly created provider
        // (signUp replaces the staff session — there is no client-side way to
        // create an account WITHOUT taking the session), so the onboarding
        // continues where it matters: the document upload. Approval of those
        // documents is what activates the provider for trading; the staff
        // member signs back into their own workspace from Profile → Sign out.
        SystemBannerController.instance.show(
          title: 'Provider registered',
          message: 'Upload their identity documents now — the account becomes '
              'active for trading once an administrator reviews them.',
          duration: const Duration(seconds: 10),
        );
        context.go('/provider/documents');
        return;
      }

      // Part 8: the welcome banner, immediately after a successful
      // registration. The same welcome is written into the notifications
      // panel by the signup trigger (notify_user_once in migration
      // 20261014000000), so it survives the banner.
      SystemBannerController.instance.show(
        title: 'Welcome to Aliob!',
        message: _isProvider
            ? 'Your provider account is ready. Set up your business profile '
                'and post your first product.'
            : 'Your account is ready. Start exploring Aliob.',
      );
      // Straight to the role's dashboard — Part 1: no pending queue for a
      // self-service signup. If the database has not yet run the
      // auto-approve migration, the router bounces this to
      // /pending-approval on its own; the screen never has to guess.
      debugPrint('[signup] 6/6 navigating to the dashboard');
      context.go(switch (widget.role) {
        SignupRole.user => '/user',
        SignupRole.vehicleProvider => '/vehicle',
        SignupRole.serviceProvider => '/provider',
      });
    } catch (e) {
      debugPrint('[signup] account creation failed: $e');
      if (mounted) {
        setState(() => _error = _friendlyError(e.toString()));
      }
    } finally {
      // The scrim is released unconditionally, including on the success path:
      // `_isLoading` used to be cleared only by the catch block, so any path
      // that neither threw nor navigated (or a navigation that was refused)
      // left a full-screen, undismissable "Creating account…" with the button
      // disabled. That spinner outliving the attempt IS the reported hang —
      // the message now comes from `_error`, where the user can act on it.
      if (mounted && _isLoading) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _friendlyError(String raw) {
    if (raw.contains('already registered') ||
        raw.contains('already exists') ||
        raw.contains('duplicate')) {
      return 'An account with this email already exists.';
    }
    if (raw.contains('Password should be at least')) {
      return 'Password must be at least 6 characters.';
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Please check your connection.';
    }
    if (raw.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    if (raw.contains('EMAIL_OTP_REQUIRED')) {
      return 'Email verification expired. Please verify your email again.';
    }
    // A signup that timed out is genuinely ambiguous: the account may have
    // been created and the answer simply lost. Telling the user to "check your
    // connection" would have them retry the registration and land on "this
    // email already exists", which reads as a failure of an account that is
    // actually there. Say which two things are true instead.
    if (raw.contains('TimeoutException') || raw.contains('timed out')) {
      return 'The server did not confirm in time. If you were then told the '
          'email already exists, the account was created — sign in with the '
          'password you chose.';
    }
    // See login_screen: the old fallthrough returned 'Registration failed:
    // $raw' and leaked the raw exception to anyone who could not register.
    return friendlyError(raw, context: 'Could not create your account');
  }

  Widget _buildFormFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Personal Information', style: AppTheme.sectionHeader),
        const SizedBox(height: 4),
        const Text(
          'Fill in your details to create your account',
          style: AppTheme.caption,
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: _isProvider ? 'Business / Owner Name' : 'Full Name',
          controller: _nameController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Name is required';
            if (v.trim().length < 2) return 'Name is too short';
            return null;
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          value: _selectedCity,
          decoration: const InputDecoration(
            labelText: 'City *',
            hintText: 'Select your city',
            prefixIcon: Icon(Icons.location_city_outlined),
          ),
          items: CityService.knownCities
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          validator: (v) =>
              (v == null || v.isEmpty) ? 'City is required' : null,
          onChanged: (v) => setState(() => _selectedCity = v),
        ),
        const SizedBox(height: 16),
        // Task 7: Kebele + Street/Road right after City — used for GPS
        // tracking accuracy and identity verification.
        BirrTextField(
          label: 'Kebele',
          hint: 'e.g. Kebele 08',
          controller: _kebeleController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) return 'Kebele is required';
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Street / Road',
          hint: 'e.g. Bole Road, near Edna Mall',
          controller: _streetRoadController,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Street / Road is required';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Email',
          hint: 'you@example.com',
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Email is required';
            }
            if (!v.contains('@') || !v.contains('.')) {
              return 'Enter a valid email address';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Phone Number',
          hint: '0912345678',
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.next,
          validator: (v) {
            if (v == null || v.trim().isEmpty) {
              return 'Phone number is required';
            }
            return PhoneFormatter.validateEthiopianPhone(v);
          },
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 4),
          child: Text(
            'Ethiopian numbers only — enter as 0912345678, +251912345678, or 251912345678',
            style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),
        ),
        const SizedBox(height: 16),
        // No National ID is collected at registration, for ANY role. ID
        // verification happens later and inside the app: the document is
        // uploaded in the verification step (user_documents) before a
        // provider may upload a product or a vehicle provider may claim a
        // ride, which is the same gate a user hits before booking. Asking for
        // it here collected a number nobody could check against the document.
        if (_isProvider) ...[
          // Task 8: optional referral code — identifies the sales/staff
          // person who registered this provider. Empty = self-registered;
          // an unknown code never blocks registration (kept as "Other").
          // The trade gate. Rendered BEFORE the referral code because it is
          // the answer that shapes everything after signup; the referral code
          // is bookkeeping about who brought them.
          DropdownButtonFormField<String>(
            value: _selectedCategoryId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText:
                  widget.role == SignupRole.vehicleProvider
                      ? 'Vehicle Category *'
                      : 'Service Category *',
              hintText: _loadingCategories
                  ? 'Loading categories...'
                  : 'What do you provide?',
              prefixIcon: const Icon(Icons.category_outlined),
            ),
            items: _providerCategories
                .map((c) => DropdownMenuItem<String>(
                      value: c['id'] as String,
                      child: Text(c['name']?.toString() ?? '',
                          overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            // When the catalogue could not be read, the picker is disabled
            // rather than empty-and-enabled: an enabled dropdown with no
            // options reads as "there are no categories", which is not true.
            onChanged: _providerCategories.isEmpty
                ? null
                : (v) => setState(() => _selectedCategoryId = v),
            validator: (v) {
              if (!_isProvider) return null;
              if (_providerCategories.isEmpty) {
                return 'Could not load categories — check your connection';
              }
              if (v == null || v.isEmpty) {
                return 'Please choose what you provide';
              }
              return null;
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 4),
            child: Text(
              'This decides the settings and pricing form you will get.',
              style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
            ),
          ),
          const SizedBox(height: 16),
          BirrTextField(
            label: widget.assistedByStaff
                ? 'Your Staff Referral Code *'
                : 'Referral Code (optional)',
            hint: widget.assistedByStaff
                ? 'Your own code — this marks the signup as staff-assisted'
                : 'From the sales person who signed you up',
            controller: _referralController,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.next,
            onChanged: (_) => _lookupReferral(),
            validator: widget.assistedByStaff
                ? (v) {
                    if (v == null || v.trim().isEmpty) {
                      return 'Your staff code is required';
                    }
                    if (_referralHint == null || !_referralHint!.contains('✓')) {
                      return 'This code does not match an active staff member';
                    }
                    return null;
                  }
                : null,
          ),
          if (_referralHint != null) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(_referralHint!, style: AppTheme.caption),
            ),
          ],
          const SizedBox(height: 16),
        ],
        BirrTextField(
          label: 'Password',
          controller: _passwordController,
          obscure: _obscurePassword,
          textInputAction: TextInputAction.next,
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: AppTheme.textMuted,
              size: 20,
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Password is required';
            if (v.length < 6) return 'Password must be at least 6 characters';
            return null;
          },
        ),
        const SizedBox(height: 16),
        BirrTextField(
          label: 'Confirm Password',
          controller: _confirmPasswordController,
          obscure: _obscureConfirm,
          textInputAction: TextInputAction.done,
          onEditingComplete: _handleSubmit,
          suffixIcon: IconButton(
            icon: Icon(
              _obscureConfirm
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: AppTheme.textMuted,
              size: 20,
            ),
            onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
          ),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Please confirm your password';
            if (v != _passwordController.text) return 'Passwords do not match';
            return null;
          },
        ),
      ],
    );
  }
}
