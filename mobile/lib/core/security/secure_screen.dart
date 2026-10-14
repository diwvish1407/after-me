import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';

/// Sets and clears `FLAG_SECURE` on the app's window (FR-INS-06, SECURITY.md §11).
///
/// While the flag is set Android blocks screenshots and screen recording of the window
/// and shows nothing of it in the recents/app switcher. Android only: everywhere else
/// the call is a no-op.
abstract interface class SecureScreenGateway {
  Future<void> setSecure({required bool enabled});
}

/// The platform implementation: a tiny `MethodChannel` handled by `MainActivity`. It is
/// separate from the app lock's `ScreenPrivacy` (which only hides the recents card while
/// the lock is on): the native side keeps both reasons and clears the flag only when
/// neither applies.
class PlatformSecureScreenGateway implements SecureScreenGateway {
  const PlatformSecureScreenGateway();

  static const MethodChannel _channel = MethodChannel(
    'app.afterme/secure_screen',
  );

  @override
  Future<void> setSecure({required bool enabled}) async {
    try {
      await _channel.invokeMethod<void>('setSecure', {'enabled': enabled});
    } on MissingPluginException {
      // Not running on Android (tests, desktop previews).
    } on PlatformException {
      // Best effort: there is nothing more the screen can do.
    }
  }
}

final secureScreenGatewayProvider = Provider<SecureScreenGateway>(
  (ref) => const PlatformSecureScreenGateway(),
);

/// Counts the screens that need the window to be secure and sets the flag while at
/// least one does. Reference-counted, so a secure page pushed on a secure page (list,
/// detail, edit) can never clear the flag for the one below it.
///
/// The flag is set at once on the first holder; it is cleared a microtask after the last
/// one lets go, so a page that is replaced by another secure page in the same frame
/// never leaves the window unprotected in between.
///
/// With [screenshotMode] (a staging or dev build made to capture store screenshots, see
/// `AppConfig.screenshotMode`) the flag is never set: screens still count their holders,
/// but the window stays capturable. A build with it on also shows a "Screenshot mode"
/// strip on every screen, and `AppConfig` refuses it for prod.
class SecureScreens {
  SecureScreens(this._gateway, {this.screenshotMode = false});

  final SecureScreenGateway _gateway;

  /// The window is deliberately left capturable (never true in a prod build).
  final bool screenshotMode;
  int _holders = 0;
  bool _applied = false;

  /// How many screens hold the flag right now.
  int get holders => _holders;

  void acquire() {
    _holders++;
    if (!_applied && !screenshotMode) {
      _applied = true;
      unawaited(_gateway.setSecure(enabled: true));
    }
  }

  void release() {
    if (_holders > 0) {
      _holders--;
    }
    if (_holders == 0) {
      scheduleMicrotask(() {
        if (_holders == 0 && _applied) {
          _applied = false;
          unawaited(_gateway.setSecure(enabled: false));
        }
      });
    }
  }
}

/// Whether this is a screenshot build (`SCREENSHOT_MODE`, validated by [AppConfig]).
///
/// Fails closed: anywhere the configuration is not provided (a widget test that does not
/// set it up) the answer is false, which keeps `FLAG_SECURE` on.
final screenshotModeProvider = Provider<bool>((ref) {
  try {
    return ref.watch(appConfigProvider).screenshotMode;
  } on Object {
    return false;
  }
});

final secureScreensProvider = Provider<SecureScreens>(
  (ref) => SecureScreens(
    ref.watch(secureScreenGatewayProvider),
    screenshotMode: ref.watch(screenshotModeProvider),
  ),
);

/// Wraps a screen that shows or edits instruction content (titles included): while it is
/// on screen, the window is `FLAG_SECURE`.
///
/// "On screen" is decided by [TickerMode], which Flutter turns off for a subtree that is
/// built but not shown: a tab that is not selected (the shell keeps every tab's
/// navigator alive) and a page covered by another full-screen route. So leaving the
/// Instructions area for Home, or replacing the page, lets go of the flag as well as
/// removing the widget does.
///
/// With [enabled] false the flag is not held (Home holds it only while it shows an
/// instruction's title); switching it on or off while the widget stays in the tree
/// acquires or releases the flag at once.
class SecureScreen extends ConsumerStatefulWidget {
  const SecureScreen({required this.child, this.enabled = true, super.key});

  final Widget child;

  /// Whether this screen needs the window to be secure right now.
  final bool enabled;

  @override
  ConsumerState<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends ConsumerState<SecureScreen> {
  late final SecureScreens _screens;
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    _screens = ref.read(secureScreensProvider);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(covariant SecureScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final needed = widget.enabled && TickerMode.valuesOf(context).enabled;
    if (needed && !_holding) {
      _holding = true;
      _screens.acquire();
    } else if (!needed && _holding) {
      _holding = false;
      _screens.release();
    }
  }

  @override
  void dispose() {
    if (_holding) {
      _holding = false;
      _screens.release();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
