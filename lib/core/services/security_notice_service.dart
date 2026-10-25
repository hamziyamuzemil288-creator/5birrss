import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The client half of the security notices added in
/// `20261025000001_listing_and_security_notices.sql`.
///
/// ## What the client is and is not allowed to decide
///
/// The client does NOT decide that something was a "new device". It supplies
/// one stable key per app installation and the server keeps the memory of which
/// keys it has seen (`security_events`, unique per user + event + device). The
/// first sighting produces one notification; every later sign-in from the same
/// install is silent. That is why this can be safe to expose to a signed-in
/// client at all — `note_security_event` can only ever act on `auth.uid()`, so
/// the worst a hostile caller can do is tell themselves something.
///
/// ## Why the key lives in secure storage
///
/// A key in SharedPreferences can be read and cleared by anything with file
/// access, which would turn "new device" into "every login after someone
/// cleared app data". The Keystore/Keychain entry survives restarts and is the
/// same store the session already lives in (`SecureSessionStorage`).
///
/// Every call here is best-effort on purpose: a security notice that fails must
/// never block a login or a completed password change. Failures are logged and
/// dropped, exactly like the notification path on the server.
class SecurityNoticeService {
  SecurityNoticeService._();

  static const _deviceKeyName = 'SECURITY_DEVICE_KEY';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static String? _cached;

  /// A stable, opaque identifier for this installation.
  ///
  /// Generated once and reused forever; it contains no hardware identifier, no
  /// account id and nothing that identifies the person. Rotating it (a reinstall
  /// or a cleared keystore) is correctly treated as a new device.
  static Future<String?> _deviceKey() async {
    if (_cached != null) return _cached;
    try {
      final existing = await _secure.read(key: _deviceKeyName);
      if (existing != null && existing.isNotEmpty) {
        _cached = existing;
        return existing;
      }
      final key = '${_platformName()}-'
          '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      await _secure.write(key: _deviceKeyName, value: key);
      _cached = key;
      return key;
    } catch (e) {
      debugPrint('security notice: could not read the device key: $e');
      return null;
    }
  }

  static String _platformName() {
    try {
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isWindows) return 'windows';
      if (Platform.isLinux) return 'linux';
    } catch (_) {
      // Platform is unavailable on some test hosts; the key still works.
    }
    return 'app';
  }

  /// Call after a successful sign-in. Notifies only the first time this install
  /// signs in to this account.
  static Future<void> noteLogin() => _note('LOGIN');

  /// Call after a password has actually been changed (either the recovery
  /// screen or the signed-in change-password screen).
  static Future<void> notePasswordChanged() => _note('PASSWORD_CHANGED');

  static Future<void> _note(String event) async {
    final client = Supabase.instance.client;
    if (client.auth.currentUser == null) return;
    final key = await _deviceKey();
    if (key == null) return;
    try {
      await client.rpc('note_security_event', params: {
        'p_event': event,
        'p_device_key': key,
        'p_label': _platformName(),
      });
    } catch (e) {
      // Best effort: the login or the password change already succeeded and
      // must not be reported as failed because a courtesy notice did not send.
      debugPrint('security notice ($event) skipped: $e');
    }
  }
}
