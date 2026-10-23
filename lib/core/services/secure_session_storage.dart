import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Persists the Supabase auth session (access + refresh tokens) in the OS
/// secure store — Android Keystore / iOS Keychain — instead of the default
/// plaintext SharedPreferences.
///
/// ## Why this exists
///
/// `supabase_flutter` persists the session so a restart restores the login.
/// Out of the box that persistence is SharedPreferences: a plain JSON blob on
/// unencrypted storage. On a rooted device or via an ADB backup, anybody with
/// file access can lift a live refresh token and impersonate the user. Moving
/// the blob into the Keystore/Keychain means the tokens are encrypted at rest
/// by the platform and never sit on disk in the clear.
///
/// The adapter is deliberately thin: it forwards every operation to
/// [FlutterSecureStorage] under the same key `supabase_flutter` already uses,
/// so the SDK keeps owning the session JSON and this class only owns WHERE it
/// is written.
///
/// ## One-time migration caveat
///
/// This changes the storage BACKEND. A session written by an older build into
/// SharedPreferences is not visible here, so the first launch after this
/// ships will find no stored session and ask the user to sign in once. That is
/// a one-time cost of adopting secure storage — after it, the session is
/// restored from the Keystore across restarts. (Auto-migrating the old blob
/// would require pinning the exact default storage key of the resolved gotrue
/// version, which cannot be verified without the Flutter SDK; leaving it out
/// is safer than corrupting a live session.)
class SecureSessionStorage extends AuthAsyncStorage {
  const SecureSessionStorage();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  @override
  Future<void> initialize() async {
    // Nothing to set up: FlutterSecureStorage needs no explicit init on
    // Android or iOS. Kept because AuthAsyncStorage requires the hook and a
    // future platform may want one.
  }

  @override
  Future<String?> read({required String key}) => _secure.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _secure.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _secure.delete(key: key);

  // Deliberately NOT annotated @override: gotrue's AuthAsyncStorage has gained
  // and shed deleteAll() across minor versions. Implementing it un-annotated
  // satisfies the interface when it is abstract and is a harmless extra
  // method when it is not — either way it is not an analyzer error, so this
  // file cannot break the build over one method's presence.
  Future<void> deleteAll() => _secure.deleteAll();
}
