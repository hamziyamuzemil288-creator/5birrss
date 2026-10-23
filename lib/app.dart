import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'routing/app_router.dart';
import 'core/services/notification_service.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/app_update_gate.dart';
import 'core/widgets/connectivity_banner.dart';
import 'core/widgets/system_banner.dart';
import 'features/help_chat/floating_chat_button.dart';

class Birr5App extends ConsumerWidget {
  const Birr5App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);

    // Push deep-links navigate through the app's single GoRouter. Attaching it
    // here (idempotent) lets NotificationService route a tapped push, and drains
    // any deep link that cold-started the app before the router existed.
    NotificationService.instance.attachRouter(router);

    return MaterialApp.router(
      title: 'Aliob',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.light,
      routerConfig: router,
      // `builder` runs above the Navigator, so the connectivity banner is not
      // a route: it cannot be popped, cannot stack, and shows on every screen
      // including modal ones. That is the intent — the connection is a global
      // fact, and a per-screen indicator would mean the user learns about it
      // on whichever screen they happen to be on.
      builder: (context, child) => Column(
        children: [
          const ConnectivityBanner(),
          // Part 8: the system banner — welcome-after-signup today, any
          // system-critical alert tomorrow. In the same Column as the
          // connectivity strip for the same reason that strip is here: it
          // cannot be popped, cannot stack on a route, and shows on every
          // screen. It expands from zero height and hides itself, so it never
          // permanently takes space from the app below.
          const SystemBanner(),
          // Expanded, not Expanded-less: without it the Column would size
          // itself to the banner and the app would collapse to a sliver.
          Expanded(
            // Item I: the forced-update gate, above the Navigator and beside
            // the connectivity banner, so it covers every route including
            // /auth. A build below the minimum cannot sign in — the server
            // would reject its writes anyway.
            child: AppUpdateGate(
              child: FloatingChatOverlay(
                  child: child ?? const SizedBox.shrink()),
            ),
          ),
        ],
      ),
    );
  }
}
