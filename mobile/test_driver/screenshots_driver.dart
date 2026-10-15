import 'dart:io';
import 'dart:typed_data';

import 'package:integration_test/integration_test_driver_extended.dart';

import '../tool/store_assets/png.dart';

/// The host half of `integration_test/store_screenshots_test.dart` (run by
/// tool/screenshots.sh through `flutter drive`): every capture the test takes arrives
/// here as an RGBA PNG of the whole Flutter surface. It is cut to the app (the
/// "Screenshot mode" strip and the status bar under it removed, then at most
/// [maxHeight] px kept from the top), flattened on the app background and written as a
/// 24-bit PNG without alpha to `store/screenshots/<name>.png` (PLAY_STORE §5).
const maxHeight = 2160;

/// The light `bg` token: nothing should be transparent, but if anything is, it lands on
/// the app's own background rather than black.
const _background = 0xF7F5F2;

Future<void> main() => integrationDriver(
  onScreenshot: (rawName, bytes, [args]) async {
    // "<name>@cropTop=<px>": the test measures the strip on the phone and says how much
    // to cut (arguments to takeScreenshot are not supported on Android).
    final match = RegExp(r'^(.*)@cropTop=(\d+)$').firstMatch(rawName);
    final name = match?.group(1) ?? rawName;
    final cropTop = int.parse(match?.group(2) ?? '0');
    final image = decodePng(Uint8List.fromList(bytes));
    final height = image.height - cropTop > maxHeight
        ? maxHeight
        : image.height - cropTop;
    final cropped = image
        .crop(0, cropTop, image.width, height)
        .flattenOn(_background);
    final out = File('store/screenshots/$name.png')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(encodePng(cropped, alpha: false));
    stdout.writeln(
      'screenshot $name: ${image.width}x${image.height} -> '
      '${cropped.width}x${cropped.height} (cut $cropTop px at the top, '
      '${image.height - cropTop - height} at the bottom), ${out.lengthSync()} bytes',
    );
    return true;
  },
);
