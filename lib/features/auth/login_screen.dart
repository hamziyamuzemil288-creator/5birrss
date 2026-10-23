import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/services/captcha_service.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/google_sign_in_button.dart';
import '../../core/widgets/primary_button.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/services/login_identity.dart';
import '../../core/services/guest_session.dart';
import 'password_reset_request_sheet.dart';
import '../../core/services/staff_admin_service.dart';
import '../../core/services/staff_gateway_service.dart';
import '../auth/admin_gate.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _error;
  // Task 13 item 2: the login page is an attack surface too — enforce the
  // same server-side CAPTCHA as signup/OTP/appeals, plus the failure lockout.
  bool _captchaRequired = true; // conservative default until the server says
  String? _captchaId;
  int _captchaResetVersion = 0;

  @override
  void initState() {
    super.initState();
    // If the session ended on its own (expired and could not be refreshed), the
    // auth layer left a one-time notice. Surface it so the user is told WHY
    // they are looking at the login screen instead of being dropped onto it
    // with no explanation. Read once (not watched): it is a landing message,
    // and any later error replaces it through the normal _error path.
    final notice = ref.read(authProvider).sessionNotice;
    if (notice != null) _error = notice;
    // A lookup failure defaults to true (fail closed), matching the service.
    CaptchaService.instance.isRequired().then((required) {
      if (mounted) setState(() => _captchaRequired = required);
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// One staff-gateway attempt. Never throws — failures come back as false so
  /// the caller can decide what to say.
  ///
  /// Admin-created staff have no ordinary Supabase identity: their auth
  /// account's email is a server-derived synthetic address, so the normal
  /// email sign-in can never match them. The gateway is the only door.
  Future<bool> _staffSignIn(String username) async {
    try {
      await const StaffGatewayService()
          .signIn(username: username, password: _passwordController.text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    final identifier = _emailController.text.trim();
    final isStaff = classifyLoginIdentifier(identifier) ==
        LoginIdentityKind.staffUsername;
    // The gate keys CAPTCHA + lockout per account identity. Bare staff
    // usernames are normalized to the same synthetic address the gateway
    // derives for them so the gate (which requires an "@") can enforce
    // staff logins too — NO login path skips CAPTCHA/lockout.
    final gateKey = isStaff ? staffLoginGateKey(identifier) : identifier;

    if (_captchaRequired && _captchaId == null) {
      setState(() => _error = 'Complete the security check before signing in.');
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });

    // 1. Server gate BEFORE the credential check — staff included: consumes
    //    the CAPTCHA and enforces the failure lockout. Fail closed on any
    //    gate problem.
    try {
      await CaptchaService.instance
          .gateLogin(email: gateKey, captchaId: _captchaId);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          // login-gate consumes the challenge before checking credentials.
          // Never leave a green, already-consumed challenge on screen.
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
      return;
    }

    // ── Staff gateway credentials ──
    // A bare username (no "@") is unambiguously staff: send it to the
    // gateway instead of the email path, which would both reject the shape
    // and (even if it did not) fail against the synthetic identity. This is
    // the path that makes an admin-created staff account usable the moment
    // it exists — and it now runs behind the same gate as everything else.
    if (isStaff) {
      final ok = await _staffSignIn(identifier);
      await CaptchaService.instance.recordLoginAttempt(
        email: gateKey,
        success: ok,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _isLoading = false;
          // The gate consumed the challenge; never leave it on screen.
          _captchaId = null;
          _captchaResetVersion++;
          _error = 'Invalid username or password.';
        });
      }
      // On success the auth listener loads the profile and the router
      // forwards the staff member to /staff/dashboard; leaving the button in
      // its loading state until then avoids a flash of an idle form.
      return;
    }

    final email = identifier;
    try {
      try {
        // 2. The credential check itself (the gate already ran above).
        await ref.read(authProvider.notifier).signIn(
              email: email,
              password: _passwordController.text,
            );
        // signedIn is picked up by the auth listener; still clear the
        // failure window server-side so one typo never bites later.
        await CaptchaService.instance.recordLoginAttempt(
          email: email,
          success: true,
        );
        // 2b. The session exists, but "signed in" is not the same as "in".
        //
        // authProvider.signIn() awaits signInWithPassword and returns; the
        // PROFILE and ROLES are loaded afterwards by the auth listener, and
        // the router only forwards once they are there. So there is a window
        // — a real one, and on a slow connection a long one — in which the
        // session is valid, the profile is still null, and the router's
        // redirect deliberately returns null ("stay put, retry shortly").
        //
        // The button used to stay spinning through that window forever,
        // because nothing in this method ever cleared _isLoading on the
        // success path. If the profile load then failed — an R denial, a
        // trigger that has not committed yet, the network — the one retry
        // the router schedules was not enough and the user was left staring
        // at a disabled LOGIN button with no message at all. That is the
        // reported "the login screen does not accept the account the admin
        // approved": the credentials were accepted, the app just never said
        // so and never recovered.
        //
        // So: wait for the account to actually load, and if it does not,
        // say so in words and give the button back.
        final settled = await _awaitAccountLoaded();
        if (!mounted) return;
        if (!settled) {
          setState(() {
            _isLoading = false;
            _captchaId = null;
            _captchaResetVersion++;
            _error = 'We could not load your account just now. Your sign-in '
                'worked — tap LOGIN again to finish loading it.';
          });
        }
      } catch (signInError) {
        // A staff username MAY itself be an email address, and those accounts
        // have no ordinary Supabase identity either — so give the gateway one
        // chance with the same input before reporting a failure. Only count a
        // failure once BOTH doors have rejected the credentials: recording it
        // before the fallback would log a false failure on every successful
        // email-shaped staff login and push the account toward lockout.
        if (await _staffSignIn(identifier)) {
          // Clear the failed-attempt window for this identity — the ordinary
          // rejection above was not a real credential failure.
          await CaptchaService.instance.recordLoginAttempt(
            email: email,
            success: true,
          );
          return;
        }
        await CaptchaService.instance.recordLoginAttempt(
          email: email,
          success: false,
        );
        rethrow;
      }
      // No trailing navigation: on success the router's redirect takes over
      // once the account has loaded, which is what _awaitAccountLoaded above
      // just waited for.
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          // login-gate consumes the challenge before checking credentials.
          // Never leave a green, already-consumed challenge on screen after
          // a failed password attempt or any other completed gate attempt.
          _captchaId = null;
          _captchaResetVersion++;
          _error = _friendlyError(e.toString());
        });
      }
    }
  }

  /// "Continue as Guest" — into the marketplace, without an account.
  ///
  /// No Supabase call happens here: the flag is memory-only and the router's
  /// guest branch is what opens the browsing routes. The session stays
  /// anonymous, so every read still runs under `anon` RLS, and the transaction
  /// entry points intercept the tap (core/services/guest_session.dart).
  void _continueAsGuest() {
    ref.read(guestModeProvider.notifier).start();
    context.go('/user');
  }

  /// Wait for the signed-in account's profile and roles to arrive.
  ///
  /// Returns true as soon as the router has everything it needs to forward
  /// (profile present and at least one role), false on timeout or on a load
  /// that reported an error. Bounded so a hung query cannot leave the button
  /// disabled indefinitely — the same reason _loadUserProfile() puts a
  /// timeout on its own queries.
  ///
  /// Deliberately not a StreamBuilder: this is a one-shot wait at the end of
  /// an explicit user action, and the screen already reads authProvider for
  /// nothing else. Polling the notifier keeps it a pure function of existing
  /// state with no new subscription to leak.
  Future<bool> _awaitAccountLoaded() async {
    const deadline = Duration(seconds: 12);
    const step = Duration(milliseconds: 150);
    var waited = Duration.zero;
    while (waited < deadline) {
      if (!mounted) return true;
      final state = ref.read(authProvider);
      // A load that failed sets `error`; the router will never forward from
      // there, so waiting longer only wastes the user's time.
      if (state.error != null) return false;
      if (state.profile != null && state.roles.isNotEmpty) return true;
      await Future<void>.delayed(step);
      waited += step;
    }
    return false;
  }

  /// Task 15: open the Google consent screen. The session comes back via
  /// the auth listener (deep link) — failures surface as readable errors.
  Future<void> _handleGoogleSignIn() async {    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signInWithGoogle();
      // The OAuth round-trip continues in the browser; the router navigates
      // once the deep link delivers the session.
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not start Google sign-in. Please try again.';
        });
      }
    }
  }

  String _friendlyError(String raw) {
    // Gate/lockout messages are already written for the user.
    if (raw.contains('Too many failed attempts') ||
        raw.contains('security check')) {
      return raw;
    }
    if (raw.contains('temporarily_locked')) {
      return 'Too many failed attempts. Try again in 15 minutes.';
    }
    if (raw.contains('Invalid login credentials')) {
      return 'Invalid email or password.';
    }
    // GoTrue refuses a password sign-in on an unconfirmed address with its
    // own message. It used to fall through to friendlyError(), which files
    // it under "auth / session" and told the user their SESSION had expired —
    // true of no relevance to somebody who has never had a session, and
    // unactionable. It is the single most confusing thing this screen can
    // say to a brand-new account, which is exactly the population the
    // approval flow produces.
    if (raw.contains('Email not confirmed')) {
      return 'This account has not been confirmed yet. Check your email for '
          'the confirmation link, or ask an administrator to approve it.';
    }
    // A disabled/banned identity. Distinct from a wrong password on purpose:
    // retrying with the same password will never work, and saying so is the
    // difference between a user who waits and a user who gives up.
    if (raw.contains('User is disabled') || raw.contains('user_banned')) {
      return 'This account has been disabled. Please contact support.';
    }
    // The gate is down or unreachable. Named separately so "we cannot check
    // right now" is never reported as "your password is wrong" — the user
    // would change a perfectly good password.
    if (raw.contains('Sign-in is temporarily unavailable')) {
      return raw;
    }
    if (raw.contains('network') || raw.contains('SocketException')) {
      return 'Network error. Please check your connection.';
    }
    if (raw.contains('rate limit')) {
      return 'Too many attempts. Please wait a moment and try again.';
    }
    // Anything not recognised above used to be returned as
    // 'Login failed: $raw', which put the raw exception — PostgREST codes,
    // HttpException internals, JWT text — in front of the user on the very
    // first screen of the app. The shared mapper keeps this screen's
    // deliberate, specific messages above and only translates the tail.
    return friendlyError(raw, context: 'Could not sign you in');
  }

  /// Password reset: ask for the email, send the recovery link. The link
  /// opens the app (deep link in AndroidManifest) and lands the user on
  /// /update-password via the passwordRecovery auth event.
  void _showForgotPasswordSheet() {
    final emailController =
        TextEditingController(text: _emailController.text.trim());
    var sending = false;
    var sent = false;
    String? sheetError;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.lightLemonSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
              24, 24, 24, 24 + MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Reset Password', style: AppTheme.heading),
              const SizedBox(height: 8),
              const Text(
                'Enter your account email and we will send you a link to '
                'set a new password.',
                style: AppTheme.bodyMedium,
              ),
              const SizedBox(height: 20),
              BirrTextField(
                label: 'Email',
                hint: 'you@example.com',
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
              ),
              if (sheetError != null) ...[
                const SizedBox(height: 12),
                Text(sheetError!,
                    style:
                        const TextStyle(fontSize: 13, color: AppTheme.error)),
              ],
              if (sent) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: AppTheme.success, size: 18),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Reset link sent — check your email (and the spam '
                        'folder). The link opens this app.',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.success),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: sent ? 'RESEND LINK' : 'SEND RESET LINK',
                  isLoading: sending,
                  onPressed: () async {
                    final email = emailController.text.trim();
                    if (email.isEmpty ||
                        !email.contains('@') ||
                        !email.contains('.')) {
                      setSheetState(
                          () => sheetError = 'Enter a valid email address');
                      return;
                    }
                    setSheetState(() {
                      sending = true;
                      sheetError = null;
                    });
                    try {
                      await ref
                          .read(authProvider.notifier)
                          .resetPassword(email: email);
                      setSheetState(() {
                        sending = false;
                        sent = true;
                      });
                    } catch (_) {
                      setSheetState(() {
                        sending = false;
                        sheetError = 'Could not send the email. Check your '
                            'connection and try again.';
                      });
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
            stops: [0.0, 0.35],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 56),
                // Logo
                AdminGate(
                  onUnlocked: () => context.go('/admin-login'),
                  child: Image.asset(
                    'assets/images/aliob_logo_mark.png',
                    width: 84,
                    height: 84,
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Aliob',
                    style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 4,
                        height: 1.1)),
                const SizedBox(height: 8),
                Text('All in one',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withOpacity(0.75),
                        letterSpacing: 2)),
                const SizedBox(height: 36),
                // Login card — light lemon surface instead of flat white.
                // A thin lemon accent along the top edge keeps it warm and
                // tethered to the green header rather than floating as a white
                // block.
                Container(
                  width: double.infinity,
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
                      // A soft lemon glow under the card so it lifts off the
                      // gradient instead of sitting on it.
                      BoxShadow(
                        color: AppTheme.lightLemonAccent.withOpacity(0.25),
                        blurRadius: 24,
                        spreadRadius: 2,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Welcome Back',
                            style: AppTheme.headingLarge),
                        const SizedBox(height: 6),
                        const Text('Sign in to your account',
                            style: AppTheme.bodyMedium),
                        const SizedBox(height: 24),
                        // Accepts an account email OR a staff username — an
                        // admin-created staff member types the username they
                        // were given, which is not an email.
                        BirrTextField(
                          label: 'Email or Username',
                          hint: 'you@example.com or username',
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          validator: (v) {
                            final value = v?.trim() ?? '';
                            if (value.isEmpty) {
                              return 'Email or username is required';
                            }
                            if (classifyLoginIdentifier(value) ==
                                    LoginIdentityKind.email ||
                                isValidStaffUsername(value)) {
                              return null;
                            }
                            return 'Enter a valid email or staff username';
                          },
                        ),
                        const SizedBox(height: 16),
                        BirrTextField(
                          label: 'Password',
                          controller: _passwordController,
                          obscure: _obscurePassword,
                          textInputAction: TextInputAction.done,
                          onEditingComplete: _handleLogin,
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscurePassword
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: AppTheme.textMuted,
                              size: 20,
                            ),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                          validator: (v) {
                            if (v == null || v.isEmpty) {
                              return 'Password is required';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _showForgotPasswordSheet,
                            child: const Text('Forgot Password?'),
                          ),
                        ),
                        // The case the emailed link cannot fix. A person who
                        // lost the inbox, or whose address on the account is
                        // wrong, or who signed up with Google and never had a
                        // password, has exactly one option today and it is
                        // giving up. This files a PASSWORD_RESET appeal, which
                        // lands in the SAME admin appeals queue as every other
                        // case -- not a parallel inbox somebody has to remember
                        // to check.
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => showPasswordResetRequestSheet(
                              context,
                              initialEmail: _emailController.text.trim(),
                            ),
                            child: const Text(
                              "Can't get the email? Ask us",
                            ),
                          ),
                        ),
                        // Task 13 item 2: same tick+math CAPTCHA as signup,
                        // enforced server-side by the login-gate function.
                        if (_captchaRequired) ...[
                          CaptchaChallengeField(
                            key: ValueKey(_captchaResetVersion),
                            onVerified: (id) => setState(() => _captchaId = id),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 8),
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
                                    fontSize: 13, color: AppTheme.error)),
                          ),
                        ],
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: PrimaryButton(
                            label: 'LOGIN',
                            isLoading: _isLoading,
                            onPressed: _handleLogin,
                          ),
                        ),
                        // Task 15: Google OAuth — same account pipeline as
                        // email signups (PENDING_APPROVAL until an admin
                        // approves); the provider-verified email replaces
                        // the OTP step for these accounts only.
                        const SizedBox(height: 12),
                        GoogleSignInButton(
                          isLoading: _isLoading,
                          onPressed: _handleGoogleSignIn,
                        ),
                        const SizedBox(height: 18),
                        // Guest browsing: the marketplace IS the product, so a
                        // visitor can walk through it before deciding to
                        // register. Nothing is created and no session exists —
                        // buying, booking and requesting a ride still open the
                        // standard registration at that exact moment
                        // (core/services/guest_session.dart owns that rule).
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _isLoading ? null : _continueAsGuest,
                            icon: const Icon(Icons.storefront_outlined,
                                size: 18),
                            label: const Text('CONTINUE AS GUEST'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppTheme.primaryGreen,
                              side: const BorderSide(
                                  color: AppTheme.primaryGreen),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                              textStyle: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w700),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Browse products, services and providers without an '
                          'account. You will be asked to register when you buy, '
                          'book or request a ride.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.4,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // Sign up link
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("Don't have an account? ",
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary)),
                    GestureDetector(
                      onTap: () => context.go('/role-select'),
                      child: const Text('Create Account',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.teal)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Explicit door for staff whose username IS an email address
                // (they cannot be told apart from a normal account by shape).
                // The gateway screen is otherwise reachable only after
                // signing in, which left staff created by the admin with no
                // way in at all.
                TextButton.icon(
                  onPressed: () => context.go('/staff/login'),
                  icon: const Icon(Icons.support_agent,
                      size: 16, color: AppTheme.textSecondary),
                  label: const Text('Staff / employee sign in',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textSecondary)),
                ),
                const SizedBox(height: 36),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
