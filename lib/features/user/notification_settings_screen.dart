import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/notification_service.dart';
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
///
/// This screen is also the one place a user can see WHY the tray is empty:
/// the build has no Firebase config, Android permission is off, the app's
/// notifications are disabled in system settings, or this device has no token.
/// "Send me a test notification" exercises the real server -> FCM path.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String? _error;
  String? _testMessage;

  bool _push = true;
  bool _sms = false;
  bool _email = false;
  NotificationReadiness? _readiness;

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

      NotificationReadiness? readiness;
      try {
        readiness = await NotificationService.instance.readiness();
      } catch (_) {
        readiness = null;
      }

      if (!mounted) return;
      setState(() {
        // No row yet means "everything at its default": push on, the two
        // channels without senders off.
        _push = (row?['push_enabled'] as bool?) ?? true;
        _sms = (row?['sms_enabled'] as bool?) ?? false;
        _email = (row?['email_enabled'] as bool?) ?? false;
        _readiness = readiness;
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
      setState(() {
        _saving = false;
        if (push == false) {
          _testMessage =
              'Push is switched off in Aliob. The in-app inbox still keeps '
              'every notice.';
        }
      });
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

  Future<void> _askPermission() async {
    final granted = await NotificationService.instance.requestPermission();
    await _load();
    if (!mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Android did not allow notifications. You can turn them on from '
            'the system settings below.',
          ),
        ),
      );
    }
  }

  /// Permission can be on while this device still has no FCM token (a guest
  /// session that opened before push initialized, a transient network error).
  /// Retry the registration instead of showing a permission button that would
  /// do nothing.
  Future<void> _retryToken() async {
    await NotificationService.instance.registerToken();
    await _load();
    if (!mounted) return;
    if (_readiness?.hasToken != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This device still has no push token. Check your connection, then '
            'sign out and back in if it persists.',
          ),
        ),
      );
    }
  }

  Future<void> _sendTest() async {
    if (_testing) return;
    final readiness = _readiness;
    if (readiness == null) {
      setState(() => _testMessage =
          'Could not read this device’s notification state. Pull to refresh.');
      return;
    }
    if (!readiness.firebaseConfigured) {
      setState(() => _testMessage =
          'This build has no Firebase configuration, so it cannot receive a '
          'push. Add FIREBASE_API_KEY, FIREBASE_APP_ID, '
          'FIREBASE_MESSAGING_SENDER_ID and FIREBASE_PROJECT_ID to the release '
          'build, then install the new build.');
      return;
    }
    if (!readiness.permission || !readiness.notificationsEnabled) {
      setState(() => _testMessage =
          'Android is blocking Aliob notifications. Turn them on in the '
          'system settings, then try again.');
      return;
    }
    if (!_push) {
      setState(() => _testMessage =
          'Push notifications are switched off in Aliob. Turn the switch on, '
          'then try again.');
      return;
    }
    if (!readiness.hasToken) {
      setState(() => _testMessage =
          'This device has no push token yet. Check your connection and try '
          'again; if it still fails, sign out and back in.');
      return;
    }

    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      // The readiness check reads the local token; the server counts rows in
      // `fcm_tokens`. Persist the current token first so the button cannot
      // report "no active token" merely because the row was never written.
      await NotificationService.instance.registerToken();
      final result = await NotificationService.instance.sendTestNotification();
      final tokens = (result['active_tokens'] as num?)?.toInt() ?? 0;
      final trayExpected = result['tray_expected'] == true && tokens > 0;
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testMessage = trayExpected
            ? 'Test notification queued. It should appear in your tray and '
                'in the in-app inbox within a few seconds. If the inbox gets '
                'it but the tray does not, the Supabase n8n_events webhook or '
                'FCM secrets need checking.'
            : 'The test row was written to your in-app inbox, but no active '
                'device token was found, so no tray notification was sent. '
                'Open Aliob again while signed in, then retry.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testMessage = friendlyError(e,
            context: 'The test notification could not be sent');
      });
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
              : RefreshIndicator(
                  onRefresh: _load,
                  color: AppTheme.primaryGreen,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      _statusCard(),
                      const SizedBox(height: 14),
                      _preferenceCard(),
                      const SizedBox(height: 14),
                      _guidanceCard(),
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
                ),
    );
  }

  Widget _statusCard() {
    final r = _readiness;
    final configured = r?.firebaseConfigured ?? false;
    final permissionAllowed = (r?.permission ?? false) &&
        (r?.notificationsEnabled ?? false);
    final allowed = permissionAllowed && (r?.hasToken ?? false);
    // "Denied" or "granted permission but the app/channel is switched off in
    // Android settings" both need the system settings door. A not-yet-asked
    // permission needs the in-app request instead.
    final blockedByPermission = configured &&
        (r?.authorizationStatus == AuthorizationStatus.denied ||
            ((r?.permission ?? false) && !(r?.notificationsEnabled ?? false)));
    final needsPermission = configured && !permissionAllowed && !blockedByPermission;
    final needsToken = configured && permissionAllowed && !(r?.hasToken ?? false);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: (allowed ? AppTheme.primaryGreen : AppTheme.warning)
                      .withOpacity(0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  allowed
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_outlined,
                  color: allowed ? AppTheme.primaryGreen : AppTheme.warning,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      allowed ? 'Notifications are on' : 'Tray notifications need attention',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      !configured
                          ? 'This build was made without Firebase configuration.'
                          : allowed
                              ? 'Order, ride and payment updates can appear on this phone.'
                              : needsToken
                                  ? 'Permission is on, but this device has no push token yet.'
                                  : 'Aliob can still show notices in the in-app inbox.',
                      style: const TextStyle(
                          fontSize: 12, height: 1.4, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (configured && !allowed) ...[
            const SizedBox(height: 12),
            if (blockedByPermission)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await NotificationService.instance.openSystemSettings();
                  },
                  icon: const Icon(Icons.settings_outlined, size: 17),
                  label: const Text('OPEN SYSTEM SETTINGS'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: BorderSide(
                        color: AppTheme.primaryGreen.withOpacity(0.45)),
                  ),
                ),
              )
            else if (needsPermission)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _askPermission,
                  icon: const Icon(Icons.notifications_active_outlined, size: 17),
                  label: const Text('ALLOW NOTIFICATIONS'),
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primaryGreen),
                ),
              )
            else if (needsToken)
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _retryToken,
                  icon: const Icon(Icons.refresh_rounded, size: 17),
                  label: const Text('RETRY THIS DEVICE TOKEN'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primaryGreen,
                    side: BorderSide(
                        color: AppTheme.primaryGreen.withOpacity(0.45)),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _testing ? null : _sendTest,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_outlined, size: 17),
              label: Text(_testing
                  ? 'SENDING…'
                  : 'SEND ME A TEST NOTIFICATION'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.teal,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
          if (_testMessage != null) ...[
            const SizedBox(height: 10),
            Text(
              _testMessage!,
              style: const TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: AppTheme.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _preferenceCard() {
    return Container(
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
            onChanged: _saving ? null : (v) => _save(push: v),
            title: const Text('Push notifications',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
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
            onChanged: _saving ? null : (v) => _save(sms: v),
            title: const Text('SMS',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'Saved for when SMS alerts launch — nothing is sent by text yet.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _email,
            activeColor: AppTheme.primaryGreen,
            onChanged: _saving ? null : (v) => _save(email: v),
            title: const Text('Email',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'Saved for when email alerts launch — nothing is sent by email yet.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _guidanceCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: ExpansionTile(
        leading: const Icon(Icons.phone_android_outlined,
            color: AppTheme.teal, size: 21),
        title: const Text(
          'Phone not showing notifications?',
          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
        ),
        subtitle: const Text(
          'Samsung, Xiaomi, Oppo and Vivo can stop background apps.',
          style: TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: const [
          _GuidanceLine(
            title: 'Samsung',
            body:
                'Settings → Apps → Aliob → Battery → Unrestricted. Also turn off '
                '“Put unused apps to sleep” for Aliob.',
          ),
          SizedBox(height: 10),
          _GuidanceLine(
            title: 'Xiaomi / Redmi / POCO',
            body:
                'Settings → Apps → Manage apps → Aliob → Autostart on, Battery '
                'saver → No restrictions, and Notifications → allow lockscreen '
                'notifications.',
          ),
          SizedBox(height: 10),
          _GuidanceLine(
            title: 'Oppo / Vivo / Realme',
            body:
                'Settings → Battery → App battery management → Aliob → Allow '
                'background activity. Allow auto-start if your phone offers it.',
          ),
        ],
      ),
    );
  }
}

class _GuidanceLine extends StatelessWidget {
  const _GuidanceLine({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 3,
          height: 3,
          child: DecoratedBox(
            decoration: BoxDecoration(
                color: AppTheme.teal, shape: BoxShape.circle),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: const TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: AppTheme.textSecondary),
              children: [
                TextSpan(
                    text: '$title: ',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: body),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
