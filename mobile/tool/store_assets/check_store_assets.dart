// Checks the store assets against Google Play's published limits (PLAY_STORE §5) by
// reading each PNG's header: pixel size, bits per pixel / alpha, and file size.
//
//   dart run tool/store_assets/check_store_assets.dart [--require-screenshots]
//
// From mobile/. Exit 0 when everything present is within the limits (and, with
// --require-screenshots, when there are 2 to 8 phone screenshots); 1 otherwise, with
// every problem listed.
//
//   store/play_icon_512.png             512 x 512, 32-bit PNG (RGBA), <= 1 MB
//   store/feature_graphic_1024x500.png  1024 x 500, 24-bit PNG, no alpha (no tRNS)
//   store/screenshots/*.png             2-8; 24-bit PNG, no alpha; each side 320-3840 px;
//                                       the long side at most twice the short side;
//                                       <= 8 MB; this app's capture: 1080 wide, portrait
//   store/whatsnew/en-US.txt            the release notes: at most 500 characters, calm
//   android/.../mipmap-*/ic_launcher(_round).png   the legacy launcher sizes, 48-192 px
import 'dart:io';
import 'dart:typed_data';

import 'png.dart';

const _mb = 1024 * 1024;

const _densities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

class _Check {
  final List<String> problems = [];
  final List<String> lines = [];

  ({PngInfo info, bool hasTransparencyChunk, int bytes})? read(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      problems.add('$path is missing');
      return null;
    }
    final Uint8List bytes = file.readAsBytesSync();
    try {
      final header = readPngInfo(bytes);
      return (
        info: header.info,
        hasTransparencyChunk: header.hasTransparencyChunk,
        bytes: bytes.length,
      );
    } on FormatException catch (error) {
      problems.add('$path is not a readable PNG: ${error.message}');
      return null;
    }
  }

  void describe(String path, PngInfo info, int bytes) => lines.add(
    '  $path: ${info.width} x ${info.height}, ${info.bitsPerPixel}-bit '
    '(${info.hasAlphaChannel ? 'with' : 'no'} alpha), $bytes bytes',
  );

  void expectThat(bool ok, String problem) {
    if (!ok) {
      problems.add(problem);
    }
  }
}

void main(List<String> args) {
  final requireScreenshots = args.contains('--require-screenshots');
  final check = _Check();

  // --- the Play icon ---------------------------------------------------------------------
  const icon = 'store/play_icon_512.png';
  if (check.read(icon) case final png?) {
    check
      ..describe(icon, png.info, png.bytes)
      ..expectThat(
        png.info.width == 512 && png.info.height == 512,
        '$icon must be 512 x 512 (is ${png.info.width} x ${png.info.height})',
      )
      ..expectThat(
        png.info.bitsPerPixel == 32 && png.info.colorType == 6,
        '$icon must be a 32-bit PNG (RGBA) (is ${png.info.bitsPerPixel}-bit)',
      )
      ..expectThat(png.bytes <= _mb, '$icon must be at most 1 MB');
  }

  // --- the feature graphic ---------------------------------------------------------------
  const feature = 'store/feature_graphic_1024x500.png';
  if (check.read(feature) case final png?) {
    check
      ..describe(feature, png.info, png.bytes)
      ..expectThat(
        png.info.width == 1024 && png.info.height == 500,
        '$feature must be 1024 x 500 (is ${png.info.width} x ${png.info.height})',
      )
      ..expectThat(
        png.info.colorType == 2 &&
            png.info.bitDepth == 8 &&
            !png.hasTransparencyChunk,
        '$feature must be a 24-bit PNG without alpha (is ${png.info.bitsPerPixel}-bit, '
        'colour type ${png.info.colorType}${png.hasTransparencyChunk ? ', tRNS' : ''})',
      )
      ..expectThat(png.bytes <= 15 * _mb, '$feature must be at most 15 MB');
  }

  // --- the phone screenshots ---------------------------------------------------------------
  final shotsDir = Directory('store/screenshots');
  final shots = shotsDir.existsSync()
      ? (shotsDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.png'))
            .map((f) => f.path)
            .toList()
          ..sort())
      : <String>[];
  if (requireScreenshots || shots.isNotEmpty) {
    check.expectThat(
      shots.length >= 2 && shots.length <= 8,
      'Play takes 2 to 8 phone screenshots; store/screenshots has ${shots.length}',
    );
  }
  for (final shot in shots) {
    final png = check.read(shot);
    if (png == null) {
      continue;
    }
    final w = png.info.width;
    final h = png.info.height;
    final long = w > h ? w : h;
    final short = w > h ? h : w;
    check
      ..describe(shot, png.info, png.bytes)
      ..expectThat(
        png.info.colorType == 2 &&
            png.info.bitDepth == 8 &&
            !png.hasTransparencyChunk,
        '$shot must be a 24-bit PNG without alpha',
      )
      ..expectThat(
        short >= 320 && long <= 3840,
        '$shot: each side must be 320-3840 px (is $w x $h)',
      )
      ..expectThat(long <= 2 * short, '$shot: aspect ratio over 2:1 ($w x $h)')
      ..expectThat(
        w == 1080 && h <= 2160 && h > w,
        '$shot: expected a 1080 px wide portrait capture, at most 2160 high '
        '(is $w x $h)',
      )
      ..expectThat(png.bytes <= 8 * _mb, '$shot must be at most 8 MB');
  }

  // --- the release notes ("What's new", at most 500 characters per language) ---------------
  const notes = 'store/whatsnew/en-US.txt';
  final notesFile = File(notes);
  if (!notesFile.existsSync()) {
    check.problems.add('$notes is missing');
  } else {
    final text = notesFile.readAsStringSync().trim();
    check
      ..lines.add('  $notes: ${text.length} characters')
      ..expectThat(text.isNotEmpty, '$notes is empty')
      ..expectThat(
        text.length <= 500,
        '$notes has ${text.length} characters; Play allows 500',
      )
      ..expectThat(
        !text.contains('!'),
        '$notes: no exclamation marks (USER_FLOWS §15)',
      )
      ..expectThat(
        !RegExp(
          r'end-to-end|zero-knowledge|\b(buy|price|subscribe|upgrade)\b|[₹$]',
          caseSensitive: false,
        ).hasMatch(text),
        '$notes: no encryption claims and no purchase language',
      );
  }

  // --- the legacy launcher icons -----------------------------------------------------------
  for (final MapEntry(key: density, value: px) in _densities.entries) {
    for (final name in ['ic_launcher', 'ic_launcher_round']) {
      final path = 'android/app/src/main/res/mipmap-$density/$name.png';
      if (check.read(path) case final png?) {
        check.expectThat(
          png.info.width == px && png.info.height == px,
          '$path must be $px x $px (is ${png.info.width} x ${png.info.height})',
        );
      }
    }
  }

  stdout.writeln('Store assets:');
  check.lines.forEach(stdout.writeln);
  if (check.problems.isNotEmpty) {
    stderr.writeln('Problems:');
    for (final problem in check.problems) {
      stderr.writeln('  $problem');
    }
    exit(1);
  }
  stdout.writeln(
    'OK: the icon, the feature graphic${shots.isEmpty ? '' : ', ${shots.length} screenshots'} '
    'and the legacy launcher icons are within the limits.',
  );
}
