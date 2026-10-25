import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/friendly_error.dart';
import '../../core/widgets/load_error_view.dart';

/// The account screen's "Notification Settings" row used to call
/// `_notBuiltYet(context, 'Notification Settings')` — a menu entry that told the
/// user the feature does not exist.
///
/// What is real today, and what is honest to say about it:
///
///   * **Push** — genuinely honoured. `fcm-dispatch` reads
///     `notification_preferences.push_enabled` and skips the FCM send for every
///     recipient who turned it off; their in-app row is still written.
///   * **In-app** — always on. It is the record of what the platform told the
///     person, and quietly discarding it would make support and disputes
///     impossible. That is why there is no switch for it here.
///   * **SMS / Email** — stored, and clearly labelled as not sending yet
///     (20261025000003 defaults both to false). The switch exists now so the
///     preference survives until the sender ships, rather than needing a second
///     settings change later.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  String? _error;

  bool _push = true;
  bool _sms = false;
  bool _email = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) {
        throw StateError('not signed in');
      }
      final row = await Supabase.instance.client
          .from('notification_preferences')
          .select('push_enabled, sms_enabled, email_enabled')
          .eq('user_id', uid)
          .maybeSingle();
      if (!mounted) return;
      setState(() {
        // No row yet means "everything at its default": push on, the two
        // channels without senders off.
        _push = (row?['push_enabled'] as bool?) ?? true;
        _sms = (row?['sms_enabled'] as bool?) ?? false;
        _email = (row?['email_enabled'] as bool?) ?? false;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = friendlyError(e,
              context: 'Could not load your notification settings');
        });
      }
    }
  }

  Future<void> _save({
    bool? push,
    bool? sms,
    bool? email,
  }) async {
    final prevPush = _push;
    final prevSms = _sms;
    final prevEmail = _email;
    setState(() {
      if (push != null) _push = push;
      if (sms != null) _sms = sms;
      if (email != null) _email = email;
      _saving = true;
    });
    try {
      await Supabase.instance.client.rpc('save_notification_channels', params: {
        'p_push_enabled': _push,
        'p_sms_enabled': _sms,
        'p_email_enabled': _email,
      });
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notification settings saved')),
      );
    } catch (e) {
      if (!mounted) return;
      // Put the switch back: a toggle that stays flipped after a failed save
      // tells the user something is on when the server never heard it.
      setState(() {
        _push = prevPush;
        _sms = prevSms;
        _email = prevEmail;
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                friendlyError(e, context: 'Could not save your settings'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification Settings')),
      body: _error != null
          ? LoadErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const Center(
                  child:
                      CircularProgressIndicator(color: AppTheme.primaryGreen))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _push,
                            activeColor: AppTheme.primaryGreen,
                            onChanged: _saving
                                ? null
                                : (v) => _save(push: v),
                            title: const Text('Push notifications',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            subtitle: const Text(
                              'Alerts on this device about orders, rides, '
                              'payments and reminders.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const Divider(height: 1),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _sms,
                            activeColor: AppTheme.primaryGreen,
                            onChanged: _saving
                                ? null
                                : (v) => _save(sms: v),
                            title: const Text('SMS',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            subtitle: const Text(
                              'Saved for when SMS alerts launch — nothing is '
                              'sent by text yet.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                          const Divider(height: 1),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _email,
                            activeColor: AppTheme.primaryGreen,
                            onChanged: _saving
                                ? null
                                : (v) => _save(email: v),
                            title: const Text('Email',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            subtitle: const Text(
                              'Saved for when email alerts launch — nothing is '
                              'sent by email yet.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.inbox_outlined,
                            size: 16, color: AppTheme.textMuted),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Your in-app inbox always keeps a record of every '
                            'notice we send you, so you can look back at any '
                            'order or payment later.',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: AppTheme.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
    );
  }
}
