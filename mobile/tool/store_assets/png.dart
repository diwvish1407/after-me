// A small PNG reader and writer for the store assets (PLAY_STORE §5), with no dependency
// beyond dart:io's zlib: the Play listing needs **24-bit PNGs without alpha** (the feature
// graphic, the screenshots), which Flutter's own encoder cannot write (it always writes
// RGBA). Used by tool/store_assets/render_test.dart (writing), test_driver/
// screenshots_driver.dart (reading a capture, cropping it, writing it without alpha) and
// tool/store_assets/check_store_assets.dart (reading the header).
//
// Scope, on purpose: 8 bits per channel, colour types 2 (RGB) and 6 (RGBA), no
// interlacing. Anything else is refused with a clear error rather than misread.
import 'dart:io';
import 'dart:typed_data';

const _signature = [137, 80, 78, 71, 13, 10, 26, 10];

/// What a PNG's header says.
class PngInfo {
  const PngInfo({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlaced,
  });

  final int width;
  final int height;
  final int bitDepth;

  /// 0 grey, 2 RGB, 3 palette, 4 grey+alpha, 6 RGBA.
  final int colorType;
  final bool interlaced;

  /// Whether the image carries an alpha channel (colour types 4 and 6). A palette image
  /// with a `tRNS` chunk can also be transparent; [readPngInfo] reports that separately.
  bool get hasAlphaChannel => colorType == 4 || colorType == 6;

  /// Bits per pixel: 24 for 8-bit RGB, 32 for 8-bit RGBA.
  int get bitsPerPixel {
    const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
    return (channels[colorType] ?? 0) * bitDepth;
  }
}

/// A decoded image: straight (not premultiplied) RGBA, row by row.
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height * 4);

  final int width;
  final int height;
  final Uint8List pixels;

  /// The rectangle [left], [top], [cropWidth] x [cropHeight] of this image.
  RgbaImage crop(int left, int top, int cropWidth, int cropHeight) {
    if (left < 0 ||
        top < 0 ||
        cropWidth <= 0 ||
        cropHeight <= 0 ||
        left + cropWidth > width ||
        top + cropHeight > height) {
      throw ArgumentError(
        'crop $left,$top ${cropWidth}x$cropHeight is outside ${width}x$height',
      );
    }
    final out = Uint8List(cropWidth * cropHeight * 4);
    for (var y = 0; y < cropHeight; y++) {
      final from = ((top + y) * width + left) * 4;
      out.setRange(y * cropWidth * 4, (y + 1) * cropWidth * 4, pixels, from);
    }
    return RgbaImage(cropWidth, cropHeight, out);
  }

  /// Every pixel composited over the opaque [background] (0xRRGGBB): the result has no
  /// transparency left, so it can be written as 24-bit RGB.
  RgbaImage flattenOn(int background) {
    final br = (background >> 16) & 0xFF;
    final bg = (background >> 8) & 0xFF;
    final bb = background & 0xFF;
    final out = Uint8List.fromList(pixels);
    for (var i = 0; i < out.length; i += 4) {
      final a = out[i + 3];
      if (a == 255) {
        continue;
      }
      out[i] = (out[i] * a + br * (255 - a) + 127) ~/ 255;
      out[i + 1] = (out[i + 1] * a + bg * (255 - a) + 127) ~/ 255;
      out[i + 2] = (out[i + 2] * a + bb * (255 - a) + 127) ~/ 255;
      out[i + 3] = 255;
    }
    return RgbaImage(width, height, out);
  }

  /// Whether every pixel is fully opaque.
  bool get isOpaque {
    for (var i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 255) {
        return false;
      }
    }
    return true;
  }
}

// --- CRC-32 (ISO 3309), as PNG chunks need -------------------------------------------

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(List<int> bytes, [int start = 0, int? end]) {
  var c = 0xFFFFFFFF;
  for (var i = start; i < (end ?? bytes.length); i++) {
    c = _crcTable[(c ^ bytes[i]) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}

// --- writing ----------------------------------------------------------------------------

void _chunk(BytesBuilder out, String type, List<int> data) {
  final header = ByteData(4)..setUint32(0, data.length);
  out.add(header.buffer.asUint8List());
  final typed = [...type.codeUnits, ...data];
  out.add(typed);
  final crc = ByteData(4)..setUint32(0, _crc32(typed));
  out.add(crc.buffer.asUint8List());
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs();
  final pb = (p - b).abs();
  final pc = (p - c).abs();
  if (pa <= pb && pa <= pc) {
    return a;
  }
  return pb <= pc ? b : c;
}

/// Encodes [image] as an 8-bit PNG: RGBA (colour type 6, 32-bit) when [alpha] is true,
/// otherwise RGB (colour type 2, 24-bit). Writing RGB refuses an image that still has
/// transparency: flatten it on its background first ([RgbaImage.flattenOn]).
Uint8List encodePng(RgbaImage image, {required bool alpha}) {
  if (!alpha && !image.isOpaque) {
    throw ArgumentError(
      'the image has transparent pixels; flatten it before writing RGB',
    );
  }
  final channels = alpha ? 4 : 3;
  final stride = image.width * channels;
  final raw = Uint8List((stride + 1) * image.height);
  var previous = Uint8List(stride);
  final row = Uint8List(stride);
  final candidate = Uint8List(stride);
  final best = Uint8List(stride);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final from = (y * image.width + x) * 4;
      final to = x * channels;
      row[to] = image.pixels[from];
      row[to + 1] = image.pixels[from + 1];
      row[to + 2] = image.pixels[from + 2];
      if (alpha) {
        row[to + 3] = image.pixels[from + 3];
      }
    }
    // The usual heuristic: of the five filters, the one whose output has the smallest
    // sum of absolute (signed) values compresses best.
    var bestFilter = 0;
    var bestScore = -1;
    for (var filter = 0; filter <= 4; filter++) {
      var score = 0;
      for (var i = 0; i < stride; i++) {
        final a = i >= channels ? row[i - channels] : 0;
        final b = previous[i];
        final c = i >= channels ? previous[i - channels] : 0;
        final predicted = switch (filter) {
          0 => 0,
          1 => a,
          2 => b,
          3 => (a + b) >> 1,
          _ => _paeth(a, b, c),
        };
        final value = (row[i] - predicted) & 0xFF;
        candidate[i] = value;
        score += value < 128 ? value : 256 - value;
      }
      if (bestScore < 0 || score < bestScore) {
        bestScore = score;
        bestFilter = filter;
        best.setAll(0, candidate);
      }
    }
    final offset = y * (stride + 1);
    raw[offset] = bestFilter;
    raw.setRange(offset + 1, offset + 1 + stride, best);
    previous = Uint8List.fromList(row);
  }

  final out = BytesBuilder(copy: false)..add(_signature);
  final header = ByteData(13)
    ..setUint32(0, image.width)
    ..setUint32(4, image.height)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, alpha ? 6 : 2) // colour type
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter method
    ..setUint8(12, 0); // no interlace
  _chunk(out, 'IHDR', header.buffer.asUint8List());
  // sRGB, perceptual: what the pixels already are.
  _chunk(out, 'sRGB', const [0]);
  _chunk(out, 'IDAT', ZLibCodec(level: 9).encode(raw));
  _chunk(out, 'IEND', const []);
  return out.takeBytes();
}

// --- reading ----------------------------------------------------------------------------

class _Chunks {
  _Chunks(this.info, this.data, this.hasTransparencyChunk);
  final PngInfo info;
  final Uint8List data;
  final bool hasTransparencyChunk;
}

_Chunks _readChunks(Uint8List bytes) {
  if (bytes.length < 8 + 25) {
    throw const FormatException('not a PNG: too short');
  }
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _signature[i]) {
      throw const FormatException('not a PNG: bad signature');
    }
  }
  final view = ByteData.sublistView(bytes);
  var offset = 8;
  PngInfo? info;
  var transparency = false;
  final idat = BytesBuilder(copy: false);
  while (offset + 8 <= bytes.length) {
    final length = view.getUint32(offset);
    final type = String.fromCharCodes(bytes, offset + 4, offset + 8);
    final start = offset + 8;
    if (start + length + 4 > bytes.length) {
      throw FormatException('truncated $type chunk');
    }
    final crc = view.getUint32(start + length);
    if (_crc32(bytes, offset + 4, start + length) != crc) {
      throw FormatException('bad CRC in the $type chunk');
    }
    switch (type) {
      case 'IHDR':
        info = PngInfo(
          width: view.getUint32(start),
          height: view.getUint32(start + 4),
          bitDepth: bytes[start + 8],
          colorType: bytes[start + 9],
          interlaced: bytes[start + 12] != 0,
        );
      case 'tRNS':
        transparency = true;
      case 'IDAT':
        idat.add(Uint8List.sublistView(bytes, start, start + length));
      case 'IEND':
        offset = bytes.length;
        continue;
    }
    offset = start + length + 4;
  }
  if (info == null) {
    throw const FormatException('no IHDR chunk');
  }
  return _Chunks(info, idat.takeBytes(), transparency);
}

/// The header of the PNG in [bytes], and whether a `tRNS` chunk adds transparency to an
/// image without an alpha channel.
({PngInfo info, bool hasTransparencyChunk}) readPngInfo(Uint8List bytes) {
  final chunks = _readChunks(bytes);
  return (info: chunks.info, hasTransparencyChunk: chunks.hasTransparencyChunk);
}

/// Decodes an 8-bit, non-interlaced RGB or RGBA PNG to straight RGBA.
RgbaImage decodePng(Uint8List bytes) {
  final chunks = _readChunks(bytes);
  final info = chunks.info;
  if (info.bitDepth != 8 ||
      (info.colorType != 2 && info.colorType != 6) ||
      info.interlaced) {
    throw FormatException(
      'unsupported PNG: bit depth ${info.bitDepth}, colour type '
      '${info.colorType}, interlaced ${info.interlaced} (8-bit RGB/RGBA only)',
    );
  }
  final channels = info.colorType == 6 ? 4 : 3;
  final stride = info.width * channels;
  final raw = Uint8List.fromList(ZLibCodec().decode(chunks.data));
  if (raw.length < (stride + 1) * info.height) {
    throw const FormatException('image data is shorter than the header says');
  }
  final out = Uint8List(info.width * info.height * 4);
  var previous = Uint8List(stride);
  for (var y = 0; y < info.height; y++) {
    final offset = y * (stride + 1);
    final filter = raw[offset];
    final row = Uint8List.sublistView(raw, offset + 1, offset + 1 + stride);
    for (var i = 0; i < stride; i++) {
      final a = i >= channels ? row[i - channels] : 0;
      final b = previous[i];
      final c = i >= channels ? previous[i - channels] : 0;
      final predicted = switch (filter) {
        0 => 0,
        1 => a,
        2 => b,
        3 => (a + b) >> 1,
        4 => _paeth(a, b, c),
        _ => throw FormatException('unknown filter $filter in row $y'),
      };
      row[i] = (row[i] + predicted) & 0xFF;
    }
    for (var x = 0; x < info.width; x++) {
      final from = x * channels;
      final to = (y * info.width + x) * 4;
      out[to] = row[from];
      out[to + 1] = row[from + 1];
      out[to + 2] = row[from + 2];
      out[to + 3] = channels == 4 ? row[from + 3] : 255;
    }
    previous = row;
  }
  return RgbaImage(info.width, info.height, out);
}
