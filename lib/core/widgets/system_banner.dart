import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ONE controller behind the top-of-screen system banner.
///
/// Part 8 of the registration rework: a brief, non-blocking alert that slides
/// in at the very top of the app — above every route, below nothing but the
/// connectivity strip. Its first use is the welcome a new account sees the
/// moment registration succeeds, and it is deliberately generic so any
/// future system-critical alert ("scheduled maintenance", "your payment was
/// verified") can reuse it with one call:
///
///   SystemBannerController.instance.show(
///     title: 'Welcome to Aliob!',
///     message: 'Your account is ready.',);
///
/// It is an ADDITION to the notifications panel, not a replacement: the
/// welcome is also written into `notifications` by the signup trigger
/// (migration 20261014000000, through notify_user_once), so it stays in the
/// inbox after the banner has slid away.
///
/// A ChangeNotifier singleton rather than a Riverpod provider because the
/// banner is mounted in the app's `builder` — above the Navigator, outside
/// every route's context — where a Consumer would need an ancestor provider
/// the router overlay does not have.
class SystemBannerController extends ChangeNotifier {
  SystemBannerController._();

  static final SystemBannerController instance = SystemBannerController._();

  Timer? _timer;
  String? _title;
  String? _message;
  bool _visible = false;

  bool get isVisible => _visible;
  String? get title => _title;
  String? get message => _message;

  /// Shows the banner for [duration], then hides it. Calling show() again
  /// replaces the current message and restarts the timer — two alerts never
  /// stack, because a stack of banners is a dialog with extra steps.
  void show({
    required String title,
    required String message,
    Duration duration = const Duration(seconds: 8),
  }) {
    _timer?.cancel();
    _title = title;
    _message = message;
    _visible = true;
    _timer = Timer(duration, hide);
    notifyListeners();
  }

  void hide() {
    _timer?.cancel();
    _timer = null;
    if (!_visible && _title == null) return;
    _visible = false;
    _title = null;
    _message = null;
    notifyListeners();
  }
}

/// The banner itself. Mounted once in `app.dart`'s builder, next to the
/// connectivity strip, so it renders on every screen without being a route.
class SystemBanner extends StatelessWidget {
  const SystemBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: SystemBannerController.instance,
      builder: (context, _) {
        final controller = SystemBannerController.instance;
        // AnimatedSize, not a route transition: the banner expands from zero
        // height in place. It cannot cover content permanently (it hides
        // itself), it cannot be tapped away by accident, and the screens
        // below do not reflow around a dialog.
        return AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !controller.isVisible
              ? const SizedBox(width: double.infinity)
              : Material(
                  color: AppTheme.primaryGreen,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                      child: Row(
                        children: [
                          const Icon(Icons.celebration_outlined,
                              color: Colors.white, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  controller.title ?? '',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (controller.message != null &&
                                    controller.message!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    controller.message!,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.9),
                                      fontSize: 12.5,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Dismiss',
                            iconSize: 18,
                            icon: const Icon(Icons.close,
                                color: Colors.white, size: 18),
                            onPressed:
                                SystemBannerController.instance.hide,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}
