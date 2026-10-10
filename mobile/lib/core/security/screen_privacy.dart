import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Hides the app's content in the Android recents thumbnail.
///
/// While [setObscureInRecents] is true, `MainActivity` sets `FLAG_SECURE` in `onPause`
/// (before the system takes the snapshot) and clears it in `onResume`. Doing it natively
/// makes it synchronous with the activity lifecycle; a Dart-side overlay could be drawn
/// too late.
abstract interface class ScreenPrivacy {
  Future<void> setObscureInRecents({required bool enabled});
}

class PlatformScreenPrivacy implements ScreenPrivacy {
  const PlatformScreenPrivacy();

  static const MethodChannel _channel = MethodChannel('app.afterme/privacy');

  @override
  Future<void> setObscureInRecents({required bool enabled}) async {
    try {
      await _channel.invokeMethod<void>('setObscureInRecents', {
        'enabled': enabled,
      });
    } on MissingPluginException {
      // Not running on Android (tests, desktop previews).
    } on PlatformException {
      // Best effort: the Dart lock screen still covers the app.
    }
  }
}

final screenPrivacyProvider = Provider<ScreenPrivacy>(
  (ref) => const PlatformScreenPrivacy(),
);
