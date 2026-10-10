import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens a web page in the browser. A seam so tests never launch anything.
abstract interface class UrlOpener {
  /// Returns false when nothing could open [uri].
  Future<bool> open(Uri uri);
}

class PlatformUrlOpener implements UrlOpener {
  const PlatformUrlOpener();

  @override
  Future<bool> open(Uri uri) async {
    // Only web links, and only in the browser: never inside the app.
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return false;
    }
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  }
}

final urlOpenerProvider = Provider<UrlOpener>(
  (ref) => const PlatformUrlOpener(),
);
