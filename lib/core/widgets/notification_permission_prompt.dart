import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import '../services/notification_service.dart';
import '../theme/app_theme.dart';

/// Ask for Android 13's POST_NOTIFICATIONS permission at a moment the user
/// understands, with one short sentence about why.
///
/// It does nothing when Firebase is not configured, when permission is already
/// granted, when the user already refused (the Notification Settings screen
/// owns that recovery), or after this process has asked once. That last rule
/// is what stops the dialog reappearing on every checkout.
class NotificationPermissionPrompt {
  NotificationPermissionPrompt._();

  static bool _askedThisRun = false;

  static Future<void> maybeAsk(
    BuildContext context, {
    required String reason,
  }) async {
    if (_askedThisRun) return;

    NotificationReadiness readiness;
    try {
      readiness = await NotificationService.instance.readiness();
    } catch (_) {
      return;
    }
    if (!readiness.firebaseConfigured) return;
    if (readiness.permission) return;
    if (readiness.authorizationStatus == AuthorizationStatus.denied) return;

    _askedThisRun = true;
    if (!context.mounted) return;

    final allow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.notifications_active_outlined,
            color: AppTheme.primaryGreen),
        title: const Text('Keep up with Aliob'),
        content: Text(
          '$reason\n\n'
          'Turn on notifications and Aliob can show order approvals, a driver '
          'being assigned, and delivery updates on your phone — even when the '
          'app is closed. You can change this any time in Notification '
          'Settings.',
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primaryGreen),
            child: const Text('Turn on'),
          ),
        ],
      ),
    );

    if (allow != true) return;
    final granted = await NotificationService.instance.requestPermission();
    if (!granted && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Notifications are still off. You can turn them on later from '
            'Notification Settings.',
          ),
        ),
      );
    }
  }
}
