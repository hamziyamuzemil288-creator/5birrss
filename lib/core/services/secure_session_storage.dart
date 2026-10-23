import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase auth session (access + refresh tokens) in the OS
/// secure store — Android Keystore / iOS Keychain — instead of the default
/// plaintext SharedPreferences.
///
/// ## Why this exists
/// `supabase_flutter` persists the session so a restart restores the login.
/// Out of the box that persistence is SharedPreferences: a plain JSON blob on
/// unencrypted storage. On a rooted device or via an ADB backup, anybody with
/// file access can lift a live refresh token and impersonate the user. Moving
/// the blob into the Keystore/Keychain means the tokens are encrypted at rest
/// by the platform and never sit on disk in the clear.
///
/// ## How it plugs in
/// In supabase_flutter 2.18.x the persisted session flows exclusively through
/// the [LocalStorage] interface (`persistSession` writes the whole session
/// JSON, `accessToken` reads it back for recovery on launch,
/// `removePersistedSession` clears it on sign-out). This adapter implements
/// exactly that surface, backed by [FlutterSecureStorage], and is supplied to
/// `Supabase.initialize` via `FlutterAuthClientOptions(localStorage: ...)` in
/// `supabase_service.dart`. The SDK keeps owning the session JSON; this class
/// only owns WHERE it is written.
///
/// ## One-time migration caveat
/// This changes the storage BACKEND. A session written by an older build into
/// SharedPreferences is not visible here, so the first launch after this
/// ships will find no stored session and ask the user to sign in once. That is
/// a one-time cost of adopting secure storage — after it, the session is
/// restored from the Keystore across restarts. (Auto-migrating the old blob
/// would require pinning the exact default storage key of the resolved
/// SharedPreferencesLocalStorage version and parsing it before the SDK reads
/// it; leaving it out is safer than corrupting a live session.)
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// Our own key, private to this adapter. The default SharedPreferences
  /// backend is replaced wholesale, so there is nothing to share a key with.
  static const _sessionKey = 'SUPABASE_SECURE_SESSION';

  @override
  Future<void> initialize() async {
    // Nothing to set up: FlutterSecureStorage needs no explicit init on
    // Android or iOS. Kept because LocalStorage requires the hook and a
    // future platform may want one.
  }

  @override
  Future<bool> hasAccessToken() async =>
      (await _secure.read(key: _sessionKey)) != null;

  @override
  Future<String?> accessToken() => _secure.read(key: _sessionKey);

  @override
  Future<void> removePersistedSession() => _secure.delete(key: _sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _secure.write(key: _sessionKey, value: persistSessionString);

  /// Wipe everything this adapter wrote. Called by the session-persistence
  /// cleanup paths; not part of [LocalStorage].
  Future<void> deleteAll() => _secure.deleteAll();
}
