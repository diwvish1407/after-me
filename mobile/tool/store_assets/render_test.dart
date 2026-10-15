// Renders the store graphics and the legacy launcher PNGs from code (PLAY_STORE §5), so
// nobody needs a design tool and every asset comes from the one description of the mark
// (tool/store_assets/mark.dart). NOT part of `flutter test` (it lives outside test/ and
// writes files); run it on purpose, from mobile/:
//
//   flutter test tool/store_assets/render_test.dart
//   dart run tool/store_assets/check_store_assets.dart      # sizes, alpha, bytes
//
// It writes:
//   store/play_icon_512.png              512 x 512, 32-bit PNG (RGBA, fully opaque), <= 1 MB
//   store/feature_graphic_1024x500.png   1024 x 500, 24-bit PNG (RGB, no alpha)
//   store/previews/*.png                 how the icon looks under launcher masks, as a
//                                        themed icon and as the light/dark splash (for a
//                                        person's review only; not uploaded anywhere)
//   android/app/src/main/res/mipmap-*/ic_launcher.png, ic_launcher_round.png
//                                        the legacy launcher icons (48-192 px). minSdk is
//                                        26, so every supported phone uses the adaptive
//                                        icon instead; these exist for completeness.
//
// Text uses Roboto from the local Flutter SDK (bin/cache/artifacts/material_fonts), the
// face Android itself draws the app in: the app bundles no font, and nothing is fetched
// from the network. The words are the app's own strings (lib/l10n/app_en.arb).
//
// It also fails when the Android vector drawables drift from the mark's numbers.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:afterme/l10n/gen/app_localizations_en.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mark.dart';
import 'png.dart';

const _fontFamily = 'AfterMeStoreRoboto';
const _res = 'android/app/src/main/res';

/// Legacy launcher icon sizes per density bucket (48 dp).
const _densities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

Future<void> _loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    throw StateError('FLUTTER_ROOT is not set; cannot find the SDK fonts.');
  }
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader(_fontFamily);
  for (final face in ['Regular', 'Medium']) {
    final file = File('$dir/Roboto-$face.ttf');
    if (!file.existsSync()) {
      throw StateError('${file.path} is missing (run `flutter precache`).');
    }
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  }
  await loader.load();
}

/// Paints [painter] into a [width] x [height] image and returns its straight RGBA pixels.
Future<RgbaImage> _render(CustomPainter painter, int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  );
  image.dispose();
  picture.dispose();
  return RgbaImage(width, height, data!.buffer.asUint8List());
}

void _write(String path, Uint8List bytes) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  // ignore: avoid_print
  print('wrote $path (${bytes.length} bytes)');
}

/// A painter from a function, for the previews.
class _Paint extends CustomPainter {
  _Paint(this.body);
  final void Function(Canvas canvas, Size size) body;
  @override
  void paint(Canvas canvas, Size size) => body(canvas, size);
  @override
  bool shouldRepaint(_Paint oldDelegate) => true;
}

/// The themed (monochrome) icon as Android 13+ draws it: the outline tile and the check
/// in a tint, on a tinted circle.
void _paintThemedPreview(Canvas canvas, Size size) {
  final side = size.width;
  canvas
    ..clipPath(Path()..addOval(Offset.zero & size))
    ..drawRect(Offset.zero & size, Paint()..color = const Color(0xFFDDE7E5));
  final full = side * AfterMeMark.viewport / AfterMeMark.visible;
  final offset = (full - side) / 2;
  final scale = full / AfterMeMark.viewport;
  canvas
    ..save()
    ..translate(-offset, -offset)
    ..scale(scale);
  const inset = AfterMeMark.monochromeTileStroke / 2;
  final tint = Paint()
    ..isAntiAlias = true
    ..color = const Color(0xFF26413F)
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  canvas
    ..drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(
          AfterMeMark.tileLeft + inset,
          AfterMeMark.tileTop + inset,
          AfterMeMark.tileSize - AfterMeMark.monochromeTileStroke,
          AfterMeMark.tileSize - AfterMeMark.monochromeTileStroke,
        ),
        const Radius.circular(AfterMeMark.tileRadius - inset),
      ),
      tint..strokeWidth = AfterMeMark.monochromeTileStroke,
    )
    ..drawPath(
      Path()
        ..moveTo(AfterMeMark.checkStart.dx, AfterMeMark.checkStart.dy)
        ..lineTo(AfterMeMark.checkCorner.dx, AfterMeMark.checkCorner.dy)
        ..lineTo(AfterMeMark.checkEnd.dx, AfterMeMark.checkEnd.dy),
      tint..strokeWidth = AfterMeMark.checkStroke,
    )
    ..restore();
}

/// The Android 12+ splash: the background colour and the icon, which the system shows at
/// 240 dp inside a 160 dp circle (here 1080 x 1920 at 2.625 px per dp).
void Function(Canvas, Size) _splash({required bool dark}) => (canvas, size) {
  canvas.drawRect(
    Offset.zero & size,
    Paint()..color = dark ? AfterMeMark.darkBackground : AfterMeMark.warmWhite,
  );
  const iconPx = 240 * 2.625;
  paintMark(
    canvas,
    Rect.fromCenter(
      center: size.center(Offset.zero),
      width: iconPx,
      height: iconPx,
    ),
    tile: dark ? AfterMeMark.tealOnDark : AfterMeMark.teal,
    check: dark ? AfterMeMark.darkBackground : AfterMeMark.warmWhite,
  );
};

String _pathDataOf(String xmlPath, String name) {
  final xml = File(xmlPath).readAsStringSync();
  final path = RegExp(
    '<path[^>]*android:name="$name"[^>]*>',
    dotAll: true,
  ).firstMatch(xml);
  if (path == null) {
    throw StateError('$xmlPath has no path named "$name"');
  }
  return RegExp(r'android:pathData="([^"]*)"')
      .firstMatch(path.group(0)!)!
      .group(1)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = AppLocalizationsEn();

  setUpAll(_loadRoboto);

  test('the Android vector drawables are the mark (no drift)', () {
    for (final file in [
      '$_res/drawable/ic_launcher_foreground.xml',
      '$_res/drawable/ic_splash.xml',
    ]) {
      expect(_pathDataOf(file, 'tile'), AfterMeMark.tilePathData, reason: file);
      expect(
        _pathDataOf(file, 'check'),
        AfterMeMark.checkPathData,
        reason: file,
      );
    }
    const mono = '$_res/drawable/ic_launcher_monochrome.xml';
    expect(_pathDataOf(mono, 'tile'), AfterMeMark.monochromeTilePathData);
    expect(_pathDataOf(mono, 'check'), AfterMeMark.checkPathData);
  });

  test(
    'Play icon: 512 x 512, 32-bit PNG, full bleed (Play applies the mask)',
    () async {
      final image = await _render(const LauncherIconPainter(), 512, 512);
      expect(image.isOpaque, isTrue);
      final bytes = encodePng(image, alpha: true);
      expect(bytes.length, lessThanOrEqualTo(1024 * 1024));
      _write('store/play_icon_512.png', bytes);
    },
  );

  test('feature graphic: 1024 x 500, 24-bit PNG without alpha', () async {
    final painter = FeatureGraphicPainter(
      fontFamily: _fontFamily,
      name: l10n.appName,
      headline: l10n.tagline,
      statusTitle: l10n.homeStatusActiveTitle,
      buttonLabel: l10n.checkInLabelIdle,
    );
    final image = await _render(painter, 1024, 500);
    // Flattened on the background, so nothing transparent is left to drop.
    final flat = image.flattenOn(0xF7F5F2);
    _write('store/feature_graphic_1024x500.png', encodePng(flat, alpha: false));
  });

  test('legacy launcher PNGs, every density', () async {
    for (final MapEntry(key: density, value: px) in _densities.entries) {
      final square = await _render(
        const LauncherIconPainter(shape: BoxShape.rectangle, margin: 1 / 24),
        px,
        px,
      );
      _write(
        '$_res/mipmap-$density/ic_launcher.png',
        encodePng(square, alpha: true),
      );
      final round = await _render(
        const LauncherIconPainter(shape: BoxShape.circle, margin: 1 / 24),
        px,
        px,
      );
      _write(
        '$_res/mipmap-$density/ic_launcher_round.png',
        encodePng(round, alpha: true),
      );
    }
  });

  test(
    'previews for a person: masks, themed icon, splash light and dark',
    () async {
      final previews = <String, (CustomPainter, int, int)>{
        'launcher_circle_192': (
          const LauncherIconPainter(shape: BoxShape.circle),
          192,
          192,
        ),
        'launcher_squircle_192': (
          const LauncherIconPainter(shape: BoxShape.rectangle),
          192,
          192,
        ),
        'launcher_themed_192': (_Paint(_paintThemedPreview), 192, 192),
        'splash_light_1080x1920': (_Paint(_splash(dark: false)), 1080, 1920),
        'splash_dark_1080x1920': (_Paint(_splash(dark: true)), 1080, 1920),
      };
      for (final MapEntry(key: name, value: (painter, w, h))
          in previews.entries) {
        final image = await _render(painter, w, h);
        _write('store/previews/$name.png', encodePng(image, alpha: true));
      }
    },
  );
}
