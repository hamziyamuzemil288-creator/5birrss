// Central environment configuration. Values are injected at build time via
// --dart-define (see README). NEVER hard-code real keys here.
class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const googleMapsApiKey = String.fromEnvironment('GOOGLE_MAPS_API_KEY');

  // Firebase Cloud Messaging — TRANSPORT ONLY. There is no Firestore and no
  // Cloud Function in this project; Firebase is used purely to deliver push.
  // The four values below are the public config of a Firebase Android app
  // (Project settings → Your apps). They are PUBLIC identifiers, not secrets —
  // the same values ship inside google-services.json on every Firebase app —
  // so passing them via --dart-define is safe and keeps them out of the repo.
  //
  // When they are absent (a build without Firebase configured), the app still
  // builds and runs; NotificationService simply keeps push off. That is why
  // there is deliberately no google-services.json and no google-services
  // Gradle plugin here — neither can be present before these are supplied, and
  // their absence would fail every CI build.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseMessagingSenderId =
      String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId =
      String.fromEnvironment('FIREBASE_PROJECT_ID');

  /// True only when a complete Firebase Android config was injected. The one
  /// gate that decides whether push is attempted at all.
  static bool get firebaseConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseMessagingSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;

  static void assertConfigured() {
    assert(supabaseUrl.isNotEmpty, 'SUPABASE_URL not provided via --dart-define');
    assert(supabaseAnonKey.isNotEmpty, 'SUPABASE_ANON_KEY not provided via --dart-define');
  }
}
