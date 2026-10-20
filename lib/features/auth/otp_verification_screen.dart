import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/services/captcha_service.dart';
import '../../core/services/otp_service.dart';
import '../../core/widgets/captcha_challenge_field.dart';
import '../../core/widgets/primary_button.dart';

/// Extra route data: everything the signup screen needs to finish the
/// account AFTER the email code is verified.
class OtpArgs {
  final SignupDraft draft;
  const OtpArgs({required this.draft});
}

/// Everything the user typed on the signup screen, parked during OTP
/// verification and handed back to the signup screen afterwards.
class SignupDraft {
  final String rolePath; // 'user' | 'vehicle-provider' | 'service-provider'
  final String name;
  final String email;
  final String phone;
  final String password;
  final String? city;
  final String? kebele;
  final String? streetRoad;
  final String? nationalIdNumber; // unused: no ID is collected at signup
  // Task 8: optional referral code (provider flows only). Parked through OTP
  // verification like every other field; blank/unknown never blocks signup.
  final String? referralCode;
  // Task 10: the signup CAPTCHA id is reused for the first OTP request so the
  // user solves one challenge at the start of registration.
  final String? captchaId;
  // The trade a provider picked at the signup gate. Parked through OTP
  // verification like every other field, then claimed server-side once the
  // account exists (it selects the provider's whole settings form).
  final String? categoryId;

  const SignupDraft({
    required this.rolePath,
    required this.name,
    required this.email,
    required this.phone,
    required this.password,
    this.city,
    this.kebele,
    this.streetRoad,
    this.nationalIdNumber,
    this.referralCode,
    this.captchaId,
    this.categoryId,
  });
}

class OtpVerificationScreen extends StatefulWidget {
  final OtpArgs args;
  const OtpVerificationScreen({super.key, required this.args});

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  static const _codeLength = 6;

  final _controllers = List<TextEditingController>.generate(
      _codeLength, (_) => TextEditingController());
  final _focusNodes = List<FocusNode>.generate(_codeLength, (_) => FocusNode());

  bool _verifying = false;
  bool _sending = false;
  bool _captchaRequired = false;
  bool _showResendCaptcha = false;
  String? _resendCaptchaId;
  String? _error;
  Timer? _resendTimer;

  int _resendIn = 0;
  // Codes live for 10 minutes server-side; the UI shows the remaining time.
  DateTime _expiresAt = DateTime.now().add(const Duration(minutes: 10));

  @override
  void initState() {
    super.initState();
    _initializeOtpRequest();
  }

  Future<void> _initializeOtpRequest() async {
    final required = await CaptchaService.instance.isRequired();
    if (!mounted) return;
    setState(() => _captchaRequired = required);
    if (!required || widget.args.draft.captchaId != null) {
      await _requestCode();
    } else {
      setState(() => _showResendCaptcha = true);
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    _resendTimer?.cancel();
    super.dispose();
  }

  String get _email => widget.args.draft.email;

  Future<void> _requestCode({String? captchaId}) async {
    final challengeId = captchaId ?? widget.args.draft.captchaId;
    if (_captchaRequired && challengeId == null) {
      setState(() => _showResendCaptcha = true);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final result = await OtpService.instance.sendOtp(
        _email,
        captchaId: challengeId,
      );
      if (!mounted) return;
      // The server did not send a code because it does not require one
      // (`signup_otp_required` is off): `send-otp` answers `{delivered:false,
      // skipped:"email_verification_disabled"}`. There is nothing to type and
      // nothing will ever arrive, so asking for six digits is a dead end —
      // which is exactly how registration used to hang on this screen. Say so
      // once, complete the step, and let the signup screen create the account
      // (handle_new_user() reads the same toggle and lets it through).
      if (result.skipped) {
        setState(() => _sending = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.pop(true);
        });
        return;
      }
      setState(() {
        _sending = false;
        _showResendCaptcha = false;
        _resendCaptchaId = null;
        _expiresAt = DateTime.now().add(const Duration(minutes: 10));
        _resendIn = 60;
      });
      _startResendCountdown();
    } on OtpCooldownException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _resendIn = e.retryAfterSeconds;
      });
      _startResendCountdown();
    } on OtpUnavailableException catch (e) {
      // The endpoint's own reason, not "check your connection": when the
      // gateway refuses an anonymous call the connection is fine and telling
      // the user to check it hides the defect behind a plausible excuse.
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Could not send the code. Check your connection and retry.';
      });
    }
  }

  void _startResendCaptcha() {
    if (!_captchaRequired) {
      _requestCode();
      return;
    }
    setState(() => _showResendCaptcha = true);
  }

  void _onResendCaptchaVerified(String captchaId) {
    setState(() => _resendCaptchaId = captchaId);
    _requestCode(captchaId: captchaId);
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendIn = _resendIn > 0 ? _resendIn - 1 : 0);
      if (_resendIn == 0) t.cancel();
    });
  }

  String get _code => _controllers.map((c) => c.text).join();

  Future<void> _verify() async {
    if (_code.length != _codeLength) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      await OtpService.instance.verifyOtp(_email, _code);
      if (!mounted) return;
      // Verified. Back to the signup screen to create the account; the
      // server gate (handle_new_user) now lets it through.
      context.pop(true);
    } on OtpVerifyException catch (e) {
      if (!mounted) return;
      final msg = switch (e.code) {
        'WRONG_CODE' => 'That code is not right. Check the digits and retry.',
        'NO_ACTIVE_CODE' => 'This code expired. Send a new one.',
        'TOO_MANY_ATTEMPTS' =>
          'Too many wrong attempts. Send a new code to continue.',
        _ => 'Verification failed. Try again.',
      };
      setState(() {
        _verifying = false;
        _error = msg;
      });
      _clearBoxes();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = 'Verification failed. Check your connection and retry.';
      });
    }
  }

  void _clearBoxes() {
    for (final c in _controllers) {
      c.clear();
    }
    _focusNodes.first.requestFocus();
  }

  String get _timeLeft {
    final remaining = _expiresAt.difference(DateTime.now());
    if (remaining.isNegative) return 'expired';
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.args.draft;
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Verify your email'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(false),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the 6-digit code',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'We sent a verification code to $draft.email.',
                style: const TextStyle(
                    fontSize: 14, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                _timeLeft == 'expired'
                    ? 'The code expired — send a new one.'
                    : 'Code expires in $_timeLeft.',
                style: TextStyle(
                  fontSize: 12,
                  color: _timeLeft == 'expired'
                      ? AppTheme.error
                      : AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 28),

              // 6 code boxes with auto-advance + paste support.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(_codeLength, (i) => _box(i)),
              ),

              if (_showResendCaptcha) ...[
                const SizedBox(height: 20),
                const Text(
                  'One quick check is needed before sending a new code.',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                CaptchaChallengeField(
                  key: ValueKey('resend-captcha-${_resendCaptchaId ?? 'new'}'),
                  onVerified: _onResendCaptchaVerified,
                ),
              ],

              if (_error != null) ...[
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.08),
                    border: Border.all(color: AppTheme.error.withOpacity(0.2)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_error!,
                      style:
                          const TextStyle(fontSize: 13, color: AppTheme.error)),
                ),
              ],

              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: 'VERIFY',
                  isLoading: _verifying,
                  onPressed: _code.length == _codeLength ? _verify : null,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: _resendIn > 0 || _sending
                    ? Text(
                        _sending ? 'Sending…' : 'Resend code in $_resendIn s',
                        style: const TextStyle(
                            fontSize: 13, color: AppTheme.textMuted),
                      )
                    : TextButton(
                        onPressed: _startResendCaptcha,
                        child: const Text(
                          'Resend code',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: AppTheme.teal),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _box(int i) {
    return SizedBox(
      width: 46,
      height: 56,
      child: KeyboardListener(
        focusNode: _focusNodes[i],
        child: TextField(
          controller: _controllers[i],
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 1,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary),
          decoration: InputDecoration(
            counterText: '',
            contentPadding: EdgeInsets.zero,
            filled: true,
            fillColor: AppTheme.surface,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppTheme.cardBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide:
                  const BorderSide(color: AppTheme.primaryGreen, width: 1.6),
            ),
          ),
          onChanged: (v) {
            if (v.isNotEmpty && i < _codeLength - 1) {
              _focusNodes[i + 1].requestFocus();
            } else if (v.isEmpty && i > 0) {
              _focusNodes[i - 1].requestFocus();
            }
            if (_code.length == _codeLength && _code != _lastAutoVerify) {
              _lastAutoVerify = _code;
              _verify();
            }
          },
        ),
      ),
    );
  }

  String? _lastAutoVerify;
}
