import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The order this device is in the middle of.
///
/// There is no buyer account to log back into, so the only thing that can
/// return a guest to their waiting screen after the app is killed is a small
/// value kept on the device. It is an ORDER ID, never a token: reading the
/// order still goes through RLS as the anonymous session that placed it, so a
/// copied id on another phone reads nothing.
///
/// Cleared as soon as the order reaches a terminal state or the buyer cancels.
class ActiveOrderStore {
  ActiveOrderStore._();

  static const _key = 'aliob.active_order_id';
  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  static Future<void> save(String orderId) async {
    if (orderId.isEmpty) return;
    try {
      await _storage.write(key: _key, value: orderId);
    } catch (_) {
      // Best-effort: the in-memory route still shows the waiting screen.
    }
  }

  static Future<String?> read() async {
    try {
      final value = await _storage.read(key: _key);
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // A stale id is harmless: the resume path re-reads the order's status.
    }
  }
}
