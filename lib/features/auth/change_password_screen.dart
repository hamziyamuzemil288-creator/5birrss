import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/security_notice_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/birr_text_field.dart';
import '../../core/widgets/primary_button.dart';

/// Change your own password: current, new, confirm.
///
/// For users and providers. Staff have their own flow
/// (StaffGatewayService.changePassword → staff-change-password), which stays
/// separate because it is gated on an active staff row — see the note in that
/// Edge Function.
///
/// The current password is required even though the session is already
/// authenticated, and the reason is in account-change-password: updateUser on
/// a live session is enough to take an account over permanently, so someone
/// sitting at an unlocked device has to prove they know the password they are
/// replacing.
class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _saving = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final current = _currentCtrl.text;
    final next = _newCtrl.text;
    if (current.isEmpty || next.isEmpty) {
      setState(() => _error = 'Fill in every field.');
      return;
    }
    // Matches the 10-character floor the server enforces, checked here so the
    // person finds out before a round trip rather than after one.
    if (next.length < 10) {
      setState(() => _error = 'Your new password must be at least 10 characters.');
      return;
    }
    if (next != _confirmCtrl.text) {
      setState(() => _error = 'The two new passwords do not match.');
      return;
    }
    if (next == current) {
      setState(() => _error = 'Your new password must be different.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'account-change-password',
        body: {'current_password': current, 'new_password': next},
      );
      if (res.status != 200) {
        final data = res.data is Map ? res.data as Map : const {};
        setState(() => _error = _messageFor(data['error']?.toString()));
        return;
      }
      // The password change is already committed; this notice is a courtesy and
      // cannot fail the operation (see SecurityNoticeService).
      await SecurityNoticeService.notePasswordChanged();
      if (!mounted) return;
      _currentCtrl.clear();
      _newCtrl.clear();
      _confirmCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Password changed. Other devices have been signed out.'),
      ));
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not change your password. Try again.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _messageFor(String? code) {
    switch (code) {
      case 'current_password_incorrect':
        return 'That is not your current password.';
      case 'new_password_must_differ':
        return 'Your new password must be different.';
      case 'invalid_password_requirements':
        return 'Your new password must be at least 10 characters.';
      case 'password_change_failed':
        return 'We could not change the password. Try again.';
      case 'unauthorized':
        return 'Please sign in again first.';
      default:
        return 'We could not change the password. Try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change Password')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_error!,
                    style: const TextStyle(
                        color: AppTheme.error, fontSize: 13)),
              ),
            ],
            BirrTextField(
              label: 'Current password',
              controller: _currentCtrl,
              obscure: _obscure,
            ),
            const SizedBox(height: 14),
            BirrTextField(
              label: 'New password',
              controller: _newCtrl,
              obscure: _obscure,
            ),
            const SizedBox(height: 6),
            const Text('At least 10 characters.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            const SizedBox(height: 14),
            BirrTextField(
              label: 'Confirm new password',
              controller: _confirmCtrl,
              obscure: _obscure,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: !_obscure,
                  onChanged: (v) => setState(() => _obscure = !(v ?? false)),
                  activeColor: AppTheme.primaryGreen,
                ),
                const Text('Show passwords',
                    style:
                        TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: PrimaryButton(
                label: 'UPDATE PASSWORD',
                isLoading: _saving,
                onPressed: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
