import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_build.dart';
import '../config/env.dart';
import 'secure_session_storage.dart';

/// Thin wrapper around the Supabase client. Role checks are NEVER done
/// client-side for authorization — this class is for reads/writes that RLS
/// already protects, and for calling Edge Functions for privileged actions.
class SupabaseService {
  SupabaseService._();
  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get client => Supabase.instance.client;

  static Future<void> init() async {
    Env.assertConfigured();

    // Validate URL format — Supabase.initialize() expects a bare project
    // URL like https://<ref>.supabase.co, NOT a REST endpoint with a path.
    final url = Env.supabaseUrl;
    if (url.contains('/rest/') || url.contains('/auth/')) {
      throw ArgumentError(
        'SUPABASE_URL must be the bare project URL '
        '(e.g. https://<ref>.supabase.co) — got "$url" '
        'which contains a path segment. Remove /rest/v1 or /auth/v1 '
        'from the URL and pass only the base domain.',
      );
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      throw ArgumentError(
        'SUPABASE_URL must start with https:// — got "$url"',
      );
    }

    await Supabase.initialize(
      url: url,
      anonKey: Env.supabaseAnonKey,
      // Item I: every request carries the build this binary was compiled with,
      // so the server-side gate (assert_client_build_is_supported, read from
      // the request headers) can reject a write from a build the platform no
      // longer accepts. Sending it in a header rather than as a parameter on
      // each RPC means no RPC signature changed to become gated, and an old
      // client that sends nothing reads as build 0 — below every minimum — so
      // omitting it is not a bypass.
      headers: {
        'x-client-build': kAppBuildNumber.toString(),
        'x-client-platform': kIsWeb
            ? 'android'
            : (Platform.isIOS ? 'ios' : 'android'),
      },
      // Limit realtime event rate to prevent abuse and reduce bandwidth.
      realtimeClientOptions: const RealtimeClientOptions(
        eventsPerSecond: 2,
      ),
      // Session persistence goes to the OS secure store (Keystore/Keychain),
      // not plaintext SharedPreferences. See secure_session_storage.dart.
      authOptions: const FlutterAuthClientOptions(
        asyncStorage: SecureSessionStorage(),
      ),
    );
  }

  User? get currentUser => client.auth.currentUser;
  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
  }) {
    return client.auth.signUp(email: email, password: password);
  }

  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) {
    return client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signOut() => client.auth.signOut();

  /// Calls a privileged Edge Function. Supabase client automatically attaches
  /// the current user's JWT — the function re-validates role server-side.
  Future<Map<String, dynamic>> invokeFunction(
    String name, {
    Map<String, dynamic>? body,
  }) async {
    final res = await client.functions.invoke(name, body: body);
    if (res.status != 200) {
      throw Exception('Function $name failed: ${res.data}');
    }
    return Map<String, dynamic>.from(res.data as Map);
  }
}
