/// The build number and version name this binary was compiled with.
///
/// ## Why this is a constant and not read from the platform
///
/// The forced-update gate has to know its own build number before it can ask
/// the server whether it is too old, and it must know it on the FIRST frame —
/// over the login screen, before any RPC has succeeded. Reading the real
/// `versionCode` would need `package_info_plus` (or a Kotlin MethodChannel),
/// a new dependency and a platform path this project cannot verify without an
/// Android toolchain.
///
/// So the number is a constant, and the "build constant matches pubspec.yaml"
/// test in `test/forced_update_gate_test.dart` asserts it equals the `+N` in
/// `pubspec.yaml` (this comment named a file that does not exist until the
/// release pass; the assertion had simply moved). They cannot drift: a version
/// bump that forgets to update this file fails the test, and a build number
/// the app believes is wrong would gate the wrong users or gate nobody.
///
/// `platform` is derived at runtime from the running OS, not stored here, so
/// the same constants are right for an Android and an iOS build of the same
/// version.
library;

/// The version name from `pubspec.yaml`'s `version:` line, e.g. `1.6.4`.
///
/// The `k` prefix and the explicit `kApp` namespace are deliberate: Flutter's
/// own `package:flutter/services.dart` exports `appBuildNumber`, `appVersion`
/// and friends, and a bare `appBuildNumber` here would collide at every import
/// site that pulls in both.
const String kAppVersionName = '1.7.13';

/// The build number from `pubspec.yaml`'s `version:` line (`1.6.4+106`), i.e.
/// the part after the `+`. Sent to the server as the `x-client-build` header
/// and compared against `app_release_config.min_required_build`.
const int kAppBuildNumber = 121;
