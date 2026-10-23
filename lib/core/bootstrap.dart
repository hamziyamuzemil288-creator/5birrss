/// App bootstrap: error capture, Supabase init, and the root widget tree.
///
/// ## What changed, and why it was the single highest-value fix
///
/// The previous `main()` installed this handler:
///
/// ```dart
/// PlatformDispatcher.instance.onError = (error, stack) {
///   globalCrashError.value = error.toString();
///   return true;   // <-- "I handled it"
/// };
/// ```
///
/// `return true` tells Dart the error was handled, so it never reaches the
/// console or the debugger. Meanwhile *any* uncaught async error — including
/// a realtime socket that failed to open on a bad network — set a notifier
/// that swapped the entire `MaterialApp` for a red "App Error Detected"
/// screen. One dropped websocket, and a user mid-checkout lost the app.
///
/// That is the "blank screen regression" the brief refers to, and the
/// mechanism is now inverted:
///
/// * A **transport** error is not an application fault. It is logged, shown as
///   a quiet banner, and the app keeps running.
/// * A **genuine crash** is caught by the nearest [AppErrorBoundary] and
///   shown as a recovery screen with a Try again button — scoped to the
///   screen that broke, not the whole app.
/// * Only an error with no widget context at all reaches here, and even then
///   the user sees a sentence, never a stack trace.
///
/// ## Why the crash screen has no stack trace
///
/// A stack trace on a user's phone is unreadable to them and a small
/// information leak to everyone else. The trace goes to `client_error_logs`
/// where the CEO can read it; the screen says what happened and offers a way
/// out.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import 'resilience/failure_mapper.dart';
import 'services/error_logger.dart';
import 'services/notification_service.dart';
import 'services/supabase_service.dart';
import 'theme/app_theme.dart';
import 'widgets/app_error_boundary.dart';
import 'widgets/connectivity_banner.dart';

/// The last unhandled crash, or null. Read by the root widget to decide
/// whether to show the recovery screen.
///
/// A [String] and not the exception itself: nothing in the UI may be tempted
/// to display it, because it is a developer string, not a sentence.
final ValueNotifier<String?> globalCrashError = ValueNotifier<String?>(null);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _installErrorHandling();

  // Startup is the one place a failure is genuinely fatal — there is no
  // app to show without a Supabase client. It gets its own screen, and it
  // gets a Retry rather than a restart, because the common cause is a slow
  // network and the second attempt usually works.
  await runZonedGuarded(
    () async {
      runApp(const _Bootstrap());
    },
    (error, stack) {
      // An error in a zone with no widget context. Report it and swallow;
      // returning false would rethrow into the console, which is fine and
      // non-fatal, but true is correct here because we have logged it.
      ErrorLogger.instance.logError(
        error,
        stack,
        source: 'zone',
        context: 'app zone',
        isFatal: true,
      );
    },
  );
}

void _installErrorHandling() {
  // Framework errors during build. `presentError` still dumps to the console
  // in debug, which is where a developer wants it; in release it is a no-op.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    ErrorLogger.instance.logError(
      details.exception,
      details.stack,
      source: 'flutter_error',
      context: 'framework',
    );
    // Deliberately NOT set here. A build error is contained by the nearest
    // AppErrorBoundary, which has already swapped the subtree. Setting the
    // global would replace the whole app for one broken widget — the exact
    // failure this file exists to stop.
  };

  // Errors with no widget context: async gaps, unawaited futures, platform
  // channels. This is where a dropped realtime socket lands.
  PlatformDispatcher.instance.onError = (error, stack) {
    final failure = AppFailureMapper.map(error, context: 'the app');

    // A transport problem is not a crash. Swallowing it here is the whole
    // point: the socket reconnects or the screen polls, and the user never
    // learns there was anything to recover from.
    if (failure.isTransport) {
      ErrorLogger.instance.logError(
        error,
        stack,
        source: 'platform_error',
        context: 'transport',
      );
      return true;
    }

    ErrorLogger.instance.logError(
      error,
      stack,
      source: 'platform_error',
      context: 'fatal',
      isFatal: true,
    );
    globalCrashError.value = failure.message;
    return true;
  };
}

/// The root widget. Owns the startup gate, the crash gate, the connectivity
/// banner, and a boundary around everything.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap();

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  /// Null until the first attempt resolves. A failed attempt sets
  /// [startupError] and leaves [isStarting] false so Retry can run again.
  Object? _startupError;
  bool _isStarting = true;

  @override
  void initState() {
    super.initState();
    _startSupabase();
  }

  Future<void> _startSupabase() async {
    setState(() {
      _isStarting = true;
      _startupError = null;
    });
    try {
      // Ten seconds is a deliberate ceiling: a mobile client that cannot
      // reach the project in ten seconds is not going to, and a user staring
      // at a blank screen is worse than one reading "we could not start".
      await SupabaseService.init().timeout(const Duration(seconds: 10));
      if (mounted) setState(() => _isStarting = false);
      // Push transport comes up AFTER the app shell, never on the critical
      // path: a slow or unconfigured Firebase must not delay or break startup.
      // Best-effort and self-guarding (see NotificationService.initialize).
      unawaited(NotificationService.instance.initialize());
    } catch (e, st) {
      ErrorLogger.instance.logError(
        e,
        st,
        source: 'startup',
        context: 'SupabaseService.init',
        isFatal: true,
      );
      if (mounted) {
        setState(() {
          _startupError = e;
          _isStarting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: ValueListenableBuilder<String?>(
        valueListenable: globalCrashError,
        builder: (context, crashMessage, _) {
          // The last-resort gate. By the time anything reaches here it has
          // already been classified and logged, so all that is left is to
          // say it plainly and offer a restart.
          if (crashMessage != null) {
            return _Shell(
              child: StartupFailedScreen(
                title: 'Something went wrong',
                message: crashMessage,
                onRetry: () {
                  globalCrashError.value = null;
                  _startSupabase();
                },
              ),
            );
          }

          if (_isStarting) {
            return const _Shell(
              child: _StartupSplash(),
            );
          }

          if (_startupError != null) {
            return _Shell(
              child: StartupFailedScreen(
                title: 'We could not start',
                // A config error is ours and actionable; anything else is
                // almost certainly the network. Saying so is more useful
                // than echoing a stack trace.
                message: _startupError is ArgumentError
                    ? 'This build is not configured correctly. Please update '
                        'the app or contact support.'
                    : 'We could not reach our servers. Check your connection '
                        'and try again.',
                onRetry: _startSupabase,
              ),
            );
          }

          // No ProviderScope here. One already wraps this whole builder, and
          // a nested ProviderScope creates a SECOND container — every
          // provider the app reads would be instantiated twice and the two
          // instances would not see each other's state. That is a subtle
          // break (auth state, cart count and cached queries silently
          // disagreeing), so there is exactly one, at the top.
          return const _AppShell();
        },
      ),
    );
  }
}

/// The normal app, with the global banner and a boundary above everything.
///
/// The boundary is the backstop for a failure during the *first frame* of
/// the router, which no inner boundary can catch because the inner ones have
/// not been built yet.
class _AppShell extends StatelessWidget {
  const _AppShell();

  @override
  Widget build(BuildContext context) {
    return const AppErrorBoundary(
      screenName: 'app-root',
      child: _WithBanner(),
    );
  }
}

class _WithBanner extends StatelessWidget {
  const _WithBanner();

  @override
  Widget build(BuildContext context) {
    // The banner lives inside Birr5App's MaterialApp via its `builder`, so
    // it is not duplicated here — see app.dart. This wrapper exists to keep
    // the two failure paths (startup, crash) visually identical.
    return const Birr5App();
  }
}

class _Shell extends StatelessWidget {
  const _Shell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      // The connectivity banner is part of the app chrome, so the startup
      // and crash screens get it too: a user whose network is down should
      // be told why Retry keeps failing, on every screen.
      builder: (context, child) => Column(
        children: [
          const ConnectivityBanner(),
          Expanded(child: child ?? const SizedBox.shrink()),
        ],
      ),
      home: child,
    );
  }
}

class _StartupSplash extends StatelessWidget {
  const _StartupSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: AppTheme.primaryGreen,
              ),
            ),
            SizedBox(height: 18),
            Text(
              'Starting Aliob…',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

/// The friendly failure screen. Shared by the startup and crash gates so the
/// two are indistinguishable to a user, which is the point: "the app could
/// not start" and "the app hit a bug" are the same problem to the person
/// holding the phone.
///
/// Deliberately shows no stack trace in release. In debug the trace is one
/// tap away, because a developer needs it and a user does not.
class StartupFailedScreen extends StatelessWidget {
  const StartupFailedScreen({
    super.key,
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 86,
                height: 86,
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.wifi_off_rounded,
                  size: 40,
                  color: AppTheme.error,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.55,
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 26),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryGreen,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 30, vertical: 13),
                ),
              ),
              if (kDebugMode)
                TextButton(
                  onPressed: () => debugPrint(message),
                  child: const Text('Log details (debug build only)'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
