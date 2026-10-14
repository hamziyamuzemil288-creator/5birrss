import 'package:supabase_flutter/supabase_flutter.dart';

/// The buyer-safe slice of `system_settings` — the platform's contact number
/// and the platform's payment details — read through the one RPC that exposes
/// them (`public_app_settings()`, migration 20261014000003).
///
/// Part 3 and Part 4 of the rework: a buyer is never pointed at a PROVIDER's
/// phone number or bank account, so the number they call and the account they
/// pay into are configuration an administrator edits in Admin → Contact
/// Settings / Payment Settings, not values baked into a screen.
///
/// Reads are cached for [cacheTtl] — the same settings power every card on a
/// screen, and a checkout should not re-read configuration per rebuild. A
/// failed read yields the empty map, and every caller has a stated fallback
/// (the help chat for the phone, the platform Payment Methods rows for the
/// account); a configuration outage never blocks a buyer.
class PlatformSettings {
  PlatformSettings._();

  static const Duration cacheTtl = Duration(minutes: 5);

  static Map<String, String> _cache = const {};
  static DateTime? _cachedAt;
  static Future<Map<String, String>>? _inFlight;

  /// The two whitelisted keys, keys trimmed, empty values dropped.
  static Future<Map<String, String>> load({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < cacheTtl) {
      return _cache;
    }
    // One in-flight read: a screen with three cards must not start three
    // identical queries because it built before the first one answered.
    final pending = _inFlight;
    if (!forceRefresh && pending != null) return pending;

    _inFlight = _read();
    try {
      _cache = await _inFlight!;
      _cachedAt = DateTime.now();
    } catch (_) {
      // A settings outage is not a buyer's problem: the callers fall back.
      _cache = const {};
      _cachedAt = DateTime.now();
    } finally {
      _inFlight = null;
    }
    return _cache;
  }

  static Future<Map<String, String>> _read() async {
    final rows = await Supabase.instance.client.rpc('public_app_settings');
    final out = <String, String>{};
    for (final row in rows as List) {
      if (row is! Map) continue;
      final key = (row['key'] as String?)?.trim();
      final value = (row['value'] as String?)?.trim();
      if (key == null || key.isEmpty || value == null || value.isEmpty) {
        continue;
      }
      out[key] = value;
    }
    return out;
  }

  /// The support number an administrator configured, or null when none is
  /// set — the caller then points at the in-app help chat instead.
  static Future<String?> contactPhone() async =>
      (await load())['admin_contact_phone'];

  /// The platform's bank / mobile-money details (one per line, `Label:
  /// value`), or null when none are configured.
  static Future<String?> paymentDetails() async =>
      (await load())['admin_payment_details'];
}
