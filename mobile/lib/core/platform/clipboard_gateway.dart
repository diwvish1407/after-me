import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Puts text on the system clipboard.
///
/// The app has exactly one use: the "Copy diagnostic text" button on the About screen,
/// which the person taps on purpose to paste four facts about this build (version, build
/// number, environment, API host) into a bug report. Nothing else is ever copied, and the
/// app never *reads* the clipboard.
abstract interface class ClipboardGateway {
  /// Returns false when the system refused (the caller then says so).
  Future<bool> copy(String text);
}

class PlatformClipboardGateway implements ClipboardGateway {
  const PlatformClipboardGateway();

  @override
  Future<bool> copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      return true;
    } on Object {
      // Any failure, not only a PlatformException: a missing plugin implementation
      // (MissingPluginException is an Exception, not a PlatformException), a cancelled
      // channel or a platform that answers with something unexpected. The caller says so
      // honestly ("could not copy"); nothing is thrown at the button's handler.
      return false;
    }
  }
}

final clipboardGatewayProvider = Provider<ClipboardGateway>(
  (ref) => const PlatformClipboardGateway(),
);
