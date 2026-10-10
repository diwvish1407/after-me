import 'dart:io';

import 'package:flutter/services.dart';

/// Loads the real Roboto faces from the Flutter SDK into the test engine.
///
/// `flutter test` normally renders every glyph with a square fixture font, which makes
/// text far wider than on a device and hides (or invents) wrapping problems. Layout
/// tests that depend on true text widths call this in `setUpAll`.
Future<void> loadRoboto() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    throw StateError('FLUTTER_ROOT is not set; cannot find the SDK fonts.');
  }
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final face in ['Regular', 'Medium', 'Bold']) {
    final bytes = File('$dir/Roboto-$face.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
  }
  await loader.load();
}
